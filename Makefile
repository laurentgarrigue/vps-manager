SHELL := /bin/bash

# Makefile pour la gestion des sauvegardes
# Utilise des commentaires '##' pour l'auto-documentation via la commande 'make help'.

.DEFAULT_GOAL := help
.PHONY: help setup backup-all list-services backup-service list-backups disk-usage inspect show-cron show-cron-log install-cron-backups install-cron-matomo install-cron-maj-licencies-preprod install-cron-maj-licencies-prod install-cron-maj-verrou-presences-preprod install-cron-maj-verrou-presences-prod install-cron-health-check restore-backup show-logs show-logrotate show-fail2ban show-mail-config show-server-status health-check

help: ## Affiche ce message d'aide.
	@echo "Administration du VPS"
	@echo "--------------------------"
	@grep -E '^[a-zA-Z_-]+:.*?##' $(MAKEFILE_LIST) | sort | awk -F '##' '{ gsub(/:+ *$$/, "", $$1); printf "  %-20s %s\n", $$1, $$2 }'

# --- Installation ---
setup: ## Initialise l environnement (crée .env, dossiers, rend le script exécutable).
	@echo "Initialisation de l environnement..."
	@if [ ! -f .env ]; then \
		cp .env.dist .env; \
		echo "Fichier .env créé. Veuillez le modifier avec vos vrais credentials."; \
	else \
		echo "Fichier .env déjà existant."; \
	fi
	@bash -c 'source .env && if [ -n "$$BACKUP_BASE_DIR" ]; then \
		mkdir -p $$BACKUP_BASE_DIR; \
	else \
		echo "Variable BACKUP_BASE_DIR non définie. Remplissez .env"; \
	fi'
	@chmod +x backup.sh
	@echo "Initialisation terminée. N oubliez pas de remplir .env !"

# --- Opérations de Sauvegarde ---
backup-all: ## Lance manuellement une sauvegarde complète de tous les services.
	@echo "Lancement manuel des sauvegardes..."
	@./backup.sh

# --- Health Check ---
health-check: ## Lance manuellement un health check des URLs configurées.
	@echo "Lancement manuel du health check..."
	@./health-check.sh

list-services: ## Liste les noms des services (conteneurs) en cours d'exécution.
	@echo "Liste des services (conteneurs) en cours d'exécution..."
	@docker ps --format "{{.Names}}"

backup-service: ## Lance la sauvegarde pour un service spécifique par son numéro.
	@bash -c '\
		source .env; \
		if [ -z "$(service)" ]; then \
			echo "Erreur: Vous devez spécifier un numéro de service. Ex: make backup-service service=<numéro>"; \
			echo "Services configurés pour la sauvegarde :"; \
			for i in "$${!SERVICES_TO_BACKUP[@]}"; do \
				SERVICE_LINE="$${SERVICES_TO_BACKUP[$$i]}"; \
				SERVICE_NAME="$$(echo "$$SERVICE_LINE" | cut -d";" -f1)"; \
				printf "  %2d. %s\n" "$$(($$i + 1))" "$$SERVICE_NAME"; \
			done; \
		else \
			INDEX=$$(($(service)-1)); \
			if [ $$INDEX -lt 0 ] || [ $$INDEX -ge $${#SERVICES_TO_BACKUP[@]} ]; then \
				echo "Erreur: Numéro de service invalide : $(service)"; \
				exit 1; \
			fi; \
			SERVICE_LINE="$${SERVICES_TO_BACKUP[$$INDEX]}"; \
			SERVICE_NAME="$$(echo "$$SERVICE_LINE" | cut -d";" -f1)"; \
			echo "Lancement de la sauvegarde pour le service #$(service) : $$SERVICE_NAME"; \
			./backup.sh "$$SERVICE_NAME"; \
		fi'

# --- Supervision ---
list-backups: ## Liste toutes les sauvegardes existantes, triées par date, dans un tableau.
	@echo "Liste des fichiers de sauvegarde..."
	@bash -c 'source .env && \
	if [ ! -d "$$BACKUP_BASE_DIR" ] || [ -z "$$(ls -A $$BACKUP_BASE_DIR)" ]; then \
		echo "Aucune sauvegarde trouvée."; \
	else \
		(echo "DATE|TAILLE|CHEMIN|NOM"; \
		cd $$BACKUP_BASE_DIR && find . -type f -name "*.sql.gz" -printf "%TY-%Tm-%Td %TH:%TM|%p|%h|%f\n" | \
		while IFS="|" read -r date path dir name; do \
			size=$$(du -h "$$path" 2>/dev/null | cut -f1); \
			echo "$$date|$$size|$$dir|$$name"; \
		done | sed "s|^\./||; s|\t./|\t|") | column -t -s "|"; \
	fi'

