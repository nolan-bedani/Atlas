#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════════════
# reset_proxmox_atlas.sh — Projet Atlas PRA/DR
# Remise à zéro SÉLECTIVE des conteneurs LXC tagués « atlas » sur pve01.
# Les autres conteneurs/VM de l'hôte ne sont JAMAIS touchés.
#
# Étapes :
#   1. Détection des LXC dont le tag contient « atlas » (via pvesh + jq)
#   2. Affichage de la liste et demande de confirmation explicite
#   3. Arrêt (pct stop) puis destruction (pct destroy --purge) de chaque LXC
#
# Usage : bash reset_proxmox_atlas.sh
# ══════════════════════════════════════════════════════════════════════
set -euo pipefail

# ─── Constantes ───
TAG_FILTRE="atlas"
# Nom du nœud Proxmox (surchageable : PROXMOX_NODE=pve bash reset_proxmox_atlas.sh)
NODE="${PROXMOX_NODE:-$(hostname -s)}"

# ─── Fonctions utilitaires ───
log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

erreur() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERREUR : $*" >&2
  exit 1
}

# ─── Pré-requis ───
[ "$(id -u)" -eq 0 ] || erreur "Ce script doit être exécuté en root."
command -v pvesh > /dev/null 2>&1 || erreur "pvesh introuvable — ce script doit tourner sur l'hôte Proxmox."

# jq est requis pour parser la sortie JSON de pvesh
if command -v jq > /dev/null 2>&1; then
  log "jq présent."
else
  log "jq absent — installation..."
  # apt-get update préalable : un cache APT vide/périmé ferait échouer l'install (404).
  DEBIAN_FRONTEND=noninteractive apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y jq
fi

# ══════════════════════════════════════════════
# Étape 1 — Détection des LXC tagués « atlas »
# ══════════════════════════════════════════════
log "Recherche des conteneurs LXC tagués « ${TAG_FILTRE} » sur le nœud ${NODE}..."

LXC_JSON="$(pvesh get "/nodes/${NODE}/lxc" --output-format json)"

# Filtrage : champ « tags » contenant le tag atlas (tags séparés par « ; »)
ATLAS_VMIDS="$(echo "${LXC_JSON}" | jq -r \
  --arg tag "${TAG_FILTRE}" \
  '.[] | select((.tags // "") | split(";") | index($tag)) | .vmid' | sort -n)"

if [ -z "${ATLAS_VMIDS}" ]; then
  log "Aucun conteneur tagué « ${TAG_FILTRE} » trouvé. Rien à faire."
  exit 0
fi

NB_TOTAL="$(echo "${ATLAS_VMIDS}" | wc -l)"

# ══════════════════════════════════════════════
# Étape 2 — Affichage et confirmation
# ══════════════════════════════════════════════
echo ""
echo "═══════════════════════════════════════════════════════"
echo " ⚠️  Conteneurs Atlas qui seront DÉFINITIVEMENT supprimés"
echo "═══════════════════════════════════════════════════════"
for vmid in ${ATLAS_VMIDS}; do
  hostname_lxc="$(echo "${LXC_JSON}" | jq -r --argjson id "${vmid}" \
    '.[] | select(.vmid == $id) | .name // "inconnu"')"
  statut="$(echo "${LXC_JSON}" | jq -r --argjson id "${vmid}" \
    '.[] | select(.vmid == $id) | .status // "inconnu"')"
  echo "   - VMID ${vmid} : ${hostname_lxc} (état : ${statut})"
done
echo "═══════════════════════════════════════════════════════"
echo ""

read -p "Confirmer la suppression de ${NB_TOTAL} conteneurs ? [oui/NON] " REPONSE
if [ "${REPONSE}" != "oui" ]; then
  log "Suppression annulée par l'utilisateur (réponse : « ${REPONSE:-vide} »)."
  exit 0
fi

# ══════════════════════════════════════════════
# Étape 3 — Arrêt et destruction des conteneurs
# ══════════════════════════════════════════════
COMPTEUR=0
NB_ECHECS=0
for vmid in ${ATLAS_VMIDS}; do
  log "Arrêt du conteneur ${vmid}..."
  pct stop "${vmid}" --timeout 10 || true   # déjà arrêté = échec légitime

  # Lever la protection éventuelle (deploy_lxc.sh pose --protection 1),
  # sinon pct destroy échoue systématiquement. La confirmation a déjà été donnée.
  pct set "${vmid}" --protection 0 || true

  log "Destruction du conteneur ${vmid} (--purge)..."
  if pct destroy "${vmid}" --purge; then
    COMPTEUR=$((COMPTEUR + 1))
    log "Conteneur ${vmid} supprimé."
  else
    NB_ECHECS=$((NB_ECHECS + 1))
    log "ATTENTION : échec de la destruction du conteneur ${vmid} — passage au suivant."
  fi
done

# ══════════════════════════════════════════════
# Étape 4 — Résumé final
# ══════════════════════════════════════════════
echo ""
echo "═══════════════════════════════════════════════════════"
echo " ✅ Reset Atlas terminé : ${COMPTEUR}/${NB_TOTAL} conteneurs supprimés"
echo "═══════════════════════════════════════════════════════"
log "${COMPTEUR} conteneurs supprimés."

# Échec global si au moins une destruction a échoué (reset incomplet en exercice PRA).
if [ "${NB_ECHECS}" -gt 0 ]; then
  erreur "${NB_ECHECS} conteneur(s) non supprimé(s) — reset incomplet."
fi
