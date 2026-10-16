#!/usr/bin/env bash
# Exécuté sur le serveur cible via SSH.
# Variables attendues : DEPLOY_PATH, IMAGE_TAG
# Variables utilisées seulement au premier déploiement (création du .env) :
#   MARIADB_USER, MARIADB_DATABASE, WORDPRESS_DB_NAME, WORDPRESS_DB_USER
set -euo pipefail

: "${DEPLOY_PATH:?DEPLOY_PATH manquant}"
: "${IMAGE_TAG:?IMAGE_TAG manquant}"

cd "$DEPLOY_PATH"

# 1. Fichier .env : créé une seule fois, jamais écrasé ensuite.
#    (changer les noms de base après l'installation désynchroniserait Vault
#    et les bases existantes)
if [ ! -f .env ]; then
  echo "Premier déploiement : création du .env"
  for v in MARIADB_USER MARIADB_DATABASE WORDPRESS_DB_NAME WORDPRESS_DB_USER; do
    if [ -z "${!v:-}" ]; then
      echo "::error::Variable GitHub '$v' non définie : nécessaire pour créer le .env au premier déploiement."
      exit 1
    fi
  done
  (
    umask 077
    cat > .env <<EOF
MARIADB_USER=${MARIADB_USER}
MARIADB_DATABASE=${MARIADB_DATABASE}
WORDPRESS_DB_NAME=${WORDPRESS_DB_NAME}
WORDPRESS_DB_USER=${WORDPRESS_DB_USER}
EOF
  )
fi

# 2. Version de l'image WordPress à déployer (persistée dans le .env pour
#    qu'un 'docker compose up' manuel conserve la même version).
if grep -q '^WP_IMAGE_TAG=' .env; then
  sed -i "s/^WP_IMAGE_TAG=.*/WP_IMAGE_TAG=${IMAGE_TAG}/" .env
else
  echo "WP_IMAGE_TAG=${IMAGE_TAG}" >> .env
fi
echo "Image WordPress déployée : $(grep '^WP_IMAGE_TAG=' .env)"

# 3. Dossiers générés par vault-init (ignorés par Git, donc absents de l'archive)
#mkdir -p vault/init-out vault/approle

# 4. Validation de la configuration
docker compose config --quiet

# 5. Récupération des images
docker compose pull --quiet

# 6. vault-init tourne en continu : on le recrée pour rejouer init.sh
#    (idempotent) et prendre en compte une éventuelle nouvelle version du script.
if [ -n "$(docker compose ps --quiet vault-init 2>/dev/null)" ]; then
  echo "Relance de vault-init"
  docker compose up -d --no-deps --force-recreate vault-init
fi

# 7. Démarrage / mise à jour de la stack
docker compose up -d --remove-orphans

# 8. Nettoyage des anciennes images non utilisées
docker image prune -f >/dev/null

docker compose ps
