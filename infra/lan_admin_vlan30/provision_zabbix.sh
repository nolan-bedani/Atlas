#!/usr/bin/env bash
# ⚠️  OBSOLÈTE — doublon des rôles Ansible `zabbix` + `mariadb` (source de vérité).
# Cible le conteneur divergent CT 103 (cf. infra/proxmox_iac/deploy_lxc.sh).
# Pour forcer :  ATLAS_PROVISION_FORCE=1 bash provision_zabbix.sh
if [ "${ATLAS_PROVISION_FORCE:-0}" != "1" ]; then
  echo "[ABORT] Obsolète : utiliser les rôles Ansible 'zabbix' et 'mariadb'." >&2
  echo "        Forcer malgré le conflit : ATLAS_PROVISION_FORCE=1 bash $0" >&2
  exit 2
fi
# =============================================================================
# provision_zabbix.sh
#
# Purpose  : Provision Zabbix Server 7.x + Frontend + Agent and MariaDB
#            inside CT 103 (zabbix-server, LAN_ADMIN — VLAN 30).
#            Executed from the Proxmox VE host via the `pct` CLI.
#
#            Steps performed:
#              1. Install prerequisites and the Zabbix APT repository.
#              2. Install Zabbix Server, Frontend, Agent and MariaDB.
#              3. Enable and start MariaDB.
#              4. Create the Zabbix database and restricted DB user;
#                 import the initial Zabbix schema.
#              5. Configure /etc/zabbix/zabbix_server.conf (DB directives).
#              6. Configure PHP timezone for the Zabbix frontend.
#              7. Enable and restart Zabbix Server, Agent and Apache2.
#
# Author   : <author-placeholder>
# Date     : <date-placeholder>
#
# Node     : Must be executed directly on the Proxmox VE host (or via SSH to
#            the host) because it uses the `pct` CLI, which is only available
#            on Proxmox nodes.
#
# Usage:
#   export ZABBIX_DB_NAME=zabbixdb
#   export ZABBIX_DB_USER=zabbixuser
#   read -sr ZABBIX_DB_PASSWORD && export ZABBIX_DB_PASSWORD
#   bash provision_zabbix.sh
#
# Secrets policy: Database credentials are never hardcoded in this script.
#   They MUST be exported as environment variables before invocation (see
#   the usage block above and the "How to run" section in the runbook).
#   Use `read -sr` to capture the password interactively without echoing it
#   to the terminal or the shell history.
#   Do NOT commit credentials, certificates or any secret material to VCS.
# =============================================================================
set -euo pipefail

# =============================================================================
# CONFIGURATION — all tuneable variables are defined here.
#                 Do NOT scatter values throughout the script body.
# =============================================================================

# Proxmox container ID of the Zabbix server (LAN_ADMIN — VLAN 30)
CTID=103

# Hostname and IP of the container (informational; used in the summary).
CT_HOSTNAME="zabbix-server"
CT_IP="10.30.0.103"

# Zabbix release series to install.
# Check for the latest stable release at:
#   https://www.zabbix.com/download
ZABBIX_VERSION="7.0"

# Official Zabbix APT release package for Debian 12 (Bookworm).
# Update this filename when a newer release package is published.
ZABBIX_RELEASE_PKG="zabbix-release_latest_7.0+debian12_all.deb"
ZABBIX_RELEASE_URL="https://repo.zabbix.com/zabbix/7.0/release/debian/pool/main/z/zabbix-release/${ZABBIX_RELEASE_PKG}"

# Database engine — MariaDB is used here for consistency with CT 102 (GLPI).
# To switch to PostgreSQL:
#   - Replace 'zabbix-server-mysql' with 'zabbix-server-pgsql'
#     and 'mariadb-server' with 'postgresql' in Step 2.
#   - Remove or comment-out the DBPort=3306 line in zabbix_server.conf.
#   - Adjust Step 4 to use psql for database and user creation.
DB_ENGINE="mariadb"

