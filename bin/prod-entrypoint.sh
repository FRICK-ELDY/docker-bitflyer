#!/bin/sh
# 本番 release 用。DB 待ち → migrate → サーバ起動。シークレットは環境変数のみ。
set -eu

DB_HOST="${DB_HOST:-db}"
DB_PORT="${DB_PORT:-5432}"
DB_USER="${POSTGRES_USER:-postgres}"
DB_NAME="${POSTGRES_DB:-docker_bitflyer_prod}"
RELEASE_BIN="${RELEASE_BIN:-/app/bin/docker_bitflyer}"

wait_for_db() {
  echo "Waiting for PostgreSQL at ${DB_HOST}:${DB_PORT}..."
  i=0
  while [ "$i" -lt 60 ]; do
    if pg_isready -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" >/dev/null 2>&1; then
      echo "PostgreSQL is ready."
      return 0
    fi
    i=$((i + 1))
    sleep 1
  done
  echo "PostgreSQL did not become ready in time." >&2
  return 1
}

run_migrate() {
  wait_for_db
  echo "Running migrations..."
  "$RELEASE_BIN" eval "Bitflyer.Release.migrate()"
}

case "${1:-}" in
  bin/docker_bitflyer|*/bin/docker_bitflyer|/app/bin/server|bin/server|*/bin/server)
    run_migrate
    ;;
esac

exec "$@"
