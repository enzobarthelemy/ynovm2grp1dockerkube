# Documentation technique — stack `ynovm2grp1dockerkube`

## 1. Présentation

Cette stack Docker Compose fournit une infrastructure web locale composée de :

- Traefik comme reverse proxy HTTP.
- Nextcloud comme plateforme de stockage et de collaboration.
- WordPress comme site web CMS.
- Deux bases MariaDB séparées, une par application.
- Deux réseaux Docker dédiés pour séparer l’exposition web et les flux de base de données.
- Des volumes Docker nommés pour conserver les données lors du remplacement des conteneurs.

Le fichier principal est :

```text
docker-compose.yaml
```

## 2. Schéma général

```text
                         Navigateur
                             |
                             |
                         Traefik
                       reverse proxy
                       réseau net_ext
                       /            \
                      /              \
       Host: cloud.localhost       Host: wp.localhost
                    |                    |
                    v                    v
          Nextcloud:80          WordPress:8080
                    |                    |
                    v                    v
              mariadb:3306       wordpress-db:3306
                       réseau net_db
```

Traefik est le seul service publié sur le port HTTP `80` de l’hôte. Les applications web ne publient plus directement leurs ports vers Windows.

## 3. Services Compose

### 3.1 Traefik

| Élément | Valeur |
|---|---|
| Service | `traefik` |
| Conteneur | `traefik` |
| Image | `traefik:v3.6.2` |
| Réseau | `net_ext` |
| Port HTTP hôte | `80` |
| Dashboard | `http://localhost:8088` |
| Provider | Docker |
| Redémarrage | `unless-stopped` |

Traefik observe les conteneurs Docker grâce au socket monté en lecture seule :

```text
/var/run/docker.sock:/var/run/docker.sock:ro
```

Les labels Docker présents sur Nextcloud et WordPress sont automatiquement détectés par Traefik.

Options principales :

```yaml
--providers.docker=true
--providers.docker.exposedbydefault=false
--entrypoints.web.address=:80
--api.dashboard=true
```

`exposedbydefault=false` signifie qu’un service n’est pas publié par Traefik sans le label explicite :

```yaml
traefik.enable=true
```

### 3.2 Nextcloud

| Élément | Valeur |
|---|---|
| Service | `nextcloud` |
| Conteneur | `nextcloud` |
| Image | `nextcloud:32.0.15-apache` |
| Port interne | `80` |
| Domaine | `cloud.localhost` |
| Réseaux | `net_ext`, `net_db` |
| Base de données | `mariadb` |
| Redémarrage | `always` |

Nextcloud reçoit les requêtes envoyées par Traefik pour le domaine :

```text
http://cloud.localhost
```

Labels utilisés :

```yaml
traefik.enable=true
traefik.docker.network=net_ext
traefik.http.routers.nextcloud.rule=Host(`cloud.localhost`)
traefik.http.routers.nextcloud.entrypoints=web
traefik.http.services.nextcloud.loadbalancer.server.port=80
```

Nextcloud doit autoriser le domaine public dans `trusted_domains`. Le réglage actuel a été appliqué avec :

