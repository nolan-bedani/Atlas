#!/usr/bin/env bash
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
# NOTE: The schema import below is idempotent only on a FRESH (empty) database.
#       Do NOT re-run this step against an already-populated Zabbix database —
#       it will fail with duplicate-object errors. If you need to re-provision,
#       drop and recreate the database first.
# =============================================================================
echo "[INFO] Step 4/7 — Creating database '${ZABBIX_DB_NAME}' and user '${ZABBIX_DB_USER}' ..."
pct exec "${CTID}" -- bash -c "
    mysql -u root <<SQL
CREATE DATABASE IF NOT EXISTS ${ZABBIX_DB_NAME} CHARACTER SET utf8mb4 COLLATE utf8mb4_bin;
CREATE USER IF NOT EXISTS '${ZABBIX_DB_USER}'@'localhost' IDENTIFIED BY '${ZABBIX_DB_PASSWORD}';
GRANT ALL PRIVILEGES ON ${ZABBIX_DB_NAME}.* TO '${ZABBIX_DB_USER}'@'localhost';
FLUSH PRIVILEGES;
SQL
"
echo "[OK]   Database '${ZABBIX_DB_NAME}' and user '${ZABBIX_DB_USER}'@'localhost' created."

echo "[INFO]           Importing initial Zabbix schema into '${ZABBIX_DB_NAME}' ..."
pct exec "${CTID}" -- bash -c \
    "zcat /usr/share/zabbix/sql-scripts/mysql/server.sql.gz | mysql -u${ZABBIX_DB_USER} -p${ZABBIX_DB_PASSWORD} ${ZABBIX_DB_NAME}"
echo "[OK]   Zabbix initial schema imported successfully."

# =============================================================================
# STEP 5 — Configure /etc/zabbix/zabbix_server.conf
#
# Targeted sed substitutions are used so that upstream config comments and all
# other directives are preserved exactly as shipped.  Each pattern matches both
# commented-out (e.g. "# DBHost=") and active lines, replacing with the live
# value.
# =============================================================================
echo "[INFO] Step 5/7 — Configuring /etc/zabbix/zabbix_server.conf ..."
pct exec "${CTID}" -- sed -i \
    "s|^.*DBHost=.*|DBHost=localhost|" \
    /etc/zabbix/zabbix_server.conf
pct exec "${CTID}" -- sed -i \
    "s|^.*DBName=.*|DBName=${ZABBIX_DB_NAME}|" \
    /etc/zabbix/zabbix_server.conf
pct exec "${CTID}" -- sed -i \
    "s|^.*DBUser=.*|DBUser=${ZABBIX_DB_USER}|" \
    /etc/zabbix/zabbix_server.conf
pct exec "${CTID}" -- sed -i \
    "s|^.*DBPassword=.*|DBPassword=${ZABBIX_DB_PASSWORD}|" \
    /etc/zabbix/zabbix_server.conf
echo "[OK]   zabbix_server.conf updated (DBHost, DBName, DBUser, DBPassword)."

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
printf " %-24s : %s\n" "Default web creds" "Admin / zabbix — CHANGE IMMEDIATELY after first login"
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
echo "  2. After the installer completes and you log in with 'Admin / zabbix',"
echo "     change the Admin password IMMEDIATELY:"
echo "       Administration → Users → Admin → Change password"
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
