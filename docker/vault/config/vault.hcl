ui            = true
api_addr      = "http://vault:8200"
storage "file" { path = "/vault/file" }
listener "tcp" {
  address     = "0.0.0.0:8200"
  tls_disable = 1          # OK en labo, à remplacer par du TLS en production
}
