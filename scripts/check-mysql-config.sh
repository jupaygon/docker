#!/bin/bash

# =============================================================================
# check-mysql-config.sh — start a throwaway MySQL with this repo's conf.d and
# check what it must hold: binary logging off.
#
# Uses the same mysql:8.0 base as images/mysql/Dockerfile and mounts
# images/mysql/conf.d read-only, so it checks the files as they are on disk
# without touching dj_mysql or its data. Exits non-zero when a check fails.
# =============================================================================

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NAME="dj-mysql-config-check-$$"

trap 'docker rm -f "$NAME" >/dev/null 2>&1 || true' EXIT

docker run --rm -d --name "$NAME" \
    -e MYSQL_ALLOW_EMPTY_PASSWORD=yes \
    -v "$ROOT/images/mysql/conf.d:/etc/mysql/conf.d:ro" \
    mysql:8.0 >/dev/null

for _ in $(seq 1 60); do
    docker exec "$NAME" mysql -uroot -e 'SELECT 1' >/dev/null 2>&1 && break
    sleep 2
done

LOG_BIN="$(docker exec "$NAME" mysql -uroot -N -e 'SELECT @@log_bin')"
docker exec "$NAME" mysql -uroot -e 'CREATE DATABASE config_check; CREATE TABLE config_check.t (id INT); INSERT INTO config_check.t VALUES (1);'
BINLOG_FILES="$(docker exec "$NAME" sh -c 'ls /var/lib/mysql | grep -c "^binlog\." || true')"

if [ "$LOG_BIN" != "0" ] || [ "$BINLOG_FILES" != "0" ]; then
    echo "FAIL: @@log_bin=$LOG_BIN, binlog files=$BINLOG_FILES (both must be 0)"
    exit 1
fi

echo "OK: binary logging is off (@@log_bin=0, no binlog files after a write)"
