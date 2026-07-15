export const meta = {
  name: 'atlas-remediation',
  description: 'Correction des constats moyens/bas de l\'audit Atlas par une équipe d\'agents (fichiers disjoints)',
  phases: [
    { title: 'Correction', detail: 'un agent par zone, fichiers disjoints (pas de conflit)' },
    { title: 'Synthèse', detail: 'consolidation des changements' },
  ],
}

const ROOT = 'C:/Users/BEDANI/Documents/Atlas/Atlas'

const CONTEXT = `Projet "Atlas" : déploiement IaC (Ansible) d'un helpdesk GLPI sur Proxmox/LXC.
Contraintes (CLAUDE.md) : RPO<=20min, RTO<=40min ; secrets HORS du VCS ; moindre privilège,
aucun compte admin par défaut conservé ; TLS obligatoire sur le reverse proxy ;
réseau DMZ VLAN20 (10.20.0.0/24), LAN ADMIN VLAN30 (10.30.0.0/24), MGMT VLAN90 (10.90.0.0/24).
Hôtes : atlrp01p 10.20.0.10 (reverse proxy), atlapp01p 10.20.0.11 (GLPI), atltst01p 10.20.0.20 (testlab),
atldb01p 10.30.0.10 (MariaDB), atlsmtp01p 10.30.0.11, atlzbx01p 10.30.0.12 (Zabbix), atlbkp01p 10.30.0.13 (backup),
atlgrf01p 10.30.0.14 (Grafana), atlbst01p 10.90.0.10 (bastion).
Racine du dépôt : ${ROOT}`

const CHANGES_SCHEMA = {
  type: 'object',
  properties: {
    changes: {
      type: 'array',
      items: {
        type: 'object',
        properties: {
          file: { type: 'string', description: 'chemin relatif corrigé' },
          finding: { type: 'string', description: 'constat traité (titre court)' },
          change: { type: 'string', description: 'ce qui a été modifié, en français' },
          status: { type: 'string', enum: ['corrige', 'deja_ok', 'ignore'] },
        },
        required: ['file', 'finding', 'change', 'status'],
      },
    },
    notes: { type: 'string', description: 'remarques / dépendances éventuelles' },
  },
  required: ['changes'],
}

