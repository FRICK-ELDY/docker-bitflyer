#!/usr/bin/env bash
# mix deps.audit --format=json の結果を 3 値に分ける。
# 実行ビットは不要: bash bin/classify-deps-audit.sh <json> <exit_code> [meta]
#
# outcome:
#   clean                      — exit 0 かつ "pass":true
#   vulnerabilities_found      — JSON に "pass":false（ゲート失敗）
#   audit_tool_or_fetch_failed — タスク未定義・取得失敗など
#
# 終了: 0 = 配布を止めない（clean / ツール障害）
#       1 = advisory 検出
#       2 = 使い方誤り
set -euo pipefail

if [[ $# -lt 2 || $# -gt 3 ]]; then
  echo "usage: bash bin/classify-deps-audit.sh <json> <exit_code> [meta]" >&2
  exit 2
fi

json_path="$1"
json_exit="$2"
meta_path="${3:-}"

if [[ ! "${json_exit}" =~ ^[0-9]+$ ]]; then
  echo "exit_code must be an integer" >&2
  exit 2
fi

# pretty / 空白入りでも "pass" を読む。jq はコンテナに無い前提。
json_pass() {
  local compact
  compact="$(tr -d '[:space:]' <"$1" 2>/dev/null || true)"
  case "${compact}" in
    *'"pass":false'*) echo false ;;
    *'"pass":true'*) echo true ;;
    *) echo unknown ;;
  esac
}

outcome="audit_tool_or_fetch_failed"
pass="$(json_pass "${json_path}")"

if [[ "${pass}" == "false" ]]; then
  outcome="vulnerabilities_found"
elif [[ "${json_exit}" -eq 0 && "${pass}" == "true" ]]; then
  outcome="clean"
fi

{
  echo "json_exit=${json_exit}"
  echo "outcome=${outcome}"
} | if [[ -n "${meta_path}" ]]; then
  tee "${meta_path}"
else
  cat
fi

if [[ "${outcome}" == "vulnerabilities_found" ]]; then
  if [[ "${GITHUB_ACTIONS:-}" == "true" ]]; then
    echo "::error::mix deps.audit found Hex advisories (see artifact deps-audit-report)."
  fi
  exit 1
fi

if [[ "${outcome}" == "audit_tool_or_fetch_failed" ]]; then
  if [[ "${GITHUB_ACTIONS:-}" == "true" ]]; then
    echo "::warning::mix deps.audit tool/fetch failed (exit ${json_exit}). Advisory gate skipped; inspect artifact deps-audit-report."
  else
    echo "mix deps.audit tool/fetch failed (exit ${json_exit}); not failing the gate" >&2
  fi
fi

exit 0
