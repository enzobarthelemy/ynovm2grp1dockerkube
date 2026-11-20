# Stack ynovm2 sur k3s

Ce dépôt déploie WordPress, Nextcloud, Vault et une supervision Prometheus/Grafana sur un cluster k3s de trois VM Proxmox. Un script lancé sur l'hôte crée les VM et installe k3s ([`infra/proxmox/construire-cluster.sh`](infra/proxmox/construire-cluster.sh)). Tout le reste, du réseau et du stockage jusqu'aux applications, est déployé par une seule commande (`helmfile apply`), que le CD lance à chaque push sur `main`.

Le README suit l'ordre du montage : l'infrastructure, le cluster, le stockage, les applications, puis les pannes qu'on a provoquées pour vérifier la haute disponibilité et ce qu'on a réglé après chaque essai.

## Vue d'ensemble

```
Internet
   │  https://wp|cloud|monitor.appart.cbarreda.fr:8443   (http : 8080)
   ▼
Passerelle UniFi : 8080 → 10.1.199.100:80, 8443 → 10.1.199.100:443
   │
   ▼  VLAN 199 (10.1.199.0/24), isolé du LAN
10.1.199.100  IP virtuelle annoncée par MetalLB, portée par un des trois nœuds
   │
   ▼
Traefik (3 copies, une par nœud) ── routage par nom d'hôte (Ingress)
   │
   ├── ns wordpress   : wordpress ─ wordpress-db (MariaDB)
   ├── ns nextcloud   : nextcloud ─ nextcloud-db (MariaDB)
   ├── ns monitoring  : grafana ─ prometheus (+ node-exporter, kube-state-metrics)
   └── ns vault       : vault, injecteur de secrets, unsealer

k8s-01 (.110)        k8s-02 (.111)        k8s-03 (.112)
k3s serveur + etcd   k3s serveur + etcd   k3s serveur + etcd
Longhorn : chaque volume existe en 3 copies, une sur chaque nœud
```

## 1. Infrastructure

### Hôte et VM

Tout tourne sur un seul serveur Proxmox VE (i5-12400, 31 Go de RAM, SSD NVMe de 1 To en LVM thin). Le script [`infra/proxmox/creer-vms.sh`](infra/proxmox/creer-vms.sh) crée les trois VM :

| VM | ID | IP | vCPU | RAM | Disque |
|---|---|---|---|---|---|
| k8s-01 | 110 | 10.1.199.110 | 2 | 4 Go | 64 Go |
| k8s-02 | 111 | 10.1.199.111 | 2 | 4 Go | 64 Go |
| k8s-03 | 112 | 10.1.199.112 | 2 | 4 Go | 64 Go |

Les VM partent de l'image cloud Ubuntu 24.04 (sans interface graphique), configurée par cloud-init : IP fixe (pas de DHCP sur ce VLAN), passerelle 10.1.199.254, DNS 1.1.1.1. Aucune clé SSH ni mot de passe n'est injecté ; chacun pose le sien avec `qm guest passwd <id> ubuntu`. Le snippet autorise ensuite la connexion SSH par mot de passe (`ssh ubuntu@10.1.199.110`), que l'image cloud interdit par défaut, à condition que la passerelle laisse passer le port 22 vers le VLAN 199. Le snippet [`infra/proxmox/noeud-k8s.yaml`](infra/proxmox/noeud-k8s.yaml) (vendor-data cloud-init) installe l'agent invité QEMU, prépare les nœuds pour Longhorn (section 3) et écrit la configuration de k3s.

On avait commencé avec 2 Go de RAM et 32 Go de disque. Après k3s, etcd et Traefik, il restait environ 1 Go libre par nœud, alors que la stack en demandait 2 à 2,5 Go de plus : on est passé à 4 Go. Les disques sont passés à 64 Go pour Longhorn, qui garde 3 copies de 23 Go de volumes demandés (le pool LVM est en thin provisioning, l'espace n'est consommé qu'à l'écriture).

### Réseau

Le VLAN 199 sort sur Internet par la passerelle UniFi et ne peut pas joindre le LAN : c'est voulu. Conséquence pratique, l'hôte Proxmox (sur le VLAN 99) ne joint pas non plus l'API Kubernetes. Pour administrer les nœuds, on passe par l'agent invité : `qm guest exec <id> -- <commande>` depuis l'hôte.

Les ports publics 80 et 443 servent déjà à un autre service (Pangolin). Les applications sortent donc sur 8080 et 8443, redirigés par la passerelle vers l'IP virtuelle 10.1.199.100. Un joker DNS `*.appart.cbarreda.fr` pointe vers l'IP publique, ce qui évite de toucher au fichier hosts.

Trois pièges nous ont coûté du temps :

