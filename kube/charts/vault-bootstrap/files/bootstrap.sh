#!/bin/sh
# Initialise et configure Vault via son API HTTP. Idempotent : relançable sans risque.
set -eu
apk add --no-cache curl jq >/dev/null

V="$VAULT_ADDR"
K8S="https://kubernetes.default.svc"
SA=/var/run/secrets/kubernetes.io/serviceaccount
KTOKEN=$(cat $SA/token)
NS=$(cat $SA/namespace)

# Appel à l'API Kubernetes avec le token du ServiceAccount du Job
k8s() { curl -sS --cacert $SA/ca.crt -H "Authorization: Bearer $KTOKEN" \
             -H "Content-Type: application/json" "$@"; }
# Appel à l'API Vault avec le root token (échoue sur une erreur HTTP)
vault_api() { m=$1; p=$2; shift 2
  curl -sS -f -X "$m" -H "X-Vault-Token: $ROOT_TOKEN" "$V/v1/$p" "$@"; }

echo "==> Attente de Vault ($V)"
until curl -s -o /dev/null "$V/v1/sys/health"; do sleep 3; done

# --- 1. Initialisation (une seule fois dans la vie de Vault) -------------------
if [ "$(curl -s $V/v1/sys/init | jq -r .initialized)" = "false" ]; then
  echo "==> Initialisation (1 clé, seuil 1 : configuration de labo)"
  INIT=$(curl -sS -X PUT -d '{"secret_shares":1,"secret_threshold":1}' "$V/v1/sys/init")
  # L'API renvoie la clé dans "keys_base64" ("unseal_keys_b64" n'existe que dans
  # la sortie JSON de la CLI). On refuse de stocker une clé vide : elle serait perdue.
  BODY=$(echo "$INIT" | jq -e --arg n "$KEYS_SECRET" '{
    apiVersion:"v1", kind:"Secret", type:"Opaque", metadata:{name:$n},
    stringData:{unseal_key:.keys_base64[0], root_token:.root_token}}
    | select(.stringData.unseal_key != null and .stringData.root_token != null)') \
    || { echo "ERREUR: réponse d'init sans clé d'unseal ni root token"; exit 1; }
  CODE=$(k8s -X POST "$K8S/api/v1/namespaces/$NS/secrets" -d "$BODY" -o /dev/null -w '%{http_code}')
  [ "$CODE" = "201" ] || { echo "ERREUR: impossible de stocker les clés ($CODE)"; exit 1; }
  echo "    Clé d'unseal + root token stockés dans le Secret $NS/$KEYS_SECRET"
fi

SECRET=$(k8s "$K8S/api/v1/namespaces/$NS/secrets/$KEYS_SECRET")
UNSEAL_KEY=$(echo "$SECRET" | jq -r .data.unseal_key | base64 -d)
ROOT_TOKEN=$(echo "$SECRET" | jq -r .data.root_token | base64 -d)

# --- 2. Déverrouillage -----------------------------------------------------------
if [ "$(curl -s $V/v1/sys/seal-status | jq -r .sealed)" = "true" ]; then
  echo "==> Unseal"
  curl -sS -f -X PUT -d "{\"key\":\"$UNSEAL_KEY\"}" "$V/v1/sys/unseal" >/dev/null
fi

# --- 3. Moteur de secrets KV v2 monté sur secret/ -------------------------------
if ! vault_api GET sys/mounts | jq -e '.data["secret/"] // .["secret/"]' >/dev/null; then
  echo "==> Activation du moteur KV v2 sur secret/"
  vault_api POST sys/mounts/secret -d '{"type":"kv","options":{"version":"2"}}'
  sleep 5
fi

# --- 4. Auth Kubernetes : les pods s'authentifient avec leur ServiceAccount -----
if ! vault_api GET sys/auth | jq -e '.data["kubernetes/"] // .["kubernetes/"]' >/dev/null; then
  echo "==> Activation de l'auth Kubernetes"
  vault_api POST sys/auth/kubernetes -d '{"type":"kubernetes"}'
fi
vault_api POST auth/kubernetes/config -d '{"kubernetes_host":"https://kubernetes.default.svc:443"}'

# --- 5. Pour chaque application : policy + rôle + secret ------------------------
jq -c '.[]' /config/apps.json | while read -r app; do
  name=$(echo "$app" | jq -r .name)
  path=$(echo "$app" | jq -r .secretPath)
  echo "==> $name (secret/$path)"

  POLICY="path \"secret/data/$path\" { capabilities = [\"read\"] }"
  vault_api PUT "sys/policies/acl/$name" -d "$(jq -n --arg p "$POLICY" '{policy:$p}')"

  ROLE=$(echo "$app" | jq --arg n "$name" '{
    bound_service_account_names: .serviceAccounts,
    bound_service_account_namespaces: [.namespace],
    token_policies: [$n], token_ttl: "1h"}')
  vault_api POST "auth/kubernetes/role/$name" -d "$ROLE"

  # Secret : existant + valeurs statiques + mots de passe manquants
  EXISTING=$(curl -s -H "X-Vault-Token: $ROOT_TOKEN" "$V/v1/secret/data/$path" | jq '.data.data // {}')
  DATA=$(echo "$app" | jq --argjson ex "$EXISTING" '$ex + (.static // {})')
  for key in $(echo "$app" | jq -r '.generated[]?'); do
    if [ -z "$(echo "$DATA" | jq -r --arg k "$key" '.[$k] // empty')" ]; then
      pw=$(head -c 64 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 32)
      DATA=$(echo "$DATA" | jq --arg k "$key" --arg v "$pw" '.[$k]=$v')
      echo "    $key généré"
    fi
  done
  for i in 1 2 3 4 5 6 7 8 9 10; do
    vault_api POST "secret/data/$path" -d "$(jq -n --argjson d "$DATA" '{data:$d}')" >/dev/null && break
    echo "    KV pas encore prêt, nouvel essai..."; sleep 3
  done
done

echo "==> Vault prêt"