disk-usage: ## Affiche l espace disque total utilisé par les sauvegardes.
	@echo "Espace disque utilisé par les sauvegardes..."
	@bash -c 'source .env && du -sh $$BACKUP_BASE_DIR 2>/dev/null || echo "Dossier de sauvegarde non trouvé."'

inspect: ## Inspecte un service par son numéro. Ex: make inspect service=1
	@if [ -z "$(service)" ]; then \
		echo "Erreur: Vous devez spécifier un numéro de service. Ex: make inspect service=<numéro>"; \
		echo "Services disponibles :"; \
		docker ps --format "{{.Names}}" | cat -n; \
	else \
		SERVICE_NAME=$$(docker ps --format "{{.Names}}" | sed -n "$(service)p"); \
		if [ -z "$$SERVICE_NAME" ]; then \
			echo "Erreur: Numéro de service invalide : $(service)"; \
			echo "Services disponibles :"; \
			docker ps --format "{{.Names}}" | cat -n; \
		else \
			echo "Inspection du service #$(service) : $$SERVICE_NAME"; \
			docker inspect $$SERVICE_NAME --format '{{range .Config.Env}}{{.}}{{println}}{{end}}'; \
		fi; \
	fi

# --- Gestion Cron ---
show-cron: ## Affiche la liste des cron configurés pour l'utilisateur.
	@echo "Cron jobs pour utilisateur '$(USER)' :"
	@crontab -l 2>/dev/null || echo "-> Aucun cron job trouvé pour $(USER)."

show-cron-log: ## Affiche les logs des dernières exécutions de cron (sudo)
	@echo "Cron jobs exécutés récemment :"
	@sudo journalctl -u cron -n 100 | grep -Ei "\(($(USER))\)|\(root\)"

install-cron-backups: ## Installe le cron job pour l exécution quotidienne (ajoute si non présent).
	@bash -c 'source .env && \
	CRON_JOB="0 2 * * * /bin/bash $(CURDIR)/backup.sh >> $$LOGS_BASE_DIR/cron/backups.log 2>&1"; \
	EXISTING=$$(crontab -l 2>/dev/null | grep -F "backup.sh" | grep -v "^#" || true); \
	if [ -z "$$EXISTING" ]; then \
		COMMENTED=$$(crontab -l 2>/dev/null | grep -F "backup.sh" | grep "^#" || true); \
		if [ -n "$$COMMENTED" ]; then \
			echo "Suppression de l'\''ancien cron commenté et installation du nouveau..."; \
			crontab -l 2>/dev/null | grep -vF "backup.sh" | (cat; echo "$$CRON_JOB") | crontab -; \
		else \
			echo "Installation du nouveau cron job..."; \
			(crontab -l 2>/dev/null; echo "$$CRON_JOB") | crontab -; \
		fi; \
		echo "Cron job installé avec succès."; \
	else \
		echo "Cron job déjà existant et actif."; \
	fi'
	@make --no-print-directory show-cron

install-cron-matomo: ## Installe le cron job pour l exécution chaque heure de l'archivage matomo (ajoute si non présent).
	@bash -c 'source .env && \
	CRON_JOB="5 * * * * docker exec -t matomo_app /usr/local/bin/php /var/www/html/console core:archive --url=https://matomo.kayak-polo.info/ > $$LOGS_BASE_DIR/cron/matomo-archive.log 2>&1"; \
	EXISTING=$$(crontab -l 2>/dev/null | grep -F "matomo" | grep -v "^#" || true); \
	if [ -z "$$EXISTING" ]; then \
		COMMENTED=$$(crontab -l 2>/dev/null | grep -F "matomo" | grep "^#" || true); \
		if [ -n "$$COMMENTED" ]; then \
			echo "Suppression de l'\''ancien cron commenté et installation du nouveau..."; \
			crontab -l 2>/dev/null | grep -vF "matomo" | (cat; echo "$$CRON_JOB") | crontab -; \
		else \
			echo "Installation du nouveau cron job..."; \
			(crontab -l 2>/dev/null; echo "$$CRON_JOB") | crontab -; \
		fi; \
		echo "Cron job installé avec succès."; \
	else \
		echo "Cron job déjà existant et actif."; \
	fi'
	@make --no-print-directory show-cron

