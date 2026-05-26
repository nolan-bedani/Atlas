# Runbook — dump_mariadb.sh

**Projet :** Atlas — Portail Helpdesk GLPI  
**Composant :** Sauvegarde MariaDB/MySQL  
**RPO cible :** ≤ 20 min | **RTO cible :** ≤ 40 min  
**Dernière mise à jour :** 2026-05-26

---

## Objectif

Effectuer un dump compressé de la base de données GLPI toutes les 15 minutes, journaliser le résultat pour Zabbix, et appliquer une rotation automatique des fichiers de sauvegarde.

---

## Prérequis

### Fichier de secrets `/.env`

Le script source `/.env` à la racine du système. Ce fichier doit contenir :

```dotenv
DB_USER=glpi_backup_db      # Compte MariaDB dédié, lecture seule sur DB_NAME
DB_PASSWORD=<mot_de_passe>  # Ne jamais committer ce fichier
DB_NAME=glpi
```

Permissions recommandées :

```bash
chmod 600 /.env
chown glpi_backup:glpi_backup /.env
```

### Compte OS dédié

Le script doit être exécuté par l'utilisateur `glpi_backup` (moindre privilège).

```bash
useradd -r -s /sbin/nologin glpi_backup
```

### Dépendances

- `mysqldump` (paquet `mariadb-client` ou `mysql-client`)
- `gzip`
- `find`

---

## Exécution manuelle

```bash
sudo -u glpi_backup /scripts_pra/backup/dump_mariadb.sh
```

---

## Configuration crontab

Ajouter l'entrée suivante dans `/etc/cron.d/glpi-backup` :

```cron
*/15 * * * * glpi_backup /scripts_pra/backup/dump_mariadb.sh
```

---

## Emplacement des sauvegardes et du journal

| Ressource | Chemin |
|---|---|
| Fichiers de sauvegarde | `/var/backups/glpi/glpi_backup_YYYYMMDD_HHMMSS.sql.gz` |
| Journal de backup | `/var/log/glpi/backup.log` |

Format du journal (consommé par Zabbix) :

```
[2026-05-26 14:15:01] SUCCESS — glpi_backup_20260526_141501.sql.gz
[2026-05-26 14:30:01] FAIL — Erreur code 1 à la ligne 52 lors de la sauvegarde de glpi
```

---

## Politique de rétention

Les fichiers `.sql.gz` de plus de **48 heures** sont supprimés automatiquement à chaque exécution via `find -mtime +2 -delete`.
