#!/bin/bash
# Restores one database per dump file, on a first boot with an empty volume.
#
# docker-down.sh writes each database with `pg_dump --clean --if-exists <db>`,
# which carries no CREATE DATABASE. Dropping the dumps straight into
# /docker-entrypoint-initdb.d/ therefore ran all of them against POSTGRES_DB:
# every project's tables landed together in `app`, and the --clean of one dump
# tried to drop objects another one owned, which killed the boot outright.
#
# So the dumps are mounted at /dumps instead, and this script — which is what
# initdb runs — creates each database and loads its own file into it.
set -euo pipefail

DUMPS_DIR=/dumps

[ -d "$DUMPS_DIR" ] || { echo "No $DUMPS_DIR mounted, nothing to restore."; exit 0; }

shopt -s nullglob
for dump in "$DUMPS_DIR"/*.sql; do
    db="$(basename "$dump" .sql)"

    # A project may drop a split seed here as `<db>_1_schema_dump.sql` plus
    # `<db>_2_data_dump.sql`. Those are two halves of one database, not two
    # databases, and the project's own tooling is what loads them.
    case "$db" in
        *_1_schema_dump | *_2_data_dump) continue ;;
    esac

    echo "Restoring database '$db' from $(basename "$dump")..."
    psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d postgres \
        -c "CREATE DATABASE \"$db\" OWNER \"$POSTGRES_USER\""
    psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$db" -f "$dump" > /dev/null
done

echo "PostgreSQL dumps restored."
