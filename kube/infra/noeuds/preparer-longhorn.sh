#!/bin/bash
# Sur chaque nœud, avant d'installer Longhorn.
set -e
# disque agrandi à 64 Go côté Proxmox : on étend la partition et le système de fichiers
growpart /dev/sda 1 && resize2fs /dev/sda1
# Longhorn présente ses volumes en iSCSI
systemctl enable --now iscsid
modprobe iscsi_tcp && echo iscsi_tcp > /etc/modules-load.d/longhorn.conf
# multipathd (actif sur Ubuntu) s'empare sinon des disques iSCSI de Longhorn
cat >> /etc/multipath.conf <<'EOM'
blacklist {
    devnode "^sd[a-z0-9]+"
}
EOM
systemctl restart multipathd
# local-path reste installé mais n'est plus la classe par défaut ; ce fichier
# empêche k3s de la remettre par défaut à chaque redémarrage
touch /var/lib/rancher/k3s/server/manifests/local-storage.yaml.skip
