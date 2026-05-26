#!/usr/bin/env bash
# =============================================================================
# provision_nginx.sh
#
# Purpose  : Provision the Nginx reverse-proxy inside CT 101 (nginx-proxy).
#            Executed from the Proxmox VE host via the `pct` CLI.
#
#            Steps performed:
#              1. Install Nginx and OpenSSL inside the container.
#              2. Create the TLS certificate directory.
#              3. Generate a self-signed TLS certificate (dev/staging only).
#              4. Create symlinks so the static nginx.conf paths resolve.
#              5. Push the local nginx.conf into the container.
#              6. Validate the Nginx configuration (nginx -t).
#              7. Enable and start Nginx.
#
# Author   : <author-placeholder>
# Date     : <date-placeholder>
#
# Node     : Must be executed directly on the Proxmox VE host (or via SSH to
#            the host) because it uses the `pct` CLI, which is only available
#            on Proxmox nodes.
#
# Usage    : bash provision_nginx.sh
#
# Secrets policy: No private-key material is embedded in this script.
#   A self-signed certificate is generated *inside* the container at runtime.
#   The private key never leaves CT 101.
#
# PRODUCTION NOTE:
#   Replace the self-signed certificate with one issued by your internal PKI
#   or Let's Encrypt, then update the symlinks in /etc/nginx/certs/ to point
#   to the new material. Do NOT commit certificate files or private keys to VCS.
# =============================================================================
set -euo pipefail

# =============================================================================
# CONFIGURATION
# =============================================================================

# Proxmox container ID of the Nginx reverse-proxy (DMZ — VLAN 20)
CTID=101

# Hostname and IP of the container (informational; used in the summary).
CT_HOSTNAME="nginx-proxy"
CT_IP="10.20.0.101"

# Path to the nginx.conf that will be pushed into the container.
# Must live alongside this script in the same directory.
NGINX_CONF="$(dirname "$0")/nginx.conf"

# TLS material paths *inside* the container
TLS_KEY="/etc/ssl/private/nginx-selfsigned.key"
TLS_CERT="/etc/ssl/certs/nginx-selfsigned.crt"
CERTS_DIR="/etc/nginx/certs"
SYMLINK_KEY="${CERTS_DIR}/privkey.pem"
SYMLINK_CERT="${CERTS_DIR}/fullchain.pem"

# TLS certificate attributes — adjust O and C to match your organisation.
TLS_SUBJ="/CN=helpdesk.atlas.internal/O=Atlas/C=FR"
TLS_DAYS=365

# =============================================================================
# PREREQUISITE CHECKS
# =============================================================================

if ! command -v pct &>/dev/null; then
    echo "[ERROR] 'pct' not found in PATH." >&2
    echo "        This script must run on a Proxmox VE host." >&2
    exit 1
fi

if [[ ! -f "${NGINX_CONF}" ]]; then
    echo "[ERROR] nginx.conf not found at: ${NGINX_CONF}" >&2
    echo "        The file must exist alongside provision_nginx.sh." >&2
    exit 1
fi

# Verify the target container is running before we attempt any pct exec.
CT_STATUS="$(pct status "${CTID}" | awk '{print $2}')"
if [[ "${CT_STATUS}" != "running" ]]; then
    echo "[ERROR] CT ${CTID} is not running (status: ${CT_STATUS})." >&2
    echo "        Start it first: pct start ${CTID}" >&2
    exit 1
fi

# =============================================================================
# STEP 1 — Install Nginx and OpenSSL
# =============================================================================
echo "[INFO] Step 1/7 — Installing nginx and openssl inside CT ${CTID} ..."
pct exec "${CTID}" -- bash -c \
    "apt-get update -qq && apt-get install -y --no-install-recommends nginx openssl"
echo "[OK]   nginx and openssl installed."

# =============================================================================
# STEP 2 — Create the TLS certificate directory
# =============================================================================
echo "[INFO] Step 2/7 — Creating TLS certificate directory ${CERTS_DIR} ..."
pct exec "${CTID}" -- mkdir -p "${CERTS_DIR}"
echo "[OK]   ${CERTS_DIR} created."

