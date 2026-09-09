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

mkdir -p "${OUT_DIR}"

if [[ -f "${ENV_FILE}" ]]; then
  # shellcheck disable=SC1090
  set -a
  # 値に空白があっても大体動くよう source
  source "${ENV_FILE}"
  set +a
fi

POSTGRES_USER="${POSTGRES_USER:-postgres}"
POSTGRES_DB="${POSTGRES_DB:-docker_bitflyer_prod}"
POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-}"

echo "Backing up ${POSTGRES_DB} via compose service db -> ${OUT_FILE}"
# コンテナ内でもパスワード認証が必要な構成に備え PGPASSWORD を渡す（unix socket trust でも無害）
docker compose -f "${COMPOSE_FILE}" --env-file "${ENV_FILE}" exec -T \
  -e "PGPASSWORD=${POSTGRES_PASSWORD}" db \
  pg_dump -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" --no-owner --format=plain \
  | gzip -c > "${OUT_FILE}"

echo "Done: ${OUT_FILE}"
ls -lh "${OUT_FILE}"