install-cron-maj-licencies-preprod: ## Installe le cron job pour la MAJ des licenciés (preprod) tous les jours à 6h30.
	@bash -c 'source .env && \
	CRON_JOB="30 6 * * * docker exec -t kpi_preprod_php /usr/local/bin/php /var/www/html/commun/cron_maj_licencies.php > $$LOGS_BASE_DIR/cron/preprod-maj-licencies.log 2>&1"; \
	EXISTING=$$(crontab -l 2>/dev/null | grep -F "cron_maj_licencies.php" | grep -F "kpi_preprod_php" | grep -v "^#" || true); \
	if [ -z "$$EXISTING" ]; then \
		COMMENTED=$$(crontab -l 2>/dev/null | grep -F "cron_maj_licencies.php" | grep -F "kpi_preprod_php" | grep "^#" || true); \
		if [ -n "$$COMMENTED" ]; then \
			echo "Suppression de l'\''ancien cron commenté et installation du nouveau..."; \
			crontab -l 2>/dev/null | grep -vF "kpi_preprod_php /usr/local/bin/php /var/www/html/commun/cron_maj_licencies.php" | (cat; echo "$$CRON_JOB") | crontab -; \
		else \
			echo "Installation du nouveau cron job..."; \
			(crontab -l 2>/dev/null; echo "$$CRON_JOB") | crontab -; \
		fi; \
		echo "Cron job installé avec succès."; \
	else \
		echo "Cron job déjà existant et actif."; \
	fi'
	@make --no-print-directory show-cron

install-cron-maj-licencies-prod: ## Installe le cron job pour la MAJ des licenciés (prod) tous les jours à 6h30.
	@bash -c 'source .env && \
	CRON_JOB="30 6 * * * docker exec -t kpi_php /usr/local/bin/php /var/www/html/commun/cron_maj_licencies.php > $$LOGS_BASE_DIR/cron/maj-licencies.log 2>&1"; \
	EXISTING=$$(crontab -l 2>/dev/null | grep -F "cron_maj_licencies.php" | grep -F "kpi_php" | grep -v "^#" || true); \
	if [ -z "$$EXISTING" ]; then \
		COMMENTED=$$(crontab -l 2>/dev/null | grep -F "cron_maj_licencies.php" | grep -F "kpi_php" | grep "^#" || true); \
		if [ -n "$$COMMENTED" ]; then \
			echo "Suppression de l'\''ancien cron commenté et installation du nouveau..."; \
			crontab -l 2>/dev/null | grep -vF "kpi_php /usr/local/bin/php /var/www/html/commun/cron_maj_licencies.php" | (cat; echo "$$CRON_JOB") | crontab -; \
		else \
			echo "Installation du nouveau cron job..."; \
			(crontab -l 2>/dev/null; echo "$$CRON_JOB") | crontab -; \
		fi; \
		echo "Cron job installé avec succès."; \
	else \
		echo "Cron job déjà existant et actif."; \
	fi'
	@make --no-print-directory show-cron

install-cron-verrou-presences-preprod: ## Installe le cron job pour le verrou des présences (preprod) tous les jours à 5h00.
	@bash -c 'source .env && \
	CRON_JOB="0 5 * * * docker exec -t kpi_preprod_php /usr/local/bin/php /var/www/html/commun/cron_verrou_presences.php > $$LOGS_BASE_DIR/cron/preprod-verrou-presences.log 2>&1"; \
	EXISTING=$$(crontab -l 2>/dev/null | grep -F "cron_verrou_presences.php" | grep -F "kpi_preprod_php" | grep -v "^#" || true); \
	if [ -z "$$EXISTING" ]; then \
		COMMENTED=$$(crontab -l 2>/dev/null | grep -F "cron_verrou_presences.php" | grep -F "kpi_preprod_php" | grep "^#" || true); \
		if [ -n "$$COMMENTED" ]; then \
			echo "Suppression de l'\''ancien cron commenté et installation du nouveau..."; \
			crontab -l 2>/dev/null | grep -vF "kpi_preprod_php /usr/local/bin/php /var/www/html/commun/cron_verrou_presences.php" | (cat; echo "$$CRON_JOB") | crontab -; \
		else \
			echo "Installation du nouveau cron job..."; \
			(crontab -l 2>/dev/null; echo "$$CRON_JOB") | crontab -; \
		fi; \
		echo "Cron job installé avec succès."; \
	else \
		echo "Cron job déjà existant et actif."; \
	fi'
	@make --no-print-directory show-cron

