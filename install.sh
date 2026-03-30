#!/usr/bin/env bash
set -Eeuo pipefail

export DEBIAN_FRONTEND=noninteractive

PERSIST_ROOT="/workspace/openclaw-stack"

OPENCLAW_HOME="$PERSIST_ROOT/.openclaw"
WORKSPACE_DIR="$PERSIST_ROOT/workspace"
LOG_DIR="$PERSIST_ROOT/logs"

OLLAMA_ROOT="$PERSIST_ROOT/ollama"
OLLAMA_MODELS_DIR="$OLLAMA_ROOT/models"
OLLAMA_TMP_DIR="$OLLAMA_ROOT/tmp"

CONFIG_FILE="$OPENCLAW_HOME/openclaw.json"
TOKEN_FILE="$OPENCLAW_HOME/gateway.token"
AGENT_DIR="$OPENCLAW_HOME/agents/main/agent"
AUTH_FILE="$AGENT_DIR/auth-profiles.json"

GATEWAY_PORT="18789"
GATEWAY_BIND="loopback"

OLLAMA_HOST_VALUE="127.0.0.1:11434"
OLLAMA_BIN="/usr/local/bin/ollama"
OLLAMA_DOWNLOAD_URL="https://ollama.com/download/ollama-linux-amd64"

MODEL_PULL="qwen3-coder:30b"
MODEL_OPENCLAW="ollama/qwen3-coder:30b"

OPENCLAW_NPM_VERSION="latest"

log() {
  echo
  echo "========== $* =========="
}

retry() {
  local tries="$1"
  shift
  local n=1
  until "$@"; do
    if [ "$n" -ge "$tries" ]; then
      echo "ERROR: failed after $tries attempts: $*" >&2
      return 1
    fi
    echo "Retry $n/$tries failed: $*" >&2
    n=$((n + 1))
    sleep 3
  done
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "ERROR: required command not found: $1" >&2
    exit 1
  }
}

log "Check persistent mount"
mkdir -p /workspace
if ! touch /workspace/.rw-test 2>/dev/null; then
  echo "ERROR: /workspace is not writable"
  echo "Mount your RunPod persistent volume at /workspace"
  exit 1
fi
rm -f /workspace/.rw-test

log "Prepare directories"
mkdir -p \
  "$OPENCLAW_HOME" \
  "$WORKSPACE_DIR" \
  "$LOG_DIR" \
  "$OLLAMA_ROOT" \
  "$OLLAMA_MODELS_DIR" \
  "$OLLAMA_TMP_DIR" \
  "$AGENT_DIR"

log "Install base packages"
retry 3 apt-get update -y
retry 3 apt-get install -y \
  curl \
  ca-certificates \
  gnupg \
  tmux \
  git \
  jq \
  nano \
  zstd \
  openssl \
  lsof \
  procps \
  psmisc

log "Install Node.js 24"
mkdir -p /etc/apt/keyrings
if [ ! -f /etc/apt/keyrings/nodesource.gpg ]; then
  retry 3 bash -lc \
    'curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg'
fi

cat > /etc/apt/sources.list.d/nodesource.list <<'EOF'
deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_24.x nodistro main
EOF

retry 3 apt-get update -y
retry 3 apt-get install -y nodejs

require_cmd node
require_cmd npm

export PATH="$(npm prefix -g 2>/dev/null)/bin:$PATH"

log "Install OpenClaw"
retry 3 npm install -g "openclaw@${OPENCLAW_NPM_VERSION}"

log "Install Ollama binary"
mkdir -p /usr/local/bin
retry 3 curl -fL "$OLLAMA_DOWNLOAD_URL" -o /tmp/ollama
chmod +x /tmp/ollama
mv /tmp/ollama "$OLLAMA_BIN"

require_cmd ollama
require_cmd openclaw

log "Show versions"
node --version || true
npm --version || true
openclaw --version || true
ollama --version || true

log "Create gateway token"
if [ ! -f "$TOKEN_FILE" ]; then
  openssl rand -hex 24 > "$TOKEN_FILE"
fi
TOKEN="$(cat "$TOKEN_FILE")"

