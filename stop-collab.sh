#!/usr/bin/env bash
set -euo pipefail

# Stop the collaborative session and clean up containers
# Usage: ./stop-collab.sh [--purge]
#
# --purge  also removes the workspace directory and docker network

SESSION="claude-collab"
NETWORK="claude-chat"
WORKSPACE="$(cd "$(dirname "$0")" && pwd)/.workspace"

# Stop containers
for name in claude-chat-broker manager alice bob; do
  docker rm -f "$name" 2>/dev/null && echo "Stopped $name" || true
done

# Kill tmux session
tmux kill-session -t "$SESSION" 2>/dev/null && echo "Killed tmux session '$SESSION'" || true

if [ "${1:-}" = "--purge" ]; then
  rm -rf "$WORKSPACE" && echo "Removed workspace '$WORKSPACE'" || true
  docker network rm "$NETWORK" 2>/dev/null && echo "Removed network '$NETWORK'" || true
  echo "Purge complete."
else
  echo "Done. Workspace '$WORKSPACE' kept. Use --purge to remove it."
fi
