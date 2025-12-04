# VPS Manager - Gestionnaire de Sauvegardes MySQL

Outil d'administration pour VPS permettant la gestion automatisée des sauvegardes de bases de données MySQL dans des conteneurs Docker.

## Fonctionnalités principales

- Sauvegarde automatisée de bases de données MySQL depuis des conteneurs Docker
- Politique de rétention flexible (journalière et mensuelle)
- Sauvegardes compressées (gzip)
- Gestion multi-services avec configuration centralisée
- Restauration simplifiée via Makefile
- Gestion des tâches cron (sauvegardes et jobs métier)
- **Health check automatisé des URLs avec alertes email**
- **Logs de backups avec synthèse quotidienne et alertes email**
- Supervision et monitoring des sauvegardes
- Logs structurés par service

## Prérequis

- Bash (version 4+)
- Docker et Docker Compose
- Make
- Accès aux conteneurs MySQL/MariaDB
- Espace disque suffisant pour les sauvegardes

## Installation

### 1. Configuration initiale

```bash
make setup
```

Cette commande :
- Copie le fichier `.env.dist` vers `.env`
- Crée les répertoires de sauvegarde
- Rend le script `backup.sh` exécutable

### 2. Configuration des services

Éditez le fichier `.env` et configurez vos services :

```bash
# Paramètres généraux
BACKUP_BASE_DIR="/data/backups"  # Dossier racine des sauvegardes
LOGS_BASE_DIR="/data/logs"        # Dossier racine des logs

# Politique de rétention globale par défaut
DAILY_RETENTION_DAYS=7           # Conservation des sauvegardes journalières
MONTHLY_RETENTION_MONTHS=6       # Conservation des sauvegardes mensuelles

# Liste des services à sauvegarder
SERVICES_TO_BACKUP=(
  "nom_service;nom_conteneur;nom_db;user_db;password_db;[retention_jours];[retention_mois]"
)
```

#### Format de configuration des services

Chaque service doit être défini sur une ligne avec le format suivant :

```
"NOM_SERVICE;NOM_CONTENEUR_DOCKER;NOM_DB;USER_DB;PASSWORD_DB;[RETENTION_JOURS];[RETENTION_MOIS]"
```

**Paramètres obligatoires :**
- `NOM_SERVICE` : Nom du service (utilisé pour les dossiers et fichiers)
- `NOM_CONTENEUR_DOCKER` : Nom du conteneur Docker contenant MySQL
- `NOM_DB` : Nom de la base de données à sauvegarder
- `USER_DB` : Utilisateur MySQL
- `PASSWORD_DB` : Mot de passe MySQL

**Paramètres optionnels :**
- `RETENTION_JOURS` : Nombre de jours de rétention (surcharge la valeur globale)
- `RETENTION_MOIS` : Nombre de mois de rétention (surcharge la valeur globale)

**Exemple :**
```bash
SERVICES_TO_BACKUP=(
  "kpi;kpi_db_1;kpi_db;user;password;14;12"              # Rétention personnalisée
  "wordpress;wp_db_1;wordpress_db;user;password"         # Rétention globale
)
```

## Utilisation

### Commandes de sauvegarde

#### Sauvegarder tous les services
```bash
make backup-all
```

#### Sauvegarder un service spécifique
```bash
make backup-service service=1
```
Le numéro correspond à la position du service dans `SERVICES_TO_BACKUP` (commence à 1).

### Health Check des URLs

#### Exécuter manuellement un health check
```bash
make health-check
```

Cette commande vérifie l'accessibilité de toutes les URLs configurées dans `.env` et :
- Vérifie que chaque URL retourne le code HTTP attendu
- Enregistre chaque vérification dans les logs
- Envoie un email d'alerte en cas de problème détecté
- Envoie un email de résolution lorsque le problème est corrigé

#### Configuration des URLs à surveiller

Les URLs à surveiller sont définies dans le fichier `.env` :

```bash
# Email destinataire des alertes (health check et backups)
HEALTH_CHECK_EMAIL="admin@example.com"

# Nom de l'expéditeur pour les emails d'alerte
HEALTH_CHECK_FROM_NAME="VPS Health Monitor"

# Adresse email de l'expéditeur (doit être un domaine autorisé par votre serveur SMTP)
HEALTH_CHECK_FROM_EMAIL="noreply@example.com"

# Liste des URLs à surveiller (format: "URL;LABEL;CODES_HTTP_ATTENDUS")
HEALTH_CHECK_URLS=(
  "https://example.com;Site principal;200 301"
  "https://api.example.com/health;API Health;200"
  "https://monitoring.example.com;Monitoring;200 304"
)
```

