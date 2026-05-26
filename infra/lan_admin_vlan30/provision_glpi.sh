#!/usr/bin/env bash
# =============================================================================
# provision_glpi.sh
#
# Purpose  : Provision the GLPI application and MariaDB inside CT 102
#            (glpi-mariadb, LAN_ADMIN — VLAN 30).
#            Executed from the Proxmox VE host via the `pct` CLI.
#
#            Steps performed:
#              1. Install LAMP stack (MariaDB, PHP, Apache2).
#              2. Enable and start MariaDB and Apache2.
#              3. Create the GLPI database and restricted DB user.
#              4. Download the GLPI archive inside the container.
#              5. Extract GLPI and set correct ownership/permissions.
#              6. Write the Apache2 VirtualHost configuration.
#              7. Reload Apache2.
#
# Author   : <author-placeholder>
# Date     : <date-placeholder>
#
# Node     : Must be executed directly on the Proxmox VE host (or via SSH to
#            the host) because it uses the `pct` CLI, which is only available
#            on Proxmox nodes.
#
# Usage:
#   export GLPI_DB_NAME=glpidb
#   export GLPI_DB_USER=glpiuser
#   export GLPI_DB_PASSWORD=<strong-password>
#   bash provision_glpi.sh
#
# Secrets policy: Database credentials are never hardcoded in this script.
#   They MUST be exported as environment variables before invocation (see
#   the usage block above and the "How to run" section in the runbook).
#   Use `read -sr` to capture the password interactively without echoing it
#   to the terminal or the shell history.
# =============================================================================
set -euo pipefail

# =============================================================================
# CONFIGURATION — all tuneable variables are defined here.
#                 Do NOT scatter values throughout the script body.
# =============================================================================

# Proxmox container ID of the GLPI/MariaDB server (LAN_ADMIN — VLAN 30)
CTID=102

# Hostname and IP of the container (informational; used in the summary).
CT_HOSTNAME="glpi-mariadb"
CT_IP="10.30.0.102"

# GLPI release to install.
# Check for the latest stable release at:
#   https://github.com/glpi-project/glpi/releases
GLPI_VERSION="10.0.15"

GLPI_ARCHIVE="glpi-${GLPI_VERSION}.tgz"
GLPI_URL="https://github.com/glpi-project/glpi/releases/download/${GLPI_VERSION}/${GLPI_ARCHIVE}"

# Web root where GLPI will be extracted.
# GLPI 10.x serves content from the /public sub-directory; Apache2 is
# configured accordingly in Step 6.
GLPI_DIR="/var/www/html/glpi"

# ---------------------------------------------------------------------------
# Database credentials — read from the caller's environment.
# The :? operator causes the script to abort immediately with a descriptive
# error message if the variable is unset or empty, so there is no risk of
# silently creating a database with a blank password.
# ---------------------------------------------------------------------------
GLPI_DB_NAME="${GLPI_DB_NAME:?'[ERROR] GLPI_DB_NAME is not set. Export it before running this script.'}"
GLPI_DB_USER="${GLPI_DB_USER:?'[ERROR] GLPI_DB_USER is not set. Export it before running this script.'}"
GLPI_DB_PASSWORD="${GLPI_DB_PASSWORD:?'[ERROR] GLPI_DB_PASSWORD is not set. Export it before running this script.'}"

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
# STEP 1 — Install LAMP stack
# =============================================================================
echo "[INFO] Step 1/7 — Installing LAMP stack inside CT ${CTID} ..."
pct exec "${CTID}" -- bash -c "apt-get update -qq && apt-get install -y --no-install-recommends \
    mariadb-server \
    php php-fpm php-mysql php-xml php-curl php-gd php-mbstring php-zip php-intl php-ldap \
    apache2 libapache2-mod-php \
    wget curl ca-certificates"
echo "[OK]   LAMP stack installed."

# =============================================================================
# STEP 2 — Enable and start MariaDB and Apache2
# =============================================================================
echo "[INFO] Step 2/7 — Enabling and starting MariaDB and Apache2 ..."
pct exec "${CTID}" -- systemctl enable mariadb apache2
pct exec "${CTID}" -- systemctl start  mariadb apache2
echo "[OK]   MariaDB and Apache2 are enabled and running."

# =============================================================================
# STEP 3 — Create GLPI database and dedicated database user
#
# Root access to mysql is used here because MariaDB's unix_socket auth
# requires no password for the root OS user inside the container.
#
# The GLPI DB user is granted privileges only on the GLPI database
# (principle of least privilege — no SUPER, no GRANT OPTION).
# =============================================================================
echo "[INFO] Step 3/7 — Creating database '${GLPI_DB_NAME}' and user '${GLPI_DB_USER}' ..."
pct exec "${CTID}" -- bash -c "
    mysql -u root <<SQL
CREATE DATABASE IF NOT EXISTS ${GLPI_DB_NAME} CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${GLPI_DB_USER}'@'localhost' IDENTIFIED BY '${GLPI_DB_PASSWORD}';
GRANT ALL PRIVILEGES ON ${GLPI_DB_NAME}.* TO '${GLPI_DB_USER}'@'localhost';
FLUSH PRIVILEGES;
SQL
"
echo "[OK]   Database '${GLPI_DB_NAME}' and user '${GLPI_DB_USER}'@'localhost' created."

