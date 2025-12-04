#!/bin/bash
set -o pipefail

# Se place dans le répertoire du script pour que le .env soit trouvé
cd "$(dirname "$0")"

# Charge la configuration si le fichier .env existe
if [ -f .env ]; then
  source .env
else
  echo "Erreur : Fichier de configuration .env non trouvé." >&2
  exit 1
fi

# Vérifications des variables d'environnement requises
if [ -z "$HEALTH_CHECK_EMAIL" ]; then
  echo "Erreur : Variable HEALTH_CHECK_EMAIL non définie dans .env" >&2
  exit 1
fi

if [ -z "$LOGS_BASE_DIR" ]; then
  echo "Erreur : Variable LOGS_BASE_DIR non définie dans .env" >&2
  exit 1
fi

# Créer le dossier de logs si nécessaire
LOG_DIR="$LOGS_BASE_DIR/backups"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/backup.log"
STATE_DIR="$LOG_DIR/state"
mkdir -p "$STATE_DIR"

# Durée minimale entre deux emails d'alerte pour le même service (en secondes)
EMAIL_THROTTLE_SECONDS=3600  # 1 heure

# Fonction de logging
log_message() {
  local level=$1
  shift
  local message="$@"
  local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
  echo "[$timestamp] [$level] $message" | tee -a "$LOG_FILE"
}

# Fonction d'envoi d'email d'alerte avec throttling
send_backup_alert_email() {
  local service_name="$1"
  local subject="$2"
  local body="$3"
  local alert_type="$4"  # "error" ou "resolved"

  local state_file="$STATE_DIR/${service_name}.state"
  local last_alert_file="$STATE_DIR/${service_name}.last_alert"
  local current_time=$(date +%s)

  # Lire l'état précédent
  local previous_state=""
  if [ -f "$state_file" ]; then
    previous_state=$(cat "$state_file")
  fi

  local should_send_email=false

  if [ "$alert_type" = "error" ]; then
    # Pour les erreurs : envoyer si changement d'état ou si délai écoulé
    if [ "$previous_state" != "error" ]; then
      # Changement d'état : envoyer immédiatement
      should_send_email=true
    elif [ -f "$last_alert_file" ]; then
      # Toujours en erreur : vérifier le throttle
      local last_alert_time=$(cat "$last_alert_file")
      local time_diff=$((current_time - last_alert_time))

      if [ $time_diff -ge $EMAIL_THROTTLE_SECONDS ]; then
        should_send_email=true
      fi
    else
      # Pas de dernier envoi enregistré
      should_send_email=true
    fi

    # Enregistrer l'état d'erreur
    echo "error" > "$state_file"
  elif [ "$alert_type" = "resolved" ]; then
    # Pour les résolutions : envoyer seulement si changement d'état
    if [ "$previous_state" = "error" ]; then
      should_send_email=true
    fi

    # Enregistrer l'état OK
    echo "ok" > "$state_file"
    # Supprimer le fichier de dernier envoi
    rm -f "$last_alert_file"
  fi

  # Envoyer l'email si nécessaire
  if [ "$should_send_email" = true ]; then
    local send_result=1

    if command -v mail &> /dev/null; then
      echo "$body" | mail -s "$subject" -r "${HEALTH_CHECK_FROM_NAME} <${HEALTH_CHECK_FROM_EMAIL}>" "$HEALTH_CHECK_EMAIL"
      send_result=$?
    elif command -v sendmail &> /dev/null; then
      echo -e "From: ${HEALTH_CHECK_FROM_NAME} <${HEALTH_CHECK_FROM_EMAIL}>\nSubject: $subject\n\n$body" | sendmail "$HEALTH_CHECK_EMAIL"
      send_result=$?
    else
      log_message "WARNING" "Impossible d'envoyer l'email : aucun agent de messagerie trouvé (mail/sendmail)"
    fi

    if [ $send_result -eq 0 ]; then
      log_message "INFO" "Email envoyé à $HEALTH_CHECK_EMAIL : $subject"
    else
      log_message "WARNING" "Tentative d'envoi d'email (agent de messagerie non disponible ou erreur)"
    fi

    # Enregistrer le timestamp de la tentative d'envoi (pour les erreurs uniquement)
    if [ "$alert_type" = "error" ]; then
      echo "$current_time" > "$last_alert_file"
    fi
  fi
}

# Date du jour au format YYYY-MM-DD
TODAY=$(date +%F)

# Si un service est passé en argument, on ne sauvegarde que celui-là
if [ -n "$1" ]; then
  log_message "INFO" "Sauvegarde demandée pour un seul service : $1"
  SINGLE_SERVICE_CONFIG=""
  for service_config in "${SERVICES_TO_BACKUP[@]}"; do
    IFS=';' read -r SERVICE_NAME _ <<< "$service_config"
    if [ "$SERVICE_NAME" = "$1" ]; then
      SINGLE_SERVICE_CONFIG="$service_config"
      break
    fi
  done

  if [ -z "$SINGLE_SERVICE_CONFIG" ]; then
    log_message "ERROR" "Le service '$1' n'a pas été trouvé dans la configuration SERVICES_TO_BACKUP."
    exit 1
  fi
  # On remplace la liste des services par le service unique
  SERVICES_TO_BACKUP=("$SINGLE_SERVICE_CONFIG")
