# Rapport d'audit — Playbook Ansible Atlas

Date : 2026-06-12 — Revue multi-agents (9 zones) + verification adversariale par constat.

**Stats** : 107 constats bruts, 96 apres deduplication, 94 confirmes, 2 refutes.
Par severite : critique 5, haute 21, moyenne 34, basse 34.

## Severite : critique (5)

### critique-1. Politique iptables par défaut ACCEPT : aucun filtrage réel
- **Fichier** : `roles/proxmox_network/templates/rules.v4.j2` (ligne ~8) — categorie : securite — zone : proxmox
- **Description** : Les politiques par défaut des chaînes INPUT, FORWARD et OUTPUT sont ACCEPT. Toutes les règles -A FORWARD ... -j ACCEPT du template sont donc inopérantes (tout passe déjà), et aucune règle DROP/REJECT n'existe. Le pare-feu annoncé n'isole rien : l'hyperviseur et le routage inter-réseaux sont totalement ouverts.
- **Extrait** :
```
:INPUT ACCEPT [0:0]
:FORWARD ACCEPT [0:0]
:OUTPUT ACCEPT [0:0]
```
- **Correctif propose** : Passer la politique FORWARD (et idéalement INPUT) à DROP, conserver les règles ACCEPT explicites (ESTABLISHED/RELATED, flux autorisés), et ajouter les règles INPUT nécessaires (SSH depuis MGMT, API Proxmox) avant tout déploiement.
- **Verdict verification** : confiance haute — Confirmé. Le fichier roles/proxmox_network/templates/rules.v4.j2 contient bien aux lignes 7-9 « :INPUT ACCEPT [0:0] / :FORWARD ACCEPT [0:0] / :OUTPUT ACCEPT [0:0] », et toutes les règles générées (FORWARD vers Internet, inter-VLAN, sous-réseaux hérités) sont uniquement des -j ACCEPT. Aucune règle DROP/REJECT n'existe dans le rôle ni ailleurs dans le dépôt (grep : seuls des DROP DATABASE MySQL), aucune utilisation de pve-firewall, ufw ou nftables, et aucun garde-fou dans les tasks/defaults du rôle. Le filtrage est donc purement déclaratif : tout trafic passe déjà par politique par défaut, y compris DMZ (VLAN 20) → LAN ADMIN (VLAN 30) → MGMT (VLAN 90), ce qui annule la segmentation réseau exigée par CLAUDE.md et expose l'hyperviseur (INPUT ACCEPT). Sévérité critique justifiée.

### critique-2. Routage inter-VLAN full mesh : la DMZ accède librement au LAN ADMIN et au MGMT
- **Fichier** : `roles/proxmox_network/templates/rules.v4.j2` (ligne ~19) — categorie : securite — zone : proxmox
- **Description** : La double boucle Jinja génère un ACCEPT pour chaque couple de VLANs (20↔30, 20↔90, 30↔90...). La DMZ (VLAN 20, exposée) peut donc atteindre directement MariaDB, Zabbix, le backup et le bastion MGMT sur tous les ports. Cela annule l'intérêt de la segmentation DMZ/LAN ADMIN/MGMT annoncée dans l'architecture.
- **Extrait** :
```
{% for src in proxmox_network_vlans %}
{% for dst in proxmox_network_vlans %}
{% if src.id != dst.id %}
-A FORWARD -s {{ src.subnet }} -d {{ dst.subnet }} -j ACCEPT
```
- **Correctif propose** : Remplacer le full mesh par une matrice de flux explicite : DMZ→LAN ADMIN limité à 3306 (app→DB) et 10050/10051 (Zabbix), MGMT→tout en SSH, et DROP du reste (avec politique FORWARD DROP).
- **Verdict verification** : confiance haute — Constat exact : roles/proxmox_network/templates/rules.v4.j2 lignes 16-22 contiennent la double boucle citée ("-A FORWARD -s {{ src.subnet }} -d {{ dst.subnet }} -j ACCEPT" pour tout couple src.id != dst.id), et defaults/main.yaml définit les VLANs 20 (10.20.0.0/24), 30 (10.30.0.0/24) et 90 (10.90.0.0/24). Aucune surcharge (group_vars/host_vars) ni règle de filtrage par port n'existe dans le dépôt. La DMZ exposée accède donc à tous les ports du LAN ADMIN et du MGMT, annulant la segmentation. Facteur aggravant : la politique par défaut est ":FORWARD ACCEPT [0:0]" (ligne 8), donc tout transit est permis même hors de ces règles. Sévérité critique justifiée ; le correctif proposé (matrice de flux explicite + FORWARD DROP) est pertinent.

### critique-3. Même routage inter-VLAN totalement ouvert dans le script shell
- **Fichier** : `scripts/setup_vlan_routing.sh` (ligne ~187) — categorie : securite — zone : proxmox
- **Description** : Le script ajoute les mêmes règles ACCEPT entre tous les sous-réseaux (DMZ↔LAN ADMIN↔MGMT) sans aucune restriction de port ni politique DROP : aucune isolation entre la DMZ et les zones internes.
- **Extrait** :
```
ajoute_regle filter FORWARD -s "${src_subnet}" -d "${dst_subnet}" -j ACCEPT
```
- **Correctif propose** : Appliquer la même matrice de flux restrictive que pour le template Ansible (ports précis, politique FORWARD DROP) ou supprimer ce script au profit du rôle, pour éviter deux sources de vérité divergentes.
- **Verdict verification** : confiance haute — Confirmé. Dans C:/Users/BEDANI/Documents/Atlas/Atlas/scripts/setup_vlan_routing.sh, lignes 181-189, une double boucle sur VLANS (20 DMZ, 30 LAN ADMIN, 90 MGMT) ajoute exactement la règle citée : `ajoute_regle filter FORWARD -s "${src_subnet}" -d "${dst_subnet}" -j ACCEPT` (ligne 187), soit un maillage complet ACCEPT entre les trois zones, sans restriction de port ni de protocole. Le script ne définit nulle part de politique par défaut (`iptables -P FORWARD DROP` absent) ; les règles sont en plus persistées via iptables-save dans /etc/iptables/rules.v4 (lignes 204-206). Un hôte DMZ compromis (zone exposée) atteint donc librement le LAN ADMIN et le MGMT, en contradiction directe avec la segmentation VLAN et le moindre privilège exigés par CLAUDE.md. Sévérité critique justifiée.

### critique-4. Copie distante des dumps une seule fois par jour : RPO hors site ~24 h
- **Fichier** : `roles/backup/tasks/cron.yaml` (ligne ~7) — categorie : pra — zone : donnees
- **Description** : La collecte rsync des dumps depuis atldb01p ne s'exécute qu'à 02h30, une fois par jour. En cas de perte totale du conteneur base de données (disque, hyperviseur), le RPO réel est de près de 24 heures, très loin de l'objectif RPO <= 20 minutes. Les binlogs, eux non plus, ne sont jamais copiés hors de l'hôte.
- **Extrait** :
```
- name: "Planifier la collecte des dumps MariaDB à 02h30"
  ansible.builtin.cron:
    minute: "30"
    hour: "2"
    job: "{{ backup_scripts_dir }}/collect_dumps.sh"
```
- **Correctif propose** : Exécuter collect_dumps.sh à une fréquence alignée sur le RPO (toutes les 15-20 minutes), et inclure /var/log/mysql/mysql-bin.* dans la collecte, ou déployer une réplication MariaDB vers un secondaire.
- **Verdict verification** : confiance haute — Constat confirmé. L'extrait cité existe à l'identique dans roles/backup/tasks/cron.yaml (lignes 7-14) : collect_dumps.sh est planifié uniquement à 02h30 (minute "30", hour "2"), une fois par jour, et backup_filestore.sh à 03h00. Le script collect_dumps.sh.j2 ne fait qu'un rsync de backup_db_dumps_dir (les dumps SQL) — aucune copie des binlogs /var/log/mysql/mysql-bin.* (pourtant activés dans roles/mariadb/templates/99-atlas-server.cnf.j2 : log_bin + binlog_format=ROW). Le rôle mariadb planifie bien un dump horaire local (roles/mariadb/tasks/backup_script.yaml, « dump GLPI horaire (RPO) »), mais ces dumps et les binlogs restent sur atldb01p : en cas de perte totale du conteneur DB, seule la copie hors site de 02h30 subsiste, soit un RPO réel jusqu'à ~24 h contre un objectif <= 20 min (CLAUDE.md). Aucune réplication MariaDB n'existe dans le dépôt. Le README revendique « Dumps horaires + binlogs ROW » pour le RPO, mais la chaîne hors site ne le concrétise pas. Sévérité critique justifiée pour un projet dont le PRA est l'objectif central.

