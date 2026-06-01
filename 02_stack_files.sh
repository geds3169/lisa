#!/bin/bash
# ===================================================================================
# L.I.S.A — 02_stack_files.sh
# Génération des Dockerfiles et docker-compose depuis lisa.conf
# ===================================================================================

RED="\033[1;31m"
GREEN="\033[1;32m"
YELLOW="\033[1;33m"
BLUE="\033[1;34m"
CYAN="\033[1;36m"
RESET="\033[0m"

info()    { echo -e "${BLUE}[INFO]${RESET} $1"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET} $1"; }
error()   { echo -e "${RED}[ERROR]${RESET} $1"; }
success() { echo -e "${GREEN}[OK]${RESET} $1"; }
section() { echo -e "\n${CYAN}━━━ $1 ━━━${RESET}"; }

STACK_DIR="$HOME/ai-stack"
CONF_FILE="$STACK_DIR/lisa.conf"
STATE_FILE="$STACK_DIR/.lisa_state"
LOG_FILE="$STACK_DIR/lisa_install.log"

exec >> "$LOG_FILE" 2>&1

# --- Vérifications ---
[ ! -f "$CONF_FILE" ] && { error "lisa.conf introuvable."; exit 1; }
source "$CONF_FILE"

CURRENT_STATE=$(cat "$STATE_FILE" 2>/dev/null)
if [ "$CURRENT_STATE" = "FILES_DONE" ] || [ "$CURRENT_STATE" = "NETWORK_DONE" ] || [ "$CURRENT_STATE" = "STACK_DONE" ]; then
    info "Fichiers déjà générés (état: $CURRENT_STATE). Passage à l'étape suivante."
    exec bash "$STACK_DIR/03_run_stack.sh"
fi

# --- Keepalive sudo ---
_get_pass() { openssl enc -d -aes-256-cbc -pbkdf2 -pass pass:"$(cat "$STACK_DIR/.lisa_pass.key")" -in "$STACK_DIR/.lisa_pass.gpg" 2>/dev/null; }
_sudo() { echo "$(_get_pass)" | sudo -S "$@" 2>/dev/null; }
(while [ -f "$STACK_DIR/.lisa_pass.key" ]; do _sudo -v &>/dev/null; sleep 240; done) &
SUDO_KA_PID=$!

# --- Trap ---
# ===================================================================================
# TRAP — nettoyage centralisé sur échec ou interruption
# ===================================================================================
_trap_cleanup() {
    local EXIT_CODE=$?
    [ "$EXIT_CODE" -eq 0 ] && return
    echo ""
    echo -e "\033[1;31m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m"
    echo -e "\033[1;31m  L.I.S.A. — Interruption détectée\033[0m"
    echo -e "\033[1;31m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\033[0m"
    # Arrêt keepalive et inhibit
    [ -f "$STACK_DIR/.sudo_keepalive.pid" ] && kill "$(cat $STACK_DIR/.sudo_keepalive.pid)" 2>/dev/null
    kill "$INHIBIT_PID" 2>/dev/null || true
    # Lancement nettoyage centralisé
    if [ -f "$STACK_DIR/lisa_cleanup.sh" ]; then
        bash "$STACK_DIR/lisa_cleanup.sh" "échec ou interruption"
    else
        rm -f "$STACK_DIR/.lisa_pass.gpg" "$STACK_DIR/.lisa_pass.key" "$STACK_DIR/.env.plain"
        rm -rf "$STACK_DIR"
    fi
    exit 1
}
trap '_trap_cleanup' EXIT
trap 'exit 1' INT TERM

# ===================================================================================
# CRÉATION DES RÉPERTOIRES
# ===================================================================================
TRACE_FILE="$HOME/.lisa_trace"
_trace() { grep -qxF "${1}|${2}" "$TRACE_FILE" 2>/dev/null || echo "${1}|${2}" >> "$TRACE_FILE"; }

section "Création des répertoires"

mkdir -p "$STACK_DIR"/{api,llm,stt,tts}
_trace "dir" "$STACK_DIR/api"
_trace "dir" "$STACK_DIR/llm"
_trace "dir" "$STACK_DIR/stt"
_trace "dir" "$STACK_DIR/tts"
[ "$RAG_ENABLED" = "true" ] && mkdir -p "$STACK_DIR/rag"
[ "$WEB_SEARCH_ENABLED" = "true" ] && mkdir -p "$STACK_DIR/search"
[ "$EXPOSE_INTERNET" = "true" ] && mkdir -p "$STACK_DIR/caddy" "$STACK_DIR/authelia"
success "Répertoires créés."

