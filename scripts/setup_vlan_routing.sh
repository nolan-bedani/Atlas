#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════════════
# setup_vlan_routing.sh — Projet Atlas PRA/DR
# Préparation réseau de l'hôte Proxmox pve01 :
#   1. Activation du mode VLAN-aware sur le bridge vmbr0
#   2. Création des sous-interfaces VLAN (passerelles des sous-réseaux)
#   3. Activation du routage IP + règles iptables NAT/FORWARD persistantes
#
# Exécution : une seule fois sur pve01 (root). Le script est idempotent :
# il peut être relancé sans effet de bord.
#
# Usage : bash setup_vlan_routing.sh
# ══════════════════════════════════════════════════════════════════════
set -euo pipefail

# ─── Constantes ───
PHYS_IFACE="enp0s31f6"                          # NIC physique Hetzner
BRIDGE="vmbr0"                                  # Bridge Proxmox principal
INTERFACES_FILE="/etc/network/interfaces"
VLAN_CFG_FILE="/etc/network/interfaces.d/atlas-vlans.cfg"
IPTABLES_RULES="/etc/iptables/rules.v4"

# VLANs Atlas : "id:passerelle/cidr:sous-réseau"
VLANS=(
  "20:10.20.0.1/24:10.20.0.0/24"   # DMZ
  "30:10.30.0.1/24:10.30.0.0/24"   # LAN ADMIN
  "90:10.90.0.1/24:10.90.0.0/24"   # MGMT
)

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

log "Démarrage du setup réseau VLAN Atlas sur $(hostname)"

# ══════════════════════════════════════════════
# Étape 1 — Vérification de l'existence de vmbr0
# ══════════════════════════════════════════════
if ip link show "${BRIDGE}" > /dev/null 2>&1; then
  log "Bridge ${BRIDGE} présent."
else
  erreur "Le bridge ${BRIDGE} n'existe pas. Vérifier ${INTERFACES_FILE}."
fi

# ══════════════════════════════════════════════
# Étape 2 — Activation du mode VLAN-aware sur vmbr0
# ══════════════════════════════════════════════
RELOAD_NEEDED=0

if grep -qE '^\s*bridge-vlan-aware\s+yes' "${INTERFACES_FILE}"; then
  log "VLAN-aware déjà activé sur ${BRIDGE} (aucune modification)."
else
  log "Activation du VLAN-aware sur ${BRIDGE} dans ${INTERFACES_FILE}..."
  cp -a "${INTERFACES_FILE}" "${INTERFACES_FILE}.bak.$(date +%Y%m%d%H%M%S)"
  # Insertion juste après « iface vmbr0 inet ... » (espace final obligatoire
  # dans le motif pour NE PAS matcher la stanza « iface vmbr0 inet6 »)
  sed -i "/^iface ${BRIDGE} inet /a\\\tbridge-vlan-aware yes" "${INTERFACES_FILE}"
  RELOAD_NEEDED=1
  log "Directive 'bridge-vlan-aware yes' insérée."
fi

if grep -qE '^\s*bridge-vids\s+' "${INTERFACES_FILE}"; then
  log "Directive bridge-vids déjà présente (aucune modification)."
else
  log "Ajout de la plage de VLANs autorisés (bridge-vids 2-4094)..."
  sed -i "/^iface ${BRIDGE} inet /a\\\tbridge-vids 2-4094" "${INTERFACES_FILE}"
  RELOAD_NEEDED=1
fi

# S'assurer que le répertoire interfaces.d est bien sourcé
if grep -qE '^\s*source\s+/etc/network/interfaces\.d/' "${INTERFACES_FILE}"; then
  log "Le répertoire interfaces.d est déjà sourcé."
else
  log "Ajout de la directive 'source /etc/network/interfaces.d/*'..."
  echo "source /etc/network/interfaces.d/*" >> "${INTERFACES_FILE}"
  RELOAD_NEEDED=1
fi

# ══════════════════════════════════════════════
# Étape 3 — Création des sous-interfaces VLAN (passerelles)
# ══════════════════════════════════════════════
if [ -f "${VLAN_CFG_FILE}" ]; then
  log "Fichier ${VLAN_CFG_FILE} déjà présent — vérification du contenu."
fi

