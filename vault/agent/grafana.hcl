vault { address = "http://vault:8200" }

auto_auth {
  method "approle" {
    config = {
      role_id_file_path   = "/vault/approle/role_id"
      secret_id_file_path = "/vault/approle/secret_id"
      remove_secret_id_file_after_reading = false
    }
  }
}

template {
  contents    = "{{ with secret \"secret/data/grafana/admin\" }}{{ .Data.data.password }}{{ end }}"
  destination = "/secrets/admin_password"
  perms       = "0444"
}