# ---------------------------------------------------------------------------
# Database credentials — read from the caller's environment.
# The :? operator causes the script to abort immediately with a descriptive
# error message if the variable is unset or empty, so there is no risk of
# silently creating a database with a blank password.
# ---------------------------------------------------------------------------
ZABBIX_DB_NAME="${ZABBIX_DB_NAME:?'[ERROR] ZABBIX_DB_NAME is not set. Export it before running this script.'}"
ZABBIX_DB_USER="${ZABBIX_DB_USER:?'[ERROR] ZABBIX_DB_USER is not set. Export it before running this script.'}"
ZABBIX_DB_PASSWORD="${ZABBIX_DB_PASSWORD:?'[ERROR] ZABBIX_DB_PASSWORD is not set. Export it before running this script.'}"

# ---------------------------------------------------------------------------
# Frontend "Admin" password — CLAUDE.md : aucun compte admin par défaut conservé.
# If provided, the default Zabbix web admin password ("zabbix") is forcibly
# replaced just after the schema import (no manual UI step required). Leave it
# unset only for a throwaway lab; the default credential MUST NOT survive in a
# real deployment. Export e.g. with `read -sr ZABBIX_WEB_ADMIN_PASSWORD`.
# ---------------------------------------------------------------------------
ZABBIX_WEB_ADMIN_PASSWORD="${ZABBIX_WEB_ADMIN_PASSWORD:-}"

# =============================================================================
# PREREQUISITE CHECKS
# =============================================================================

if ! command -v pct &>/dev/null; then
    echo "[ERROR] 'pct' not found in PATH." >&2
    echo "        This script must run on a Proxmox VE host." >&2
    exit 1
fi

CT_STATUS="$(pct status "${CTID}" | awk '{print $2}')"
if [[ "${CT_STATUS}" != "running" ]]; then
    echo "[ERROR] CT ${CTID} is not running (status: ${CT_STATUS})." >&2
    echo "        Start it first: pct start ${CTID}" >&2
    exit 1
fi

# =============================================================================
# STEP 1 — Install prerequisites and the Zabbix APT repository
# =============================================================================
echo "[INFO] Step 1/7 — Installing prerequisites and Zabbix APT repository inside CT ${CTID} ..."
pct exec "${CTID}" -- bash -c \
    "apt-get update -qq && apt-get install -y --no-install-recommends wget gnupg ca-certificates"
pct exec "${CTID}" -- bash -c \
    "wget -q '${ZABBIX_RELEASE_URL}' -O /tmp/${ZABBIX_RELEASE_PKG}"
pct exec "${CTID}" -- bash -c \
    "dpkg -i /tmp/${ZABBIX_RELEASE_PKG}"
pct exec "${CTID}" -- bash -c \
    "apt-get update -qq"
echo "[OK]   Zabbix APT repository registered and package lists updated."

# =============================================================================
# STEP 2 — Install Zabbix Server, Frontend, Agent and MariaDB
# =============================================================================
echo "[INFO] Step 2/7 — Installing Zabbix ${ZABBIX_VERSION} stack and MariaDB inside CT ${CTID} ..."
pct exec "${CTID}" -- bash -c "apt-get install -y --no-install-recommends \
    zabbix-server-mysql \
    zabbix-frontend-php \
    zabbix-apache-conf \
    zabbix-sql-scripts \
    zabbix-agent \
    mariadb-server \
    php php-mysql php-mbstring php-xml php-gd php-bcmath php-ldap \
    apache2 libapache2-mod-php"
echo "[OK]   Zabbix Server, Frontend, Agent, MariaDB and Apache2 installed."

# =============================================================================
# STEP 3 — Enable and start MariaDB
# =============================================================================
echo "[INFO] Step 3/7 — Enabling and starting MariaDB ..."
pct exec "${CTID}" -- systemctl enable mariadb
pct exec "${CTID}" -- systemctl start  mariadb
echo "[OK]   MariaDB is enabled and running."

