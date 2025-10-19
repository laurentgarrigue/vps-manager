SHELL := /bin/bash

# Makefile pour la gestion des sauvegardes
# Utilise des commentaires '##' pour l'auto-documentation via la commande 'make help'.

.DEFAULT_GOAL := help
.PHONY: help setup backup-all list-backups disk-usage show-cron install-cron

help: ## Affiche ce message d'aide.
	@echo "Gestionnaire de Sauvegardes"
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
	@. .env 2>/dev/null && mkdir -p $$BACKUP_BASE_DIR || echo "Variable BACKUP_ B_DIR non définie. Remplissez .env"
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
	@if [ -z "$(service)" ]; then \
		echo "Erreur: Vous devez spécifier un numéro de service. Ex: make backup-service service=<numéro>"; \
		echo "Services configurés pour la sauvegarde :"; \
		. .env; \
		for service_config in "$${SERVICES_TO_BACKUP[@]}"; do \
			echo $$service_config | cut -d';' -f1; \
		done | cat -n; \
	else \
		. .env; \
		SERVICE_NAME=$$(echo $${SERVICES_TO_BACKUP[$(service)-1]} | cut -d';' -f1); \
		if [ -z "$$SERVICE_NAME" ]; then \
			echo "Erreur: Numéro de service invalide : $(service)"; \
		else \
			echo "Lancement de la sauvegarde pour le service #$(service) : $$SERVICE_NAME"; \
			./backup.sh "$$SERVICE_NAME"; \
		fi \
	fi

# --- Supervision ---
list-backups: ## Liste toutes les sauvegardes existantes, triées par date.
	@echo "Liste des fichiers de sauvegarde..."
	@. .env 2>/dev/null && find $$BACKUP_BASE_DIR -type f -name '*.sql.gz' -printf '%T@ %p\n' | sort -n | cut -d' ' -f2- || echo "Aucune sauvegarde trouvée."

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
		fi \
	fi

# --- Gestion Cron ---
show-cron: ## Affiche la ligne de cron configurée pour ce script.
	@echo "Cron jobs pour l utilisateur '$(USER)' contenant 'backup.sh':"
	@crontab -l 2>/dev/null | grep "backup.sh" || echo "-> Aucun cron job trouvé pour backup.sh."

install-cron: ## Installe le cron job pour l exécution quotidienne (ajoute si non présent).
	@CRON_JOB="0 2 * * * /bin/bash $(CURDIR)/backup.sh >> $(CURDIR)/cron.log 2>&1"
	if ! crontab -l 2>/dev/null | grep -q "backup.sh"; then \
		(crontab -l 2>/dev/null; echo "$$CRON_JOB") | crontab -; \
		echo "Cron job installé avec succès."; \
	else \
		echo "Cron job déjà existant."; \
	fi
	@make --no-print-directory show-cron
