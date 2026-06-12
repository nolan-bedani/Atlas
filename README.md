# 🛰️ Projet Atlas — Helpdesk GLPI avec PRA/DR

> **En une phrase :** un portail de tickets d'assistance (GLPI) déployé à 100 % en
> Infrastructure as Code, supervisé, sauvegardé, et capable d'être entièrement
> reconstruit après un désastre en moins de 40 minutes.

**Objectifs de reprise mesurables :**

| Indicateur | Cible | Comment on y arrive |
|---|---|---|
| **RPO** (perte de données max) | ≤ 20 min | Dumps MariaDB horaires + binlogs ROW |
| **RTO** (durée de reconstruction) | ≤ 40 min | Runbook Ansible `pra_restore_full.yaml` chronométré |

---

## 🗺️ Architecture

```
Internet ──→ enp0s31f6 (138.201.135.108 — Hetzner, hôte Proxmox pve01)
                  │  NAT MASQUERADE (iptables)
              vmbr0 [VLAN-aware]
                  │
   ┌──────────────┼──────────────────────────────┐
   │ VLAN 20 (DMZ)│ VLAN 30 (LAN ADMIN)          │ VLAN 90 (MGMT)
   │ 10.20.0.0/24 │ 10.30.0.0/24                 │ 10.90.0.0/24
   │              │                              │
   │ atlrp01p     │ atldb01p    atlzbx01p        │ atlbst01p
   │ atlapp01p    │ atlsmtp01p  atlbkp01p        │ (bastion SSH,
   │ atltst01p    │ atlgrf01p                    │  seule porte
   │              │                              │  d'entrée admin)
   └──────────────┴──────────────────────────────┘
```

**Pourquoi 3 VLANs ?** Cloisonnement : la DMZ est la seule zone « exposée » aux
utilisateurs ; la base de données et les sauvegardes vivent dans le LAN ADMIN,
inaccessible depuis la DMZ sauf flux explicitement autorisés (UFW) ; le VLAN MGMT
porte l'unique point d'entrée SSH. Compromettre le frontal ne donne ni la base,
ni les backups.

### Les 9 conteneurs LXC (Debian 12, tous tagués `atlas` dans Proxmox)

| Hostname   | VMID | VLAN | IP          | Outil & rôle                                        | vCPU | RAM  | Disque |
|------------|------|------|-------------|-----------------------------------------------------|------|------|--------|
| atlbst01p  | 200  | 90   | 10.90.0.10  | **Bastion SSH** — point d'entrée admin unique       | 1    | 512M | 4G     |
| atlrp01p   | 201  | 20   | 10.20.0.10  | **Nginx reverse proxy** — HTTPS, seul frontal web   | 1    | 512M | 4G     |
| atlapp01p  | 202  | 20   | 10.20.0.11  | **GLPI 10** (Nginx + PHP-FPM 8.2) — le helpdesk     | 2    | 1G   | 8G     |
| atldb01p   | 203  | 30   | 10.30.0.10  | **MariaDB** — la base de GLPI + binlogs + dumps     | 2    | 1G   | 10G    |
| atlsmtp01p | 204  | 30   | 10.30.0.11  | **Postfix** — relai mail (notifications, alertes)   | 1    | 512M | 4G     |
| atlzbx01p  | 205  | 30   | 10.30.0.12  | **Zabbix 7.0** — supervision + alertes (9 agents)   | 2    | 1G   | 8G     |
| atlbkp01p  | 206  | 30   | 10.30.0.13  | **Backup** — collecte dumps + filestore (rsync)     | 1    | 512M | 8G     |
| atlgrf01p  | 207  | 30   | 10.30.0.14  | **Grafana** — tableaux de bord branchés sur Zabbix  | 1    | 512M | 6G     |
| atltst01p  | 208  | 20   | 10.20.0.20  | **Machine de test** — incidents contrôlés (chaos)   | 1    | 512M | 4G     |

### Les flux en bref

- **Utilisateur** → HTTPS → atlrp01p (TLS, rate-limit) → HTTP → GLPI (atlapp01p) → SQL → MariaDB (atldb01p)
- **Sauvegarde** : dump horaire sur atldb01p → collecté à 02h30 par atlbkp01p ; filestore GLPI rsyncé à 03h00 ; rétention 7 jours
- **Supervision** : agents Zabbix sur les 9 LXC → serveur Zabbix → dashboards Grafana ; la machine de test génère des incidents toutes les 2 h (CPU, disque, service) réparés à H+45
- **Admin** : SSH → bastion (10.90.0.10) → rebond vers tous les autres (clé `atlas_ed25519`)

