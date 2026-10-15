#!/bin/sh
set -eu
export VAULT_ADDR=http://vault:8200
KEYS=/init-out/keys.txt

gen() { head -c 48 /dev/urandom | base64 | tr -d '/+=\n' | head -c 32; }

# 1. Attendre que Vault réponde (code 2 = scellé, c'est normal)
until vault status >/dev/null 2>&1 || [ $? -eq 2 ]; do sleep 2; done

# 2. Initialiser une seule fois
if ! vault status | grep -Eq 'Initialized +true'; then
  vault operator init -key-shares=1 -key-threshold=1 > "$KEYS"
  chmod 600 "$KEYS"
fi
UNSEAL_KEY=$(awk '/Unseal Key 1:/ {print $NF}' "$KEYS")
export VAULT_TOKEN=$(awk '/Initial Root Token:/ {print $NF}' "$KEYS")

unseal() {
  if vault status | grep -Eq 'Sealed +true'; then
    vault operator unseal "$UNSEAL_KEY" >/dev/null
  fi
}
unseal

# 3. Moteurs et méthodes d'authentification
vault secrets list | grep -q '^secret/' || vault secrets enable -path=secret kv-v2
vault auth list    | grep -q '^approle/' || vault auth enable approle

# 4. Secrets (créés une seule fois, jamais écrasés)
for app in wordpress nextcloud; do
  vault kv get secret/$app/db >/dev/null 2>&1 || \
    vault kv put secret/$app/db password="$(gen)" root_password="$(gen)" >/dev/null
done
vault kv patch secret/nextcloud/db name="$NC_DB_NAME" user="$NC_DB_USER" >/dev/null

vault kv get secret/grafana/admin >/dev/null 2>&1 || \
  vault kv put secret/grafana/admin password="$(gen)" >/dev/null

# 5. Pour chaque application : policy en lecture seule, AppRole, identifiants
for app in wordpress nextcloud grafana; do
  vault policy write $app - >/dev/null <<EOF
path "secret/data/$app/*" { capabilities = ["read"] }
EOF

  vault write auth/approle/role/$app token_policies=$app token_ttl=1h token_max_ttl=24h >/dev/null

  mkdir -p /approle/$app
  vault read -field=role_id auth/approle/role/$app/role-id > /approle/$app/role_id
  [ -s /approle/$app/secret_id ] || \
    vault write -f -field=secret_id auth/approle/role/$app/secret-id > /approle/$app/secret_id
  chmod 644 /approle/$app/role_id /approle/$app/secret_id
done

# 6. Prêt : le healthcheck du conteneur regarde ce fichier
touch /tmp/ready

# 7. Redescellement automatique après un redémarrage de Vault
while true; do unseal || true; sleep 10; done
