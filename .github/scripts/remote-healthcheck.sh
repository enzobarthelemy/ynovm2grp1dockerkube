#!/usr/bin/env bash
# Exécuté sur le serveur cible via SSH.
# 1. Attend que tous les conteneurs du projet soient 'running' et, quand ils
#    déclarent un healthcheck, 'healthy'.
# 2. Vérifie les réponses HTTP des applications à travers Traefik.
# Variables attendues : DEPLOY_PATH, HEALTH_TIMEOUT (secondes)
set -uo pipefail

: "${DEPLOY_PATH:?DEPLOY_PATH manquant}"
TIMEOUT="${HEALTH_TIMEOUT:-300}"
INTERVAL=10

cd "$DEPLOY_PATH" || exit 1

EXPECTED=$(docker compose config --services | wc -l)
elapsed=0

while :; do
  ok=0
  bad=()
  # Nom | État | Santé (vide si pas de healthcheck)
  while IFS='|' read -r name state health; do
    [ -z "$name" ] && continue
    if [ "$state" = "running" ] && { [ -z "$health" ] || [ "$health" = "healthy" ]; }; then
      ok=$((ok + 1))
    else
      bad+=("${name} (${state}${health:+/$health})")
    fi
  done < <(docker compose ps --all --format '{{.Name}}|{{.State}}|{{.Health}}')

  if [ "$ok" -eq "$EXPECTED" ] && [ "${#bad[@]}" -eq 0 ]; then
    echo "Tous les conteneurs sont opérationnels (${ok}/${EXPECTED})."
    break
  fi

  if [ "$elapsed" -ge "$TIMEOUT" ]; then
    echo "::error::Healthchecks en échec après ${TIMEOUT}s : ${ok}/${EXPECTED} conteneurs OK."
    docker compose ps --all
    for c in "${bad[@]}"; do
      cname="${c%% *}"
      echo "----- Logs ${cname} (50 dernières lignes)"
      docker logs --tail 50 "$cname" 2>&1 || true
    done
    exit 1
  fi

  echo "En attente (${elapsed}s) : ${ok}/${EXPECTED} OK - ${bad[*]:-conteneurs manquants}"
  sleep "$INTERVAL"
  elapsed=$((elapsed + INTERVAL))
done

docker compose ps --all --format 'table {{.Name}}\t{{.State}}\t{{.Health}}\t{{.Image}}'

# --- Vérifications HTTP via Traefik (en-tête Host, sans dépendre du DNS) ---
if ! command -v curl >/dev/null 2>&1; then
  echo "::warning::curl absent du serveur : vérifications HTTP ignorées."
  exit 0
fi

fail=0
check_http() {
  local host="$1" path="$2" code
  for _ in 1 2 3 4 5 6; do
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 -H "Host: ${host}" "http://127.0.0.1${path}")
    case "$code" in
      2??|3??) echo "OK   ${host}${path} -> HTTP ${code}"; return 0 ;;
    esac
    sleep 5
  done
  echo "::error::KO   ${host}${path} -> HTTP ${code}"
  fail=1
}

check_http wp.ynovm2.lab      /wp-login.php
check_http cloud.ynovm2.lab   /status.php
check_http monitor.ynovm2.lab /api/health

exit "$fail"
