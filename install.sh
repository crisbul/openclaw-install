#!/usr/bin/env bash
set -Eeuo pipefail

export DEBIAN_FRONTEND=noninteractive

OPENCLAW_HOME=/root/.openclaw
WORKSPACE="${OPENCLAW_WORKSPACE:-$OPENCLAW_HOME/workspace}"
LOG_DIR="${OPENCLAW_LOG_DIR:-$OPENCLAW_HOME/logs}"
CONFIG_FILE="$OPENCLAW_HOME/openclaw.json"
TOKEN_FILE="$OPENCLAW_HOME/gateway.token"

GATEWAY_BIND="${OPENCLAW_GATEWAY_BIND:-127.0.0.1}"
GATEWAY_PORT="${OPENCLAW_GATEWAY_PORT:-18789}"
OLLAMA_BIND="${OLLAMA_HOST:-127.0.0.1:11434}"
MODEL="${OPENCLAW_MODEL:-ollama/qwen2.5:14b}"
MODEL_PULL="${MODEL#ollama/}"
TELEGRAM_ENABLED="${TELEGRAM_ENABLED:-true}"
TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-REPLACE_ME}"
TELEGRAM_DM_POLICY="${TELEGRAM_DM_POLICY:-pairing}"
TELEGRAM_REQUIRE_MENTION="${TELEGRAM_REQUIRE_MENTION:-true}"

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
  zstd

log "Install Node 24"
mkdir -p /etc/apt/keyrings
if [ ! -f /etc/apt/keyrings/nodesource.gpg ]; then
  curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key \
    | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg
fi

cat > /etc/apt/sources.list.d/nodesource.list <<'EOF'
deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_24.x nodistro main
EOF

retry 3 apt-get update -y
retry 3 apt-get install -y nodejs

export PATH="$(npm prefix -g 2>/dev/null)/bin:$PATH"

log "Install OpenClaw"
retry 3 npm install -g openclaw@latest

log "Install Ollama"
curl -fsSL https://ollama.com/install.sh | sh

log "Prepare directories"
mkdir -p "$OPENCLAW_HOME" "$WORKSPACE" "$LOG_DIR"

if [ ! -f "$TOKEN_FILE" ]; then
  tr -dc 'A-Za-z0-9' </dev/urandom | head -c 48 > "$TOKEN_FILE"
fi
TOKEN="$(cat "$TOKEN_FILE")"

log "Write config"
cat > "$CONFIG_FILE" <<EOF
{
  "gateway": {
    "bind": "${GATEWAY_BIND}",
    "port": ${GATEWAY_PORT},
    "auth": {
      "token": "${TOKEN}"
    }
  },
  "agents": {
    "defaults": {
      "workspace": "${WORKSPACE}",
      "model": {
        "primary": "${MODEL}"
      }
    }
  },
  "channels": {
    "telegram": {
      "enabled": ${TELEGRAM_ENABLED},
      "botToken": "${TELEGRAM_BOT_TOKEN}",
      "dmPolicy": "${TELEGRAM_DM_POLICY}",
      "groups": {
        "*": {
          "requireMention": ${TELEGRAM_REQUIRE_MENTION}
        }
      }
    }
  }
}
EOF

log "Stop old sessions"
tmux kill-session -t ollama 2>/dev/null || true
tmux kill-session -t openclaw 2>/dev/null || true

log "Start Ollama"
tmux new-session -d -s ollama \
  "bash -lc 'export OLLAMA_HOST=${OLLAMA_BIND}; ollama serve >> ${LOG_DIR}/ollama.log 2>&1'"

sleep 8

if [[ "$MODEL" == ollama/* ]]; then
  log "Pull model"
  ollama pull "$MODEL_PULL" || true
fi

log "Start OpenClaw"
tmux new-session -d -s openclaw \
  "bash -lc 'export PATH=\$(npm prefix -g 2>/dev/null)/bin:\$PATH; which openclaw; openclaw gateway run >> ${LOG_DIR}/gateway.log 2>&1'"

sleep 8

log "Checks"
set +e
curl -fsS "http://${OLLAMA_BIND}/api/tags" >/tmp/ollama-tags.json 2>/dev/null
OLLAMA_OK=$?
openclaw gateway status --deep >/tmp/openclaw-status.txt 2>&1
GATEWAY_OK=$?
set -e

echo
echo "================ DONE ================"
echo "Node:        $(node -v)"
echo "npm:         $(npm -v)"
echo "OpenClaw:    $(openclaw --version || true)"
echo "Ollama:      $(ollama --version || true)"
echo "Config:      $CONFIG_FILE"
echo "Logs:        $LOG_DIR"
echo "Gateway:     ws://${GATEWAY_BIND}:${GATEWAY_PORT}"
echo "Ollama:      http://${OLLAMA_BIND}"
echo
echo "tmux sessions:"
tmux ls || true
echo
echo "Useful:"
echo "  tail -f ${LOG_DIR}/gateway.log"
echo "  tail -f ${LOG_DIR}/ollama.log"
echo "  tmux attach -t openclaw"
echo "  tmux attach -t ollama"
echo "  openclaw gateway status --deep"
echo "  curl http://${OLLAMA_BIND}/api/tags"
echo
echo "Tunnel from laptop:"
echo "  ssh -L 18789:127.0.0.1:18789 -L 11434:127.0.0.1:11434 root@YOUR_RUNPOD_IP -p YOUR_SSH_PORT"
echo "  then open http://127.0.0.1:18789/"
echo "======================================"

if [ "$OLLAMA_OK" -ne 0 ]; then
  echo "WARNING: Ollama health check failed"
fi

if [ "$GATEWAY_OK" -ne 0 ]; then
  echo "WARNING: OpenClaw health check failed"
fi
