#!/usr/bin/env bash
set -Eeuo pipefail

export DEBIAN_FRONTEND=noninteractive

OPENCLAW_HOME=/root/.openclaw
WORKSPACE="$OPENCLAW_HOME/workspace"
LOG_DIR="$OPENCLAW_HOME/logs"
CONFIG_FILE="$OPENCLAW_HOME/openclaw.json"

echo "========== INSTALL =========="

apt-get update -y
apt-get install -y curl git tmux jq ca-certificates gnupg

# Node 24
mkdir -p /etc/apt/keyrings
curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key \
  | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg

echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_24.x nodistro main" \
  > /etc/apt/sources.list.d/nodesource.list

apt-get update -y
apt-get install -y nodejs

# OpenClaw
npm install -g openclaw

# Ollama
curl -fsSL https://ollama.com/install.sh | sh

# Directories
mkdir -p "$WORKSPACE" "$LOG_DIR"

# Config (CRITICAL FIX)
cat > "$CONFIG_FILE" <<EOF
{
  "gateway": {
    "bind": "127.0.0.1",
    "port": 18789
  },
  "agents": {
    "defaults": {
      "workspace": "/root/.openclaw/workspace",
      "model": {
        "primary": "ollama/qwen2.5:7b"
      }
    }
  }
}
EOF

echo "========== START SERVICES =========="

# Start Ollama (background)
tmux new-session -d -s ollama \
  "bash -lc 'export OLLAMA_HOST=127.0.0.1:11434 && ollama serve'"

sleep 5

# Pull model (safe small first)
ollama pull qwen2.5:7b

# Start OpenClaw (background)
tmux new-session -d -s openclaw \
  "bash -lc 'openclaw gateway run'"

sleep 5

echo "========== STATUS =========="
openclaw gateway status --deep || true

echo "========== READY =========="

# 🔥🔥🔥 THIS LINE FIXES EVERYTHING 🔥🔥🔥
tail -f /dev/null
