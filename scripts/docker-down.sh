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

# Stop containers
echo "Stopping Docker environment..."
docker compose -f "$DOCKER_DIR/docker-compose.yml" down

echo "Done!"