```powershell
docker compose exec nextcloud php occ config:system:set trusted_domains 1 --value=cloud.localhost
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
| Base | valeur `MARIADB_DATABASE` du `.env` |
| Utilisateur | valeur `MARIADB_USER` du `.env` |
| Volume | `nextcloud_db_data` |
| Redémarrage | `always` |

La base n’est pas publiée sur un port Windows. Elle est accessible uniquement depuis les conteneurs connectés à `net_db`.

Le healthcheck vérifie :

```text
healthcheck.sh --connect --innodb_initialized
```

Nextcloud dépend de l’état sain de ce service avant son démarrage.

### 3.4 WordPress

| Élément | Valeur |
|---|---|
| Service | `wordpress` |
| Conteneur | `wordpress` |
| Image | `ebynov/ynovm2dockerwp:1.2.1` |
| Port interne | `8080` |
| Domaine | `wp.localhost` |
| Réseaux | `net_ext`, `net_db` |
| Base de données | `wordpress-db` |
| Redémarrage | `unless-stopped` |

WordPress reçoit les requêtes envoyées par Traefik pour :

```text
http://wp.localhost
```

Labels utilisés :

```yaml
traefik.enable=true
traefik.docker.network=net_ext
traefik.http.routers.wordpress.rule=Host(`wp.localhost`)
traefik.http.routers.wordpress.entrypoints=web
traefik.http.services.wordpress.loadbalancer.server.port=8080
```

Le port interne `8080` vient de l’image WordPress personnalisée, qui configure Apache pour écouter sur ce port.

Les URLs WordPress ont été définies avec :

```powershell
docker compose exec wordpress wp option update home "http://wp.localhost"
docker compose exec wordpress wp option update siteurl "http://wp.localhost"
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
| Volume | `wordpress_db_data` |
| Redémarrage | `unless-stopped` |

La base WordPress n’est pas accessible directement depuis l’hôte. WordPress la contacte avec le nom DNS Docker :

```text
wordpress-db:3306
```

## 4. Réseaux Docker

### 4.1 Réseau `net_ext`

Réseau externe de la stack applicative web.

Services connectés :

```text
traefik
nextcloud
wordpress
```

Il permet à Traefik d’atteindre les deux applications web.

### 4.2 Réseau `net_db`

Réseau interne dédié aux communications avec les bases de données.

Services connectés :

```text
mariadb
nextcloud
wordpress-db
wordpress
```

Les bases MariaDB ne sont pas publiées vers l’hôte. Cette séparation limite leur exposition réseau.

## 5. Routage HTTP

### Requête Nextcloud

```text
Navigateur
  -> cloud.localhost:80
  -> Traefik
  -> règle Host(`cloud.localhost`)
  -> réseau net_ext
  -> nextcloud:80
```

### Requête WordPress

```text
Navigateur
  -> wp.localhost:80
  -> Traefik
  -> règle Host(`wp.localhost`)
  -> réseau net_ext
  -> wordpress:8080
```

Le navigateur doit donc utiliser les noms suivants :

```text
http://cloud.localhost
http://wp.localhost
```

## 6. Volumes persistants

| Volume | Contenu |
|---|---|
| `ynovm2grp1dockerkube_nextcloud_data` | Installation, configuration et fichiers Nextcloud |
| `ynovm2grp1dockerkube_nextcloud_db_data` | Données MariaDB de Nextcloud |
| `ynovm2grp1dockerkube_wordpress_data` | Fichiers WordPress |
| `ynovm2grp1dockerkube_wordpress_db_data` | Données MariaDB de WordPress |

Les volumes survivent à :

```powershell
docker compose down
```

## 7. Configuration et secrets

Le fichier `.env` contient les variables réellement utilisées par Compose :

```text
MARIADB_ROOT_PASSWORD
MARIADB_PASSWORD
MARIADB_USER
MARIADB_DATABASE
WORDPRESS_DB_NAME
WORDPRESS_DB_USER
WORDPRESS_DB_PASSWORD
WORDPRESS_DB_ROOT_PASSWORD
```

Le fichier `.env` ne doit pas être versionné. Il est exclu par `.gitignore`.

Le fichier partageable est :

```text
.env.example
```

Il ne doit contenir que des valeurs vides ou d’exemple.

## 8. Démarrage et arrêt

Depuis le dossier du projet :

```powershell
cd "XX\ynovm2grp1dockerkube"
```

Valider la configuration :

```powershell
docker compose config
```

Démarrer la stack :

```powershell
docker compose up -d --pull always
```

Afficher l’état :

```powershell
docker compose ps
```

Consulter les logs :

```powershell
docker compose logs -f traefik
docker compose logs -f nextcloud
docker compose logs -f wordpress
```

Arrêter les services sans supprimer les conteneurs :

