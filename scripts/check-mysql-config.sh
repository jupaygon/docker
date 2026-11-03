#!/bin/bash

# =============================================================================
# check-mysql-config.sh — start a throwaway MySQL with this repo's conf.d and
# check what it must hold: binary logging off, and a healthcheck that passes
# right after a restart.
#
# Uses the same mysql:8.0 base as images/mysql/Dockerfile, the same root
# password as docker-compose.yml, and mounts images/mysql/conf.d read-only, so
# it checks the files as they are on disk without touching dj_mysql or its
# data. Exits non-zero when a check fails.
# =============================================================================

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NAME="dj-mysql-config-check-$$"
# The healthcheck of the mysql service in docker-compose.yml.
HEALTHCHECK=(mysqladmin ping -h 127.0.0.1 -ppassword --get-server-public-key)

trap 'docker rm -f "$NAME" >/dev/null 2>&1 || true' EXIT

wait_until_up() {
    for _ in $(seq 1 60); do
        docker exec "$NAME" mysql -uroot -ppassword -e 'SELECT 1' >/dev/null 2>&1 && return 0
        sleep 2
    done
    echo "FAIL: the server did not come up"
    exit 1
}

docker run --rm -d --name "$NAME" \
    -e MYSQL_ROOT_PASSWORD=password \
    -v "$ROOT/images/mysql/conf.d:/etc/mysql/conf.d:ro" \
    mysql:8.0 >/dev/null
wait_until_up

LOG_BIN="$(docker exec "$NAME" mysql -uroot -ppassword -N -e 'SELECT @@log_bin' 2>/dev/null)"
docker exec "$NAME" mysql -uroot -ppassword -e 'CREATE DATABASE config_check; CREATE TABLE config_check.t (id INT); INSERT INTO config_check.t VALUES (1);' 2>/dev/null
BINLOG_FILES="$(docker exec "$NAME" sh -c 'ls /var/lib/mysql | grep -c "^binlog\." || true')"

if [ "$LOG_BIN" != "0" ] || [ "$BINLOG_FILES" != "0" ]; then
    echo "FAIL: @@log_bin=$LOG_BIN, binlog files=$BINLOG_FILES (both must be 0)"
    exit 1
fi
echo "OK: binary logging is off (@@log_bin=0, no binlog files after a write)"

# A restart empties the server's authentication cache: the healthcheck must pass before anyone else logs in.
docker restart "$NAME" >/dev/null
for _ in $(seq 1 30); do
    if docker exec "$NAME" "${HEALTHCHECK[@]}" >/dev/null 2>&1; then
        echo "OK: the healthcheck passes right after a restart"
        exit 0
    fi
    sleep 2
done

echo "FAIL: the healthcheck does not pass after a restart: $(docker exec "$NAME" "${HEALTHCHECK[@]}" 2>&1 | tail -1)"
exit 1