- Sans `searchdomain`, Proxmox donne aux VM le domaine de recherche de l'hôte (`appart.cbarreda.fr`). Avec le joker DNS et le `ndots:5` des pods, `metallb.github.io` se résolvait d'abord en `metallb.github.io.appart.cbarreda.fr`, donc vers l'IP de la maison, injoignable depuis le VLAN isolé. L'installation Helm de MetalLB échouait en timeout. On a fixé `searchdomain` à `home.arpa`.
- La passerelle a deux WAN. Une redirection liée au mauvais (WAN1 au lieu d'Internet 2) ne s'applique jamais : le trafic arrive alors sur la passerelle elle-même et la règle `BLOCK_EXT-GW` le jette. On l'a vu dans Insights > Flows (zone de destination « Gateway », 0 hit sur les règles « Allow Port Forward »).
- Depuis le LAN, l'IP publique ne mène pas aux VM : l'isolation du VLAN 199 bloque aussi ce retour. Il faut tester depuis l'extérieur (4G).

## 2. Cluster k3s

Les trois nœuds sont des serveurs k3s avec etcd intégré. etcd garde le quorum à 2 sur 3 : le cluster survit à la perte d'un nœud. Aucun nœud ne porte de taint, chacun fait aussi tourner les applications.

[`infra/proxmox/construire-cluster.sh`](infra/proxmox/construire-cluster.sh), lancé sur l'hôte, fait l'installation. Il génère un jeton commun, le dépose dans `/root/.k3s-token` (mode 600) sur chaque nœud, puis lance l'installeur de k3s : d'abord sur k8s-01, qui crée le cluster, ensuite sur k8s-02 et k8s-03, l'un après l'autre (etcd n'accepte qu'un nouveau membre à la fois).

```bash
# k8s-01
curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION=v1.37.2+k3s1 K3S_TOKEN_FILE=/root/.k3s-token \
  INSTALL_K3S_EXEC="server --cluster-init --node-ip 10.1.199.110 --write-kubeconfig-mode 600" sh -

# k8s-02 et k8s-03 (node-ip .111 / .112)
curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION=v1.37.2+k3s1 K3S_TOKEN_FILE=/root/.k3s-token \
  INSTALL_K3S_EXEC="server --server https://10.1.199.110:6443 --node-ip 10.1.199.111 --write-kubeconfig-mode 600" sh -
```

La configuration de k3s (`/etc/rancher/k3s/config.yaml`, écrite par cloud-init) désactive deux composants fournis par défaut : le répartiteur `servicelb`, remplacé par MetalLB, et le stockage `local-path`, remplacé par Longhorn. Le cluster sort de là nu, avec k3s, CoreDNS et Traefik ; `helmfile apply` installe tout le reste.

### IP virtuelle : MetalLB et Traefik

k3s fournit un répartiteur (servicelb) qui publie les services sur l'IP de chaque nœud. Il fallait une adresse unique à viser depuis la passerelle, qui survive à la perte d'un nœud. On a désactivé servicelb et installé MetalLB 0.16.2 en mode L2 (release `metallb`, pool d'adresses dans [`charts/reseau`](charts/reseau/templates/metallb-pool.yaml)) : un nœud répond aux requêtes ARP pour l'IP, un autre reprend s'il tombe.

Le Traefik de k3s (3.7.15) est surchargé par un HelmChartConfig, le mécanisme prévu par k3s ([`traefik-config.yaml`](charts/reseau/templates/traefik-config.yaml), dans le même chart) : IP fixe 10.1.199.100, trois copies réparties sur les trois nœuds. Avec une seule copie, notre premier test de panne a échoué : elle tournait sur le nœud coupé. En coupant le nœud qui porte l'IP, le site revient en 5 s environ.

Pour savoir quel nœud porte l'IP : `kubectl get servicel2statuses.metallb.io -A`.

## 3. Stockage : Longhorn

Au départ, les volumes utilisaient `local-path`, le stockage par défaut de k3s : un simple dossier sur le disque d'un nœud. Si ce nœud tombe, l'application et sa base restent arrêtées jusqu'à son retour, puisque les données n'existent nulle part ailleurs.

Longhorn 1.13.0 (release `longhorn`, [`values/longhorn.yaml`](values/longhorn.yaml)) garde chaque volume en trois copies, une par nœud. Quand un nœud tombe, Kubernetes relance le pod ailleurs et Longhorn lui attache une copie restante. C'est la seule StorageClass du cluster, et celle par défaut ; les charts du projet n'indiquent pas de classe, ils n'ont donc pas changé.

La préparation des nœuds est faite par cloud-init au premier démarrage ([`noeud-k8s.yaml`](infra/proxmox/noeud-k8s.yaml)) : installation et démarrage d'`iscsid` (Longhorn présente ses volumes en iSCSI), chargement du module `iscsi_tcp`, et exclusion des disques `sd*` dans `multipath.conf`, sans quoi `multipathd` s'empare des volumes Longhorn.

Les trois VM partagent le même hôte et le même SSD. Longhorn protège donc d'une panne de VM (plantage, redémarrage, mise à jour), pas d'une panne de l'hôte, et chaque écriture part trois fois sur le même NVMe.

## 4. Applications

### De Docker Compose à Kubernetes

La stack vient d'un `docker-compose.yaml`. Les équivalences utilisées :

| Docker Compose | Kubernetes | Rôle |
|---|---|---|
| un service | Deployment (sans état) / StatefulSet (base de données) | garde N pods en vie, les recrée s'ils meurent |
| conteneur | Pod | un ou plusieurs conteneurs qui partagent réseau et volumes |
| nom de service (DNS) | Service | nom DNS et IP stables devant les pods |
| labels Traefik | Ingress | routage HTTP par nom d'hôte |
| volume nommé | PersistentVolumeClaim | demande de stockage, servie ici par Longhorn |
| réseaux `net_*` | Namespace + NetworkPolicy | isolation et filtrage réseau |
| `healthcheck` | sondes readiness / liveness / startup | pod pas prêt = pas de trafic ; pod bloqué = redémarré |
| `depends_on` | initContainer + `needs` dans helmfile | Kubernetes n'ordonne pas les démarrages, on attend explicitement |
| `.env` | values Helm | paramètres injectés dans les templates |
| AppRole + vault-agent | auth Kubernetes + Vault Agent Injector | le pod prouve son identité avec son ServiceAccount |
| cAdvisor | (supprimé) | déjà intégré au kubelet |

Helm installe un chart (des templates YAML et leurs valeurs par défaut) ; une installation s'appelle une release. Helmfile décrit plusieurs releases, leur ordre et leurs valeurs dans un seul fichier.

### Releases

[`helmfile.yaml.gotmpl`](helmfile.yaml.gotmpl) les installe dans cet ordre (`needs`) et attend que chacune soit prête avant la suivante :

| Release | Chart | Contenu |
|---|---|---|
| metallb | metallb/metallb 0.16.2 | répartiteur MetalLB (IP virtuelle) |
| reseau | `charts/reseau` | pool d'IP de MetalLB, réglages du Traefik de k3s |
| longhorn | longhorn/longhorn 1.13.0 | stockage répliqué en 3 copies |
| vault | hashicorp/vault 0.34.1 | Vault 2.0.4 (stockage fichier, un serveur), injecteur de secrets en 2 copies |
| vault-bootstrap | `charts/vault-bootstrap` | Job d'initialisation, boucle de déverrouillage (unsealer) |
| monitoring | prometheus-community/kube-prometheus-stack 93.5.0 | Prometheus, Grafana 13.3, node-exporter, kube-state-metrics |
| dashboards | `charts/dashboards` | le tableau de bord Grafana du lab |
| wordpress-db, nextcloud-db | `charts/mariadb` | MariaDB 12.3 (`mariadb:lts-ubi10`), un chart déployé deux fois |
| wordpress | `charts/webapp` | image `ghcr.io/enzobarthelemy/ynovm2dockerwp` |
| nextcloud | `charts/webapp` | `nextcloud:32.0.15-apache` |

Le même chart `mariadb` ou `webapp` sert deux fois avec des valeurs différentes : c'est le principal intérêt de Helm ici. Toutes les versions de charts sont figées dans le helmfile : une mise à jour passe par un commit, pas par le prochain déploiement.

### Secrets

Aucun mot de passe n'est écrit dans le dépôt.

1. Vault démarre non initialisé et scellé.
2. Le Job `vault-bootstrap` ([`bootstrap.sh`](charts/vault-bootstrap/files/bootstrap.sh)) initialise Vault, range la clé de déverrouillage et le root token dans le Secret `vault/vault-unseal-keys`, active le moteur KV v2 et l'auth Kubernetes. Pour chaque application, il génère les mots de passe (une seule fois), une policy en lecture seule et un rôle lié aux ServiceAccounts de l'application.
3. `vault-unsealer` redéverrouille Vault après chaque redémarrage (Vault repart toujours scellé).
4. Les pods annotés `vault.hashicorp.com/*` ([`_vault.tpl`](charts/webapp/templates/_vault.tpl)) reçoivent de l'injecteur un init-container `vault-agent-init`. Il présente le jeton du ServiceAccount à Vault, qui le vérifie auprès de l'API Kubernetes, puis il écrit chaque clé dans `/vault/secrets/<clé>` (volume en mémoire).
5. Le conteneur lit ces fichiers via les variables `*_FILE` (`MARIADB_PASSWORD_FILE`, `WORDPRESS_DB_PASSWORD_FILE`...), comme dans le compose.

### Accès

| Site | Adresse |
|---|---|
| WordPress | https://wp.appart.cbarreda.fr:8443 |
| Nextcloud | https://cloud.appart.cbarreda.fr:8443 |
| Grafana | https://monitor.appart.cbarreda.fr:8443 (compte `admin`, s'ouvre sur le tableau de bord du lab) |

Les mêmes noms répondent en HTTP sur le port 8080. Le certificat est celui que Traefik génère par défaut, le navigateur affiche donc un avertissement une fois par nom. Vault et Prometheus ne sont pas exposés (`kubectl port-forward`).

Mot de passe Grafana, depuis un nœud :

```bash
kubectl -n vault exec vault-0 -- sh -c "VAULT_TOKEN=$(kubectl -n vault get secret vault-unseal-keys -o jsonpath='{.data.root_token}' | base64 -d) vault kv get -field=admin_password secret/grafana/admin"
```

## 5. Ce qu'il a fallu corriger

Le projet s'installait sur le papier mais pas sur un cluster vierge avec les charts actuels. Corrections faites :

| Fichier | Problème | Correction |
|---|---|---|
| `charts/vault-bootstrap/files/bootstrap.sh` | Le script lisait `.keys_b64[0]` dans la réponse de `sys/init` ; l'API renvoie `keys_base64` (`unseal_keys_b64` n'existe que dans la sortie JSON de la CLI). Une clé vide a été stockée, Vault est resté scellé pour de bon et il a fallu effacer son volume. | `.keys_base64[0]`, et le Job s'arrête en erreur plutôt que de stocker une clé vide. |
| `values/monitoring.yaml` | Le chart Grafana actuel utilise une image « distroless » et refuse `GF_SECURITY_ADMIN_PASSWORD__FILE` : le rendu Helm échoue. | `GF_SECURITY_ADMIN_PASSWORD: "$__file{/vault/secrets/admin_password}"`, l'expansion de fichier propre à Grafana. |
| `helmfile.yaml.gotmpl` | `helmfile apply` lance un `helm diff` avant d'installer ; sur un cluster vierge, les types `Prometheus`, `ServiceMonitor`... n'existent pas encore et le diff échoue. | `disableValidationOnInstall: true` sur la release monitoring. |
| `charts/mariadb`, `charts/webapp`, `values/wordpress.yaml` | Un volume Longhorn neuf appartient à root. MariaDB tourne en uid 999 et l'image WordPress en `www-data` (33) : « Permission denied ». `local-path` créait des dossiers en 0777 et cachait le problème. | `podSecurityContext.fsGroup` (999 et 33) : Kubernetes donne le volume au bon groupe au montage. |
| `values/*.yaml` | Noms en `*.ynovm2.lab`, joignables seulement avec une entrée dans `/etc/hosts`. | `wp.`, `cloud.` et `monitor.appart.cbarreda.fr`, URL racine de Grafana en `https://...:8443/`. |
| `charts/vault-bootstrap/files/unseal.sh` | Au démarrage du cluster, `apk add curl jq` échouait parce que le réseau des pods n'était pas encore prêt. Le script ne le voyait pas et tournait sur « curl: not found » : Vault est resté scellé 7 min au redémarrage du 20/11. | Nouvel essai toutes les 5 s jusqu'à ce que l'installation réussisse. |
| `values/vault.yaml` | L'injecteur de Vault est en `failurePolicy: Ignore` par défaut : un pod créé pendant que l'injecteur ne répond pas démarre sans son agent, donc sans ses mots de passe, et ne s'en remet jamais seul. Le 20/11, après une éviction, WordPress répondait 500 et Grafana redémarrait en boucle. | `failurePolicy: Fail` limité aux namespaces des applications, délai de 10 s : la création est refusée et Kubernetes réessaie jusqu'au retour de l'injecteur. |
| `.github/workflows/ci-cd.yaml` | helmfile lance par défaut les 14 `helm diff` en même temps. Sur le nœud du runner (2 vCPU, 4 Go, pas de swap), la mémoire a saturé, k3s n'a plus répondu et le nœud a été déclaré en panne une minute : ses pods ont été évincés en plein déploiement. | `helmfile apply --concurrency 1`, une release à la fois. |
| `values/vault.yaml`, tableau de bord | Le pod Vault est déclaré prêt même scellé (sonde réglée ainsi pour `helm --wait`) : la tuile « Vault » du tableau de bord, calculée sur cet état, aurait affiché « Déverrouillé » sur un Vault scellé. | Télémétrie de Vault activée et lue par Prometheus ; la tuile suit `vault_core_unsealed`. |

Le dry-run `helmfile template` a trouvé l'erreur Grafana avant tout déploiement ; les deux autres sont apparues au premier `helmfile apply`.

## 6. Haute disponibilité : tests de panne

### Méthode

On coupe brutalement (`qm stop`, l'équivalent d'un débranchement) la VM qui héberge Nextcloud. Depuis un nœud survivant, une sonde interroge toutes les 5 à 15 s les trois sites à travers l'IP virtuelle et relève sur quel nœud tourne chaque pod. On relance ensuite la VM et on attend que Longhorn reconstruise les trois copies.

### Résultats

Temps entre la coupure et le retour de chaque site :

| Test | Réglages | Nœud coupé | WordPress | Nextcloud | Grafana |
|---|---|---|---|---|---|
| 1 | valeurs par défaut | k8s-01 | 615 s | 615 s | non touché |
| 2 | éviction à 30 s, correctifs Vault | k8s-02 | 458 s | 588 s | 601 s |
| 3 | + taint `out-of-service` posé à la main | k8s-03 | non touché | 85 s | 92 s |
| 4 | + taint posé par `k8s-fencing` | k8s-01 | 185 s | 172 s | non touché |

Au test 1, Prometheus a mis 1 002 s ; au test 4, 138 s. Après chaque test, Longhorn a reconstruit les copies du nœud revenu en moins de deux minutes.

Les tests 3 et 4 ne coupaient pas la même chose. Au test 3, k8s-03 ne portait que Nextcloud et Grafana : leurs bases et Vault tournaient ailleurs. Au test 4, k8s-01 portait presque tout (Vault, les deux bases, WordPress, Nextcloud, Prometheus) et toute la chaîne a dû redémarrer : clôture à 96 s, Vault prêt à 124 s, bases à 158 s, Nextcloud à 172 s, WordPress à 185 s.

### Où partait le temps

Au test 1, avec les réglages par défaut :

| Étape | Durée | Cause |
|---|---|---|
| Détection | ~75 s | le nœud passe NotReady après plusieurs battements de cœur du kubelet manqués |
| Éviction | 300 s | `tolerationSeconds: 300`, ajouté à chaque pod par le contrôleur d'admission `DefaultTolerationSeconds` |
| Détachement des volumes | jusqu'à 6 min | Kubernetes ne détache pas un volume d'un nœud injoignable avant 6 min : ce nœud est peut-être coupé du réseau mais vivant, et deux écrivains sur un même disque corrompraient les données. Longhorn attend ce détachement avant de supprimer le pod bloqué. |
| Vault scellé | ~70 s | Vault a démarré à 10:37:40 mais l'unsealer ne l'a déverrouillé qu'à 10:38:57. Son `curl` n'avait pas de délai maximal ; il était très probablement bloqué sur l'IP du pod mort. |
| Secrets | 30 à 50 s | `vault-agent-init` double son attente à chaque échec d'authentification (1, 2, 4, 8, 16, 32 s...) et ratait le moment où Vault revenait. |
| Prometheus | 600 s de plus | l'opérateur laisse 600 s d'arrêt à Prometheus, et Longhorn ne supprime un pod bloqué qu'après ce délai. |

Les valeurs par défaut de Kubernetes privilégient la sécurité des données à la vitesse. On les a resserrées une fois le stockage répliqué en place.

### Réglages appliqués

| Réglage | Fichier | Effet |
|---|---|---|
| `tolerationSeconds: 30` sur `not-ready` et `unreachable` | `charts/mariadb`, `charts/webapp`, `charts/vault-bootstrap`, `values/vault.yaml`, `values/monitoring.yaml` | éviction après 30 s au lieu de 300 s |
| `vault.hashicorp.com/auth-max-backoff: "5s"` | `_vault.tpl` (deux charts), `values/monitoring.yaml` | l'agent réessaie au plus toutes les 5 s |
| `curl -m 5`, boucle de 5 s | `charts/vault-bootstrap/files/unseal.sh` | Vault déverrouillé quelques secondes après son redémarrage |
| `injector.replicas: 2` | `values/vault.yaml` | si l'injecteur manque, Kubernetes crée les pods sans leurs secrets (`failurePolicy: Ignore`) |
| `terminationGracePeriodSeconds: 60` pour Prometheus | `values/monitoring.yaml` | 60 s au lieu de 600 s |
| `initialDelaySeconds` 15 → 5 (readiness MariaDB) | `charts/mariadb` | la base reçoit du trafic 10 s plus tôt |
| `nodeDownPodDeletionPolicy` | `values/longhorn.yaml` | Longhorn supprime de force les pods restés sur un nœud mort |
| taint `node.kubernetes.io/out-of-service` | `k8s-fencing` (section 7) | supprime l'attente de 6 min sur les volumes |

Le test 2 a montré que l'éviction à 30 s et les correctifs Vault ne suffisaient pas : une fois le volume attaché, WordPress et Nextcloud étaient prêts en 11 s (contre 2 min 30 au test 1), mais les volumes restaient bloqués 6 min sur le nœud mort. Seul le taint `out-of-service` lève ce blocage.

Tous ces réglages sont documentés : taints et tolérances et « Non-graceful node shutdown » (GA depuis Kubernetes 1.28) sur kubernetes.io, « Node Failure Handling » dans la documentation Longhorn, annotations de l'Agent Injector chez HashiCorp. Seul l'unsealer est propre au labo : en production, Vault se déverrouille seul par un KMS (auto-unseal) et ce pod n'existe pas.

## 7. Clôture automatique des nœuds (k8s-fencing)

Poser le taint `out-of-service` revient à dire à Kubernetes « ce nœud est éteint, ses volumes sont libres ». Kubernetes ne le fait jamais seul, faute de pouvoir distinguer un nœud éteint d'un nœud coupé du réseau. Il faut une clôture (fencing) : quelqu'un qui sait que la machine est arrêtée.

Ici, l'hôte Proxmox le sait. [`infra/proxmox/k8s-fencing`](infra/proxmox/k8s-fencing) tourne sur l'hôte comme service systemd ([`k8s-fencing.service`](infra/proxmox/k8s-fencing.service)) et vérifie l'état des nœuds toutes les 10 s :

- nœud NotReady depuis 10 s et `qm status` qui confirme que sa VM est arrêtée : il pose le taint ;
- nœud NotReady mais VM allumée : il ne fait rien et l'écrit dans le journal, car ce peut être une coupure réseau ;
- nœud de nouveau Ready : il retire le taint.

L'hôte ne joint pas l'API Kubernetes (VLAN isolé) ; le script passe par l'agent invité d'un nœud allumé (`qm guest exec <id> -- k3s kubectl ...`).

```bash
systemctl status k8s-fencing
journalctl -u k8s-fencing -f
```

Journal du test 4 (k8s-01 coupé à 12:12:24) :

```
12:14:00 k8s-fencing: k8s-01 NotReady depuis 14s et VM 110 arrêtée (qm status) : taint out-of-service posé
12:16:11 k8s-fencing: k8s-01 de nouveau Ready : taint out-of-service retiré
```

Sur un cloud public, ce script ne sert à rien : quand une VM disparaît, le `cloud-controller-manager` supprime l'objet Node et les volumes sont libérés aussitôt. Sur du matériel physique, le même principe existe avec Medik8s (Node Health Check et Fence Agents Remediation, utilisés par OpenShift), qui coupe l'alimentation par IPMI avant de poser le taint. Ici, Proxmox joue le rôle de l'IPMI.

Limite : une VM allumée mais figée (noyau planté) n'est pas clôturée. Il faudrait que le script l'éteigne lui-même (`qm stop`) après un délai, ce qu'on n'a pas fait.

## 8. Déployer et exploiter

### Prérequis sur un nœud

```bash
# kubeconfig pour root
mkdir -p ~/.kube && ln -sfn /etc/rancher/k3s/k3s.yaml ~/.kube/config

# Helm 3.22.1, helmfile 1.8.2, plugin helm-diff 3.15.15 (versions utilisées)
# depuis leurs pages de releases GitHub, en vérifiant les sommes SHA-256 publiées
helm version && helmfile version && helm diff version
```

### Lancer

```bash
export WP_IMAGE_TAG=latest   # ou le tag produit par la CI
helmfile diff                # ce qui va changer
helmfile apply               # installe ou met à jour tout, relançable sans risque
```

- Une seule release : `helmfile -l name=nextcloud apply`
- Nouvelle version de WordPress : `WP_IMAGE_TAG=v1.2.3 helmfile apply`
- Tout supprimer : `helmfile destroy`. Les volumes des StatefulSets et ceux marqués `keep` restent ; pour repartir de zéro, supprimer aussi les PVC et le Secret `vault/vault-unseal-keys`.
- Le StatefulSet de Vault se met à jour en `OnDelete` : après un changement de `values/vault.yaml`, supprimer le pod `vault-0` pour qu'il soit recréé.

### Arrêter et redémarrer le lab

Les VM ne démarrent pas avec l'hôte. Deux scripts, lancés sur l'hôte Proxmox, s'en chargent :

- [`k8s-arret`](infra/proxmox/k8s-arret) met en pause `k8s-fencing`, qui prendrait l'arrêt pour une panne, et note le nombre de copies de chaque charge dans `/var/lib/k8s-stack/replicas.txt`. Il réduit ensuite à zéro les applications, puis les bases, puis Vault : MariaDB et Vault s'arrêtent sur un signal propre. Il attend que Longhorn ait détaché les 7 volumes avant d'éteindre les trois VM, comme le recommande la documentation Longhorn. Rien n'est supprimé.
- [`k8s-demarrage`](infra/proxmox/k8s-demarrage) rallume les VM, attend les trois nœuds et relance `k8s-fencing`. Il remonte ensuite Vault et attend son déverrouillage, puis les bases, puis les applications, avec le nombre de copies noté.

L'arrêt du 13/11 a pris une minute. Le démarrage du 20/11 en a pris neuf, dont sept perdues par le bug de l'unsealer décrit en section 5.

### Déploiement continu

Le workflow [`ci-cd.yaml`](../.github/workflows/ci-cd.yaml) se déclenche à chaque push sur `main` qui touche `kube/` ou l'image WordPress. Le job `build` tourne chez GitHub : il construit l'image, la scanne avec Trivy et l'envoie sur ghcr.io avec le tag `sha-<commit>`. Le job `deploy` tourne sur un runner du cluster : il lance `helmfile apply` avec ce tag et attend la fin du déploiement de WordPress.

Le déploiement est idempotent : `helmfile apply` compare chaque release à ce qui tourne et ne met à jour que celles qui diffèrent. Rien n'est réinstallé, les volumes et Vault (déjà initialisé, mots de passe déjà générés) restent tels quels. En pratique, un push met à jour WordPress (nouveau tag d'image à chaque commit) et ce qui a changé dans `kube/`. Le job lance helmfile une release à la fois (`--concurrency 1`), voir la section 5.

