#!/usr/bin/env bash
# =============================================================================
# deploy_lxc.sh
#
# Purpose  : Provision three unprivileged LXC containers on a Proxmox VE node
#            for Projet Atlas (GLPI-like helpdesk portal):
#              CT 101  nginx-proxy   — DMZ (VLAN 20)
#              CT 102  glpi-mariadb  — LAN_ADMIN (VLAN 30)
#              CT 103  zabbix-server — LAN_ADMIN (VLAN 30)
#
# Author   : <author-placeholder>
# Date     : <date-placeholder>
#
# Node     : Must be executed directly on the Proxmox VE node (or via SSH to
#            the node) because it calls the `pct` CLI which is only available
#            on Proxmox hosts.
#
# Usage    : bash deploy_lxc.sh
#
# IMPORTANT — Before running this script, download the Debian 12 template:
#   pveam update && pveam download local debian-12-standard_12.7-1_amd64.tar.zst
#
# Secrets policy: No passwords are embedded in this script. Root password login
# is disabled; access is granted exclusively via the injected SSH public key.
# The key pair must be generated separately (once, on the operator workstation):
#   ssh-keygen -t ed25519 -f ~/.ssh/atlas_id_ed25519
# =============================================================================
set -euo pipefail

# =============================================================================
# CONFIGURATION — adjust these variables before running; do NOT scatter values
# throughout the script body.
# =============================================================================

# Proxmox storage pool used for container root filesystems
STORAGE="local-lvm"

# OS template path on the Proxmox node (must be downloaded first — see header)
TEMPLATE="local:vztmpl/debian-12-standard_12.7-1_amd64.tar.zst"

# vCPU count allocated to every container
CORES=2

# RAM in MB allocated to every container
MEMORY=1024

# Root disk size for every container
DISK="8G"

# Path to the SSH public key to inject into each container.
# Generate the key pair once with:
#   ssh-keygen -t ed25519 -f ~/.ssh/atlas_id_ed25519
SSH_PUBKEY_PATH="${HOME}/.ssh/atlas_id_ed25519.pub"

# DNS resolver — LAN_ADMIN gateway doubles as the internal DNS forwarder
NAMESERVER="10.30.0.1"

# Internal search domain
SEARCHDOMAIN="atlas.internal"

# =============================================================================
# PREREQUISITE CHECKS — fail early with a descriptive error rather than a
# cryptic mid-script failure.
# =============================================================================

if ! command -v pct &>/dev/null; then
    echo "[ERROR] 'pct' not found in PATH." >&2
    echo "        This script must run on a Proxmox VE node." >&2
    exit 1
fi

if [[ ! -f "${SSH_PUBKEY_PATH}" ]]; then
    echo "[ERROR] SSH public key not found: ${SSH_PUBKEY_PATH}" >&2
    echo "        Generate it with: ssh-keygen -t ed25519 -f ~/.ssh/atlas_id_ed25519" >&2
    exit 1
fi

# =============================================================================
# FUNCTION: create_ct
#
# Arguments:
#   $1  ctid      — Proxmox container ID (e.g. 101)
#   $2  hostname  — container hostname (e.g. nginx-proxy)
#   $3  vlan      — 802.1Q VLAN tag (e.g. 20)
#   $4  ip        — static IP with prefix length (e.g. 10.20.0.101/24)
#   $5  gw        — default gateway for the container (e.g. 10.20.0.1)
# =============================================================================
create_ct() {
    local ctid="$1"
    local hostname="$2"
    local vlan="$3"
    local ip="$4"
    local gw="$5"

    echo "[INFO] Creating CT ${ctid} (${hostname}) on VLAN ${vlan} with IP ${ip} ..."

    pct create "${ctid}" "${TEMPLATE}" \
        --storage        "${STORAGE}" \
        --rootfs         "${STORAGE}:${DISK}" \
        --cores          "${CORES}" \
        --memory         "${MEMORY}" \
        --net0           "name=eth0,bridge=vmbr0,tag=${vlan},ip=${ip},gw=${gw},firewall=1" \
        --hostname       "${hostname}" \
        --unprivileged   1 \
        `# --unprivileged 1: the container UID/GID namespace is shifted so that` \
        `# UID 0 inside the container maps to an unprivileged host UID.`        \
        `# This limits blast radius if a process escapes the container.`        \
        --features       "nesting=0" \
        `# nesting=0: Docker-in-LXC is not required; disabling nesting reduces` \
        `# the kernel attack surface.`                                          \
        --ssh-public-keys "${SSH_PUBKEY_PATH}" \
        --password       "" \
        `# --password "": root password is explicitly disabled.`               \
        `# SSH key (injected above) is the ONLY authentication method.`        \
        --nameserver     "${NAMESERVER}" \
        --searchdomain   "${SEARCHDOMAIN}" \
        --start          0
        # --start 0: containers are NOT auto-started after creation.
        # The operator must verify the config, then start each one manually:
        #   pct start <CTID>

    # Post-create hardening: enable deletion protection to prevent accidental
    # removal via the Proxmox web UI or a typo in a pct destroy command.
    pct set "${ctid}" --protection 1

    echo "[OK]   CT ${ctid} (${hostname}) created and hardened."
    echo "       Reminder: start manually with: pct start ${ctid}"
    echo ""
}

# =============================================================================
# CONTAINER PROVISIONING
# =============================================================================
#
#          CTID  hostname        VLAN  IP                GW
# -------  ----  --------------  ----  ----------------  ----------
create_ct  101   "nginx-proxy"    20   "10.20.0.101/24"  "10.20.0.1"   # DMZ
create_ct  102   "glpi-mariadb"   30   "10.30.0.102/24"  "10.30.0.1"   # LAN_ADMIN
create_ct  103   "zabbix-server"  30   "10.30.0.103/24"  "10.30.0.1"   # LAN_ADMIN

# =============================================================================
# SUMMARY
# =============================================================================
echo "============================================================"
echo " Projet Atlas — LXC containers provisioned successfully"
echo "============================================================"
printf " %-6s  %-16s  %-6s  %-18s\n" "CTID" "HOSTNAME" "VLAN" "IP"
printf " %-6s  %-16s  %-6s  %-18s\n" "------" "----------------" "------" "------------------"
printf " %-6s  %-16s  %-6s  %-18s\n" "101"   "nginx-proxy"    "20"   "10.20.0.101/24"
printf " %-6s  %-16s  %-6s  %-18s\n" "102"   "glpi-mariadb"   "30"   "10.30.0.102/24"
printf " %-6s  %-16s  %-6s  %-18s\n" "103"   "zabbix-server"  "30"   "10.30.0.103/24"
echo "============================================================"
echo " All containers are stopped. Start each one after verification:"
echo "   pct start 101 && pct start 102 && pct start 103"
echo "============================================================"
