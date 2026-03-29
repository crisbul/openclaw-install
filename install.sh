#!/usr/bin/env bash
set -Eeuo pipefail

export DEBIAN_FRONTEND=noninteractive

OPENCLAW_HOME=/root/.openclaw
WORKSPACE="$OPENCLAW_HOME/workspace"
LOG_DIR="$OPENCLAW_HOME/logs"
CONFIG_FILE="$OPENCLAW_HOME/openclaw.json"
TOKEN_FILE="$OPENCLAW_HOME/gateway.token"

GATEWAY_BIND="loopback"
GATEWAY_PORT="18789"
OLLAMA_BIND="127.0.0.1:11434"
MODEL="ollama/qwen2.5:14b"
MODEL_PULL="qwen2.5:14b"

mkdir -p "$WORKSPACE" "$LOG_DIR"

echo "=== install deps ==="
apt-get update -y
apt-get install -y curl ca-certificates gnupg tmux git jq nano zstd

echo "=== install node ==="
mkdir -p /etc/apt/keyrings
curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key \
  | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg

echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_24.x nodistro main" \
  > /etc/apt/sources.list.d/nodesource.list

apt-get update -y
apt-get install -y nodejs

export PATH="$(npm prefix -g)/bin:$PATH"

echo "=== install openclaw ==="
npm install -g openclaw@latest

echo "=== install ollama ==="
curl -fsSL https://ollama.com/install.sh | sh

echo "=== start ollama ==="
tmux kill-session -t ollama 2>/dev/null || true
tmux new-session -d -s ollama \
  "bash -lc 'export OLLAMA_HOST=${OLLAMA_BIND}; ollama serve >> ${LOG_DIR}/ollama.log 2>&1'"

echo "=== wait for ollama ==="
for i in {1..30}; do
  if curl -s http://${OLLAMA_BIND}/api/tags >/dev/null; then
    echo "ollama ready"
    break
  fi
  sleep 2
done

echo "=== pull model ==="
ollama pull "$MODEL_PULL"

echo "=== verify model ==="
ollama list

echo "=== create token ==="
tr -dc A-Za-z0-9 </dev/urandom | head -c 48 > "$TOKEN_FILE"
TOKEN=$(cat "$TOKEN_FILE")

echo "=== write config ==="
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
      "workspace": "${WORKSPACE}",
      "model": {
        "primary": "${MODEL}"
      }
    }
  }
}
EOF

echo "=== start openclaw ==="
tmux kill-session -t openclaw 2>/dev/null || true

tmux new-session -d -s openclaw \
  "bash -lc 'export PATH=\$(npm prefix -g)/bin:\$PATH; openclaw gateway run >> ${LOG_DIR}/gateway.log 2>&1'"

sleep 5

echo "=== verify ==="
tmux ls

echo "=== gateway log ==="
tail -n 50 ${LOG_DIR}/gateway.log || true

echo "=== DONE ==="
