# Matrice des risques — Projet Atlas (PRA/DR Helpdesk GLPI)

> Livrable DAT (cf. CLAUDE.md). Échelles : Probabilité (1 Rare → 4 Fréquent), Impact (1 Mineur → 4 Critique). Criticité = P × I.

## Cotation

| Criticité (P×I) | Niveau | Traitement |
|-----------------|--------|------------|
| 12 – 16 | 🔴 Critique | Action immédiate, ne pas mettre en production |
| 6 – 11 | 🟠 Élevé | Plan de remédiation court terme |
| 3 – 5 | 🟡 Modéré | À traiter, surveiller |
| 1 – 2 | 🟢 Faible | Accepté / surveillé |

---

## 1. Risques de disponibilité / PRA

| # | Risque | P | I | Crit. | Mesure de réduction | Statut |
|---|--------|---|---|-------|---------------------|--------|
| D1 | Perte du conteneur BDD (`atldb01p`) | 2 | 4 | 🟠 8 | Dumps 15 min + binlogs hors site (`atlbkp01p`) ; Runbook A | Couvert |
| D2 | Perte totale de l'hyperviseur (panne matérielle Hetzner) | 1 | 4 | 🟡 4 | IaC complète rejouable (`pra_restore_full.yaml`) ; sauvegardes hors hôte | Couvert (dépend de la fraîcheur hors site) |
| D3 | RPO non tenu (perte de données > 20 min) | 2 | 4 | 🟠 8 | Collecte hors site ramenée à 15 min + PITR binlogs | **Remédié** (était 24 h) |
| D4 | Sauvegarde silencieusement cassée | 2 | 4 | 🟠 8 | Code retour scripts + alerte Zabbix sur fraîcheur des dumps ; test de restauration périodique | Partiel — mettre en place l'alerte fraîcheur |
| D5 | Restauration jamais testée → PRA théorique | 3 | 3 | 🟠 9 | Calendrier de tests (Runbook §6) | À planifier |
| D6 | Coupure réseau de l'hyperviseur lors d'un changement firewall/VLAN | 2 | 4 | 🟠 8 | `iptables-restore --test` + `ifquery` avant rechargement ; `INPUT ACCEPT` conservé ; runbook `apply_network_safe.sh` avec rollback auto | **Remédié** |

## 2. Risques de sécurité

| # | Risque | P | I | Crit. | Mesure de réduction | Statut |
|---|--------|---|---|-------|---------------------|--------|
| S1 | Absence de segmentation (DMZ → LAN/MGMT ouverts) | 3 | 4 | 🔴 12 | Politique `FORWARD DROP` + matrice de flux moindre privilège | **Remédié** |
| S2 | Comptes par défaut conservés (`glpi/glpi`, Zabbix `Admin/zabbix`, Grafana) | 3 | 4 | 🔴 12 | Renommage/mot de passe fort super-admin GLPI, mot de passe Zabbix Admin via vault, désactivation comptes démo | **Remédié** (GLPI, Zabbix) — vérifier Grafana |
| S3 | Secrets en clair (mot de passe en argument `ps`, vault non chiffré) | 2 | 3 | 🟡 6 | `--defaults-extra-file` 0600, `no_log`, vault AES-256 hors VCS | Partiel — balayer les `provision_*.sh` |
| S4 | Clé SSH de sauvegarde sans restriction (shell complet) | 2 | 3 | 🟡 6 | `from=` + `no-pty`/`no-*-forwarding` ; option `command="rrsync -ro"` | **Remédié** |
| S5 | Accès SSH trop permissif (root direct, host-key non vérifiée) | 2 | 3 | 🟡 6 | `prohibit-password` partout, `StrictHostKeyChecking=accept-new`, bastion durci | **Remédié** (host-key, sshd) — bascule atlsvc à phaser |
| S6 | Reverse proxy / frontend en HTTP clair (identifiants en clair) | 3 | 3 | 🟠 9 | TLS obligatoire sur le reverse proxy ; frontend Zabbix derrière le proxy | À traiter (constat moyen) |
| S7 | Sudo `NOPASSWD` à joker (`systemctl *`) → escalade | 2 | 3 | 🟡 6 | Liste blanche de services explicite (`common_sudo_allowed_services`) | **Remédié** |
| S8 | RCE persistante : code applicatif inscriptible par le serveur web | 2 | 4 | 🟠 8 | Code GLPI `root:www-data`, écriture limitée aux données/plugins | **Remédié** |
| S9 | Jeton API Proxmox sans séparation de privilèges (`--privsep 0`) | 2 | 3 | 🟡 6 | Créer le jeton avec privilèges restreints | À traiter (constat moyen) |
| S10 | Scripts `chaos.sh` (testlab) sans garde-fou de ciblage | 2 | 4 | 🟠 8 | Restreindre aux hôtes lab, refuser la prod | À traiter (constat moyen) |

## 3. Risques d'exploitation / fiabilité IaC

| # | Risque | P | I | Crit. | Mesure de réduction | Statut |
|---|--------|---|---|-------|---------------------|--------|
| E1 | Import de schéma non atomique (demi-schéma irrécupérable) | 2 | 3 | 🟡 6 | `block`/`rescue` avec purge + relance (Zabbix) | **Remédié** (Zabbix) |
| E2 | Scripts non idempotents (échec au 2e run) | 3 | 2 | 🟡 6 | Gardes `creates`/`--test`, vérifs d'existence | Partiel |
| E3 | Double/triple source de vérité (`infra/*.sh` vs rôles Ansible) | 3 | 3 | 🟠 9 | Désigner Ansible comme référence, marquer les scripts `infra/` obsolètes | À traiter |
| E4 | Téléchargement applicatif sans vérification d'intégrité (checksum) | 2 | 3 | 🟡 6 | Renseigner `glpi_checksum` (sha256) | À traiter (constat moyen) |
| E5 | `dist-upgrade` systématique → régression non maîtrisée | 2 | 3 | 🟡 6 | `upgrade: safe` par défaut, `dist` ponctuel | **Remédié** |

---

## 4. Synthèse

- **Risques critiques (🔴)** identifiés à l'audit : **remédiés** (segmentation S1, comptes par défaut S2).
- **Priorités restantes** : tests de restauration (D5), alerte fraîcheur sauvegarde (D4), TLS frontend (S6), unification IaC vs scripts `infra/` (E3), garde-fou chaos (S10).
- Réviser cette matrice à chaque évolution majeure et après chaque test PRA.

> Source : audit du dépôt (revue multi-agents, 2026-06) — cf. `docs/audit/2026-06-12-rapport-audit-atlas.md`.