**Paramètres de configuration :**
- `HEALTH_CHECK_EMAIL` : Adresse email destinataire des alertes (health check et backups)
- `HEALTH_CHECK_FROM_NAME` : Nom d'affichage de l'expéditeur (ex: "VPS Health Monitor")
- `HEALTH_CHECK_FROM_EMAIL` : Adresse email de l'expéditeur - **Important :** doit utiliser un domaine autorisé par votre serveur SMTP

**Format de configuration des URLs :**
- `URL` : L'URL complète à vérifier
- `LABEL` : Un libellé court pour identifier le service dans les logs et emails
- `CODES_HTTP_ATTENDUS` : Liste des codes HTTP acceptables séparés par des espaces (par défaut : `200 304`)

#### Mécanisme d'alerte

Le système d'alerte est intelligent :
- **Premier problème détecté** : Email envoyé immédiatement
- **Problème persistant** : Email de rappel toutes les heures maximum (throttling)
- **Résolution du problème** : Email de notification envoyé une seule fois
- **Problème résolu** : Plus d'envoi d'email jusqu'à la prochaine détection

#### Automatisation via cron

Pour activer la surveillance automatique toutes les 5 minutes :
```bash
make install-cron-health-check
```

Le cron job sera ajouté et s'exécutera en arrière-plan. Consultez les logs pour suivre les vérifications.

### Logs et alertes des backups

Le système de backup intègre désormais un système de logs structuré et d'alertes email similaire au health check.

#### Format des logs

Chaque backup génère une ligne de log avec :
- **Timestamp** : Date et heure au format `YYYY-MM-DD HH:MM:SS`
- **Niveau** : `[OK]` pour succès, `[ERROR]` pour échec
- **Message** : Détails du backup (nom du service, base de données)

**Exemple de logs :**
```
[2025-12-04 02:00:15] [OK] Backup 'kpi' réussi (kpi_db)
[2025-12-04 02:00:47] [ERROR] Backup 'wordpress' échoué (wordpress_db)
[2025-12-04 02:01:12] [OK] Backup 'matomo' réussi (matomo_db)
[2025-12-04 02:01:12] [WARNING] === Backups terminés : 1/3 échoués ===
```

#### Synthèse quotidienne

À la fin de chaque exécution, une ligne de synthèse indique :
- `[INFO]` : Si tous les backups ont réussi
- `[WARNING]` : Si un ou plusieurs backups ont échoué

#### Alertes email

Le système envoie automatiquement des emails à `HEALTH_CHECK_EMAIL` en cas de problème :

**Premier échec détecté :**
- Email envoyé immédiatement
- Contient : nom du service, base de données, conteneur, commandes de diagnostic

**Échec persistant :**
- Email de rappel maximum toutes les heures (throttling)

**Problème résolu :**
- Email de notification envoyé une seule fois
- Confirme que la sauvegarde fonctionne à nouveau

**Fichiers de logs :**
- Logs : `$LOGS_BASE_DIR/backups/backup.log`
- États : `$LOGS_BASE_DIR/backups/state/{service}.state`

#### Consultation des logs de backup

```bash
make show-logs folder=backups
```

### Commandes de supervision

#### Lister les services Docker actifs
```bash
make list-services
```

#### Lister toutes les sauvegardes
```bash
make list-backups
```
Affiche un tableau avec la date, la taille, le chemin et le nom de chaque sauvegarde.

#### Vérifier l'espace disque utilisé
```bash
make disk-usage
```

#### Inspecter un conteneur Docker
```bash
make inspect service=1
```
Affiche les variables d'environnement du conteneur.

### Commandes de restauration

#### Restaurer une sauvegarde
```bash
make restore-backup service=1 backup=chemin/vers/backup.sql.gz
```

**Attention :** Cette opération écrase toutes les données actuelles de la base. Une confirmation explicite (taper `YES`) est requise.

Le chemin peut être :
- Un chemin absolu : `/data/backups/kpi/daily/kpi_2025-11-18.sql.gz`
- Un chemin relatif : `kpi/daily/kpi_2025-11-18.sql.gz` (relatif à `BACKUP_BASE_DIR`)

