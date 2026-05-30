# L.I.S.A. — Local Intelligent System Assistant

> Stack IA locale complète · Reverse proxy · DDNS · RAG · STT/TTS · HUD Tauri (à venir)

---

<details>
<summary><strong>Table des matières</strong></summary>

- [C'est quoi L.I.S.A.](#cest-quoi-lisa)
- [Architecture de la stack](#architecture-de-la-stack)
- [Prérequis hardware](#prérequis-hardware)
- [Installation rapide](#installation-rapide)
- [Ce que fait chaque script](#ce-que-fait-chaque-script)
- [Arborescence du repository](#arborescence-du-repository)
- [Configuration réseau](#configuration-réseau)
- [Sécurité](#sécurité)
- [Endpoints HUD — référence API](#endpoints-hud--référence-api)
- [Gestion des clés API](#gestion-des-clés-api)
- [Upgrade et maintenance](#upgrade-et-maintenance)
- [Le HUD L.I.S.A.](#le-hud-lisa)
- [Compatibilité OS et architectures](#compatibilité-os-et-architectures)
- [Roadmap](#roadmap)
- [Modèle économique](#modèle-économique)

</details>

---

## C'est quoi L.I.S.A.

**L**ocal **I**ntelligent **S**ystem **A**ssistant.

L.I.S.A. est une stack IA qui s'installe sur votre machine Linux et vous donne accès à un assistant vocal et textuel qui tourne entièrement chez vous. Aucune donnée ne quitte votre machine par défaut. Vous pouvez activer la recherche internet à la demande, connecter des services externes si vous le souhaitez, et exposer l'ensemble sur internet via un reverse proxy sécurisé.

La stack est la fondation. Par-dessus vient le **HUD L.I.S.A.** — une interface bureau sous forme d'orbe interactive, développée en Tauri v2, qui sera disponible sur Linux, Windows et macOS. Le HUD est un produit séparé, payant, qui communique avec la stack via l'API locale.

**La stack est gratuite et open source. Le HUD sera payant.**

---

## Architecture de la stack

```
┌─────────────────────────────────────────────────────────────────┐
│                        MACHINE LINUX                            │
│                                                                 │
│  ┌──────────────┐    ┌──────────────────────────────────────┐  │
│  │   HUD Tauri  │    │         Réseau Docker interne         │  │
│  │  (à venir)   │    │  (lisa_internal — isolé du host)     │  │
│  └──────┬───────┘    │                                       │  │
│         │            │  ┌──────────┐   ┌──────────────────┐ │  │
│         │            │  │   LLM    │   │   API FastAPI     │ │  │
│         │            │  │ (Ollama) │◄──│  orchestrateur   │ │  │
│         │            │  └──────────┘   └────────┬─────────┘ │  │
│         │            │                          │            │  │
│         │            │  ┌──────────┐   ┌────────▼─────────┐ │  │
│         │            │  │   STT    │◄──│   RAG (Qdrant)   │ │  │
│         │            │  │(Whisper) │   └──────────────────┘ │  │
│         │            │  └──────────┘                        │  │
│         │            │  ┌──────────┐   ┌──────────────────┐ │  │
│         │            │  │   TTS    │   │ Search (SearXNG) │ │  │
│         │            │  │ (Piper)  │   │   (optionnel)    │ │  │
│         │            │  └──────────┘   └──────────────────┘ │  │
│         │            └──────────────────────────────────────┘  │
│         │                          │                            │
│         │            ┌─────────────▼──────────────┐            │
│         └────────────►   Caddy (reverse proxy)    │            │
│                      │   TLS automatique           │            │
│                      │   Authelia (auth optionnel) │            │
│                      └─────────────────────────────┘            │
│                                    │                            │
└────────────────────────────────────┼────────────────────────────┘
                                     │ HTTPS
                              ┌──────▼───────┐
                              │   Internet   │
                              │  (optionnel) │
                              └──────────────┘
```

### Services et rôles

| Service | Image | Rôle | Port interne |
|---------|-------|------|-------------|
| LLM | `ollama/ollama` | Inférence locale des modèles | 11434 |
| STT | `whisper.cpp` (compilé) | Transcription audio → texte | 8080 |
| TTS | `piper-tts` (Python) | Synthèse texte → audio | 5500 |
| RAG | `qdrant/qdrant` | Base vectorielle / mémoire | 6333 |
| Search | `searxng/searxng` | Recherche web (on/off) | 8888 |
| API | `python:3.11` FastAPI | Orchestrateur + endpoints HUD | 8000 |
| Caddy | `caddy:alpine` | Reverse proxy + TLS auto | 80/443 |
| Authelia | `authelia/authelia` | SSO / authentification | 9091 |
| DDNS | `linuxserver/duckdns` | Mise à jour IP dynamique | — |

**Règle réseau** : seuls `Caddy` et `API` ont accès au réseau externe (`lisa_external`). Tous les autres services sont sur `lisa_internal`, invisible depuis l'extérieur. Ollama n'est jamais exposé directement sur le host.

---

## Prérequis hardware

### Profil bas — 4 à 8 GB RAM (ex: vieux PC, mini PC, VM légère)

- Modèles LLM : `phi3` (3.8B) ou `tinyllama` (1.1B)
- STT : Whisper modèle `base`
- RAM allouée stack : ~4 GB
- Disque recommandé : 20 GB minimum

### Profil moyen — 8 à 16 GB RAM (PC desktop standard)

- Modèles LLM : `llama3.2` (3B), `mistral` (7B)
- STT : Whisper modèle `small` ou `base`
- RAM allouée stack : ~7 GB
- Disque recommandé : 30 GB

### Profil élevé — 16 GB+ RAM (workstation, serveur)

- Modèles LLM : `llama3.1:8b`, `mistral`, `mixtral` (32 GB+ requis)
- STT : Whisper modèle `medium`
- GPU NVIDIA : accélération automatique via Ollama (CUDA)
- Disque recommandé : 50 GB+

### Architectures supportées

| Architecture | Support | Notes |
|-------------|---------|-------|
| x86_64 (AMD64) | ✅ Complet | Configuration de référence |
| ARM64 (aarch64) | ✅ Supporté | Raspberry Pi 5 (8GB min), serveurs ARM, Apple Silicon via VM |
| x86 32 bits | ❌ Non supporté | Docker et Ollama n'en veulent plus |
| ARMv7 et moins | ❌ Non supporté | Trop limité |

**OS requis pour la stack** : Linux uniquement (Ubuntu 22.04/24.04 recommandé, Debian 11/12 supporté).
Le HUD L.I.S.A. sera multiplateforme via Tauri v2 (Linux, Windows, macOS, et plus tard Android/iOS).

---

## Installation rapide

La seule commande à connaître :

```bash
bash install.sh
```

L'`install.sh` se télécharge depuis la page **Releases** du repository GitHub. C'est le seul fichier à récupérer manuellement. Il télécharge le reste automatiquement.

```
https://github.com/geds3169/lisa/releases → Télécharger install.sh → bash install.sh

Ou directement :

```bash
curl -fsSL https://raw.githubusercontent.com/geds3169/lisa/main/install.sh -o install.sh && bash install.sh
```
```

### Ce qui se passe concrètement

```
install.sh
  │
  ├── Vérifie Linux + architecture
  ├── Installe curl/git si absents
  ├── Télécharge tous les scripts depuis GitHub
  └── Lance 00_config.sh
        │
        ├── Questions interactives (réseau, modèles, clés API...)
        ├── Chiffrement GPG des secrets
        └── Lance 01_precheck_install.sh (dans tmux)
              │
              ├── Installe Docker (méthode officielle)
              ├── Configure le groupe docker (sg docker)
              ├── Configure UFW (pare-feu)
              └── Lance 02_stack_files.sh
                    │
                    ├── Génère tous les Dockerfiles depuis lisa.conf
                    ├── Génère docker-compose.yml adapté
                    └── Lance 03_run_stack.sh
                          │
                          ├── Build séquentiel (anti-saturation ressources)
                          ├── Pull du modèle Ollama
                          ├── Health checks adaptatifs
                          └── Lance 04_network.sh (si exposition internet)
                                │
                                ├── Génère le Caddyfile
                                ├── Configure Authelia (si activé)
                                └── Démarre DDNS DuckDNS (si choisi)
```

---

## Ce que fait chaque script

### `install.sh` — Bootstrap

Télécharge le repository, applique les droits d'exécution, lance la chaîne. C'est le seul fichier distribué dans les releases GitHub.

### `00_config.sh` — Configuration interactive

Pose toutes les questions à l'utilisateur :
- Architecture et ressources (détection auto)
- Exposition internet + type DNS
- Choix des modèles LLM selon RAM disponible
- Mode local ou API externe pour chaque service
- Clés API (chiffrées GPG dès la saisie)
- Services optionnels (RAG, SearXNG, Authelia)

Génère `lisa.conf` (configuration en clair, sans secrets) et `.env.gpg` (secrets chiffrés).

Peut être relancé seul pour modifier la configuration :
```bash
bash ~/ai-stack/00_config.sh --reconfigure
```

### `00_provider_select.sh` — Sélection fournisseur API

Sous-script appelé par `00_config.sh`. Affiche la liste des fournisseurs d'une catégorie (llm, stt, tts, rag...), propose une saisie par numéro ou nom, avec fuzzy matching pour les fautes de frappe.

### `01_precheck_install.sh` — Environnement système

- Installe Docker via la méthode officielle (pas `docker.io` apt qui est souvent en retard)
- Gère le groupe docker proprement via `sg docker`
- Configure UFW (pare-feu) : ports 80/443 ouverts si exposition internet, sinon API uniquement en local
- Sauvegarde un snapshot de l'environnement Docker existant pour restauration en cas d'échec
- Bloque la mise en veille système pendant toute l'installation

### `02_stack_files.sh` — Génération des fichiers Docker

Génère tous les `Dockerfiles` et le `docker-compose.yml` en fonction de `lisa.conf`. Adapte les images et options de compilation selon l'architecture (ARM64 vs x86_64). Les services désactivés (RAG, SearXNG, Authelia, Caddy) ne sont simplement pas générés.

### `03_run_stack.sh` — Démarrage de la stack

- Build Docker avec gestion des erreurs
- Démarrage séquentiel : LLM → STT → TTS → RAG → Search → API
- Chaque service attend que les ressources CPU/RAM soient disponibles avant de démarrer le suivant
- Health checks avec retry adaptatifs selon le profil RAM
- Pull automatique du modèle Ollama
- Supprime les secrets éphémères (mot de passe, .env.plain) en fin d'installation

### `04_network.sh` — Réseau externe

- Génère le `Caddyfile` dynamiquement selon les domaines configurés
- Configure Authelia avec hash du mot de passe (Argon2)
- Démarre le container DDNS pour DuckDNS (mise à jour auto de l'IP)
- Première mise à jour IP immédiate

### `providers.json` — Base fournisseurs API

Fichier JSON contenant la liste de tous les fournisseurs supportés, par catégorie (llm, stt, tts, rag, search, domotique, meteo, calendrier, notifications). Utilisé par `00_provider_select.sh` pour le fuzzy matching.

---

## Arborescence du repository

```
lisa/                          ← Racine du repo GitHub
│
├── install.sh                 ← Seul fichier dans les Releases (point d'entrée)
│
├── 00_config.sh               ← Configuration interactive
├── 00_provider_select.sh      ← Sélection fournisseur API (sous-script)
├── 01_precheck_install.sh     ← Environnement système + Docker
├── 02_stack_files.sh          ← Génération Dockerfiles + compose
├── 03_run_stack.sh            ← Build + démarrage + health checks
├── 04_network.sh              ← Caddy + DuckDNS + Authelia
│
├── providers.json             ← Base fournisseurs API (fuzzy match)
│
└── README.md                  ← Ce fichier

─────────────────────────── (généré à l'installation dans ~/ai-stack/)

~/ai-stack/
│
├── lisa.conf                  ← Config L.I.S.A. (sans secrets)
├── .env.gpg                   ← Secrets chiffrés GPG
├── .lisa_state                ← Marqueur d'étape (reprise après interruption)
├── lisa_install.log           ← Log complet de l'installation
│
├── docker-compose.yml         ← Compose généré dynamiquement
│
├── api/
│   ├── Dockerfile
│   └── main.py                ← Orchestrateur FastAPI + endpoints HUD
├── llm/
│   └── Dockerfile             ← Ollama
├── stt/
│   └── Dockerfile             ← Whisper.cpp (compilé from source)
├── tts/
│   ├── Dockerfile
│   └── tts_server.py          ← Serveur Flask Piper
├── rag/
│   └── Dockerfile             ← Qdrant (optionnel)
├── search/                    ← SearXNG (optionnel)
├── caddy/
│   └── Caddyfile              ← Généré par 04_network.sh
└── authelia/
    ├── configuration.yml      ← Généré par 04_network.sh
    └── users_database.yml     ← Utilisateurs Authelia
```

---

## Configuration réseau

### Option 1 — Local uniquement

Aucune configuration réseau nécessaire. L'API est accessible sur `http://localhost:8001`.
Le pare-feu bloque tout accès externe aux ports de la stack.

### Option 2 — Domaine personnel

Vous avez un domaine (ex: `mondomaine.fr`). Vous pointez les DNS vers votre IP publique. Caddy gère automatiquement les certificats Let's Encrypt.

Les sous-domaines créés :
```
llm.mondomaine.fr    → Ollama
stt.mondomaine.fr    → Whisper
tts.mondomaine.fr    → Piper
rag.mondomaine.fr    → Qdrant
api.mondomaine.fr    → API principale (point d'entrée HUD)
search.mondomaine.fr → SearXNG
```

Si vous avez déjà un certificat, ajoutez-le dans `~/ai-stack/caddy/` et modifiez le `Caddyfile` :
```
api.mondomaine.fr {
    tls /etc/caddy/certs/cert.pem /etc/caddy/certs/key.pem
    reverse_proxy lisa_api:8000
}
```
Puis : `docker compose restart caddy`

### Option 3 — DuckDNS (gratuit, sans domaine)

Créez un compte sur [duckdns.org](https://www.duckdns.org), créez 6 sous-domaines avec un suffixe numérique unique :

```
lisa-api-XXXX.duckdns.org
lisa-llm-XXXX.duckdns.org
lisa-stt-XXXX.duckdns.org
lisa-tts-XXXX.duckdns.org
lisa-rag-XXXX.duckdns.org
lisa-search-XXXX.duckdns.org
```

Choisissez un suffixe à 4 chiffres (ex: 4827). Si le nom est déjà pris sur DuckDNS, essayez une autre combinaison — nous ne pouvons pas vérifier la disponibilité à votre place, le nombre d'utilisateurs de L.I.S.A. étant variable.

Le container DDNS se charge de maintenir votre IP à jour automatiquement, y compris après redémarrage ou coupure réseau.

---

## Sécurité

### Réseau Docker

Deux réseaux distincts :
- `lisa_internal` : réseau isolé (flag `internal: true`). Aucun service n'y a accès depuis l'extérieur sauf via l'API ou Caddy.
- `lisa_external` : réseau avec accès internet, uniquement pour Caddy, l'API et le container DDNS.

Ollama (11434), Whisper (8080), Piper (5500), Qdrant (6333) et SearXNG (8888) ne sont **jamais exposés directement** sur le host.

### Secrets

Les clés API sont chiffrées via GPG (Ed25519) dans `~/.ai-stack/.env.gpg`. Pour consulter ou modifier :

```bash
# Déchiffrement temporaire
gpg -d ~/ai-stack/.env.gpg > /tmp/lisa_env

# Modification
nano /tmp/lisa_env

# Rechiffrement
gpg -e -r VOTRE_GPG_KEY_ID /tmp/lisa_env
mv /tmp/lisa_env.gpg ~/ai-stack/.env.gpg

# Nettoyage
rm /tmp/lisa_env
```

**Le HUD L.I.S.A. permettra de modifier les clés API via son interface** sans passer par le terminal — fonctionnalité prévue dans la version HUD payante.

Emplacement du fichier de secrets : `~/ai-stack/.env.gpg`
Emplacement de la configuration (sans secrets) : `~/ai-stack/lisa.conf`

### Mot de passe système éphémère

Pendant l'installation, votre mot de passe sudo est chiffré avec AES-256 dans un fichier temporaire, utilisé pour maintenir les droits sudo actifs sans vous redemander le mot de passe à chaque étape. Ce fichier est **supprimé automatiquement** à la fin de l'installation, en cas d'interruption (Ctrl+C), ou en cas d'erreur fatale. Rien n'est conservé après installation.

### Authelia (authentification externe)

Si vous activez l'exposition internet avec Authelia, tout accès externe passe par une page de login. Le mot de passe est hashé en Argon2 avant stockage. L'ajout de 2FA TOTP est possible manuellement dans `~/ai-stack/authelia/configuration.yml`.

### Pare-feu UFW

Règles appliquées automatiquement :
```
Mode local    : entrant bloqué sauf SSH + API sur 127.0.0.1:8001
Mode internet : entrant bloqué sauf SSH + ports 80 + 443 (Caddy)
```

---

## Endpoints HUD — référence API

L'API FastAPI expose tous les endpoints nécessaires au HUD. Base URL : `http://localhost:8001` (ou `https://api.votre-domaine` en externe).

Documentation interactive Swagger : `http://localhost:8001/docs`

### Lecture d'état

| Méthode | Endpoint | Description |
|---------|----------|-------------|
| `GET` | `/` | Ping — service vivant |
| `GET` | `/status` | État complet de tous les microservices |
| `GET` | `/config` | Configuration courante |

**Exemple réponse `/status` :**
```json
{
  "services": {
    "llm":    { "status": "up", "models": ["llama3.2", "phi3"], "active": "llama3.2" },
    "stt":    { "status": "up", "provider": "local" },
    "tts":    { "status": "up", "provider": "local" },
    "rag":    { "status": "up" },
    "search": { "status": "up", "enabled": false }
  },
  "config": {
    "web_search": false,
    "llm_model": "llama3.2",
    "rag_enabled": true
  }
}
```

### Contrôle à chaud (HUD → API)

| Méthode | Endpoint | Body | Description |
|---------|----------|------|-------------|
| `POST` | `/config` | `{"web_search": true}` | Activer/désactiver recherche web |
| `POST` | `/config` | `{"llm_model": "mistral"}` | Changer de modèle LLM |

Le bouton web search du HUD envoie `POST /config {"web_search": true/false}` — l'API démarre ou arrête le container SearXNG en conséquence.

### Chat et services

| Méthode | Endpoint | Body | Description |
|---------|----------|------|-------------|
| `POST` | `/chat` | `{"prompt": "...", "model": "llama3.2"}` | Chat LLM (RAG + web search injectés si actifs) |
| `POST` | `/search` | `{"query": "..."}` | Recherche web (SearXNG) |
| `POST` | `/tts` | `{"text": "...", "voice": "fr_FR-siwis-medium"}` | Synthèse vocale |

### Architecture des interactions HUD → API

```
HUD (Tauri)
    │
    ├── GET  /status          → État des services (indicateur orbe)
    ├── GET  /config          → Config courante (état boutons HUD)
    ├── POST /config          → Toggle web search, changement modèle
    ├── POST /chat            → Envoi message utilisateur
    ├── POST /tts             → Lecture vocale de la réponse
    └── POST /search          → Recherche web directe (widget)
```

---

## Gestion des clés API

### Clés renseignées à l'installation

Stockées dans `~/ai-stack/.env.gpg` (chiffré GPG).

### Ajouter ou modifier une clé après installation

**Via terminal :**
```bash
# Déchiffrer
gpg -d ~/ai-stack/.env.gpg > /tmp/lisa_env

# Éditer (ajouter une ligne NOUVEAU_SERVICE_API_KEY=votre_clé)
nano /tmp/lisa_env

# Rechiffrer (remplacez VOTRE_KEY_ID par la valeur dans lisa.conf)
GPG_KEY_ID=$(grep GPG_KEY_ID ~/ai-stack/lisa.conf | cut -d'"' -f2)
gpg -e -r "$GPG_KEY_ID" /tmp/lisa_env
mv /tmp/lisa_env.gpg ~/ai-stack/.env.gpg
rm /tmp/lisa_env
```

**Via le HUD L.I.S.A. (version payante) :** un panneau dédié permettra d'ajouter, modifier ou supprimer des clés API sans toucher au terminal. Le HUD écrira directement dans `~/ai-stack/.env.gpg` via un endpoint API sécurisé (à implémenter dans une version ultérieure).

### Liste des fournisseurs supportés

La liste complète est dans `~/ai-stack/providers.json`, organisée par catégorie :
`llm`, `stt`, `tts`, `rag`, `search`, `domotique`, `meteo`, `calendrier`, `notifications`.

Pour ajouter un fournisseur non listé : éditez `providers.json` en ajoutant une entrée dans la catégorie correspondante, format :
```json
{
  "id": "mon_fournisseur",
  "name": "Mon Fournisseur",
  "aliases": ["mon fournisseur", "monfournisseur"],
  "key_format": "sk-...",
  "url": "https://mon-fournisseur.com/api-keys"
}
```

---

## Upgrade et maintenance

### Changer de modèle LLM sans tout reconstruire

```bash
# Lister les modèles disponibles
docker exec lisa_llm ollama list

# Télécharger un nouveau modèle
docker exec lisa_llm ollama pull mistral

# Changer le modèle actif (persisté dans la config)
curl -X POST http://localhost:8001/config \
     -H "Content-Type: application/json" \
     -d '{"llm_model": "mistral"}'
```

### Mettre à jour une image Docker individuelle

```bash
cd ~/ai-stack

# Mettre à jour un service spécifique (ex: Ollama)
docker compose pull llm
docker compose up -d --no-deps llm

# Mettre à jour tous les services
docker compose pull
docker compose up -d
```

### Reconfigurer L.I.S.A. (changer domaine, activer RAG...)

```bash
bash ~/ai-stack/00_config.sh --reconfigure
```

Relance le questionnaire complet, regénère `lisa.conf`, `.env.gpg`, et les fichiers Docker.

### Activer/désactiver la recherche web

```bash
# Via API (utilisé par le HUD)
curl -X POST http://localhost:8001/config \
     -H "Content-Type: application/json" \
     -d '{"web_search": true}'

# Via Docker directement
docker compose start search   # activer
docker compose stop search    # désactiver
```

### Voir les logs

```bash
# Log d'installation complet
cat ~/ai-stack/lisa_install.log

# Logs d'un service en temps réel
docker compose -f ~/ai-stack/docker-compose.yml logs -f llm
docker compose -f ~/ai-stack/docker-compose.yml logs -f api

# Tous les services
docker compose -f ~/ai-stack/docker-compose.yml logs -f
```

### État de la stack

```bash
# État rapide
curl -s http://localhost:8001/status | jq

# État Docker
docker compose -f ~/ai-stack/docker-compose.yml ps
```

### Désinstallation propre

```bash
cd ~/ai-stack
docker compose down --volumes --remove-orphans
docker images --filter "label=lisa.stack=true" -q | xargs docker rmi -f
rm -rf ~/ai-stack
# Suppression règles UFW L.I.S.A.
sudo ufw delete allow 80/tcp
sudo ufw delete allow 443/tcp
# Suppression entrée .bashrc
sed -i '/LISA_AUTO_RESUME/,/^fi$/d' ~/.bashrc
```

---

## Le HUD L.I.S.A.

> Cette section documente la vision du HUD. Le code n'est pas encore écrit.

Le HUD est une interface bureau non intrusive développée en **Tauri v2**. Il se présente sous forme d'une **orbe interactive** positionnée sur le bureau, qui sert à la fois d'indicateur d'état et de point d'accès à l'assistant.

### Comportement de l'orbe

- **Visible** par défaut, positionnée en coin d'écran
- **Se masque automatiquement** lors de la détection d'activité plein écran (jeux, vidéos, présentations)
- **Rappelable** à tout moment par commande vocale ou raccourci systray
- **Indicateur d'état** : couleur et animation de l'orbe reflètent l'état des services (LLM actif, recherche web on/off, erreur...)
- **Extensible** : l'orbe déploie des widgets indépendants (météo, domotique, YouTube, WhatsApp, système...)

### Widgets prévus

Chaque widget est une application web indépendante, chargée à la demande :
- Météo (OpenWeatherMap, Météo France)
- Domotique (Home Assistant, Jeedom, Philips Hue)
- Infos système (CPU, RAM, température)
- YouTube, WhatsApp (WebView)
- Calendrier (Google Calendar, Microsoft)

### Compatibilité OS prévue

| Plateforme | Stack IA | HUD Tauri |
|-----------|----------|-----------|
| Linux | ✅ Requis | ✅ V1 |
| Windows | ❌ Non supporté | ✅ V2 |
| macOS | ❌ Non supporté | ✅ V2 |
| Android | ❌ | 🔜 Futur |
| iOS | ❌ | 🔜 Futur |

### Ce que le HUD appelle sur l'API

Le HUD communique exclusivement via l'API L.I.S.A. Pour intégrer le HUD à votre stack :
- URL de base configurable dans le HUD : `http://localhost:8001` (local) ou `https://api.votre-domaine` (distant)
- Authentification via token Bearer si Authelia est activé
- Polling `/status` toutes les 10s pour l'état de l'orbe
- Webhook entrant sur `/config` pour les toggles (web search, modèle...)

### Gestion des clés API via le HUD

Le HUD intégrera un panneau de gestion des clés API permettant à l'utilisateur d'ajouter, modifier ou supprimer des intégrations sans toucher au terminal. Ces modifications seront transmises à l'API qui mettra à jour `~/ai-stack/.env.gpg` de façon sécurisée.

---

## Roadmap

### V1 (actuelle) — Stack IA

- [x] Installation automatisée Linux x86_64 / ARM64
- [x] LLM local (Ollama) + sélection modèle selon RAM
- [x] STT local (Whisper.cpp)
- [x] TTS local (Piper)
- [x] RAG local (Qdrant)
- [x] Recherche web on/off (SearXNG)
- [x] API orchestrateur + endpoints HUD
- [x] Reverse proxy Caddy + TLS automatique
- [x] DuckDNS DDNS automatique
- [x] Authelia (authentification externe)
- [x] Chiffrement GPG des secrets
- [x] Pare-feu UFW automatique
- [x] Reprise après interruption (état persistant)

### V2 — HUD Linux

- [ ] Orbe Tauri v2 (Linux)
- [ ] Widgets météo, domotique, système
- [ ] Gestion clés API via interface
- [ ] Chat vocal complet (STT → LLM → TTS)
- [ ] Détection activité écran (masquage auto)

### V3 — Portabilité

- [ ] HUD Windows et macOS
- [ ] Connexion HUD distant (stack sur serveur, HUD sur laptop)
- [ ] Android et iOS (roadmap longue)

---

## Modèle économique

**La stack L.I.S.A. est gratuite et open source.**
Scripts d'installation, Dockerfiles, configuration réseau, API — tout est disponible librement.

**Le HUD L.I.S.A. sera payant.**
Interface bureau Tauri, widgets, gestion clés API, mises à jour — distribué sous licence commerciale.

La séparation est claire : si vous voulez juste une IA locale avec une API, la stack suffit et ne coûte rien. Le HUD est pour ceux qui veulent une expérience bureau complète et intégrée.

---

*README généré pour L.I.S.A. v1.0.0 — mise à jour : voir CHANGELOG.md*
