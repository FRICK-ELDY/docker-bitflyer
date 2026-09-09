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

compose() {
  docker compose -f "${COMPOSE_FILE}" --env-file "${ENV_FILE}" "$@"
}

record_current_image() {
  local id
  id="$(compose images -q app 2>/dev/null || true)"
  if [[ -n "${id}" ]]; then
    mkdir -p .deploy
    echo "${id}" > .deploy/previous-app-image-id
    docker image inspect --format '{{index .RepoDigests 0}}{{"\n"}}{{index .RepoTags 0}}' "${id}" \
      > .deploy/previous-app-image.txt 2>/dev/null || true
    echo "Recorded previous app image -> .deploy/previous-app-image.txt"
  fi
}

wait_healthy() {
  echo "Waiting for app healthy..."
  local i=0
  while [[ "$i" -lt 60 ]]; do
    if compose ps --status running | grep -q app; then
      if curl -fsS "http://127.0.0.1:4000/health/live" >/dev/null 2>&1; then
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