Chaque nœud porte un runner, installé par [`infra/noeuds/installer-runner.sh`](infra/noeuds/installer-runner.sh). C'est un service `actions.runner.*` qui tourne sous l'utilisateur `github-runner`, avec sa copie du kubeconfig et le plugin helm-diff. Si un nœud tombe, GitHub confie le job à un autre runner ; `concurrency: deploy-k3s` empêche deux déploiements en même temps. Le dépôt est public, mais le workflow ne se déclenche ni sur les pull requests ni depuis un fork : seuls ceux qui peuvent pousser sur `main` exécutent du code sur le cluster.

Premier déploiement réussi le 13/11 : build en 1 min 25 s, deploy en 43 s (`sha-60d5f00`).

Chaque `helmfile apply` met aussi à jour la release `monitoring`, pour rien. Le chart Grafana va chercher le volume déjà lié à son PVC (`lookup`), ce que `helm diff` ne fait pas : il voit une différence à chaque fois. Helm réapplique la même chose et aucun pod ne redémarre.

### Reconstruire le cluster de zéro

Le CD ne peut pas créer ce dont il a besoin pour tourner : les VM, k3s et ses propres runners. Tout le reste est dans le helmfile. Sur l'hôte Proxmox :

```bash
cd /root/k8s-stack/infra/proxmox      # copie du dossier infra/
./sauver-runners                      # avant de détruire : identité GitHub des 3 runners
systemctl stop k8s-fencing
for id in 110 111 112; do qm stop $id; qm destroy $id --destroy-unreferenced-disks 1; done
./construire-cluster.sh               # VM, k3s, runners, k8s-fencing
gh workflow run ci-cd.yaml -R enzobarthelemy/ynovm2grp1dockerkube   # ou un push sur main
```