# Génération du fichier de configuration des sous-interfaces VLAN
TMP_CFG="$(mktemp)"
{
  echo "# ══════════════════════════════════════════════"
  echo "# Sous-interfaces VLAN Atlas — généré par setup_vlan_routing.sh"
  echo "# Ne pas modifier manuellement."
  echo "# ══════════════════════════════════════════════"
  for entry in "${VLANS[@]}"; do
    vid="${entry%%:*}"
    rest="${entry#*:}"
    gw_cidr="${rest%%:*}"
    echo ""
    echo "auto ${BRIDGE}.${vid}"
    echo "iface ${BRIDGE}.${vid} inet static"
    echo "	address ${gw_cidr}"
  done
} > "${TMP_CFG}"

if [ -f "${VLAN_CFG_FILE}" ] && cmp -s "${TMP_CFG}" "${VLAN_CFG_FILE}"; then
  log "Sous-interfaces VLAN déjà configurées (aucune modification)."
  rm -f "${TMP_CFG}"
else
  install -m 0644 "${TMP_CFG}" "${VLAN_CFG_FILE}"
  rm -f "${TMP_CFG}"
  RELOAD_NEEDED=1
  log "Fichier ${VLAN_CFG_FILE} déployé (VLANs 20/30/90)."
fi

# Application sans reboot via ifupdown2
if [ "${RELOAD_NEEDED}" -eq 1 ]; then
  log "Application de la configuration réseau (ifreload -a)..."
  ifreload -a
  log "Configuration réseau rechargée."
else
  log "Aucun rechargement réseau nécessaire."
fi

# ══════════════════════════════════════════════
# Étape 4 — Activation du routage IP (ip_forward)
# ══════════════════════════════════════════════
if [ "$(sysctl -n net.ipv4.ip_forward)" = "1" ]; then
  log "ip_forward déjà actif."
else
  log "Activation de net.ipv4.ip_forward..."
  sysctl -w net.ipv4.ip_forward=1 > /dev/null
fi

# Persistance du ip_forward au reboot
SYSCTL_ATLAS="/etc/sysctl.d/99-atlas-routing.conf"
if [ -f "${SYSCTL_ATLAS}" ] && grep -q 'net.ipv4.ip_forward=1' "${SYSCTL_ATLAS}"; then
  log "Persistance ip_forward déjà en place (${SYSCTL_ATLAS})."
else
  echo "net.ipv4.ip_forward=1" > "${SYSCTL_ATLAS}"
  log "Persistance ip_forward écrite dans ${SYSCTL_ATLAS}."
fi

# ══════════════════════════════════════════════
# Étape 5 — Règles iptables NAT (MASQUERADE) + FORWARD
# ══════════════════════════════════════════════
# ajoute_regle <table> <chaîne> <args...> : ajoute la règle si absente
ajoute_regle() {
  local table="$1" chain="$2"
  shift 2
  if iptables -t "${table}" -C "${chain}" "$@" 2> /dev/null; then
    log "Règle déjà présente : -t ${table} -A ${chain} $*"
  else
    iptables -t "${table}" -A "${chain}" "$@"
    log "Règle ajoutée : -t ${table} -A ${chain} $*"
  fi
}

# ─── Trafic retour (connexions établies) autorisé globalement ───
ajoute_regle filter FORWARD -m state --state RELATED,ESTABLISHED -j ACCEPT

for entry in "${VLANS[@]}"; do
  vid="${entry%%:*}"
  subnet="${entry##*:}"

  # ─── NAT sortant vers Internet ───
  ajoute_regle nat POSTROUTING -s "${subnet}" -o "${PHYS_IFACE}" -j MASQUERADE

  # ─── Trafic sortant VLAN → Internet ───
  ajoute_regle filter FORWARD -s "${subnet}" -o "${PHYS_IFACE}" -j ACCEPT

  # ─── Trafic retour Internet → VLAN (connexions établies) ───
  ajoute_regle filter FORWARD -d "${subnet}" -i "${PHYS_IFACE}" \
    -m state --state RELATED,ESTABLISHED -j ACCEPT
done

