# Documentation technique — stack `ynovm2grp1dockerkube`

## 1. Présentation

Le projet fournit une infrastructure web locale décrite dans un seul fichier `docker-compose.yaml`, qui regroupe la partie applicative, la gestion des secrets et la supervision. Le nom de projet Compose est fixé dans le fichier :

```yaml
name: ynovm2grp1dockerkube
```

Il sert de préfixe aux volumes et de filtre au dashboard Grafana, quel que soit le nom du dossier dans lequel le dépôt est cloné.

Partie applicative :

- Traefik comme reverse proxy HTTP.
- Nextcloud comme plateforme de stockage et de collaboration.
- WordPress comme site web CMS (image personnalisée).
- Deux bases MariaDB séparées, une par application.
- HashiCorp Vault pour la génération et la distribution de tous les mots de passe (bases de données et admin Grafana).
- Trois Vault Agents (WordPress, Nextcloud, Grafana) qui écrivent les secrets dans des volumes en mémoire (tmpfs).
- Quatre réseaux Docker dédiés : exposition web, bases de données, Vault, supervision.
- Des volumes Docker nommés pour conserver les données lors du remplacement des conteneurs.

Partie supervision :

- cAdvisor pour la collecte des métriques des conteneurs.
- Prometheus pour le stockage des métriques.
- Grafana, publié par Traefik sur `monitor.ynovm2.lab`, avec une source de données et un tableau de bord provisionnés automatiquement.

Arborescence utile :

```text
docker-compose.yaml                 stack complète (applications, Vault, supervision)
prometheus.yml                      configuration Prometheus
grafana/provisioning/               datasource + dashboard Grafana
vault/config/vault.hcl              configuration du serveur Vault
vault/init.sh                       initialisation / descellement de Vault
vault/agent/nextcloud.hcl           configuration Vault Agent Nextcloud
vault/agent/wordpress.hcl           configuration Vault Agent WordPress
vault/agent/grafana.hcl             configuration Vault Agent Grafana
customwp/                           sources de l’image WordPress personnalisée
SCAN.md                             résultats des scans Trivy
.env.example                        modèle de fichier .env
.gitattributes                      fins de ligne LF forcées
```

## 2. Schéma général

```text
                                Navigateur
                                    |
                                    | :80
                                 Traefik
                              reverse proxy
                              réseau net_ext
                           /                  \
          Host: cloud.ynovm2.lab          Host: wp.ynovm2.lab
                  |                                |
                  v                                v
            nextcloud:80                    wordpress:8080
                  |                                |
                  v            réseau net_db       v
            mariadb:3306                   wordpress-db:3306
         (nextcloud-db)
                  ^                                ^
                  | /run/vault (ro)                | /run/vault (ro)
           volume nc_secrets (tmpfs)        volume wp_secrets (tmpfs)
                  ^                                ^
                  |                                |
           vault-agent-nc                   vault-agent-wp
                   \                              /
                    \        réseau net_vault    /
                     +------> vault:8200 <------+
                                  ^
                                  |
                              vault-init


   Supervision (réseau monitoring) :

   cAdvisor --> Prometheus :9091 --> Grafana:3000 <-- Traefik (Host: monitor.ynovm2.lab, net_ext)
                                         ^
                                         | /run/vault (ro)
                              volume grafana_secrets (tmpfs)
                                         ^
                                vault-agent-grafana --> vault (net_vault)
```

Traefik est le seul point d’entrée HTTP vers les applications et Grafana (port `80` de l’hôte). Les applications web, Grafana et les bases ne publient aucun port vers l’hôte.

## 3. Services applicatifs et secrets

### 3.1 Traefik

| Élément | Valeur |
|---|---|
| Service | `traefik` |
| Conteneur | `traefik` |
| Image | `traefik:v3.6.2` |
| Réseau | `net_ext` |
| Ports hôte | `80` (HTTP), `8088` → `8080` (API / dashboard) |
| Provider | Docker |
| Redémarrage | `unless-stopped` |

Traefik observe les conteneurs Docker grâce au socket monté en lecture seule :

```text
/var/run/docker.sock:/var/run/docker.sock:ro
```

Options principales :

```yaml
--providers.docker=true
--providers.docker.exposedbydefault=false
--entrypoints.web.address=:80
--api.dashboard=true
--api.insecure=true
```

`exposedbydefault=false` signifie qu’un service n’est pas publié par Traefik sans le label explicite :

```yaml
traefik.enable=true
```

`--api.insecure=true` sert l’API et le dashboard sur le port interne `8080` (publié sur `8088`), sans authentification. Réservé au labo : voir la section 14.

### 3.2 Nextcloud