[`sauver-runners`](infra/proxmox/sauver-runners) copie les fichiers d'enregistrement de chaque runner (`.runner`, `.credentials` et sa clé privée) dans `/root/k8s-runners/`, en mode 600. [`construire-cluster.sh`](infra/proxmox/construire-cluster.sh) les remet en place : les runners reviennent sous le même nom, sans jeton à redemander à l'admin du dépôt. Les données, elles, ne survivent pas : contenus WordPress et Nextcloud, Grafana, et Vault, qui est réinitialisé avec de nouveaux mots de passe pour tout le monde.

Test du 20/11 : VM, k3s et runners prêts en 5 minutes environ (2 min 30 pour créer les VM et former le cluster, 2 min pour les runners). Le cluster est alors nu : pas de StorageClass, un seul Traefik, sans IP virtuelle. Il a fallu corriger un point en route : sans `config.sh`, le script de service `svc.sh` du runner n'existe pas, `installer-runner.sh` le crée désormais à partir du modèle fourni dans le paquet.

Puis le CD, lancé par le push du commit `992a326` : build en 1 min 54 s, deploy en 5 min 32 s. MetalLB, le pool d'IP et Longhorn sont prêts en moins d'une minute, l'initialisation de Vault prend ensuite 2 minutes, les bases, la supervision et les applications suivent. À la fin : 14 releases, 7 volumes sains en 3 copies, Vault déverrouillé, Traefik en 3 copies sur l'IP virtuelle et les trois sites en ligne depuis Internet. Il s'est écoulé 13 minutes entre la destruction des anciennes VM et les sites en ligne, dont 2 perdues sur le correctif du runner.

