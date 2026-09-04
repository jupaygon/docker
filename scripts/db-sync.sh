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
  # Candidates: a server bound on the entry (one, or a srvA|srvB list) takes
  # precedence over the global DB_SYNC_SERVERS list. A single bound server skips
  # the prompt; a list (or the global fallback) prompts.
  local -a candidates
  if [ -n "$SELECTED_SERVER" ]; then
    IFS='|' read -ra candidates <<< "$SELECTED_SERVER"
    if [ "${#candidates[@]}" -eq 1 ]; then
      echo "  -> Using bound server: $SELECTED_SERVER"
      return
    fi
  elif [ ${#SERVERS[@]} -gt 0 ]; then
    candidates=("${SERVERS[@]}")
  else
    echo "ERROR: database $SELECTED_DB has no bound server and DB_SYNC_SERVERS is empty"
    exit 1
  fi

  echo ""
  echo "From which server?"
  echo ""
  for i in "${!candidates[@]}"; do
    echo "  $((i + 1))) ${candidates[$i]}"
  done
  echo ""

  while true; do
    read -rp "Choose [1-${#candidates[@]}]: " choice
    if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#candidates[@]}" ]; then
      SELECTED_SERVER="${candidates[$((choice - 1))]}"
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

# Keeps one file per dump, the compressed one wherever both are published. A
# project that has just started compressing leaves the plain file behind for a
# while, and loading the pair means loading the same dump twice — for the schema,
# that is a DROP TABLE in the middle of the data it just wrote.
#
# Reads paths on stdin, writes the kept ones on stdout. awk and not an
# associative array: this also runs on the bash that ships with macOS.
prefer_compressed() {
  awk '
    { base = $0; sub(/\.gz$/, "", base)
      if (!(base in best) || $0 ~ /\.gz$/) { best[base] = $0 } }
    END { for (b in best) { print best[b] } }
  ' | sort
}

# A path written as @name is a Docker named volume, not a directory: the dumps
# live under the daemon's volume area and its exact location is the daemon's to
# decide, so it is asked rather than assumed. Root owns that area, hence sudo.
resolve_remote_path() {
  case "$1" in
    @*)
      # @volume, or @volume/subdirectory when the dumps sit inside it.
      spec="${1#@}"
      volume_name="${spec%%/*}"
      subpath=""
      [ "$spec" != "$volume_name" ] && subpath="/${spec#*/}"

      # Whatever is in the config ends up inside a remote shell command, so it
      # is held to the character set Docker itself accepts for a volume name.
      if ! [[ "$volume_name" =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]*$ ]]; then
        echo "ERROR: '$volume_name' is not a valid Docker volume name" >&2
        return 1
      fi

      if [ -n "$subpath" ] && ! [[ "$subpath" =~ ^(/[a-zA-Z0-9][a-zA-Z0-9_.-]*)+$ ]]; then
        echo "ERROR: '${subpath#/}' is not a valid path inside the volume" >&2
        return 1
      fi

      mountpoint=$(ssh "$SELECTED_SERVER" "docker volume inspect '$volume_name' --format '{{.Mountpoint}}'" 2>/dev/null)

      [ -n "$mountpoint" ] && printf '%s%s' "$mountpoint" "$subpath"
      ;;
    *)
      printf '%s' "$1"
      ;;
  esac
}

# Decided here and not inside resolve_remote_path: callers read that function
# through $(...), which runs it in a subshell where an assignment dies.
path_needs_sudo() {
  case "$1" in
    @*) printf 'true' ;;
    *)  printf 'false' ;;
  esac
}

# Through `sudo sh -c` and not plain `sudo`: the unprivileged shell cannot read
# root's directory, so it would expand a wildcard to nothing and hand the literal
# pattern to a command that then reports it as missing.
remote_run() {
  if [ "$REMOTE_NEEDS_SUDO" = true ]; then
    ssh "$SELECTED_SERVER" "sudo sh -c $(printf '%q' "$1")"
  else
    ssh "$SELECTED_SERVER" "$1"
  fi
}