# =============================================================================
# STEP 4 — Download GLPI archive inside the container
# =============================================================================
echo "[INFO] Step 4/7 — Downloading GLPI ${GLPI_VERSION} from GitHub ..."
pct exec "${CTID}" -- bash -c "wget -q '${GLPI_URL}' -O /tmp/${GLPI_ARCHIVE}"
echo "[OK]   GLPI ${GLPI_VERSION} downloaded to /tmp/${GLPI_ARCHIVE}."

# =============================================================================
# STEP 5 — Extract GLPI and set ownership / permissions
# =============================================================================
echo "[INFO] Step 5/7 — Extracting GLPI to /var/www/html/ ..."
pct exec "${CTID}" -- bash -c "tar -xzf /tmp/${GLPI_ARCHIVE} -C /var/www/html/"

echo "[INFO]           Setting ownership and permissions on ${GLPI_DIR} ..."
pct exec "${CTID}" -- bash -c "chown -R www-data:www-data ${GLPI_DIR}"
pct exec "${CTID}" -- bash -c "find ${GLPI_DIR} -type d -exec chmod 755 {} \;"
pct exec "${CTID}" -- bash -c "find ${GLPI_DIR} -type f -exec chmod 644 {} \;"
echo "[OK]   GLPI extracted and permissions set (www-data:www-data, 755/644)."

# =============================================================================
# STEP 6 — Configure Apache2 VirtualHost for GLPI
#
# Design notes:
#   - Listens on port 80 only: TLS termination is handled by the Nginx proxy
#     in CT 101 (DMZ — VLAN 20). Apache2 must NOT expose port 443.
#   - DocumentRoot points to /public as required by GLPI 10.x.
#   - AllowOverride All enables GLPI's .htaccess rewrite rules.
#   - mod_rewrite is enabled inside the container.
#   - The default Apache2 site (000-default) is disabled; only the GLPI site
#     is active, minimising the exposed attack surface.
# =============================================================================
echo "[INFO] Step 6/7 — Writing Apache2 VirtualHost for GLPI ..."
pct exec "${CTID}" -- bash -c "cat > /etc/apache2/sites-available/glpi.conf <<'APACHECONF'
# -----------------------------------------------------------------------------
# Projet Atlas — Apache2 VirtualHost for GLPI
# Zone     : LAN_ADMIN (VLAN 30 — 10.30.0.0/24)
# Backend  : CT 102 (glpi-mariadb) — 10.30.0.102:80
# TLS      : Terminated by Nginx reverse-proxy in CT 101 (DMZ — VLAN 20).
#            This VHost listens on HTTP only; it must NOT be reachable from
#            the Internet or DMZ directly.
# GLPI 10.x requires DocumentRoot to point to the /public subdirectory.
# -----------------------------------------------------------------------------
<VirtualHost *:80>
    ServerName helpdesk.atlas.internal

    DocumentRoot /var/www/html/glpi/public

    <Directory /var/www/html/glpi/public>
        Options -Indexes +FollowSymLinks
        AllowOverride All
        Require all granted
    </Directory>

    # Deny direct access to GLPI internal directories (config, files, lib, etc.)
    <Directory /var/www/html/glpi>
        Options -Indexes
        AllowOverride None
        Require all denied
    </Directory>

    <Directory /var/www/html/glpi/public>
        # Re-grant access specifically to /public (overrides the deny above).
        Require all granted
    </Directory>

    ErrorLog  \${APACHE_LOG_DIR}/glpi_error.log
    CustomLog \${APACHE_LOG_DIR}/glpi_access.log combined
</VirtualHost>
APACHECONF
"

echo "[INFO]           Enabling mod_rewrite and GLPI site ..."
pct exec "${CTID}" -- bash -c "a2enmod rewrite"
pct exec "${CTID}" -- bash -c "a2dissite 000-default"
pct exec "${CTID}" -- bash -c "a2ensite glpi"
echo "[OK]   Apache2 VirtualHost configured; default site disabled."

# =============================================================================
# STEP 7 — Reload Apache2 to apply the new VirtualHost
# =============================================================================
echo "[INFO] Step 7/7 — Reloading Apache2 ..."
pct exec "${CTID}" -- systemctl reload apache2
echo "[OK]   Apache2 reloaded successfully."

# =============================================================================
# SUMMARY
# =============================================================================
echo ""
echo "============================================================"
echo " Projet Atlas — CT ${CTID} provisioned successfully"
echo "============================================================"
printf " %-20s : %s\n" "CTID"          "${CTID}"
printf " %-20s : %s\n" "Hostname"      "${CT_HOSTNAME}"
printf " %-20s : %s\n" "IP"            "${CT_IP}"
printf " %-20s : %s\n" "GLPI version"  "${GLPI_VERSION}"
printf " %-20s : %s\n" "Database name" "${GLPI_DB_NAME}"
printf " %-20s : %s\n" "Database user" "${GLPI_DB_USER}"
printf " %-20s : %s\n" "Web root"      "${GLPI_DIR}/public"
printf " %-20s : %s\n" "Apache2"       "enabled — listening on port 80 (LAN_ADMIN only)"
echo "============================================================"
echo " NEXT STEPS:"
echo "   1. Complete GLPI web installer:"
echo "      http://${CT_IP}/   (from LAN_ADMIN segment)"
echo "      DB host: localhost | DB: ${GLPI_DB_NAME} | User: ${GLPI_DB_USER}"
echo "   2. After the web installer completes, remove the install dir:"
echo "      pct exec ${CTID} -- rm -rf ${GLPI_DIR}/install"
echo "   3. Verify Nginx proxy (CT 101) reaches this backend:"
echo "      curl -s http://${CT_IP}/ | head -5"
echo "============================================================"