---

## 🚀 Déploiement de zéro (sur pve01)

### Prérequis

- Proxmox VE 8.x, storage `local` avec contenu `rootdir` activé, template
  `debian-12-standard_12.12-1_amd64.tar.zst` téléchargé (`pveam download local ...`)
- Ansible ≥ 2.14, `python3-proxmoxer`, `python3-requests`, `jq`
- Clé SSH `/root/.ssh/atlas_ed25519` (la clé publique est injectée dans les LXC)
- Un jeton API Proxmox **à moindre privilège** (PRA = ne pas dépendre de root@pam) :
  créer un rôle restreint aux opérations LXC + un utilisateur dédié + un jeton
  **avec** séparation de privilèges (`--privsep 1`) :
  ```bash
  pveum role add AtlasProvision -privs \
    "VM.Allocate VM.Config.Disk VM.Config.CPU VM.Config.Memory \
     VM.Config.Network VM.Config.Options VM.PowerMgmt \
     Datastore.AllocateSpace Datastore.Audit"
  pveum user add ansible@pve
  pveum acl modify / -user ansible@pve -role AtlasProvision
  pveum user token add ansible@pve atlas --privsep 1   # NOTER le secret affiché
  pveum acl modify / -user 'ansible@pve!atlas' -role AtlasProvision
  ```
  > ⚠️ Ne pas utiliser `pveum user token add root@pam ansible --privsep 0` :
  > le jeton hériterait de **tous** les pouvoirs root sur l'hyperviseur. Reporter
  > l'utilisateur, l'id de jeton et le secret dans le vault (`vault_proxmox_*`).

### Les 5 commandes

```bash
git clone <ce repo> /root/Atlas && cd /root/Atlas
ansible-galaxy collection install -r collections/requirements.yaml

# 1. Réseau de l'hyperviseur (une seule fois) : VLAN-aware + passerelles + NAT
bash scripts/setup_vlan_routing.sh

# 2. Secrets : remplir le vault puis le chiffrer
cp develop/group_vars/all/vault.yaml.example develop/group_vars/all/vault.yaml
vim develop/group_vars/all/vault.yaml            # remplacer tous les CHANGE_ME
openssl rand -base64 24 > .vault_pass && chmod 600 .vault_pass
ansible-vault encrypt develop/group_vars/all/vault.yaml

# 3. Tout déployer (≈ 20-30 min)
ansible-playbook site.yaml -i develop/hosts.yaml

# 4. Initialiser le schéma GLPI (une seule fois)
ssh root@10.20.0.11 'cd /var/www/glpi && sudo -u www-data php bin/console db:install \
  --reconfigure --db-host=10.30.0.10 --db-name=glpi_db --db-user=glpi_user \
  --db-password=<vault_glpi_db_password> --default-language=fr_FR --no-interaction --force'

# 5. Rejouer le remplissage de démo + l'enregistrement Zabbix
ansible-playbook site.yaml -i develop/hosts.yaml --tags glpi_seed,zabbix
```

Déploiement ciblé d'un seul composant : `--tags mariadb` (ou `glpi`, `zabbix`,
`grafana`, `backup`, `testlab`, `reverse_proxy`, `bastion`, `common`, `smtp`,
`proxmox_network`, `proxmox_provision`, `glpi_seed`).

---

## 🖥️ Accéder aux interfaces (depuis votre poste)

Les services ne sont **pas exposés sur Internet** : on y accède par tunnel SSH.
Ouvrez un terminal par tunnel et **laissez-le ouvert** :

| Service | Tunnel | URL navigateur | Compte initial |
|---|---|---|---|
| GLPI | `ssh -L 8443:10.20.0.10:443 root@138.201.135.108` | `https://localhost:8443` ⚠️ certificat auto-signé : « Avancé → Continuer » | `atlasadmin` / *(vault `vault_glpi_admin_password`)* |
| Zabbix | `ssh -L 8080:10.30.0.12:8080 root@138.201.135.108` | `http://localhost:8080` | `Admin` / `zabbix` |
| Grafana | `ssh -L 3000:10.30.0.14:3000 root@138.201.135.108` | `http://localhost:3000` | `admin` / *(vault)* |

