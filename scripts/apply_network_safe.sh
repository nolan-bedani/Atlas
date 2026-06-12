#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════════════
# apply_network_safe.sh — Application du firewall/réseau Atlas avec
# ROLLBACK AUTOMATIQUE (dead-man's switch).
#
# Contexte : l'hyperviseur pve01 est une machine DISTANTE (Hetzner) sans accès
# physique. Une règle iptables erronée peut couper l'accès SSH. Ce script
# applique les nouvelles règles puis, si l'opérateur ne CONFIRME pas dans le
# délai imparti, restaure automatiquement les règles précédentes.
#
# Usage (à lancer EN ROOT SUR pve01, depuis la racine du dépôt) :
#   scripts/apply_network_safe.sh apply   [--timeout 120]
#   scripts/apply_network_safe.sh confirm     # garde les nouvelles règles
#   scripts/apply_network_safe.sh abort       # restaure immédiatement
#
# Procédure recommandée :
#   1. apply  → applique + programme le rollback
#   2. depuis une NOUVELLE session SSH, vérifier l'accès
#   3. confirm (si OK) | ne rien faire (si accès perdu → rollback auto)
# ══════════════════════════════════════════════════════════════════════
set -euo pipefail

TIMEOUT="${ATLAS_FW_TIMEOUT:-120}"
ROLLBACK_V4="/root/atlas-fw-rollback.v4"
ROLLBACK_MARK="/run/atlas-fw-rollback.job"
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"

usage() { echo "Usage: $0 {apply|confirm|abort} [--timeout SECONDES]" >&2; exit 1; }
log()   { echo "[$(date '+%H:%M:%S')] $*"; }

[ "$(id -u)" -eq 0 ] || { echo "Ce script doit être exécuté en root sur pve01." >&2; exit 1; }

cmd="${1:-}"; shift || true
while [ $# -gt 0 ]; do
  case "$1" in
    --timeout) TIMEOUT="${2:?}"; shift 2 ;;
    *) usage ;;
  esac
done

case "${cmd}" in
  apply)
    command -v at >/dev/null 2>&1 || { echo "Paquet 'at' requis : apt-get install -y at" >&2; exit 1; }

    log "Sauvegarde des règles iptables actuelles -> ${ROLLBACK_V4}"
    iptables-save > "${ROLLBACK_V4}"

    local_minutes=$(( (TIMEOUT + 59) / 60 ))
    log "Programmation du rollback automatique dans ~${local_minutes} min (filet de secours)"
    at_err="$(mktemp)"
    echo "iptables-restore < ${ROLLBACK_V4}; logger -t atlas-fw 'ROLLBACK firewall automatique (confirmation absente)'" \
      | at now + "${local_minutes}" minute 2>"${at_err}"
    grep -oE 'job [0-9]+' "${at_err}" | awk '{print $2}' > "${ROLLBACK_MARK}"
    rm -f "${at_err}"

    log "Application des nouvelles règles via Ansible (le handler valide par 'iptables-restore --test')"
    ansible-playbook "${REPO_DIR}/site.yaml" -i "${REPO_DIR}/develop/hosts.yaml" \
      --tags proxmox_network --limit proxmox_node

    cat <<MSG

  ✅ Nouvelles règles appliquées. ROLLBACK programmé (job $(cat "${ROLLBACK_MARK}" 2>/dev/null || echo '?')).
  ➜  Depuis une NOUVELLE session SSH, vérifie que tu as TOUJOURS accès, puis :
        $0 confirm        # annule le rollback, conserve les nouvelles règles
  ➜  Accès perdu ? Ne fais rien : les anciennes règles reviendront seules.
MSG
    ;;

  confirm)
    if [ ! -f "${ROLLBACK_MARK}" ]; then echo "Aucun rollback en attente."; exit 0; fi
    at -d "$(cat "${ROLLBACK_MARK}")" 2>/dev/null || true
    rm -f "${ROLLBACK_MARK}"
    mkdir -p /etc/iptables
    iptables-save > /etc/iptables/rules.v4
    log "Rollback annulé. Nouvelles règles conservées et persistées (/etc/iptables/rules.v4)."
    ;;

  abort)
    log "Restauration immédiate des règles précédentes."
    [ -f "${ROLLBACK_V4}" ] && iptables-restore < "${ROLLBACK_V4}"
    if [ -f "${ROLLBACK_MARK}" ]; then at -d "$(cat "${ROLLBACK_MARK}")" 2>/dev/null || true; rm -f "${ROLLBACK_MARK}"; fi
    log "Règles précédentes restaurées."
    ;;

  *) usage ;;
esac
