#!/usr/bin/env bash
# 取引ホストとは別のマシンで /health/ready を引く。
# 実行ビットは不要: bash bin/watch-ready.sh
# 同一ホストから叩いてもホスト死は検知できない。
#
# 単発（cron / Uptime Kuma の Command）:
#   READY_URL=https://bot.example/health/ready bash bin/watch-ready.sh
#
# 常駐（間隔 60s・連続失敗 3 で stderr に alert。監視ホストの systemd 等）:
#   READY_URL=... READY_LOOP=1 READY_INTERVAL=60 READY_STRIKES=3 bash bin/watch-ready.sh
#
# 終了 0: 単発が HTTP 200 かつ JSON status=ready
# 終了 1: 単発失敗。READY_LOOP=1 はアラート後も継続（SIGINT まで）
set -euo pipefail

URL="${READY_URL:?READY_URL is required (e.g. https://host/health/ready)}"
TIMEOUT="${READY_TIMEOUT:-5}"
LOOP="${READY_LOOP:-0}"
INTERVAL="${READY_INTERVAL:-60}"
STRIKES="${READY_STRIKES:-3}"

body_is_ready() {
  local file="$1"
  local compact
  compact="$(tr -d '[:space:]' <"${file}" 2>/dev/null || true)"
  [[ "${compact}" == *'"status":"ready"'* ]]
}

probe_once() {
  local tmp code
  tmp="$(mktemp)"
  code="$(curl -sS -o "${tmp}" -w '%{http_code}' --max-time "${TIMEOUT}" "${URL}" || true)"

  if [[ "${code}" == "200" ]] && body_is_ready "${tmp}"; then
    rm -f "${tmp}"
    return 0
  fi

  echo "ready probe failed http=${code}" >&2
  if [[ -s "${tmp}" ]]; then
    cat "${tmp}" >&2
    echo >&2
  fi
  rm -f "${tmp}"
  return 1
}

if [[ "${LOOP}" != "1" ]]; then
  probe_once
  exit $?
fi

fail_count=0

while true; do
  if probe_once; then
    fail_count=0
  else
    fail_count=$((fail_count + 1))
    if [[ "${fail_count}" -ge "${STRIKES}" ]]; then
      echo "ready watch alert strikes=${fail_count}" >&2
    fi
  fi
  sleep "${INTERVAL}"
done
