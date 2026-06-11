# Projet Atlas — PRA/DR Helpdesk (GLPI)

Infrastructure as Code complète du portail de tickets **GLPI** avec plan de reprise
d'activité (PRA/DR) : provisioning Proxmox, configuration Ansible, supervision Zabbix,
sauvegardes et runbooks de restauration.

**Objectifs de reprise : RPO ≤ 20 minutes | RTO ≤ 40 minutes**

---

## Architecture

```
Internet → enp0s31f6 (138.201.135.108, Hetzner)
               ↓ NAT MASQUERADE (iptables sur pve01)
           vmbr0 [vlan-aware]
           ├── VLAN 20 — DMZ       : 10.20.0.0/24
           ├── VLAN 30 — LAN ADMIN : 10.30.0.0/24
           └── VLAN 90 — MGMT      : 10.90.0.0/24
```

### Conteneurs LXC (Debian 12, tagués `atlas`)

| Hostname   | VMID | VLAN | IP          | Rôle                       | vCPU | RAM (MB) | Disk (GB) |
|------------|------|------|-------------|----------------------------|------|----------|-----------|
| atlbst01p  | 200  | 90   | 10.90.0.10  | Bastion SSH                | 1    | 512      | 4         |
| atlrp01p   | 201  | 20   | 10.20.0.10  | Reverse proxy Nginx + TLS  | 1    | 512      | 4         |
| atlapp01p  | 202  | 20   | 10.20.0.11  | GLPI (Nginx + PHP-FPM 8.2) | 2    | 1024     | 8         |
| atldb01p   | 203  | 30   | 10.30.0.10  | MariaDB                    | 2    | 1024     | 10        |
| atlsmtp01p | 204  | 30   | 10.30.0.11  | SMTP relay (Postfix)       | 1    | 512      | 4         |
| atlzbx01p  | 205  | 30   | 10.30.0.12  | Zabbix Server + Frontend   | 2    | 1024     | 8         |
| atlbkp01p  | 206  | 30   | 10.30.0.13  | Backup (dumps + filestore) | 1    | 512      | 8         |