download_dumps() {
  echo ""

  REMOTE_NEEDS_SUDO=$(path_needs_sudo "$SELECTED_DB_PATH")
  REMOTE_DUMPS_PATH=$(resolve_remote_path "$SELECTED_DB_PATH")

  if [ -z "$REMOTE_DUMPS_PATH" ]; then
    echo "ERROR: no Docker volume named ${SELECTED_DB_PATH#@} on $SELECTED_SERVER"
    echo "       docker volume ls   there will show what is available"
    exit 1
  fi

  echo "Listing remote dump files in $SELECTED_SERVER:$REMOTE_DUMPS_PATH ..."

  # Both extensions: dumps are compressed at the source now, and older ones are
  # not. Which of the two to take, when a dump has both, is decided below.
  remote_files=$(remote_run "ls -1 '${REMOTE_DUMPS_PATH}'/*.sql '${REMOTE_DUMPS_PATH}'/*.sql.gz 2>/dev/null" | sort)

  if [ -z "$remote_files" ]; then
    echo "ERROR: No dump files found at $SELECTED_SERVER:$REMOTE_DUMPS_PATH"
    exit 1
  fi

  # A project that publishes a slim pair alongside the full one means it: the
  # slim leaves out bulk that can be fetched from its own source, and taking
  # the full one instead is hours of restoring for the same working database.
  slim_files=$(echo "$remote_files" | grep "/${SELECTED_DB}_slim_" || true)

  if [ -n "$slim_files" ] && [ "$WANT_FULL" != true ]; then
    echo "  (a slim dump is published; taking it — pass --full for the complete one)"
    remote_files="$slim_files"
  else
    remote_files=$(echo "$remote_files" | grep -v "/${SELECTED_DB}_slim_" || true)
  fi

  remote_files=$(printf '%s\n' "$remote_files" | prefer_compressed)

  # Asking for --full where only the slim pair is published leaves nothing to
  # download, and saying so here beats failing later on an empty import.
  if [ -z "$remote_files" ]; then
    echo "ERROR: No matching dump files at $SELECTED_SERVER:$REMOTE_DUMPS_PATH"
    if [ "$WANT_FULL" = true ]; then
      echo "       Only a slim dump is published for $SELECTED_DB; drop --full to take it."
    fi
    exit 1
  fi

  echo "Found:"
  while IFS= read -r f; do
    echo "  - $(basename "$f")"
  done <<< "$remote_files"

  # Clean previous dumps for this database in local dir
  echo ""
  echo "Cleaning previous dumps in $DUMPS_DIR ..."
  rm -f "$DUMPS_DIR"/${SELECTED_DB}_*.sql "$DUMPS_DIR"/${SELECTED_DB}_*.sql.gz

  # Download each file
  echo "Downloading dumps to $DUMPS_DIR ..."
  while IFS= read -r remote_file; do
    local_file="$DUMPS_DIR/$(basename "$remote_file")"
    echo "  $SELECTED_SERVER:$remote_file -> $local_file"

    # scp cannot become root on the far side; the redirection creates the file
    # even when the pipe fails, so a failed one has to be removed here.
    if [ "$REMOTE_NEEDS_SUDO" = true ]; then
      if ! ssh "$SELECTED_SERVER" "sudo cat '$remote_file'" > "$local_file"; then
        rm -f "$local_file"
        echo "ERROR: Failed to download $remote_file"
        exit 1
      fi
    elif ! scp "$SELECTED_SERVER":"$remote_file" "$local_file"; then
      echo "ERROR: Failed to download $remote_file"
      exit 1
    fi
  done <<< "$remote_files"

  echo "Download complete."
}

import_dumps_mysql() {
  echo ""
  echo "Importing dumps into container $MYSQL_CONTAINER ..."

  local_files=$(ls -1 "$DUMPS_DIR"/${SELECTED_DB}_*.sql "$DUMPS_DIR"/${SELECTED_DB}_*.sql.gz 2>/dev/null | prefer_compressed)

  if [ -z "$local_files" ]; then
    echo "ERROR: No dump files found in $DUMPS_DIR for database $SELECTED_DB"
    exit 1
  fi

  while IFS= read -r sql_file; do
    filename=$(basename "$sql_file")
    echo "  Importing $filename ..."
    # Compressed or not, depending on how old the dump is.
    case "$sql_file" in
      *.gz) reader="gzip -dc" ;;
      *)    reader="cat" ;;
    esac
    if ! $reader "$sql_file" | docker exec -i "$MYSQL_CONTAINER" mysql -uroot -p"$MYSQL_ROOT_PASSWORD"; then
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

  local_files=$(ls -1 "$DUMPS_DIR"/${SELECTED_DB}_*.sql "$DUMPS_DIR"/${SELECTED_DB}_*.sql.gz 2>/dev/null | prefer_compressed)

  if [ -z "$local_files" ]; then
    echo "ERROR: No dump files found in $DUMPS_DIR for database $SELECTED_DB"
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
    # Compressed or not, depending on how old the dump is.
    case "$sql_file" in
      *.gz) reader="gzip -dc" ;;
      *)    reader="cat" ;;
    esac
    if ! {
      printf "SET session_replication_role = 'replica';\n"
      $reader "$sql_file"
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

WANT_FULL=false
for arg in "$@"; do
  case "$arg" in
    --full) WANT_FULL=true ;;
    -h|--help)
      echo "Usage: db-sync.sh [--full]"
      echo ""
      echo "  --full   Take the complete dump even when a slim one is published."
      exit 0
      ;;
    *)
      echo "ERROR: unknown option '$arg' (try --help)"
      exit 1
      ;;
  esac
done

echo ""
echo "=== DB Sync ==="

ask_database
ask_server
resolve_dumps_dir
download_dumps
import_dumps

echo ""
echo "Done!"