### Gestion des tâches cron

#### Afficher les cron jobs configurés
```bash
make show-cron
```

#### Afficher les logs des exécutions cron récentes
```bash
make show-cron-log
```
(Nécessite sudo)

#### Installer les cron jobs

**Sauvegarde quotidienne (2h du matin) :**
```bash
make install-cron-backups
```

**Archivage Matomo (toutes les heures à H+05) :**
```bash
make install-cron-matomo
```

**MAJ des licenciés KPI (6h30) :**
```bash
make install-cron-maj-licencies-prod      # Production
make install-cron-maj-licencies-preprod   # Pré-production
```

**Verrou des présences KPI (5h00) :**
```bash
make install-cron-verrou-presences-prod      # Production
make install-cron-verrou-presences-preprod   # Pré-production
```

**Health check des URLs (toutes les 5 minutes) :**
```bash
make install-cron-health-check
```

Les commandes d'installation de cron :
- Détectent si un cron existe déjà (évite les doublons)
- Suppriment les anciens crons commentés
- Affichent la configuration après installation

### Gestion des logs

#### Afficher les logs disponibles
```bash
make show-logs
```
Liste tous les dossiers de logs disponibles.

#### Afficher les logs d'un service
```bash
make show-logs folder=backups          # 50 dernières lignes par défaut
make show-logs folder=kpi lines=100    # 100 dernières lignes
```

Dossiers de logs typiques :
- `backups` : Logs des sauvegardes automatiques
- `health-check` : Logs de surveillance des URLs
- `matomo` : Logs d'archivage Matomo
- `kpi` / `kpi_preprod` : Logs des jobs métier KPI

### Supervision du système

#### Afficher l'état général du serveur
```bash
make server-status
```
Affiche un tableau de bord complet avec :
- Informations système (OS, uptime, hostname)
- **État des mises à jour système (APT) avec liste des paquets disponibles**
- Performances CPU et load average
- Utilisation mémoire avec barre de progression visuelle
- État des disques avec alertes colorées
- Conteneurs Docker actifs
- Configuration réseau et IP publique
- État de la sécurité (Fail2Ban, Firewall)
- **Statistiques des sauvegardes avec état de la dernière exécution**
- **État du health check avec résumé**
- Liste des cron jobs actifs

#### Afficher la configuration LogRotate
```bash
make show-logrotate
```
Affiche :
- La configuration principale (`/etc/logrotate.conf`)
- Toutes les configurations spécifiques (`/etc/logrotate.d/*`)

#### Afficher le statut de Fail2Ban
```bash
make show-fail2ban
```
Affiche :
- Le statut du service Fail2Ban
- La liste des jails actives
- Les détails de chaque jail (IPs bannies, etc.)
- La configuration principale

#### Afficher la configuration mail
```bash
make show-mail-config
```
Détecte et affiche la configuration de l'agent de messagerie installé :
- **Postfix** : statut, configuration principale, aliases
- **SSMTP** : configuration
- **Sendmail** : statut du service

Fournit également une commande de test d'envoi de mail.

### Aide

```bash
make help
```
Affiche la liste de toutes les commandes disponibles avec leur description.

## Structure des sauvegardes

Les sauvegardes sont organisées selon cette arborescence :

```
/data/backups/
├── nom_service_1/
│   ├── daily/
│   │   ├── nom_service_1_2025-11-17.sql.gz
│   │   └── nom_service_1_2025-11-18.sql.gz
│   └── monthly/
│       ├── nom_service_1_2025-10.sql.gz
│       └── nom_service_1_2025-11.sql.gz
├── nom_service_2/
│   ├── daily/
│   └── monthly/
...
```

## Politique de rétention

### Sauvegardes journalières
- Créées chaque jour lors de l'exécution du script
- Stockées dans `{service}/daily/`
- Conservées selon `DAILY_RETENTION_DAYS` (ou valeur personnalisée par service)
- Supprimées automatiquement après la période de rétention

### Sauvegardes mensuelles
- Créées automatiquement le 1er de chaque mois
- Stockées dans `{service}/monthly/`
- Conservées selon `MONTHLY_RETENTION_MONTHS` (ou valeur personnalisée par service)
- Supprimées automatiquement après la période de rétention

