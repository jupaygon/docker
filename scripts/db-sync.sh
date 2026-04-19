#!/bin/bash

# =============================================================================
# Configuration (loaded from .env) -
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="$PROJECT_DIR/.env"

if [ ! -f "$ENV_FILE" ]; then
  echo "ERROR: .env file not found at $ENV_FILE"
  echo "Copy .env.dist to .env and configure DB_SYNC_DATABASES and DB_SYNC_SERVERS"
  exit 1
fi

source "$ENV_FILE"

if [ -z "$DB_SYNC_DATABASES" ]; then
  echo "ERROR: DB_SYNC_DATABASES must be set in .env"
  exit 1
fi

# Parse database entries.
# Supported formats per entry (comma-separated):
#   1) name:path                          -> engine=mysql, server picked from DB_SYNC_SERVERS
#   2) name:engine:path                   -> server picked from DB_SYNC_SERVERS
#   3) name:engine:server:path            -> fully bound, no server prompt
DB_NAMES=()
DB_ENGINES=()
DB_SERVERS=()
DB_PATHS=()
IFS=',' read -ra DB_ENTRIES <<< "$DB_SYNC_DATABASES"
for entry in "${DB_ENTRIES[@]}"; do
  IFS=':' read -ra PARTS <<< "$entry"
  case "${#PARTS[@]}" in
    2)
      DB_NAMES+=("${PARTS[0]}")
      DB_ENGINES+=("mysql")
      DB_SERVERS+=("")
      DB_PATHS+=("${PARTS[1]}")
      ;;
    3)
      DB_NAMES+=("${PARTS[0]}")
      DB_ENGINES+=("${PARTS[1]}")
      DB_SERVERS+=("")
      DB_PATHS+=("${PARTS[2]}")
      ;;
    4)
      DB_NAMES+=("${PARTS[0]}")
      DB_ENGINES+=("${PARTS[1]}")
      DB_SERVERS+=("${PARTS[2]}")
      DB_PATHS+=("${PARTS[3]}")
      ;;
    *)
      echo "ERROR: invalid DB_SYNC_DATABASES entry: $entry"
      echo "Expected: name:path | name:engine:path | name:engine:server:path"
      exit 1
      ;;
  esac
done

# Parse "host,host" into array (only required if any DB has no bound server)
SERVERS=()
if [ -n "$DB_SYNC_SERVERS" ]; then
  IFS=',' read -ra SERVERS <<< "$DB_SYNC_SERVERS"
fi

# Local paths
MYSQL_DUMPS_DIR="$PROJECT_DIR/images/mysql/dumps"
POSTGRES_DUMPS_DIR="$PROJECT_DIR/images/postgres/dumps"

# Docker
MYSQL_CONTAINER="dj_mysql"
MYSQL_ROOT_PASSWORD="password"

POSTGRES_CONTAINER="dj_postgres"
POSTGRES_USER="app"
POSTGRES_ADMIN_DB="postgres"

# =============================================================================
# Functions
# =============================================================================

ask_database() {
  echo ""
  echo "Which database do you want to sync?"
  echo ""
  for i in "${!DB_NAMES[@]}"; do
    label="${DB_NAMES[$i]} (${DB_ENGINES[$i]}"
    if [ -n "${DB_SERVERS[$i]}" ]; then
      label="$label @ ${DB_SERVERS[$i]}"
    fi
    label="$label)"
    echo "  $((i + 1))) $label"
  done
  echo ""

  while true; do
    read -rp "Choose [1-${#DB_NAMES[@]}]: " choice
    if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#DB_NAMES[@]}" ]; then
      idx=$((choice - 1))
      SELECTED_DB="${DB_NAMES[$idx]}"
      SELECTED_ENGINE="${DB_ENGINES[$idx]}"
      SELECTED_SERVER="${DB_SERVERS[$idx]}"
      SELECTED_DB_PATH="${DB_PATHS[$idx]}"
      echo "  -> Selected database: $SELECTED_DB ($SELECTED_ENGINE)"
      return
    fi
    echo "  Invalid option. Try again."
  done
}

ask_server() {
  # Skip prompt if database entry already binds a server
  if [ -n "$SELECTED_SERVER" ]; then
    echo "  -> Using bound server: $SELECTED_SERVER"
    return
  fi

  if [ ${#SERVERS[@]} -eq 0 ]; then
    echo "ERROR: database $SELECTED_DB has no bound server and DB_SYNC_SERVERS is empty"
    exit 1
  fi

  echo ""
  echo "From which server?"
  echo ""
  for i in "${!SERVERS[@]}"; do
    echo "  $((i + 1))) ${SERVERS[$i]}"
  done
  echo ""

  while true; do
    read -rp "Choose [1-${#SERVERS[@]}]: " choice
    if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#SERVERS[@]}" ]; then
      SELECTED_SERVER="${SERVERS[$((choice - 1))]}"
      echo "  -> Selected server: $SELECTED_SERVER"
      return
    fi
    echo "  Invalid option. Try again."
  done
}

resolve_dumps_dir() {
  case "$SELECTED_ENGINE" in
    mysql)    DUMPS_DIR="$MYSQL_DUMPS_DIR" ;;
    postgres) DUMPS_DIR="$POSTGRES_DUMPS_DIR" ;;
    *)
      echo "ERROR: unsupported engine '$SELECTED_ENGINE' (expected: mysql | postgres)"
      exit 1
      ;;
  esac
  mkdir -p "$DUMPS_DIR"
}