| Élément | Valeur |
|---|---|
| Service | `nextcloud` |
| Conteneur | `nextcloud` |
| Image | `nextcloud:32.0.15-apache` |
| Port interne | `80` |
| Domaine | `cloud.ynovm2.lab` |
| Réseaux | `net_ext`, `net_db` |
| Base de données | `mariadb` |
| Secrets | volume `nc_secrets` monté sur `/run/vault` (lecture seule) |
| Redémarrage | `always` |

Toutes les informations de connexion à la base sont lues depuis des fichiers fournis par Vault Agent :

```yaml
MYSQL_HOST: mariadb
MYSQL_DATABASE_FILE: /run/vault/db_name
MYSQL_USER_FILE: /run/vault/db_user
MYSQL_PASSWORD_FILE: /run/vault/db_password
```

Labels Traefik :

```yaml
traefik.enable=true
traefik.docker.network=net_ext
traefik.http.routers.nextcloud.rule=Host(`cloud.ynovm2.lab`)
traefik.http.routers.nextcloud.entrypoints=web
traefik.http.services.nextcloud.loadbalancer.server.port=80
```

Nextcloud doit autoriser le domaine public dans `trusted_domains` :

```powershell
docker compose exec -u www-data nextcloud php occ config:system:set trusted_domains 1 --value=cloud.ynovm2.lab
```

Ce réglage est enregistré dans le volume Nextcloud et non dans `docker-compose.yaml`.

### 3.3 Base MariaDB de Nextcloud

| Élément | Valeur |
|---|---|
| Service | `mariadb` |
| Conteneur | `nextcloud-db` |
| Image | `mariadb:lts-ubi10` |
| Réseau | `net_db` |
| Port interne | `3306` |
| Base | secret Vault `secret/nextcloud/db` → `name` |
| Utilisateur | secret Vault `secret/nextcloud/db` → `user` |
| Mots de passe | secret Vault `secret/nextcloud/db` → `password`, `root_password` |
| Volumes | `nextcloud_db_data`, `nc_secrets` (lecture seule) |
| Dépendance | `vault-agent-nextcloud` sain |
| Redémarrage | `always` |

Variables utilisées :

```yaml
MARIADB_ROOT_PASSWORD_FILE: /run/vault/db_root_password
MARIADB_USER_FILE: /run/vault/db_user
MARIADB_PASSWORD_FILE: /run/vault/db_password
MARIADB_DATABASE_FILE: /run/vault/db_name
```

Le nom de base et l’utilisateur proviennent des variables `MARIADB_DATABASE` et `MARIADB_USER` du `.env`, injectées dans Vault par `vault-init`. Les mots de passe sont générés aléatoirement par Vault.

Healthcheck :

```text
healthcheck.sh --connect --innodb_initialized
```

Nextcloud attend l’état sain de ce service avant son démarrage.

### 3.4 WordPress

| Élément | Valeur |
|---|---|
| Service | `wordpress` |
| Conteneur | `wordpress` |
| Image | `ebynov/ynovm2dockerwp:1.2.1` |
| Port interne | `8080` |
| Domaine | `wp.ynovm2.lab` |
| Réseaux | `net_ext`, `net_db` |
| Base de données | `wordpress-db` |
| Secrets | volume `wp_secrets` monté sur `/run/vault` (lecture seule) |
| Redémarrage | `unless-stopped` |

Variables utilisées :

```yaml
WORDPRESS_DB_HOST: wordpress-db:3306
WORDPRESS_DB_USER: ${WORDPRESS_DB_USER}
WORDPRESS_DB_PASSWORD_FILE: /run/vault/db_password
WORDPRESS_DB_NAME: ${WORDPRESS_DB_NAME}
```

Labels Traefik :

```yaml
traefik.enable=true
traefik.docker.network=net_ext
traefik.http.routers.wordpress.rule=Host(`wp.ynovm2.lab`)
traefik.http.routers.wordpress.entrypoints=web
traefik.http.services.wordpress.loadbalancer.server.port=8080
```

Le port interne `8080` vient de l’image WordPress personnalisée, qui configure Apache pour écouter sur ce port.

Les URLs WordPress doivent correspondre au domaine public :

```powershell
docker compose exec wordpress wp option update home "http://wp.ynovm2.lab"
docker compose exec wordpress wp option update siteurl "http://wp.ynovm2.lab"
```

Ces valeurs sont stockées dans la base WordPress.

### 3.5 Base MariaDB de WordPress

| Élément | Valeur |
|---|---|
| Service | `wordpress-db` |
| Conteneur | `wordpress-db` |
| Image | `mariadb:lts-ubi10` |
| Réseau | `net_db` |
| Port interne | `3306` |
| Base | valeur `WORDPRESS_DB_NAME` du `.env` |
| Utilisateur | valeur `WORDPRESS_DB_USER` du `.env` |
| Mots de passe | secret Vault `secret/wordpress/db` → `password`, `root_password` |
| Volumes | `wordpress_db_data`, `wp_secrets` (lecture seule) |
| Dépendance | `vault-agent-wordpress` sain |
| Redémarrage | `unless-stopped` |

