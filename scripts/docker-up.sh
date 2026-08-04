#!/bin/bash
set -euo pipefail

# ---------------------------------------------------------------
# docker-up.sh — Start the Workspace Docker environment
# ---------------------------------------------------------------

# Resolve the docker directory
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DOCKER_DIR="$(dirname "$SCRIPT_DIR")"

# An explicit -f disables the automatic pickup of docker-compose.override.yml,
# so add it here. That file is gitignored and is where machine-specific bits go.
COMPOSE_FILES=(-f "$DOCKER_DIR/docker-compose.yml")
[ -f "$DOCKER_DIR/docker-compose.override.yml" ] && COMPOSE_FILES+=(-f "$DOCKER_DIR/docker-compose.override.yml")

echo "Starting Workspace Docker environment..."
docker compose "${COMPOSE_FILES[@]}" up -d

# Start project workers (any sibling repo with docker-compose.worker.yml)
WORKSPACE_DIR="$(dirname "$DOCKER_DIR")"
for worker_file in "$WORKSPACE_DIR"/*/docker-compose.worker.yml; do
  [ -f "$worker_file" ] || continue
  project_dir="$(dirname "$worker_file")"
  project_name="$(basename "$project_dir")"
  # Skip git worktrees — they share the main repo's worker
  case "$project_name" in wt-*) continue;; esac
  echo "Starting worker for $project_name..."
  docker compose -f "$worker_file" up -d --build
done

echo "Done!"
