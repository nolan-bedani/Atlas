# Runbooks PRA/DR — Projet Atlas

> Plan de Reprise d'Activité du helpdesk GLPI déployé sur Proxmox/LXC.
> **Objectifs contractuels : RPO ≤ 20 min — RTO ≤ 40 min.**

---

## 1. Architecture concernée

| Zone | VLAN | Hôtes | Rôle |
|------|------|-------|------|
| DMZ | 20 — `10.20.0.0/24` | `atlrp01p` (10.20.0.10) reverse proxy, `atlapp01p` (10.20.0.11) GLPI, `atltst01p` (10.20.0.20) testlab | Front web exposé |
| LAN ADMIN | 30 — `10.30.0.0/24` | `atldb01p` (.10) MariaDB, `atlsmtp01p` (.11), `atlzbx01p` (.12) Zabbix, `atlbkp01p` (.13) backup, `atlgrf01p` (.14) Grafana | Données & supervision |
| MGMT | 90 — `10.90.0.0/24` | `atlbst01p` (10.90.0.10) bastion | Administration |

Hyperviseur : Proxmox `pve01` (control node Ansible). Segmentation assurée par `roles/proxmox_network` (politique `FORWARD DROP` + matrice de flux).

---

## 2. Chaîne de sauvegarde (ce qui garantit le RPO)

| Élément | Fréquence | Emplacement | Géré par |
|---------|-----------|-------------|----------|
| Dump SQL GLPI (`--single-transaction`) | toutes les 15 min (`5,20,35,50`) + dump quotidien 02h00 | `atldb01p:/var/backups/atlas/db` | `roles/mariadb` (`backup_script.yaml`) |
| Binlogs MariaDB (PITR, format ROW) | continus, expédiés toutes les 15 min | `atldb01p:/var/log/mysql/mysql-bin.*` → `atlbkp01p` | `roles/backup` (`collect_dumps.sh`) |
| Copie hors site dumps + binlogs | toutes les 15 min | `atlbkp01p:{{ backup_db_remote_dest }}` (+ `/binlogs`) | `roles/backup` (cron) |
| Filestore GLPI (pièces jointes) | quotidien 03h00 | `atlbkp01p:/var/backups/atlas/filestore` | `roles/backup` (`backup_filestore.sh`) |

**RPO effectif** = âge du dernier dump (≤ 15 min) affiné par rejeu des binlogs jusqu'à l'instant de l'incident → conforme à l'objectif ≤ 20 min.

> ⚠️ Pré-requis RPO : le compte `atlsvc` doit avoir un accès **lecture** sur `/var/log/mysql/mysql-bin.*` (binlogs) sur `atldb01p`.

---

## 3. Runbook A — Restauration complète (perte d'un ou plusieurs LXC)

**Quand :** perte d'un conteneur, corruption disque, perte de l'hyperviseur (après réinstallation Proxmox).
**Playbook :** `pra_restore_full.yaml` — recrée les LXC, redéploie tous les rôles dans l'ordre de dépendance, restaure base + filestore, mesure le RTO.

### Pré-requis
1. Hyperviseur Proxmox opérationnel, control node prêt (`ansible.cfg`, vault déchiffrable via `.vault_pass`).
2. `passlib` installé sur le control node (`pip3 install passlib`) — requis pour les hash de mots de passe.
3. Sauvegardes présentes sur `atlbkp01p` (`/var/backups/atlas/db-remote/`, `/filestore/`).
4. Clé `atlas_ed25519` disponible sur le control node.

### Procédure
```bash
cd /root/atlas            # racine du dépôt sur pve01
# 1. Dry-run de contrôle (n'applique rien)
ansible-playbook pra_restore_full.yaml -i develop/hosts.yaml --check --diff

# 2. Restauration réelle (dernier dump collecté par défaut)
ansible-playbook pra_restore_full.yaml -i develop/hosts.yaml

# Variante : restaurer un dump précis
ansible-playbook pra_restore_full.yaml -i develop/hosts.yaml \
  -e "pra_restore_dump=/var/backups/atlas/db-remote/glpi_dump_AAAAMMJJ_HHMMSS.sql.gz"
```

### Vérifications post-restauration (automatiques dans le playbook)
- GLPI répond en HTTP (`atlapp01p`) — 5 tentatives espacées de 10 s.
- Comptage des tickets restaurés sur `atldb01p`.
- Port Zabbix `10051` ouvert sur `atlzbx01p`.
- **RTO mesuré** journalisé dans `/var/log/atlas/pra_restore_full.log` (cible 40 min).

### Vérifications manuelles complémentaires
- [ ] Connexion à l'interface **via le reverse proxy en HTTPS** (`https://<vip-dmz>/`), pas seulement en HTTP direct.
- [ ] Authentification avec le compte super-admin sécurisé (`atlasadmin`, mot de passe du vault) — le couple `glpi/glpi` ne doit plus exister.
- [ ] Cohérence du dernier ticket vs l'incident (rejeu binlog si nécessaire).

---

## 4. Runbook B — Restauration granulaire (tickets supprimés par erreur)