Variables utilisées :

```yaml
MARIADB_DATABASE: ${WORDPRESS_DB_NAME}
MARIADB_USER: ${WORDPRESS_DB_USER}
MARIADB_PASSWORD_FILE: /run/vault/db_password
MARIADB_ROOT_PASSWORD_FILE: /run/vault/db_root_password
```

WordPress contacte la base avec le nom DNS Docker `wordpress-db:3306`. La base n’est pas accessible depuis l’hôte.

### 3.6 Vault

| Élément | Valeur |
|---|---|
| Service | `vault` |
| Conteneur | `vault` |
| Image | `hashicorp/vault:1.13.3` |
| Commande | `server` |
| Réseau | `net_vault` |
| Port hôte | `127.0.0.1:8200` (local uniquement) |
| Stockage | backend `file`, volume `vault_data` |
| Capacité | `IPC_LOCK` |
| Redémarrage | `unless-stopped` |

Configuration (`vault/config/vault.hcl`) :

```hcl
ui            = true
api_addr      = "http://vault:8200"
storage "file" { path = "/vault/file" }
listener "tcp" {
  address     = "0.0.0.0:8200"
  tls_disable = 1
}
```

L’interface web est accessible sur `http://127.0.0.1:8200` avec le root token (voir 3.7).

### 3.7 Vault Init

| Élément | Valeur |
|---|---|
| Service | `vault-init` |
| Conteneur | `vault-init` |
| Image | `hashicorp/vault:1.13.3` |
| Script | `vault/init.sh` |
| Réseau | `net_vault` |
| Bind mounts | `./vault/init-out`, `./vault/approle` |
| Healthcheck | présence de `/tmp/ready` |
| Redémarrage | `unless-stopped` |

Le script est idempotent et réalise, dans l’ordre :

1. Attente de la disponibilité de Vault.
2. Initialisation (une seule fois) avec une clé de descellement unique (`-key-shares=1 -key-threshold=1`). La clé et le root token sont écrits dans `vault/init-out/keys.txt` (droits `600`).
3. Descellement de Vault.
4. Activation du moteur `kv-v2` sur `secret/` et de la méthode d’authentification `approle`.
5. Création des secrets, uniquement s’ils sont absents (jamais écrasés) :
   - `secret/wordpress/db` et `secret/nextcloud/db` avec `password` et `root_password` aléatoires (32 caractères) ;
   - ajout de `name` et `user` dans `secret/nextcloud/db` à partir de `MARIADB_DATABASE` et `MARIADB_USER` ;
   - `secret/grafana/admin` avec un `password` aléatoire (32 caractères).
6. Pour chaque application (`wordpress`, `nextcloud`, `grafana`) :
   - création d’une policy `<app>` en lecture seule sur `secret/data/<app>/*` ;
   - création d’un rôle AppRole `<app>` (TTL du token : 1 h, maximum 24 h) ;
   - écriture de `role_id` et `secret_id` dans `vault/approle/<app>/`.
7. Création de `/tmp/ready` (débloque les agents).
8. Boucle de redescellement automatique toutes les 10 secondes.

Le conteneur reste donc actif en permanence pour redesceller Vault après un redémarrage.

### 3.8 Vault Agents

| Élément | WordPress | Nextcloud | Grafana |
|---|---|---|---|
| Service | `vault-agent-wordpress` | `vault-agent-nextcloud` | `vault-agent-grafana` |
| Conteneur | `vault-agent-wp` | `vault-agent-nc` | `vault-agent-grafana` |
| Image | `hashicorp/vault:1.13.3` | `hashicorp/vault:1.13.3` | `hashicorp/vault:1.13.3` |
| Config | `vault/agent/wordpress.hcl` | `vault/agent/nextcloud.hcl` | `vault/agent/grafana.hcl` |
| Identifiants AppRole | `vault/approle/wordpress` | `vault/approle/nextcloud` | `vault/approle/grafana` |
| Volume de sortie | `wp_secrets` → `/secrets` | `nc_secrets` → `/secrets` | `grafana_secrets` → `/secrets` |
| Fichiers produits | `db_password`, `db_root_password` | `db_password`, `db_root_password`, `db_name`, `db_user` | `admin_password` |
| Healthcheck | `db_password` non vide | `db_password`, `db_name`, `db_user` non vides | `admin_password` non vide |
| Réseau | `net_vault` | `net_vault` | `net_vault` |