# ─── Routage inter-VLAN : matrice de flux explicite (moindre privilège) ───
# ⚠️  Source de vérité = rôle Ansible proxmox_network (templates/rules.v4.j2).
# Garder cette matrice ALIGNÉE sur proxmox_network_interzone_rules.
# Format : "src_subnet:dst:proto:port:commentaire"
INTERZONE=(
  "10.20.0.0/24:10.30.0.10:tcp:3306:DMZ -> MariaDB (GLPI)"
  "10.20.0.0/24:10.30.0.11:tcp:25:DMZ -> relais SMTP"
  "10.20.0.0/24:10.30.0.12:tcp:10051:Agents DMZ -> Zabbix (checks actifs)"
  "10.30.0.12:10.20.0.0/24:tcp:10050:Zabbix -> agents DMZ (checks passifs)"
  "10.90.0.0/24:10.20.0.0/24:tcp:22:MGMT -> DMZ SSH"
  "10.90.0.0/24:10.30.0.0/24:tcp:22:MGMT -> LAN ADMIN SSH"
)
for rule in "${INTERZONE[@]}"; do
  IFS=':' read -r r_src r_dst r_proto r_port _ <<< "${rule}"
  ajoute_regle filter FORWARD -s "${r_src}" -d "${r_dst}" -p "${r_proto}" --dport "${r_port}" -j ACCEPT
done

# ─── Politique par défaut : transit refusé (segmentation réelle des VLAN) ───
# INPUT reste ACCEPT pour ne pas verrouiller l'accès SSH à l'hyperviseur distant.
if [ "$(iptables -nL FORWARD | head -1)" != "Chain FORWARD (policy DROP)" ]; then
  iptables -P FORWARD DROP
  log "Politique FORWARD par défaut : DROP (transit inter-VLAN non autorisé refusé)."
else
  log "Politique FORWARD déjà en DROP."
fi

# ══════════════════════════════════════════════
# Étape 6 — Persistance des règles iptables
# ══════════════════════════════════════════════
if dpkg -s iptables-persistent > /dev/null 2>&1; then
  log "Paquet iptables-persistent déjà installé."
else
  log "Installation de iptables-persistent..."
  # Pré-réponses debconf pour éviter les prompts interactifs
  echo "iptables-persistent iptables-persistent/autosave_v4 boolean false" | debconf-set-selections || true
  echo "iptables-persistent iptables-persistent/autosave_v6 boolean false" | debconf-set-selections || true
  DEBIAN_FRONTEND=noninteractive apt-get install -y iptables-persistent
fi

# ⚠️  iptables-save capture l'ÉTAT VIVANT COMPLET (règles temporaires, PVE firewall,
# doublons d'anciens runs). Si le rôle Ansible proxmox_network gère déjà rules.v4
# (templates/rules.v4.j2, source de vérité), ce dump brut le fait DÉRIVER de manière
# non déterministe selon l'ordre script/rôle. Ne persister ici qu'en mode autonome
# (hôte non géré par Ansible) : PERSIST_IPTABLES=0 désactive l'écrasement.
PERSIST_IPTABLES="${PERSIST_IPTABLES:-1}"
if [ "${PERSIST_IPTABLES}" -eq 1 ]; then
  mkdir -p /etc/iptables
  iptables-save > "${IPTABLES_RULES}"
  log "Règles iptables sauvegardées dans ${IPTABLES_RULES} (état vivant)."
else
  log "Persistance iptables ignorée (PERSIST_IPTABLES=0) — ${IPTABLES_RULES} géré par Ansible (rules.v4.j2)."
fi

# ══════════════════════════════════════════════
# Étape 7 — Résumé final
# ══════════════════════════════════════════════
echo ""
echo "═══════════════════════════════════════════════════════"
echo " ✅ Setup réseau VLAN Atlas terminé sur $(hostname)"
echo "═══════════════════════════════════════════════════════"
echo " Bridge VLAN-aware : ${BRIDGE}"
echo " NIC physique      : ${PHYS_IFACE} (NAT MASQUERADE)"
echo " Passerelles créées :"
for entry in "${VLANS[@]}"; do
  vid="${entry%%:*}"
  rest="${entry#*:}"
  gw_cidr="${rest%%:*}"
  subnet="${entry##*:}"
  echo "   - ${BRIDGE}.${vid} → ${gw_cidr} (sous-réseau ${subnet})"
done
echo " Persistance       : ${IPTABLES_RULES} + ${SYSCTL_ATLAS}"
echo "═══════════════════════════════════════════════════════"