download_dumps() {
  echo ""
  echo "Listing remote .sql files in $SELECTED_SERVER:$SELECTED_DB_PATH ..."

  # Get list of .sql files from remote server
  remote_files=$(ssh "$SELECTED_SERVER" "ls -1 ${SELECTED_DB_PATH}/*.sql 2>/dev/null" | sort)

  if [ -z "$remote_files" ]; then
    echo "ERROR: No .sql files found at $SELECTED_SERVER:$SELECTED_DB_PATH"
    exit 1
  fi

  echo "Found:"
  while IFS= read -r f; do
    echo "  - $(basename "$f")"
  done <<< "$remote_files"

  # Clean previous dumps for this database in local dir
  echo ""
  echo "Cleaning previous dumps in $DUMPS_DIR ..."
  rm -f "$DUMPS_DIR"/${SELECTED_DB}_*.sql

  # Download each file
  echo "Downloading dumps to $DUMPS_DIR ..."
  while IFS= read -r remote_file; do
    local_file="$DUMPS_DIR/$(basename "$remote_file")"
    echo "  scp $SELECTED_SERVER:$remote_file -> $local_file"
    if ! scp "$SELECTED_SERVER":"$remote_file" "$local_file"; then
      echo "ERROR: Failed to download $remote_file"
      exit 1
    fi
  done <<< "$remote_files"

  echo "Download complete."
}

import_dumps_mysql() {
  echo ""
  echo "Importing dumps into container $MYSQL_CONTAINER ..."

  local_files=$(ls -1 "$DUMPS_DIR"/${SELECTED_DB}_*.sql 2>/dev/null | sort)

  if [ -z "$local_files" ]; then
    echo "ERROR: No .sql files found in $DUMPS_DIR for database $SELECTED_DB"
    exit 1
  fi

  while IFS= read -r sql_file; do
    filename=$(basename "$sql_file")
    echo "  Importing $filename ..."
    if ! docker exec -i "$MYSQL_CONTAINER" mysql -uroot -p"$MYSQL_ROOT_PASSWORD" < "$sql_file"; then
      echo "ERROR: Failed to import $filename"
      exit 1
    fi
    echo "  $filename imported OK"
  done <<< "$local_files"

  echo ""
  echo "All dumps imported successfully."
}

import_dumps_postgres() {
  echo ""
  echo "Importing dumps into container $POSTGRES_CONTAINER ..."

  local_files=$(ls -1 "$DUMPS_DIR"/${SELECTED_DB}_*.sql 2>/dev/null | sort)

  if [ -z "$local_files" ]; then
    echo "ERROR: No .sql files found in $DUMPS_DIR for database $SELECTED_DB"
    exit 1
  fi

  # Drop and recreate target database to guarantee a clean import
  echo "  Recreating database '$SELECTED_DB' on $POSTGRES_CONTAINER ..."
  docker exec -i "$POSTGRES_CONTAINER" psql -U "$POSTGRES_USER" -d "$POSTGRES_ADMIN_DB" \
    -c "DROP DATABASE IF EXISTS \"$SELECTED_DB\";" >/dev/null
  if [ $? -ne 0 ]; then
    echo "ERROR: Failed to drop database $SELECTED_DB"
    exit 1
  fi
  docker exec -i "$POSTGRES_CONTAINER" psql -U "$POSTGRES_USER" -d "$POSTGRES_ADMIN_DB" \
    -c "CREATE DATABASE \"$SELECTED_DB\" OWNER \"$POSTGRES_USER\";" >/dev/null
  if [ $? -ne 0 ]; then
    echo "ERROR: Failed to create database $SELECTED_DB"
    exit 1
  fi

  # Wrap each dump in `session_replication_role = replica` so FK ordering
  # in the dump cannot break the import. pg_dump emits INSERTs in OID
  # order, not topological order, so a child row that references a parent
  # still to be inserted (e.g. task.parent_task_id -> task.id) fails a
  # FK check otherwise. Requires superuser on the local cluster — already
  # the case for dj_postgres.
  while IFS= read -r sql_file; do
    filename=$(basename "$sql_file")
    echo "  Importing $filename ..."
    if ! {
      printf "SET session_replication_role = 'replica';\n"
      cat "$sql_file"
      printf "\nSET session_replication_role = 'origin';\n"
    } | docker exec -i "$POSTGRES_CONTAINER" psql -U "$POSTGRES_USER" -d "$SELECTED_DB" -v ON_ERROR_STOP=1; then
      echo "ERROR: Failed to import $filename"
      exit 1
    fi
    echo "  $filename imported OK"
  done <<< "$local_files"

  echo ""
  echo "All dumps imported successfully."
}

import_dumps() {
  case "$SELECTED_ENGINE" in
    mysql)    import_dumps_mysql ;;
    postgres) import_dumps_postgres ;;
    *)
      echo "ERROR: unsupported engine '$SELECTED_ENGINE'"
      exit 1
      ;;
  esac
}

# =============================================================================
# Main
# =============================================================================

echo ""
echo "=== DB Sync ==="

ask_database
ask_server
resolve_dumps_dir
download_dumps
import_dumps

echo ""
echo "Done!"