Chaque agent s’authentifie par AppRole, lit uniquement le secret de son application (policy dédiée) et le rend sous forme de fichiers via des blocs `template`. Les volumes `wp_secrets`, `nc_secrets` et `grafana_secrets` sont de type `tmpfs` : les secrets ne sont jamais écrits sur disque et disparaissent à l’arrêt.

### 3.9 Chaîne de démarrage

```text
vault
  -> vault-init              (healthy : /tmp/ready)
     -> vault-agent-wordpress (healthy : secrets écrits)
        -> wordpress-db       (healthy)
           -> wordpress
     -> vault-agent-nextcloud (healthy : secrets écrits)
        -> mariadb            (healthy)
           -> nextcloud
     -> vault-agent-grafana   (healthy : secret écrit)
        -> grafana            (+ prometheus démarré, lui-même après cadvisor)
traefik                       (indépendant)
```

Le premier démarrage peut prendre quelques dizaines de secondes, le temps que Vault soit initialisé et que les agents produisent les fichiers.

## 4. Supervision

### 4.1 cAdvisor

| Élément | Valeur |
|---|---|
| Service | `cadvisor` |
| Conteneur | `cadvisor` |
| Image | `ghcr.io/google/cadvisor:v0.60.6` |
| Mode | `privileged`, `cgroup: host` |
| Réseau | `monitoring` |
| Port hôte | aucun |
| Redémarrage | `unless-stopped` |

Options principales :

```yaml
--docker_only=true
--housekeeping_interval=10s
--store_container_labels=false
--whitelisted_container_labels=com.docker.compose.project,com.docker.compose.service
```

Seuls les labels Compose `project` et `service` sont exportés, ce qui permet au dashboard de filtrer les conteneurs du projet.

### 4.2 Prometheus

| Élément | Valeur |
|---|---|
| Service | `prometheus` |
| Conteneur | `prometheus` |
| Image | `prom/prometheus:v2.55.1` |
| Port hôte | `9091` → `9090` |
| Configuration | `./prometheus.yml` (lecture seule) |
| Volume | `prometheus_data` |
| Réseau | `monitoring` |

Cibles collectées toutes les 15 secondes :

```text
prometheus:9090
cadvisor:8080
```

### 4.3 Grafana

| Élément | Valeur |
|---|---|
| Service | `grafana` |
| Conteneur | `grafana` |
| Image | `grafana/grafana-oss:11.3.0` |
| Port interne | `3000` |
| Domaine | `monitor.ynovm2.lab` (via Traefik) |
| Compte admin | `admin` / secret Vault `secret/grafana/admin` → `password` |
| Secrets | volume `grafana_secrets` monté sur `/run/vault` (lecture seule) |
| Provisioning | `./grafana/provisioning` (lecture seule) |
| Volume | `grafana_data` |
| Réseaux | `monitoring`, `net_ext` |

Grafana est publié par Traefik, avec les labels :

```yaml
traefik.enable=true
traefik.docker.network=net_ext
traefik.http.routers.grafana.rule=Host(`monitor.ynovm2.lab`)
traefik.http.routers.grafana.entrypoints=web
traefik.http.services.grafana.loadbalancer.server.port=3000
```

`GF_SERVER_DOMAIN` et `GF_SERVER_ROOT_URL` sont alignés sur `http://monitor.ynovm2.lab/` pour que les redirections et les liens générés par Grafana utilisent le domaine public.

Grafana lit le mot de passe admin via `GF_SECURITY_ADMIN_PASSWORD__FILE` (suffixe `__FILE` natif de Grafana). Pour le récupérer :

```powershell
docker compose exec grafana cat /run/vault/admin_password
```

Grafana n’applique ce mot de passe qu’à la création de sa base interne (premier démarrage avec un volume `grafana_data` vide). Sur un volume existant, voir la section 12 « Le mot de passe Grafana ne fonctionne pas ».

Éléments provisionnés automatiquement :

- Datasource `Prometheus` (uid `prometheus`, par défaut) vers `http://prometheus:9090`.
- Dashboard « Conteneurs ynovm2grp1dockerkube » (`conteneurs.json`, uid `docker-conteneurs`) dans le dossier `Docker`.

Le dashboard affiche, pour les conteneurs du projet `ynovm2grp1dockerkube` (hors `cadvisor`, `prometheus` et `grafana`) :

- nombre de conteneurs UP / DOWN (un conteneur non vu depuis 60 s est considéré DOWN) ;
- CPU total en % de l’hôte et mémoire totale ;
- CPU et mémoire par conteneur ;
- frise de disponibilité et tableau d’état ;
- trafic réseau entrant et sortant.

Une variable `service` permet de filtrer par service Compose.

## 5. Réseaux Docker