# =============================================================================
# STEP 3 — Generate a self-signed TLS certificate
#
# PRODUCTION: replace self-signed certs with PKI/Let's Encrypt certs and
# update the symlinks created in Step 4.
# =============================================================================
echo "[INFO] Step 3/7 — Generating self-signed TLS certificate (${TLS_DAYS} days) ..."
pct exec "${CTID}" -- openssl req -x509 -nodes \
    -days    "${TLS_DAYS}"  \
    -newkey  rsa:4096       \
    -keyout  "${TLS_KEY}"   \
    -out     "${TLS_CERT}"  \
    -subj    "${TLS_SUBJ}"
# Restrict private key permissions: readable only by root.
pct exec "${CTID}" -- chmod 600 "${TLS_KEY}"
echo "[OK]   Self-signed certificate generated."
echo "       Key : ${TLS_KEY}"
echo "       Cert: ${TLS_CERT}"

# =============================================================================
# STEP 4 — Create symlinks so nginx.conf paths resolve without modification
#
# nginx.conf expects:
#   ssl_certificate     /etc/nginx/certs/fullchain.pem
#   ssl_certificate_key /etc/nginx/certs/privkey.pem
#
# PRODUCTION: replace self-signed certs with PKI/Let's Encrypt certs and
# update the symlinks below to point to the new material.
# =============================================================================
echo "[INFO] Step 4/7 — Creating symlinks in ${CERTS_DIR} ..."
pct exec "${CTID}" -- ln -sf "${TLS_KEY}"  "${SYMLINK_KEY}"
pct exec "${CTID}" -- ln -sf "${TLS_CERT}" "${SYMLINK_CERT}"
echo "[OK]   Symlinks created:"
echo "       ${SYMLINK_KEY}  -> ${TLS_KEY}"
echo "       ${SYMLINK_CERT} -> ${TLS_CERT}"

# =============================================================================
# STEP 5 — Push the local nginx.conf into the container
# =============================================================================
echo "[INFO] Step 5/7 — Pushing nginx.conf to CT ${CTID}:/etc/nginx/nginx.conf ..."
pct push "${CTID}" "${NGINX_CONF}" /etc/nginx/nginx.conf
echo "[OK]   nginx.conf deployed."

# =============================================================================
# STEP 6 — Validate the Nginx configuration
# =============================================================================
echo "[INFO] Step 6/7 — Validating Nginx configuration (nginx -t) ..."
pct exec "${CTID}" -- nginx -t
echo "[OK]   Nginx configuration is valid."

# =============================================================================
# STEP 7 — Enable and start Nginx
# =============================================================================
echo "[INFO] Step 7/7 — Enabling and starting Nginx ..."
pct exec "${CTID}" -- systemctl enable nginx
pct exec "${CTID}" -- systemctl restart nginx
echo "[OK]   Nginx is enabled and running."

# =============================================================================
# SUMMARY
# =============================================================================
echo ""
echo "============================================================"
echo " Projet Atlas — CT ${CTID} provisioned successfully"
echo "============================================================"
printf " %-20s : %s\n" "CTID"              "${CTID}"
printf " %-20s : %s\n" "Hostname"          "${CT_HOSTNAME}"
printf " %-20s : %s\n" "IP"                "${CT_IP}"
printf " %-20s : %s\n" "TLS key"           "${TLS_KEY}"
printf " %-20s : %s\n" "TLS cert"          "${TLS_CERT}"
printf " %-20s : %s\n" "privkey symlink"   "${SYMLINK_KEY}"
printf " %-20s : %s\n" "fullchain symlink" "${SYMLINK_CERT}"
printf " %-20s : %s\n" "nginx.conf"        "/etc/nginx/nginx.conf"
echo "============================================================"
echo " PRODUCTION REMINDER:"
echo "   Replace the self-signed certificate with your PKI or"
echo "   Let's Encrypt certificate, then update the symlinks:"
echo "     pct exec ${CTID} -- ln -sf /path/to/real.key  ${SYMLINK_KEY}"
echo "     pct exec ${CTID} -- ln -sf /path/to/real.crt  ${SYMLINK_CERT}"
echo "     pct exec ${CTID} -- systemctl reload nginx"
echo "============================================================"
