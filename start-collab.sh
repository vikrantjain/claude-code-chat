#!/usr/bin/env bash
set -euo pipefail

# Collaborative app development launcher for tmux
# Usage: ./start-collab.sh
#
# Requires:
#   - CLAUDE_CODE_OAUTH_TOKEN env var (run `claude setup-token` first)
#   - Docker with the `claude-code` image built
#   - tmux

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
SESSION="claude-collab"
NETWORK="claude-chat"
VOLUME="workspace"
BROKER_IMAGE="oven/bun:1-debian"
CLIENT_IMAGE="claude-code"
MODEL="${CLAUDE_CHAT_MODEL:-haiku}"

if [ -z "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then
  echo "Error: CLAUDE_CODE_OAUTH_TOKEN is not set."
  echo "Run 'claude setup-token' first, then export the token."
  exit 1
fi

# Ensure Docker prerequisites exist
docker network inspect "$NETWORK" >/dev/null 2>&1 || docker network create "$NETWORK"
docker volume inspect "$VOLUME" >/dev/null 2>&1 || docker volume create "$VOLUME"

# Stop any leftover containers from a previous run
for name in claude-chat-broker manager alice bob; do
  docker rm -f "$name" 2>/dev/null || true
done

# Helper: builds the docker run command for a client agent
client_cmd() {
  local agent_name="$1"
  local system_prompt="$2"

  cat <<EOF
docker run --rm -it \\
  --network $NETWORK \\
  -v "$PROJECT_DIR/src/client.ts:/app/src/client.ts:ro" \\
  -v "$PROJECT_DIR/package.json:/app/package.json:ro" \\
  -v "$PROJECT_DIR/bun.lock:/app/bun.lock:ro" \\
  -v "$PROJECT_DIR/docker/entrypoint.sh:/app/docker/entrypoint.sh:ro" \\
  -v "$PROJECT_DIR/docker/.mcp.json:/app/.mcp.json:ro" \\
  -v $VOLUME:/app/workspace \\
  --name "$agent_name" \\
  -e CLAUDE_CODE_OAUTH_TOKEN="$CLAUDE_CODE_OAUTH_TOKEN" \\
  -e CLAUDE_CHAT_NAME="$agent_name" \\
  -e CLAUDE_CHAT_BROKER=ws://claude-chat-broker:4000 \\
  $CLIENT_IMAGE \\
  --model $MODEL \\
  -n "$agent_name" \\
  --append-system-prompt "$system_prompt" \\
  --dangerously-skip-permissions \\
  --dangerously-load-development-channels server:claude-chat \\
  --allowedTools '*'
EOF
}

BROKER_CMD="docker run --rm -it --name claude-chat-broker \
  --network $NETWORK \
  -v \"$PROJECT_DIR/src/broker.ts:/app/src/broker.ts:ro\" \
  -w /app $BROKER_IMAGE bun run src/broker.ts"

MANAGER_PROMPT="Your name is manager. You are a project manager. You break tasks into subtasks, assign them to developer agents (alice and bob), coordinate their work, and verify the final result. If verification fails, send the issues back to the responsible developer for fixing until everything works. All code should be written in /app/workspace."
ALICE_PROMPT="Your name is alice. You are a developer agent. You write code in /app/workspace as assigned by the manager. When you need to agree on interfaces, discuss with the other developer. Report progress and completion back to the manager."
BOB_PROMPT="Your name is bob. You are a developer agent. You write code in /app/workspace as assigned by the manager. When you need to agree on interfaces, discuss with the other developer. Report progress and completion back to the manager."

MANAGER_CMD=$(client_cmd "manager" "$MANAGER_PROMPT")
ALICE_CMD=$(client_cmd "alice" "$ALICE_PROMPT")
BOB_CMD=$(client_cmd "bob" "$BOB_PROMPT")

# Kill existing session if any
tmux kill-session -t "$SESSION" 2>/dev/null || true

# Create tmux session with broker in the first pane
tmux new-session -d -s "$SESSION" -n "collab"
tmux send-keys -t "$SESSION:collab" "$BROKER_CMD" C-m

# Wait for broker to start
sleep 2

# Split into 4 panes (2x2 grid)
# Current layout: [broker]
tmux split-window -h -t "$SESSION:collab"    # right pane
tmux split-window -v -t "$SESSION:collab.0"  # bottom-left
tmux split-window -v -t "$SESSION:collab.1"  # bottom-right

# Send commands to each pane
# Pane 0: broker (already running)
# Pane 1: bob (top-right after splits)
# Pane 2: manager (bottom-left)
# Pane 3: alice (bottom-right)
tmux send-keys -t "$SESSION:collab.1" "$BOB_CMD" C-m
tmux send-keys -t "$SESSION:collab.2" "$MANAGER_CMD" C-m
tmux send-keys -t "$SESSION:collab.3" "$ALICE_CMD" C-m

# Even out the layout
tmux select-layout -t "$SESSION:collab" tiled

# Attach
tmux attach-session -t "$SESSION"