| Réseau | Services connectés | Rôle |
|---|---|---|
| `net_ext` | `traefik`, `nextcloud`, `wordpress`, `grafana` | Exposition web via Traefik |
| `net_db` | `mariadb`, `nextcloud`, `wordpress-db`, `wordpress` | Accès aux bases de données |
| `net_vault` | `vault`, `vault-init`, `vault-agent-wordpress`, `vault-agent-nextcloud`, `vault-agent-grafana` | Flux vers Vault |
| `monitoring` | `cadvisor`, `prometheus`, `grafana` | Supervision |

Les applications et les bases ne sont pas reliées à `net_vault` : elles ne parlent jamais à Vault directement et ne reçoivent que les fichiers produits par les agents.

## 6. Routage HTTP et résolution des noms

### Requête Nextcloud

```text
Navigateur
  -> cloud.ynovm2.lab:80
  -> Traefik
  -> règle Host(`cloud.ynovm2.lab`)
  -> réseau net_ext
  -> nextcloud:80
```

### Requête WordPress

```text
Navigateur
  -> wp.ynovm2.lab:80
  -> Traefik
  -> règle Host(`wp.ynovm2.lab`)
  -> réseau net_ext
  -> wordpress:8080
```

### Requête Grafana (supervision)

```text
Navigateur
  -> monitor.ynovm2.lab:80
  -> Traefik
  -> règle Host(`monitor.ynovm2.lab`)
  -> réseau net_ext
  -> grafana:3000
```

Contrairement à `*.localhost`, le domaine `ynovm2.lab` n’est pas résolu automatiquement. Il faut ajouter dans `C:\Windows\System32\drivers\etc\hosts` (éditeur lancé en administrateur) :

```text
127.0.0.1   cloud.ynovm2.lab
127.0.0.1   wp.ynovm2.lab
127.0.0.1   monitor.ynovm2.lab
```

Puis vider le cache DNS si nécessaire :

```powershell
ipconfig /flushdns
```

## 7. Accès et ports

| URL | Service | Exposition |
|---|---|---|
| `http://cloud.ynovm2.lab` | Nextcloud | via Traefik, port 80 |
| `http://wp.ynovm2.lab` | WordPress | via Traefik, port 80 |
| `http://localhost:8088` | API / dashboard Traefik | toutes interfaces |
| `http://127.0.0.1:8200` | Vault (UI + API) | boucle locale uniquement |
| `http://localhost:9091` | Prometheus | toutes interfaces |
| `http://monitor.ynovm2.lab` | Grafana | via Traefik, port 80 |

## 8. Volumes et fichiers persistants

### 8.1 Volumes nommés

| Volume | Type | Contenu |
|---|---|---|
| `ynovm2grp1dockerkube_nextcloud_data` | disque | Installation, configuration et fichiers Nextcloud |
| `ynovm2grp1dockerkube_nextcloud_db_data` | disque | Données MariaDB de Nextcloud |
| `ynovm2grp1dockerkube_wordpress_data` | disque | Fichiers WordPress |
| `ynovm2grp1dockerkube_wordpress_db_data` | disque | Données MariaDB de WordPress |
| `ynovm2grp1dockerkube_vault_data` | disque | Stockage chiffré de Vault |
| `ynovm2grp1dockerkube_wp_secrets` | tmpfs | Secrets WordPress rendus par l’agent |
| `ynovm2grp1dockerkube_nc_secrets` | tmpfs | Secrets Nextcloud rendus par l’agent |
| `ynovm2grp1dockerkube_grafana_secrets` | tmpfs | Mot de passe admin Grafana rendu par l’agent |
| `ynovm2grp1dockerkube_prometheus_data` | disque | Séries temporelles Prometheus |
| `ynovm2grp1dockerkube_grafana_data` | disque | Base interne Grafana |

Les volumes sur disque survivent à `docker compose down`. Les volumes tmpfs sont vidés dès qu’ils ne sont plus montés, puis régénérés par les agents au démarrage suivant.

### 8.2 Fichiers générés sur l’hôte

| Chemin | Contenu | Versionné |
|---|---|---|
| `vault/init-out/keys.txt` | Clé de descellement et root token | Non (`.gitignore`) |
| `vault/approle/<app>/role_id` | Identifiant de rôle AppRole | Non (`.gitignore`) |
| `vault/approle/<app>/secret_id` | Secret AppRole | Non (`.gitignore`) |

`keys.txt` et `vault_data` sont indissociables : sans `keys.txt`, les données de Vault ne peuvent plus être descellées. Ils doivent être sauvegardés ensemble.

## 9. Configuration et secrets

### 9.1 Fichier `.env`

Le `.env` ne contient plus aucun mot de passe : ils sont tous générés et distribués par Vault. Variables utilisées :

