SHELL := /bin/bash

# Makefile pour la gestion des sauvegardes
# Utilise des commentaires '##' pour l'auto-documentation via la commande 'make help'.

.DEFAULT_GOAL := help
.PHONY: help setup backup-all list-services backup-service list-backups disk-usage inspect show-cron show-cron-log install-cron-backups install-cron-matomo

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
	@. .env 2>/dev/null && mkdir -p $$BACKUP_BASE_DIR || echo "Variable BACKUP_BASE_DIR non définie. Remplissez .env"
	@chmod +x backup.sh
	@echo "Initialisation terminée. N oubliez pas de remplir .env !"

# --- Opérations de Sauvegarde ---
backup-all: ## Lance manuellement une sauvegarde complète de tous les services.
	@echo "Lancement manuel des sauvegardes..."
	@./backup.sh

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
	@. .env 2>/dev/null && \
	if [ ! -d "$$BACKUP_BASE_DIR" ] || [ -z "$$(ls -A $$BACKUP_BASE_DIR)" ]; then \
		echo "Aucune sauvegarde trouvée."; \
	else \
		(echo "DATE|TAILLE|CHEMIN|NOM"; \
		cd $$BACKUP_BASE_DIR && find . -type f -name '*.sql.gz' -printf '%TY-%Tm-%Td %TH:%TM|%p|%h|%f\n' | \
		while IFS='|' read -r date path dir name; do \
			size=$$(du -h "$$path" 2>/dev/null | cut -f1); \
			echo "$$date|$$size|$$dir|$$name"; \
		done | sed 's|^\./||; s|\t./|\t|') | column -t -s '|'; \
	fi

disk-usage: ## Affiche l espace disque total utilisé par les sauvegardes.
	@echo "Espace disque utilisé par les sauvegardes..."
	@. .env 2>/dev/null && du -sh $$BACKUP_BASE_DIR || echo "Dossier de sauvegarde non trouvé."

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
	@CRON_JOB="0 2 * * * /bin/bash $(CURDIR)/backup.sh >> $(LOGS_BASE_DIR)/backups/cron.log 2>&1"; \
	if ! crontab -l 2>/dev/null | grep -Fq "backup.sh"; then \
		(crontab -l 2>/dev/null; echo "$$CRON_JOB") | crontab -; \
		echo "Cron job installé avec succès."; \
	else \
		echo "Cron job déjà existant."; \
	fi
	@make --no-print-directory show-cron

install-cron-matomo: ## Installe le cron job pour l exécution chaque heure de l'archivage matomo (ajoute si non présent).
	@CRON_JOB="5 * * * * docker exec -t matomo_app /usr/local/bin/php /var/www/html/console core:archive --url=https://matomo.kayak-polo.info/ > $(LOGS_BASE_DIR)/matomo/matomo-archive.log 2>&1"; \
	if ! crontab -l 2>/dev/null | grep -Fq "matomo"; then \
		(crontab -l 2>/dev/null; echo "$$CRON_JOB") | crontab -; \
		echo "Cron job installé avec succès."; \
	else \
		echo "Cron job déjà existant."; \
	fi
	@make --no-print-directory show-cron