> 🔐 **Comptes GLPI par défaut — supprimés automatiquement.** Le rôle `glpi_seed`
> (tâche `harden_accounts`, jouée par `--tags glpi_seed`) applique la règle CLAUDE.md
> « aucun compte admin par défaut conservé » : le super-admin `glpi`/`glpi` est
> **renommé** en `atlasadmin` (variable `glpi_admin_username`) avec le mot de passe
> fort `vault_glpi_admin_password`, et les comptes de démo `tech`, `normal`,
> `post-only` sont **désactivés**. Renseignez donc `vault_glpi_admin_password`
> (>= 12 caractères, ≠ `CHANGE_ME`) **avant** de jouer `glpi_seed`.
>
> 🔐 **Zabbix** : le compte `Admin`/`zabbix` par défaut n'est pas encore durci par
> le code — **changez son mot de passe dès la première connexion**, mettez à jour
> `vault_zabbix_admin_password` (`ansible-vault edit develop/group_vars/all/vault.yaml`)
> puis rejouez `--tags grafana,zabbix`.

---

## 🆘 PRA — les runbooks de restauration

### Désastre total (perte de conteneurs)

```bash
ansible-playbook pra_restore_full.yaml -i develop/hosts.yaml
```

Reprovisionne les LXC manquants, rejoue tous les rôles, restaure le dernier dump
et le filestore depuis atlbkp01p, vérifie GLPI/MariaDB/Zabbix, et **affiche le RTO
mesuré** (journal : `/var/log/atlas/pra_restore_full.log` sur pve01).

### Tickets supprimés par erreur (restauration chirurgicale)

```bash
ansible-playbook pra_restore_granular.yaml -i develop/hosts.yaml \
  -e "pra_target_dump=/var/backups/atlas/db/glpi_dump_YYYYMMDD_HHMMSS.sql.gz"
```

Restaure le dump dans une base temporaire, en extrait uniquement les tables
tickets, puis les **merge en `INSERT IGNORE`** : les tickets créés depuis
l'incident ne sont jamais écrasés. Affiche le RPO effectif.

### Tout raser et recommencer (maquette)

```bash
bash scripts/reset_proxmox_atlas.sh   # ne supprime QUE les LXC tagués « atlas »
```

---

## 🧪 La machine de test (chaos contrôlé)

`atltst01p` simule des pannes pour alimenter Zabbix/Grafana et s'entraîner :

```bash
/opt/atlas/scripts/chaos.sh run       # un incident aléatoire (cpu | disque | service)
/opt/atlas/scripts/chaos.sh cpu       # scénario précis
/opt/atlas/scripts/chaos.sh clean     # tout réparer
```

Par défaut un cron déclenche un incident **toutes les 2 h** (réparé à H+45) —
désactivable avec `testlab_cron_enabled: false`. Journal : `/var/log/atlas/chaos.log`.

---

## 📁 Structure du dépôt

