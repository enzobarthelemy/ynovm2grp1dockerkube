#!/bin/bash
# Sur chaque nœud, en root : installe un runner GitHub Actions auto-hébergé pour le CD
# (job « deploy » de .github/workflows/ci-cd.yaml : helmfile apply dans kube/).
# Un runner par nœud : si l'un tombe, GitHub confie le job à un autre ; le workflow
# n'autorise qu'un déploiement à la fois (concurrency: deploy-k3s).
# Prérequis : jeton d'enregistrement du dépôt (valable 1 h, généré par un admin du dépôt)
# dans /root/.runner-token ; le fichier est supprimé à la fin.
set -euo pipefail
REPO=https://github.com/enzobarthelemy/ynovm2grp1dockerkube
RUNNER=2.338.2
RUNNER_SHA=baebf204307bac6193480852732f0aba2ae97b6c5597c244f4d5558390147c40
HELM=v3.22.1 HELMFILE=1.8.2 HELMDIFF=3.15.15
U=github-runner
D=/opt/actions-runner
W=$(mktemp -d)
trap 'rm -rf "$W" /root/.runner-token' EXIT
cd "$W"

# 1. helm et helmfile s'ils manquent (sommes SHA-256 vérifiées)
if ! command -v helm >/dev/null; then
  curl -fsSLO "https://get.helm.sh/helm-$HELM-linux-amd64.tar.gz"
  curl -fsSLO "https://get.helm.sh/helm-$HELM-linux-amd64.tar.gz.sha256sum"
  sha256sum -c --quiet "helm-$HELM-linux-amd64.tar.gz.sha256sum"
  tar xzf "helm-$HELM-linux-amd64.tar.gz" linux-amd64/helm
  install -m 755 linux-amd64/helm /usr/local/bin/helm
fi
if ! command -v helmfile >/dev/null; then
  B="https://github.com/helmfile/helmfile/releases/download/v$HELMFILE"
  curl -fsSLO "$B/helmfile_${HELMFILE}_linux_amd64.tar.gz"
  curl -fsSLO "$B/helmfile_${HELMFILE}_checksums.txt"
  grep " helmfile_${HELMFILE}_linux_amd64.tar.gz\$" "helmfile_${HELMFILE}_checksums.txt" | sha256sum -c --quiet
  tar xzf "helmfile_${HELMFILE}_linux_amd64.tar.gz" helmfile
  install -m 755 helmfile /usr/local/bin/helmfile
fi

# 2. utilisateur dédié avec sa copie du kubeconfig (k3s.yaml n'est lisible que par root).
#    Le certificat client de k3s vaut un an : recopier le fichier s'il est renouvelé.
id "$U" >/dev/null 2>&1 || useradd -m -s /bin/bash "$U"
install -d -o "$U" -g "$U" -m 700 "/home/$U/.kube"
install -o "$U" -g "$U" -m 600 /etc/rancher/k3s/k3s.yaml "/home/$U/.kube/config"

# 3. plugin helm-diff pour cet utilisateur (helmfile apply en a besoin)
B="https://github.com/databus23/helm-diff/releases/download/v$HELMDIFF"
curl -fsSLO "$B/helm-diff-linux-amd64.tgz"
curl -fsSLO "$B/helm-diff_${HELMDIFF}_checksums.txt"
grep " helm-diff-linux-amd64.tgz\$" "helm-diff_${HELMDIFF}_checksums.txt" | sha256sum -c --quiet
P=$(sudo -u "$U" -H helm env HELM_PLUGINS)
mkdir -p "$P" && rm -rf "$P/diff" && tar xzf helm-diff-linux-amd64.tgz -C "$P"
chown -R "$U:$U" "/home/$U"

# 4. le runner, enregistré avec l'étiquette k3s en plus de self-hosted, linux, x64
mkdir -p "$D" && cd "$D"
curl -fsSLo runner.tar.gz "https://github.com/actions/runner/releases/download/v$RUNNER/actions-runner-linux-x64-$RUNNER.tar.gz"
echo "$RUNNER_SHA  runner.tar.gz" | sha256sum -c --quiet
tar xzf runner.tar.gz && rm runner.tar.gz
./bin/installdependencies.sh >/dev/null 2>&1
chown -R "$U:$U" "$D"
sudo -u "$U" -H ./config.sh --unattended --url "$REPO" --token "$(cat /root/.runner-token)" \
  --name "$(hostname)" --labels k3s --work _work --replace >/dev/null
echo "KUBECONFIG=/home/$U/.kube/config" >> .env   # lu par le service au démarrage
./svc.sh install "$U" >/dev/null
./svc.sh start >/dev/null
echo "$(hostname): runner $RUNNER $(systemctl is-active "actions.runner.*$(hostname).service")," \
     "helm $(helm version --short), helmfile $(helmfile version -o short 2>/dev/null)," \
     "kubectl en $U : $(sudo -u "$U" -H env KUBECONFIG=/home/$U/.kube/config kubectl get nodes --no-headers | wc -l) nœuds"