Le push suivant, sur le cluster plein, a échoué et révélé deux défauts. Les 14 `helm diff` lancés en parallèle ont saturé k8s-01, qui portait le runner : Kubernetes l'a déclaré en panne et a évincé ses pods. L'injecteur de Vault faisait partie des pods évincés, et WordPress et Grafana ont été recréés sans leurs secrets. Il a fallu supprimer leurs pods à la main. Les deux corrections sont dans le tableau de la section 5.

### Observer

```bash
kubectl get pods -A -o wide
kubectl -n vault logs job/vault-bootstrap                 # initialisation de Vault
kubectl -n vault logs deploy/vault-unsealer
kubectl -n wordpress logs <pod> -c vault-agent-init       # échec de récupération des secrets
kubectl -n wordpress logs <pod> -c wait-db                # attente de la base
kubectl -n longhorn-system get volumes.longhorn.io        # état des volumes (healthy / degraded)
kubectl get servicel2statuses.metallb.io -A               # nœud qui porte l'IP virtuelle
helm list -A
```

Symptômes déjà rencontrés :

- pod en `Init:0/2` longtemps : `vault-agent-init` n'arrive pas à s'authentifier (Vault scellé, rôle ou ServiceAccount différent) ;
- pod `Pending` ou `ContainerCreating` avec « Waiting for detach » : le volume est encore attaché à un nœud mort, voir la section 7 ;
- base en `CrashLoopBackOff` avec « Permission denied » sur `/var/lib/mysql` : `fsGroup` manquant ;
- 404 de Traefik : mauvais nom d'hôte ou Ingress absent (`kubectl get ingress -A`).