```
├── site.yaml                  # Orchestrateur : déploie TOUT, play par play
├── pra_restore_full.yaml      # Runbook PRA — reconstruction complète (RTO)
├── pra_restore_granular.yaml  # Runbook PRA — récupération de tickets (RPO)
├── ansible.cfg                # Config Ansible (inventaire, vault, SSH)
├── collections/requirements.yaml
├── scripts/
│   ├── setup_vlan_routing.sh  # Prépare le réseau de pve01 (1 seule fois)
│   └── reset_proxmox_atlas.sh # Détruit les LXC atlas (avec confirmation)
├── develop/
│   ├── hosts.yaml             # Inventaire : proxmox / mgmt / dmz / lan_admin
│   └── group_vars/
│       ├── all/vars.yaml      # Variables globales (non secrètes)
│       ├── all/vault.yaml     # SECRETS chiffrés AES-256 (gitignored !)
│       └── all/vault.yaml.example  # Modèle à copier
├── roles/                     # 1 rôle = 1 brique, toujours la même structure :
│   │                          #   tasks/main.yaml = sommaire (imports only)
│   │                          #   tasks/*.yaml    = la logique, par étape
│   │                          #   templates/*.j2  = fichiers de conf générés
│   │                          #   defaults/       = variables modifiables
│   ├── proxmox_network/       # VLANs + NAT sur pve01
│   ├── proxmox_provision/     # Création des 9 LXC via l'API Proxmox
│   ├── common/                # Socle : hardening SSH, UFW, atlsvc, NTP
│   ├── bastion/               # Le sas SSH
│   ├── reverse_proxy/         # Nginx TLS
│   ├── glpi/                  # L'application helpdesk
│   ├── glpi_seed/             # Données de démo + durcissement comptes par défaut
│   ├── mariadb/               # BDD + dumps automatiques
│   ├── smtp/                  # Postfix
│   ├── zabbix/                # Serveur + frontend + enregistrement des hôtes
│   ├── zabbix_agent/          # Agent sur les 9 LXC
│   ├── grafana/               # Dashboards (datasource Zabbix provisionnée)
│   ├── backup/                # Collecte des sauvegardes
│   └── testlab/               # Générateur d'incidents
├── infra/                     # ⚠️ OBSOLÈTE — voie de provisioning legacy (pct/
│   │                          #   Docker) divergente des rôles. NE PAS utiliser :
│   │                          #   la source de vérité est roles/ + site.yaml.
│   │                          #   Scripts neutralisés par ATLAS_PROVISION_FORCE.
│   ├── dmz_vlan20/            # provision_nginx.sh, nginx.conf, docker-compose.yml
│   ├── lan_admin_vlan30/      # provision_glpi.sh, provision_zabbix.sh
│   └── proxmox_iac/           # deploy_lxc.sh (CT 101-103, topologie divergente)
├── scripts_pra/              # Scripts/notes PRA hors orchestration Ansible
│   ├── backup/                # dump_mariadb.sh (+ .md)
│   └── restore/
└── docs/                      # Dossier documentaire (DAT, PRA, risques, audit)
    ├── DAT.md                 # Dossier d'Architecture Technique
    ├── Runbooks_PRA.md        # Procédures de restauration
    ├── Matrice_Risques.md     # Analyse de risques
    └── audit/                 # Rapports d'audit du dépôt
```

### Conventions du code (à respecter dans toute contribution)

- Extensions **`.yaml`** uniquement ; tâches et commentaires **en français**
- Modules Ansible en **FQCN** (`ansible.builtin.apt`, jamais `apt`)
- `tasks/main.yaml` = uniquement des `import_tasks` (zéro logique)
- Variables préfixées par le rôle (`glpi_version`, `backup_retention_days`...)
- **Aucun secret en clair** : tout passe par `vault_*` (Ansible Vault AES-256)
- Chaque rôle a un flag `<role>_debug: false` qui active ses tâches de diagnostic

---

## 🔐 Sécurité

- Secrets uniquement dans le vault chiffré (`develop/group_vars/all/vault.yaml`,
  exclu du Git) ; mot de passe vault dans `.vault_pass` (exclu aussi)
- SSH par clé uniquement, `MaxAuthTries 3`, accès root par mot de passe désactivé
- UFW sur chaque LXC : SSH accepté seulement depuis le VLAN MGMT (10.90.0.0/24),
  chaque flux applicatif ouvert au cas par cas (3306 pour GLPI/Zabbix, 25 interne...)
- Compte de service `atlsvc` (uid 2000) : sudo limité à `systemctl restart/reload`
- MariaDB liée à son IP, GRANT par hôte source uniquement
- Authentification API Proxmox par **jeton révocable** (`pveum user token remove root@pam ansible`)

## 🩺 Dépannage express

| Symptôme | Réflexe |
|---|---|
| Un play échoue | Relancer avec `-vvv`, les rôles sont idempotents (rejouables sans risque) |
| GLPI ne répond plus | `ansible-playbook site.yaml --tags glpi,reverse_proxy` |
| Vérifier les dumps | `ssh root@10.30.0.10 'ls -lh /var/backups/atlas/db/'` + `/var/log/atlas/dump_glpi.log` |
| Zabbix n'alerte pas | Vérifier `systemctl status zabbix-agent2` sur l'hôte concerné |
| Tout est cassé | C'est prévu 😉 → `pra_restore_full.yaml` |
