#!/bin/bash
# Sur l'hôte Proxmox : construit le cluster de zéro, jusqu'au point où le CD prend le relais.
#   1. crée les 3 VM (creer-vms.sh) ; cloud-init les prépare pour k3s et Longhorn
#   2. installe k3s : k8s-01 crée le cluster (etcd intégré), k8s-02 et k8s-03 le rejoignent
#   3. installe un runner GitHub Actions par nœud (identité reprise de /root/k8s-runners/,
#      sinon nouvel enregistrement avec le jeton /root/.runner-token)
#   4. relance la clôture automatique (k8s-fencing)
# Le cluster est alors nu (k3s et son Traefik) : un push sur main, ou un lancement manuel
# du workflow, déploie tout le reste (MetalLB, Longhorn, Vault, supervision, applications).
# Relançable : les VM déjà créées et un k3s déjà en place sont conservés.
set -euo pipefail
umask 077
cd "$(dirname "$0")"
K3S=v1.37.2+k3s1
VMS="110 111 112"
nom() { echo "k8s-0$(($1 - 109))"; }

# Commande dans une VM par l'agent invité ; renvoie sa sortie et son code de retour.
# Avec SCRIPT=fichier, le fichier est passé en entrée standard (bash -s).
vm() { local id=$1; shift
  if [ -n "${SCRIPT:-}" ]; then
    qm guest exec "$id" --timeout "${T:-60}" --pass-stdin 1 -- "$@" < "$SCRIPT"
  else
    qm guest exec "$id" --timeout "${T:-60}" -- "$@"
  fi | python3 -c '
import sys, json
d = json.load(sys.stdin)
sys.stdout.write(d.get("out-data") or ""); sys.stderr.write(d.get("err-data") or "")
sys.exit(d.get("exitcode") or 0)'; }

# Dépose un fichier dans une VM (mode 600) sans qu'il passe par la sortie.
envoyer() { base64 -w0 < "$3" | qm guest exec "$1" --timeout 30 --pass-stdin 1 -- \
  bash -c "umask 077; base64 -d > $2" >/dev/null; }

noeuds_prets() { T=30 vm 110 k3s kubectl get nodes --no-headers 2>/dev/null | awk '$2 == "Ready"' | wc -l; }
attendre_noeuds() { local i
  for i in $(seq 1 120); do [ "$(noeuds_prets)" -ge "$1" ] && return 0; sleep 5; done
  echo "moins de $1 nœud(s) Ready après 10 min"; exit 1; }

systemctl stop k8s-fencing 2>/dev/null || true

echo "== 1. VM"
if qm status 110 >/dev/null 2>&1; then echo "VM déjà créées, on les garde"; else ./creer-vms.sh; fi
for id in $VMS; do
  for i in $(seq 1 120); do qm agent "$id" ping >/dev/null 2>&1 && break; sleep 5; done
  qm agent "$id" ping >/dev/null 2>&1 || { echo "agent invité de $(nom $id) muet après 10 min"; exit 1; }
  # cloud-init status rend 2 pour de simples avertissements : on lit l'état final
  T=900 vm "$id" bash -c 'cloud-init status --wait >/dev/null; cloud-init status | head -1' \
    | grep -q 'status: done' || { echo "cloud-init en échec sur $(nom $id)"; exit 1; }
  echo "$(nom $id) prête"
done

echo "== 2. k3s $K3S"
if [ "$(noeuds_prets)" -ge 3 ]; then echo "k3s déjà en place sur les 3 nœuds"; else
  JETON=$(mktemp); trap 'rm -f "$JETON"' EXIT
  openssl rand -hex 32 > "$JETON"                 # jeton commun du cluster
  for id in $VMS; do envoyer "$id" /root/.k3s-token "$JETON"; done
  installer_k3s() { T=600 vm "$1" bash -c "curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION=$K3S \
    K3S_TOKEN_FILE=/root/.k3s-token INSTALL_K3S_EXEC='$2' sh - >/var/log/installation-k3s.log 2>&1"; }
  installer_k3s 110 "server --cluster-init --node-ip 10.1.199.110 --write-kubeconfig-mode 600"
  attendre_noeuds 1
  for id in 111 112; do     # l'un après l'autre : etcd n'ajoute qu'un membre à la fois
    installer_k3s "$id" "server --server https://10.1.199.110:6443 --node-ip 10.1.199.$id --write-kubeconfig-mode 600"
    attendre_noeuds $((id - 109))
  done
fi
T=30 vm 110 k3s kubectl get nodes

echo "== 3. runners GitHub Actions"
pids=()
for id in $VMS; do
  n=$(nom "$id")
  if [ -f "/root/k8s-runners/$n.tgz" ]; then envoyer "$id" /root/.runner-registration.tgz "/root/k8s-runners/$n.tgz"
  elif [ -f /root/.runner-token ]; then envoyer "$id" /root/.runner-token /root/.runner-token
  else echo "$n : ni enregistrement sauvé (sauver-runners) ni jeton /root/.runner-token"; exit 1; fi
  SCRIPT=../noeuds/installer-runner.sh T=900 vm "$id" bash -s > "/tmp/runner-$n.log" 2>&1 &
  pids+=($!)
done
echec=0
for p in "${pids[@]}"; do wait "$p" || echec=1; done
for id in $VMS; do tail -1 "/tmp/runner-$(nom $id).log"; done
[ "$echec" = 0 ] || { echo "installation d'un runner en échec, voir /tmp/runner-*.log"; exit 1; }
rm -f /tmp/runner-k8s-0*.log

echo "== 4. clôture automatique"
systemctl start k8s-fencing
echo "Cluster prêt. Le CD déploie la stack au prochain push sur main (ou : gh workflow run ci-cd.yaml)."