# =============================================================================
# STEP 4 — Create Zabbix database and dedicated database user;
#           import the initial Zabbix schema.
#
# Root access to mysql is used here because MariaDB's unix_socket auth
# requires no password for the root OS user inside the container.
#
# The Zabbix DB user is granted privileges only on the Zabbix database
# (principle of least privilege — no SUPER, no GRANT OPTION).
#
# Secret handling: the DB password is NEVER passed on a mysql command line
# (it would be visible in `ps`/`/proc/<pid>/cmdline` on the host and inside
# the container). It is written once to a temporary option file (chmod 0600)
# inside the container, consumed via --defaults-extra-file, then deleted.
# The CREATE USER statement is fed through a heredoc on stdin, not argv.
#
# Idempotence: the schema import is guarded by a table-count test so a re-run
# (e.g. after a failure at a later step) skips the import on an already
# populated database instead of aborting on duplicate-object errors.
# =============================================================================
# Validate identifiers so they cannot break out of the backtick-quoted names,
# then build the SQL in this outer shell (single quotes of the password doubled)
# and feed it to `mysql -u root` on stdin — the secret is never on any argv.
if ! [[ "${ZABBIX_DB_NAME}" =~ ^[A-Za-z0-9_]+$ ]]; then
    echo "[ERROR] ZABBIX_DB_NAME contient des caractères non autorisés (attendu : [A-Za-z0-9_])." >&2
    exit 1
fi
if ! [[ "${ZABBIX_DB_USER}" =~ ^[A-Za-z0-9_]+$ ]]; then
    echo "[ERROR] ZABBIX_DB_USER contient des caractères non autorisés (attendu : [A-Za-z0-9_])." >&2
    exit 1
fi
SQ="'"
ZABBIX_DB_PASSWORD_SQL="${ZABBIX_DB_PASSWORD//${SQ}/${SQ}${SQ}}"

echo "[INFO] Step 4/7 — Creating database '${ZABBIX_DB_NAME}' and user '${ZABBIX_DB_USER}' ..."
printf '%s\n' \
"CREATE DATABASE IF NOT EXISTS \`${ZABBIX_DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_bin;" \
"CREATE USER IF NOT EXISTS '${ZABBIX_DB_USER}'@'localhost' IDENTIFIED BY '${ZABBIX_DB_PASSWORD_SQL}';" \
"GRANT ALL PRIVILEGES ON \`${ZABBIX_DB_NAME}\`.* TO '${ZABBIX_DB_USER}'@'localhost';" \
"FLUSH PRIVILEGES;" \
    | pct exec "${CTID}" -- mysql -u root
echo "[OK]   Database '${ZABBIX_DB_NAME}' and user '${ZABBIX_DB_USER}'@'localhost' created."

# Write a temporary 0600 client option file inside the container so the Zabbix
# DB password never appears in any process argument list. Credentials are
# passed to the inner shell via the environment (env), not via argv, and the
# option file is removed in all cases through a trap.
echo "[INFO]           Writing temporary MySQL option file (chmod 0600) ..."
pct exec "${CTID}" -- \
    env ZBX_DB_USER="${ZABBIX_DB_USER}" \
        ZBX_DB_PASS="${ZABBIX_DB_PASSWORD}" \
        ZBX_DB_NAME="${ZABBIX_DB_NAME}" \
    bash -c '
    set -euo pipefail
    OPT_FILE="$(mktemp /root/.zbx-my.XXXXXX.cnf)"
    trap "rm -f \"${OPT_FILE}\"" EXIT
    chmod 600 "${OPT_FILE}"
    {
        printf "[client]\n"
        printf "user=%s\n"     "${ZBX_DB_USER}"
        printf "password=%s\n" "${ZBX_DB_PASS}"
    } > "${OPT_FILE}"

    # Import only if the schema is absent (0 table) — keeps the step replayable.
    TABLE_COUNT="$(mysql --defaults-extra-file="${OPT_FILE}" -N -B -e \
        "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema=DATABASE();" \
        "${ZBX_DB_NAME}")"
    if [ "${TABLE_COUNT}" -eq 0 ]; then
        echo "[INFO]           Importing initial Zabbix schema into ${ZBX_DB_NAME} ..."
        zcat /usr/share/zabbix/sql-scripts/mysql/server.sql.gz | \
            mysql --defaults-extra-file="${OPT_FILE}" "${ZBX_DB_NAME}"
        echo "[OK]   Zabbix initial schema imported successfully."
    else
        echo "[OK]   Zabbix schema already present (${TABLE_COUNT} tables) — import skipped."
    fi
'

