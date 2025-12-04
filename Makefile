SHELL := /bin/bash

# Makefile pour la gestion des sauvegardes
# Utilise des commentaires '##' pour l'auto-documentation via la commande 'make help'.

.DEFAULT_GOAL := help
.PHONY: help setup backup-all list-services backup-service list-backups disk-usage inspect show-cron show-cron-log install-cron-backups install-cron-matomo install-cron-maj-licencies-preprod install-cron-maj-licencies-prod install-cron-maj-verrou-presences-preprod install-cron-maj-verrou-presences-prod install-cron-health-check restore-backup show-logs show-logrotate show-fail2ban show-mail-config server-status health-check

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

# --- Supervision Système ---
show-logrotate: ## Affiche la configuration LogRotate du système.
	@echo "=== Configuration LogRotate ==="
	@echo ""
	@echo "Fichiers de configuration LogRotate :"
	@echo "-------------------------------------"
	@if [ -f /etc/logrotate.conf ]; then \
		echo ""; \
		echo "📄 Configuration principale : /etc/logrotate.conf"; \
		echo ""; \
		cat /etc/logrotate.conf; \
	else \
		echo "⚠️  Fichier /etc/logrotate.conf non trouvé."; \
	fi
	@echo ""
	@echo "-------------------------------------"
	@echo "Configurations spécifiques (/etc/logrotate.d/) :"
	@echo "-------------------------------------"
	@if [ -d /etc/logrotate.d ]; then \
		for file in /etc/logrotate.d/*; do \
			if [ -f "$$file" ]; then \
				echo ""; \
				echo "📄 $$(basename $$file)"; \
				echo "---"; \
				cat "$$file"; \
				echo ""; \
			fi; \
		done; \
	else \
		echo "⚠️  Dossier /etc/logrotate.d/ non trouvé."; \
	fi

show-fail2ban: ## Affiche le statut et la configuration de Fail2Ban.
	@echo "=== Fail2Ban - Statut et Configuration ==="
	@echo ""
	@if ! command -v fail2ban-client &> /dev/null; then \
		echo "⚠️  Fail2Ban n'est pas installé sur ce système."; \
		exit 0; \
	fi
	@echo "📊 Statut du service Fail2Ban :"
	@echo "-------------------------------"
	@sudo systemctl status fail2ban --no-pager -l || echo "⚠️  Impossible de récupérer le statut."
	@echo ""
	@echo "🔒 Jails actives :"
	@echo "------------------"
	@sudo fail2ban-client status 2>/dev/null || echo "⚠️  Impossible de récupérer les jails."
	@echo ""
	@echo "📋 Détails des jails :"
	@echo "----------------------"
	@for jail in $$(sudo fail2ban-client status 2>/dev/null | grep "Jail list:" | sed 's/.*://; s/,//g'); do \
		echo ""; \
		echo "Jail: $$jail"; \
		sudo fail2ban-client status $$jail 2>/dev/null || true; \
		echo ""; \
	done
	@echo "📄 Configuration principale (/etc/fail2ban/jail.local) :"
	@echo "--------------------------------------------------------"
	@if [ -f /etc/fail2ban/jail.local ]; then \
		cat /etc/fail2ban/jail.local; \
	elif [ -f /etc/fail2ban/jail.conf ]; then \
		echo "⚠️  jail.local non trouvé, affichage de jail.conf :"; \
		cat /etc/fail2ban/jail.conf; \
	else \
		echo "⚠️  Aucun fichier de configuration trouvé."; \
	fi

show-mail-config: ## Affiche la configuration de l'envoi de mails (Postfix/SSMTP).
	@echo "=== Configuration de l'envoi de mails ==="
	@echo ""
	@if command -v postfix &> /dev/null; then \
		echo "📧 Postfix détecté"; \
		echo "-----------------"; \
		echo ""; \
		echo "Statut du service :"; \
		sudo systemctl status postfix --no-pager -l 2>/dev/null || echo "⚠️  Service non actif"; \
		echo ""; \
		echo "Configuration principale (/etc/postfix/main.cf) :"; \
		echo "------------------------------------------------"; \
		if [ -f /etc/postfix/main.cf ]; then \
			grep -v "^#" /etc/postfix/main.cf | grep -v "^$$"; \
		else \
			echo "⚠️  Fichier non trouvé"; \
		fi; \
		echo ""; \
		echo "Aliases (/etc/aliases) :"; \
		echo "------------------------"; \
		if [ -f /etc/aliases ]; then \
			grep -v "^#" /etc/aliases | grep -v "^$$"; \
		else \
			echo "⚠️  Fichier non trouvé"; \
		fi; \
	elif command -v ssmtp &> /dev/null; then \
		echo "📧 SSMTP détecté"; \
		echo "----------------"; \
		echo ""; \
		if [ -f /etc/ssmtp/ssmtp.conf ]; then \
			echo "Configuration (/etc/ssmtp/ssmtp.conf) :"; \
			echo "---------------------------------------"; \
			sudo cat /etc/ssmtp/ssmtp.conf 2>/dev/null || echo "⚠️  Accès refusé"; \
		else \
			echo "⚠️  Fichier de configuration non trouvé"; \
		fi; \
	elif command -v sendmail &> /dev/null; then \
		echo "📧 Sendmail détecté"; \
		echo "-------------------"; \
		echo ""; \
		echo "Statut du service :"; \
		sudo systemctl status sendmail --no-pager -l 2>/dev/null || echo "⚠️  Service non actif"; \
	else \
		echo "⚠️  Aucun agent de messagerie détecté (Postfix, SSMTP, Sendmail)"; \
	fi
	@echo ""
	@echo "Test de configuration mail :"
	@echo "----------------------------"
	@echo "Pour tester l'envoi : echo 'Test' | mail -s 'Test VPS' votre@email.com"

server-status: ## Affiche l'état général du serveur avec KPIs visuels.
	@echo "╔════════════════════════════════════════════════════════════╗"
	@echo "║           📊 TABLEAU DE BORD DU SERVEUR VPS               ║"
	@echo "╚════════════════════════════════════════════════════════════╝"
	@echo ""
	@echo "🖥️  SYSTÈME"
	@echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
	@echo "Hostname      : $$(hostname)"
	@echo "OS            : $$(lsb_release -d 2>/dev/null | cut -f2 || cat /etc/os-release | grep PRETTY_NAME | cut -d'=' -f2 | tr -d '\"')"
	@echo "Kernel        : $$(uname -r)"
	@echo "Uptime        : $$(uptime -p)"
	@echo "Date          : $$(date '+%Y-%m-%d %H:%M:%S %Z')"
	@echo ""
	@echo "🔄 MISES À JOUR"
	@echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
	@bash -c 'if command -v apt-get &> /dev/null; then \
		UPDATES=$$(apt list --upgradable 2>/dev/null | grep -E "^[a-z0-9]" | grep "/" | wc -l); \
		SECURITY=$$(apt list --upgradable 2>/dev/null | grep -E "^[a-z0-9]" | grep -i security | wc -l); \
		if [ -f /var/lib/apt/periodic/update-success-stamp ]; then \
			LAST_UPDATE=$$(stat -c %Y /var/lib/apt/periodic/update-success-stamp 2>/dev/null || echo 0); \
			NOW=$$(date +%s); \
			AGE=$$(($$NOW - $$LAST_UPDATE)); \
			AGE_HOURS=$$(($$AGE / 3600)); \
			if [ $$AGE_HOURS -lt 24 ]; then \
				printf "Dernière vérif: Il y a %dh\n" $$AGE_HOURS; \
			else \
				AGE_DAYS=$$(($$AGE_HOURS / 24)); \
				printf "Dernière vérif: Il y a %dj\n" $$AGE_DAYS; \
			fi; \
		fi; \
		if [ $$UPDATES -eq 0 ]; then \
			echo "État          : ✓ Système à jour"; \
		else \
			echo "État          : ⚠️  $$UPDATES mise(s) à jour disponible(s)"; \
			if [ $$SECURITY -gt 0 ]; then \
				echo "Sécurité      : ⚠️  $$SECURITY mise(s) à jour de sécurité"; \
			else \
				echo "Sécurité      : ✓ Aucune mise à jour de sécurité"; \
			fi; \
			echo ""; \
			echo "Paquets à mettre à jour :"; \
			apt list --upgradable 2>/dev/null | grep -E "^[a-z0-9]" | grep "/" | head -10 | while IFS= read -r line; do \
				PKG=$$(echo "$$line" | cut -d"/" -f1); \
				VERSION=$$(echo "$$line" | grep -oP "\[upgradable from: \K[^\]]+"); \
				NEW_VERSION=$$(echo "$$line" | awk "{print \$$2}"); \
				if echo "$$line" | grep -qi security; then \
					printf "  🔒 %-30s %s → %s\n" "$$PKG" "$$VERSION" "$$NEW_VERSION"; \
				else \
					printf "  •  %-30s %s → %s\n" "$$PKG" "$$VERSION" "$$NEW_VERSION"; \
				fi; \
			done; \
			if [ $$UPDATES -gt 10 ]; then \
				echo "  ... et $$(($$UPDATES - 10)) autre(s)"; \
			fi; \
			echo ""; \
			echo "Commande      : sudo apt-get update && sudo apt-get upgrade"; \
		fi; \
	else \
		echo "⚠️  APT non disponible sur ce système"; \
	fi'
	@echo ""
	@echo "⚡ PERFORMANCES CPU"
	@echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
	@echo "Architecture  : $$(uname -m)"
	@echo "CPU(s)        : $$(nproc) core(s)"
	@echo "Load Average  : $$(cat /proc/loadavg | cut -d' ' -f1-3)"
	@bash -c 'LOAD=$$(cat /proc/loadavg | cut -d" " -f1); \
		CORES=$$(nproc); \
		LOAD_PERCENT=$$(echo "scale=1; ($$LOAD / $$CORES) * 100" | bc 2>/dev/null || echo "N/A"); \
		echo "CPU Usage     : $$LOAD_PERCENT%"'
	@echo ""
	@echo "💾 MÉMOIRE"
	@echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
	@free -h | awk 'NR==1{printf "%-14s %10s %10s %10s %10s\n", "", $$1, $$2, $$3, $$6} NR==2{printf "%-14s %10s %10s %10s %10s\n", "RAM:", $$2, $$3, $$4, $$7}'
	@bash -c 'MEM_TOTAL=$$(free | awk "NR==2{print \$$2}"); \
		MEM_USED=$$(free | awk "NR==2{print \$$3}"); \
		MEM_PERCENT=$$(echo "scale=1; ($$MEM_USED / $$MEM_TOTAL) * 100" | bc); \
		BAR_LEN=30; \
		FILLED=$$(echo "scale=0; $$BAR_LEN * $$MEM_USED / $$MEM_TOTAL" | bc); \
		EMPTY=$$(echo "$$BAR_LEN - $$FILLED" | bc); \
		printf "Usage         : ["; \
		for i in $$(seq 1 $$FILLED); do printf "█"; done; \
		for i in $$(seq 1 $$EMPTY); do printf "░"; done; \
		printf "] $$MEM_PERCENT%%\n"'
	@echo ""
	@echo "💿 DISQUES"
	@echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
	@df -h | awk 'NR==1 || $$1 ~ /^\/dev\//' | while IFS= read -r line; do \
		if echo "$$line" | grep -q "fichiers\|Filesystem"; then \
			printf "%-4s %s\n" "" "$$line"; \
		else \
			USAGE=$$(echo "$$line" | awk '{print $$5}' | tr -d '%'); \
			if [ "$$USAGE" -ge 90 ] 2>/dev/null; then \
				printf "⚠️  %s\n" "$$line"; \
			elif [ "$$USAGE" -ge 75 ] 2>/dev/null; then \
				printf "⚡ %s\n" "$$line"; \
			else \
				printf "✓  %s\n" "$$line"; \
			fi; \
		fi; \
	done
	@echo ""
	@echo "🐳 DOCKER"
	@echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
	@if command -v docker &> /dev/null; then \
		echo "Version       : $$(docker --version | cut -d' ' -f3 | tr -d ',')"; \
		echo "Conteneurs    : $$(docker ps -q | wc -l) actifs / $$(docker ps -aq | wc -l) total"; \
		echo "Images        : $$(docker images -q | wc -l)"; \
		echo "Volumes       : $$(docker volume ls -q | wc -l)"; \
		echo "Réseaux       : $$(docker network ls -q | wc -l)"; \
		echo ""; \
		echo "Conteneurs en cours d'exécution :"; \
		docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Image}}" | head -15; \
	else \
		echo "⚠️  Docker non installé"; \
	fi
	@echo ""
	@echo "🌐 RÉSEAU"
	@echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
	@echo "IP Publique   : $$(curl -s ifconfig.me 2>/dev/null || echo 'N/A')"
	@echo "Interfaces    :"
	@ip -br addr | grep -v "lo" | awk '{printf "  - %-10s : %s\n", $$1, $$3}'
	@echo "Connexions    : $$(ss -tun | wc -l) actives"
	@echo ""
	@echo "🔐 SÉCURITÉ"
	@echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
	@if command -v fail2ban-client &> /dev/null; then \
		echo "Fail2Ban      : ✓ Installé"; \
		if sudo systemctl is-active --quiet fail2ban 2>/dev/null; then \
			echo "              : ✓ Actif"; \
			JAILS=$$(sudo fail2ban-client status 2>/dev/null | grep "Jail list:" | sed 's/.*://; s/,//g' | wc -w); \
			echo "              : $$JAILS jail(s) configurée(s)"; \
			BANNED=$$(sudo fail2ban-client status 2>/dev/null | grep -E "Currently banned" | awk '{sum+=$$NF} END {print sum+0}'); \
			echo "              : $$BANNED IP(s) bannies"; \
		else \
			echo "              : ⚠️  Inactif"; \
		fi; \
	else \
		echo "Fail2Ban      : ⚠️  Non installé"; \
	fi
	@if command -v ufw &> /dev/null; then \
		echo "Firewall (UFW): ✓ Installé"; \
		UFW_STATUS=$$(sudo ufw status 2>/dev/null | head -1); \
		echo "              : $$UFW_STATUS"; \
	elif command -v iptables &> /dev/null; then \
		RULES=$$(sudo iptables -L | grep -c "^Chain"); \
		echo "Firewall      : iptables ($$RULES chaînes)"; \
	else \
		echo "Firewall      : ⚠️  Aucun détecté"; \
	fi
	@echo ""
	@echo "📦 SAUVEGARDES"
	@echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
	@bash -c 'source .env 2>/dev/null || true; \
		if [ -d "$$BACKUP_BASE_DIR" ]; then \
			BACKUP_COUNT=$$(find $$BACKUP_BASE_DIR -type f -name "*.sql.gz" 2>/dev/null | wc -l); \
			BACKUP_SIZE=$$(du -sh $$BACKUP_BASE_DIR 2>/dev/null | cut -f1); \
			LAST_BACKUP=$$(find $$BACKUP_BASE_DIR -type f -name "*.sql.gz" -printf "%T@ %p\n" 2>/dev/null | sort -rn | head -1 | cut -d" " -f2- | xargs -I {} stat -c "%y" {} 2>/dev/null | cut -d. -f1); \
			echo "Répertoire    : $$BACKUP_BASE_DIR"; \
			echo "Nombre        : $$BACKUP_COUNT sauvegarde(s)"; \
			echo "Taille totale : $$BACKUP_SIZE"; \
			if [ -n "$$LAST_BACKUP" ]; then \
				echo "Dernière      : $$LAST_BACKUP"; \
			else \
				echo "Dernière      : Aucune"; \
			fi; \
			if [ -d "$$LOGS_BASE_DIR/backups" ] && [ -f "$$LOGS_BASE_DIR/backups/backup.log" ]; then \
				LOG_FILE="$$LOGS_BASE_DIR/backups/backup.log"; \
				LAST_RUN=$$(tail -1 "$$LOG_FILE" 2>/dev/null | grep -oP "^\[\K[^]]*" || echo "Jamais"); \
				echo "Dernière exec : $$LAST_RUN"; \
				LAST_SUMMARY=$$(tail -1 "$$LOG_FILE" 2>/dev/null); \
				if echo "$$LAST_SUMMARY" | grep -q "réussis"; then \
					STATS=$$(echo "$$LAST_SUMMARY" | grep -oP "\d+/\d+" | head -1); \
					SUCCESS=$$(echo "$$STATS" | cut -d"/" -f1); \
					TOTAL=$$(echo "$$STATS" | cut -d"/" -f2); \
					if [ "$$SUCCESS" = "$$TOTAL" ]; then \
						echo "État          : ✓ Tous les backups OK ($$STATS)"; \
					else \
						echo "État          : ⚠️  $$SUCCESS/$$TOTAL réussis"; \
					fi; \
				elif echo "$$LAST_SUMMARY" | grep -q "échoués"; then \
					STATS=$$(echo "$$LAST_SUMMARY" | grep -oP "\d+/\d+" | head -1); \
					FAILED=$$(echo "$$STATS" | cut -d"/" -f1); \
					TOTAL=$$(echo "$$STATS" | cut -d"/" -f2); \
					SUCCESS=$$((TOTAL - FAILED)); \
					echo "État          : ⚠️  $$FAILED échec(s) / $$SUCCESS OK"; \
				else \
					echo "État          : Aucun backup récent"; \
				fi; \
			fi; \
		else \
			echo "⚠️  Répertoire de sauvegarde non configuré"; \
		fi'
	@echo ""
	@echo "🏥 HEALTH CHECK"
	@echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
	@bash -c 'source .env 2>/dev/null || true; \
		if [ -d "$$LOGS_BASE_DIR/health-check" ]; then \
			LOG_FILE="$$LOGS_BASE_DIR/health-check/health-check.log"; \
			STATE_DIR="$$LOGS_BASE_DIR/health-check/state"; \
			URLS_COUNT=$${#HEALTH_CHECK_URLS[@]}; \
			echo "URLs surveillées : $$URLS_COUNT"; \
			if [ -f "$$LOG_FILE" ]; then \
				LAST_CHECK=$$(tail -1 "$$LOG_FILE" 2>/dev/null | grep -oP "^\[\K[^]]*" || echo "Jamais"); \
				echo "Dernière vérif : $$LAST_CHECK"; \
				LAST_SUMMARY=$$(tail -1 "$$LOG_FILE" 2>/dev/null); \
				if echo "$$LAST_SUMMARY" | grep -q "URLs OK"; then \
					CHECKS=$$(echo "$$LAST_SUMMARY" | grep -oP "\d+/\d+" | head -1); \
					echo "État          : ✓ Tous les services OK ($$CHECKS)"; \
				elif echo "$$LAST_SUMMARY" | grep -q "URLs en erreur"; then \
					CHECKS=$$(echo "$$LAST_SUMMARY" | grep -oP "\d+/\d+" | head -1); \
					FAILED=$$(echo "$$CHECKS" | cut -d"/" -f1); \
					TOTAL=$$(echo "$$CHECKS" | cut -d"/" -f2); \
					OK=$$((TOTAL - FAILED)); \
					echo "État          : ⚠️  $$FAILED erreur(s) / $$OK OK"; \
				else \
					echo "État          : Aucune vérification récente"; \
				fi; \
			else \
				echo "État          : Aucun log disponible"; \
			fi; \
		else \
			echo "⚠️  Health check non configuré"; \
		fi'
	@echo ""
	@echo "⏰ CRON JOBS"
	@echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
	@CRON_COUNT=$$(crontab -l 2>/dev/null | grep -v "^#" | grep -v "^$$" | wc -l); \
		echo "Jobs actifs   : $$CRON_COUNT"; \
		if [ $$CRON_COUNT -gt 0 ]; then \
			echo ""; \
			crontab -l 2>/dev/null | grep -v "^#" | grep -v "^$$" | while read -r line; do \
				echo "  • $$line"; \
			done; \
		fi
	@echo ""
	@echo "╔════════════════════════════════════════════════════════════╗"
	@echo "║  💡 Commandes utiles: make help                            ║"
	@echo "╚════════════════════════════════════════════════════════════╝"