// Zones à fichiers DISJOINTS : aucun fichier n'apparaît dans deux zones.
const AREAS = [
  {
    key: 'mariadb-backup',
    findings: `
- roles/mariadb/tasks/secure.yaml:8 — Mot de passe root passé en argument mysql (visible via ps) -> utiliser --defaults-extra-file 0600 ou /root/.my.cnf
- roles/mariadb/tasks/secure.yaml:40 — Sécurisation incomplète : comptes root distants/anonymes + base test non supprimés (équivalent mysql_secure_installation)
- roles/mariadb/templates/dump_glpi.sh.j2:49 — Aucune vérification d'intégrité du dump (tester gzip -t et taille > 0)
- roles/mariadb/defaults/main.yaml:13 — Rétention « 7 dumps » = 7 h d'historique avec le dump toutes les 15 min : augmenter pour couvrir un horizon cohérent
- roles/mariadb/tasks/databases.yaml:39 — ALL PRIVILEGES au compte applicatif GLPI : restreindre (SELECT,INSERT,UPDATE,DELETE,CREATE,ALTER,INDEX,LOCK TABLES,REFERENCES)
- roles/backup/templates/collect_dumps.sh.j2:12 — StrictHostKeyChecking=no sur les rsync : passer à accept-new
- roles/backup/tasks/scripts.yaml:8 — chmod récursif g+rx ponctuel non idempotent : utiliser file/recurse ou fixer le mode à la création`,
  },
  {
    key: 'glpi-web',
    findings: `
- roles/glpi/defaults/main.yaml:11 — Archive GLPI sans checksum : prévoir une variable glpi_checksum (laisser vide par défaut mais documenter fortement, OU renseigner le sha256 si connu)
- roles/glpi/tasks/download.yaml:0 — Répertoire install/ de GLPI jamais supprimé après installation : ajouter une tâche de suppression de /var/www/glpi/install après install
- roles/glpi/tasks/configure.yaml:42 — UFW ouvre le port 80 du backend à toutes les sources : restreindre aux sources légitimes (reverse proxy 10.20.0.10, supervision)
- roles/glpi/tasks/configure.yaml:8 — config_db.php appartient à www-data (auto-modifiable) : root:www-data, mode 0640
- roles/glpi/tasks/service.yaml:29 — IP backend codée en dur dans la vérif HTTP : paramétrer via variable
- roles/glpi/handlers/main.yaml:8 — Handler « Redémarrer php8.2-fpm » jamais notifié : le notifier depuis les tâches pertinentes (ou retirer si inutile)
- roles/glpi_seed/templates/seed_glpi.py.j2:274 — Marqueur run-once écrit même si tous les appels API échouent : n'écrire le marqueur qu'en cas de succès
- roles/glpi_seed/tasks/api_enable.yaml:19 — activation API sans changed_when ni gestion d'échec : ajouter changed_when et failed_when cohérents
- roles/glpi_seed/tasks/api_enable.yaml:12 — commandes mysql sans base paramétrée : utiliser {{ vault_glpi_db_name }}
- roles/glpi_seed/tasks/seed.yaml:29 — no_log masque toute erreur du script : limiter no_log ou journaliser le code retour
- roles/reverse_proxy/templates/vhost_glpi.conf.j2:34 — Host transmis au backend != server_name du vhost GLPI : aligner proxy_set_header Host`,
  },
  {
    key: 'supervision',
    findings: `
- roles/zabbix/templates/zabbix_nginx.conf.j2:8 — Frontend/API Zabbix en HTTP clair (identifiants admin non chiffrés) : forcer HTTPS / passer derrière le reverse proxy TLS, ou redirect 80->443
- roles/zabbix/tasks/database.yaml:38 — Rotation du mot de passe BDD zabbix impossible (dérive vault/MariaDB) : ALTER USER ... IDENTIFIED BY au lieu de ne créer qu'à l'absence
- roles/zabbix/tasks/register_hosts.yaml:146 — Hôtes existants jamais mis à jour (dérive IP/groupe/template) : host.update pour les hôtes déjà présents
- roles/grafana/templates/provisioning_datasource.yaml.j2:16 — Datasource Grafana utilise le super-admin Zabbix : créer/utiliser un compte Zabbix en lecture seule dédié
- roles/testlab/templates/chaos.sh.j2:50 — chaos.sh sans garde-fou de ciblage (risque d'arrêt de services de prod) : restreindre explicitement aux hôtes/lab, refuser si hors lab
- roles/testlab/templates/chaos.sh.j2:24 — Capture de PIPESTATUS inopérante avec set -e -o pipefail : corriger la logique de capture
- roles/testlab/tasks/install.yaml:45 — Règle UFW trop large 10.0.0.0/8 : restreindre aux VLAN Atlas (10.20/30/90.0/24)
- roles/smtp/tasks/service.yaml:19 — Envoi d'un courriel de test à chaque exécution : conditionner (smtp_send_test|default(false)) ou changed_when correct`,
  },
  {
    key: 'pra-orchestration',
    findings: `
- pra_restore_full.yaml:0 — Aucun any_errors_fatal ni block/rescue : ajouter any_errors_fatal: true aux plays critiques (restauration des données surtout)
- pra_restore_full.yaml:106 — Incohérence des chemins de sauvegarde entre dump et restauration : aligner les chemins (db-remote / filestore) avec le rôle backup
- pra_restore_full.yaml:174 — Vérification post-restore en HTTP direct : ajouter une vérification via le reverse proxy HTTPS
- pra_restore_granular.yaml:26 — pra_target_dump vérifié après l'avoir journalisé ; aucune vérif post-fusion : déplacer l'assert avant, ajouter un COUNT post-fusion
- pra_restore_granular.yaml:87 — Export des tickets en clair dans /tmp sans permissions : créer le fichier avec umask 077 / mode 0600, ou mktemp -p un répertoire restreint
- site.yaml:0 — Aucune gestion d'échec inter-plays : ajouter any_errors_fatal: true aux plays
- site.yaml:89 — Le serveur de sauvegarde est configuré en dernier, après l'application : remonter le play backup avant/au bon endroit
- site.yaml:6 — En-tête des tags incomplet (grafana, testlab, glpi_seed absents) : compléter le commentaire d'en-tête`,
  },
  {
    key: 'proxmox-provision',
    findings: `
- roles/proxmox_provision/tasks/create_lxc_item.yaml:17 — validate_certs: false sur l'API Proxmox : rendre paramétrable (proxmox_validate_certs, défaut true) avec commentaire
- roles/proxmox_provision/tasks/create_lxc_item.yaml:28 — Bridge vmbr0 codé en dur dans netif : utiliser la variable du rôle réseau (proxmox_network_bridge)
- roles/proxmox_provision/defaults/main.yaml:7 — Clé publique SSH atladm codée en dur : conserver en defaults est acceptable pour une clé PUBLIQUE, mais la rendre paramétrable/documentée
- roles/proxmox_network/templates/atlas-vlans.cfg.j2:9 — Masque /24 codé en dur ignorant vlan.subnet : dériver le préfixe depuis vlan.subnet
- scripts/reset_proxmox_atlas.sh:94 — pct destroy bloqué par la protection (deploy_lxc) sans gestion : pct set --protection 0 avant destroy
- scripts/reset_proxmox_atlas.sh:40 — Installation de jq sans apt-get update préalable : ajouter apt-get update
- scripts/setup_vlan_routing.sh:205 — iptables-save capture l'état courant complet (dérive de rules.v4) : commenter/limiter, déployer un rules.v4 maîtrisé plutôt que iptables-save brut`,
  },
  {
    key: 'infra-docs-secrets',
    findings: `
NB : les scripts infra/*.sh sont DÉJÀ marqués obsolètes (garde-fou ATLAS_PROVISION_FORCE). Les durcir quand même (défense en profondeur), sans retirer le garde-fou.
- infra/lan_admin_vlan30/provision_zabbix.sh:163 — Mot de passe DB en argument (ps) : --defaults-extra-file 0600
- infra/lan_admin_vlan30/provision_zabbix.sh:175 — Motifs sed trop larges (écrase commentaires/duplique) : ancrer les motifs
- infra/lan_admin_vlan30/provision_zabbix.sh:162 — Import schéma Zabbix non rejouable : garder par test d'existence des tables
- infra/lan_admin_vlan30/provision_zabbix.sh:224 — Comptes admin par défaut conservés (simple rappel) : au minimum forcer le changement
- infra/lan_admin_vlan30/provision_glpi.sh:123 — Injection SQL/shell via variables non échappées : échapper/guillemeter, paramétrer proprement
- infra/lan_admin_vlan30/provision_glpi.sh:141 — Ré-extraction archive GLPI par-dessus install existante : garder (creates / test)
- infra/dmz_vlan20/provision_nginx.sh:109 — Certificat auto-signé régénéré (clé écrasée) à chaque exécution : ne (re)générer que si absent
- infra/dmz_vlan20/docker-compose.yml:19 — Image Docker non épinglée (stable-alpine) : épingler une version précise
- infra/dmz_vlan20/docker-compose.yml:83 — Healthcheck commenté inutilisable (exec form avec ||, curl absent) : corriger ou retirer proprement
- infra/lan_admin_vlan30/docker-compose.yml:0 — Fichier docker-compose.yml VIDE (0 octet) : le compléter a minima ou documenter qu'il est volontairement vide
- ez.txt:1 — Fichier parasite à la racine : SUPPRIMER (utiliser l'outil Bash : rm "${ROOT}/ez.txt")
- README.md:169 — Structure du dépôt documentée omet infra/, docs/, scripts_pra/ : compléter
- README.md:113 — Comptes GLPI par défaut : la doc dit qu'ils ne sont pas supprimés ; or harden_accounts.yaml le fait désormais — METTRE À JOUR la doc en ce sens
- README.md:71 — Jeton API Proxmox créé sans séparation de privilèges (--privsep 0) : documenter --privsep 1 + rôle restreint
- develop/group_vars/all/vault.yaml.example:14 — IP publique et identifiants réels dans l'exemple versionné : remplacer par des placeholders (CHANGE_ME)
- ansible.cfg:10 — Commentaire « control node = pve01 » fige le PRA du control node : ajouter une note sur la reprise du control node`,
  },
]

