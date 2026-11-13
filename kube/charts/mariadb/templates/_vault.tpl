{{/*
Annotations lues par le Vault Agent Injector :
- agent-inject            : ajoute un init-container vault-agent au pod
- agent-pre-populate-only : uniquement l'init-container (secrets statiques, pas de sidecar)
- role                    : rôle d'auth Kubernetes à utiliser
- auth-max-backoff        : attente max entre deux essais d'auth (défaut 5 min,
                            doublée à chaque échec : retardait le redémarrage de ~1 min)
- agent-inject-secret-X   : écrit /vault/secrets/X (volume en mémoire, ex-tmpfs)
- agent-inject-template-X : extrait une seule clé du secret KV v2
*/}}
{{- define "vault.annotations" -}}
{{- with .Values.vault }}
vault.hashicorp.com/agent-inject: "true"
vault.hashicorp.com/agent-pre-populate-only: "true"
vault.hashicorp.com/role: {{ .role | quote }}
vault.hashicorp.com/auth-max-backoff: "5s"
{{- $path := .secretPath }}
{{- range .keys }}
vault.hashicorp.com/agent-inject-secret-{{ . }}: {{ $path | quote }}
vault.hashicorp.com/agent-inject-template-{{ . }}: {{ printf "{{- with secret %q -}}{{ .Data.data.%s }}{{- end -}}" $path . | quote }}
{{- end }}
{{- end }}
{{- end }}
