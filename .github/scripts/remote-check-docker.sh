#!/usr/bin/env bash
# Exécuté sur le serveur cible via SSH.
# Vérifie que Docker Engine et le plugin Compose v2 sont installés et utilisables
# par l'utilisateur de déploiement. Installe Docker s'il est absent (sudo sans
# mot de passe requis pour cette installation).
set -euo pipefail

if ! command -v docker >/dev/null 2>&1; then
  echo "::warning::Docker est absent du serveur : installation via get.docker.com"
  if ! sudo -n true 2>/dev/null; then
    echo "::error::Docker absent et sudo sans mot de passe indisponible : installer Docker manuellement."
    exit 1
  fi
  curl -fsSL https://get.docker.com | sudo -n sh
  sudo -n systemctl enable --now docker
  sudo -n usermod -aG docker "$(id -un)"
  echo "Docker installé. L'utilisateur $(id -un) a été ajouté au groupe docker (effectif à la prochaine connexion SSH)."
  DOCKER="sudo -n docker"
else
  DOCKER="docker"
fi

echo "--- Client"
$DOCKER --version

echo "--- Moteur"
if ! $DOCKER info --format 'Docker Engine {{.ServerVersion}} | {{.OperatingSystem}} | {{.NCPU}} CPU | cgroup {{.CgroupVersion}}'; then
  echo "::error::Le démon Docker ne répond pas, ou l'utilisateur $(id -un) n'a pas accès au socket (groupe docker)."
  exit 1
fi

echo "--- Compose"
if ! $DOCKER compose version; then
  echo "::error::Le plugin Docker Compose v2 est absent (paquet docker-compose-plugin)."
  exit 1
fi

# --wait et --format sur 'docker compose ps' nécessitent Compose >= 2.17
COMPOSE_VERSION=$($DOCKER compose version --short | sed 's/^v//')
if [ "$(printf '%s\n' "2.17.0" "$COMPOSE_VERSION" | sort -V | head -n1)" != "2.17.0" ]; then
  echo "::error::Docker Compose ${COMPOSE_VERSION} trop ancien (2.17 minimum requis)."
  exit 1
fi

echo "Docker est opérationnel."