phase('Correction')
log(`Équipe de ${AREAS.length} agents — correction des moyens/bas par zone (fichiers disjoints)`)

const fixPrompt = (a) => `Tu es un ingénieur Ansible/sécurité chargé de CORRIGER une partie d'un dépôt IaC. Réponds en français.

${CONTEXT}

TA ZONE : ${a.key}
Tu ne dois éditer QUE les fichiers listés ci-dessous (chemins relatifs à ${ROOT}). N'édite AUCUN autre fichier (d'autres agents s'occupent du reste en parallèle).

CONSTATS À CORRIGER (avec piste de correction) :
${a.findings}

MÉTHODE :
1. Lis CLAUDE.md et le rapport d'audit ${ROOT}/docs/audit/2026-06-12-rapport-audit-atlas.md (filtre sur TES fichiers) pour le détail de chaque constat et le correctif proposé.
2. Lis INTÉGRALEMENT chaque fichier avant de l'éditer (outil Read), puis applique des corrections MINIMALES, SÛRES et IDEMPOTENTES (outil Edit/Write). Outils chemins Windows : ${ROOT}/...
3. Préserve le comportement fonctionnel existant. Ne reformate pas le code non concerné. Garde le style et les commentaires en français du dépôt.
4. Si un correctif nécessite une nouvelle variable, définis-la dans les defaults du rôle concerné (jamais de secret en clair ; secrets via vault_*).
5. Certains fichiers ont déjà reçu des corrections (critiques/hautes) : si un constat est déjà réglé, marque-le status="deja_ok" sans rééditer.
6. Ne touche pas à la logique des hautes/critiques déjà en place (ex : politique FORWARD DROP, harden_accounts, block/rescue Zabbix).

Quand tu as fini, retourne la liste de TES changements via le schéma fourni (un item par constat traité).`

const results = await parallel(AREAS.map(a => () =>
  agent(fixPrompt(a), { label: `fix:${a.key}`, phase: 'Correction', schema: CHANGES_SCHEMA })
))

phase('Synthèse')
const all = results
  .map((r, i) => r ? r.changes.map(c => ({ ...c, area: AREAS[i].key })) : [])
  .flat()

const corrige = all.filter(c => c.status === 'corrige')
const dejaOk = all.filter(c => c.status === 'deja_ok')
const ignore = all.filter(c => c.status === 'ignore')
log(`${corrige.length} corrigés, ${dejaOk.length} déjà OK, ${ignore.length} ignorés`)

return {
  stats: {
    zones: AREAS.length,
    total: all.length,
    corrige: corrige.length,
    dejaOk: dejaOk.length,
    ignore: ignore.length,
  },
  parZone: AREAS.map((a, i) => ({
    zone: a.key,
    changements: results[i] ? results[i].changes : null,
    notes: results[i] ? results[i].notes : 'agent échoué',
  })),
}