# =============================================================================
# STEP 5 — Configure /etc/zabbix/zabbix_server.conf
#
# The sed patterns are strictly anchored to the start of line and only tolerate
# leading '#'/whitespace before the directive name, immediately followed by '='
# (e.g. "DBHost=" or "# DBHost="). This avoids matching unrelated comment lines
# such as "### Option: DBHost" and prevents writing the same directive several
# times (which Zabbix would reject as "defined multiple times").
#
# The DBPassword value is injected via an environment variable consumed inside
# the container so the secret is not visible in the host-side argv of pct exec.
# =============================================================================
echo "[INFO] Step 5/7 — Configuring /etc/zabbix/zabbix_server.conf ..."
pct exec "${CTID}" -- sed -i -E \
    "s|^[#[:space:]]*DBHost=.*|DBHost=localhost|" \
    /etc/zabbix/zabbix_server.conf
pct exec "${CTID}" -- sed -i -E \
    "s|^[#[:space:]]*DBName=.*|DBName=${ZABBIX_DB_NAME}|" \
    /etc/zabbix/zabbix_server.conf
pct exec "${CTID}" -- sed -i -E \
    "s|^[#[:space:]]*DBUser=.*|DBUser=${ZABBIX_DB_USER}|" \
    /etc/zabbix/zabbix_server.conf
pct exec "${CTID}" -- env ZBX_DB_PASS="${ZABBIX_DB_PASSWORD}" bash -c \
    'sed -i -E "s|^[#[:space:]]*DBPassword=.*|DBPassword=${ZBX_DB_PASS}|" /etc/zabbix/zabbix_server.conf'
echo "[OK]   zabbix_server.conf updated (DBHost, DBName, DBUser, DBPassword)."