install-cron-verrou-presences-prod: ## Installe le cron job pour le verrou des présences (prod) tous les jours à 5h00.
	@bash -c 'source .env && \
	CRON_JOB="0 5 * * * docker exec -t kpi_php /usr/local/bin/php /var/www/html/commun/cron_verrou_presences.php > $$LOGS_BASE_DIR/cron/verrou-presences.log 2>&1"; \
	EXISTING=$$(crontab -l 2>/dev/null | grep -F "cron_verrou_presences.php" | grep -F "kpi_php" | grep -v "^#" || true); \
	if [ -z "$$EXISTING" ]; then \
		COMMENTED=$$(crontab -l 2>/dev/null | grep -F "cron_verrou_presences.php" | grep -F "kpi_php" | grep "^#" || true); \
		if [ -n "$$COMMENTED" ]; then \
			echo "Suppression de l'\''ancien cron commenté et installation du nouveau..."; \
			crontab -l 2>/dev/null | grep -vF "kpi_php /usr/local/bin/php /var/www/html/commun/cron_verrou_presences.php" | (cat; echo "$$CRON_JOB") | crontab -; \
		else \
			echo "Installation du nouveau cron job..."; \
			(crontab -l 2>/dev/null; echo "$$CRON_JOB") | crontab -; \
		fi; \
		echo "Cron job installé avec succès."; \
	else \
		echo "Cron job déjà existant et actif."; \
	fi'
	@make --no-print-directory show-cron

install-cron-health-check: ## Installe le cron job pour le health check des URLs toutes les 5 minutes.
	@bash -c 'source .env && \
	mkdir -p $$LOGS_BASE_DIR/health-check; \
	CRON_JOB="*/5 * * * * /bin/bash $(CURDIR)/health-check.sh 2>&1"; \
	EXISTING=$$(crontab -l 2>/dev/null | grep -F "health-check.sh" | grep -v "^#" || true); \
	if [ -z "$$EXISTING" ]; then \
		COMMENTED=$$(crontab -l 2>/dev/null | grep -F "health-check.sh" | grep "^#" || true); \
		if [ -n "$$COMMENTED" ]; then \
			echo "Suppression de l'\''ancien cron commenté et installation du nouveau..."; \
			crontab -l 2>/dev/null | grep -vF "health-check.sh" | (cat; echo "$$CRON_JOB") | crontab -; \
		else \
			echo "Installation du nouveau cron job..."; \
			(crontab -l 2>/dev/null; echo "$$CRON_JOB") | crontab -; \
		fi; \
		echo "Cron job health check installé avec succès (exécution toutes les 5 minutes)."; \
	else \
		echo "Cron job health check déjà existant et actif."; \
	fi'
	@make --no-print-directory show-cron

