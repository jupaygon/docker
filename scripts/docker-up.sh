#!/bin/bash
set -euo pipefail

# ---------------------------------------------------------------
# docker-up.sh — Start the Workspace Docker environment
# ---------------------------------------------------------------

# Resolve the docker directory
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DOCKER_DIR="$(dirname "$SCRIPT_DIR")"

# Source .github.conf if it exists (exports GITHUB_AGENT_TOKEN)
if [ -f "$DOCKER_DIR/.github.conf" ]; then
  source "$DOCKER_DIR/.github.conf"
  export GITHUB_TOKEN="${GITHUB_AGENT_TOKEN:-}"
fi

echo "Starting Workspace Docker environment..."
docker compose -f "$DOCKER_DIR/docker-compose.yml" up -d

echo "Done!"