### critique-5. Compte super-admin par défaut « glpi » conservé et utilisé pour l'API
- **Fichier** : `roles/glpi_seed/tasks/api_enable.yaml` (ligne ~42) — categorie : securite — zone : web
- **Description** : Aucune tâche dans glpi ni glpi_seed ne supprime ou désactive les comptes par défaut de GLPI (glpi/glpi, tech, post-only, normal). Pire, le jeton API est posé sur le compte « glpi », super-administrateur avec mot de passe par défaut connu (glpi/glpi). Violation directe de la règle CLAUDE.md « aucun compte administrateur par défaut ne doit être conservé ». L'interface étant publiée via le reverse proxy, n'importe qui peut se connecter en glpi/glpi.
- **Extrait** :
```
UPDATE glpi_users SET api_token='{{ vault_glpi_api_token }}' WHERE name='glpi';
```
- **Correctif propose** : Créer un compte de service API dédié à privilèges minimaux, changer le mot de passe du compte glpi (ou le désactiver) et supprimer/désactiver tech, post-only et normal (via bin/console ou l'API) dans une tâche dédiée.
- **Verdict verification** : confiance haute — Constat confirmé. L'extrait cité existe mot pour mot à la ligne 42 de roles/glpi_seed/tasks/api_enable.yaml : « UPDATE glpi_users SET api_token='{{ vault_glpi_api_token }}' WHERE name='glpi'; » — le jeton API est bien posé sur le compte super-admin par défaut « glpi ». Recherche exhaustive dans roles/glpi et roles/glpi_seed (tasks, defaults, vars, templates) : aucune tâche ne change le mot de passe du compte glpi ni ne supprime/désactive tech, post-only ou normal (aucun UPDATE de champ password, aucun is_active=0, aucun appel console user:*). Le seul no_log présent protège le jeton dans les logs Ansible, pas les comptes par défaut. Violation directe de la règle CLAUDE.md « Aucun compte administrateur par défaut ne doit être conservé », avec exposition via le reverse proxy. Sévérité critique justifiée (authentification triviale glpi/glpi en super-admin).

## Severite : haute (21)

### haute-1. Runbook PRA vide (0 octet)
- **Fichier** : `docs/Runbooks_PRA.md` (ligne ~0) — categorie : pra — zone : pra
- **Description** : Le fichier docs/Runbooks_PRA.md fait 0 octet. C'est un livrable obligatoire selon CLAUDE.md (documentation des scripts pour le DAT et les Runbooks). Sans runbook, aucune procédure opérateur pour déclencher la restauration full/granulaire, aucun test de restauration documenté, et le RTO 40 min n'est pas tenable en situation de crise réelle.
- **Extrait** :
```
Runbooks_PRA.md — Length: 0
```
- **Correctif propose** : Rédiger le runbook : déclencheurs, prérequis (clés SSH, /root/.my.cnf), commandes exactes des deux playbooks, vérifications post-restore, procédure de test de restauration périodique avec mesure RTO/RPO.
- **Verdict verification** : confiance haute — Confirmé : C:\Users\BEDANI\Documents\Atlas\Atlas\docs\Runbooks_PRA.md fait bien 0 octet (vérifié via Get-Item, Length=0 ; Matrice_Risques.md est aussi vide). Aucun runbook de substitution dans le dépôt : la recherche « runbook/restore/restauration » ne trouve que des mentions éparses, dont docs/DAT.md lignes 256 et 275 qui décrivent sommairement la restauration de la clé SSH et du dernier dump GLPI — ce n'est pas une procédure PRA complète (pas de déclencheurs, pas de tests de restauration, pas de mesure RTO/RPO). Le constat est factuel. Sévérité ajustée de critique à haute : c'est un manquement documentaire majeur qui compromet la tenabilité du RTO 40 min en crise, mais les mécanismes techniques de sauvegarde/restauration existent (scripts_pra/backup) et le DAT couvre partiellement la reconstruction ; l'absence de doc n'introduit pas de vulnérabilité technique directe.

### haute-2. Matrice des risques vide (0 octet)
- **Fichier** : `docs/Matrice_Risques.md` (ligne ~0) — categorie : pra — zone : pra
- **Description** : docs/Matrice_Risques.md fait 0 octet alors que c'est un livrable obligatoire du dossier PRA. Aucune analyse de risques (perte VM, suppression de données, compromission) n'est tracée.
- **Extrait** :
```
Matrice_Risques.md — Length: 0
```
- **Correctif propose** : Renseigner la matrice : scénarios (perte LXC, corruption DB, suppression tickets, perte du serveur de backup), probabilité/impact, mesure de mitigation, procédure PRA associée.
- **Verdict verification** : confiance haute — Vérifié : docs/Matrice_Risques.md fait exactement 0 octet (Get-Item Length=0, contenu vide). Aucune analyse de risques ailleurs dans docs/ (grep insensible à la casse 'risque|risk' sans résultat, DAT.md n'en contient pas). Runbooks_PRA.md est également vide, confirmant l'absence totale du volet documentaire PRA. Constat factuel confirmé, mais sévérité 'critique' exagérée : il s'agit d'un livrable manquant, pas d'une défaillance technique exploitable ni d'une perte de capacité de restauration en soi → haute.

### haute-3. Le sshd_config templaté supprime la directive Include : le drop-in bastion n'est jamais chargé
- **Fichier** : `roles/common/templates/sshd_config.j2` (ligne ~24) — categorie : bug — zone : socle
- **Description** : Le rôle common écrase /etc/ssh/sshd_config avec un template qui ne contient AUCUNE directive 'Include /etc/ssh/sshd_config.d/*.conf' (présente par défaut sur Debian 12). Or le rôle bastion déploie son durcissement dans /etc/ssh/sshd_config.d/90-atlas-bastion.conf (AllowUsers atlsvc root + Banner). Conséquence : sur le bastion, la restriction AllowUsers et la bannière déployée dans /etc/ssh/banner ne sont JAMAIS appliquées par sshd. Tout le durcissement spécifique au bastion est silencieusement inopérant.
- **Extrait** :
```
# ─── Sous-systèmes ───
Subsystem sftp /usr/lib/openssh/sftp-server
```
- **Correctif propose** : Ajouter 'Include /etc/ssh/sshd_config.d/*.conf' en tête du template sshd_config.j2 (avant toute autre directive, car sshd applique la première occurrence d'un mot-clé), ou intégrer AllowUsers/Banner directement dans le template conditionné par l'hôte.
- **Verdict verification** : confiance haute — Confirmé : sshd_config.j2 (rôle common) écrase /etc/ssh/sshd_config sans aucune directive 'Include /etc/ssh/sshd_config.d/*.conf' (vérifié sur les 25 lignes du template ; l'extrait 'Subsystem sftp' est bien en ligne 24). Or roles/bastion/tasks/configure.yaml déploie sshd_bastion.conf.j2 (AllowUsers atlsvc root, Banner) vers /etc/ssh/sshd_config.d/90-atlas-bastion.conf, qui n'est donc jamais chargé par sshd. Aucune mitigation ailleurs. Aggravant : le template met PermitRootLogin yes sur le bastion. Sévérité ramenée de critique à haute car PasswordAuthentication no et l'auth par clé restent appliqués par le fichier principal — la perte concerne la défense en profondeur (AllowUsers, bannière), pas une exposition directe à une intrusion.

### haute-4. Connexion en root sur tous les hôtes (violation du moindre privilège)
- **Fichier** : `develop/group_vars/all/vars.yaml` (ligne ~31) — categorie : securite — zone : orchestration
- **Description** : ansible_user: root dans group_vars/all écrase remote_user = atlsvc défini dans ansible.cfg (la précédence des variables d'inventaire l'emporte sur la config). Tous les plays s'exécutent donc en root SSH direct sur tous les LXC, en contradiction avec la contrainte projet « moindre privilège, aucun compte admin par défaut conservé ». Le compte de service atlsvc déclaré dans ansible.cfg n'est en pratique jamais utilisé.
- **Extrait** :
```
# le compte de service atlsvc (sudo limité) sert à l'exploitation.
ansible_user: root
```
- **Correctif propose** : Réserver root au tout premier bootstrap (ex: play dédié avec -e ansible_user=root ou variable atlas_bootstrap), puis basculer ansible_user sur atlsvc avec become: true et sudo limité ; désactiver ensuite PermitRootLogin sur les LXC.
- **Verdict verification** : confiance haute — Confirmé. develop/group_vars/all/vars.yaml:31 contient bien « ansible_user: root » (avec le commentaire cité), et develop/hosts.yaml:12 le répète pour Proxmox. ansible.cfg:9 définit remote_user = atlsvc, mais la précédence Ansible (inventaire/group_vars > config) fait que tous les plays s'exécutent en root SSH direct. Aucune mitigation : pas de play de bootstrap séparé ni de bascule vers atlsvc ; sshd_config.j2:12 garde PermitRootLogin prohibit-password (et même « yes » sur le bastion atlbst01p) ; le sudoers d'atlsvc (roles/common/tasks/users.yaml:39) ne permet que systemctl restart/reload, donc atlsvc ne peut pas exécuter les playbooks. Violation directe de la contrainte « moindre privilège, aucun compte admin par défaut conservé ». Sévérité haute justifiée (pas critique : auth par clé uniquement, réseau interne/bastion).

### haute-5. Vérification des clés d'hôte SSH totalement désactivée
- **Fichier** : `ansible.cfg` (ligne ~11) — categorie : securite — zone : orchestration
- **Description** : host_key_checking = False dans [defaults] et -o StrictHostKeyChecking=no dans ssh_args, doublés par les ansible_ssh_common_args de l'inventaire (y compris dans le ProxyCommand vers le bastion). Aucune authentification des hôtes : un MITM sur le chemin control-node → bastion → cibles permettrait d'intercepter les secrets (mots de passe DB poussés par les rôles).
- **Extrait** :
```
host_key_checking   = False
...
ssh_args            = -o ControlMaster=auto -o ControlPersist=60s -o StrictHostKeyChecking=no
```
- **Correctif propose** : Activer host_key_checking = True et provisionner les known_hosts au moment du provisioning LXC (récupération des clés d'hôte via l'API Proxmox ou ssh-keyscan contrôlé), ou utiliser StrictHostKeyChecking=accept-new au minimum.
- **Verdict verification** : confiance haute — Confirmé par lecture du code. ansible.cfg ligne 11 : `host_key_checking = False` et ligne 20 : `ssh_args = ... -o StrictHostKeyChecking=no`, exactement comme cité. Le problème est doublé dans develop/hosts.yaml (lignes 18, 29-30, 43-44, y compris dans le ProxyCommand vers le bastion 10.90.0.10) et étendu à d'autres fichiers non cités : pra_restore_full.yaml (l.130, 154), roles/bastion/templates/ssh_config.j2 (l.12) et les scripts de backup (backup_filestore.sh.j2, collect_dumps.sh.j2). Aucune mitigation trouvée : pas de provisionnement de known_hosts, pas de ssh-keyscan, pas de UserKnownHostsFile, pas de accept-new. Le control node ayant une IP publique (138.201.135.108, Hetzner), un MITM permettrait d'usurper bastion/cibles et de capter les secrets poussés par Ansible. Sévérité haute confirmée (pas critique : exige une position réseau d'interception, le trafic reste chiffré SSH).

### haute-6. Saut via le bastion effectué avec le compte root du bastion
- **Fichier** : `develop/hosts.yaml` (ligne ~30) — categorie : securite — zone : orchestration
- **Description** : Le ProxyCommand des groupes dmz et lan_admin se connecte au bastion en root (root@10.90.0.10). Le bastion, point de passage censé porter le contrôle d'accès, est traversé avec le compte le plus privilégié, ce qui contredit la règle « aucun compte administrateur par défaut conservé » et annule l'intérêt d'auditer les rebonds par compte nominatif/service.
- **Extrait** :
```
-o ProxyCommand="ssh -i /root/.ssh/atlas_ed25519 -o StrictHostKeyChecking=no -W %h:%p root@10.90.0.10"
```
- **Correctif propose** : Créer un compte de rebond non privilégié dédié sur le bastion (shell restreint, ForceCommand/AllowTcpForwarding limité aux cibles internes) et l'utiliser dans le ProxyCommand ; désactiver PermitRootLogin sur le bastion.
- **Verdict verification** : confiance haute — Constat confirmé. L'extrait cité existe textuellement aux lignes 30 et 44 de Atlas/develop/hosts.yaml : les groupes dmz et lan_admin utilisent ProxyCommand "ssh -i /root/.ssh/atlas_ed25519 ... -W %h:%p root@10.90.0.10" — rebond via le compte root du bastion. Aucune mitigation ailleurs : group_vars/all/vars.yaml fixe ansible_user: root globalement, et pire, roles/common/templates/sshd_config.j2 ligne 12 active explicitement "PermitRootLogin yes" pour le bastion atlbst01p (alors que les autres hôtes sont en prohibit-password), ce qui autorise même le login root par mot de passe sur le point de passage. Cela contredit directement la règle CLAUDE.md « aucun compte administrateur par défaut conservé » et le moindre privilège. Sévérité haute justifiée (surface limitée au MGMT VLAN 90, mais root par mot de passe possible sur le bastion).

### haute-7. rules.v4 écrasé intégralement : perte des règles hors gabarit au rechargement
- **Fichier** : `roles/proxmox_network/tasks/iptables_rules.yaml` (ligne ~26) — categorie : fiabilite — zone : proxmox
- **Description** : Le template remplace /etc/iptables/rules.v4 en totalité puis le handler exécute iptables-restore, qui purge les tables filter et nat. Toute règle existante non reproduite dans le template (règles PVE firewall, Docker, règles ajoutées par setup_vlan_routing.sh via iptables-save, autres NAT) est supprimée au premier run. Seul le NAT du lab 10.10.10.0/24 est préservé via proxmox_network_extra_nat_subnets.
- **Extrait** :
```
- name: "Déployer les règles iptables Atlas (/etc/iptables/rules.v4)"
  ansible.builtin.template:
    src: rules.v4.j2
    dest: /etc/iptables/rules.v4
  notify: Recharger les règles iptables
```
- **Correctif propose** : Soit rendre le template seule source de vérité documentée et y intégrer toutes les règles nécessaires de l'hôte, soit utiliser des chaînes dédiées (ATLAS-FORWARD, ATLAS-POSTROUTING) gérées par Ansible sans toucher au reste, avec validate sur iptables-restore --test.
- **Verdict verification** : confiance haute — Confirmé par le code : tasks/iptables_rules.yaml l.26-33 déploie rules.v4 en écrasement total sans validate ; le handler exécute « iptables-restore < /etc/iptables/rules.v4 » sans --noflush, purgeant filter et nat ; rules.v4.j2 ne reproduit que les règles Atlas + extra_nat_subnets (seul 10.10.10.0/24 NAT préservé, défini dans defaults/main.yaml dont le commentaire admet lui-même que « tout NAT préexistant doit y figurer »). Règles PVE firewall/Docker/filter tierces perdues au premier run, sur l'hyperviseur central. Aucune mitigation ailleurs ; sévérité haute confirmée.

### haute-8. ifreload -a sans validation préalable : risque de coupure réseau de l'hyperviseur
- **Fichier** : `roles/proxmox_network/handlers/main.yaml` (ligne ~6) — categorie : fiabilite — zone : proxmox
- **Description** : Le handler recharge toute la configuration réseau de l'hyperviseur distant après des modifications par lineinfile/template, sans aucune vérification syntaxique préalable. Une erreur dans /etc/network/interfaces ou atlas-vlans.cfg coupe le réseau du Proxmox (serveur Hetzner distant), rendant l'hôte injoignable — incident majeur incompatible avec le RTO de 40 min.
- **Extrait** :
```
- name: Recharger la configuration réseau
  ansible.builtin.command:
    cmd: ifreload -a
```
- **Correctif propose** : Exécuter d'abord « ifreload -a --syntax-check » (ifupdown2) et ne lancer ifreload -a que si la validation passe ; prévoir un garde-fou type rollback (ifreload -a -X ou tâche asynchrone avec wait_for_connection).
- **Verdict verification** : confiance haute — Confirmé. Le handler (roles/proxmox_network/handlers/main.yaml l.6-9) exécute bien « ifreload -a » via ansible.builtin.command sans aucune validation préalable ni garde-fou. Il est notifié par 4 tâches qui modifient /etc/network/interfaces (lineinfile dans tasks/vlan_bridge.yaml : bridge-vlan-aware, bridge-vids, source interfaces.d) et par le template atlas-vlans.cfg.j2 (tasks/vlan_interfaces.yaml). Aucune tâche du rôle ne fait de syntax-check (« ifreload -a -s »), pas de wait_for_connection ni de mécanisme de rollback ; seul un « backup: true » existe sur une seule des tâches lineinfile, inutile si l'hôte devient injoignable. Une config invalide (ex. variable proxmox_network_vlans erronée dans le template) couperait le réseau de l'hyperviseur Proxmox distant, incompatible avec le RTO de 40 min. Sévérité haute appropriée : risque conditionnel (nécessite une config erronée) mais impact majeur.

### haute-9. deploy_lxc.sh non idempotent : échec au second run (pct create + set -e)
- **Fichier** : `infra/proxmox_iac/deploy_lxc.sh` (ligne ~97) — categorie : idempotence — zone : proxmox
- **Description** : Aucun test d'existence du CT avant pct create. Au second lancement, pct create 101 échoue (« CT 101 already exists ») et set -euo pipefail interrompt le script avant les CT suivants. Le script viole sa propre promesse implicite de rejouabilité IaC.
- **Extrait** :
```
pct create "${ctid}" "${TEMPLATE}" \
```
- **Correctif propose** : Tester l'existence avant création : « if pct status "${ctid}" >/dev/null 2>&1; then log "CT ${ctid} existe déjà — ignoré"; return 0; fi » au début de create_ct.
- **Verdict verification** : confiance haute — Constat confirmé par lecture intégrale de C:/Users/BEDANI/Documents/Atlas/Atlas/infra/proxmox_iac/deploy_lxc.sh. Ligne 28 : `set -euo pipefail`. Ligne 97 : `pct create "${ctid}" "${TEMPLATE}" \` exactement comme cité. La fonction create_ct (l.88-129) ne contient aucun test d'existence (pas de `pct status`, `pct config` ni `pct list`), et aucun garde-fou n'existe ailleurs : les pré-checks (l.66-76) ne vérifient que la présence de `pct` et de la clé SSH. Au second run, `pct create 101` échoue (« CT 101 already exists ») et set -e arrête le script avant les CT 102/103 (appels séquentiels l.137-139). Aggravant : `pct set --protection 1` (l.124) du CT 101 ne serait même pas ré-exécuté. La sévérité « haute » est justifiée dans ce contexte PRA : une relance partielle pendant une reconstruction DR (RTO 40 min) laisserait l'infrastructure dans un état incohérent, et CLAUDE.md impose une méthodologie IaC dont la rejouabilité est une propriété attendue. Le correctif proposé (test `pct status` en tête de create_ct) est pertinent.

### haute-10. StrictHostKeyChecking no dans la config SSH cliente du bastion
- **Fichier** : `roles/bastion/templates/ssh_config.j2` (ligne ~12) — categorie : securite — zone : socle
- **Description** : La configuration cliente de root sur le bastion désactive la vérification des clés d'hôte pour TOUS les conteneurs Atlas, y compris ceux en DMZ (VLAN 20). Un hôte compromis ou usurpé (ARP spoofing dans la DMZ) permettrait une attaque man-in-the-middle interceptant la clé/les sessions d'administration sans aucune alerte.
- **Extrait** :
```
StrictHostKeyChecking no
```
- **Correctif propose** : Utiliser 'StrictHostKeyChecking accept-new' (TOFU) au minimum, ou pré-provisionner les clés d'hôte dans /root/.ssh/known_hosts via ansible.builtin.known_hosts.
- **Verdict verification** : confiance haute — Confirmé : ligne 12 de roles/bastion/templates/ssh_config.j2 contient bien « StrictHostKeyChecking no », appliqué en boucle à TOUS les hôtes de bastion_atlas_hosts (connexion root, clé /root/.ssh/atlas_ed25519), y compris ceux en DMZ. Aucun garde-fou ailleurs : grep sur tout le dépôt ne montre aucun module ansible.builtin.known_hosts ni pré-provisionnement de clés d'hôte ; au contraire le motif est systémique (ansible.cfg ligne 20, develop/hosts.yaml, roles/backup/templates/*.sh.j2, pra_restore_full.yaml). Le risque MITM sur les sessions d'administration root est réel ; sévérité haute justifiée (pas critique car exploitation requiert déjà une position réseau dans la DMZ/MGMT).

### haute-11. Dump horaire incompatible avec le RPO de 20 minutes
- **Fichier** : `roles/mariadb/tasks/backup_script.yaml` (ligne ~50) — categorie : pra — zone : donnees
- **Description** : Le dump GLPI est planifié toutes les heures (minute 30). En cas de perte de la base, jusqu'à ~60 minutes de données sont perdues, soit 3 fois l'objectif RPO <= 20 minutes du projet. Les journaux binaires (99-atlas-server.cnf) atténuent localement, mais ne suffisent pas si le conteneur lui-même est perdu (voir constat sur la copie distante).
- **Extrait** :
```
- name: Planifier le dump GLPI horaire (RPO)
  ansible.builtin.cron:
    name: "Dump GLPI horaire RPO"
    minute: "30"
    hour: "*"
```
- **Correctif propose** : Planifier le dump (ou au minimum un flush + copie des binlogs) toutes les 15 minutes : minute: "*/15", ou mettre en place une réplication/archivage continu des binlogs vers atlbkp01p.
- **Verdict verification** : confiance haute — Extrait exact confirmé dans roles/mariadb/tasks/backup_script.yaml (lignes 50-56) : cron "Dump GLPI horaire RPO" avec minute: "30", hour: "*", soit un dump par heure. Le RPO du CLAUDE.md est <= 20 min ; en cas de perte du conteneur juste avant le dump, la perte atteint ~60 min. Les binlogs (log_bin dans 99-atlas-server.cnf.j2, format ROW) restent locaux sur atldb01p : aucune copie distante des binlogs n'existe — collect_dumps.sh.j2 (rôle backup) ne rsynchronise que le répertoire des dumps, pas /var/log/mysql/mysql-bin*. Aucune variable, réplication ou autre mécanisme ne mitige le constat ailleurs dans le dépôt. Sévérité haute justifiée : violation directe et chiffrable d'un objectif contractuel du projet (RPO x3), sans être critique car des sauvegardes horaires + binlogs locaux existent.

### haute-12. Collision à 02h30 : la collecte rsync s'exécute pendant le dump horaire
- **Fichier** : `roles/backup/tasks/cron.yaml` (ligne ~11) — categorie : fiabilite — zone : donnees
- **Description** : Le dump GLPI horaire (rôle mariadb) s'exécute à HH:30, donc à 02h30, exactement au moment où collect_dumps.sh lance le rsync sur le même répertoire. rsync peut copier un fichier glpi_dump_*.sql.gz en cours d'écriture, produisant un dump distant tronqué/corrompu — c'est précisément le dump qui serait utilisé en PRA. Le commentaire du rôle mariadb (« décalé à :30 pour ne pas chevaucher le dump de 02h00 ») montre que cette collision n'a pas été vue.
- **Extrait** :
```
minute: "30"
    hour: "2"
    job: "{{ backup_scripts_dir }}/collect_dumps.sh"  # vs rôle mariadb : Dump GLPI horaire RPO minute "30" hour "*"
```
- **Correctif propose** : Décaler la collecte (ex. 02h45), faire écrire le dump dans un fichier temporaire puis mv atomique en fin de dump (renommage .part -> .sql.gz), et exclure *.part dans rsync.
- **Verdict verification** : confiance haute — Constat confirmé par le code. roles/backup/tasks/cron.yaml (l.11-13) planifie collect_dumps.sh à minute "30", hour "2" — l'extrait cité est exact. roles/mariadb/tasks/backup_script.yaml (l.53-54) planifie le dump GLPI horaire à minute "30", hour "*", donc il démarre aussi à 02h30. Aucune mitigation : dump_glpi.sh.j2 écrit directement via `mysqldump | gzip > glpi_dump_*.sql.gz` (l.37) sans fichier temporaire ni mv atomique (le flock ne protège que contre deux dumps simultanés, pas contre rsync) ; collect_dumps.sh fait `rsync -avz` sans aucun --exclude. rsync peut donc copier un .sql.gz en cours d'écriture et produire une copie distante tronquée — précisément le dump le plus récent, celui qui serait choisi en PRA, avec un risque d'échec de restauration (gzip tronqué). Sévérité haute justifiée (fiabilité PRA, RTO compromis si la restauration échoue sur le dump le plus récent). Correctif proposé pertinent.

### haute-13. Clé SSH de sauvegarde sans restriction command=/from= (shell complet)
- **Fichier** : `roles/backup/tasks/ssh_key.yaml` (ligne ~24) — categorie : securite — zone : donnees
- **Description** : La clé publique est autorisée pour atlsvc sur atlapp01p et atldb01p sans aucune option restrictive. La clé privée résidant sur atlbkp01p (root), sa compromission donne un shell interactif complet atlsvc sur les deux hôtes, alors que seul rsync en lecture est nécessaire. Non-respect du moindre privilège.
- **Extrait** :
```
ansible.builtin.authorized_key:
    user: "{{ backup_remote_user }}"
    key: "{{ backup_ssh_keypair.public_key }}"
    comment: "atlas-backup@atlbkp01p"
    state: present
```
- **Correctif propose** : Ajouter key_options: 'command="rsync --server --sender ..." (ou rrsync en lecture seule),from="10.30.0.13",no-pty,no-agent-forwarding,no-port-forwarding,no-X11-forwarding'.
- **Verdict verification** : confiance haute — Confirmé : roles/backup/tasks/ssh_key.yaml (l.24-33) autorise la clé via ansible.builtin.authorized_key sans aucun key_options (command=, from=, no-pty...), pour atlsvc sur atlapp01p et atldb01p ; un grep du dépôt ne trouve key_options nulle part. Le firewall UFW ouvre même le port 22 depuis backup_local_ip (l.38-47), donc la compromission de la clé privée (root@atlbkp01p) donne un shell interactif complet atlsvc sur les deux hôtes. Impact aggravé : atlsvc dispose de sudo NOPASSWD systemctl restart/reload (roles/common/tasks/users.yaml l.39) et d'un accès en écriture au filestore GLPI (pra_restore_full.yaml l.155 pousse vers /var/lib/glpi/files via cette clé — potentiel dépôt de webshell). Sévérité haute justifiée (pas critique : pas root direct, et l'accès suppose déjà la compromission du serveur de sauvegarde). Nuance sur le correctif : pra_restore_full.yaml utilise cette même clé en écriture (scp/rsync push), donc un command= strict en lecture seule casserait la restauration ; prévoir rrsync ou une clé PRA dédiée.

### haute-14. Tout le code GLPI appartient à www-data (moindre privilège violé)
- **Fichier** : `roles/glpi/tasks/download.yaml` (ligne ~71) — categorie : securite — zone : web
- **Description** : Le chown récursif www-data:www-data sur /var/www/glpi rend l'intégralité du code PHP modifiable par le processus web. Une compromission de l'application (RCE, plugin malveillant) permet de modifier le code et de persister. Seuls les répertoires de données ({{ glpi_data_dir }}) doivent être inscriptibles par www-data.
- **Extrait** :
```
- name: Appliquer les permissions www-data sur les répertoires GLPI
  ansible.builtin.file:
    path: "{{ item }}"
    ...
    recurse: true
  loop:
    - /var/www/glpi
    - "{{ glpi_data_dir }}"
```
- **Correctif propose** : Laisser /var/www/glpi en root:root (lecture seule pour www-data) et n'appliquer www-data que sur {{ glpi_data_dir }} (files, config, marketplace).
- **Verdict verification** : confiance haute — Confirmé dans roles/glpi/tasks/download.yaml lignes 71-80 : la tâche « Appliquer les permissions www-data sur les répertoires GLPI » fait un ansible.builtin.file owner=www-data group=www-data recurse=true sur /var/www/glpi ET {{ glpi_data_dir }}. Ironie : le playbook déplace bien files/config/marketplace hors du webroot (lignes 41-49) « pour la sécurité », mais le chown final annule ce bénéfice en rendant tout le code PHP inscriptible par le processus web. Aucune tâche ultérieure ne re-durcit /var/www/glpi en root:root (rien d'autre dans le rôle ne corrige cela). Le correctif proposé (root:root sur le code, www-data uniquement sur glpi_data_dir + inc/downstream.php si besoin) est conforme aux recommandations GLPI et au principe de moindre privilège du CLAUDE.md. Sévérité « haute » justifiée : c'est un vecteur de persistance post-RCE, mais pas une vulnérabilité directement exploitable seule (pas « critique »).

### haute-15. Mot de passe Admin Zabbix par défaut jamais changé
- **Fichier** : `roles/zabbix/tasks/register_hosts.yaml` (ligne ~11) — categorie : securite — zone : supervision
- **Description** : Le rôle se connecte à l'API avec le compte super-admin « Admin » et vault_zabbix_admin_password, mais aucune tâche ne modifie le mot de passe par défaut « zabbix » de ce compte après l'import du schéma. Deux cas : soit le vault contient « zabbix » (compte admin par défaut conservé, violation directe de la contrainte CLAUDE.md « aucun compte admin par défaut conservé »), soit le vault contient un autre mot de passe et le user.login échoue au premier run (le playbook casse). De plus le compte « guest » par défaut n'est pas désactivé.
- **Extrait** :
```
method: user.login
      params:
        username: Admin
        password: "{{ vault_zabbix_admin_password }}"
```
- **Correctif propose** : Après l'import du schéma, ajouter une tâche idempotente qui change le mot de passe Admin : tenter user.login avec vault_zabbix_admin_password ; en cas d'échec, se connecter avec « zabbix » puis appeler user.update (passwd) pour appliquer le mot de passe du vault. Désactiver aussi le compte « guest » via user.update (users_status=1).
- **Verdict verification** : confiance haute — Extrait exact présent (register_hosts.yaml l.18-21 : user.login avec username Admin et vault_zabbix_admin_password). Grep sur tout le dépôt : aucun appel user.update, aucune modification du mot de passe Admin Zabbix (seul vault_zabbix_db_password est géré dans database.yaml pour la BDD), aucune désactivation du compte guest. Le rôle ne peut donc fonctionner au premier run que si le vault contient le mot de passe par défaut « zabbix », ce qui viole la règle CLAUDE.md « aucun compte administrateur par défaut conservé » ; sinon le playbook échoue. Les no_log présents ne mitigent pas ce point. Sévérité haute justifiée (credentials par défaut sur la supervision, mais service a priori non exposé en DMZ publique, donc pas critique).

### haute-16. Import du schéma non atomique : un échec partiel rend le déploiement irrécupérable
- **Fichier** : `roles/zabbix/tasks/database.yaml` (ligne ~69) — categorie : fiabilite — zone : supervision
- **Description** : L'idempotence de l'import repose uniquement sur COUNT(*) des tables (skip si > 0). Si zcat|mysql échoue à mi-parcours (coupure réseau vers 10.30.0.10, timeout), des tables existent déjà : au 2e run l'import est sauté et Zabbix démarre sur un schéma incomplet, sans aucune erreur Ansible. De plus, en cas d'échec le play s'arrête avant la tâche de désactivation, laissant log_bin_trust_function_creators=1 en permanence sur atldb01p.
- **Extrait** :
```
when: zabbix_tables_count.stdout | int == 0
# ...
zcat /usr/share/zabbix-sql-scripts/mysql/server.sql.gz |
mysql -h 10.30.0.10 -u zabbix -p"$ZBX_DB_PASS" zabbix
```
- **Correctif propose** : Vérifier la complétude plutôt que la simple présence : tester l'existence d'une table de fin de schéma (ex. SELECT 1 FROM zabbix.dbversion) ou comparer le nombre de tables au nombre attendu ; en cas d'import partiel, DROP DATABASE puis ré-import. Encapsuler la désactivation de log_bin_trust_function_creators dans un block/always.
- **Verdict verification** : confiance haute — Confirmé par lecture de roles/zabbix/tasks/database.yaml. L'extrait cité est exact : l'import (lignes 69-79) et l'activation/désactivation de log_bin_trust_function_creators (lignes 62-65 et 81-84) sont tous gardés par `when: zabbix_tables_count.stdout | int == 0` (COUNT(*) sur information_schema.tables, lignes 50-56). Aucun block/rescue/always, aucun handler ni garde-fou ailleurs dans le rôle. Le `set -o pipefail` détecte bien l'échec au 1er run, mais si zcat|mysql échoue à mi-parcours, des tables existent déjà : au 2e run le count est > 0, l'import est sauté silencieusement et le schéma reste incomplet. De même, en cas d'échec le play s'arrête avant la tâche ligne 81, laissant log_bin_trust_function_creators=1 en permanence sur atldb01p. Sévérité haute justifiée : panne silencieuse non récupérable sans intervention manuelle, mais ne survient qu'en cas d'échec à mi-import (pas systématique), donc pas critique.

### haute-17. Compte administrateur Zabbix par défaut « Admin » conservé et utilisé par l'automatisation
- **Fichier** : `roles/zabbix/tasks/register_hosts.yaml` (ligne ~20) — categorie : securite — zone : secrets
- **Description** : L'automatisation s'authentifie avec le compte par défaut « Admin ». Aucune tâche ne change son mot de passe initial (« zabbix », documenté dans README.md ligne 114) ni ne désactive le compte « guest » : au premier run, vault_zabbix_admin_password doit donc valoir « zabbix » pour que le rôle fonctionne, et le changement est laissé à une action manuelle (README : « Changez les mots de passe par défaut dès la première connexion »). Cela viole la règle « aucun compte admin par défaut conservé » et la règle « aucun clic-clic manuel non tracé ».
- **Extrait** :
```
params:
        username: Admin
        password: "{{ vault_zabbix_admin_password }}"
```
- **Correctif propose** : Ajouter une tâche idempotente qui, via l'API (user.update), force le mot de passe d'Admin à vault_zabbix_admin_password (login d'abord avec « zabbix », repli sur la valeur vault), désactive le compte guest, et idéalement créer un compte d'automatisation dédié à privilèges restreints au lieu d'utiliser Admin.
- **Verdict verification** : confiance haute — Constat confirmé. L'extrait cité existe textuellement (roles/zabbix/tasks/register_hosts.yaml lignes 20-21 : « username: Admin / password: {{ vault_zabbix_admin_password }} »). Une recherche exhaustive du dépôt ne trouve aucun appel user.update, aucune tâche changeant le mot de passe Admin ni désactivant le compte guest : la seule mitigation est manuelle (provision_zabbix.sh ligne 237 « change the Admin password IMMEDIATELY: Administration → Users → Admin → Change password » et README.md ligne 114 documentant « Admin / zabbix »). Le rôle Grafana (provisioning_datasource.yaml.j2 lignes 16-19) utilise aussi ce même compte Admin comme compte de service, confirmant l'absence de compte d'automatisation à moindre privilège. Cela viole bien les règles CLAUDE.md « aucun compte admin par défaut conservé » et « aucun clic-clic manuel non tracé ». Atténuants pris en compte (Zabbix accessible uniquement depuis le LAN_ADMIN VLAN 30, no_log présent sur toutes les tâches) : ils justifient de ne pas monter à « critique », mais le mot de passe par défaut requis au premier run et l'usage du super-admin par l'automatisation maintiennent la sévérité « haute ».

### haute-18. Comptes GLPI par défaut (glpi/glpi) jamais supprimés ni changés par le code
- **Fichier** : `README.md` (ligne ~113) — categorie : securite — zone : secrets
- **Description** : Le README documente l'accès GLPI avec le compte par défaut glpi/glpi, et aucun rôle (glpi, glpi_seed) ne supprime ou ne change les comptes par défaut de GLPI (glpi, post-only, tech, normal). Pire, glpi_seed pose le jeton API sur ce compte super-admin par défaut (api_enable.yaml : UPDATE glpi_users SET api_token=... WHERE name='glpi'), pérennisant son usage. Violation directe de « aucun compte administrateur par défaut ne doit être conservé ».
- **Extrait** :
```
| GLPI | ... | `glpi` / `glpi` |
```
- **Correctif propose** : Ajouter dans le rôle glpi_seed des tâches idempotentes qui changent le mot de passe du compte glpi (valeur vault) et suppriment/désactivent post-only, tech et normal ; faire porter le jeton API par un compte de service dédié au profil API minimal.
- **Verdict verification** : confiance haute — Confirmé. README.md ligne 113 documente bien l'accès avec `glpi` / `glpi`. roles/glpi_seed/tasks/api_enable.yaml ligne 42 exécute « UPDATE glpi_users SET api_token='{{ vault_glpi_api_token }}' WHERE name='glpi' », fixant le jeton API sur le super-admin par défaut. Une recherche sur l'ensemble des rôles glpi et glpi_seed ne montre aucune tâche changeant le mot de passe du compte glpi ni supprimant/désactivant post-only, tech ou normal (seul seed_glpi.py.j2 crée des utilisateurs supplémentaires). Violation directe de la contrainte « aucun compte admin par défaut conservé ». Sévérité haute justifiée : l'exposition est atténuée par l'accès via tunnel SSH/DMZ, sinon ce serait critique.

### haute-19. Deux sources de vérité divergentes : nginx.conf statique vs rôle Ansible reverse_proxy
- **Fichier** : `infra/dmz_vlan20/nginx.conf` (ligne ~153) — categorie : fiabilite — zone : infra-dmz
- **Description** : Le nginx.conf statique de infra/ pointe vers un backend 10.30.0.10:80 avec server_name helpdesk.atlas.internal, alors que le rôle Ansible reverse_proxy (la source utilisée par site.yaml et le PRA) définit reverse_proxy_backend_ip: "10.20.0.11" et reverse_proxy_server_name: "atlas.internal" (roles/reverse_proxy/defaults/main.yaml). De plus l'architecture diverge : le README/rôles placent GLPI dans la DMZ (atlapp01p, 10.20.0.11) et MariaDB en 10.30.0.10, tandis que le nginx.conf statique proxifie directement vers 10.30.0.10 — c'est-à-dire vers l'IP de la base de données dans l'architecture réelle. Quiconque déploie infra/ obtient un proxy cassé et un nom TLS incohérent.
- **Extrait** :
```
proxy_pass http://10.30.0.10:80;  /  server_name helpdesk.atlas.internal;  — vs roles/reverse_proxy/defaults/main.yaml : reverse_proxy_backend_ip: "10.20.0.11", reverse_proxy_server_name: "atlas.internal"
```
- **Correctif propose** : Supprimer le répertoire infra/ (ou le déplacer dans docs/archive avec un avertissement explicite 'OBSOLÈTE — la source de vérité est roles/reverse_proxy'). Une seule source de vérité IaC doit subsister.
- **Verdict verification** : confiance haute — Constat confirmé par lecture intégrale du code. infra/dmz_vlan20/nginx.conf contient bien `proxy_pass http://10.30.0.10:80;` (ligne 153) et `server_name helpdesk.atlas.internal;` (ligne 77), tandis que roles/reverse_proxy/defaults/main.yaml définit `reverse_proxy_backend_ip: "10.20.0.11"` et `reverse_proxy_server_name: "atlas.internal"`. Dans l'architecture réellement déployée par Ansible, 10.30.0.10 est l'IP de MariaDB (roles/mariadb/defaults/main.yaml : `mariadb_bind_address: "10.30.0.10"`; README : atldb01p=10.30.0.10, atlapp01p GLPI=10.20.0.11) — le nginx statique proxifie donc vers la base de données, pas vers GLPI. Aucune mitigation trouvée : pas de variable surchargée ni d'avertissement d'obsolescence; au contraire docs/DAT.md (lignes 222-273) référence infra/ comme procédure officielle de déploiement, et infra/ introduit même une 3e adresse divergente (provision_glpi.sh : CT 102 = 10.30.0.102). Trois sources de vérité contradictoires, dont une documentée comme officielle qui produit un proxy cassé : sévérité haute justifiée en fiabilité.

### haute-20. CTID/IP des scripts infra/ en conflit total avec l'inventaire Ansible
- **Fichier** : `infra/dmz_vlan20/provision_nginx.sh` (ligne ~42) — categorie : fiabilite — zone : infra-dmz
- **Description** : Les trois scripts de provisioning utilisent CTID=101/102/103 et les IP 10.20.0.101, 10.30.0.102, 10.30.0.103, alors que le README et les rôles Ansible définissent les VMID 200-208 et les IP 10.20.0.10 (atlrp01p), 10.20.0.11 (atlapp01p), 10.30.0.10 (atldb01p), 10.30.0.12 (atlzbx01p). Exécuter ces scripts sur la maquette réelle échouerait (CT inexistants) ou, pire, provisionnerait des conteneurs parallèles hors supervision/sauvegarde/PRA. L'architecture applicative diverge aussi : provision_glpi.sh installe GLPI+MariaDB colocalisés sous Apache dans le VLAN 30, alors que les rôles déploient GLPI sous Nginx+PHP-FPM en DMZ et MariaDB séparée. Le PRA (pra_restore_full.yaml) ne reconstruirait jamais ce que ces scripts installent : RTO/RPO non garantis pour cette voie de déploiement.
- **Extrait** :
```
CTID=101 ... CT_IP="10.20.0.101" (provision_nginx.sh) ; CTID=102 ... CT_IP="10.30.0.102" (provision_glpi.sh) ; CTID=103 ... CT_IP="10.30.0.103" (provision_zabbix.sh) — vs README : atlrp01p VMID 201 10.20.0.10, atldb01p 203 10.30.0.10, atlzbx01p 205 10.30.0.12
```
- **Correctif propose** : Supprimer les scripts infra/*.sh (doublons d'une itération antérieure) ou les aligner sur l'inventaire develop/hosts.yaml. Conserver uniquement la chaîne Ansible comme source de vérité pour respecter le RTO.
- **Verdict verification** : confiance haute — Constat confirmé par lecture du code. provision_nginx.sh ligne 42 contient bien CTID=101 et CT_IP="10.20.0.101" ; provision_glpi.sh : CTID=102, CT_IP="10.30.0.102", hostname "glpi-mariadb" avec installation LAMP colocalisée (mariadb-server + apache2 + GLPI dans le même CT, VLAN 30) ; provision_zabbix.sh : CTID=103. infra/proxmox_iac/deploy_lxc.sh crée précisément les CT 101/102/103 (10.20.0.101, 10.30.0.102, 10.30.0.103) : la chaîne infra/ est donc cohérente en interne, mais constitue une voie de déploiement parallèle totalement déconnectée de la source de vérité Ansible. L'inventaire develop/hosts.yaml utilise 10.20.0.10/10.20.0.11/10.30.0.10/10.30.0.12 et le README les VMID 201/203/205 ; aucun fichier YAML du dépôt ne référence les IP 10.20.0.101/10.30.0.102/10.30.0.103. Une nuance par rapport au constat : si deploy_lxc.sh est exécuté d'abord, les scripts ne « échouent » pas — c'est le second scénario (conteneurs parallèles hors supervision/sauvegarde/PRA, architecture GLPI+MariaDB colocalisée sous Apache que pra_restore_full.yaml ne reconstruirait pas) qui se réalise. La sévérité haute est justifiée au vu des contraintes RPO 20 min / RTO 40 min : deux sources de vérité contradictoires dans un dépôt IaC compromettent la fiabilité du PRA.

### haute-21. AllowUsers inclut root sur le bastion et aucune restriction du forwarding
- **Fichier** : `roles/bastion/templates/sshd_bastion.conf.j2` (ligne ~7) — categorie : securite — zone : socle
- **Description** : Même si le drop-in était chargé (cf. bug Include), il autorise explicitement root en SSH sur le bastion, et ne restreint pas AllowTcpForwarding (hérité 'yes' du common sans PermitOpen). Le bastion devrait limiter les destinations de forwarding aux conteneurs Atlas (port 22) et interdire la connexion root directe au profit d'atlsvc.
- **Extrait** :
```
AllowUsers atlsvc root
```
- **Correctif propose** : Retirer root d'AllowUsers et ajouter sur le bastion : 'PermitOpen 10.20.0.0/24:22 10.30.0.0/24:22' (ou liste explicite des hôtes), X11Forwarding no, AllowAgentForwarding no.
- **Verdict verification** : confiance haute — Confirmé par le code. roles/bastion/templates/sshd_bastion.conf.j2 ligne 7 contient exactement « AllowUsers atlsvc root », et aucune directive PermitOpen, AllowTcpForwarding, X11Forwarding ou AllowAgentForwarding n'existe dans le rôle bastion. Pire : roles/common/templates/sshd_config.j2 ligne 12 fait « PermitRootLogin {{ 'yes' if inventory_hostname == 'atlbst01p' else 'prohibit-password' }} » — donc root est explicitement autorisé en SSH (y compris par mot de passe) précisément sur le bastion, et la ligne 21 fixe « AllowTcpForwarding yes » sans restriction PermitOpen. Aucune mitigation ailleurs. Cela viole la règle CLAUDE.md « aucun compte administrateur par défaut conservé / moindre privilège » sur le point d'entrée le plus exposé. La sévérité doit être relevée à haute : root + mot de passe autorisé sur le bastion combiné à un forwarding TCP illimité vers les VLAN 20/30.

## Severite : moyenne (34)

### moyenne-1. Mot de passe DB passé en argument de mysqldump (visible dans ps)
- **Fichier** : `scripts_pra/backup/dump_mariadb.sh` (ligne ~65) — categorie : securite — zone : pra
- **Description** : --password="${DB_PASSWORD}" expose le mot de passe dans la liste des processus (/proc, ps aux) pendant toute la durée du dump (toutes les 15 minutes). Tout utilisateur local peut le lire.
- **Extrait** :
```
mysqldump \
    --user="${DB_USER}" \
    --password="${DB_PASSWORD}" \
```
- **Correctif propose** : Utiliser un fichier d'options : mysqldump --defaults-extra-file=/etc/glpi_backup.my.cnf (chmod 600, owner glpi_backup) contenant [client] user/password, ou exporter MYSQL_PWD (moins bon mais invisible dans ps).
- **Verdict verification** : confiance haute — Confirmé : lignes 63-65 de scripts_pra/backup/dump_mariadb.sh contiennent bien `mysqldump --user="${DB_USER}" --password="${DB_PASSWORD}"`, exécuté toutes les 15 minutes (cron */15, ligne 8). Aucune mitigation ailleurs : pas de --defaults-extra-file, pas de MYSQL_PWD, le script source /.env puis passe le secret en argv. Le problème est réel (CWE-214). Sévérité ajustée à moyenne plutôt que haute : les clients MySQL/MariaDB récents masquent le mot de passe dans argv juste après le démarrage (visible "mysqldump -p x xxxxx" dans ps), ne laissant qu'une courte fenêtre de course ; de plus le conteneur LXC DB n'a en principe que des comptes de service, limitant les utilisateurs locaux non privilégiés capables de lire /proc. Le correctif proposé (--defaults-extra-file chmod 600) reste pertinent.

### moyenne-2. --password "" ne désactive pas l'authentification root
- **Fichier** : `infra/proxmox_iac/deploy_lxc.sh` (ligne ~112) — categorie : securite — zone : proxmox
- **Description** : Le commentaire affirme que le mot de passe root est « désactivé », mais passer une chaîne vide à pct create --password ne verrouille pas le compte : selon la version PVE, soit la commande échoue (mot de passe trop court), soit le compte root du conteneur se retrouve avec un mot de passe vide — exploitable via la console Proxmox (pct enter / login console). Contradiction avec la règle « aucun compte admin par défaut conservé ».
- **Extrait** :
```
--password       "" \
`# --password "": root password is explicitly disabled.`
```
- **Correctif propose** : Omettre complètement l'option --password (compte alors verrouillé « ! » par défaut) ou exécuter « pct exec ${ctid} -- passwd -l root » après création.
- **Verdict verification** : confiance haute — Constat confirmé : la ligne 112 de deploy_lxc.sh contient bien `--password ""` avec le commentaire erroné « root password is explicitly disabled », et aucune mitigation ailleurs (pas de passwd -l, pas de surcharge ; pct set ne fait que --protection 1). `pct create --password ""` ne verrouille pas root : l'API PVE exige >=5 caractères (la commande échoue alors, et avec `set -euo pipefail` tout le script s'arrête — bug fonctionnel) ou, à défaut, laisse un mot de passe vide au lieu du verrou `!` obtenu en omettant l'option. Sévérité abaissée à moyenne : l'exploitation suppose déjà un accès console Proxmox (pct enter passe de toute façon) et sshd refuse les mots de passe vides par défaut ; l'impact dominant est la rupture du déploiement et la non-conformité à la règle « aucun compte admin par défaut ».

### moyenne-3. PermitRootLogin yes sur le bastion, point d'entrée le plus exposé
- **Fichier** : `roles/common/templates/sshd_config.j2` (ligne ~12) — categorie : securite — zone : socle
- **Description** : Le template fixe 'PermitRootLogin yes' précisément sur atlbst01p, le bastion, alors que c'est l'hôte le plus exposé. La logique est inversée par rapport au commentaire : c'est sur les hôtes internes qu'on a besoin de root par clé (prohibit-password), et le bastion devrait être le plus restrictif. 'yes' autorise root par mot de passe (atténué par PasswordAuthentication no, mais une dérive future de cette ligne ou un drop-in réactiverait l'accès root par mot de passe). Contraire au principe de moindre privilège du projet.
- **Extrait** :
```
PermitRootLogin {{ 'yes' if inventory_hostname == 'atlbst01p' else 'prohibit-password' }}
```
- **Correctif propose** : Utiliser 'prohibit-password' partout (PermitRootLogin prohibit-password), voire 'no' sur le bastion en passant par atlsvc + sudo.
- **Verdict verification** : confiance haute — Confirmé : ligne 12 de roles/common/templates/sshd_config.j2 contient exactement "PermitRootLogin {{ 'yes' if inventory_hostname == 'atlbst01p' else 'prohibit-password' }}", et atlbst01p est bien le bastion (README, proxmox_provision defaults, point d'entrée admin unique). Aucune surcharge ni autre gestion ailleurs dans le dépôt. La logique est inversée : 'yes' sur l'hôte le plus exposé, contraire au moindre privilège (CLAUDE.md). Sévérité abaissée de haute à moyenne car "PasswordAuthentication no" (ligne 13 du même template) rend 'yes' fonctionnellement équivalent à 'prohibit-password' aujourd'hui : pas d'accès root par mot de passe exploitable, le risque est une perte de défense en profondeur et de dérive future.

### moyenne-4. Rétention « 7 dumps » = 7 heures d'historique local avec le dump horaire
- **Fichier** : `roles/mariadb/defaults/main.yaml` (ligne ~13) — categorie : pra — zone : donnees
- **Description** : La rotation conserve les 7 derniers fichiers (ls -t | tail -n +$((RETENTION+1)) | xargs rm). Avec un dump toutes les heures, il ne reste que ~7 heures d'historique sur atldb01p. La collecte distante quotidienne à 02h30 ne récupère donc que les dumps des 7 dernières heures ; la rétention de 7 jours visée côté backup ne porte que sur ce sous-ensemble. Tout incident détecté tardivement (corruption, suppression de données) ne sera pas restaurable depuis le serveur DB.
- **Extrait** :
```
# ─── Nombre de dumps conservés (rotation) ───
mariadb_backup_retention: 7
```
- **Correctif propose** : Exprimer la rétention en jours et adapter le script (find -mtime), ou porter mariadb_backup_retention à un nombre cohérent avec la fréquence horaire (ex. 48-168).
- **Verdict verification** : confiance haute — Confirmé : mariadb_backup_retention: 7 (defaults/main.yaml:13, aucune surcharge) avec rotation par nombre de fichiers (dump_glpi.sh.j2:57 « ls -t | tail -n +$((RETENTION+1)) | xargs -r rm -f ») et cron horaire (backup_script.yaml, minute 30 hour "*") → ~7 h d'historique local seulement. Cependant la collecte rsync de 02h30 (backup/tasks/cron.yaml) sans --delete capture le dump quotidien de 02h00 et le conserve 7 jours sur atlbkp01p (find -mtime +7), donc un point de restauration quotidien sur 7 jours subsiste. L'impact réel est la perte de la granularité horaire hors fenêtre de collecte, pas l'impossibilité totale de restauration tardive : sévérité ramenée à moyenne.

### moyenne-5. Archive GLPI téléchargée sans vérification de checksum
- **Fichier** : `roles/glpi/defaults/main.yaml` (ligne ~11) — categorie : securite — zone : web
- **Description** : glpi_checksum est vide par défaut et download.yaml omet alors complètement le paramètre checksum de get_url : l'archive applicative est installée sans aucune vérification d'intégrité, et rien ne force l'échec si la variable reste vide.
- **Extrait** :
```
glpi_checksum: ""  …  checksum: "{{ ('sha256:' + glpi_checksum) if glpi_checksum | length > 0 else omit }}"
```
- **Correctif propose** : Renseigner le SHA-256 officiel de la release 10.0.16 dans defaults, et ajouter une assertion (ansible.builtin.assert) qui fait échouer le rôle si glpi_checksum est vide.
- **Verdict verification** : confiance haute — Confirmé par lecture du code : roles/glpi/defaults/main.yaml ligne 11 contient bien `glpi_checksum: ""` et roles/glpi/tasks/download.yaml ligne 26 omet le paramètre checksum si la variable est vide (`... else omit`). Un grep sur tout le dépôt ne montre aucune surcharge (group_vars/host_vars/inventaire) ni aucun ansible.builtin.assert : par défaut l'archive GLPI est téléchargée et extraite dans le webroot sans aucune vérification d'intégrité. Sévérité ajustée à moyenne plutôt que haute : le téléchargement se fait en HTTPS depuis les releases GitHub officielles (TLS protège contre un MITM classique), le risque résiduel est une compromission de la release amont ou du compte GitHub — réel mais moins direct qu'une exécution non chiffrée. Le correctif proposé (pinner le SHA-256 + assert si vide) est pertinent.

### moyenne-6. chaos.sh sans garde-fou de ciblage : risque d'arrêt de services de production
- **Fichier** : `roles/testlab/templates/chaos.sh.j2` (ligne ~50) — categorie : fiabilite — zone : supervision
- **Description** : Le script lancé en root par cron arrête nginx (incident_service) et remplit le disque, sans aucune vérification qu'il s'exécute bien sur l'hôte de lab (atltst01p). Or nginx est aussi le composant critique du reverse proxy (atlrp01p) et du frontend Zabbix (atlzbx01p). Si le rôle testlab est appliqué par erreur à un autre hôte (faute de frappe dans l'inventaire, hosts: trop large), le cron déclenchera toutes les 2 h des pannes réelles en production, compromettant directement le RTO de 40 min.
- **Extrait** :
```
incident_service() {
    systemctl stop nginx
    log "INCIDENT DÉCLENCHÉ : service (nginx arrêté)"
}
```
- **Correctif propose** : Ajouter en tête de script un garde-fou : [[ "$(hostname -s)" == "atltst01p" ]] || { echo "REFUS : hôte non-lab" >&2; exit 1; } (ou rendre le nom attendu paramétrable via une variable Ansible) ; ajouter aussi une assertion dans tasks/main.yaml (assert inventory_hostname == 'atltst01p').
- **Verdict verification** : confiance haute — Constat factuellement confirmé. L'extrait cité existe à l'identique (roles/testlab/templates/chaos.sh.j2, lignes 50-53 : `incident_service() { systemctl stop nginx ... }`). Le script ne contient aucune vérification d'hôte (aucun `hostname`, aucune variable de garde), et roles/testlab/tasks/ ne contient aucun `assert` ni condition sur inventory_hostname (grep "assert|atltst" dans le rôle : 0 résultat). cron.yaml planifie bien `/opt/atlas/scripts/chaos.sh run` en root toutes les 2 h avec `testlab_cron_enabled: true` par défaut. Le ciblage repose uniquement sur `hosts: atltst01p` dans site.yaml (ligne 105), qui est correct aujourd'hui — le risque est donc conditionnel à une erreur humaine (inventaire/hosts élargi, --limit erroné), pas un défaut actif. De plus le cron de réparation à la minute 45 redémarre nginx automatiquement, limitant la durée d'une panne accidentelle à ~45 min. Défaut réel de défense en profondeur, mais sévérité « haute » exagérée : je la ramène à « moyenne ».

### moyenne-7. Mot de passe DB passé en argument de ligne de commande (visible dans ps)
- **Fichier** : `infra/lan_admin_vlan30/provision_zabbix.sh` (ligne ~163) — categorie : securite — zone : infra-dmz
- **Description** : Le mot de passe Zabbix est interpolé dans la ligne de commande mysql (-p${ZABBIX_DB_PASSWORD}) exécutée via pct exec. Il apparaît en clair dans la liste des processus (ps/proc) à la fois sur l'hôte Proxmox (argv de pct exec) et dans le conteneur (argv de mysql), ainsi que potentiellement dans les journaux/audit. Même problème pour les sed des lignes 175-186 dont l'argv contient DBPassword=<secret>, et pour le heredoc SQL de provision_glpi.sh ligne 120-127 dont tout le contenu (CREATE USER ... IDENTIFIED BY '<secret>') est passé en argument à bash -c.
- **Extrait** :
```
zcat /usr/share/zabbix/sql-scripts/mysql/server.sql.gz | mysql -u${ZABBIX_DB_USER} -p${ZABBIX_DB_PASSWORD} ${ZABBIX_DB_NAME}
```
- **Correctif propose** : Passer le mot de passe via un fichier d'options temporaire chmod 600 ([client] password=...) poussé par pct push puis supprimé, ou via la variable d'environnement MYSQL_PWD à l'intérieur du conteneur, jamais en argv.
- **Verdict verification** : confiance haute — Confirmé par lecture du code : provision_zabbix.sh ligne 163 contient exactement « mysql -u${ZABBIX_DB_USER} -p${ZABBIX_DB_PASSWORD} » dans une chaîne bash -c passée à pct exec ; lignes 184-186, le sed reçoit « DBPassword=${ZABBIX_DB_PASSWORD} » en argv ; lignes 151-158, le heredoc SQL avec IDENTIFIED BY '<secret>' fait partie de l'argument bash -c (idem provision_glpi.sh ligne 123). Le secret est donc visible dans /proc/<pid>/cmdline sur l'hôte Proxmox et dans le conteneur. Aucune mitigation (pas de MYSQL_PWD, pas de fichier d'options, pas de pct push). Sévérité ramenée à « moyenne » : exposition transitoire nécessitant un accès local à l'hôte (généralement déjà root) ou au conteneur pendant le provisioning.

### moyenne-8. Aucune gestion d'échec inter-plays (any_errors_fatal/dépendances)
- **Fichier** : `site.yaml` (ligne ~0) — categorie : fiabilite — zone : orchestration
- **Description** : site.yaml enchaîne 14 plays dépendants (provisioning → common → mariadb → glpi → reverse_proxy → zabbix → agents) sans any_errors_fatal, max_fail_percentage ni vérification de précondition. Si le play mariadb échoue, Ansible continue et exécute quand même les plays smtp, glpi, reverse_proxy, etc. : GLPI sera installé/démarré sans base fonctionnelle, et glpi_seed tentera d'appeler une API inexistante. En contexte PRA (RTO 40 min), cela produit une reconstruction partiellement cassée difficile à diagnostiquer.
- **Extrait** :
```
- name: "Configuration du serveur MariaDB"
  hosts: atldb01p
  gather_facts: true
  roles:
    - role: mariadb
      tags: [mariadb]
```
- **Correctif propose** : Ajouter any_errors_fatal: true sur les plays critiques (proxmox_provision, common, mariadb, glpi, reverse_proxy) et/ou des pre_tasks de vérification (wait_for sur le port 3306 de atldb01p avant le play glpi).
- **Verdict verification** : confiance haute — Confirmé. L'extrait cité existe (site.yaml lignes 42-47) et le fichier enchaîne bien 14 plays, chacun ciblant un hôte différent, sans aucun any_errors_fatal, max_fail_percentage ni pre_tasks de vérification (grep sur tout le dépôt : aucune occurrence d'any_errors_fatal). Point clé : comme les plays ciblent des hôtes distincts, le mécanisme natif d'Ansible (retrait de l'hôte en échec) ne protège pas — un échec du play mariadb sur atldb01p n'empêche pas l'exécution des plays glpi (atlapp01p), reverse_proxy, etc. Le rôle glpi ne contient aucun wait_for/assert sur le port 3306 (seul roles/glpi/tasks/php.yaml mentionne mysql comme paquet). Le playbook de PRA dédié pra_restore_full.yaml souffre du même défaut (un seul wait_for ligne 200, aucun any_errors_fatal), ce qui valide aussi l'argument RTO. Sévérité moyenne appropriée : impact fiabilité/diagnostic réel mais pas de faille sécurité ni perte de données.

### moyenne-9. Configuration figée sur une exécution en root depuis pve01 (pas de PRA du control node)
- **Fichier** : `ansible.cfg` (ligne ~10) — categorie : fiabilite — zone : orchestration
- **Description** : private_key_file = /root/.ssh/atlas_ed25519 et le commentaire « Control node : pve01 » lient l'exécution d'Ansible au compte root de l'hyperviseur lui-même. Les chemins absolus /root/.ssh/... sont aussi codés en dur dans les ProxyCommand de l'inventaire. Si pve01 est l'hôte sinistré (scénario PRA nominal), le playbook de reconstruction n'est exécutable nulle part ailleurs sans réécrire config et inventaire, ce qui menace le RTO de 40 minutes. C'est aussi une exécution du control node en root, non nécessaire.
- **Extrait** :
```
private_key_file    = /root/.ssh/atlas_ed25519
```
- **Correctif propose** : Paramétrer le chemin de clé via une variable (ansible_ssh_private_key_file: "{{ atlas_ssh_key | default(lookup('env','ATLAS_SSH_KEY')) }}") et documenter/outiller un control node de secours hors de l'hyperviseur protégé.
- **Verdict verification** : confiance haute — Constat confirmé par lecture du code. ansible.cfg ligne 10 contient bien « private_key_file    = /root/.ssh/atlas_ed25519 » et la ligne 3 « # Control node : pve01 (138.201.135.108) ». Les chemins root sont aussi codés en dur dans develop/hosts.yaml (lignes 13, 30, 44 : ProxyCommand="ssh -i /root/.ssh/atlas_ed25519 ... root@10.90.0.10"), dans pra_restore_full.yaml (lignes 130, 154 : /root/.ssh/atlas_backup_ed25519) et roles/backup/vars/main.yaml. Aucune variable d'environnement, defaults surchargeables ni control node de secours documenté : le README confirme au contraire que le déploiement et le PRA s'exécutent « sur pve01 » en root avec la clé /root/.ssh/atlas_ed25519. Le ProxyJump passe par root@10.90.0.10 (pve01 lui-même) : si pve01 est sinistré, la reconstruction exige de réécrire ansible.cfg, l'inventaire et le playbook PRA, ce qui menace le RTO de 40 min ; l'exécution en root contredit aussi le moindre privilège. Sévérité « moyenne » appropriée (risque conditionnel au scénario sinistre du control node, pas une faille immédiate).

### moyenne-10. StrictHostKeyChecking=no sur les transferts de restauration
- **Fichier** : `pra_restore_full.yaml` (ligne ~130) — categorie : securite — zone : pra
- **Description** : Les deux rsync PRA désactivent la vérification de clé d'hôte SSH, exposant le dump de la base et le filestore à une attaque MITM précisément pendant un scénario de crise (hôtes reconstruits).
- **Extrait** :
```
-e "ssh -i /root/.ssh/atlas_backup_ed25519 -o StrictHostKeyChecking=no"
```
- **Correctif propose** : Utiliser StrictHostKeyChecking=accept-new ou pré-provisionner les known_hosts (module ansible.builtin.known_hosts) lors du reprovisioning des LXC.
- **Verdict verification** : confiance haute — Constat confirmé. L'extrait cité existe textuellement aux lignes 130 et 154 de C:/Users/BEDANI/Documents/Atlas/Atlas/pra_restore_full.yaml : les deux rsync (dump SQL vers atlsvc@10.30.0.10 et filestore vers atlsvc@10.20.0.11) passent `-o StrictHostKeyChecking=no`. Aucune mitigation ailleurs : grep sur tout le dépôt ne montre aucun usage de ansible.builtin.known_hosts ni de pré-provisionnement de known_hosts ; au contraire, le motif est généralisé (ansible.cfg, develop/hosts.yaml, roles/bastion/templates/ssh_config.j2, roles/backup/templates/collect_dumps.sh.j2 et backup_filestore.sh.j2). Le no_log:true ligne 143 ne couvre que l'import mysql, pas les transferts. Le risque MITM sur le dump de la base et le filestore pendant un PRA est réel, atténué seulement par le fait que les flux restent sur des VLAN internes (10.20/10.30) avec authentification par clé. Sévérité moyenne justifiée, ni exagérée ni sous-estimée.

### moyenne-11. Aucun any_errors_fatal ni block/rescue dans les playbooks PRA
- **Fichier** : `pra_restore_full.yaml` (ligne ~0) — categorie : fiabilite — zone : pra
- **Description** : Aucune gestion d'erreur structurée : pas de any_errors_fatal sur les plays multi-hôtes (common, zabbix_agent), pas de block/rescue autour de la restauration des données. Si un hôte du groupe échoue en config de base, les plays suivants continuent sur les autres et on obtient une plateforme partiellement restaurée sans signal clair ; en cas d'échec au milieu de la restauration DB, le dump temporaire et l'état intermédiaire ne sont pas nettoyés ni journalisés (le log ne reçoit jamais de ligne FIN/ÉCHEC).
- **Extrait** :
```
- name: "PRA — Configuration de base (common)"
  hosts: mgmt:dmz:lan_admin
  gather_facts: true
  roles:
    - common
```
- **Correctif propose** : Ajouter any_errors_fatal: true sur les plays critiques, et encapsuler la restauration des données dans block/rescue/always (journalisation ÉCHEC + nettoyage de /tmp/restore.sql.gz).
- **Verdict verification** : confiance haute — Confirmé par lecture intégrale de C:/Users/BEDANI/Documents/Atlas/Atlas/pra_restore_full.yaml : aucun "any_errors_fatal", "block", "rescue" ou "always" dans le fichier (vérifié sur les 227 lignes). L'extrait cité existe bien (play "PRA — Configuration de base (common)", lignes 39-43, hosts mgmt:dmz:lan_admin). Le play "PRA — Restauration des données" (l.95-166) enchaîne transfert rsync, "zcat /tmp/restore.sql.gz | mysql glpi_db" (l.137-143) puis suppression du dump (l.145-148) en tâches plates : un échec de la restauration saute la suppression et laisse /tmp/restore.sql.gz, et la ligne "FIN restauration" n'est écrite qu'au dernier play (l.222-227), jamais en cas d'échec — aucune journalisation ÉCHEC nulle part. Comportement Ansible par défaut : seul l'hôte en échec est retiré, les plays suivants continuent sur les autres hôtes du groupe, d'où plateforme partiellement restaurée. Aucune mitigation ailleurs (pas de ansible.cfg avec max_fail_percentage, pas de strategy particulière). Sévérité "moyenne" appropriée : fiabilité/observabilité du PRA dégradées, mais pas de perte de données directe ni de faille de sécurité.

### moyenne-12. Vérification de pra_target_dump après des actions, et aucune vérification post-fusion
- **Fichier** : `pra_restore_granular.yaml` (ligne ~26) — categorie : fiabilite — zone : pra
- **Description** : La journalisation et la création du répertoire s'exécutent avant l'assert sur pra_target_dump (ordre incohérent mais non bloquant). Surtout, après la fusion INSERT IGNORE en production, aucune vérification n'est faite (compte des tickets réinjectés, intégrité), contrairement au playbook full qui compte les tickets. En cas de mismatch de schéma entre le dump et la prod, INSERT IGNORE masque silencieusement les erreurs de clés mais mysql s'arrêtera sur une erreur de colonne sans rollback : la prod peut rester partiellement fusionnée.
- **Extrait** :
```
- name: "Fusionner les tickets restaurés dans la base de production"
  ansible.builtin.shell: >
    mysql glpi_db < /tmp/tickets_restore.sql
```
- **Correctif propose** : Déplacer l'assert en première tâche ; après la fusion, compter les lignes réinjectées (ROW_COUNT / comparaison COUNT avant-après) et l'afficher ; envisager une transaction (SET autocommit=0 ... COMMIT) autour de la fusion.
- **Verdict verification** : confiance haute — Constat confirmé par lecture intégrale de pra_restore_granular.yaml. (1) L'extrait cité existe à l'identique (lignes 94-98 : "mysql glpi_db < /tmp/tickets_restore.sql"). (2) L'assert sur pra_target_dump est bien à la ligne 34, APRÈS la création du répertoire (l.18) et la journalisation (l.26-31) qui utilise `default('NON DÉFINI')` — ordre incohérent mais non bloquant, comme décrit. (3) Aucune vérification post-fusion : entre la fusion (l.94) et le nettoyage (l.101), aucun COUNT, aucun register, aucun assert ; le bilan final (l.132) n'affiche que durée et RPO. À l'inverse, pra_restore_full.yaml:187 exécute bien "SELECT COUNT(*) FROM glpi_db.glpi_tickets" — l'asymétrie dénoncée est réelle. (4) Aucune transaction ni pipefail sur la tâche de fusion (contrairement à la restauration tmp l.69-71 qui a "set -o pipefail") : un échec en milieu de fichier SQL laisserait la prod partiellement fusionnée, et le no_log:true masque en plus le détail de l'erreur. Aucune mitigation ailleurs (pas de handler, pas de rescue/block). Sévérité moyenne appropriée : risque de fusion partielle silencieuse en production lors d'un PRA, mais pas d'écrasement de données existantes grâce à --insert-ignore/--no-create-info.

### moyenne-13. Export des tickets en clair dans /tmp sans permissions restreintes
- **Fichier** : `pra_restore_granular.yaml` (ligne ~87) — categorie : securite — zone : pra
- **Description** : /tmp/tickets_restore.sql (contenu métier : tickets, suivis, solutions) est créé via redirection shell avec l'umask par défaut, donc lisible par tout utilisateur local jusqu'à sa suppression. Même problème pour /tmp/restore.sql.gz dans le playbook full.
- **Extrait** :
```
> /tmp/tickets_restore.sql
```
- **Correctif propose** : Écrire dans un répertoire dédié 0700 (ex. /var/lib/atlas_restore) ou faire précéder la commande de umask 077 ; idem pour /tmp/restore.sql.gz dans pra_restore_full.yaml.
- **Verdict verification** : confiance haute — Constat confirmé. Dans pra_restore_granular.yaml ligne 87, l'export se fait via `mysqldump ... > /tmp/tickets_restore.sql` (ansible.builtin.shell) sans umask ni tâche file fixant un mode : avec l'umask root par défaut (022), le fichier est créé 0644 et donc lisible par tout utilisateur local jusqu'à sa suppression (tâche ligne 107-110). Les `no_log: true` présents protègent les journaux Ansible, pas les permissions du fichier. Même schéma dans pra_restore_full.yaml : rsync vers atlsvc@10.30.0.10:/tmp/restore.sql.gz (l.131), consommé l.139 puis supprimé l.145-148, sans permissions restreintes. Aucune mitigation ailleurs (pas de répertoire 0700, pas de mode). Sévérité moyenne justifiée : exposition réelle de données métier (tickets, suivis, solutions) mais temporaire, locale au serveur DB, nécessitant déjà un compte local — ni critique ni négligeable au vu de la contrainte de moindre privilège du projet.

### moyenne-14. Double source de vérité contradictoire avec le rôle proxmox_provision
- **Fichier** : `infra/proxmox_iac/deploy_lxc.sh` (ligne ~36) — categorie : fiabilite — zone : proxmox
- **Description** : Le script bash provisionne CT 101-103 (storage local-lvm, template 12.7, nesting=0, non démarrés, hostnames nginx-proxy/glpi-mariadb/zabbix-server) tandis que le rôle Ansible provisionne CT 200-208 (storage local, template 12.12, nesting=1, onboot, hostnames atlxx01p). Deux inventaires incompatibles dans le même dépôt : risque de déployer la mauvaise topologie et d'invalider le PRA (runbooks ambigus, RTO compromis).
- **Extrait** :
```
STORAGE="local-lvm"
TEMPLATE="local:vztmpl/debian-12-standard_12.7-1_amd64.tar.zst"
...
create_ct  101   "nginx-proxy"    20   "10.20.0.101/24"  "10.20.0.1"
```
- **Correctif propose** : Supprimer ou archiver deploy_lxc.sh (et setup_vlan_routing.sh) si le rôle Ansible est la référence, ou les marquer explicitement obsolètes ; un seul chemin de provisionnement doit exister pour le PRA.
- **Verdict verification** : confiance haute — Constat confirmé point par point. deploy_lxc.sh contient bien STORAGE="local-lvm" (l.36), TEMPLATE debian 12.7 (l.39), --features "nesting=0" (l.108), --start 0 (l.117) et provisionne CT 101-103 (nginx-proxy/glpi-mariadb/zabbix-server, l.137-139). Le rôle roles/proxmox_provision/defaults/main.yaml définit une topologie incompatible : CT 200-208, hostnames atlxx01p, IP différentes (10.20.0.10 vs 10.20.0.101), et tasks/create_lxc_item.yaml impose template 12.12, nesting=1, onboot:true, storage local « jamais local-lvm » (commentaire explicite contredisant le script bash). Aucune mention obsolete/deprecated dans le dépôt ; pire, docs/DAT.md (l.222, 262) référence deploy_lxc.sh comme procédure officielle de création des conteneurs, donc le runbook PRA pointe vers la topologie 3-CT alors que le rôle Ansible en déploie 9 — l'ambiguïté pour le RTO est réelle. Sévérité moyenne (fiabilité/documentation, pas de faille directe) confirmée.

### moyenne-15. validate_certs: false sur l'API Proxmox
- **Fichier** : `roles/proxmox_provision/tasks/create_lxc_item.yaml` (ligne ~17) — categorie : securite — zone : proxmox
- **Description** : Toutes les connexions à l'API Proxmox (création et démarrage des CT) désactivent la vérification TLS alors qu'elles transportent le jeton/mot de passe API (vault_proxmox_token_secret / vault_proxmox_password). Un MITM sur le réseau de gestion permet de capturer ces identifiants à privilèges élevés.
- **Extrait** :
```
validate_certs: false
```
- **Correctif propose** : Déployer un certificat valide sur l'API Proxmox (ou ajouter la CA interne au trust store du contrôleur) et passer validate_certs: true ; au minimum en faire une variable surchargeable documentée.
- **Verdict verification** : confiance haute — Confirmé. `validate_certs: false` est codé en dur ligne 17 de roles/proxmox_provision/tasks/create_lxc_item.yaml et ligne 17 de start_lxc.yaml, sur les tâches community.general.proxmox qui transmettent api_token_secret (vault_proxmox_token_secret) et api_password (vault_proxmox_password). Aucune variable de surcharge (rien dans defaults/vars du rôle), aucun garde-fou ailleurs : ce sont les deux seules occurrences du dépôt et toutes deux désactivent la vérification TLS. Le risque MITM sur les identifiants API Proxmox est réel. Sévérité moyenne justifiée (et non haute) car l'API Proxmox est censée être sur le VLAN 90 MGMT, réseau restreint, et l'exposition se limite aux exécutions du playbook.

### moyenne-16. iptables-save capture l'état courant complet : dérive du fichier rules.v4
- **Fichier** : `scripts/setup_vlan_routing.sh` (ligne ~205) — categorie : idempotence — zone : proxmox
- **Description** : Le script persiste l'intégralité des règles actives (y compris règles temporaires, PVE firewall, doublons issus d'anciennes exécutions) dans /etc/iptables/rules.v4. Ce fichier sera ensuite écrasé par le template Ansible rules.v4.j2 : selon l'ordre d'exécution script/rôle, le contenu effectif des règles au boot diffère à chaque passage (dérive non idempotente).
- **Extrait** :
```
iptables-save > "${IPTABLES_RULES}"
```
- **Correctif propose** : Choisir une seule méthode de gestion (le template Ansible) et faire générer rules.v4 de façon déterministe ; ne jamais mélanger iptables-save d'état vivant et fichier templatisé.
- **Verdict verification** : confiance haute — Confirmé par lecture du code. setup_vlan_routing.sh:205 contient bien `iptables-save > "${IPTABLES_RULES}"` vers /etc/iptables/rules.v4, capturant l'état iptables vivant complet (règles PVE firewall, règles temporaires incluses). Le même fichier est géré de façon déterministe par le rôle Ansible proxmox_network (tasks/iptables_rules.yaml:26-33, template rules.v4.j2, handler `iptables-restore < /etc/iptables/rules.v4`). Deux sources de vérité concurrentes sur le même fichier, contenu au boot dépendant de l'ordre d'exécution ; aucun garde-fou. Le commentaire defaults/main.yaml:17 ("rules.v4 étant déployé en intégralité, tout NAT préexistant doit y figurer") confirme le conflit. Sévérité moyenne justifiée (dérive de configuration réseau, pas de faille directe).

### moyenne-17. sudo NOPASSWD avec joker systemctl restart/reload * : escalade de privilèges possible
- **Fichier** : `roles/common/tasks/users.yaml` (ligne ~39) — categorie : securite — zone : socle
- **Description** : La règle 'systemctl restart *' avec joker permet à atlsvc de redémarrer N'IMPORTE QUELLE unité (y compris des services critiques pour provoquer un déni de service), et le joker sudoers '*' matche aussi les espaces : atlsvc peut passer des options arbitraires à systemctl (ex. 'sudo systemctl restart sshd --job-mode=...' ou plusieurs unités). Ce n'est pas du moindre privilège.
- **Extrait** :
```
atlsvc ALL=(root) NOPASSWD: /bin/systemctl restart *, /bin/systemctl reload *
```
- **Correctif propose** : Énumérer explicitement les unités autorisées (ex. /bin/systemctl restart nginx.service, /bin/systemctl reload nginx.service) sans joker, par rôle/hôte.
- **Verdict verification** : confiance haute — Confirmé. La ligne 39 de roles/common/tasks/users.yaml contient exactement « atlsvc ALL=(root) NOPASSWD: /bin/systemctl restart *, /bin/systemctl reload * », déployée dans /etc/sudoers.d/atlsvc. Aucune mitigation ailleurs : le joker n'est restreint nulle part, et en sudoers '*' matche les espaces, donc atlsvc peut redémarrer n'importe quelle unité (sshd, mariadb, zabbix-agent...) et passer des arguments supplémentaires à systemctl. Cela contredit le principe de moindre privilège imposé par CLAUDE.md. Sévérité « moyenne » correcte : nécessite déjà la compromission du compte atlsvc (clé SSH), pas d'escalade root directe évidente, mais déni de service étendu possible.

### moyenne-18. Clé privée /root/.ssh/atlas_ed25519 référencée mais jamais déployée par le rôle
- **Fichier** : `roles/bastion/templates/ssh_config.j2` (ligne ~11) — categorie : fiabilite — zone : socle
- **Description** : La config cliente pointe vers IdentityFile /root/.ssh/atlas_ed25519, mais aucune tâche du rôle bastion (ni du rôle common) ne déploie cette clé privée. Si elle n'est pas provisionnée ailleurs, les rebonds SSH depuis le bastion échoueront — impact direct sur le RTO en scénario PRA où le bastion est reconstruit. (Note : si elle était versionnée pour combler ce manque, ce serait une violation 'secrets hors VCS' ; elle doit venir d'un vault ou être générée au déploiement.)
- **Extrait** :
```
IdentityFile /root/.ssh/atlas_ed25519
```
- **Correctif propose** : Ajouter une tâche qui génère la paire de clés sur le bastion (community.crypto.openssh_keypair) ou la déploie depuis Ansible Vault, et distribue la clé publique sur les hôtes cibles.
- **Verdict verification** : confiance haute — Extrait confirmé (IdentityFile /root/.ssh/atlas_ed25519, ligne 11 de ssh_config.j2). Le rôle bastion (tasks/ssh_config.yaml) crée /root/.ssh et déploie le fichier config, mais aucune tâche du dépôt ne génère ni ne déploie atlas_ed25519 : le seul openssh_keypair existant concerne atlas_backup_ed25519 (roles/backup/tasks/ssh_key.yaml). deploy_lxc.sh injecte seulement la clé publique opérateur (~/.ssh/atlas_id_ed25519.pub, nom différent) dans les LXC ; la clé privée sur le bastion reste une étape manuelle non tracée, contraire à la règle IaC et impactant le RTO si le bastion est reconstruit (ansible.cfg et develop/hosts.yaml en dépendent aussi). Sévérité moyenne justifiée.

### moyenne-19. dist-upgrade systématique à chaque exécution du playbook
- **Fichier** : `roles/common/tasks/packages.yaml` (ligne ~8) — categorie : fiabilite — zone : socle
- **Description** : La tâche applique un 'upgrade: dist' inconditionnel à chaque run. Outre la non-idempotence (le play rapporte changed et modifie le système de façon non maîtrisée), un dist-upgrade peut redémarrer des services (MariaDB, nginx, sshd) en pleine production ou pendant un exercice PRA, allongeant le RTO de façon imprévisible.
- **Extrait** :
```
ansible.builtin.apt:
    update_cache: true
    upgrade: dist
    cache_valid_time: 3600
```
- **Correctif propose** : Séparer la mise à jour dans un playbook de maintenance dédié, ou la conditionner à une variable (ex. when: common_apply_upgrades | bool, défaut false), et garder uniquement update_cache dans le rôle common.
- **Verdict verification** : confiance haute — Confirmé : roles/common/tasks/packages.yaml lignes 8-12 contiennent bien « upgrade: dist » avec update_cache, sans aucun « when » ni variable de garde (rien dans roles/common/defaults/main.yaml ni vars/main.yaml). Le rôle common est inclus dans site.yaml (tags [common], tous les hôtes) et surtout dans pra_restore_full.yaml ligne 39-43 : un dist-upgrade complet (téléchargements + redémarrages potentiels de MariaDB/nginx/sshd) s'exécute donc pendant la restauration PRA, allongeant le RTO (<=40 min) de façon imprévisible. Non-idempotence et mise à jour non maîtrisée avérées. Sévérité moyenne justifiée (fiabilité/RTO, pas de faille directe).

### moyenne-20. Mot de passe root passé en argument de commande (visible via ps)
- **Fichier** : `roles/mariadb/tasks/secure.yaml` (ligne ~8) — categorie : securite — zone : donnees
- **Description** : mysqladmin reçoit le mot de passe root en clair sur la ligne de commande : pendant l'exécution, il est visible par tout processus local via /proc/<pid>/cmdline ou ps. no_log protège seulement les logs Ansible. Même problème pour les CREATE USER ... IDENTIFIED BY '...' dans databases.yaml (lignes 26-28 et 52-54).
- **Extrait** :
```
ansible.builtin.shell: mysqladmin -u root password '{{ vault_mariadb_root_password }}'
```
- **Correctif propose** : Utiliser community.mysql.mysql_user (login_unix_socket: /run/mysqld/mysqld.sock) qui passe le mot de passe via le protocole, ou passer le SQL sur stdin (mysql <<'EOF').
- **Verdict verification** : confiance haute — Constat exact. roles/mariadb/tasks/secure.yaml ligne 8 contient bien `ansible.builtin.shell: mysqladmin -u root password '{{ vault_mariadb_root_password }}'` : le secret est interpolé dans l'argv du processus, donc lisible via /proc/<pid>/cmdline par tout utilisateur local pendant l'exécution. Le `no_log: true` présent (ligne 11) ne masque que les logs Ansible, pas la ligne de commande, comme l'annonce le constat. Même schéma confirmé dans databases.yaml lignes 26-28 et 52-54 (`CREATE USER ... IDENTIFIED BY '{{ vault_glpi_db_password }}'` via shell, no_log présent mais inopérant contre ps). Aucune mitigation ailleurs (pas d'usage de community.mysql, pas de stdin). Sévérité moyenne justifiée : fenêtre d'exposition brève et nécessitant déjà un accès local au conteneur DB, mais bien réelle.

### moyenne-21. StrictHostKeyChecking=no sur les rsync de sauvegarde
- **Fichier** : `roles/backup/templates/collect_dumps.sh.j2` (ligne ~12) — categorie : securite — zone : donnees
- **Description** : Les deux scripts (collect_dumps.sh et backup_filestore.sh ligne 12) désactivent la vérification de la clé d'hôte SSH, ouvrant la voie à une attaque MITM : un hôte usurpant 10.30.0.10/10.20.0.11 pourrait servir des dumps falsifiés ou capter la connexion. Inutile puisque les hôtes sont connus et gérés par Ansible.
- **Extrait** :
```
SSH_OPTS="ssh -i {{ backup_ssh_key_path }} -o StrictHostKeyChecking=no"
```
- **Correctif propose** : Provisionner les clés d'hôte via ansible.builtin.known_hosts dans le rôle et utiliser -o StrictHostKeyChecking=yes (ou accept-new au premier déploiement).
- **Verdict verification** : confiance haute — Constat confirmé. La ligne 12 de roles/backup/templates/collect_dumps.sh.j2 contient exactement SSH_OPTS="ssh -i {{ backup_ssh_key_path }} -o StrictHostKeyChecking=no", idem backup_filestore.sh.j2 ligne 12, et les rsync de restauration PRA (pra_restore_full.yaml l.130/154). Aucune tâche ansible.builtin.known_hosts ni provisioning de clés d'hôte n'existe dans le dépôt (grep négatif) : aucune mitigation ailleurs. Le risque MITM sur les flux de sauvegarde (10.30.0.10/10.20.0.11) est réel mais limité à un attaquant déjà positionné sur le LAN admin, et le pattern est généralisé (ansible.cfg, bastion ssh_config) : sévérité moyenne appropriée.

### moyenne-22. Aucune vérification d'intégrité du dump produit
- **Fichier** : `roles/mariadb/templates/dump_glpi.sh.j2` (ligne ~49) — categorie : fiabilite — zone : donnees
- **Description** : Après le dump, seul le code retour de mysqldump/gzip est contrôlé. Aucun test d'intégrité (gzip -t, taille minimale, présence du marqueur '-- Dump completed' en fin de fichier) n'est effectué, ni localement ni après la collecte sur atlbkp01p. Un dump tronqué (disque plein côté lecture, kill OOM silencieux) peut être conservé et propagé, et ne sera découvert qu'au moment d'une restauration PRA.
- **Extrait** :
```
if [ "${RC_DUMP}" -ne 0 ] || [ "${RC_GZIP}" -ne 0 ]; then
    log "ERREUR : échec du dump..."
```
- **Correctif propose** : Ajouter après le dump : gzip -t "${FICHIER}" et zcat "${FICHIER}" | tail -1 | grep -q 'Dump completed' ; supprimer le fichier et sortir en erreur sinon. Idéalement, tester aussi côté serveur de sauvegarde.
- **Verdict verification** : confiance haute — Constat confirmé. L'extrait cité existe à la ligne 45 de roles/mariadb/templates/dump_glpi.sh.j2 : seuls RC_DUMP et RC_GZIP (via PIPESTATUS) sont contrôlés après le dump (lignes 36-49). Aucun `gzip -t`, aucun contrôle de taille minimale, aucune vérification du marqueur '-- Dump completed' dans tout le script ni ailleurs dans le dépôt (grep sur gzip -t/zcat/Dump completed/integrit : seules occurrences = restauration PRA et init Zabbix, aucune vérification). La rotation (ligne 57) peut même supprimer les derniers dumps sains au profit de dumps plus récents potentiellement corrompus. Le risque est réel pour le PRA (RPO 20 min / RTO 40 min) : un dump tronqué silencieux (OOM kill de gzip avec code 0 improbable mais disque plein détecté par gzip ; en revanche corruption disque ou troncature post-écriture non détectées) ne serait découvert qu'à la restauration. La sévérité moyenne est appropriée : le code retour du pipeline couvre déjà les échecs explicites (mysqldump, gzip, disque plein), ce qui mitige partiellement les scénarios cités ; reste le risque résiduel non couvert.

### moyenne-23. Répertoire install/ de GLPI jamais supprimé après installation
- **Fichier** : `roles/glpi/tasks/download.yaml` (ligne ~0) — categorie : securite — zone : web
- **Description** : Aucune tâche du rôle ne supprime /var/www/glpi/install après l'installation. Les scripts d'installation/migration restent accessibles via le routeur public (index.php route /install/install.php), ce qui expose des fonctions sensibles (réinstallation, mise à jour de la base).
- **Extrait** :
```
tasks/download.yaml ne contient aucune tâche state: absent sur /var/www/glpi/install
```
- **Correctif propose** : Ajouter en fin de rôle : ansible.builtin.file: path=/var/www/glpi/install state=absent (après confirmation que la base est installée).
- **Verdict verification** : confiance haute — Constat confirmé. roles/glpi/tasks/download.yaml déploie GLPI 10.0.16 dans /var/www/glpi sans aucune tâche supprimant install/ ; aucun `state: absent` sur ce chemin nulle part dans le dépôt (vérifié par grep : les seuls state:absent du rôle glpi portent sur sites-enabled/default dans configure.yaml). Le vhost (templates/vhost_glpi.conf.j2) a pour racine /var/www/glpi/public et route tout vers index.php (`try_files $uri /index.php$is_args$args`) ; or le routeur GLPI 10 sert bien /install/install.php via index.php, donc les scripts d'installation restent accessibles. Le projet est conscient du risque : infra/lan_admin_vlan30/provision_glpi.sh ligne 235 affiche seulement en « NEXT STEPS » une commande manuelle `rm -rf ${GLPI_DIR}/install` — une étape manuelle non tracée, contraire à la règle IaC du CLAUDE.md, et absente du rôle Ansible. Sévérité moyenne maintenue : exposition réelle (réinstallation/maj DB possible via le proxy), mais le backend est en LAN ADMIN derrière le reverse proxy et l'installeur exige les identifiants DB pour les actions destructives.

### moyenne-24. UFW ouvre le port 80 du backend GLPI à toutes les sources
- **Fichier** : `roles/glpi/tasks/configure.yaml` (ligne ~42) — categorie : securite — zone : web
- **Description** : Le flux HTTP entrant sur atlapp01p est censé venir uniquement du reverse proxy, mais la règle UFW autorise le port 80 depuis n'importe quelle IP. Tout hôte de la DMZ (voire au-delà selon le routage) peut atteindre GLPI en HTTP clair, en contournant le TLS et la limitation de débit du proxy.
- **Extrait** :
```
- name: Autoriser le flux HTTP entrant (depuis le reverse proxy)
  community.general.ufw:
    rule: allow
    port: "80"
    proto: tcp
```
- **Correctif propose** : Ajouter src: 10.20.0.10 (IP du reverse proxy) à la règle UFW pour restreindre la source.
- **Verdict verification** : confiance haute — Constat confirmé. Dans roles/glpi/tasks/configure.yaml (lignes 42-46), la tâche "Autoriser le flux HTTP entrant (depuis le reverse proxy)" appelle community.general.ufw avec rule: allow, port: "80", proto: tcp, SANS paramètre from_ip/src — le port 80 est donc ouvert à toute source malgré le titre de la tâche. Aucune mitigation ailleurs : roles/common/tasks/hardening.yaml fixe bien une politique deny par défaut, mais tous les autres rôles (mariadb, zabbix, grafana, smtp, backup, bastion) restreignent leurs règles via from_ip — le rôle glpi est l'exception, ce qui confirme l'oubli. Sévérité moyenne appropriée : exposition limitée à la DMZ/réseaux routés internes, mais contournement du TLS et du rate-limiting du proxy. Correctif proposé valide (le paramètre exact du module est from_ip, pas src).

### moyenne-25. Le marqueur run-once est écrit même si tous les appels API échouent
- **Fichier** : `roles/glpi_seed/templates/seed_glpi.py.j2` (ligne ~274) — categorie : fiabilite — zone : web
- **Description** : Le script compte les échecs (variable echecs) mais termine toujours avec le code retour 0 et écrit le marqueur /var/lib/glpi/.atlas_seed_done quoi qu'il arrive après init_session. Si la création des catégories/utilisateurs/tickets échoue massivement (API mal configurée, droits insuffisants), Ansible considère la tâche réussie et le creates: empêche définitivement toute ré-exécution.
- **Extrait** :
```
os.makedirs(os.path.dirname(MARQUEUR), exist_ok=True)
with open(MARQUEUR, "w", encoding="utf-8") as marqueur:
    marqueur.write(recap)
```
- **Correctif propose** : Ne pas écrire le marqueur et sortir avec sys.exit(1) si echecs > 0 (ou au-delà d'un seuil), afin qu'Ansible signale l'échec et qu'un re-run soit possible.
- **Verdict verification** : confiance haute — Confirmé dans C:/Users/BEDANI/Documents/Atlas/Atlas/roles/glpi_seed/templates/seed_glpi.py.j2 : seul init_session() peut provoquer sys.exit(1) (lignes 41-55). La fonction creer() (l.69-95) incrémente le compteur global `echecs` et retourne None en cas d'erreur réseau ou HTTP, mais main() (l.263-281) écrit inconditionnellement le marqueur MARQUEUR=/var/lib/glpi/.atlas_seed_done (l.274-276, extrait cité exact) et se termine avec code 0, `echecs` n'étant utilisé que dans le récapitulatif texte. Le commentaire d'en-tête (l.11-12) confirme que Ansible utilise args.creates sur ce marqueur : un échec massif post-session serait donc vu comme un succès et bloquerait définitivement tout re-run. Sévérité moyenne justifiée : impact limité à des données de démonstration (fiabilité), mais détection masquée et remédiation manuelle requise.

### moyenne-26. La datasource Grafana utilise le compte super-admin Zabbix
- **Fichier** : `roles/grafana/templates/provisioning_datasource.yaml.j2` (ligne ~16) — categorie : securite — zone : supervision
- **Description** : Le provisioning de la source de données Zabbix s'authentifie avec le compte « Admin » (super-administrateur Zabbix) alors que Grafana n'a besoin que d'un accès en lecture. Violation du principe de moindre privilège : une compromission de Grafana (ou la lecture du fichier /etc/grafana/provisioning/datasources/zabbix.yaml) donne un contrôle total de Zabbix (scripts d'exécution distante sur tous les agents inclus).
- **Extrait** :
```
jsonData:
      username: Admin
      trends: true
    secureJsonData:
      password: "{{ vault_zabbix_admin_password }}"
```
- **Correctif propose** : Créer via l'API (dans le rôle zabbix) un utilisateur dédié « grafana » avec un rôle en lecture seule (User role, accès API limité) et un mot de passe vault distinct (vault_zabbix_grafana_password), et l'utiliser dans la datasource.
- **Verdict verification** : confiance haute — Constat confirmé. Le fichier roles/grafana/templates/provisioning_datasource.yaml.j2 contient bien lignes 15-19 « jsonData: username: Admin » et « secureJsonData: password: \"{{ vault_zabbix_admin_password }}\" » : la datasource Grafana s'authentifie avec le super-admin Zabbix. Recherche dans tout le dépôt : aucun utilisateur Zabbix dédié à Grafana n'est créé (le rôle zabbix n'utilise « Admin » que dans register_hosts.yaml, aucune tâche user.create), et aucune variable vault_zabbix_grafana_password n'existe. Le compte par défaut « Admin » est donc conservé et utilisé en lecture par un service tiers, en violation du principe de moindre privilège et de la règle CLAUDE.md « aucun compte administrateur par défaut conservé ». Atténuants : mot de passe en vault (hors VCS) et flux interne, mais une compromission de Grafana ou la lecture du fichier provisionné donne le contrôle total de Zabbix. Sévérité « moyenne » appropriée.

### moyenne-27. Frontend/API Zabbix en HTTP clair : identifiants admin transitant non chiffrés
- **Fichier** : `roles/zabbix/templates/zabbix_nginx.conf.j2` (ligne ~8) — categorie : securite — zone : supervision
- **Description** : Le frontend Zabbix écoute en HTTP simple sur le port 8080, ouvert aux réseaux 10.30.0.0/24 et 10.90.0.0/24. Le mot de passe Admin transite en clair sur le réseau à chaque login web, à chaque run Ansible (user.login dans register_hosts.yaml) et en continu depuis Grafana (datasource sur http://10.30.0.12:8080/api_jsonrpc.php). Idem pour Grafana (http_addr=0.0.0.0, pas de section [server] protocol=https). Le projet impose TLS sur le reverse proxy ; les interfaces d'administration internes véhiculant des secrets devraient l'être aussi.
- **Extrait** :
```
listen          {{ zabbix_frontend_port }};
server_name     {{ zabbix_server_ip }} atlzbx01p.atlas.local;
```
- **Correctif propose** : Servir le frontend Zabbix et Grafana en HTTPS (certificats internes hors VCS, listen 8080 ssl / protocol = https dans grafana.ini), et pointer la datasource Grafana et zabbix_api_url vers https.
- **Verdict verification** : confiance haute — Confirmé par le code. roles/zabbix/templates/zabbix_nginx.conf.j2 ligne 8 contient bien « listen {{ zabbix_frontend_port }}; » sans « ssl » ni directive de certificat, avec zabbix_frontend_port: 8080 (roles/zabbix/defaults/main.yaml:18). install_frontend.yaml:56-64 ouvre ce port en TCP depuis 10.30.0.0/24 et 10.90.0.0/24 : le login web Admin transite donc en clair sur le réseau. Grafana confirme aussi : grafana.ini.j2 a http_addr = 0.0.0.0 sans protocol=https, et provisioning_datasource.yaml.j2:12 pointe en http vers grafana_zabbix_host=10.30.0.12:8080 — les identifiants API Zabbix circulent en clair entre conteneurs en continu. Aucune mitigation trouvée (pas de reverse proxy TLS devant Zabbix/Grafana dans le dépôt). Seule nuance : zabbix_api_url vaut « http://localhost:8080/... » (defaults/main.yaml:27), donc les appels user.login de register_hosts.yaml passent par la boucle locale et non par le réseau — cette partie du constat est exagérée. Sévérité moyenne adéquate : exposition limitée aux VLAN internes 30/90, mais contraire à l'exigence TLS du projet.

### moyenne-28. Rotation du mot de passe BDD zabbix impossible : dérive entre vault et MariaDB
- **Fichier** : `roles/zabbix/tasks/database.yaml` (ligne ~38) — categorie : idempotence — zone : supervision
- **Description** : La création de l'utilisateur MySQL n'est exécutée que si l'utilisateur n'existe pas (COUNT(*) == 0). Si vault_zabbix_db_password change (rotation de secret), le mot de passe en base n'est jamais mis à jour, alors que zabbix_server.conf et zabbix.conf.php reçoivent la nouvelle valeur : le serveur Zabbix et le frontend perdent l'accès à la BDD au run suivant.
- **Extrait** :
```
mysql -e "CREATE USER 'zabbix'@'10.30.0.12'
    IDENTIFIED BY '{{ vault_zabbix_db_password }}';
...
  when: zabbix_db_user_present.stdout | int == 0
```
- **Correctif propose** : Remplacer la logique par un ALTER USER ... IDENTIFIED BY inconditionnel (ou CREATE USER IF NOT EXISTS suivi de ALTER USER), avec changed_when basé sur une vérification préalable de connexion avec le mot de passe courant.
- **Verdict verification** : confiance haute — Confirmé dans roles/zabbix/tasks/database.yaml (lignes 30-46) : la tâche "Créer l'utilisateur MySQL zabbix" (CREATE USER ... IDENTIFIED BY '{{ vault_zabbix_db_password }}') n'est exécutée que si `zabbix_db_user_present.stdout | int == 0` (COUNT(*) sur mysql.user). Aucun ALTER USER ni SET PASSWORD ailleurs dans le rôle. En revanche, les templates zabbix_server.conf.j2 (DBPassword=) et zabbix.conf.php.j2 ($DB['PASSWORD']) reçoivent inconditionnellement la valeur du vault. En cas de rotation de vault_zabbix_db_password, la BDD garde l'ancien mot de passe tandis que serveur et frontend Zabbix utilisent le nouveau : perte d'accès à la BDD. Sévérité moyenne justifiée : impacte la supervision (pas le service GLPI lui-même) et seulement lors d'une rotation de secret.

### moyenne-29. Jeton API Proxmox créé sans séparation de privilèges (--privsep 0) sur root@pam
- **Fichier** : `README.md` (ligne ~71) — categorie : securite — zone : secrets
- **Description** : La procédure documentée crée le jeton d'automatisation sur le compte root@pam avec --privsep 0 : le jeton hérite de TOUS les privilèges root de l'hyperviseur. La fuite de ce seul secret (transmis de surcroît avec validate_certs: false) donne le contrôle complet de Proxmox. Contraire au principe de moindre privilège du projet.
- **Extrait** :
```
`pveum user token add root@pam ansible --privsep 0`
```
- **Correctif propose** : Créer un utilisateur dédié (ex. ansible@pve) avec un rôle limité aux opérations LXC nécessaires (VM.Allocate, VM.Config.*, VM.PowerMgmt, Datastore.AllocateSpace) et un jeton avec privsep activé.
- **Verdict verification** : confiance haute — Extrait exact présent à README.md:71 et répété dans develop/group_vars/all/vault.yaml.example:12 avec vault_proxmox_user: "root@pam". Le rôle proxmox_provision (create_lxc_item.yaml, start_lxc.yaml) utilise ce jeton root avec validate_certs: false. Aucun utilisateur dédié ni rôle ACL limité n'existe dans le dépôt : le jeton --privsep 0 sur root@pam hérite de tous les privilèges, contraire au principe de moindre privilège du CLAUDE.md. Mitigation partielle (secret dans vault chiffré, jeton révocable) justifie de rester en sévérité moyenne.

### moyenne-30. Injection SQL/shell possible via les variables d'environnement non échappées
- **Fichier** : `infra/lan_admin_vlan30/provision_glpi.sh` (ligne ~123) — categorie : securite — zone : infra-dmz
- **Description** : GLPI_DB_NAME, GLPI_DB_USER et GLPI_DB_PASSWORD sont interpolés directement dans un heredoc SQL non quoté lui-même imbriqué dans un bash -c entre guillemets doubles. Un mot de passe contenant une apostrophe, un backtick, un $ ou des guillemets casse la requête (échec du script via set -e) ou permet l'injection SQL en tant que root MariaDB. Même construction dans provision_zabbix.sh lignes 151-158. C'est un vrai bug fonctionnel : la consigne du projet recommande des mots de passe forts, qui contiennent fréquemment ces caractères.
- **Extrait** :
```
CREATE USER IF NOT EXISTS '${GLPI_DB_USER}'@'localhost' IDENTIFIED BY '${GLPI_DB_PASSWORD}';
```
- **Correctif propose** : Échapper les apostrophes du mot de passe (ex. ${GLPI_DB_PASSWORD//\'/\\'}) ou écrire le SQL dans un fichier temporaire généré avec printf %q / un quoted heredoc, poussé via pct push et exécuté avec mysql < fichier.
- **Verdict verification** : confiance haute — Constat confirmé. Dans provision_glpi.sh lignes 120-127, le SQL est bien généré via un heredoc non quoté (<<SQL) imbriqué dans un `pct exec ... bash -c "..."` entre guillemets doubles : `CREATE USER IF NOT EXISTS '${GLPI_DB_USER}'@'localhost' IDENTIFIED BY '${GLPI_DB_PASSWORD}';` — l'extrait cité existe mot pour mot (ligne 123). Le mot de passe est interpolé deux fois (par le shell appelant via les guillemets doubles, puis par le bash interne via le heredoc non quoté) : un `$`, backtick, `"` ou `'` dans GLPI_DB_PASSWORD casse le script (set -euo pipefail, ligne 37) ou permet une injection SQL exécutée en root MariaDB (unix_socket). Aucun garde-fou en amont : la seule validation est `${VAR:?}` (lignes 70-72) qui vérifie juste que la variable est non vide. Même construction confirmée dans provision_zabbix.sh (lignes 151-158), qui aggrave avec `mysql -p${ZABBIX_DB_PASSWORD}` en clair sur la ligne de commande (visible dans ps). Le commentaire du script recommande explicitement un "strong-password" (ligne 28), donc le scénario du caractère spécial est réaliste. Sévérité "moyenne" appropriée : l'injection requiert que l'opérateur fournisse lui-même la valeur (pas d'entrée non fiable externe), c'est surtout un bug de robustesse fonctionnelle avec impact sécurité secondaire.

### moyenne-31. Motifs sed trop larges : risque d'écraser des lignes de commentaires et de créer des directives dupliquées
- **Fichier** : `infra/lan_admin_vlan30/provision_zabbix.sh` (ligne ~175) — categorie : bug — zone : infra-dmz
- **Description** : Les substitutions sed utilisent ^.*DBHost=.* (et équivalents) : elles remplacent TOUTE ligne contenant la chaîne, y compris les lignes de commentaire explicatif du fichier livré par Zabbix (ex. '### Option: DBHost' n'est pas touché mais '# DBHost=localhost' ET la ligne active 'DBHost=localhost' le sont toutes les deux). Résultat : plusieurs lignes 'DBHost=localhost' identiques, et pour DBPassword, le mot de passe est écrit sur chaque ligne contenant 'DBPassword=' y compris d'anciens commentaires. Sur le fichier zabbix_server.conf standard, '# DBPassword=' (commentaire d'exemple) et la directive sont tous deux réécrits avec le secret en clair, dupliquant le mot de passe. Le résultat dérive à chaque exécution sur fichier modifié.
- **Extrait** :
```
pct exec "${CTID}" -- sed -i "s|^.*DBPassword=.*|DBPassword=${ZABBIX_DB_PASSWORD}|" /etc/zabbix/zabbix_server.conf
```
- **Correctif propose** : Cibler précisément la directive : sed -E 's|^[#[:space:]]*DBPassword=.*|DBPassword=...|' avec ancrage strict, ou mieux : gérer ce fichier via le template Jinja2 du rôle Ansible zabbix (source unique).
- **Verdict verification** : confiance haute — Extrait confirmé lignes 175-186 de provision_zabbix.sh : les quatre sed utilisent des motifs non ancrés (s|^.*DBHost=.*|...|) qui matchent toute ligne contenant la chaîne, y compris les exemples commentés du fichier stock ('# DBUser=', '# DBName=', '# DBPassword='). Le commentaire du script (l.168-172) assume ce comportement, et aucun garde-fou (template, idempotence) n'existe ailleurs. Sur le fichier Debian standard, DBName et DBUser ont à la fois un exemple commenté et une directive active : les deux sont réécrits, créant des directives dupliquées que le parseur Zabbix peut rejeter ('parameter defined multiple times'). Pour DBPassword, l'exemple commenté devient la directive active avec le secret, et le résultat dérive aux ré-exécutions. Sévérité moyenne confirmée : bug réel de fiabilité/idempotence, mais correctible et sans exposition réseau directe.

### moyenne-32. Import du schéma Zabbix non rejouable : échec garanti au 2e run
- **Fichier** : `infra/lan_admin_vlan30/provision_zabbix.sh` (ligne ~162) — categorie : idempotence — zone : infra-dmz
- **Description** : Le script importe server.sql.gz sans aucun garde-fou. Le commentaire du script l'admet lui-même ('Do NOT re-run this step'), mais comme set -euo pipefail est actif, toute ré-exécution du script (par ex. après un échec à l'étape 5) s'arrête en erreur sur les objets dupliqués, laissant le conteneur dans un état intermédiaire. Le script n'est donc pas idempotent alors que c'est l'un des objectifs PRA (rejouabilité pour tenir le RTO).
- **Extrait** :
```
pct exec "${CTID}" -- bash -c "zcat /usr/share/zabbix/sql-scripts/mysql/server.sql.gz | mysql -u${ZABBIX_DB_USER} -p${ZABBIX_DB_PASSWORD} ${ZABBIX_DB_NAME}"
```
- **Correctif propose** : Conditionner l'import à un test d'existence : SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='${ZABBIX_DB_NAME}' — n'importer que si 0 table.
- **Verdict verification** : confiance haute — Constat confirmé par lecture intégrale de infra/lan_admin_vlan30/provision_zabbix.sh. L'extrait cité existe textuellement aux lignes 162-163 (zcat server.sql.gz | mysql ...) sans aucun garde-fou. Le commentaire des lignes 145-148 admet explicitement : « Do NOT re-run this step against an already-populated Zabbix database — it will fail with duplicate-object errors ». Avec set -euo pipefail (ligne 39), une ré-exécution après échec partiel (ex. à l'étape 5/6/7) s'arrête en erreur à l'étape 4, alors que les étapes 1-3 et la création DB/user (CREATE ... IF NOT EXISTS) sont, elles, idempotentes. Aucune mitigation ailleurs (pas de wrapper, pas de marqueur d'état). Le correctif proposé (test du nombre de tables via information_schema avant import) est pertinent. Sévérité « moyenne » justifiée : impact sur la rejouabilité/RTO du PRA, mais contournable manuellement (drop/recreate documenté dans le commentaire).

### moyenne-33. Trois méthodes de déploiement concurrentes pour le même reverse proxy
- **Fichier** : `infra/dmz_vlan20/provision_nginx.sh` (ligne ~0) — categorie : fiabilite — zone : infra-dmz
- **Description** : Le proxy Nginx DMZ a trois implémentations dans le dépôt : (1) docker-compose.yml + nginx.conf statique (Docker), (2) provision_nginx.sh (pct exec + paquets Debian + systemctl), (3) rôle Ansible reverse_proxy (templates Jinja2, utilisé par site.yaml et le PRA). Les méthodes 1 et 2 sont d'ailleurs incompatibles entre elles : le compose monte ./certs (fullchain.pem/privkey.pem fournis sur l'hôte) tandis que le script crée des symlinks /etc/nginx/certs/* vers un auto-signé dans le conteneur, et nginx.conf inclut un bloc events/http complet incompatible avec le paquet Debian (conf.d/sites-enabled ignorés). Aucune doc n'indique laquelle est canonique ; le README ne mentionne même pas infra/.
- **Extrait** :
```
infra/dmz_vlan20/{docker-compose.yml, nginx.conf, provision_nginx.sh} vs roles/reverse_proxy/templates/{nginx.conf.j2, vhost_glpi.conf.j2}
```
- **Correctif propose** : Conserver uniquement le rôle Ansible reverse_proxy (référencé par site.yaml et le PRA) et supprimer ou archiver explicitement le répertoire infra/.
- **Verdict verification** : confiance haute — Constat confirmé par lecture du code. (1) infra/dmz_vlan20/ contient bien docker-compose.yml (image nginx:stable-alpine, montage `./certs:/etc/nginx/certs:ro` attendant fullchain.pem/privkey.pem fournis sur l'hôte), nginx.conf statique (blocs `events {}` l.16 et `http {}` l.20, donc un nginx.conf complet) et provision_nginx.sh (pct exec, apt-get install nginx, auto-signé openssl dans le CT 101 avec symlinks /etc/nginx/certs/{privkey,fullchain}.pem -> /etc/ssl/* — Steps 3-4, l.109-136 — puis pct push de ce même nginx.conf et systemctl enable/restart). Les deux approches TLS sont bien incompatibles : certs hôte montés vs auto-signé généré dans le conteneur. (2) Le rôle Ansible reverse_proxy (templates nginx.conf.j2 + vhost_glpi.conf.j2) est la voie réellement utilisée : site.yaml l.70 et pra_restore_full.yaml l.74 le référencent ; rien ne référence infra/. (3) Le README ne mentionne pas le répertoire infra/ (seule occurrence de « infra » : « Infrastructure as Code » l.4). Trois implémentations concurrentes non documentées du même proxy constituent un vrai risque de dérive/confusion opérationnelle (notamment en PRA). Sévérité « moyenne » appropriée : pas d'impact direct en exécution puisque seul le rôle Ansible est câblé dans les playbooks.

### moyenne-34. Comptes admin par défaut (Admin/zabbix, glpi/glpi) conservés, simple rappel verbal
- **Fichier** : `infra/lan_admin_vlan30/provision_zabbix.sh` (ligne ~224) — categorie : securite — zone : infra-dmz
- **Description** : La contrainte projet impose qu'aucun compte administrateur par défaut ne soit conservé. Les scripts laissent le compte Zabbix Admin/zabbix actif et GLPI avec ses 4 comptes par défaut (glpi/glpi, tech, normal, post-only), en se limitant à un message 'CHANGE IMMEDIATELY' affiché en fin de script — étape manuelle non tracée, contraire à la règle 'aucun clic-clic manuel'. Le répertoire ${GLPI_DIR}/install n'est pas non plus supprimé automatiquement (simple suggestion en NEXT STEPS dans provision_glpi.sh ligne 235).
- **Extrait** :
```
printf " %-24s : %s\n" "Default web creds" "Admin / zabbix — CHANGE IMMEDIATELY after first login"
```
- **Correctif propose** : Automatiser : UPDATE users SET passwd=... (Zabbix) / désactivation des comptes GLPI par défaut et rm -rf ${GLPI_DIR}/install dans le script ou via le rôle Ansible, avec mot de passe issu du vault.
- **Verdict verification** : confiance haute — Confirmé par lecture intégrale du code. provision_zabbix.sh ligne 224 contient bien l'extrait cité ("Default web creds : Admin / zabbix — CHANGE IMMEDIATELY after first login") et les lignes 236-238 ne proposent qu'un changement manuel via l'UI (Administration → Users → Admin). Aucune commande SQL/API n'automatise le changement du mot de passe Admin ni la désactivation des comptes par défaut. Côté GLPI, provision_glpi.sh lignes 234-235 se contente de suggérer en NEXT STEPS "pct exec ... rm -rf ${GLPI_DIR}/install" sans l'exécuter, et aucun traitement des comptes glpi/tech/normal/post-only n'existe. Une recherche dans tout le dépôt (yml/sh) ne révèle aucun garde-fou ailleurs (pas de rôle Ansible, pas d'UPDATE users). Cela contrevient aux règles CLAUDE.md "aucun compte administrateur par défaut conservé" et "aucun clic-clic manuel non tracé". Sévérité moyenne appropriée : services sur LAN_ADMIN (VLAN 30) non directement exposés, mais GLPI est servi via le reverse proxy DMZ, ce qui rend les credentials par défaut exploitables tant que l'étape manuelle n'est pas faite.

## Severite : basse (34)

### basse-1. Incohérence des chemins de sauvegarde entre dump et restauration
- **Fichier** : `pra_restore_full.yaml` (ligne ~106) — categorie : pra — zone : pra
- **Description** : Le script de dump écrit dans /var/backups/glpi/glpi_backup_*.sql.gz sur atldb01p, mais la restauration full cherche /var/backups/atlas/db-remote/*.sql.gz sur atlbkp01p et la granulaire documente /var/backups/atlas/db/glpi_dump_*.sql.gz. Trois chemins et deux conventions de nommage (glpi_backup_ vs glpi_dump_) incohérents : rien dans la zone auditée ne montre comment les dumps locaux arrivent en db-remote, et un opérateur suivant le runbook du dump ne trouvera pas les fichiers attendus par les playbooks.
- **Extrait** :
```
ls -t /var/backups/atlas/db-remote/*.sql.gz | head -1  (vs dump_mariadb.sh : BACKUP_DIR="/var/backups/glpi", BACKUP_FILE=...glpi_backup_${TIMESTAMP}.sql.gz)
```
- **Correctif propose** : Unifier la convention (un seul préfixe et une seule arborescence /var/backups/atlas/db), documenter et versionner le mécanisme de réplication atldb01p → atlbkp01p (rsync/pull cron) — c'est lui qui détermine le RPO réel, pas la fréquence du dump local.
- **Verdict verification** : confiance haute — Constat partiellement exact mais sa thèse centrale est fausse. La chaîne Ansible réellement déployée est cohérente et complète : roles/mariadb/templates/dump_glpi.sh.j2 écrit glpi_dump_*.sql.gz dans /var/backups/atlas/db (mariadb_backup_dir, cron déployé par roles/mariadb/tasks/backup_script.yaml), puis roles/backup/templates/collect_dumps.sh.j2 (versionné, planifié par roles/backup/tasks/cron.yaml à 02h30) rsync /var/backups/atlas/db (atldb01p) vers /var/backups/atlas/db-remote (atlbkp01p, backup_db_remote_dest dans roles/backup/vars/main.yaml). L'affirmation « rien dans la zone auditée ne montre comment les dumps arrivent en db-remote » et « mécanisme non versionné » est donc réfutée — pra_restore_full.yaml:106 (ls -t /var/backups/atlas/db-remote/*.sql.gz) trouve bien les fichiers collectés, et la granulaire (/var/backups/atlas/db) est cohérente avec le rôle mariadb. Ce qui reste réel : un script legacy doublon scripts_pra/backup/dump_mariadb.sh (BACKUP_DIR=/var/backups/glpi, préfixe glpi_backup_) et docs/DAT.md §277-288 documentent une convention différente jamais collectée par collect_dumps — un opérateur suivant ce runbook-là serait induit en erreur. Incohérence documentaire/legacy réelle mais sans impact sur les playbooks PRA : sévérité ramenée de haute à basse. (Note hors périmètre : la collecte quotidienne à 02h30 vs dump toutes les 15 min pose un vrai problème de RPO, mais ce n'est pas ce que dit ce constat.)

### basse-2. Le serveur de sauvegarde est configuré en dernier, après l'application
- **Fichier** : `site.yaml` (ligne ~89) — categorie : pra — zone : orchestration
- **Description** : Le play backup (atlbkp01p) arrive après mariadb, glpi et même zabbix. Lors d'un déploiement complet (ou d'une reconstruction PRA via site.yaml), la base et GLPI sont en production sans qu'aucun mécanisme de sauvegarde ne soit en place pendant toute la durée des plays intermédiaires ; en cas d'échec du playbook avant le play backup, l'infrastructure tourne sans sauvegarde, ce qui compromet le RPO de 20 minutes.
- **Extrait** :
```
- name: "Configuration du serveur de sauvegarde"
  hosts: atlbkp01p
  gather_facts: true
  roles:
    - role: backup
      tags: [backup]
```
- **Correctif propose** : Remonter le play backup juste après common/mariadb (avant la mise en service de GLPI), afin que la chaîne de sauvegarde soit opérationnelle dès que des données existent.
- **Verdict verification** : confiance haute — Le fait est exact : dans C:/Users/BEDANI/Documents/Atlas/Atlas/site.yaml, le play backup (atlbkp01p, l.89-94) arrive après mariadb (l.42), glpi (l.58), reverse_proxy (l.65) et les deux plays zabbix (l.74-86). L'extrait cité est conforme au code. En revanche, la sévérité « moyenne » est exagérée : lors d'un déploiement initial, aucune donnée de production n'existe encore (les données de démo glpi_seed sont chargées en tout dernier, l.113), et lors d'une reconstruction PRA, le serveur de sauvegarde source des données restaurées existe nécessairement déjà. La fenêtre sans sauvegarde se limite à quelques minutes d'exécution de plays intermédiaires, et le RPO de 20 min n'est compromis que dans le scénario improbable d'un échec du playbook combiné à une mise en production immédiate. Défaut d'ordonnancement réel mais mineur ; le correctif proposé (remonter le play backup après mariadb) reste pertinent.

### basse-3. Sécurisation incomplète : comptes root distants non supprimés
- **Fichier** : `roles/mariadb/tasks/secure.yaml` (ligne ~40) — categorie : securite — zone : donnees
- **Description** : L'équivalent mysql_secure_installation est partiel : les utilisateurs anonymes et la base de test sont supprimés, mais aucune tâche ne supprime les comptes root accessibles à distance (root@'%' ou root@<hostname>), étape standard de la sécurisation. Le bind-address restreint l'exposition mais un compte root non-localhost resterait utilisable depuis les IP autorisées par UFW.
- **Extrait** :
```
# ─── Suppression des utilisateurs anonymes ───
... # ─── Suppression de la base de test ───
(aucune tâche pour les root distants)
```
- **Correctif propose** : Ajouter une tâche : DELETE FROM mysql.global_priv WHERE User='root' AND Host NOT IN ('localhost','127.0.0.1','::1'); FLUSH PRIVILEGES; (avec garde-fou de vérification comme pour les anonymes).
- **Verdict verification** : confiance haute — Confirmé : secure.yaml (lignes 40-60) ne traite que les utilisateurs anonymes et la base test ; aucune tâche du rôle ne supprime les root distants, et grep sur tout le dépôt ne montre aucune mitigation ailleurs. Le serveur écoute sur le réseau (mariadb_bind_address: "10.30.0.10" dans defaults/main.yaml), donc un éventuel compte root non-localhost serait exploitable depuis le VLAN 30. Toutefois, les paquets MariaDB Debian/Ubuntu récents ne créent par défaut que root@localhost (unix_socket) : le risque est conditionnel à l'existence préalable d'un root distant. C'est un manque de durcissement réel (étape standard de mysql_secure_installation, cohérent avec la règle « aucun compte admin par défaut conservé ») mais d'exploitabilité faible, d'où une sévérité abaissée à basse.

### basse-4. Commandes mysql sur atldb01p sans identifiants ni base paramétrée
- **Fichier** : `roles/glpi_seed/tasks/api_enable.yaml` (ligne ~12) — categorie : fiabilite — zone : web
- **Description** : Les tâches déléguées à atldb01p invoquent « mysql glpi_db » sans option -u/-p : elles ne fonctionnent que si l'utilisateur de connexion Ansible bénéficie d'une authentification unix_socket root sur MariaDB, ce qui n'est ni garanti ni du moindre privilège. De plus le nom de base « glpi_db » est codé en dur alors que la connexion GLPI utilise vault_glpi_db_name (risque d'incohérence).
- **Extrait** :
```
ansible.builtin.command: >
    mysql glpi_db -N -e
```
- **Correctif propose** : Utiliser community.mysql.mysql_query avec un compte dédié à droits limités (UPDATE/SELECT sur glpi_users, glpi_configs) et référencer vault_glpi_db_name au lieu du nom en dur.
- **Verdict verification** : confiance moyenne — L'extrait existe bien (lignes 12-13, 31-32, 40-41 de roles/glpi_seed/tasks/api_enable.yaml) : trois appels « mysql glpi_db -N -e » sans -u/-p ni module mysql, délégués à atldb01p. Le constat est donc factuel : ces tâches reposent sur l'auth unix_socket root (défaut Debian/MariaDB), pas du moindre privilège, et « glpi_db » est codé en dur alors que vault_glpi_db_name existe (develop/group_vars/all/vault.yaml.example:25, utilisé dans roles/glpi/templates/config_db.php.j2). Cependant la sévérité « moyenne » est exagérée : ce motif est la convention uniforme de tout le dépôt — roles/mariadb/tasks/databases.yaml (mysql -e sans identifiants pour CREATE DATABASE/GRANT), roles/mariadb/templates/dump_glpi.sh.j2 et les playbooks pra_restore_*.yaml utilisent exactement le même schéma. Ansible se connecte en root (cf. bastion ssh_config.j2 « User root »), donc l'unix_socket root fonctionne de fait ; le risque de défaillance réel est faible et le nom en dur est cohérent partout (vault.yaml.example fixe d'ailleurs glpi_db). Problème réel mais d'hygiène/moindre privilège, pas de fiabilité immédiate : sévérité basse.

### basse-5. Fichier docker-compose.yml vide (0 octet)
- **Fichier** : `infra/lan_admin_vlan30/docker-compose.yml` (ligne ~0) — categorie : qualite — zone : infra-dmz
- **Description** : Le fichier infra/lan_admin_vlan30/docker-compose.yml fait 0 octet. Il ne déploie rien : toute personne suivant l'arborescence infra/ pour déployer la zone LAN_ADMIN via Docker Compose échouera (docker compose lèvera une erreur 'empty compose file'). C'est un livrable fantôme qui crée une fausse impression de parité avec infra/dmz_vlan20/docker-compose.yml.
- **Extrait** :
```
0 infra/lan_admin_vlan30/docker-compose.yml (taille en octets)
```
- **Correctif propose** : Supprimer le fichier, ou le remplir avec une stack GLPI/MariaDB cohérente. Si le déploiement LAN_ADMIN passe uniquement par provision_glpi.sh / les rôles Ansible, supprimer le fichier et documenter ce choix.
- **Verdict verification** : confiance haute — Confirmé : infra/lan_admin_vlan30/docker-compose.yml fait exactement 0 octet (vérifié via Get-Item), alors que infra/dmz_vlan20/docker-compose.yml (4435 octets) est rempli — l'asymétrie dénoncée est réelle. Aucune mitigation trouvée : le fichier n'est pas généré ailleurs ni ignoré. Toutefois le répertoire contient provision_glpi.sh et provision_zabbix.sh qui assurent le déploiement réel de la zone ; le fichier vide est donc un défaut de propreté/documentation sans impact sécurité ni PRA. Sévérité ramenée de moyenne à basse.

### basse-6. En-tête des tags incomplet (grafana, testlab, glpi_seed absents)
- **Fichier** : `site.yaml` (ligne ~6) — categorie : qualite — zone : orchestration
- **Description** : Le commentaire d'usage en tête de site.yaml liste les tags disponibles mais omet grafana, testlab et glpi_seed, pourtant définis plus bas dans le playbook. Un opérateur se fiant à l'en-tête (notamment en situation PRA) ignorera ces cibles ou croira à une erreur de tag.
- **Extrait** :
```
# Tags : proxmox_network, proxmox_provision, common, bastion,
#        reverse_proxy, glpi, mariadb, smtp, zabbix, backup
```
- **Correctif propose** : Compléter l'en-tête : ajouter grafana, testlab et glpi_seed à la liste des tags documentés.
- **Verdict verification** : confiance haute — Confirmé : l'en-tête de site.yaml (lignes 6-7) liste bien "proxmox_network, proxmox_provision, common, bastion, reverse_proxy, glpi, mariadb, smtp, zabbix, backup" mais omet les tags grafana (l.102), testlab (l.110) et glpi_seed (l.118), pourtant définis dans le playbook. Aucune autre documentation interne au fichier ne les mentionne. Constat factuel, purement documentaire — la sévérité basse est appropriée.

### basse-7. IP publique et identifiants d'API réels exposés dans le fichier d'exemple versionné
- **Fichier** : `develop/group_vars/all/vault.yaml.example` (ligne ~14) — categorie : securite — zone : orchestration
- **Description** : Le fichier .example (versionné, contrairement à vault.yaml) contient l'IP publique réelle de l'hyperviseur (138.201.135.108, confirmée dans ansible.cfg et hosts.yaml), l'utilisateur root@pam et l'identifiant de jeton. Seul le secret est en CHANGE_ME : la surface de reconnaissance (cible, compte, nom de token) est dans le VCS. De plus, le token est créé avec --privsep 0, c'est-à-dire avec tous les privilèges de root@pam, contraire au moindre privilège.
- **Extrait** :
```
#   pveum user token add root@pam ansible --privsep 0
vault_proxmox_host: "138.201.135.108"
vault_proxmox_user: "root@pam"
vault_proxmox_token_id: "ansible"
```
- **Correctif propose** : Mettre des valeurs placeholder dans le .example (vault_proxmox_host: "CHANGE_ME"), créer un utilisateur API dédié (ex: ansible@pve) avec un rôle restreint et un token privilege-separated au lieu de root@pam --privsep 0.
- **Verdict verification** : confiance haute — Constat confirmé. Le fichier develop/group_vars/all/vault.yaml.example est bien suivi par git (git ls-files le liste, seul vault.yaml est dans .gitignore) et contient exactement l'extrait cité : vault_proxmox_host: "138.201.135.108" (l.14), vault_proxmox_user: "root@pam" (l.15), vault_proxmox_token_id: "ansible" (l.16), et le commentaire l.12 recommande `pveum user token add root@pam ansible --privsep 0` (token sans séparation de privilèges = pleins pouvoirs root, contraire au moindre privilège du CLAUDE.md). L'IP est réelle et confirmée dans ansible.cfg (l.3) et develop/hosts.yaml (l.11), eux aussi versionnés. Aucune mitigation ailleurs. Sévérité basse correcte : le secret du token reste en CHANGE_ME et l'IP est de toute façon déjà exposée dans hosts.yaml versionné ; il s'agit de surface de reconnaissance plus que de fuite de secret.

### basse-8. Rotation 48 h fausse : -mtime +2 supprime au-delà de 3 jours
- **Fichier** : `scripts_pra/backup/dump_mariadb.sh` (ligne ~75) — categorie : bug — zone : pra
- **Description** : RETENTION_HOURS=48 converti en -mtime +2 : find -mtime +2 ne supprime que les fichiers de plus de 72 h (l'âge est tronqué en jours entiers, +2 signifie strictement plus de 2 jours révolus). La rétention réelle est ~3 jours, pas 48 h, ce qui triple le volume stocké par rapport à la doc (dump_mariadb.md annonce 48 h).
- **Extrait** :
```
find "${BACKUP_DIR}" -maxdepth 1 -name "*.sql.gz" -mtime "+$((RETENTION_HOURS / 24))" -delete
```
- **Correctif propose** : Utiliser -mmin "+$((RETENTION_HOURS * 60))" pour une rétention exacte en heures.
- **Verdict verification** : confiance haute — Confirmé. Ligne 40 : RETENTION_HOURS=48 ; ligne 75 : `find "${BACKUP_DIR}" -maxdepth 1 -name "*.sql.gz" -mtime "+$((RETENTION_HOURS / 24))" -delete` — l'extrait cité est exact, et le commentaire ligne 73 annonce bien « suppression des fichiers de plus de 48 heures ». Or 48/24=2 et la sémantique POSIX de -mtime +2 (âge tronqué en jours entiers, strictement supérieur) ne supprime que les fichiers de plus de 72 h. Aucune mitigation ailleurs (pas de seconde rotation, pas de surcharge de variable). Avec un cron toutes les 15 min, la rétention réelle est ~3 jours au lieu de 2 (~288 dumps au lieu de ~192, +50 % de volume, pas un triplement comme annoncé — la description exagère légèrement l'impact). Pas d'impact sur RPO/RTO ni sécurité : sévérité basse correcte. Correctif -mmin "+$((RETENTION_HOURS * 60))" valide.

### basse-9. Entrée cron incohérente et contraire au moindre privilège
- **Fichier** : `scripts_pra/backup/dump_mariadb.sh` (ligne ~8) — categorie : qualite — zone : pra
- **Description** : L'en-tête recommande « crontab -e en tant que root » avec une ligne au format /etc/cron.d (champ utilisateur 'root') : dans un crontab utilisateur, 'root' serait interprété comme le début de la commande et le cron échouerait. De plus elle exécute le script en root, contredisant le commentaire ligne 10-11 et le runbook .md qui prescrit /etc/cron.d avec l'utilisateur glpi_backup.
- **Extrait** :
```
# */15 * * * * root /scripts_pra/backup/dump_mariadb.sh
```
- **Correctif propose** : Aligner l'en-tête sur le runbook : fichier /etc/cron.d/glpi-backup avec '*/15 * * * * glpi_backup /scripts_pra/backup/dump_mariadb.sh'.
- **Verdict verification** : confiance haute — Vérifié dans scripts_pra/backup/dump_mariadb.sh : ligne 7 « Crontab recommandée (ajouter via : crontab -e en tant que root) » suivie ligne 8 de « # */15 * * * * root /scripts_pra/backup/dump_mariadb.sh » (format /etc/cron.d à 6 champs, invalide dans un crontab utilisateur où 'root' serait pris pour la commande). Contradiction interne avec les lignes 10-11 (« DOIT être exécuté par glpi_backup ») et avec le runbook dump_mariadb.md (lignes 61-64) qui prescrit /etc/cron.d/glpi-backup avec l'utilisateur glpi_backup, conforme au moindre privilège du DAT. Aucune mitigation ailleurs. Impact limité à un commentaire/documentation : sévérité basse appropriée.

### basse-10. Vérification post-restore en HTTP direct, TLS/reverse proxy non testés
- **Fichier** : `pra_restore_full.yaml` (ligne ~174) — categorie : pra — zone : pra
- **Description** : La vérification finale interroge http://10.20.0.11/ (l'app en direct, en clair). Le reverse proxy TLS — obligatoire selon CLAUDE.md et point d'entrée réel des utilisateurs — n'est jamais testé : le PRA peut être déclaré réussi alors que la chaîne TLS (cert restauré hors VCS, vhost nginx) est cassée.
- **Extrait** :
```
url: "http://10.20.0.11/"
```
- **Correctif propose** : Ajouter une vérification uri sur https://<vip_du_reverse_proxy>/ avec validate_certs adapté, en plus du check direct de l'app.
- **Verdict verification** : confiance haute — Confirmé : pra_restore_full.yaml ligne 175 contient bien `url: "http://10.20.0.11/"`, unique check HTTP du playbook, en clair et directement sur l'app GLPI. Le rôle reverse_proxy est redéployé (lignes 70-74) mais aucune vérification (uri HTTPS, wait_for 443) ne teste atlrp01p ni la chaîne TLS avant de déclarer le PRA terminé et de mesurer le RTO. Aucune mitigation ailleurs dans le fichier. Sévérité basse justifiée : lacune de couverture de test, pas de faille directe.

### basse-11. Clé publique SSH atladm codée en dur dans les defaults
- **Fichier** : `roles/proxmox_provision/defaults/main.yaml` (ligne ~7) — categorie : securite — zone : proxmox
- **Description** : La clé publique (non secrète mais identifiante) est figée dans le rôle. En cas de rotation de la clé de l'opérateur ou de PRA sur un autre poste, il faut modifier le code du rôle ; et tous les conteneurs partagent une unique clé root.
- **Extrait** :
```
proxmox_provision_ssh_pubkey: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICGExy+C98JHFxEVLa3pi7P3EGdCDLHcsmKYpIldns2j atladm@atlas"
```
- **Correctif propose** : Charger la clé depuis l'inventaire/group_vars (lookup('file', ...)) plutôt que dans defaults du rôle, et documenter la procédure de rotation dans le runbook PRA.
- **Verdict verification** : confiance haute — Confirmé : la ligne 7 de roles/proxmox_provision/defaults/main.yaml contient bien la clé codée en dur, utilisée pour tous les conteneurs via tasks/create_lxc_item.yaml (pubkey: "{{ proxmox_provision_ssh_pubkey }}"). Aucune surcharge dans group_vars/inventaire trouvée, et la même clé est dupliquée dans roles/common/defaults/main.yaml (common_ssh_pubkey), aggravant le risque de divergence lors d'une rotation. Une clé publique n'est pas un secret (pas de violation de la règle "secrets hors VCS"), c'est un problème de maintenabilité/rotation : sévérité "basse" appropriée.

### basse-12. Bridge vmbr0 codé en dur dans netif au lieu de la variable du rôle réseau
- **Fichier** : `roles/proxmox_provision/tasks/create_lxc_item.yaml` (ligne ~28) — categorie : qualite — zone : proxmox
- **Description** : Le rôle proxmox_network expose proxmox_network_bridge (défaut vmbr0), mais le provisioning code en dur bridge=vmbr0 dans netif. Si le bridge est renommé via la variable, les conteneurs seront attachés au mauvais bridge sans erreur de syntaxe.
- **Extrait** :
```
netif: '{"net0":"name=eth0,bridge=vmbr0,ip={{ conteneur.ip }}/24,gw={{ conteneur.gw }},tag={{ conteneur.vlan }}"}'
```
- **Correctif propose** : Utiliser bridge={{ proxmox_network_bridge | default('vmbr0') }} dans le netif pour garder une source unique.
- **Verdict verification** : confiance haute — Constat confirmé. L'extrait cité existe mot pour mot à la ligne 28 de roles/proxmox_provision/tasks/create_lxc_item.yaml : netif: '{"net0":"name=eth0,bridge=vmbr0,...}'. Le rôle proxmox_network définit bien proxmox_network_bridge: "vmbr0" (roles/proxmox_network/defaults/main.yaml:8) et l'utilise partout (vlan_bridge.yaml, atlas-vlans.cfg.j2), tandis que le rôle proxmox_provision n'a aucune variable de bridge ni garde-fou : un renommage du bridge via la variable laisserait le provisioning attacher silencieusement les LXC à vmbr0. Aucune mitigation trouvée ailleurs. Nuance qui maintient la sévérité basse : c'est une duplication inter-rôles (le couplage proposé entre rôles est lui-même discutable ; une variable de défaut propre au rôle provision serait préférable), et vmbr0 est codé en dur de façon cohérente dans scripts/setup_vlan_routing.sh et infra/proxmox_iac/deploy_lxc.sh — c'est un problème de qualité/source unique de vérité, sans impact fonctionnel actuel. Sévérité « basse » correcte.

### basse-13. Masque /24 codé en dur ignorant vlan.subnet
- **Fichier** : `roles/proxmox_network/templates/atlas-vlans.cfg.j2` (ligne ~9) — categorie : qualite — zone : proxmox
- **Description** : L'adresse de la passerelle est toujours suffixée /24 alors que chaque VLAN définit un champ subnet. Si un sous-réseau change de masque dans proxmox_network_vlans, le template produira une configuration incohérente silencieusement.
- **Extrait** :
```
address {{ vlan.gw }}/24
```
- **Correctif propose** : Dériver le préfixe du champ subnet : address {{ vlan.gw }}/{{ vlan.subnet | ansible.utils.ipaddr('prefix') }}.
- **Verdict verification** : confiance haute — Confirmé. Ligne 9 de roles/proxmox_network/templates/atlas-vlans.cfg.j2 : « address {{ vlan.gw }}/24 » avec le masque codé en dur, alors que chaque entrée de proxmox_network_vlans (defaults/main.yaml) porte un champ subnet (ex. "10.20.0.0/24") déjà utilisé ailleurs (templates/rules.v4.j2 pour FORWARD/NAT). Aucun garde-fou ni dérivation du préfixe ailleurs dans le rôle. Impact aujourd'hui nul (tous les VLAN définis sont en /24), donc incohérence latente uniquement : sévérité basse appropriée.

### basse-14. pct destroy bloqué par la protection posée par deploy_lxc.sh, sans gestion
- **Fichier** : `scripts/reset_proxmox_atlas.sh` (ligne ~94) — categorie : pra — zone : proxmox
- **Description** : deploy_lxc.sh active --protection 1 sur ses conteneurs ; pct destroy --purge échoue alors systématiquement et le script se contente de logger « passage au suivant », laissant un reset incomplet (problématique en exercice PRA où le temps est compté). Aucune option pour lever la protection n'est prévue.
- **Extrait** :
```
if pct destroy "${vmid}" --purge; then
```
- **Correctif propose** : Après confirmation explicite, lever la protection avant destruction : « pct set "${vmid}" --protection 0 » puis pct destroy, et faire échouer le script (exit != 0) si au moins une destruction a échoué.
- **Verdict verification** : confiance haute — Confirmé. deploy_lxc.sh (infra/proxmox_iac/deploy_lxc.sh:124) active `pct set "${ctid}" --protection 1` sur tous les conteneurs Atlas (documenté dans docs/DAT.md:155). Or scripts/reset_proxmox_atlas.sh ligne 94 exécute `if pct destroy "${vmid}" --purge; then` sans jamais faire `pct set --protection 0` : avec la protection active, pct destroy échoue systématiquement, le script logge seulement « échec ... passage au suivant » (ligne 98) et termine avec exit 0 et un compteur 0/N. Aucune option ni garde-fou ailleurs dans le script. Le reset PRA est donc inopérant sur ces conteneurs, mais sans destruction de données ni faille sécurité : sévérité basse appropriée.

### basse-15. Installation de jq sans apt-get update préalable
- **Fichier** : `scripts/reset_proxmox_atlas.sh` (ligne ~40) — categorie : fiabilite — zone : proxmox
- **Description** : Sur un hôte au cache APT vide ou périmé, apt-get install -y jq peut échouer (404 sur les paquets), interrompant le script via set -e avant même la phase de confirmation.
- **Extrait** :
```
DEBIAN_FRONTEND=noninteractive apt-get install -y jq
```
- **Correctif propose** : Exécuter « apt-get update -qq » avant l'installation, ou faire de jq un prérequis vérifié avec message d'erreur explicite.
- **Verdict verification** : confiance haute — Constat confirmé. Lignes 36-41 de scripts/reset_proxmox_atlas.sh : si jq est absent, le script exécute « DEBIAN_FRONTEND=noninteractive apt-get install -y jq » sans aucun « apt-get update » préalable, et aucun autre fichier ne mitige cela (le script est autonome, lancé manuellement sur l'hôte Proxmox). Avec « set -euo pipefail » (ligne 14), un échec d'installation (cache APT vide/périmé, 404) interrompt le script. L'impact reste limité : c'est un échec précoce, avant toute action destructive (la confirmation est ligne 79, les destructions lignes 89+), donc aucun risque pour les données — uniquement un confort/fiabilité d'exécution. La sévérité « basse » est correcte.

### basse-16. Un seul serveur NTP, non paramétrable, sans FallbackNTP
- **Fichier** : `roles/common/templates/timesyncd.conf.j2` (ligne ~7) — categorie : fiabilite — zone : socle
- **Description** : La configuration NTP est codée en dur sur pool.ntp.org sans FallbackNTP ni variable. Les hôtes du VLAN 30 (LAN ADMIN) n'ont pas forcément de sortie Internet ; une dérive d'horloge fausse les horodatages des sauvegardes et de la réplication, éléments clés du suivi RPO (<=20 min).
- **Extrait** :
```
[Time]
NTP=pool.ntp.org
```
- **Correctif propose** : Paramétrer NTP via une variable de rôle (ex. common_ntp_servers, défaut un serveur interne MGMT + pool.ntp.org en FallbackNTP) et ajouter une ligne FallbackNTP.
- **Verdict verification** : confiance haute — Confirmé : roles/common/templates/timesyncd.conf.j2 contient exactement "[Time]\nNTP=pool.ntp.org" (ligne 7), sans FallbackNTP ni variable Jinja. defaults/main.yaml du rôle common ne définit aucune variable NTP et un grep du dépôt ne révèle aucune surcharge ailleurs ; tasks/ntp.yaml déploie ce template tel quel sur tous les hôtes (dont VLAN 30). Le risque reste modéré (timesyncd retente, dérive lente, impact RPO indirect), la sévérité "basse" est appropriée.

### basse-17. chmod récursif g+rx ponctuel : dérive sur les nouveaux dumps et tâche non idempotente
- **Fichier** : `roles/backup/tasks/scripts.yaml` (ligne ~8) — categorie : idempotence — zone : donnees
- **Description** : La tâche applique mode g+rx récursivement au moment du run Ansible seulement : les dumps créés ensuite par cron héritent du groupe root (et non atlsvc) selon l'umask, et le mode symbolique avec recurse rend la tâche 'changed' à chaque nouveau fichier. De plus g+rx ajoute le bit d'exécution aux fichiers .sql.gz, inutilement. La lisibilité effective repose en réalité sur le 0644 par défaut des fichiers, pas sur cette tâche.
- **Extrait** :
```
ansible.builtin.file:
    path: "{{ backup_db_dumps_dir }}"
    state: directory
    group: "{{ backup_remote_user }}"
    mode: "g+rx"
    recurse: true
```
- **Correctif propose** : Supprimer le recurse et garantir les droits à la source : dans dump_glpi.sh, créer le fichier avec install -g atlsvc -m 0640, ou poser le setgid sur le répertoire (chmod 2750, groupe atlsvc).
- **Verdict verification** : confiance haute — Constat confirmé. L'extrait existe à l'identique (roles/backup/tasks/scripts.yaml l.8-15 : file path={{ backup_db_dumps_dir }}, group atlsvc, mode "g+rx", recurse: true, delegate_to atldb01p). Le script roles/mariadb/templates/dump_glpi.sh.j2 crée les dumps via `gzip > "${FICHIER}"` en root (cron user: root, horaire à :30) sans chown/chmod/umask ni setgid : les nouveaux fichiers naissent root:root 0644. La tâche Ansible recursive ne corrige donc le groupe et le mode qu'au moment du run ; chaque nouveau dump rend la tâche 'changed' (changement de groupe root→atlsvc + g+rx ajoute un bit x inutile aux .sql.gz) : non idempotente, comme décrit. La lisibilité par atlsvc repose effectivement sur le 0644 par défaut (world-readable), pas sur cette tâche ; le répertoire est déjà géré proprement ailleurs (roles/mariadb/tasks/backup_script.yaml l.20-29 : 0750 root:atlsvc, sans setgid). Aucune mitigation (pas de umask/install/chmod dans le script). Sévérité basse appropriée : impact limité à l'idempotence et un bit x cosmétique, pas de rupture fonctionnelle ni de faille notable.

### basse-18. ALL PRIVILEGES accordé au compte applicatif GLPI
- **Fichier** : `roles/mariadb/tasks/databases.yaml` (ligne ~39) — categorie : securite — zone : donnees
- **Description** : glpi_user@10.20.0.11 reçoit ALL PRIVILEGES sur glpi_db.*, ce qui inclut DROP, ALTER, CREATE, LOCK TABLES, etc. GLPI a besoin de droits étendus lors des installations/migrations, mais en fonctionnement courant SELECT/INSERT/UPDATE/DELETE suffisent. Une compromission de l'application permet la destruction complète de la base (DROP DATABASE). Écart au principe de moindre privilège affiché par le projet, à arbitrer.
- **Extrait** :
```
ansible.builtin.command: mysql -e "GRANT ALL PRIVILEGES ON glpi_db.* TO 'glpi_user'@'10.20.0.11';"
```
- **Correctif propose** : Restreindre à la liste de privilèges requise par GLPI (SELECT, INSERT, UPDATE, DELETE, et temporairement CREATE/ALTER/DROP/INDEX/REFERENCES pendant les migrations), ou documenter l'acceptation du risque.
- **Verdict verification** : confiance haute — Confirmé : lignes 39-43 de roles/mariadb/tasks/databases.yaml contiennent exactement "GRANT ALL PRIVILEGES ON glpi_db.* TO 'glpi_user'@'10.20.0.11'", sans restriction ni révocation ultérieure ailleurs dans le fichier. Aucune mitigation : le grant est permanent (garde idempotente ligne 41 seulement). C'est un écart au principe de moindre privilège affiché dans CLAUDE.md. Sévérité "basse" appropriée : le grant est limité à glpi_db.* (pas de GRANT OPTION, pas de privilèges globaux), restreint à une IP source (10.20.0.11, l'app), et GLPI exige effectivement des droits DDL lors des installations/migrations — pratique courante et documentée par GLPI. À noter que le compte Zabbix (lignes 65-69) reçoit lui correctement SELECT seul, signe que le moindre privilège a été appliqué là où c'était simple. Arbitrage/documentation du risque recommandé, pas critique.

### basse-19. Host transmis au backend ne correspond pas au server_name du vhost GLPI
- **Fichier** : `roles/reverse_proxy/templates/vhost_glpi.conf.j2` (ligne ~34) — categorie : fiabilite — zone : web
- **Description** : Le proxy transmet Host: atlas.internal ($host), alors que le vhost backend (roles/glpi/templates/vhost_glpi.conf.j2) déclare server_name atlapp01p.atlas.local. Cela ne fonctionne aujourd'hui que parce que le site default est supprimé et que glpi.conf devient le serveur par défaut implicite — comportement fragile si un autre vhost est ajouté sur atlapp01p.
- **Extrait** :
```
proxy_set_header Host $host;
```
- **Correctif propose** : Aligner les noms : ajouter atlas.internal au server_name du vhost backend, ou marquer le vhost backend default_server explicitement.
- **Verdict verification** : confiance haute — Confirmé : le proxy envoie « proxy_set_header Host $host » (ligne 34) avec server_name atlas.internal (reverse_proxy/defaults/main.yaml: reverse_proxy_server_name: "atlas.internal"), alors que le backend (roles/glpi/templates/vhost_glpi.conf.j2:8) déclare server_name atlapp01p.atlas.local sans default_server ni alias atlas.internal. Le routage ne tient que parce que roles/glpi/tasks/configure.yaml:36 supprime sites-enabled/default, faisant du vhost GLPI le serveur par défaut implicite. Fragilité réelle mais sans impact immédiat : sévérité basse appropriée.

### basse-20. IP du backend codée en dur dans la vérification HTTP
- **Fichier** : `roles/glpi/tasks/service.yaml` (ligne ~29) — categorie : qualite — zone : web
- **Description** : La vérification utilise l'adresse 10.20.0.11 en dur au lieu d'une variable (ansible_host ou variable de rôle), alors que le rôle reverse_proxy paramètre cette même IP via reverse_proxy_backend_ip. Toute renumérotation casserait silencieusement le check.
- **Extrait** :
```
url: "http://10.20.0.11/"
```
- **Correctif propose** : Utiliser http://127.0.0.1/ (le check s'exécute sur l'hôte GLPI) ou une variable d'inventaire.
- **Verdict verification** : confiance haute — Confirmé : roles/glpi/tasks/service.yaml ligne 29 contient bien `url: "http://10.20.0.11/"` codé en dur, sans variable ni default dans le rôle glpi. Le rôle s'exécute sur l'hôte GLPI lui-même (atlapp01p = 10.20.0.11 dans develop/hosts.yaml), donc http://127.0.0.1/ ou {{ ansible_host }} serait préférable. À noter que d'autres rôles paramètrent cette IP via une variable avec défaut (reverse_proxy_backend_ip, zabbix_agent_glpi_url), confirmant l'incohérence de style. Impact limité : le check échouerait bruyamment (uri + until), pas vraiment « silencieusement », et l'IP est de toute façon répliquée dans une dizaine de defaults. Sévérité basse (qualité) appropriée.

### basse-21. Handler « Redémarrer php8.2-fpm » jamais notifié
- **Fichier** : `roles/glpi/handlers/main.yaml` (ligne ~8) — categorie : qualite — zone : web
- **Description** : Le handler est défini mais aucune tâche du rôle glpi ne le notifie (aucune modification de pool/php.ini n'existe d'ailleurs). Code mort qui laisse croire qu'un redémarrage FPM est géré.
- **Extrait** :
```
- name: Redémarrer php8.2-fpm
  ansible.builtin.service:
    name: php8.2-fpm
    state: restarted
```
- **Correctif propose** : Supprimer le handler, ou ajouter la configuration PHP (php.ini/pool) avec notify vers ce handler.
- **Verdict verification** : confiance haute — L'extrait cité existe à la ligne 8 de roles/glpi/handlers/main.yaml. Un grep de « notify » sur tout le rôle glpi ne renvoie que trois occurrences (tasks/configure.yaml lignes 25, 32, 38), toutes vers « Recharger nginx (glpi) ». Aucune tâche ne notifie « Redémarrer php8.2-fpm » ; tasks/php.yaml installe seulement les paquets et tasks/service.yaml démarre/active le service sans notify. Le handler équivalent du rôle zabbix est bien notifié, mais c'est un handler distinct. Code mort confirmé, sans impact fonctionnel : sévérité basse correcte.

### basse-22. config_db.php appartient à www-data (auto-modifiable)
- **Fichier** : `roles/glpi/tasks/configure.yaml` (ligne ~8) — categorie : securite — zone : web
- **Description** : Le fichier contenant le mot de passe de la base est en owner www-data mode 0640 : le processus web peut le réécrire. Le mode 0640 est bon, mais l'owner devrait être root avec groupe www-data en lecture seule.
- **Extrait** :
```
dest: "{{ glpi_data_dir }}/config/config_db.php"
    owner: www-data
    group: www-data
    mode: "0640"
```
- **Correctif propose** : owner: root, group: www-data, mode: 0640 (lecture seule pour le serveur web). Attention au chown récursif de download.yaml qui écraserait ce réglage : l'exclure.
- **Verdict verification** : confiance haute — Confirmé. roles/glpi/tasks/configure.yaml lignes 8-14 : le template config_db.php est bien déployé avec owner: www-data, group: www-data, mode 0640. Le processus PHP/nginx (www-data) peut donc réécrire le fichier contenant le mot de passe DB (et contourner le 0640 via chmod, étant propriétaire). Aucune mitigation ailleurs : download.yaml (l.72-80) fait au contraire un chown récursif www-data avec recurse: true sur /var/www/glpi et glpi_data_dir, ce qui confirme l'avertissement du correctif (un owner root serait écrasé si l'ordre des tâches changeait). Le constat est factuel, son impact reste du durcissement (défense en profondeur, nécessite déjà une compromission RCE de www-data) : sévérité basse appropriée.

### basse-23. Règle UFW trop large : 10.0.0.0/8 au lieu des VLAN Atlas
- **Fichier** : `roles/testlab/tasks/install.yaml` (ligne ~45) — categorie : securite — zone : supervision
- **Description** : Le port 80 du testlab est ouvert à tout 10.0.0.0/8, bien au-delà des trois réseaux définis par le projet (10.20.0.0/24, 10.30.0.0/24, 10.90.0.0/24). Incohérent avec les autres rôles (zabbix, grafana, smtp) qui restreignent par /24.
- **Extrait** :
```
from_ip: 10.0.0.0/8
```
- **Correctif propose** : Restreindre aux sous-réseaux nécessaires à la supervision : 10.30.0.0/24 (Zabbix) et éventuellement 10.90.0.0/24, via une boucle comme dans les autres rôles.
- **Verdict verification** : confiance haute — Confirmé : `from_ip: 10.0.0.0/8` codé en dur à la ligne 45 de roles/testlab/tasks/install.yaml, sans variable surchargeables ni garde-fou ailleurs. Tous les autres rôles (zabbix, grafana, smtp, mariadb, bastion, common) restreignent via variables/boucles sur des sous-réseaux précis. Incohérent avec le moindre privilège et les VLAN 10.20/10.30/10.90 du CLAUDE.md. Impact limité (port 80 d'un nginx de testlab, réseau privé uniquement), donc sévérité basse correcte.

### basse-24. Envoi d'un courriel de test à chaque exécution du playbook
- **Fichier** : `roles/smtp/tasks/service.yaml` (ligne ~19) — categorie : idempotence — zone : supervision
- **Description** : La tâche de vérification envoie réellement un mail à root à chaque run (le changed_when: false masque le changement mais l'effet de bord persiste). Sur des runs répétés (CI, re-déploiements), cela génère du bruit dans la boîte atlsvc et ne valide pas réellement la remise (la commande mail réussit dès la mise en file, même si Postfix ne délivre pas).
- **Extrait** :
```
- name: Envoyer un courriel de test à root
  ansible.builtin.shell: echo "Test Atlas" | mail -s "Test SMTP Atlas" root
  changed_when: false
```
- **Correctif propose** : Remplacer par une vérification passive idempotente : ansible.builtin.wait_for port 25 sur {{ smtp_listen_ip }} ou postfix check via command avec changed_when: false, et réserver l'envoi de mail réel à un tag de validation explicite (tags: [never, smoke]).
- **Verdict verification** : confiance haute — Constat confirmé. Le fichier roles/smtp/tasks/service.yaml contient bien aux lignes 18-20 la tâche « Envoyer un courriel de test à root » avec `ansible.builtin.shell: echo "Test Atlas" | mail -s "Test SMTP Atlas" root` et `changed_when: false`, sans aucun garde-fou (pas de `when`, pas de tags `never`/`smoke`, pas de condition sur smtp_debug — seule la tâche debug suivante en a une). Chaque exécution du playbook envoie donc réellement un mail (effet de bord non idempotent), et `mail` réussit dès la mise en file sans valider la remise effective par Postfix. Sévérité « basse » justifiée : bruit et faux sentiment de validation, sans impact sécurité ni PRA.

### basse-25. Capture de PIPESTATUS inopérante avec set -e -o pipefail
- **Fichier** : `roles/testlab/templates/chaos.sh.j2` (ligne ~24) — categorie : bug — zone : supervision
- **Description** : Avec set -euo pipefail, si l'écriture du journal échoue (tee en erreur, /var/log/atlas absent), le pipeline echo|tee fait quitter le script immédiatement : la ligne RC=("${PIPESTATUS[@]}") et l'avertissement qui suit ne sont jamais exécutés. Conséquence concrète : un simple problème de fichier de log fait échouer l'incident ou — plus grave — la réparation (chaos.sh clean), laissant nginx arrêté sur le lab.
- **Extrait** :
```
echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "${LOG_FILE}"
    # Piège set -u : on capture PIPESTATUS d'un bloc, sinon il est perdu
    RC=("${PIPESTATUS[@]}")
```
- **Correctif propose** : Neutraliser l'échec du pipeline pour qu'il soit réellement capturé : echo ... | tee -a "${LOG_FILE}" || vrai avertissement, par exemple : if ! echo "..." | tee -a "${LOG_FILE}"; then echo "AVERTISSEMENT..." >&2; fi. Surtout, dans reparer(), ne jamais laisser la journalisation empêcher systemctl start nginx (logger après les actions, en mode tolérant).
- **Verdict verification** : confiance haute — Confirmé : chaos.sh.j2 a `set -euo pipefail` (l.14) et la fonction log() (l.21-28) contient exactement l'extrait cité. Si `tee -a ${LOG_FILE}` échoue, le pipeline en erreur fait quitter le script avant `RC=("${PIPESTATUS[@]}")` : la capture et l'avertissement sont du code mort, et un simple problème de fichier de log fait échouer le script. Nuance : dans reparer() (l.56-61), log() est appelé après `systemctl start nginx`, donc la réparation n'est pas bloquée (l'affirmation « laissant nginx arrêté » est exagérée) ; l'impact se limite à une sortie prématurée et un code retour erroné. Sévérité basse appropriée.

### basse-26. Hôtes existants jamais mis à jour (dérive IP/groupe/template)
- **Fichier** : `roles/zabbix/tasks/register_hosts.yaml` (ligne ~146) — categorie : idempotence — zone : supervision
- **Description** : La logique en deux passes ne fait que créer les hôtes absents : si l'IP d'un conteneur change dans zabbix_monitored_hosts, ou si le template/groupe d'un hôte existant a été modifié manuellement, aucun host.update n'est effectué — la configuration Zabbix dérive silencieusement de la définition Ansible.
- **Extrait** :
```
when: item.name not in zabbix_existing_host_names
```
- **Correctif propose** : Pour les hôtes déjà présents, récupérer interfaces/groupes/templates via host.get (selectInterfaces, selectParentTemplates) et appeler host.update / hostinterface.update uniquement en cas d'écart, avec changed_when conditionnel.
- **Verdict verification** : confiance haute — Confirmé dans roles/zabbix/tasks/register_hosts.yaml : la seconde passe (ligne 146-176) n'appelle que host.create avec la condition exacte « when: item.name not in zabbix_existing_host_names » (ligne 176). Le host.get préalable (lignes 119-139) ne récupère que le champ « host » (output: [host]), sans interfaces/groupes/templates, et aucun host.update / hostinterface.update n'existe dans le rôle. Si l'IP d'un hôte change dans zabbix_monitored_hosts ou si groupe/template sont modifiés côté Zabbix, rien n'est réconcilié : la dérive est réelle et silencieuse. Aucune mitigation ailleurs. Sévérité « basse » adéquate : pas d'impact sécurité direct, c'est un défaut d'idempotence/convergence de la supervision.

### basse-27. Tâche d'activation de l'API GLPI sans changed_when ni gestion d'échec partiel
- **Fichier** : `roles/glpi_seed/tasks/api_enable.yaml` (ligne ~19) — categorie : qualite — zone : secrets
- **Description** : La tâche shell enchaîne quatre commandes console et est rapportée « changed » à chaque exécution où la condition est vraie, mais surtout : si la condition when se base uniquement sur enable_api ('enable_api\t1' absent), une dérive de use_rest_api ou url_base_api seule ne sera jamais corrigée (la tâche est sautée tant qu'enable_api vaut 1). Dérive de configuration possible au 2e run.
- **Extrait** :
```
when: "'enable_api\t1' not in glpi_seed_api_state.stdout"
```
- **Correctif propose** : Vérifier les trois clés (enable_api, use_rest_api, url_base_api) dans la condition, ou exécuter les config:set systématiquement avec changed_when calculé à partir de l'état lu.
- **Verdict verification** : confiance haute — Constat confirmé par lecture du fichier. La tâche shell (ligne 19-26) exécute quatre commandes (config:set enable_api, use_rest_api, url_base_api, cache:clear) mais sa condition est bien `when: "'enable_api\t1' not in glpi_seed_api_state.stdout"` (ligne 26), qui ne teste que enable_api. La requête SQL de lecture (lignes 11-17) ne lit que enable_api et use_rest_api, jamais url_base_api. Donc si enable_api vaut 1 mais que use_rest_api a été désactivé ou que url_base_api a dérivé (changement de glpi_seed_api_url ou modification manuelle), la tâche est sautée et la dérive jamais corrigée. De plus, aucune clause changed_when : la tâche est rapportée 'changed' à chaque exécution où la condition est vraie. Aucune mitigation ailleurs dans le fichier. Sévérité 'basse' (qualité/idempotence, pas de faille sécurité) est adéquate.

### basse-28. no_log sur le seed masque toute erreur d'exécution du script
- **Fichier** : `roles/glpi_seed/tasks/seed.yaml` (ligne ~29) — categorie : fiabilite — zone : secrets
- **Description** : La tâche run-once d'exécution de seed_glpi.py est en no_log: true alors que le secret n'apparaît que dans environment (qui n'est de toute façon pas un argument de commande). En cas d'échec du script (API down, jeton invalide), le message d'erreur sera entièrement masqué (« censored due to no_log »), rendant le diagnostic impossible — pour un faible gain puisque stdout du script ne contient pas le jeton.
- **Extrait** :
```
- name: Exécuter le remplissage GLPI (run-once)
  ansible.builtin.command: python3 /opt/atlas/scripts/seed_glpi.py
  ...
  no_log: true
```
- **Correctif propose** : Garder no_log mais ajouter un bloc rescue affichant un message générique, ou retirer no_log de cette tâche précise puisque le jeton n'est jamais imprimé par le script (vérifier seed_glpi.py n'affiche pas USER_TOKEN), en conservant no_log sur les tâches qui manipulent réellement le secret.
- **Verdict verification** : confiance haute — Confirmé : seed.yaml ligne 36 contient bien no_log: true sur la tâche command exécutant seed_glpi.py, avec le jeton uniquement dans environment (jamais en argument CLI). Le template seed_glpi.py.j2 ne print jamais GLPI_USER_TOKEN (seulement des messages d'erreur génériques). Aucun block/rescue ; la tâche debug suivante est conditionnée à glpi_seed_debug et ne s'exécute pas en cas d'échec. En cas d'erreur (API down, jeton invalide), la sortie sera entièrement censurée par no_log, masquant le diagnostic pour un gain de confidentialité quasi nul. Sévérité basse correcte (fiabilité/diagnosticabilité uniquement).

### basse-29. Certificat auto-signé régénéré (clé écrasée) à chaque exécution
- **Fichier** : `infra/dmz_vlan20/provision_nginx.sh` (ligne ~109) — categorie : idempotence — zone : infra-dmz
- **Description** : L'étape 3 régénère systématiquement la clé privée et le certificat auto-signés, écrasant l'existant sans test préalable. Au 2e run, le certificat change (nouvelle empreinte), ce qui invalide les exceptions TLS déjà acceptées par les clients et, en production, écraserait un certificat PKI/Let's Encrypt installé manuellement au même chemin si les symlinks ont été repointés vers ces fichiers.
- **Extrait** :
```
pct exec "${CTID}" -- openssl req -x509 -nodes -days "${TLS_DAYS}" -newkey rsa:4096 -keyout "${TLS_KEY}" -out "${TLS_CERT}" -subj "${TLS_SUBJ}"
```
- **Correctif propose** : Encadrer la génération d'un test : pct exec ${CTID} -- test -f ${TLS_KEY} || openssl req ... pour ne générer qu'en absence de matériel TLS existant.
- **Verdict verification** : confiance haute — Confirmé. Lignes 109-114 de infra/dmz_vlan20/provision_nginx.sh : `pct exec "${CTID}" -- openssl req -x509 -nodes -days "${TLS_DAYS}" -newkey rsa:4096 -keyout "${TLS_KEY}" -out "${TLS_CERT}" ...` s'exécute inconditionnellement, sans `test -f` ni garde-fou ailleurs dans le script. Chaque run régénère la clé/cert (nouvelle empreinte). Pire, l'étape 4 (lignes 132-133, `ln -sf`) re-pointe systématiquement les symlinks privkey.pem/fullchain.pem vers les fichiers auto-signés, annulant un éventuel repointage manuel vers des certs PKI/Let's Encrypt (la procédure prod décrite dans le résumé du script lui-même, lignes 179-181). Le seul atténuateur est un commentaire « dev/staging only », pas du code. Sévérité « basse » appropriée : impact limité (empreintes TLS, idempotence), pas de fuite de secret.

### basse-30. Image Docker non épinglée (tag mouvant stable-alpine)
- **Fichier** : `infra/dmz_vlan20/docker-compose.yml` (ligne ~19) — categorie : fiabilite — zone : infra-dmz
- **Description** : L'image nginx:stable-alpine est un tag mouvant : chaque pull peut tirer une version différente, ce qui casse la reproductibilité de la reconstruction PRA (le proxy reconstruit pendant un sinistre peut différer de celui testé). Aucun digest ni version exacte n'est figé.
- **Extrait** :
```
image: nginx:stable-alpine
```
- **Correctif propose** : Épingler une version exacte, idéalement avec digest : image: nginx:1.26-alpine@sha256:<digest>.
- **Verdict verification** : confiance haute — La ligne 19 de infra/dmz_vlan20/docker-compose.yml contient bien « image: nginx:stable-alpine », sans digest ni version exacte, et aucun mécanisme ailleurs dans le fichier (pas de variable, pas de pull policy figée) ne fige la version. Le tag « stable-alpine » est mouvant : une reconstruction PRA tirera la dernière version publiée, potentiellement différente de celle testée, ce qui affecte la reproductibilité visée par le RTO <= 40 min. Constat factuel, impact limité (nginx stable est rétro-compatible en pratique), la sévérité « basse » est correcte.

### basse-31. Healthcheck commenté inutilisable tel quel (exec form avec ||, curl absent de l'image)
- **Fichier** : `infra/dmz_vlan20/docker-compose.yml` (ligne ~83) — categorie : bug — zone : infra-dmz
- **Description** : Le healthcheck proposé en commentaire utilise la forme exec CMD avec les tokens "||", "exit", "1" : en forme exec, il n'y a pas de shell, donc || serait passé comme argument littéral à curl et le test échouerait toujours. De plus, curl n'est pas inclus dans l'image nginx:stable-alpine. Quiconque décommente ce bloc obtient un conteneur perpétuellement unhealthy.
- **Extrait** :
```
# test: ["CMD", "curl", "-f", "https://localhost/health", "||", "exit", "1"]
```
- **Correctif propose** : Utiliser CMD-SHELL avec un outil présent dans l'image : test: ["CMD-SHELL", "wget -q --no-check-certificate -O /dev/null https://localhost/health || exit 1"].
- **Verdict verification** : confiance haute — Vérifié dans C:/Users/BEDANI/Documents/Atlas/Atlas/infra/dmz_vlan20/docker-compose.yml : la ligne 83 contient exactement `# test: ["CMD", "curl", "-f", "https://localhost/health", "||", "exit", "1"]` et le commentaire ligne 78 invite explicitement à le décommenter (« uncomment once certs are in place »). Le problème est techniquement exact : en forme exec ["CMD", ...] il n'y a pas de shell, donc "||", "exit", "1" seraient passés comme arguments littéraux à curl (erreur de parsing curl), et l'image déclarée ligne 19 est nginx:stable-alpine qui n'embarque pas curl (seul wget BusyBox est présent). Le conteneur deviendrait perpétuellement unhealthy une fois le bloc décommenté. Aucune mitigation ailleurs (pas d'autre définition de healthcheck dans le fichier). Sévérité basse justifiée : le bloc est commenté, donc aucun impact tant qu'il n'est pas activé ; c'est un piège latent documenté, pas un défaut actif.

### basse-32. Fichier parasite ez.txt à la racine du dépôt
- **Fichier** : `ez.txt` (ligne ~1) — categorie : qualite — zone : infra-dmz
- **Description** : Fichier de 4 octets contenant uniquement la chaîne 'ez'. Aucun lien avec le projet ; vraisemblablement un reste de test. Il pollue la racine du dépôt censé alimenter un DAT.
- **Extrait** :
```
ez
```
- **Correctif propose** : Supprimer ez.txt du dépôt.
- **Verdict verification** : confiance haute — Vérifié : C:/Users/BEDANI/Documents/Atlas/Atlas/ez.txt existe (4 octets), contient uniquement 'ez' suivi d'une fin de ligne. Aucune référence dans le code (grep ne trouve 'ez.txt' que dans .git/index et le pack git, prouvant qu'il est suivi par le VCS et non ignoré par .gitignore). Aucun lien fonctionnel avec le projet Ansible/GLPI. Constat factuel confirmé ; sévérité 'basse' appropriée (simple problème de propreté du dépôt, pas de secret ni d'impact sécurité/PRA).

### basse-33. La structure du dépôt documentée dans le README omet infra/, docs/ et scripts_pra/
- **Fichier** : `README.md` (ligne ~169) — categorie : qualite — zone : infra-dmz
- **Description** : La section 'Structure du dépôt' du README ne mentionne ni le répertoire infra/ (qui contient pourtant des scripts de provisioning contradictoires avec les rôles), ni docs/, ni scripts_pra/ (backup/restore). Un nouvel arrivant ne sait pas que infra/ existe ni qu'il est obsolète, ce qui aggrave le risque d'utiliser la mauvaise source de vérité. Les commandes documentées (site.yaml, pra_restore_*.yaml, scripts/*.sh, vault.yaml.example) existent bien, en revanche.
- **Extrait** :
```
## 📁 Structure du dépôt (arborescence listée : site.yaml, pra_restore_*, ansible.cfg, collections/, scripts/, develop/, roles/ — pas de infra/, docs/, scripts_pra/)
```
- **Correctif propose** : Mettre à jour l'arborescence du README pour refléter le contenu réel, ou supprimer les répertoires non documentés s'ils sont obsolètes.
- **Verdict verification** : confiance haute — Constat confirmé. La section « Structure du dépôt » du README (lignes 169-205) liste site.yaml, pra_restore_*.yaml, ansible.cfg, collections/, scripts/, develop/ et roles/, mais omet trois répertoires bien présents à la racine : infra/ (dmz_vlan20, lan_admin_vlan30, proxmox_iac — scripts de provisioning parallèles aux rôles), scripts_pra/ (backup, restore) et docs/ (DAT.md, Matrice_Risques.md, Runbooks_PRA.md). Le .gitignore ne les exclut pas. L'arborescence documentée est donc incomplète, ce qui peut faire confondre la source de vérité (roles/ vs infra/). Sévérité basse appropriée : problème purement documentaire, sans impact direct sécurité/PRA.

### basse-34. Ré-extraction de l'archive GLPI par-dessus une installation existante
- **Fichier** : `infra/lan_admin_vlan30/provision_glpi.sh` (ligne ~141) — categorie : idempotence — zone : infra-dmz
- **Description** : Au 2e run, tar -xzf ré-écrase tous les fichiers GLPI existants dans /var/www/html/glpi sans condition, y compris potentiellement des fichiers modifiés après installation (le répertoire config/ et files/ de GLPI vivent sous l'arborescence extraite en 10.x si non déplacés). Le script n'est pas rejouable sans risque de régression de l'application.
- **Extrait** :
```
pct exec "${CTID}" -- bash -c "tar -xzf /tmp/${GLPI_ARCHIVE} -C /var/www/html/"
```
- **Correctif propose** : Conditionner le téléchargement et l'extraction à l'absence du répertoire : test -d ${GLPI_DIR} || (wget ... && tar ...).
- **Verdict verification** : confiance haute — Confirmé dans C:/Users/BEDANI/Documents/Atlas/Atlas/infra/lan_admin_vlan30/provision_glpi.sh : la ligne 141 exécute inconditionnellement `pct exec "${CTID}" -- bash -c "tar -xzf /tmp/${GLPI_ARCHIVE} -C /var/www/html/"`, précédée d'un wget tout aussi inconditionnel (l.134). Aucun garde-fou (`test -d ${GLPI_DIR}`, marqueur d'état) nulle part dans le script. Au 2e run, l'archive ré-écrase les fichiers de l'arborescence /var/www/html/glpi, et les lignes 144-146 réinitialisent ownership/permissions (chmod 644 récursif) sur tout, y compris config/ et files/. Nuance qui borne la sévérité : tar n'efface pas les fichiers absents de l'archive (config_db.php, données files/ survivent), donc l'installation reste probablement fonctionnelle pour la même version ; le risque réel est la régression de fichiers core patchés ou d'une version GLPI mise à jour entre-temps (downgrade silencieux vers 10.0.15 épinglée l.54). Sévérité « basse » (idempotence) est correcte, le correctif proposé est pertinent.

## Constats refutes (2)
- `pra_restore_full.yaml` — hostvars['proxmox_node'] : groupe utilisé comme nom d'hôte : Prémisse fausse : dans develop/hosts.yaml, 'proxmox_node' est un NOM D'HÔTE (membre du groupe 'proxmox', ligne 10 : « proxmox: hosts: proxmox_node: ansible_host: 138.201.135.108 »), pas un groupe. 'hosts: proxmox_node' cible donc cet hôte directement et hostvars['proxmox_node'].pra_start_epoch (ligne 216 de pra_restore_full.yaml) est valide, le fact étant posé dans le premier play sur le même hôte (ligne 15). Le calcul du RTO fonctionne. Le détour par hostvars est redondant ({{ pra_start_epoch }} suffirait) mais c'est cosmétique, pas un bug.
- `develop/hosts.yaml` — Le bastion (mgmt) est joint en direct sur une IP privée VLAN 90 sans documentation du prérequis de routage : L'extrait cité existe bien (develop/hosts.yaml lignes 16-21 : mgmt/atlbst01p en 10.90.0.10 sans ProxyCommand), et il est factuel que l'exécution dépend du routage local de pve01. Mais le constat affirme que cette dépendance n'est « exprimée nulle part », ce qui est faux : ansible.cfg ligne 3 indique explicitement « Control node : pve01 (138.201.135.108) », et le README.md documente une section « Déploiement de zéro (sur pve01) » avec ses prérequis, plus le schéma admin « SSH → bastion (10.90.0.10) → rebond ». Le correctif proposé (documenter le prérequis d'exécution depuis pve01) est donc déjà satisfait ailleurs dans le dépôt ; reprocher uniquement l'absence d'un commentaire dans le fichier d'inventaire est un point de style, pas un défaut réel. De plus, les groupes dmz/lan_admin pointent eux aussi 10.90.0.10 en ProxyCommand : la conception entière assume de façon cohérente et documentée pve01 comme control node. Constat réfuté car déjà mitigé par la documentation existante.