# --- Restauration ---
restore-backup: ## Restaure une sauvegarde dans un service. Ex: make restore-backup service=1 backup=<chemin>
	@bash -c '\
		source .env; \
		if [ -z "$(service)" ] || [ -z "$(backup)" ]; then \
			echo "Erreur: Vous devez spécifier un service et un fichier de sauvegarde."; \
			echo "Usage: make restore-backup service=<numéro> backup=<chemin_fichier>"; \
			echo ""; \
			echo "Services configurés pour la restauration :"; \
			for i in "$${!SERVICES_TO_BACKUP[@]}"; do \
				SERVICE_LINE="$${SERVICES_TO_BACKUP[$$i]}"; \
				SERVICE_NAME="$$(echo "$$SERVICE_LINE" | cut -d";" -f1)"; \
				printf "  %2d. %s\n" "$$(($$i + 1))" "$$SERVICE_NAME"; \
			done; \
			echo ""; \
			echo "Sauvegardes disponibles (utilisez la commande: make list-backups):"; \
			exit 1; \
		fi; \
		INDEX=$$(($(service)-1)); \
		if [ $$INDEX -lt 0 ] || [ $$INDEX -ge $${#SERVICES_TO_BACKUP[@]} ]; then \
			echo "Erreur: Numéro de service invalide : $(service)"; \
			exit 1; \
		fi; \
		SERVICE_LINE="$${SERVICES_TO_BACKUP[$$INDEX]}"; \
		IFS=";" read -r SERVICE_NAME CONTAINER_NAME DB_NAME DB_USER DB_PASS _ _ <<< "$$SERVICE_LINE"; \
		BACKUP_PATH="$(backup)"; \
		if [ ! -f "$$BACKUP_PATH" ]; then \
			if [ -f "$$BACKUP_BASE_DIR/$$BACKUP_PATH" ]; then \
				BACKUP_PATH="$$BACKUP_BASE_DIR/$$BACKUP_PATH"; \
			else \
				echo "Erreur: Fichier de sauvegarde non trouvé : $(backup)"; \
				exit 1; \
			fi; \
		fi; \
		echo "=== ATTENTION ==="; \
		echo "Vous êtes sur le point de restaurer la sauvegarde :"; \
		echo "  Fichier : $$BACKUP_PATH"; \
		echo "  Dans le service : $$SERVICE_NAME (conteneur: $$CONTAINER_NAME)"; \
		echo "  Base de données : $$DB_NAME"; \
		echo ""; \
		echo "Cette opération va ÉCRASER toutes les données actuelles de la base !"; \
		read -p "Êtes-vous sûr de vouloir continuer ? (tapez YES pour confirmer) : " CONFIRM; \
		if [ "$$CONFIRM" != "YES" ]; then \
			echo "Restauration annulée."; \
			exit 0; \
		fi; \
		echo ""; \
		echo "Démarrage de la restauration..."; \
		if zcat "$$BACKUP_PATH" | docker exec -i "$$CONTAINER_NAME" mysql -u"$$DB_USER" -p"$$DB_PASS" "$$DB_NAME"; then \
			echo "✓ Restauration réussie !"; \
		else \
			echo "✗ Erreur lors de la restauration."; \
			exit 1; \
		fi'

# --- Logs ---
show-logs: ## Affiche les derniers logs. Ex: make show-logs [folder=backups] [lines=50]
	@bash -c 'source .env && \
		if [ ! -d "$$LOGS_BASE_DIR" ]; then \
			echo "Erreur: Dossier de logs non trouvé : $$LOGS_BASE_DIR"; \
			exit 1; \
		fi; \
		if [ -z "$(folder)" ]; then \
			echo "Sous-dossiers disponibles dans $$LOGS_BASE_DIR :"; \
			echo ""; \
			if [ -z "$$(ls -A $$LOGS_BASE_DIR 2>/dev/null)" ]; then \
				echo "  (aucun sous-dossier trouvé)"; \
			else \
				for dir in $$LOGS_BASE_DIR/*/; do \
					if [ -d "$$dir" ]; then \
						dirname=$$(basename "$$dir"); \
						file_count=$$(find "$$dir" -type f 2>/dev/null | wc -l); \
						latest=$$(find "$$dir" -type f -printf "%T@ %p\n" 2>/dev/null | sort -rn | head -1 | cut -d" " -f2-); \
						if [ -n "$$latest" ]; then \
							latest_name=$$(basename "$$latest"); \
							printf "  - %-20s (%d fichier(s), dernier: %s)\n" "$$dirname" "$$file_count" "$$latest_name"; \
						else \
							printf "  - %-20s (vide)\n" "$$dirname"; \
						fi; \
					fi; \
				done; \
			fi; \
			echo ""; \
			echo "Usage: make show-logs folder=<nom_dossier> [lines=50]"; \
		else \
			LOG_DIR="$$LOGS_BASE_DIR/$(folder)"; \
			if [ ! -d "$$LOG_DIR" ]; then \
				echo "Erreur: Sous-dossier non trouvé : $$LOG_DIR"; \
				echo "Utilisez \"make show-logs\" pour voir la liste des dossiers disponibles."; \
				exit 1; \
			fi; \
			LATEST_LOG=$$(find "$$LOG_DIR" -type f -printf "%T@ %p\n" 2>/dev/null | sort -rn | head -1 | cut -d" " -f2-); \
			if [ -z "$$LATEST_LOG" ]; then \
				echo "Aucun fichier de log trouvé dans : $$LOG_DIR"; \
			else \
				LOG_LINES="$${lines:-50}"; \
				echo "Fichier de log le plus récent : $$LATEST_LOG"; \
				echo "Affichage des $$LOG_LINES dernières lignes :"; \
				echo "----------------------------------------"; \
				tail -n $$LOG_LINES "$$LATEST_LOG"; \
			fi; \
		fi'