### Supervision

Grafana s'ouvre sur un seul tableau de bord, « Vue d'ensemble du lab k3s » ([`charts/dashboards/files/vue-ensemble.json`](charts/dashboards/files/vue-ensemble.json)). Les 24 tableaux fournis par kube-prometheus-stack sont désactivés (`grafana.defaultDashboardsEnabled: false`) : trop détaillés pour suivre le lab, et deux d'entre eux visent AIX et macOS. Il se lit de haut en bas :

| Section | Contenu |
|---|---|
| En un coup d'œil | nœuds prêts, pods en difficulté, Vault déverrouillé ou scellé, volumes dégradés, redémarrages sur 24 h, part d'erreurs 5xx |
| Applications | état de chaque application (OK, Dégradée, Arrêtée), processeur et mémoire par application |
| Trafic web | requêtes par seconde et temps de réponse (95 % des requêtes) de chaque site, vus par Traefik |
| Machines virtuelles | processeur, mémoire et disque de k8s-01 à k8s-03 |
| Stockage Longhorn | état de chaque volume (Sain, Dégradé, En panne, Détaché) et son remplissage |

C'est l'écran à garder ouvert pendant un test de panne : le compteur de nœuds passe à 2 / 3, les applications du nœud coupé passent en Arrêtée puis reviennent ailleurs, et les volumes restent en Dégradé (deux copies sur trois) jusqu'au retour du nœud.

