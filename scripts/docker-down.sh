#!/bin/bash
set -euo pipefail

# ---------------------------------------------------------------
# docker-down.sh — Backup databases and stop the Docker environment
# ---------------------------------------------------------------

# Resolve the docker directory
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DOCKER_DIR="$(dirname "$SCRIPT_DIR")"
DUMPS_DIR="$DOCKER_DIR/images/mysql/dumps"

# Backup all databases (except system ones) before stopping
echo "Backing up databases..."

DATABASES=$(docker exec dj_mysql mysql -uroot -ppassword -N -e \
  "SELECT schema_name FROM information_schema.schemata WHERE schema_name NOT IN ('mysql','information_schema','performance_schema','sys')" 2>/dev/null)

if [ -n "$DATABASES" ]; then
  for DB in $DATABASES; do
    echo "  Dumping $DB..."
    docker exec dj_mysql mysqldump -uroot -ppassword \
      --no-tablespaces --add-drop-table --routines --add-drop-trigger \
      "$DB" > "$DUMPS_DIR/${DB}.sql" 2>/dev/null
  done
  echo "Backups saved in images/mysql/dumps/"
else
  echo "  No user databases found, skipping backup."
fi


# Backup PostgreSQL databases (except system ones) before stopping
echo "Backing up PostgreSQL databases..."
PG_DUMPS_DIR="$DOCKER_DIR/images/postgres/dumps"

PG_DATABASES=$(docker exec dj_postgres psql -U app -d app -At -c \
  "SELECT datname FROM pg_database WHERE datistemplate = false AND datname NOT IN ('postgres', 'app')" 2>/dev/null)

if [ -n "$PG_DATABASES" ]; then
  for DB in $PG_DATABASES; do
    echo "  Dumping PostgreSQL: $DB..."
    docker exec dj_postgres pg_dump -U app --clean --if-exists "$DB" > "$PG_DUMPS_DIR/${DB}.sql" 2>/dev/null
  done
  echo "PostgreSQL backups saved in images/postgres/dumps/"
else
  echo "  No PostgreSQL user databases found, skipping backup."
fi

# Stop project workers
WORKSPACE_DIR="$(dirname "$DOCKER_DIR")"
for worker_file in "$WORKSPACE_DIR"/*/docker-compose.worker.yml; do
  [ -f "$worker_file" ] || continue
  project_dir="$(dirname "$worker_file")"
  project_name="$(basename "$project_dir")"
  # Skip git worktrees — they share the main repo's worker
  case "$project_name" in wt-*) continue;; esac
  echo "Stopping worker for $project_name..."
  docker compose -f "$worker_file" down
done

# Stop containers
echo "Stopping Docker environment..."
docker compose -f "$DOCKER_DIR/docker-compose.yml" down

echo "Done!"
