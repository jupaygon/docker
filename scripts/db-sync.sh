#!/bin/bash

# =============================================================================
# Configuration (loaded from .env)
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

if [ -z "$DB_SYNC_DATABASES" ] || [ -z "$DB_SYNC_SERVERS" ]; then
  echo "ERROR: DB_SYNC_DATABASES and DB_SYNC_SERVERS must be set in .env"
  exit 1
fi

# Parse "name:path,name:path" into parallel arrays
DB_NAMES=()
DB_PATHS=()
IFS=',' read -ra DB_ENTRIES <<< "$DB_SYNC_DATABASES"
for entry in "${DB_ENTRIES[@]}"; do
  DB_NAMES+=("${entry%%:*}")
  DB_PATHS+=("${entry#*:}")
done

# Parse "host,host" into array
IFS=',' read -ra SERVERS <<< "$DB_SYNC_SERVERS"

# Local paths
DUMPS_DIR="$PROJECT_DIR/images/mysql/dumps"

# Docker
MYSQL_CONTAINER="dj_mysql"
MYSQL_ROOT_PASSWORD="password"

# =============================================================================
# Functions
# =============================================================================

ask_database() {
  echo ""
  echo "Which database do you want to sync?"
  echo ""
  for i in "${!DB_NAMES[@]}"; do
    echo "  $((i + 1))) ${DB_NAMES[$i]}"
  done
  echo ""

  while true; do
    read -rp "Choose [1-${#DB_NAMES[@]}]: " choice
    if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#DB_NAMES[@]}" ]; then
      SELECTED_DB="${DB_NAMES[$((choice - 1))]}"
      SELECTED_DB_PATH="${DB_PATHS[$((choice - 1))]}"
      echo "  -> Selected database: $SELECTED_DB"
      return
    fi
    echo "  Invalid option. Try again."
  done
}

ask_server() {
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
  echo "$remote_files" | while read -r f; do echo "  - $(basename "$f")"; done

  # Clean previous dumps for this database in local dir
  echo ""
  echo "Cleaning previous dumps in $DUMPS_DIR ..."
  rm -f "$DUMPS_DIR"/${SELECTED_DB}_*.sql

  # Download each file
  echo "Downloading dumps to $DUMPS_DIR ..."
  echo "$remote_files" | while read -r remote_file; do
    local_file="$DUMPS_DIR/$(basename "$remote_file")"
    echo "  scp $SELECTED_SERVER:$remote_file -> $local_file"
    scp "$SELECTED_SERVER":"$remote_file" "$local_file"
    if [ $? -ne 0 ]; then
      echo "ERROR: Failed to download $remote_file"
      exit 1
    fi
  done

  if [ $? -ne 0 ]; then
    exit 1
  fi

  echo "Download complete."
}

import_dumps() {
  echo ""
  echo "Importing dumps into container $MYSQL_CONTAINER ..."

  # Get local .sql files for this database, sorted alphabetically
  local_files=$(ls -1 "$DUMPS_DIR"/${SELECTED_DB}_*.sql 2>/dev/null | sort)

  if [ -z "$local_files" ]; then
    echo "ERROR: No .sql files found in $DUMPS_DIR for database $SELECTED_DB"
    exit 1
  fi

  echo "$local_files" | while read -r sql_file; do
    filename=$(basename "$sql_file")
    echo "  Importing $filename ..."
    docker exec -i "$MYSQL_CONTAINER" mysql -uroot -p"$MYSQL_ROOT_PASSWORD" < "$sql_file"
    if [ $? -ne 0 ]; then
      echo "ERROR: Failed to import $filename"
      exit 1
    fi
    echo "  $filename imported OK"
  done

  if [ $? -ne 0 ]; then
    exit 1
  fi

  echo ""
  echo "All dumps imported successfully."
}

# =============================================================================
# Main
# =============================================================================

echo ""
echo "=== DB Sync ==="

ask_database
ask_server
download_dumps
import_dumps

echo ""
echo "Done!"
