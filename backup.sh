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

# Date du jour au format YYYY-MM-DD
TODAY=$(date +%F)

# Boucle sur chaque service défini dans la configuration
for service_config in "${SERVICES_TO_BACKUP[@]}"; do
  # Parse la ligne de configuration (avec les rétentions optionnelles)
  IFS=';' read -r SERVICE_NAME CONTAINER_NAME DB_NAME DB_USER DB_PASS DAILY_RET MONTHLY_RET <<< "$service_config"

  echo "--- Traitement de la sauvegarde pour le service : $SERVICE_NAME ---"

  # --- Définition de la politique de rétention ---
  # Utilise la rétention spécifique au service si définie, sinon la globale
  local_daily_days=${DAILY_RET:-$DAILY_RETENTION_DAYS}
  local_monthly_months=${MONTHLY_RET:-$MONTHLY_RETENTION_MONTHS}
  echo "Politique de rétention appliquée : $local_daily_days jours (daily), $local_monthly_months mois (monthly)."

  # Crée les dossiers de sauvegarde s'ils n'existent pas
  DAILY_DIR="$BACKUP_BASE_DIR/$SERVICE_NAME/daily"
  MONTHLY_DIR="$BACKUP_BASE_DIR/$SERVICE_NAME/monthly"
  mkdir -p "$DAILY_DIR"
  mkdir -p "$MONTHLY_DIR"

  # Nom et chemin du fichier de sauvegarde
  BACKUP_FILE="$DAILY_DIR/${SERVICE_NAME}_${TODAY}.sql.gz"

  # --- Exécution de la sauvegarde ---
  echo "Démarrage du dump de la base '$DB_NAME' depuis le conteneur '$CONTAINER_NAME'..."
  if docker exec "$CONTAINER_NAME" mysqldump -u"$DB_USER" -p"$DB_PASS" "$DB_NAME" | gzip > "$BACKUP_FILE"; then
    echo "Sauvegarde réussie dans : $BACKUP_FILE"
  else
    echo "Erreur lors de la sauvegarde de '$DB_NAME'. Suppression du fichier partiel." >&2
    rm -f "$BACKUP_FILE"
    continue # Passe au service suivant
  fi

  # --- Rotation des sauvegardes journalières ---
  echo "Nettoyage des sauvegardes journalières de plus de $local_daily_days jours..."
  find "$DAILY_DIR" -type f -name '*.sql.gz' -mtime +$local_daily_days -delete

  # --- Promotion en sauvegarde mensuelle (le 1er du mois) ---
  if [ "$(date +%d)" = "01" ]; then
    echo "C'est le premier du mois, promotion de la sauvegarde en mensuelle."
    MONTHLY_FILE="$MONTHLY_DIR/${SERVICE_NAME}_$(date +%Y-%m).sql.gz"
    cp "$BACKUP_FILE" "$MONTHLY_FILE"
    echo "Sauvegarde mensuelle créée : $MONTHLY_FILE"

    # --- Rotation des sauvegardes mensuelles ---
    # Calcule le nombre de jours équivalent à N mois (approx.)
    RETENTION_DAYS=$(($local_monthly_months * 31))
    echo "Nettoyage des sauvegardes mensuelles de plus de $local_monthly_months mois ($RETENTION_DAYS jours)..."
    find "$MONTHLY_DIR" -type f -name '*.sql.gz' -mtime +$RETENTION_DAYS -delete
  fi

done

echo "--- Opérations de sauvegarde terminées. ---"
