#!/bin/bash
# Sur l'hôte Proxmox : crée et démarre les 3 VM du cluster (image cloud Ubuntu 24.04, VLAN 199).
# Pas de mot de passe ni de clé SSH : chacun pose le sien ensuite (qm guest passwd <id> ubuntu).
set -euo pipefail
cd "$(dirname "$0")"
IMG=/var/lib/vz/import/noble-server-cloudimg-amd64.img
URL=https://cloud-images.ubuntu.com/noble/current

# image cloud, téléchargée une fois et vérifiée (somme SHA-256 publiée par Ubuntu)
if [ ! -f "$IMG" ]; then
  mkdir -p "$(dirname "$IMG")"
  curl -fsSLo "$IMG.part" "$URL/noble-server-cloudimg-amd64.img"
  curl -fsSLo /tmp/SHA256SUMS.noble "$URL/SHA256SUMS"
  echo "$(awk '/ \*?noble-server-cloudimg-amd64.img$/ {print $1}' /tmp/SHA256SUMS.noble)  $IMG.part" | sha256sum -c --quiet
  mv "$IMG.part" "$IMG"
fi
install -m 644 noeud-k8s.yaml /var/lib/vz/snippets/noeud-k8s.yaml

for id in 110 111 112; do
  qm create $id --name k8s-0$((id - 109)) --ostype l26 --machine q35 --cpu host \
    --cores 2 --memory 4096 \
    --net0 virtio,bridge=vmbr1,tag=199 --scsihw virtio-scsi-single \
    --scsi0 local-lvm:0,import-from=$IMG,discard=on,ssd=1,iothread=1 \
    --ide2 local-lvm:cloudinit --boot order=scsi0 --agent enabled=1 \
    --ipconfig0 ip=10.1.199.$id/24,gw=10.1.199.254 \
    --nameserver 1.1.1.1 --searchdomain home.arpa \
    --cicustom vendor=local:snippets/noeud-k8s.yaml
  qm resize $id scsi0 64G
  qm start $id
done
