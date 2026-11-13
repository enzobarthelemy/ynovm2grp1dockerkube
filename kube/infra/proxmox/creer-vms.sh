#!/bin/bash
# Sur l'hôte Proxmox : crée les 3 VM du cluster (image cloud Ubuntu 24.04, VLAN 199).
# Image : https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img
# Pas de mot de passe ni de clé SSH : chacun pose le sien ensuite (qm guest passwd <id> ubuntu).
set -e
IMG=/var/lib/vz/import/noble-server-cloudimg-amd64.img
for id in 110 111 112; do
  qm create $id --name k8s-0$((id - 109)) --ostype l26 --machine q35 --cpu host \
    --cores 2 --memory 4096 \
    --net0 virtio,bridge=vmbr1,tag=199 --scsihw virtio-scsi-single \
    --scsi0 local-lvm:0,import-from=$IMG,discard=on,ssd=1,iothread=1 \
    --ide2 local-lvm:cloudinit --boot order=scsi0 --agent enabled=1 \
    --ipconfig0 ip=10.1.199.$id/24,gw=10.1.199.254 \
    --nameserver 1.1.1.1 --searchdomain home.arpa \
    --cicustom vendor=local:snippets/qga.yaml
  qm resize $id scsi0 64G
  qm start $id
done