# ===================================================================================
# DOCKERFILE LLM (Ollama)
# ===================================================================================
section "Dockerfile LLM"

# Adaptation ARM64 : même image, mais platform explicite
cat > "$STACK_DIR/llm/Dockerfile" << EOF
FROM --platform=${PLATFORM} ollama/ollama:latest
LABEL lisa.stack="true"
EXPOSE 11434
CMD ["ollama", "serve"]
EOF
success "Dockerfile LLM généré (platform: $PLATFORM)"

# ===================================================================================
# DOCKERFILE STT (Whisper.cpp)
# ===================================================================================
section "Dockerfile STT"

# ARM64 : on compile from source avec les flags appropriés
if [ "$ARCH" = "aarch64" ] || [ "$ARCH" = "arm64" ]; then
    cat > "$STACK_DIR/stt/Dockerfile" << 'EOF'
FROM --platform=linux/arm64 ubuntu:22.04
LABEL lisa.stack="true"
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y \
    git build-essential cmake wget ffmpeg python3 python3-pip \
    libopenblas-dev && rm -rf /var/lib/apt/lists/*
WORKDIR /app
RUN git clone https://github.com/ggerganov/whisper.cpp .
RUN make -j$(nproc) WHISPER_OPENBLAS=1
RUN bash ./models/download-ggml-model.sh base
EXPOSE 8080
CMD ["./server", "-m", "models/ggml-base.bin", "--host", "0.0.0.0", "--port", "8080"]
EOF
else
    cat > "$STACK_DIR/stt/Dockerfile" << 'EOF'
FROM --platform=linux/amd64 ubuntu:22.04
LABEL lisa.stack="true"
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y \
    git build-essential cmake wget ffmpeg && rm -rf /var/lib/apt/lists/*
WORKDIR /app
RUN git clone https://github.com/ggerganov/whisper.cpp .
RUN make -j$(nproc)
RUN bash ./models/download-ggml-model.sh base
EXPOSE 8080
CMD ["./server", "-m", "models/ggml-base.bin", "--host", "0.0.0.0", "--port", "8080"]
EOF
fi
success "Dockerfile STT généré."

# ===================================================================================
# DOCKERFILE TTS (Piper)
# ===================================================================================
section "Dockerfile TTS"

cat > "$STACK_DIR/tts/Dockerfile" << EOF
FROM --platform=${PLATFORM} python:3.11-slim
LABEL lisa.stack="true"
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y wget sox libsndfile1 && rm -rf /var/lib/apt/lists/*
RUN pip install --no-cache-dir piper-tts flask
WORKDIR /app
COPY tts_server.py .
EXPOSE 5500
CMD ["python3", "tts_server.py"]
EOF

cat > "$STACK_DIR/tts/tts_server.py" << 'PYEOF'
from flask import Flask, request, Response
import subprocess, tempfile, os
app = Flask(__name__)

@app.route("/synthesize", methods=["POST"])
def synthesize():
    text = request.json.get("text", "")
    voice = request.json.get("voice", "fr_FR-siwis-medium")
    with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as f:
        out_path = f.name
    subprocess.run(
        ["piper", "--model", f"/app/voices/{voice}.onnx", "--output_file", out_path],
        input=text.encode(), check=True
    )
    with open(out_path, "rb") as f:
        data = f.read()
    os.unlink(out_path)
    return Response(data, mimetype="audio/wav")

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5500)
PYEOF
success "Dockerfile TTS généré."

# ===================================================================================
# DOCKERFILE RAG (Qdrant)
# ===================================================================================
if [ "$RAG_ENABLED" = "true" ] && [ "$RAG_PROVIDER" = "local" ]; then
    section "Dockerfile RAG"
    cat > "$STACK_DIR/rag/Dockerfile" << EOF
FROM --platform=${PLATFORM} qdrant/qdrant:latest
LABEL lisa.stack="true"
EXPOSE 6333
EOF
    success "Dockerfile RAG (Qdrant) généré."
fi

# ===================================================================================
# DOCKERFILE API (FastAPI orchestrateur)
# ===================================================================================
section "Dockerfile API"

cat > "$STACK_DIR/api/Dockerfile" << EOF
FROM --platform=${PLATFORM} python:3.11-slim
LABEL lisa.stack="true"
RUN pip install --no-cache-dir fastapi uvicorn requests python-dotenv httpx
WORKDIR /app
COPY main.py .
EXPOSE 8000
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000"]
EOF

# main.py — lu depuis lisa.conf, endpoints HUD complets
cat > "$STACK_DIR/api/main.py" << PYEOF
from fastapi import FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel
from typing import Optional
import requests, os, subprocess

app = FastAPI(title="L.I.S.A. API", version="1.0.0")

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)

# --- Config depuis variables d'environnement (injectées par docker compose) ---
OLLAMA_URL        = os.getenv("OLLAMA_URL", "http://llm:11434")
STT_URL           = os.getenv("STT_URL", "http://stt:8080")
TTS_URL           = os.getenv("TTS_URL", "http://tts:5500")
RAG_URL           = os.getenv("RAG_URL", "http://rag:6333")
SEARXNG_URL       = os.getenv("SEARXNG_URL", "http://search:8888")
LLM_MODEL         = os.getenv("LLM_MODEL", "${LLM_MODEL_LOCAL}")
WEB_SEARCH_ON     = os.getenv("WEB_SEARCH_DEFAULT", "false").lower() == "true"

# État mutable (contrôlable via /config)
_state = {
    "web_search": WEB_SEARCH_ON,
    "llm_model": LLM_MODEL,
    "llm_provider": "${LLM_PROVIDER}",
    "stt_provider": "${STT_PROVIDER}",
    "tts_provider": "${TTS_PROVIDER}",
    "rag_enabled": "${RAG_ENABLED}".lower() == "true",
}

# =============================================================
# MODÈLES
# =============================================================
class ChatRequest(BaseModel):
    prompt: str
    model: Optional[str] = None
    stream: Optional[bool] = False

class ConfigUpdate(BaseModel):
    web_search: Optional[bool] = None
    llm_model: Optional[str] = None

class SearchRequest(BaseModel):
    query: str

class TTSRequest(BaseModel):
    text: str
    voice: Optional[str] = "fr_FR-siwis-medium"

# =============================================================
# ENDPOINTS CORE
# =============================================================

@app.get("/")
def root():
    return {"service": "L.I.S.A. API", "version": "1.0.0", "status": "operational"}

@app.get("/status")
def status():
    """État complet de tous les microservices — utilisé par le HUD."""
    services = {}

    # LLM
    try:
        r = requests.get(f"{OLLAMA_URL}/api/tags", timeout=3)
        models = [m["name"] for m in r.json().get("models", [])]
        services["llm"] = {"status": "up", "url": OLLAMA_URL, "models": models, "active": _state["llm_model"]}
    except:
        services["llm"] = {"status": "down", "url": OLLAMA_URL}

    # STT
    try:
        requests.get(f"{STT_URL}/", timeout=3)
        services["stt"] = {"status": "up", "url": STT_URL, "provider": _state["stt_provider"]}
    except:
        services["stt"] = {"status": "down", "url": STT_URL}

    # TTS
    try:
        requests.get(f"{TTS_URL}/", timeout=3)
        services["tts"] = {"status": "up", "url": TTS_URL, "provider": _state["tts_provider"]}
    except:
        services["tts"] = {"status": "down", "url": TTS_URL}

    # RAG
    if _state["rag_enabled"]:
        try:
            requests.get(f"{RAG_URL}/healthz", timeout=3)
            services["rag"] = {"status": "up", "url": RAG_URL}
        except:
            services["rag"] = {"status": "down", "url": RAG_URL}

    # SearXNG
    try:
        requests.get(f"{SEARXNG_URL}/", timeout=3)
        services["search"] = {"status": "up", "enabled": _state["web_search"]}
    except:
        services["search"] = {"status": "down", "enabled": False}

    return {"services": services, "config": _state}

@app.get("/config")
def get_config():
    """Configuration courante — lecture HUD."""
    return _state

@app.post("/config")
def update_config(update: ConfigUpdate):
    """Mise à jour configuration à chaud — écriture HUD (web search on/off, modèle...)."""
    if update.web_search is not None:
        _state["web_search"] = update.web_search
        action = "démarrée" if update.web_search else "arrêtée"
        try:
            cmd = "start" if update.web_search else "stop"
            subprocess.run(
                ["docker", "compose", "-f", "/stack/docker-compose.yml", cmd, "search"],
                timeout=10, capture_output=True
            )
        except Exception as e:
            pass
    if update.llm_model is not None:
        _state["llm_model"] = update.llm_model
    return {"status": "updated", "config": _state}

@app.post("/chat")
def chat(req: ChatRequest):
    """Chat LLM — local Ollama ou API externe selon config."""
    model = req.model or _state["llm_model"]
    context = ""

    # Enrichissement RAG si activé
    if _state["rag_enabled"]:
        try:
            rag_r = requests.post(
                f"{RAG_URL}/collections/lisa/points/search",
                json={"vector": [0]*384, "limit": 3, "with_payload": True},
                timeout=3
            )
            hits = rag_r.json().get("result", [])
            if hits:
                context = "\n".join([h["payload"].get("text","") for h in hits])
        except:
            pass

    # Enrichissement web si activé
    if _state["web_search"]:
        try:
            s_r = requests.get(
                f"{SEARXNG_URL}/search",
                params={"q": req.prompt, "format": "json"},
                timeout=5
            )
            results = s_r.json().get("results", [])[:3]
            if results:
                context += "\n" + "\n".join([r.get("content","") for r in results])
        except:
            pass

    full_prompt = f"{context}\n\n{req.prompt}" if context else req.prompt

    try:
        r = requests.post(
            f"{OLLAMA_URL}/api/generate",
            json={"model": model, "prompt": full_prompt, "stream": False},
            timeout=120
        )
        return r.json()
    except Exception as e:
        raise HTTPException(status_code=503, detail=f"LLM indisponible: {str(e)}")

@app.post("/search")
def search(req: SearchRequest):
    """Recherche web via SearXNG — accessible HUD."""
    if not _state["web_search"]:
        raise HTTPException(status_code=403, detail="Recherche web désactivée.")
    try:
        r = requests.get(
            f"{SEARXNG_URL}/search",
            params={"q": req.query, "format": "json"},
            timeout=10
        )
        return r.json()
    except Exception as e:
        raise HTTPException(status_code=503, detail=f"SearXNG indisponible: {str(e)}")

@app.post("/tts")
def tts(req: TTSRequest):
    """Synthèse vocale — retourne l'URL du fichier audio généré."""
    try:
        r = requests.post(
            f"{TTS_URL}/synthesize",
            json={"text": req.text, "voice": req.voice},
            timeout=30
        )
        return {"status": "ok", "audio_url": f"{TTS_URL}/synthesize"}
    except Exception as e:
        raise HTTPException(status_code=503, detail=f"TTS indisponible: {str(e)}")
PYEOF

success "Dockerfile API et main.py générés."

# ===================================================================================
# DOCKER COMPOSE
# ===================================================================================
section "Génération docker-compose.yml"

# Calcul des mem_limit selon profil RAM
case "$RAM_PROFILE" in
    low)    MEM_LLM="2g" ; MEM_STT="768m" ; MEM_TTS="512m" ; MEM_API="256m" ; MEM_RAG="512m" ;;
    medium) MEM_LLM="4g" ; MEM_STT="1g"   ; MEM_TTS="512m" ; MEM_API="512m" ; MEM_RAG="1g"   ;;
    high)   MEM_LLM="8g" ; MEM_STT="2g"   ; MEM_TTS="1g"   ; MEM_API="512m" ; MEM_RAG="2g"   ;;
esac

# Construction du compose dynamiquement
{
cat << COMPOSEEOF
# L.I.S.A. — docker-compose.yml — généré le $(date '+%Y-%m-%d %H:%M:%S')
# NE PAS MODIFIER MANUELLEMENT — régénéré par 02_stack_files.sh

networks:
  lisa_internal:
    driver: bridge
    internal: true
  lisa_external:
    driver: bridge

volumes:
  ollama_data:
  qdrant_data:
  searxng_data:

services:

  llm:
    build:
      context: ./llm
      platforms: ["${PLATFORM}"]
    image: lisa/llm:latest
    container_name: lisa_llm
    networks:
      - lisa_internal
    volumes:
      - ollama_data:/root/.ollama
    restart: unless-stopped
    mem_limit: ${MEM_LLM}
    environment:
      - OLLAMA_HOST=0.0.0.0
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:11434/api/tags"]
      interval: 30s
      timeout: 10s
      retries: 5
      start_period: 60s

  stt:
    build:
      context: ./stt
      platforms: ["${PLATFORM}"]
    image: lisa/stt:latest
    container_name: lisa_stt
    networks:
      - lisa_internal
    restart: unless-stopped
    mem_limit: ${MEM_STT}
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:8080/"]
      interval: 30s
      timeout: 10s
      retries: 5
      start_period: 120s

  tts:
    build:
      context: ./tts
      platforms: ["${PLATFORM}"]
    image: lisa/tts:latest
    container_name: lisa_tts
    networks:
      - lisa_internal
    restart: unless-stopped
    mem_limit: ${MEM_TTS}

  api:
    build:
      context: ./api
      platforms: ["${PLATFORM}"]
    image: lisa/api:latest
    container_name: lisa_api
    networks:
      - lisa_internal
      - lisa_external
    depends_on:
      llm:
        condition: service_healthy
    restart: unless-stopped
    mem_limit: ${MEM_API}
    environment:
      - OLLAMA_URL=http://llm:11434
      - STT_URL=http://stt:8080
      - TTS_URL=http://tts:5500
      - RAG_URL=http://rag:6333
      - SEARXNG_URL=http://search:8888
      - LLM_MODEL=${LLM_MODEL_LOCAL}
      - WEB_SEARCH_DEFAULT=${WEB_SEARCH_DEFAULT}
COMPOSEEOF

# Injection secrets Docker si .env.gpg existe
if [ -f "$STACK_DIR/.env.gpg" ]; then
cat << 'SECRETEOF'
    secrets:
      - lisa_env
SECRETEOF
fi

cat << COMPOSEEOF2

COMPOSEEOF2

# Service RAG conditionnel
if [ "$RAG_ENABLED" = "true" ] && [ "$RAG_PROVIDER" = "local" ]; then
cat << RAGEOF

  rag:
    build:
      context: ./rag
      platforms: ["${PLATFORM}"]
    image: lisa/rag:latest
    container_name: lisa_rag
    networks:
      - lisa_internal
    volumes:
      - qdrant_data:/qdrant/storage
    restart: unless-stopped
    mem_limit: ${MEM_RAG}
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:6333/healthz"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 30s
RAGEOF
fi

# Service SearXNG conditionnel
if [ "$WEB_SEARCH_ENABLED" = "true" ]; then
cat << SEARCHEOF

  search:
    image: searxng/searxng:latest
    container_name: lisa_search
    networks:
      - lisa_internal
    volumes:
      - searxng_data:/etc/searxng
    restart: unless-stopped
    mem_limit: 512m
    environment:
      - SEARXNG_BASE_URL=http://search:8888
SEARCHEOF
fi

# Service Caddy conditionnel
if [ "$EXPOSE_INTERNET" = "true" ]; then
cat << CADDYEOF

  caddy:
    image: caddy:alpine
    container_name: lisa_caddy
    networks:
      - lisa_internal
      - lisa_external
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - ./caddy/Caddyfile:/etc/caddy/Caddyfile:ro
      - caddy_data:/data
      - caddy_config:/config
    restart: unless-stopped
    mem_limit: 256m
    depends_on:
      - api
CADDYEOF
fi

# Service Authelia conditionnel
if [ "$AUTHELIA_ENABLED" = "true" ]; then
cat << AUTHELIAEOF

  authelia:
    image: authelia/authelia:latest
    container_name: lisa_authelia
    networks:
      - lisa_internal
    volumes:
      - ./authelia:/config
    restart: unless-stopped
    mem_limit: 256m
AUTHELIAEOF
fi

# Volumes supplémentaires si Caddy
if [ "$EXPOSE_INTERNET" = "true" ]; then
cat << VOLEOF

  # volumes supplémentaires Caddy (ajoutés à la section volumes globale)
  # caddy_data et caddy_config sont déclarés dans la section volumes ci-dessus
VOLEOF
fi

# Secrets Docker
if [ -f "$STACK_DIR/.env.gpg" ]; then
cat << SECRETSEOF

secrets:
  lisa_env:
    file: ./.env.gpg
SECRETSEOF
fi

} > "$STACK_DIR/docker-compose.yml"

# Ajout volumes caddy si exposition internet
if [ "$EXPOSE_INTERNET" = "true" ]; then
    sed -i '/^volumes:/a\  caddy_data:\n  caddy_config:' "$STACK_DIR/docker-compose.yml"
fi

success "docker-compose.yml généré."
_trace "file" "$STACK_DIR/docker-compose.yml"

# ===================================================================================
# MARQUEUR D'ÉTAT
# ===================================================================================
echo "FILES_DONE" > "$STATE_FILE"
success "Étape génération fichiers terminée."

kill "$SUDO_KA_PID" 2>/dev/null
sleep 1
exec bash "$STACK_DIR/03_run_stack.sh"