Trois sources ont été ajoutées pour ce tableau, dans [`values/monitoring.yaml`](values/monitoring.yaml) : un PodMonitor pour Traefik (port `metrics`, 9100), un ServiceMonitor pour les managers Longhorn (port 9500) et un pour Vault (`/v1/sys/metrics`, d'où vient `vault_core_unsealed`). Vault ne publie ses métriques sans jeton que sur son port 8200, déjà réservé par sa NetworkPolicy aux namespaces autorisés, dont `monitoring`. Le chart Longhorn pose une NetworkPolicy qui n'accepte sur ce port que ses propres pods ; une seconde NetworkPolicy, déclarée dans `extraManifests`, l'ouvre à Prometheus.

Le chart [`charts/dashboards`](charts/dashboards) transforme chaque fichier JSON de `files/` en ConfigMap avec le label `grafana_dashboard: "1"`, que le sidecar de Grafana charge tout seul. Pour modifier le tableau : l'éditer dans Grafana, « Exporter > JSON », remplacer le fichier et redéployer (Grafana n'enregistre pas lui-même un tableau provisionné). Pour retrouver ceux du chart : `defaultDashboardsEnabled: true`.

## 9. Limites connues

- Un seul hôte physique et un seul SSD : Longhorn couvre la panne d'une VM, pas celle du serveur.
- Chaque application tourne en un seul exemplaire. Une panne de nœud coûte encore entre une minute et demie et trois minutes d'interruption, selon ce que le nœud portait. Pour n'en perdre aucune, il faudrait plusieurs copies de Nextcloud sur un stockage partagé (RWX ou S3) avec Redis, et une base répliquée (Galera ou un opérateur MariaDB).
- Clé de déverrouillage unique et root token gardés dans un Secret Kubernetes, unsealer maison : acceptable en labo seulement. En production : auto-unseal, cinq clés avec un seuil de trois, root token révoqué après configuration.
- Certificat autosigné. Let's Encrypt ne peut pas valider par HTTP ou TLS-ALPN, les ports 80 et 443 étant pris ; il faudrait le challenge DNS-01 (API OVH).
- Les applications ne voient pas l'IP des visiteurs : avec `externalTrafficPolicy: Cluster`, le trafic est translaté par le nœud. Nextcloud voit donc tout le monde avec une adresse en 10.42.x, et sa protection contre le brute-force traite tous les visiteurs comme un seul.
- L'image WordPress échoue au premier démarrage (`tar: .: Cannot change mode`) puis redémarre une fois et fonctionne ; à corriger dans son entrypoint.
- `k8s-fencing` ne clôture pas une VM allumée mais figée.

## Arborescence

```
helmfile.yaml.gotmpl      point d'entrée : liste et ordre des releases
values/                   paramètres de chaque release
charts/
  reseau/                 pool d'IP MetalLB, réglages de Traefik
  vault-bootstrap/        Job d'initialisation et unsealer
  dashboards/             tableau de bord Grafana du lab (JSON)
  mariadb/                MariaDB réutilisable (déployé deux fois)
  webapp/                 application web générique (déployée deux fois)
infra/
  proxmox/                construction du cluster (VM, cloud-init, k3s), arrêt, démarrage, clôture
  noeuds/                 installation d'un runner GitHub Actions
```
