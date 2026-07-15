# Constats de recette & remédiation — Projet Atlas (PRA/DR)

> Journal des écarts identifiés lors de la **validation en conditions réelles** de
> l'infrastructure et des runbooks PRA, avec cause racine, preuve, correctif et
> vérification. Démarche : *« prouver, pas déclarer »*. Toutes les vérifications ont
> été menées sur l'infrastructure live (`pve01`, 138.201.135.108) les 15–16 juillet 2026.

## Synthèse

| # | Constat | Domaine | Statut | Correctif (commit) |
|---|---------|---------|--------|--------------------|
| 1 | Agent du bastion injoignable par Zabbix (flux VLAN30→90 absent) | Réseau / supervision | ✅ Corrigé | `roles/proxmox_network/defaults/main.yaml` |
| 2 | Hôte « Zabbix server » en ECONNRESET (`Server=` sans loopback) | Supervision | ✅ Corrigé | `roles/zabbix_agent/templates/zabbix_agent2.conf.j2` |
| 3 | 11 items internes « not supported » polluant le dashboard | Supervision | ✅ Corrigé | `roles/zabbix/tasks/tune_health.yaml` |
| 4 | Restauration granulaire : table `glpi_tickets_groups` inexistante | PRA (bug) | ✅ Corrigé | `pra_restore_granular.yaml` |
| 5 | `proxmox_validate_certs` incohérent → restore complet bloqué | IaC / API | ✅ Corrigé | `develop/hosts.yaml`, `start_lxc.yaml` |
| 6 | Comptes GLPI par défaut actifs + secret admin absent du vault | Sécurité | ✅ Corrigé | vault + `glpi_seed/harden_accounts` |
| 7 | `python3-cryptography` absent (TLS Zabbix) | PRA (dépendance) | ✅ Corrigé | `roles/common/tasks/packages.yaml` |
| 8 | Secret `vault_zabbix_grafana_password` absent (compte Grafana RO) | Sécurité / PRA | ✅ Corrigé | vault |
| 9 | `rsync` absent d'atlapp01p (restauration filestore) | PRA (dépendance) | ✅ Corrigé | `roles/common/tasks/packages.yaml` |
| 10 | Sélection du dump : SIGPIPE (`ls\|head`) + réplique 0 octet | PRA (bug) | ✅ Corrigé | `pra_restore_full.yaml` |
| 11 | Flux Backup→GLPI:22 absent + permissions filestore (www-data) | PRA (réseau / perms) | ✅ Corrigé | `pra_restore_full.yaml`, `proxmox_network` |

**Résultat final :** `pra_restore_full.yaml` s'exécute de bout en bout (`failed=0` sur les 10 hôtes) et mesure un **RTO réel de 3 min 15 s** (cible ≤ 40 min). RPO ≤ 15 min (dumps toutes les 15 min). Détection d'incident ≈ 6 min. Restauration granulaire 36 s.

---

## Détail des constats

### 1. Supervision du bastion injoignable
- **Symptôme :** hôte `atlbst01p` en « agent not available » dans Zabbix depuis le 13/06 ; capture nulle.
- **Cause racine :** la chaîne `iptables FORWARD` (politique `DROP`) du host n'avait aucune règle pour `VLAN30 (10.30.0.12) → VLAN90 (10.90.0.10)` sur 10050/10051. Le SYN mourait sur l'hyperviseur (0 paquet reçu par le bastion). Les autres hôtes VLAN30 sont verts car sur le même sous-réseau que le serveur Zabbix (pas de forward).
- **Preuve :** capture réseau sur le bastion pendant une connexion = 0 paquet ; `iptables -S FORWARD` sans règle VLAN90.
- **Correctif :** ajout de 2 règles inter-VLAN (`10.30.0.12↔10.90.0.10`, 10050 passif / 10051 actif) dans `proxmox_network_interzone_rules`.
- **Vérification :** TCP `205→200:10050` OUVERT ; bastion vert, 0 problème.

### 2. Agent Zabbix local en ECONNRESET
- **Symptôme :** hôte « Zabbix server » (127.0.0.1) rouge, erreur `cannot read from socket [104]`.
- **Cause racine :** l'agent avait `Server=10.30.0.12` mais l'hôte est sondé via loopback (127.0.0.1) → l'agent réinitialise la connexion.
- **Correctif :** `Server=127.0.0.1,{{ zabbix_agent_server_ip }}` dans le template agent.
- **Vérification :** hôte vert, 0 problème.

### 3. Items internes « not supported »
- **Symptôme :** 11 items rouges du template *Zabbix server health* (`ipmi poller`, `java poller`, `vmware collector`, `report writer`, `connector`, `snmp trapper`…).
- **Cause racine :** sous-systèmes désactivés par défaut mais surveillés par le template.
- **Correctif :** tâche API idempotente `tune_health.yaml` désactivant ces items (liste `zabbix_health_disabled_items`).
- **Vérification :** 0 item « not supported ».

### 4. Restauration granulaire — table inexistante
- **Symptôme :** `pra_restore_granular.yaml` échoue : `mysqldump: Couldn't find table "glpi_tickets_groups"`.
- **Cause racine :** dans GLPI la relation groupe↔ticket est `glpi_groups_tickets` (nom **inversé** dans le playbook).
- **Correctif :** `glpi_tickets_groups` → `glpi_groups_tickets`.
- **Vérification :** ticket #25 supprimé puis restauré en 36 s (« 25 tickets présents »).