```text
MARIADB_USER             utilisateur de la base Nextcloud (injecté dans Vault)
MARIADB_DATABASE         nom de la base Nextcloud (injecté dans Vault)
WORDPRESS_DB_NAME        nom de la base WordPress
WORDPRESS_DB_USER        utilisateur de la base WordPress
```

Le `.env` n’est pas versionné (`.gitignore`). Le modèle partageable est `.env.example`, qui ne contient que des valeurs vides.

### 9.2 Secrets gérés par Vault

| Chemin Vault | Clés | Lu par |
|---|---|---|
| `secret/wordpress/db` | `password`, `root_password` | `vault-agent-wordpress` |
| `secret/nextcloud/db` | `password`, `root_password`, `name`, `user` | `vault-agent-nextcloud` |
| `secret/grafana/admin` | `password` | `vault-agent-grafana` |

Les mots de passe ne sont générés qu’une fois. En revanche, `name` et `user` de Nextcloud sont réécrits depuis le `.env` à chaque démarrage de `vault-init` : modifier ces variables après l’installation désynchronise Vault et la base existante.

Consulter un secret (root token dans `vault/init-out/keys.txt`) :

```powershell
docker compose exec -e VAULT_TOKEN=<root_token> vault vault kv get -address=http://127.0.0.1:8200 secret/wordpress/db
```

### 9.3 Fins de ligne

Le fichier `.gitattributes` force les fins de ligne `LF` pour les fichiers `*.sh`, `*.hcl`, `*.yml`, `*.yaml` et `*.json`. C’est indispensable sous Windows : un `init.sh` en `CRLF` ferait échouer `vault-init` dans le conteneur Linux.

## 10. Démarrage et arrêt

Depuis le dossier du projet :

```powershell
cd "XX\ynovm2grp1dockerkube"
```

Préparer le `.env` à partir du modèle puis le compléter :

```powershell
Copy-Item .env.example .env
```

Valider la configuration :

```powershell
docker compose config
```

Démarrer l’ensemble de la stack :

```powershell
docker compose up -d --pull always
```

Migration depuis l’ancienne organisation en deux fichiers : `docker-compose.monitoring.yml` n’est plus utilisé et doit être supprimé du dépôt (`git rm docker-compose.monitoring.yml`). Les conteneurs qu’il avait lancés font partie du même projet : ils sont recréés sous leurs nouveaux noms (`cadvisor`, `prometheus`, `grafana`) au premier `up`, en conservant les volumes `prometheus_data` et `grafana_data`.

Afficher l’état :

```powershell
docker compose ps
```

Consulter les logs :

```powershell
docker compose logs -f traefik
docker compose logs -f vault-init
docker compose logs -f vault-agent-wordpress
docker compose logs -f vault-agent-nextcloud
docker compose logs -f vault-agent-grafana
docker compose logs -f nextcloud
docker compose logs -f wordpress
docker compose logs -f grafana
```

Arrêter les services sans supprimer les conteneurs :

```powershell
docker compose stop
```

Arrêter et supprimer les conteneurs et réseaux :

```powershell
docker compose down
```

Le `down` simple ne supprime pas les volumes nommés sur disque. `down -v` supprime tout, y compris `vault_data` : Vault sera réinitialisé avec de nouveaux mots de passe et un nouveau `keys.txt` au démarrage suivant.

## 11. Vérifications fonctionnelles

Vérifier les conteneurs :

```powershell
docker compose ps
```

Résultat attendu :

```text
traefik          Up
vault            Up
vault-init       Up (healthy)
vault-agent-wp       Up (healthy)
vault-agent-nc       Up (healthy)
vault-agent-grafana  Up (healthy)
nextcloud-db     Up (healthy)
wordpress-db     Up (healthy)
nextcloud        Up
wordpress        Up (healthy)
cadvisor         Up (healthy)
prometheus       Up
grafana          Up
```

Vérifier Vault :

```powershell
docker compose exec vault vault status -address=http://127.0.0.1:8200
```

Valeurs attendues : `Initialized true`, `Sealed false`.

Vérifier la présence des secrets rendus :

```powershell
docker compose exec vault-agent-wordpress ls -l /secrets
docker compose exec vault-agent-nextcloud ls -l /secrets
docker compose exec vault-agent-grafana ls -l /secrets
```

Tester les applications :

```powershell
curl.exe -I http://wp.ynovm2.lab/
curl.exe -I http://cloud.ynovm2.lab/
curl.exe -I http://monitor.ynovm2.lab/
```

Vérifier la configuration WordPress :

```powershell
docker compose exec wordpress wp option get home
docker compose exec wordpress wp option get siteurl
```

Valeur attendue :

