#!/usr/bin/env bash
# 本番相当の入れ替え（実弾なし検証・本番PC 共通の骨）。
# 発注停止の確認なしに TRADE_MODE=live を再開しない。
#
# 使い方:
#   ./bin/deploy-prod.sh                  # ローカル build + up
#   APP_IMAGE=ghcr.io/...@sha256:... ./bin/deploy-prod.sh
#   ./bin/deploy-prod.sh rollback ghcr.io/...@sha256:<previous>
set -euo pipefail

COMPOSE_FILE="${COMPOSE_FILE:-compose.prod.yaml}"
ENV_FILE="${ENV_FILE:-.env.prod}"
MODE="${1:-deploy}"

require_env_file() {
  if [[ ! -f "${ENV_FILE}" ]]; then
    echo "missing ${ENV_FILE}. Copy from .env.example and set secrets." >&2
    exit 1
  fi
}

# KEY=value をシェル評価なしで読む（source しない。.env の $ や空白を壊さない）。
env_file_get() {
  local key="$1"
  local line val
  line="$(grep -E "^${key}=" "${ENV_FILE}" 2>/dev/null | head -n1 || true)"
  [[ -z "${line}" ]] && return 0
  val="${line#*=}"
  val="${val%$'\r'}"
  # 両端の対応する引用符だけ外す
  if [[ "${val}" == \"*\" ]]; then
    val="${val:1:${#val}-2}"
  elif [[ "${val}" == \'*\' ]]; then
    val="${val:1:${#val}-2}"
  fi
  printf '%s' "${val}"
}

load_env_file() {
  # compose の --env-file はシェル変数に入らない。スクリプトが使う 2 キーだけ取り出す。
  APP_IMAGE="${APP_IMAGE:-$(env_file_get APP_IMAGE)}"
  APP_HOST_PORT="${APP_HOST_PORT:-$(env_file_get APP_HOST_PORT)}"
}

compose() {
  docker compose -f "${COMPOSE_FILE}" --env-file "${ENV_FILE}" "$@"
}

record_current_image() {
  local id
  id="$(compose images -q app 2>/dev/null || true)"
  if [[ -n "${id}" ]]; then
    mkdir -p .deploy
    echo "${id}" > .deploy/previous-app-image-id
    # ローカル build は RepoDigests が空になり得る。index 0 は範囲外になるので range で書く。
    docker image inspect --format \
      '{{range .RepoDigests}}{{println .}}{{end}}{{range .RepoTags}}{{println .}}{{end}}' \
      "${id}" > .deploy/previous-app-image.txt 2>/dev/null || true
    echo "Recorded previous app image -> .deploy/previous-app-image.txt"
  fi
}

wait_healthy() {
  # APP_HOST_PORT 例: 127.0.0.1:4001 → ホスト側ヘルスは 4001
  local host_port="${APP_HOST_PORT:-127.0.0.1:4000}"
  local port="${host_port##*:}"
  port="${port:-4000}"

  echo "Waiting for app healthy on 127.0.0.1:${port}..."
  local i=0
  while [[ "$i" -lt 60 ]]; do
    if [[ -n "$(compose ps --status running -q app 2>/dev/null || true)" ]]; then
      if curl -fsS "http://127.0.0.1:${port}/health/live" >/dev/null 2>&1; then
        echo "app /health/live OK"
        return 0
      fi
    fi
    i=$((i + 1))
    sleep 2
  done
  echo "app did not become healthy in time" >&2
  compose logs --tail=80 app || true
  exit 1
}

require_env_file
load_env_file

case "${MODE}" in
  deploy)
    record_current_image
    if [[ -n "${APP_IMAGE:-}" ]]; then
      echo "Pulling ${APP_IMAGE}"
      compose pull app || true
      compose up -d --no-build
    else
      echo "Building local image (APP_IMAGE unset)"
      compose up -d --build
    fi
    wait_healthy
    echo "Deploy finished. Check /health/ready and logs before any live unlock."
    ;;
  rollback)
    PREV="${2:-}"
    if [[ -z "${PREV}" ]]; then
      echo "usage: $0 rollback <image-ref-or-digest>" >&2
      exit 1
    fi
    export APP_IMAGE="${PREV}"
    echo "Rolling back to ${APP_IMAGE}"
    compose pull app || true
    compose up -d --no-build
    wait_healthy
    echo "Rollback finished."
    ;;
  *)
    echo "usage: $0 [deploy|rollback <image>]" >&2
    exit 1
    ;;
esac
