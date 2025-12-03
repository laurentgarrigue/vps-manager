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
if [ -z "$HEALTH_CHECK_URLS" ]; then
  echo "Erreur : Variable HEALTH_CHECK_URLS non définie dans .env" >&2
  exit 1
fi

if [ -z "$HEALTH_CHECK_EMAIL" ]; then
  echo "Erreur : Variable HEALTH_CHECK_EMAIL non définie dans .env" >&2
  exit 1
fi

if [ -z "$LOGS_BASE_DIR" ]; then
  echo "Erreur : Variable LOGS_BASE_DIR non définie dans .env" >&2
  exit 1
fi

# Créer le dossier de logs si nécessaire
LOG_DIR="$LOGS_BASE_DIR/health-check"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/health-check.log"
STATE_DIR="$LOG_DIR/state"
mkdir -p "$STATE_DIR"

# Durée minimale entre deux emails d'alerte pour la même URL (en secondes)
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
send_alert_email() {
  local url_hash="$1"
  local subject="$2"
  local body="$3"
  local alert_type="$4"  # "error" ou "resolved"

  local state_file="$STATE_DIR/${url_hash}.state"
  local last_alert_file="$STATE_DIR/${url_hash}.last_alert"
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
      # log_message "INFO" "Détection d'un nouveau problème, envoi d'email immédiat"
    elif [ -f "$last_alert_file" ]; then
      # Toujours en erreur : vérifier le throttle
      local last_alert_time=$(cat "$last_alert_file")
      local time_diff=$((current_time - last_alert_time))

      if [ $time_diff -ge $EMAIL_THROTTLE_SECONDS ]; then
        should_send_email=true
        # log_message "INFO" "Délai de throttling écoulé (${time_diff}s), envoi d'email de rappel"
      # else
        # log_message "INFO" "Email throttle actif, pas d'envoi (dernier envoi il y a ${time_diff}s)"
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
      # log_message "INFO" "Problème résolu, envoi d'email de résolution"
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
    # pour éviter de tenter d'envoyer trop souvent même si l'envoi échoue
    if [ "$alert_type" = "error" ]; then
      echo "$current_time" > "$last_alert_file"
    fi
  fi
}

# Fonction de génération d'un hash pour identifier une URL
get_url_hash() {
  local url="$1"
  echo -n "$url" | md5sum | cut -d' ' -f1
}

# Fonction de vérification d'une URL
check_url() {
  local url="$1"
  local label="$2"
  local expected_codes="$3"

  local url_hash=$(get_url_hash "$url")

  # log_message "INFO" "Vérification de '$label' ($url)"

  # Effectue la requête HTTP avec timeout de 10 secondes
  http_code=$(curl -o /dev/null -s -w "%{http_code}" --connect-timeout 10 --max-time 10 "$url")
  curl_exit_code=$?

  # Si curl a échoué
  if [ $curl_exit_code -ne 0 ]; then
    log_message "ERROR" "'$label' ($url) - Échec de la connexion (code erreur curl: $curl_exit_code)"
    send_alert_email \
      "$url_hash" \
      "[HEALTH CHECK] Échec de connexion - $label" \
      "L'URL '$label' est inaccessible.

URL: $url
Erreur: Échec de la connexion (code curl: $curl_exit_code)
Date: $(date '+%Y-%m-%d %H:%M:%S')

Veuillez vérifier l'état du service." \
      "error"
    return 1
  fi

  # Vérifie si le code HTTP est dans la liste des codes attendus
  if echo "$expected_codes" | grep -qw "$http_code"; then
    log_message "OK" "'$label' ($url) - Code HTTP $http_code (attendu: $expected_codes)"

    # Vérifier si c'est une résolution de problème
    local state_file="$STATE_DIR/${url_hash}.state"
    if [ -f "$state_file" ] && [ "$(cat "$state_file")" = "error" ]; then
      send_alert_email \
        "$url_hash" \
        "[HEALTH CHECK] Problème résolu - $label" \
        "L'URL '$label' est de nouveau accessible.

URL: $url
Code HTTP: $http_code
Date de résolution: $(date '+%Y-%m-%d %H:%M:%S')

Le service fonctionne à nouveau normalement." \
        "resolved"
    else
      # Pas de changement d'état, juste mettre à jour le fichier d'état
      echo "ok" > "$state_file"
    fi

    return 0
  else
    log_message "ERROR" "'$label' ($url) - Code HTTP $http_code inattendu (attendu: $expected_codes)"
    send_alert_email \
      "$url_hash" \
      "[HEALTH CHECK] Code HTTP inattendu - $label" \
      "L'URL '$label' a retourné un code HTTP inattendu.

URL: $url
Code HTTP reçu: $http_code
Codes attendus: $expected_codes
Date: $(date '+%Y-%m-%d %H:%M:%S')

Veuillez vérifier l'état du service." \
      "error"
    return 1
  fi
}

# Début du health check
# log_message "INFO" "=== Début du health check ==="

total_checks=0
failed_checks=0

# Parcours de toutes les URLs configurées
for url_config in "${HEALTH_CHECK_URLS[@]}"; do
  # Parse la configuration: "URL;LABEL;CODES"
  IFS=';' read -r url label expected_codes <<< "$url_config"

  # Valeurs par défaut
  if [ -z "$label" ]; then
    label="$url"
  fi

  if [ -z "$expected_codes" ]; then
    expected_codes="200 304"
  fi

  total_checks=$((total_checks + 1))

  if ! check_url "$url" "$label" "$expected_codes"; then
    failed_checks=$((failed_checks + 1))
  fi
done

# Résumé
if [ $failed_checks -eq 0 ]; then
  log_message "INFO" "=== Health check terminé : $total_checks/$total_checks URLs OK ==="
else
  log_message "WARNING" "=== Health check terminé : $failed_checks/$total_checks URLs en erreur ==="
fi

exit 0
