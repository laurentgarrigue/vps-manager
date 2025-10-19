# Makefile pour la gestion des sauvegardes
# Utilise des commentaires '##' pour l'auto-documentation via la commande 'make help'.

.DEFAULT_GOAL := help
.PHONY: help setup backup-all list-backups disk-usage show-cron install-cron

help: ## Affiche ce message d'aide.
	@echo "Gestionnaire de Sauvegardes"
	@echo "--------------------------"
	@grep -E '^[a-zA-Z_-]+:.*?##' $(MAKEFILE_LIST) | sort | awk -F '##' '{ \
        gsub(/:+ *$$/, "", $$1); \
        printf "  %-20s %s\n", $$1, $$2 \
    }'

# --- Installation ---
setup: ## Initialise l environnement (crée .env, dossiers, rend le script exécutable).
	@echo "Initialisation de l environnement..."
	@if [ ! -f .env ]; then \
		cp .env.dist .env; \
		echo "Fichier .env créé. Veuillez le modifier avec vos vrais credentials."; \
	else \
		echo "Fichier .env déjà existant."; \
	fi
	@source .env 2>/dev/null && mkdir -p $$BACKUP_BASE_DIR || echo "Variable BACKUP_ B_DIR non définie. Remplissez .env"
	@chmod +x backup.sh
	@echo "Initialisation terminée. N oubliez pas de remplir .env !"

# --- Opérations de Sauvegarde ---
backup-all: ## Lance manuellement une sauvegarde complète de tous les services.
	@echo "Lancement manuel des sauvegardes..."
	@./backup.sh

# --- Supervision ---
list-backups: ## Liste toutes les sauvegardes existantes, triées par date.
	@echo "Liste des fichiers de sauvegarde..."
	@source .env 2>/dev/null && find $$BACKUP_BASE_DIR -type f -name '*.sql.gz' -printf '%T@ %p\n' | sort -n | cut -d' ' -f2- || echo "Aucune sauvegarde trouvée."

disk-usage: ## Affiche l espace disque total utilisé par les sauvegardes.
	@echo "Espace disque utilisé par les sauvegardes..."
	@source .env 2>/dev/null && du -sh $$BACKUP_BASE_DIR || echo "Dossier de sauvegarde non trouvé."

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