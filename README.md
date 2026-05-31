# L.I.S.A. — Local Intelligent System Assistant

> Votre IA personnelle, chez vous, sans compromis.

---

## Tu rêves d'un assistant IA vraiment personnel ?

Pas un abonnement. Pas une API qui envoie tes conversations à une entreprise. Pas une dépendance à un serveur distant qui tombe en panne le jour où tu en as besoin.

**L.I.S.A.** s'installe sur ta machine Linux et tourne entièrement chez toi. Tes conversations restent chez toi. Tes documents restent chez toi. Même sans internet, L.I.S.A. répond.

Un assistant vocal et textuel complet, open source, qui comprend ce que tu dis, te répond à voix haute, retient ce que tu lui montres, et cherche sur le web quand tu lui demandes. Accessible depuis ton bureau ou depuis internet, protégé par un vrai système d'authentification.

**La stack est gratuite. Le HUD (interface bureau) sera payant.**

---

<details>
<summary><strong>Table des matières</strong></summary>

- [Installation rapide](#installation-rapide)
- [Ce qui est installé](#ce-qui-est-installé)
- [Profils matériels](#profils-matériels)
- [Architecture de la stack](#architecture-de-la-stack)
- [L'installateur — interface graphique en terminal](#linstallateur--interface-graphique-en-terminal)
- [Configuration réseau](#configuration-réseau)
- [Sécurité](#sécurité)
- [Endpoints HUD — référence API](#endpoints-hud--référence-api)
- [Gestion des clés API](#gestion-des-clés-api)
- [Arborescence du repository](#arborescence-du-repository)
- [Upgrade et maintenance](#upgrade-et-maintenance)
- [Le HUD L.I.S.A.](#le-hud-lisa)
- [Compatibilité](#compatibilité)
- [Roadmap](#roadmap)
- [Modèle économique](#modèle-économique)

</details>

---

## Installation rapide

### Option 1 — Téléchargement depuis la release

1. Télécharge `install.sh` depuis la page [Releases](https://github.com/geds3169/lisa/releases)
2. Ouvre un terminal dans le dossier de téléchargement
3. Lance :

```bash
bash install.sh
```

### Option 2 — Directement via curl

```bash
curl -fsSL https://raw.githubusercontent.com/geds3169/lisa/main/install.sh -o install.sh && bash install.sh
```

C'est tout. Le script télécharge le reste, détecte ta machine, et te guide à travers une interface graphique en terminal.

**Prérequis :** Linux Ubuntu 22.04/24.04 ou Debian 11/12 — 4 GB RAM minimum — 20 GB disque libre.

---

## Ce qui est installé

L.I.S.A. installe automatiquement une stack complète. Rien à choisir, tout est adapté à ta machine.

| Service | Rôle | Technologie |
|---------|------|-------------|
| **LLM** | Cerveau de L.I.S.A. — comprend et répond | Ollama |
| **STT** | Reconnaît ta voix | Whisper.cpp |
| **TTS** | Parle à voix haute | Piper |
| **RAG** | Retient tes documents | Qdrant |
| **Recherche web** | Cherche sur internet à la demande | SearXNG |
| **API** | Orchestrateur — point d'entrée du HUD | FastAPI |
| **Reverse proxy** | Accès externe sécurisé + TLS auto | Caddy |
| **Authentification** | Protège l'accès depuis internet | Authelia |
| **DDNS** | Met à jour ton IP publique automatiquement | DuckDNS container |

Tout tourne dans des containers Docker isolés. Seuls le reverse proxy et l'API sont exposés. Ollama, Whisper, Piper, Qdrant et SearXNG ne sont jamais accessibles directement depuis l'extérieur.

---

## Profils matériels

L.I.S.A. détecte automatiquement ta machine et adapte la configuration. Tu ne choisis pas le modèle — il est sélectionné pour toi selon ce que ta machine peut faire confortablement.

### Profil léger — 4 à 8 GB RAM

```
Modèle LLM  : phi3 (3.8B)
Mémoire docs: désactivée par défaut (activable via HUD)
RAM allouée : ~3.5 GB
Disque      : 15 GB minimum
```

Convient pour un usage conversationnel simple. Les réponses sont correctes, la vitesse dépend du CPU.

### Profil standard — 8 à 16 GB RAM

```
Modèle LLM  : llama3.2 (3B)
Mémoire docs: activée
RAM allouée : ~7 GB
Disque      : 25 GB minimum
```

Bon équilibre vitesse/qualité pour un usage quotidien.

### Profil élevé — 16 GB RAM et plus

```
Modèle LLM  : llama3.1:8b
Mémoire docs: activée
GPU NVIDIA  : accélération automatique si détecté
RAM allouée : ~10 GB
Disque      : 40 GB minimum
```

Qualité de réponse élevée, adapté à un usage intensif ou professionnel.

> **Note ARM64 :** Raspberry Pi 5 (8 GB), serveurs ARM, Apple Silicon via VM — supportés. Certaines images sont compilées from source, l'installation est plus longue.

---

## Architecture de la stack

```
┌─────────────────────────────────────────────────────────────┐
│                      MACHINE LINUX                          │
│                                                             │
│  ┌──────────────────────────────────────────────────────┐   │
│  │              Réseau Docker interne                   │   │
│  │           (isolé — invisible depuis l'extérieur)     │   │
│  │                                                      │   │
│  │  ┌──────────┐  ┌──────────┐  ┌──────────┐           │   │
│  │  │   LLM    │  │   STT    │  │   TTS    │           │   │
│  │  │ (Ollama) │  │(Whisper) │  │ (Piper)  │           │   │
│  │  └────┬─────┘  └────┬─────┘  └────┬─────┘           │   │
│  │       └─────────────┴─────────────┘                  │   │
│  │                     │                                 │   │
│  │             ┌────────┴────────┐                       │   │
│  │             │   API FastAPI   │◄── HUD L.I.S.A.       │   │
│  │             │  orchestrateur  │                       │   │
│  │             └────────┬────────┘                       │   │
│  │                      │                                │   │
│  │  ┌──────────┐  ┌──────┴───────┐                       │   │
│  │  │   RAG    │  │   SearXNG   │                       │   │
│  │  │ (Qdrant) │  │ (optionnel) │                       │   │
│  │  └──────────┘  └─────────────┘                       │   │
│  └──────────────────────┬───────────────────────────────┘   │
│                         │                                    │
│            ┌────────────┴────────────┐                       │
│            │   Caddy (reverse proxy) │                       │
│            │   TLS automatique       │                       │
│            │   Authelia (auth)       │                       │
│            └────────────┬────────────┘                       │
└─────────────────────────┼────────────────────────────────────┘
                          │ HTTPS
                   ┌──────┴───────┐
                   │   Internet   │
                   │  (optionnel) │
                   └──────────────┘
```

---

## L'installateur — interface graphique en terminal

L.I.S.A. utilise **whiptail**, la même technologie que l'installateur Debian, pour afficher une interface graphique dans le terminal. Pas besoin d'interface graphique, ça fonctionne en SSH, sur un serveur headless, sur un Raspberry Pi.

Si whiptail n'est pas disponible, l'installateur bascule automatiquement en mode texte coloré.

### Écran 1 — Profil machine

L'installateur détecte ta machine et affiche ce qui sera installé. Aucune décision à prendre sur les modèles.

```
┌─────────────────────────────────┐
│         Votre machine           │
├─────────────────────────────────┤
│ Profil détecté : Standard       │
│                                 │
│   CPU  : 4 cœurs                │
│   RAM  : 12 GB                  │
│   GPU  : Aucun — mode CPU       │
│                                 │
│ L.I.S.A. sera configurée        │
│ automatiquement avec les        │
│ modèles adaptés à votre         │
│ machine. Aucun remplacement     │
│ de modèle possible ou conseillé │
│                                 │
│         < OK >                  │
└─────────────────────────────────┘
```

### Écran 2 — Services en ligne (optionnel)

```
┌─────────────────────────────────┐
│       Services en ligne         │
├─────────────────────────────────┤
│ Avez-vous des comptes chez des  │
│ services d'IA en ligne ?        │
│ (OpenAI, Anthropic, Mistral...) │
│                                 │
│ Si oui, L.I.S.A. pourra les     │
│ utiliser en complément.         │
│                                 │
│   < Oui >        < Non >        │
└─────────────────────────────────┘
```

### Écran 3 — Récapitulatif avant installation

```
┌─────────────────────────────────────────────┐
│  Récapitulatif — Votre configuration L.I.S.A│
├─────────────────────────────────────────────┤
│ Profil machine   : Standard (12GB RAM)      │
│ Modèle IA        : llama3.2                 │
│                                             │
│ Service IA ext.  : Non                      │
│ Recherche web    : Active par défaut        │
│ Mémoire docs     : Active                   │
│                                             │
│ Accès internet   : Oui — DuckDNS           │
│   API : lisa-api-4827.duckdns.org          │
│ Protection login : Oui (admin)              │
│                                             │
│ Tout est correct ?                          │
│                                             │
│   < Oui >              < Non >             │
└─────────────────────────────────────────────┘
```

Si tu réponds Non, un menu te permet de corriger n'importe quel paramètre avant de lancer.

### Ce qui se passe après confirmation

```
install.sh
  └── 00_config.sh   Détection système, sudo, GPG
        └── 01_config.sh   Profil machine + 3 questions
              └── 02_config.sh   Réseau + récapitulatif + lisa.conf
                    └── 01_precheck_install.sh   Docker + UFW
                          └── 02_stack_files.sh   Dockerfiles + compose
                                └── 03_run_stack.sh   Build + démarrage
                                      └── 04_network.sh   Caddy + DNS (si internet)
```

Chaque étape écrit un marqueur d'état. Si l'installation est interrompue (coupure, redémarrage), elle reprend automatiquement là où elle s'était arrêtée.

---

## Configuration réseau

### Local uniquement

Aucune configuration nécessaire. L.I.S.A. est accessible sur `http://localhost:8001`.

### Accès depuis internet — Domaine personnel

Tu as un domaine (`mondomaine.fr`). Tu crées les enregistrements DNS de type A chez ton registrar, Caddy gère les certificats Let's Encrypt automatiquement.

```
lisa-api.mondomaine.fr
lisa-llm.mondomaine.fr
lisa-stt.mondomaine.fr
lisa-tts.mondomaine.fr
lisa-rag.mondomaine.fr
lisa-search.mondomaine.fr
```

### Accès depuis internet — DuckDNS (gratuit, sans domaine)

1. Crée un compte sur [duckdns.org](https://www.duckdns.org) avec Google
2. Crée 6 sous-domaines avec un suffixe numérique unique :

```
lisa-api-XXXX.duckdns.org
lisa-llm-XXXX.duckdns.org
lisa-stt-XXXX.duckdns.org
lisa-tts-XXXX.duckdns.org
lisa-rag-XXXX.duckdns.org
lisa-search-XXXX.duckdns.org
```

Remplace `XXXX` par un nombre à toi (ex: `4827`). Si le nom est déjà pris, essaie une autre combinaison — il n'existe pas de base centrale pour vérifier la disponibilité à l'avance.

Un container DDNS maintient ton IP à jour automatiquement, même après un redémarrage ou une coupure réseau.

> Si tu as un certificat SSL existant, consulte la section [Upgrade et maintenance](#upgrade-et-maintenance) pour l'ajouter manuellement dans le Caddyfile.

---

## Sécurité

### Réseau Docker isolé

Deux réseaux distincts :
- `lisa_internal` — réseau interne, aucun accès depuis l'extérieur. Ollama, Whisper, Piper, Qdrant, SearXNG y vivent.
- `lisa_external` — accès internet, uniquement pour Caddy, l'API et le container DDNS.

### Secrets chiffrés GPG

Toutes les clés API sont chiffrées avec AES-256 dans `~/ai-stack/.env.gpg`. La clé de chiffrement est dans `~/ai-stack/.env.key`. Pour les modifier :

```bash
# Déchiffrer
openssl enc -d -aes-256-cbc -pbkdf2 \
    -pass pass:$(cat ~/ai-stack/.env.key) \
    -in ~/ai-stack/.env.gpg > /tmp/lisa_env

# Modifier
nano /tmp/lisa_env

# Rechiffrer
openssl enc -aes-256-cbc -pbkdf2 \
    -pass pass:$(cat ~/ai-stack/.env.key) \
    -in /tmp/lisa_env -out ~/ai-stack/.env.gpg

# Nettoyer
rm /tmp/lisa_env
```

Le HUD L.I.S.A. permettra de modifier les clés via son interface graphique.

### Mot de passe éphémère

Pendant l'installation, ton mot de passe sudo est chiffré AES-256 dans un fichier temporaire, utilisé pour maintenir les droits actifs sans te le redemander. Il est supprimé automatiquement à la fin, en cas de Ctrl+C, ou en cas d'erreur.

### Pare-feu UFW

```
Mode local    : entrant bloqué sauf SSH + API sur 127.0.0.1
Mode internet : entrant bloqué sauf SSH + ports 80 et 443
```

### Authelia

Si tu actives l'exposition internet avec Authelia, tout accès externe passe par une page de login. 2FA TOTP activable manuellement dans `~/ai-stack/authelia/configuration.yml`.

---

## Endpoints HUD — référence API

Base URL locale : `http://localhost:8001`
Documentation Swagger : `http://localhost:8001/docs`

| Méthode | Endpoint | Description |
|---------|----------|-------------|
| `GET` | `/` | Ping |
| `GET` | `/status` | État de tous les services |
| `GET` | `/config` | Configuration courante |
| `POST` | `/config` | Modifier config à chaud |
| `POST` | `/chat` | Chat LLM |
| `POST` | `/search` | Recherche web |
| `POST` | `/tts` | Synthèse vocale |

**Exemple — activer/désactiver la recherche web :**
```bash
curl -X POST http://localhost:8001/config \
     -H "Content-Type: application/json" \
     -d '{"web_search": true}'
```

**Exemple — réponse `/status` :**
```json
{
  "services": {
    "llm":    { "status": "up", "active": "llama3.2" },
    "stt":    { "status": "up" },
    "tts":    { "status": "up" },
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

### Interactions HUD → API

```
HUD (Tauri)
  ├── GET  /status   → État services (couleur de l'orbe)
  ├── GET  /config   → État des boutons HUD
  ├── POST /config   → Toggle web search, changement modèle
  ├── POST /chat     → Message utilisateur
  ├── POST /tts      → Lecture vocale de la réponse
  └── POST /search   → Recherche web directe (widget)
```

---

## Gestion des clés API

### Ajouter une clé après installation

**Via terminal :**
```bash
# Déchiffrer
openssl enc -d -aes-256-cbc -pbkdf2 \
    -pass pass:$(cat ~/ai-stack/.env.key) \
    -in ~/ai-stack/.env.gpg > /tmp/lisa_env

# Modifier
nano /tmp/lisa_env

# Rechiffrer
openssl enc -aes-256-cbc -pbkdf2 \
    -pass pass:$(cat ~/ai-stack/.env.key) \
    -in /tmp/lisa_env -out ~/ai-stack/.env.gpg

# Nettoyer
rm /tmp/lisa_env
```

**Via le HUD L.I.S.A. (version payante) :** panneau dédié sans toucher au terminal.

Emplacement : `~/ai-stack/.env.gpg`

### Fournisseurs supportés

Le fichier `providers.json` liste tous les fournisseurs par catégorie :
`llm`, `stt`, `tts`, `rag`, `search`, `domotique`, `meteo`, `calendrier`, `notifications`.

Pour ajouter un fournisseur non listé :
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

## Arborescence du repository

```
lisa/
├── install.sh                  ← Seul fichier dans les Releases
│
├── 00_config.sh                ← Détection système + sudo + GPG
├── 01_config.sh                ← Profil machine + choix utilisateur
├── 02_config.sh                ← Réseau + récapitulatif + lisa.conf
├── 00_provider_select.sh       ← Sélection fournisseur API
├── 01_precheck_install.sh      ← Docker + UFW + groupe
├── 02_stack_files.sh           ← Dockerfiles + docker-compose
├── 03_run_stack.sh             ← Build + démarrage + health checks
├── 04_network.sh               ← Caddy + DuckDNS + Authelia
├── lisa_cleanup.sh             ← Nettoyage centralisé
│
├── providers.json              ← Base fournisseurs API
└── README.md

─── Généré à l'installation dans ~/ai-stack/ ──────────────────

~/ai-stack/
├── lisa.conf                   ← Config (sans secrets)
├── .env.gpg                    ← Secrets chiffrés GPG
├── .lisa_state                 ← Marqueur d'étape (reprise auto)
├── lisa_install.log            ← Log complet
├── docker-compose.yml          ← Généré dynamiquement
├── api/   llm/   stt/   tts/
├── rag/   search/
├── caddy/ authelia/
```

---

## Upgrade et maintenance

### Changer de modèle LLM (profil élevé uniquement)

```bash
docker exec lisa_llm ollama pull mistral
curl -X POST http://localhost:8001/config \
     -H "Content-Type: application/json" \
     -d '{"llm_model": "mistral"}'
```

### Mettre à jour un service

```bash
cd ~/ai-stack
docker compose pull llm
docker compose up -d --no-deps llm
```

### Reconfigurer L.I.S.A.

```bash
bash ~/ai-stack/00_config.sh --reconfigure
```

### Voir les logs

```bash
# Log d'installation
cat ~/ai-stack/lisa_install.log

# Logs d'un service en temps réel
docker compose -f ~/ai-stack/docker-compose.yml logs -f llm
```

### Ajouter un certificat SSL existant

Modifie `~/ai-stack/caddy/Caddyfile` :
```
api.mondomaine.fr {
    tls /etc/caddy/certs/cert.pem /etc/caddy/certs/key.pem
    reverse_proxy lisa_api:8000
}
```
Puis : `docker compose restart caddy`

### Désinstallation propre

```bash
cd ~/ai-stack && bash lisa_cleanup.sh "désinstallation manuelle"
```

---

## Le HUD L.I.S.A.

> Interface bureau en développement — non disponible actuellement.

Le HUD est une interface bureau développée en **Tauri v2**. Il se présente sous forme d'une **orbe interactive** sur le bureau — indicateur d'état, point d'accès à l'assistant, et conteneur de widgets.

**Comportement :**
- Visible en coin d'écran par défaut
- Se masque automatiquement en plein écran (jeux, vidéos, présentations)
- Rappelable par commande vocale ou raccourci systray
- Couleur et animation de l'orbe reflètent l'état des services

**Widgets prévus :** météo, domotique, infos système, YouTube, WhatsApp, calendrier.

**Ce que le HUD utilise sur l'API :** `GET /status` (état de l'orbe), `POST /config` (toggles), `POST /chat` (messages), `POST /tts` (réponses vocales).

**Gestion des clés API via le HUD :** panneau dédié pour ajouter, modifier ou supprimer des intégrations sans toucher au terminal — écriture directe dans `~/ai-stack/.env.gpg` via endpoint sécurisé.

---

## Compatibilité

### Stack IA — Linux obligatoire

| OS | Support |
|----|---------|
| Ubuntu 22.04 / 24.04 | ✅ Recommandé |
| Debian 11 / 12 | ✅ Supporté |
| Linux Mint, Pop!_OS | ✅ Supporté |
| Autres distributions | ⚠️ Non testé |
| Windows, macOS | ❌ Non supporté pour la stack |

### Architectures

| Architecture | Support | Notes |
|-------------|---------|-------|
| x86_64 (AMD64) | ✅ Complet | Configuration de référence |
| ARM64 (aarch64) | ✅ Supporté | Pi 5 (8GB min), serveurs ARM |
| x86 32 bits | ❌ | Docker et Ollama ne supportent plus |
| ARMv7 et moins | ❌ | Trop limité |

### HUD Tauri — multiplateforme

| Plateforme | Statut |
|-----------|--------|
| Linux | 🔜 V1 |
| Windows | 🔜 V2 |
| macOS | 🔜 V2 |
| Android / iOS | 🔜 Futur |

---

## Roadmap

**V1 — Stack IA (actuelle)**
- [x] Installation automatisée Linux x86_64 / ARM64
- [x] Interface graphique whiptail + fallback texte
- [x] Profils automatiques low / medium / high
- [x] LLM local (Ollama) + STT (Whisper) + TTS (Piper)
- [x] RAG local (Qdrant)
- [x] Recherche web (SearXNG)
- [x] API orchestrateur + endpoints HUD
- [x] Reverse proxy Caddy + TLS automatique
- [x] DuckDNS DDNS automatique
- [x] Authelia (authentification externe)
- [x] Chiffrement GPG des secrets
- [x] Pare-feu UFW automatique
- [x] Reprise après interruption

**V2 — HUD Linux**
- [ ] Orbe Tauri v2 (Linux)
- [ ] Widgets météo, domotique, système
- [ ] Gestion clés API via interface
- [ ] Chat vocal complet

**V3 — Portabilité**
- [ ] HUD Windows et macOS
- [ ] Connexion HUD distant
- [ ] Android et iOS

---

## Modèle économique

**La stack L.I.S.A. est gratuite et open source.**
Scripts, Dockerfiles, configuration réseau, API — tout est libre.

**Le HUD L.I.S.A. sera payant.**
Interface bureau Tauri, widgets, gestion clés API, mises à jour.

---

*L.I.S.A. v1.0.0 — [github.com/geds3169/lisa](https://github.com/geds3169/lisa)*
