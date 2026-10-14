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
  contents    = "{{ with secret \"secret/data/nextcloud/db\" }}{{ .Data.data.password }}{{ end }}"
  destination = "/secrets/db_password"
  perms       = "0444"
}
template {
  contents    = "{{ with secret \"secret/data/nextcloud/db\" }}{{ .Data.data.root_password }}{{ end }}"
  destination = "/secrets/db_root_password"
  perms       = "0444"
}
template {
  contents    = "{{ with secret \"secret/data/nextcloud/db\" }}{{ .Data.data.name }}{{ end }}"
  destination = "/secrets/db_name"
  perms       = "0444"
}
template {
  contents    = "{{ with secret \"secret/data/nextcloud/db\" }}{{ .Data.data.user }}{{ end }}"
  destination = "/secrets/db_user"
  perms       = "0444"
}
