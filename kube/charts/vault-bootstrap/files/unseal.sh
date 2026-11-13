#!/bin/sh
# Boucle de déverrouillage : après chaque redémarrage, Vault repart scellé.
# (En production on utiliserait l'auto-unseal via un KMS.)
# curl -m 5 : sans délai max, un appel vers l'IP d'un pod Vault mort (nœud tombé)
# reste bloqué ~2 min et retarde d'autant le déverrouillage du nouveau pod.
apk add --no-cache curl jq >/dev/null
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