### Exemple
```bash
DAILY_RETENTION_DAYS=7           # Garde 7 jours de sauvegardes quotidiennes
MONTHLY_RETENTION_MONTHS=6       # Garde 6 mois de sauvegardes mensuelles
```

Un service peut surcharger ces valeurs :
```bash
"kpi;kpi_db_1;kpi_db;user;password;14;12"  # 14 jours, 12 mois pour ce service
```

## Logs

### Structure des logs

```
/data/logs/
├── backups/
│   ├── backup.log               # Logs structurés des sauvegardes
│   └── state/                   # Fichiers d'état des backups par service
├── cron/
│   └── backups.log              # Logs bruts des exécutions cron
├── health-check/
│   ├── health-check.log         # Logs de surveillance des URLs
│   └── state/                   # Fichiers d'état des URLs surveillées
├── matomo/
│   └── matomo-archive.log       # Logs d'archivage Matomo
├── kpi/
│   ├── maj-licencies.log        # Logs MAJ licenciés (prod)
│   └── verrou-presences.log     # Logs verrou présences (prod)
└── kpi_preprod/
    ├── maj-licencies.log        # Logs MAJ licenciés (preprod)
    └── verrou-presences.log     # Logs verrou présences (preprod)
```

### Consultation des logs

Via le Makefile :
```bash
make show-logs folder=backups
```

Manuellement :
```bash
tail -f /data/logs/backups/cron.log
```

## Sécurité

### Bonnes pratiques

1. **Permissions du fichier .env :**
   ```bash
   chmod 600 .env
   ```
   Le fichier contient des mots de passe sensibles.

2. **Sauvegardes des sauvegardes :**
   Envisagez une copie hors site (rsync, cloud storage, etc.)

3. **Test de restauration :**
   Testez régulièrement la restauration sur un environnement de test

4. **Monitoring :**
   Surveillez les logs pour détecter les échecs

### Limitations

- Les mots de passe sont stockés en clair dans `.env`
- Pas de chiffrement des sauvegardes
- Pas de vérification d'intégrité (checksum)

## Dépannage

### La sauvegarde échoue

1. Vérifier que le conteneur est actif :
   ```bash
   docker ps | grep nom_conteneur
   ```

2. Tester la connexion MySQL :
   ```bash
   docker exec nom_conteneur mysql -uuser -ppassword -e "SHOW DATABASES;"
   ```

3. Vérifier les permissions du dossier de sauvegarde :
   ```bash
   ls -la /data/backups
   ```

4. Consulter les logs :
   ```bash
   make show-logs folder=backups
   ```

### Le cron ne s'exécute pas

1. Vérifier que le cron est installé :
   ```bash
   make show-cron
   ```

2. Vérifier que le service cron tourne :
   ```bash
   sudo systemctl status cron
   ```

3. Consulter les logs système :
   ```bash
   make show-cron-log
   ```

### Espace disque insuffisant

1. Vérifier l'utilisation :
   ```bash
   make disk-usage
   df -h /data/backups
   ```

2. Réduire la rétention dans `.env`

3. Supprimer manuellement les anciennes sauvegardes :
   ```bash
   find /data/backups -type f -name "*.sql.gz" -mtime +30 -delete
   ```

## Architecture technique

### Script backup.sh

Le script principal effectue :
1. Chargement de la configuration depuis `.env`
2. Pour chaque service configuré :
   - Création des dossiers daily/monthly
   - Dump MySQL via `mysqldump` dans le conteneur
   - Compression gzip du dump
   - Rotation des sauvegardes journalières
   - Si 1er du mois : promotion en sauvegarde mensuelle
   - Rotation des sauvegardes mensuelles

### Gestion des erreurs

- Utilise `set -o pipefail` pour détecter les échecs dans les pipes
- Supprime les fichiers partiels en cas d'échec
- Continue avec le service suivant en cas d'erreur (via `continue`)
- Logs détaillés à chaque étape

### Makefile

Interface utilisateur conviviale qui :
- Abstrait les commandes complexes
- Fournit des validations et confirmations
- Centralise la documentation (via `make help`)
- Gère la configuration des crons

## Licence

Ce projet est à usage interne. Tous droits réservés.

## Contributeurs

Développé pour la gestion des VPS hébergeant les applications KPI, WordPress et Matomo.