log "Write OpenClaw config"
cat > "$CONFIG_FILE" <<EOF
{
  "gateway": {
    "mode": "local",
    "bind": "${GATEWAY_BIND}",
    "port": ${GATEWAY_PORT},
    "auth": {
      "token": "${TOKEN}"
    }
  },
  "agents": {
    "defaults": {
      "workspace": "${WORKSPACE_DIR}",
      "model": {
        "primary": "${MODEL_OPENCLAW}"
      }
    }
  }
}
EOF

log "Write Ollama auth profile"
cat > "$AUTH_FILE" <<'EOF'
{
  "version": 1,
  "profiles": {
    "ollama:default": {
      "type": "api_key",
      "provider": "ollama",
      "key": "ollama-local"
    }
  },
  "lastGood": {
    "ollama": "ollama:default"
  }
}
EOF

log "Stop old sessions"
tmux kill-session -t ollama 2>/dev/null || true
tmux kill-session -t openclaw 2>/dev/null || true
fuser -k 11434/tcp 2>/dev/null || true
fuser -k "${GATEWAY_PORT}"/tcp 2>/dev/null || true
sleep 2

log "Start Ollama"
tmux new-session -d -s ollama \
  "bash -lc '
    export OLLAMA_HOST=${OLLAMA_HOST_VALUE}
    export OLLAMA_MODELS=${OLLAMA_MODELS_DIR}
    export TMPDIR=${OLLAMA_TMP_DIR}
    exec ollama serve >> ${LOG_DIR}/ollama.log 2>&1
  '"

log "Wait for Ollama API"
for i in $(seq 1 120); do
  if curl -fsS "http://${OLLAMA_HOST_VALUE}/api/tags" >/dev/null 2>&1; then
    echo "Ollama is ready"
    break
  fi
  sleep 2
done

if ! curl -fsS "http://${OLLAMA_HOST_VALUE}/api/tags" >/dev/null 2>&1; then
  echo "ERROR: Ollama API did not become ready"
  echo
  echo "---- ollama log ----"
  tail -n 120 "${LOG_DIR}/ollama.log" || true
  exit 1
fi

log "Pull model if missing"
if ! OLLAMA_HOST="${OLLAMA_HOST_VALUE}" OLLAMA_MODELS="${OLLAMA_MODELS_DIR}" ollama list | grep -Fq "$MODEL_PULL"; then
  OLLAMA_HOST="${OLLAMA_HOST_VALUE}" OLLAMA_MODELS="${OLLAMA_MODELS_DIR}" ollama pull "$MODEL_PULL"
fi

log "Verify model exists"
if ! OLLAMA_HOST="${OLLAMA_HOST_VALUE}" OLLAMA_MODELS="${OLLAMA_MODELS_DIR}" ollama list | grep -Fq "$MODEL_PULL"; then
  echo "ERROR: model not found after pull: $MODEL_PULL"
  OLLAMA_HOST="${OLLAMA_HOST_VALUE}" OLLAMA_MODELS="${OLLAMA_MODELS_DIR}" ollama list || true
  exit 1
fi

log "Start OpenClaw"
tmux new-session -d -s openclaw \
  "bash -lc '
    export PATH=\$(npm prefix -g 2>/dev/null)/bin:\$PATH
    export HOME=/root
    exec openclaw gateway run >> ${LOG_DIR}/gateway.log 2>&1
  '"

sleep 8

log "Checks"
tmux ls || true
openclaw gateway status --deep || true

echo
echo "---- ollama models ----"
OLLAMA_HOST="${OLLAMA_HOST_VALUE}" OLLAMA_MODELS="${OLLAMA_MODELS_DIR}" ollama list || true

echo
echo "---- gateway log ----"
tail -n 80 "${LOG_DIR}/gateway.log" || true

echo
echo "---- ollama log ----"
tail -n 80 "${LOG_DIR}/ollama.log" || true

echo
echo "================ DONE ================"
echo "Persistent root:  $PERSIST_ROOT"
echo "OpenClaw home:    $OPENCLAW_HOME"
echo "Workspace:        $WORKSPACE_DIR"
echo "Ollama models:    $OLLAMA_MODELS_DIR"
echo "Logs:             $LOG_DIR"
echo "Config:           $CONFIG_FILE"
echo "Gateway token:    $TOKEN_FILE"
echo "Gateway URL:      ws://127.0.0.1:${GATEWAY_PORT}"
echo "Ollama API:       http://${OLLAMA_HOST_VALUE}"
echo "Primary model:    ${MODEL_OPENCLAW}"
echo "======================================"