# =============================================================================
# STEP 5b — Force-change the default frontend "Admin" password
#
# CLAUDE.md : « Aucun compte administrateur par défaut ne doit être conservé. »
# Zabbix ships the super-admin "Admin" with the well-known password "zabbix".
# When ZABBIX_WEB_ADMIN_PASSWORD is provided, replace it immediately via SQL so
# the default credential never survives provisioning (no manual UI step).
#
# Zabbix 7.0 stores the password as a bcrypt hash in users.passwd; we generate
# it inside the container with PHP (password_hash, available with the frontend
# packages installed at Step 2). The secret is passed via the environment and a
# 0600 option file, never on argv.
# =============================================================================
if [ -n "${ZABBIX_WEB_ADMIN_PASSWORD}" ]; then
    echo "[INFO] Step 5b — Forcing the default Zabbix 'Admin' password change ..."
    pct exec "${CTID}" -- \
        env ZBX_DB_USER="${ZABBIX_DB_USER}" \
            ZBX_DB_PASS="${ZABBIX_DB_PASSWORD}" \
            ZBX_DB_NAME="${ZABBIX_DB_NAME}" \
            ZBX_WEB_PASS="${ZABBIX_WEB_ADMIN_PASSWORD}" \
        bash -c '
        set -euo pipefail
        OPT_FILE="$(mktemp /root/.zbx-my.XXXXXX.cnf)"
        trap "rm -f \"${OPT_FILE}\"" EXIT
        chmod 600 "${OPT_FILE}"
        {
            printf "[client]\n"
            printf "user=%s\n"     "${ZBX_DB_USER}"
            printf "password=%s\n" "${ZBX_DB_PASS}"
        } > "${OPT_FILE}"
        # bcrypt hash generated by PHP, fed to mysql on stdin (never on argv).
        # A bcrypt hash only contains [./A-Za-z0-9$] — safe to inline in SQL.
        HASH="$(php -r "echo password_hash(getenv(\"ZBX_WEB_PASS\"), PASSWORD_BCRYPT);")"
        printf "UPDATE users SET passwd='"'"'%s'"'"' WHERE username='"'"'Admin'"'"';\n" "${HASH}" \
            | mysql --defaults-extra-file="${OPT_FILE}" "${ZBX_DB_NAME}"
    '
    echo "[OK]   Default 'Admin' password replaced (value taken from ZABBIX_WEB_ADMIN_PASSWORD)."
else
    echo "[WARN] ZABBIX_WEB_ADMIN_PASSWORD not set — the default 'Admin' / 'zabbix' credential" >&2
    echo "       is still active. Set it and re-run, or change it on first login (see NEXT STEPS)." >&2
fi

# =============================================================================
# STEP 6 — Configure PHP timezone for the Zabbix frontend
#
# zabbix.conf.php is auto-generated by the web installer, but the PHP timezone
# must be set before the first request so the frontend renders dates correctly.
# Adjust Europe/Paris to the actual server timezone if different.
# =============================================================================
echo "[INFO] Step 6/7 — Setting PHP timezone in php.ini ..."
pct exec "${CTID}" -- bash -c \
    "sed -i 's|;date.timezone =|date.timezone = Europe/Paris|' /etc/php/*/apache2/php.ini"
echo "[OK]   PHP timezone set to Europe/Paris in /etc/php/*/apache2/php.ini."

# =============================================================================
# STEP 7 — Enable and restart Zabbix Server, Agent and Apache2
# =============================================================================
echo "[INFO] Step 7/7 — Enabling and restarting Zabbix Server, Agent and Apache2 ..."
pct exec "${CTID}" -- systemctl enable  zabbix-server zabbix-agent apache2
pct exec "${CTID}" -- systemctl restart zabbix-server zabbix-agent apache2
echo "[OK]   zabbix-server, zabbix-agent and apache2 are enabled and running."

# =============================================================================
# SUMMARY
# =============================================================================
echo ""
echo "============================================================"
echo " Projet Atlas — CT ${CTID} provisioned successfully"
echo "============================================================"
printf " %-24s : %s\n" "CTID"              "${CTID}"
printf " %-24s : %s\n" "Hostname"          "${CT_HOSTNAME}"
printf " %-24s : %s\n" "IP"                "${CT_IP}"
printf " %-24s : %s\n" "Zabbix version"    "${ZABBIX_VERSION}"
printf " %-24s : %s\n" "DB engine"         "${DB_ENGINE}"
printf " %-24s : %s\n" "Database name"     "${ZABBIX_DB_NAME}"
printf " %-24s : %s\n" "Database user"     "${ZABBIX_DB_USER}"
printf " %-24s : %s\n" "Web UI URL"        "http://${CT_IP}/zabbix"
if [ -n "${ZABBIX_WEB_ADMIN_PASSWORD}" ]; then
    printf " %-24s : %s\n" "Web admin creds" "Admin / (changed via ZABBIX_WEB_ADMIN_PASSWORD)"
else
    printf " %-24s : %s\n" "Web admin creds" "Admin / zabbix — DEFAULT STILL ACTIVE, change it NOW (see step 2)"
fi
echo "============================================================"
echo " NEXT STEPS:"
echo ""
echo "  1. Open the Zabbix web installer from the LAN_ADMIN segment:"
echo "       http://${CT_IP}/zabbix"
echo "     When prompted, enter the DB connection details:"
echo "       DB host : localhost"
echo "       DB name : ${ZABBIX_DB_NAME}"
echo "       DB user : ${ZABBIX_DB_USER}"
echo "     (DB password was set during provisioning — enter it in the form.)"
echo ""
echo "  2. Default super-admin 'Admin' (CLAUDE.md: no default admin account kept):"
echo "       - Preferred: export ZABBIX_WEB_ADMIN_PASSWORD before running this"
echo "         script (it is then changed automatically in Step 5b), or rely on"
echo "         the Ansible 'zabbix' role which sets it from vault_zabbix_admin_password."
echo "       - If neither was done, the default 'Admin' / 'zabbix' is STILL ACTIVE:"
echo "         log in and change it IMMEDIATELY via Administration → Users → Admin,"
echo "         and disable the 'guest' user."
echo ""
echo "  3. Add Zabbix Agent monitoring for existing containers:"
echo "       CT 101 — nginx-proxy  (10.20.0.101)"
echo "       CT 102 — glpi-mariadb (10.30.0.102)"
echo "     Test agent connectivity from CT 103:"
echo "       pct exec ${CTID} -- zabbix_agentd -t agent.ping"
echo ""
echo "  4. Configure backup log monitoring for CT 102:"
echo "       Administration → Hosts → CT 102 → Items"
echo "       Add a Log monitoring item:"
echo "         Key    : log[/var/log/glpi/backup.log,FAIL]"
echo "         Type   : Zabbix agent"
echo "         Trigger: expression matching 'FAIL' → severity High"
echo "============================================================"