fi

# Compteurs pour le résumé
total_backups=0
successful_backups=0
failed_backups=0

# Boucle sur chaque service défini dans la configuration
for service_config in "${SERVICES_TO_BACKUP[@]}"; do
  # Parse la ligne de configuration (avec les rétentions optionnelles)
  IFS=';' read -r SERVICE_NAME CONTAINER_NAME DB_NAME DB_USER DB_PASS DAILY_RET MONTHLY_RET <<< "$service_config"

  total_backups=$((total_backups + 1))

  # --- Définition de la politique de rétention ---
  # Utilise la rétention spécifique au service si définie, sinon la globale
  DAILY_DAYS=${DAILY_RET:-$DAILY_RETENTION_DAYS}
  MONTHLY_MONTHS=${MONTHLY_RET:-$MONTHLY_RETENTION_MONTHS}

  # Crée les dossiers de sauvegarde s'ils n'existent pas
  DAILY_DIR="$BACKUP_BASE_DIR/$SERVICE_NAME/daily"
  MONTHLY_DIR="$BACKUP_BASE_DIR/$SERVICE_NAME/monthly"
  mkdir -p "$DAILY_DIR"
  mkdir -p "$MONTHLY_DIR"

  # Nom et chemin du fichier de sauvegarde
  BACKUP_FILE="$DAILY_DIR/${SERVICE_NAME}_${TODAY}.sql.gz"

  # --- Exécution de la sauvegarde ---
  if docker exec "$CONTAINER_NAME" mariadb-dump -u"$DB_USER" -p"$DB_PASS" "$DB_NAME" | gzip > "$BACKUP_FILE"; then
    log_message "OK" "Backup '$SERVICE_NAME' réussi ($DB_NAME)"
    successful_backups=$((successful_backups + 1))

    # Vérifier si c'est une résolution de problème
    STATE_FILE="$STATE_DIR/${SERVICE_NAME}.state"
    if [ -f "$STATE_FILE" ] && [ "$(cat "$STATE_FILE")" = "error" ]; then
      send_backup_alert_email \
        "$SERVICE_NAME" \
        "[BACKUP] Problème résolu - $SERVICE_NAME" \
        "La sauvegarde du service '$SERVICE_NAME' fonctionne à nouveau normalement.

Service: $SERVICE_NAME
Base de données: $DB_NAME
Conteneur: $CONTAINER_NAME
Fichier: $BACKUP_FILE
Date de résolution: $(date '+%Y-%m-%d %H:%M:%S')

La sauvegarde s'est exécutée avec succès." \
        "resolved"
    else
      # Pas de changement d'état, juste mettre à jour le fichier d'état
      echo "ok" > "$STATE_FILE"
    fi

    # --- Rotation des sauvegardes journalières ---
    find "$DAILY_DIR" -type f -name '*.sql.gz' -mtime +$DAILY_DAYS -delete

    # --- Promotion en sauvegarde mensuelle (le 1er du mois) ---
    if [ "$(date +%d)" = "01" ]; then
      MONTHLY_FILE="$MONTHLY_DIR/${SERVICE_NAME}_$(date +%Y-%m).sql.gz"
      cp "$BACKUP_FILE" "$MONTHLY_FILE"

      # --- Rotation des sauvegardes mensuelles ---
      # Calcule le nombre de jours équivalent à N mois (approx.)
      MONTHLY_RETENTION_DAYS=$(($MONTHLY_MONTHS * 31))
      find "$MONTHLY_DIR" -type f -name '*.sql.gz' -mtime +$MONTHLY_RETENTION_DAYS -delete
    fi
  else
    log_message "ERROR" "Backup '$SERVICE_NAME' échoué ($DB_NAME)"
    rm -f "$BACKUP_FILE"
    failed_backups=$((failed_backups + 1))

    # Envoyer une alerte email
    send_backup_alert_email \
      "$SERVICE_NAME" \
      "[BACKUP] Échec de sauvegarde - $SERVICE_NAME" \
      "La sauvegarde du service '$SERVICE_NAME' a échoué.

Service: $SERVICE_NAME
Base de données: $DB_NAME
Conteneur: $CONTAINER_NAME
Date: $(date '+%Y-%m-%d %H:%M:%S')

Veuillez vérifier l'état du conteneur et de la base de données.

Commandes de diagnostic :
  docker ps | grep $CONTAINER_NAME
  docker logs $CONTAINER_NAME --tail 50" \
      "error"

    continue # Passe au service suivant
  fi

done

# Résumé quotidien
if [ $failed_backups -eq 0 ]; then
  log_message "INFO" "=== Backups terminés : $successful_backups/$total_backups réussis ==="
else
  log_message "WARNING" "=== Backups terminés : $failed_backups/$total_backups échoués ==="
fi

exit 0