```text
http://wp.ynovm2.lab
```

Vérifier les domaines Nextcloud :

```powershell
docker compose exec -u www-data nextcloud php occ config:system:get trusted_domains
```

Valeur attendue (au minimum) :

```text
cloud.ynovm2.lab
```

Vérifier la supervision :

- Prometheus : `http://localhost:9091/targets` → cibles `prometheus` et `cadvisor` à l’état `UP`.
- Grafana : `http://monitor.ynovm2.lab` → dossier `Docker` → dashboard « Conteneurs ynovm2grp1dockerkube ».

## 12. Dépannage

### Traefik répond `404 Not Found`

```powershell
docker compose ps
docker logs traefik
docker inspect wordpress
docker inspect nextcloud
docker inspect grafana
```

Contrôler notamment :

- Le nom utilisé dans le navigateur correspond au label `Host(...)` (`*.ynovm2.lab`).
- Le service cible possède `traefik.enable=true`.
- Traefik et le service cible partagent `net_ext`.
- Le port du label correspond au port interne réel.
- Le port `80` de l’hôte est bien occupé par Traefik.

### Le navigateur ne trouve pas `*.ynovm2.lab`

Le fichier `hosts` n’est pas renseigné ou le cache DNS est ancien. Voir la section 6.

### Nextcloud indique un domaine non approuvé

```powershell
docker compose exec -u www-data nextcloud php occ config:system:set trusted_domains 1 --value=cloud.ynovm2.lab
```

### WordPress redirige vers `localhost` ou un ancien domaine

```powershell
docker compose exec wordpress wp option update home "http://wp.ynovm2.lab"
docker compose exec wordpress wp option update siteurl "http://wp.ynovm2.lab"
```

### Les bases ou les applications restent en attente (`Waiting`)

La chaîne Vault n’est pas prête. Vérifier dans l’ordre :

```powershell
docker compose logs vault
docker compose logs vault-init
docker compose logs vault-agent-wordpress
docker compose logs vault-agent-nextcloud
docker compose logs vault-agent-grafana
```

Causes fréquentes :

- `init.sh` en `CRLF` (erreur `set: illegal option` ou `not found`) : vérifier `.gitattributes` puis re-cloner ou reconvertir le fichier en `LF`.
- `MARIADB_DATABASE` ou `MARIADB_USER` vide dans `.env` : l’agent Nextcloud ne passe jamais `healthy` car `db_name` ou `db_user` est vide.
- Vault scellé : `vault-init` le redescelle normalement en moins de 10 secondes.

### Erreur d’authentification MariaDB après la migration vers Vault

Les volumes de base créés avant l’intégration de Vault conservent les anciens mots de passe du `.env` : MariaDB ignore les variables `*_PASSWORD_FILE` quand le répertoire de données est déjà initialisé. Deux options :

- Labo : supprimer les volumes de base concernés puis redémarrer (perte des données).
- Conserver les données : modifier les mots de passe dans MariaDB (`ALTER USER ...`) avec les valeurs lues dans Vault.

Le même problème apparaît si `vault_data` est supprimé alors que les volumes de base sont conservés.

### Vault ne peut plus être descellé

`vault/init-out/keys.txt` a été perdu ou ne correspond plus à `vault_data`. Sans sauvegarde de ce fichier, il faut supprimer `vault_data` (et les volumes de base associés) pour repartir d’une initialisation propre.

### Le mot de passe Grafana ne fonctionne pas

Le volume `grafana_data` a été créé avant le passage à Vault et conserve l’ancien mot de passe. Aligner le compte admin sur le secret Vault :

```powershell
docker compose exec grafana sh -c 'grafana cli admin reset-admin-password "$(cat /run/vault/admin_password)"'
```

### `vault-agent-grafana` redémarre en boucle après une mise à jour

`vault-init` tournait déjà avec l’ancienne version de `init.sh` : le rôle AppRole `grafana` et le dossier `vault/approle/grafana` n’existent pas encore. Relancer le script :

```powershell
docker compose up -d --force-recreate vault-init
docker compose up -d
```

### Grafana n’affiche aucune donnée

- Vérifier les cibles dans `http://localhost:9091/targets`.
- Le dashboard filtre sur le projet `ynovm2grp1dockerkube` : ne pas surcharger le nom de projet avec `-p` ou `COMPOSE_PROJECT_NAME`.
- Sous Docker Desktop / WSL2, cAdvisor peut ne pas voir certains montages ; consulter `docker compose logs cadvisor`.

## 13. Image WordPress personnalisée

Le dossier `customwp` contient le Dockerfile de l’image `ebynov/ynovm2dockerwp` :

