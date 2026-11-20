#!/bin/sh
# Boucle de déverrouillage : après chaque redémarrage, Vault repart scellé.
# (En production on utiliserait l'auto-unseal via un KMS.)
# curl -m 5 : sans délai max, un appel vers l'IP d'un pod Vault mort (nœud tombé)
# reste bloqué ~2 min et retarde d'autant le déverrouillage du nouveau pod.
# Au démarrage du cluster, le DNS et le réseau des pods ne sont pas toujours prêts :
# sans nouvel essai, apk échouait et la boucle tournait sur « curl: not found »,
# Vault restant scellé (vu le 2026-11-20).
until apk add --no-cache curl jq >/dev/null 2>&1; do
  echo "$(date) apk add a échoué (réseau pas prêt ?), nouvel essai dans 5 s"
  sleep 5
done
while true; do
  if [ -s /keys/unseal_key ]; then
    if [ "$(curl -s -m 5 $VAULT_ADDR/v1/sys/seal-status | jq -r .sealed 2>/dev/null)" = "true" ]; then
      echo "$(date) Vault scellé -> unseal"
      curl -s -m 5 -X PUT -d "{\"key\":\"$(cat /keys/unseal_key)\"}" $VAULT_ADDR/v1/sys/unseal >/dev/null
    fi
  else
    echo "$(date) clé pas encore disponible (Vault pas encore initialisé)"
  fi
  sleep 5
done