**Quand :** suppression/corruption logique d'un sous-ensemble de tickets, sans perte d'infrastructure.
**Playbook :** `pra_restore_granular.yaml` — restaure un dump dans une base temporaire `glpi_restore_tmp`, ré-injecte **uniquement les tickets manquants** (`INSERT IGNORE`) sans écraser les tickets créés après l'incident. La production n'est jamais restaurée en bloc.

### Procédure
```bash
cd /root/atlas
ansible-playbook pra_restore_granular.yaml -i develop/hosts.yaml \
  -e "pra_target_dump=/var/backups/atlas/db/glpi_dump_AAAAMMJJ_HHMMSS.sql.gz"
```

### Points de contrôle
- [ ] Le dump cible est antérieur à la suppression et postérieur au dernier état sain voulu.
- [ ] Après fusion : vérifier le nombre de tickets (`SELECT COUNT(*) FROM glpi_db.glpi_tickets;`) et l'intégrité d'un échantillon.
- [ ] Le RPO effectif (âge du dump) est journalisé dans `/var/log/atlas/pra_restore_granular.log`.
- [ ] La base temporaire `glpi_restore_tmp` et l'export `/tmp/tickets_restore.sql` sont bien supprimés.

---

## 5. Restauration point-in-time (PITR via binlogs)

Pour revenir à un instant **précis** entre deux dumps :
1. Restaurer le dump complet le plus récent **antérieur** à l'instant cible (Runbook A).
2. Rejouer les binlogs collectés jusqu'à l'horodatage voulu :
   ```bash
   mysqlbinlog --stop-datetime="AAAA-MM-JJ HH:MM:SS" \
     /var/backups/atlas/db-remote/binlogs/mysql-bin.* | mysql glpi_db
   ```
3. Vérifier la cohérence applicative.

---

## 6. Tests de restauration (obligatoire — sinon le PRA est théorique)

| Test | Fréquence | Critère de succès |
|------|-----------|-------------------|
| Restauration granulaire sur base de test | mensuel | tickets ré-injectés, RTO < 10 min |
| Restauration complète sur LXC jetable | trimestriel | GLPI fonctionnel en HTTPS, **RTO mesuré < 40 min**, RPO < 20 min |
| Vérification fraîcheur binlogs hors site | hebdomadaire (alerte Zabbix) | dernier binlog < 20 min |

Consigner chaque test (date, RTO/RPO mesurés, anomalies) en annexe de ce runbook.

---

## 7. Sauvegarde hors site des secrets du control node (RTO)

`pve01` est à la fois le control node Ansible **et** un hôte susceptible d'être perdu.
Deux fichiers le rendent irremplaçable et **ne doivent pas exister uniquement sur pve01** :

| Fichier | Rôle | Sans lui |
|---------|------|----------|
| `<dépôt>/.vault_pass` | déchiffre le vault Ansible | aucun secret déchiffrable → aucun déploiement |
| `/root/.ssh/atlas_ed25519` (+ `.pub`) | clé de déploiement vers les LXC (via bastion) | impossible d'atteindre les conteneurs |

### Mise à l'abri (dès maintenant, puis à chaque rotation de secret)
```bash
# Sur pve01 — archive chiffrée des secrets du control node
umask 077
tar czf - .vault_pass /root/.ssh/atlas_ed25519 /root/.ssh/atlas_ed25519.pub \
  | gpg --symmetric --cipher-algo AES256 -o /tmp/atlas-control-secrets.tar.gz.gpg
# Transférer vers le coffre hors site (gestionnaire de secrets / support chiffré
# conservé hors datacenter), puis effacer la copie locale :
shred -u /tmp/atlas-control-secrets.tar.gz.gpg
```
Ces fichiers sont déjà couverts par `.gitignore` : ne **jamais** les committer.

### Reprise sur un control node de secours (si pve01 est perdu)
1. Sur une machine de secours ayant accès réseau aux hôtes : cloner le dépôt, restaurer `.vault_pass` + `atlas_ed25519` depuis le coffre (`gpg -d … | tar xzf -`), `chmod 600` la clé.
2. Lancer Ansible en surchargeant les chemins sans éditer `ansible.cfg` (cf. son en-tête) :
   ```bash
   ansible-playbook pra_restore_full.yaml -i develop/hosts.yaml \
     -e ansible_ssh_private_key_file=<chemin_local_clé>
   ```
3. Si le bastion `10.90.0.10` est injoignable, adapter le `ProxyCommand` de l'inventaire ou cibler les hôtes en direct.

> Tester cette bascule à chaque test PRA trimestriel pour garantir le **RTO ≤ 40 min**.

## 8. Contacts & escalade

| Rôle | Responsable | Quand |
|------|-------------|-------|
| Astreinte N1 | _à compléter_ | détection incident |
| Référent PRA | _à compléter_ | décision de bascule |
| Hébergeur (Hetzner) | _ticket support_ | panne matérielle hyperviseur |

> _Ce document est un livrable du DAT (cf. CLAUDE.md). Le maintenir à jour à chaque évolution de l'architecture ou de la chaîne de sauvegarde._