```powershell
docker compose stop
```

Arrêter et supprimer les conteneurs et réseaux Compose :

```powershell
docker compose down
```

Le `down` simple ne supprime pas les volumes nommés.

## 9. Vérifications fonctionnelles

Vérifier les conteneurs :

```powershell
docker compose ps
```

Résultat attendu :

```text
nextcloud       Up
nextcloud-db    Up (healthy)
traefik         Up
wordpress       Up (healthy)
wordpress-db    Up (healthy)
```

Tester WordPress :

```powershell
curl.exe -I http://wp.localhost/
```

Tester Nextcloud :

```powershell
curl.exe -I http://cloud.localhost/
```

Vérifier la configuration WordPress :

```powershell
docker compose exec wordpress wp option get home
docker compose exec wordpress wp option get siteurl
```

Valeur attendue :

```text
http://wp.localhost
```

Vérifier les domaines Nextcloud :

```powershell
docker compose exec nextcloud php occ config:system:get trusted_domains
```

Valeurs attendues :

```text
localhost
cloud.localhost
```

## 10. Dépannage

### Traefik répond `404 Not Found`

Vérifier :

```powershell
docker compose ps
docker logs traefik
docker inspect wordpress
docker inspect nextcloud
```

Contrôler notamment :

- Le nom utilisé dans le navigateur correspond au label `Host(...)`.
- Le service cible possède `traefik.enable=true`.
- Traefik et le service cible partagent `net_ext`.
- Le port du label correspond au port interne réel.
- Le port `80` de l’hôte est bien occupé par Traefik.

### Nextcloud indique un domaine non approuvé

Ajouter le domaine avec :

```powershell
docker compose exec nextcloud php occ config:system:set trusted_domains 1 --value=cloud.localhost
```

### WordPress redirige vers `localhost:8080`

Réappliquer les URLs publiques :

```powershell
docker compose exec wordpress wp option update home "http://wp.localhost"
docker compose exec wordpress wp option update siteurl "http://wp.localhost"
```

## 11. Image WordPress personnalisée

Le dossier `customwp` contient un Dockerfile capable de construire une image WordPress personnalisée avec :

- PHP 8.3.
- Extensions PHP `zip`, `intl` et Redis.
- WP-CLI.
- Configuration PHP personnalisée.
- Thèmes, plugins et mu-plugins copiés dans l’image.
- Apache configuré sur le port `8080`.
- Un healthcheck sur `/wp-login.php`.

Le Compose utilise actuellement l’image publiée :

```yaml
image: ebynov/ynovm2dockerwp:1.2.1
```

Le Dockerfile local `customwp/Dockerfile` n’est donc pas reconstruit par `docker compose up`. Pour l’utiliser, le service WordPress devrait employer une instruction `build` pointant vers ce dossier, après validation du changement.

## 12. Sécurité et limites

- Les mots de passe du `.env` doivent être remplacés par des secrets forts.
- Le fichier `.env` ne doit jamais être envoyé dans Git.
- Le socket Docker donne à Traefik une visibilité importante sur le moteur ; le montage en lecture seule réduit les possibilités d’écriture mais ne supprime pas tous les risques.
- Le dashboard Traefik exposé sur `localhost:8088` ne doit pas être publié sur Internet sans authentification.
- La stack actuelle utilise HTTP local, sans chiffrement TLS.
- Une exposition externe nécessite HTTPS, certificats, pare-feu, sauvegardes et une politique de mise à jour.
- Les bases MariaDB ne sont pas publiées sur l’hôte, ce qui réduit leur surface d’exposition.

Les réglages persistants spécifiques aux volumes peuvent nécessiter une initialisation :

```powershell
docker compose exec nextcloud php occ config:system:set trusted_domains 1 --value=cloud.localhost
docker compose exec wordpress wp option update home "http://wp.localhost"
docker compose exec wordpress wp option update siteurl "http://wp.localhost"
```