Le bastion `atlbst01p` est le **seul point d'entrée SSH** : Ansible atteint les groupes
`dmz` et `lan_admin` via `ProxyJump root@10.90.0.10` (configuré dans l'inventaire).

---

## Prérequis

- Hôte Proxmox `pve01` (Debian), storage `local`, template
  `local:vztmpl/debian-12-standard_12.12-1_amd64.tar.zst`
- **Ansible ≥ 2.15** sur le control node (pve01)
- Python `proxmoxer` + `requests` sur pve01 (`apt install python3-proxmoxer python3-requests`)
- Clé SSH de déploiement : `/root/.ssh/atlas_ed25519`
- Collections Ansible :

```bash
ansible-galaxy collection install -r collections/requirements.yaml
```

---

## Déploiement — dans l'ordre

```bash
# 1. Préparation réseau de l'hyperviseur (une seule fois, sur pve01)
bash scripts/setup_vlan_routing.sh

# 2. Secrets : renseigner puis chiffrer le vault
cp develop/group_vars/all/vault.yaml.example develop/group_vars/all/vault.yaml
vim develop/group_vars/all/vault.yaml          # remplacer les CHANGE_ME
echo 'MotDePasseVault' > .vault_pass && chmod 600 .vault_pass
ansible-vault encrypt develop/group_vars/all/vault.yaml

# 3. Déploiement complet
ansible-playbook site.yaml -i develop/hosts.yaml

# Déploiement ciblé par tag
ansible-playbook site.yaml -i develop/hosts.yaml --tags mariadb
```

Tags disponibles : `proxmox_network`, `proxmox_provision`, `common`, `bastion`,
`reverse_proxy`, `glpi`, `mariadb`, `smtp`, `zabbix`, `backup`.

---

## PRA — Runbooks de restauration

### Restauration complète (perte de VM) — mesure du RTO

```bash
ansible-playbook pra_restore_full.yaml -i develop/hosts.yaml
# Optionnel : forcer un dump précis
ansible-playbook pra_restore_full.yaml -i develop/hosts.yaml \
  -e "pra_restore_dump=/var/backups/atlas/db-remote/glpi_dump_20260611_020000.sql.gz"
```

Le runbook reprovisionne les LXC détruits, rejoue tous les rôles, restaure le dernier
dump + le filestore depuis `atlbkp01p`, vérifie GLPI/MariaDB/Zabbix et affiche le
**RTO mesuré**.

### Restauration granulaire (tickets supprimés) — mesure du RPO

```bash
ansible-playbook pra_restore_granular.yaml -i develop/hosts.yaml \
  -e "pra_target_dump=/var/backups/atlas/db/glpi_dump_20260101_020000.sql.gz"
```

Restaure les tables tickets dans une base temporaire puis les **merge en production
en INSERT IGNORE** (les tickets créés après l'incident ne sont jamais écrasés).

### Reset complet de la maquette

```bash
bash scripts/reset_proxmox_atlas.sh   # supprime UNIQUEMENT les LXC tagués « atlas »
```

---

## Sauvegardes

| Quoi                  | Où                                     | Quand              | Rétention |
|-----------------------|----------------------------------------|--------------------|-----------|
| Dump MariaDB (GLPI)   | atldb01p `/var/backups/atlas/db/`      | 02h00 + horaire    | 7 dumps   |
| Collecte des dumps    | atlbkp01p `/var/backups/atlas/db-remote/` | 02h30           | 7 jours   |
| Filestore GLPI        | atlbkp01p `/var/backups/atlas/filestore/` | 03h00           | miroir    |

Les binlogs MariaDB (`ROW`, 3 jours) permettent un point de restauration fin (RPO ≤ 20 min).

---

## Structure du dépôt

```
├── site.yaml                    # Orchestrateur principal (tags par rôle)
├── pra_restore_full.yaml        # Runbook PRA — restauration complète (RTO)
├── pra_restore_granular.yaml    # Runbook PRA — restauration granulaire tickets (RPO)
├── ansible.cfg
├── collections/requirements.yaml
├── scripts/
│   ├── setup_vlan_routing.sh    # vmbr0 VLAN-aware + routage iptables (pve01)
│   └── reset_proxmox_atlas.sh   # Suppression sélective des LXC tagués atlas
├── develop/
│   ├── hosts.yaml               # Inventaire (proxmox, mgmt, dmz, lan_admin)
│   └── group_vars/              # Variables globales + vault (gitignored)
└── roles/
    ├── proxmox_network          # VLAN-aware + iptables sur pve01
    ├── proxmox_provision        # 7 LXC via community.general.proxmox
    ├── common                   # Hardening, atlsvc, NTP, /etc/hosts
    ├── bastion                  # Point d'entrée SSH unique (VLAN 90)
    ├── reverse_proxy            # Nginx TLS auto-signé (VLAN 20)
    ├── glpi                     # GLPI 10.x + PHP-FPM 8.2 (VLAN 20)
    ├── mariadb                  # MariaDB + binlogs + dumps horaires (VLAN 30)
    ├── smtp                     # Postfix relay (VLAN 30)
    ├── zabbix                   # Zabbix 7.0 server + frontend (VLAN 30)
    ├── zabbix_agent             # Agent2 sur tous les LXC
    └── backup                   # rsync filestore + collecte dumps (VLAN 30)
```

## Sécurité

- Secrets uniquement via **Ansible Vault AES-256** (`develop/group_vars/all/vault.yaml`,
  exclu du Git) — aucun secret en clair dans le dépôt.
- SSH durci sur tous les LXC : clé uniquement, `MaxAuthTries 3`, UFW limité au bastion.
- Compte de service `atlsvc` (uid 2000) avec sudo restreint à `systemctl restart/reload`.
- MariaDB liée à `10.30.0.10` uniquement, GRANT limités par hôte source.
