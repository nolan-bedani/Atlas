#!/usr/bin/env bash
# ==============================================================================
# dump_mariadb.sh — Sauvegarde MariaDB/MySQL pour GLPI (Projet Atlas)
# Auteur   : glpi_backup (compte OS dédié, moindre privilège)
# RPO cible: <= 20 minutes — planifier toutes les 15 minutes via cron.
#
# Crontab recommandée — déposer dans /etc/cron.d/glpi-backup (exécution sous
# le compte de moindre privilège 'glpi_backup', PAS root) :
# */15 * * * * glpi_backup /scripts_pra/backup/dump_mariadb.sh
#
# IMPORTANT : Ce script DOIT être exécuté par l'utilisateur OS 'glpi_backup'
#             (accès lecture seule à la base via /.env). Jamais en root.
# ==============================================================================
set -euo pipefail

# ------------------------------------------------------------------------------
# 1. Chargement des secrets depuis /.env (jamais de secrets en dur)
# ------------------------------------------------------------------------------
ENV_FILE="/.env"
if [[ ! -f "${ENV_FILE}" ]]; then
    echo "ERREUR : Fichier de secrets '${ENV_FILE}' introuvable." >&2
    exit 1
fi
# shellcheck source=/.env
. "${ENV_FILE}"

# Vérification que les variables requises sont définies et non vides
: "${DB_USER:?ERREUR : DB_USER est absent ou vide dans ${ENV_FILE}}"
: "${DB_PASSWORD:?ERREUR : DB_PASSWORD est absent ou vide dans ${ENV_FILE}}"
: "${DB_NAME:?ERREUR : DB_NAME est absent ou vide dans ${ENV_FILE}}"

# ------------------------------------------------------------------------------
# 2. Variables de chemins et timestamp
# ------------------------------------------------------------------------------
BACKUP_DIR="/var/backups/glpi"
LOG_DIR="/var/log/glpi"
LOG_FILE="${LOG_DIR}/backup.log"
TIMESTAMP="$(date '+%Y%m%d_%H%M%S')"
DATE_FMT="$(date '+%Y-%m-%d %H:%M:%S')"
BACKUP_FILE="${BACKUP_DIR}/glpi_backup_${TIMESTAMP}.sql.gz"
RETENTION_HOURS=48

# Fichier d'identifiants temporaire (0600) : évite de passer le mot de passe en
# argument de mysqldump (visible par tout utilisateur via 'ps'). Nettoyé à la sortie.
DB_CNF="$(mktemp)"
chmod 600 "${DB_CNF}"
cat > "${DB_CNF}" <<EOF
[client]
user=${DB_USER}
password=${DB_PASSWORD}
EOF
trap 'rm -f "${DB_CNF}"' EXIT

# ------------------------------------------------------------------------------
# 3. Création des répertoires si absents
# ------------------------------------------------------------------------------
mkdir -p "${BACKUP_DIR}"
mkdir -p "${LOG_DIR}"

# ------------------------------------------------------------------------------
# 4. Trap : journaliser les échecs et sortir proprement
# ------------------------------------------------------------------------------
_on_error() {
    local exit_code="${?}"
    local line_no="${BASH_LINENO[0]:-?}"
    echo "[${DATE_FMT}] FAIL — Erreur code ${exit_code} à la ligne ${line_no} lors de la sauvegarde de ${DB_NAME}" \
        >> "${LOG_FILE}"
    exit "${exit_code}"
}
trap '_on_error' ERR

# ------------------------------------------------------------------------------
# 5. Dump MariaDB/MySQL compressé
# ------------------------------------------------------------------------------
mysqldump \
    --defaults-extra-file="${DB_CNF}" \
    --single-transaction \
    --quick \
    --lock-tables=false \
    "${DB_NAME}" \
    | gzip -9 > "${BACKUP_FILE}"

# ------------------------------------------------------------------------------
# 6. Rotation : suppression des fichiers de plus de 48 heures
# ------------------------------------------------------------------------------
# -mmin (minutes) et non -mtime (jours) : -mtime +2 supprimait au-delà de 3 jours,
# pas 48 h. On exprime la rétention exacte en minutes.
find "${BACKUP_DIR}" -maxdepth 1 -name "*.sql.gz" -mmin "+$((RETENTION_HOURS * 60))" -delete

# ------------------------------------------------------------------------------
# 7. Journalisation du succès (consommé par Zabbix)
# ------------------------------------------------------------------------------
BACKUP_BASENAME="$(basename "${BACKUP_FILE}")"
echo "[${DATE_FMT}] SUCCESS — ${BACKUP_BASENAME}" >> "${LOG_FILE}"
