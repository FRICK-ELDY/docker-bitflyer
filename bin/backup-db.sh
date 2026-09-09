#!/usr/bin/env bash
# PostgreSQL 論理バックアップ（本番 Compose 向け）。
# 使い方（ホスト）:
#   ./bin/backup-db.sh
#   ./bin/backup-db.sh /path/to/dir
#
# 復元は architecture/env/prod.md の手順を正とする。
set -euo pipefail

COMPOSE_FILE="${COMPOSE_FILE:-compose.prod.yaml}"
ENV_FILE="${ENV_FILE:-.env.prod}"
OUT_DIR="${1:-./backups}"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
OUT_FILE="${OUT_DIR}/docker_bitflyer_prod_${STAMP}.sql.gz"

if [[ ! -f "${ENV_FILE}" ]]; then
  echo "missing ${ENV_FILE}. Copy from .env.example and set secrets." >&2
  exit 1
fi

mkdir -p "${OUT_DIR}"

# ホストで .env.prod を source しない（特殊文字の誤評価を避ける）。
# POSTGRES_* は起動時に db コンテナへ注入済みなので、コンテナ内の値で pg_dump する。
# --env-file は compose ファイル補間用（ホストシェルには載せない）。
echo "Backing up via compose service db -> ${OUT_FILE}"
docker compose -f "${COMPOSE_FILE}" --env-file "${ENV_FILE}" exec -T db \
  sh -c 'PGPASSWORD="$POSTGRES_PASSWORD" exec pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" --no-owner --format=plain' \
  | gzip -c > "${OUT_FILE}"

echo "Done: ${OUT_FILE}"
ls -lh "${OUT_FILE}"