- Base `wordpress:7.1.3-php8.3-apache`, avec `apt-get upgrade` des paquets système.
- Extensions PHP `zip`, `intl` et Redis.
- WP-CLI.
- Configuration PHP personnalisée (`php/custom.ini`) : `upload_max_filesize` et `post_max_size` à 64M, `memory_limit` à 256M, `max_execution_time` à 120.
- Thème Astra et plugin Contact Form 7 copiés dans l’image.
- Apache configuré sur le port `8080`, exécution en `www-data`.
- Un healthcheck sur `/wp-login.php`.

Le Compose utilise l’image publiée :

```yaml
image: ebynov/ynovm2dockerwp:1.2.1
```

Le Dockerfile n’est donc pas reconstruit par `docker compose up`.

Le dossier `wp-content/mu-plugins/` contient un fichier `.gitkeep` pour que Git le versionne : sans lui, le `COPY` du Dockerfile échoue lors d’une reconstruction depuis un clone.

### Scans de sécurité

Les résultats Trivy sont consignés dans `SCAN.md` :

| Scan | Image | Résultat |
|---|---|---|
| N°1 — 14/10/2026 12h06 | `ynovm2dockerwp:1.2.0` | 177 vulnérabilités (175 HIGH, 2 CRITICAL), aucun secret |
| N°2 — 14/10/2026 12h26 | `ynovm2dockerwp:1.2.1` | 0 vulnérabilité, aucun secret |

La version `1.2.1` intègre les correctifs disponibles. Le risque résiduel est lié à l’image de base WordPress.

## 14. Sécurité et limites

Acquis :

- Aucun mot de passe dans le `.env` : bases et admin Grafana sont générés aléatoirement par Vault.
- Chaque agent ne lit que le secret de son application (policy AppRole dédiée, token de 1 h).
- Les secrets rendus vivent en tmpfs, montés en lecture seule dans les conteneurs consommateurs.
- Les bases, les applications et Grafana ne sont pas publiées directement sur l’hôte (accès web uniquement via Traefik) ; Vault n’est exposé que sur `127.0.0.1`.
- `keys.txt`, `role_id`, `secret_id` et `.env` sont exclus de Git.

Limites (acceptables en labo, à traiter avant toute exposition) :

- Vault fonctionne sans TLS (`tls_disable = 1`) et avec une seule clé de descellement.
- La clé de descellement et le root token sont stockés en clair sur l’hôte, à côté de Vault, et le descellement est automatique : le scellement ne protège donc pas contre un accès à l’hôte. En production : auto-unseal via KMS/HSM, révocation du root token, clés réparties.
- Les fichiers de secrets sont en `0444` dans le tmpfs.
- `vault-init` conserve le root token en mémoire en permanence.
- L’image `hashicorp/vault:1.13.3` est ancienne : prévoir une montée de version.
- Les ports Traefik (`8088`) et Prometheus (`9091`) sont publiés sur toutes les interfaces ; les lier à `127.0.0.1` pour un usage local. Prometheus n’a pas d’authentification.
- Le dashboard Traefik ne doit pas être publié sur Internet sans authentification.
- cAdvisor tourne en mode `privileged` et Traefik a accès au socket Docker (même en lecture seule, cela donne une visibilité importante sur le moteur).
- Les applications sont servies en HTTP local, sans TLS. Une exposition externe nécessite HTTPS, certificats, pare-feu, sauvegardes et une politique de mise à jour.

Réglages persistants à appliquer après une première installation (ou après un changement de domaine) :

```powershell
docker compose exec -u www-data nextcloud php occ config:system:set trusted_domains 1 --value=cloud.ynovm2.lab
docker compose exec wordpress wp option update home "http://wp.ynovm2.lab"
docker compose exec wordpress wp option update siteurl "http://wp.ynovm2.lab"
```

## 15. Actions à finaliser/corriger

Fait :

- ~~Fusion de docker-compose.yaml et docker-compose.monitoring.yml~~
- ~~Mot de passe admin Grafana géré par Vault~~
- ~~Grafana publié par Traefik sur `monitor.ynovm2.lab`~~
- ~~Nom de projet Compose fixé (`name: ynovm2grp1dockerkube`)~~

À faire :

- Faire disparaître les secrets des conteneurs applicatifs (actuellement visibles dans `/run/vault`) → `/dev/shm`.
- Lier les ports `8088` (Traefik) et `9091` (Prometheus) à `127.0.0.1`, ou les passer derrière Traefik avec authentification.
- Rendre déclaratifs les réglages encore manuels :
  - WordPress : `WORDPRESS_CONFIG_EXTRA` avec `WP_HOME` / `WP_SITEURL` ;
  - Nextcloud : `TRUSTED_PROXIES` et `OVERWRITECLIURL`, adaptés au fonctionnement derrière Traefik.

