#!/bin/sh
# 常駐起動時だけ DB 待ちと ash.setup を行う。`mix compile` などの単発コマンドでは走らない。
# Umbrella ルートには Mix app が無いため、ash.setup には domains を明示する。
set -eu

cd /app

DB_HOST="${DB_HOST:-db}"
DB_PORT="${DB_PORT:-5432}"
DB_USER="${POSTGRES_USER:-postgres}"
DB_NAME="${POSTGRES_DB:-docker_bitflyer_dev}"

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

run_setup() {
  wait_for_db
  mix deps.get
  mix ash.setup --domains Bitflyer.System,Bitflyer.Trading
}

case "${1:-}" in
  mix)
    if [ "${2:-}" = "phx.server" ]; then
      run_setup
    fi
    ;;
esac

exec "$@"