### 5. Vérification TLS de l'API Proxmox
- **Symptôme :** `pra_restore_full.yaml` échoue au reprovisioning : `CERTIFICATE_VERIFY_FAILED` (API Proxmox 8006, certificat auto-signé).
- **Cause racine :** `proxmox_validate_certs: true` par défaut, alors que `start_lxc.yaml` codait `false` en dur → incohérence, et la CA interne n'est pas dans le trust store.
- **Correctif :** override `proxmox_validate_certs: false` sur le groupe `proxmox` de l'inventaire (défaut du rôle conservé à `true`) ; `start_lxc.yaml` aligné sur la variable.
- **Vérification :** reprovisioning `ok`, playbook poursuit.

### 6. Comptes GLPI par défaut + secret absent
- **Symptôme :** comptes `glpi`/`tech`/`normal`/`post-only` actifs (super-admin `glpi/glpi` exposé) ; `vault_glpi_admin_password` absent du vault → tâche de durcissement systématiquement sautée.
- **Cause racine :** secret manquant + durcissement jamais appliqué (violation CLAUDE.md « aucun compte admin par défaut »).
- **Correctif :** ajout de `vault_glpi_admin_password` (24 car., vault chiffré) + exécution de `glpi_seed/harden_accounts` : `glpi`→`atlasadmin` (bcrypt), `tech`/`normal`/`post-only` désactivés.
- **Vérification :** `atlasadmin` actif, comptes par défaut `is_active=0`.

### 7. Dépendance `python3-cryptography`
- **Symptôme :** restore complet échoue sur `atlzbx01p` : `No module named 'cryptography'` (génération de la clé TLS du frontend).
- **Cause racine :** `community.crypto.openssl_privatekey` exige la lib Python `cryptography`, absente de l'hôte.
- **Correctif :** ajout de `python3-cryptography` aux paquets de base (rôle `common`).

### 8. Secret `vault_zabbix_grafana_password` absent
- **Symptôme :** restore échoue sur « Créer le compte de service Grafana » (`no_log`). API : `Invalid parameter "/1/passwd": cannot be empty`.
- **Cause racine :** `vault_zabbix_grafana_password` absent du vault → mot de passe vide → `user.create` rejeté.
- **Correctif :** ajout du secret (24 car.) au vault chiffré.

### 9. Dépendance `rsync`
- **Symptôme :** restauration du filestore : `rsync: command not found` (rc 127) sur `atlapp01p`.
- **Cause racine :** `rsync` doit être aux deux bouts ; absent de la cible.
- **Correctif :** ajout de `rsync` aux paquets de base (rôle `common`).

### 10. Sélection du dump — SIGPIPE + réplique corrompue
- **Symptôme :** (a) `ls -t … | head -1` renvoie rc 141 (SIGPIPE) sous `set -o pipefail` quand les dumps sont nombreux ; (b) la réplique hors-site la plus récente était un fichier **0 octet** (réplication d'un dump en cours d'écriture) → import `unexpected end of file`.
- **Cause racine :** `head` ferme le tuyau tôt (SIGPIPE) ; le runbook prenait « le plus récent » sans contrôle d'intégrité.
- **Correctif :** parcours des dumps du plus récent au plus ancien, sélection du **premier VALIDE** (`[ -s ]` + `gzip -t`). Une sauvegarde corrompue ne bloque plus la reprise.

### 11. Flux Backup→GLPI + permissions filestore
- **Symptôme :** (a) `ssh: connect to 10.20.0.11 port 22: Connection timed out` (rsync backup→GLPI) ; (b) puis rc 23 `failed to set times … Operation not permitted`.
- **Cause racine :** (a) aucun flux inter-VLAN `10.30.0.13→10.20.0.11:22` (FORWARD DROP) ; (b) `atlsvc` n'est pas propriétaire de `/var/lib/glpi/files` (www-data) → ne peut préserver perms/horodatages.
- **Correctif :** (a) règle de moindre privilège `10.30.0.13/32→10.20.0.11/32:22` ; (b) `rsync -rlDvz --omit-dir-times --no-perms --no-owner --no-group` (la tâche suivante rétablit déjà les droits www-data).
- **Vérification :** filestore restauré, permissions www-data OK, GLPI HTTP + HTTPS 200.

---

## Preuve finale — RTO mesuré

```
TASK [Afficher le nombre de tickets restaurés] — Vérification base : ['COUNT(*)', '25']
TASK [Afficher le RTO mesuré] — RTO mesuré : 3 minutes 15 secondes (cible : 40 minutes)
PLAY RECAP — 10 hôtes, failed=0
```

## Note sécurité (persistance des secrets)

Les deux secrets ajoutés (`vault_glpi_admin_password`, `vault_zabbix_grafana_password`) sont
stockés **chiffrés dans le vault Ansible** (`develop/group_vars/all/vault.yaml`), hors du
dépôt Git (`.gitignore`). Le vault vit sur `pve01` ; il doit être **sauvegardé hors-site**
(coffre) pour la reprise du control node.
