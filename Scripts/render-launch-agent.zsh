#!/bin/zsh

set -euo pipefail

readonly TEMPLATE="${1:?template path is required}"
readonly OUTPUT="${2:?output path is required}"
readonly BINARY="${3:?binary path is required}"
readonly LOG_DIRECTORY="${4:?log directory is required}"
readonly JQ="$(command -v jq || true)"

[[ -x "${JQ}" ]] || {
  print -u2 "jq is required to render the LaunchAgent"
  exit 1
}

/bin/cp "${TEMPLATE}" "${OUTPUT}"
arguments_json="$("${JQ}" -cn --arg binary "${BINARY}" '[$binary, "reconcile"]')"
/usr/bin/plutil -replace ProgramArguments -json "${arguments_json}" "${OUTPUT}"
/usr/bin/plutil -replace StandardErrorPath -string "${LOG_DIRECTORY}/AgentAwake.error.log" "${OUTPUT}"
/usr/bin/plutil -replace StandardOutPath -string "${LOG_DIRECTORY}/AgentAwake.log" "${OUTPUT}"
/usr/bin/plutil -lint "${OUTPUT}" >/dev/null
/bin/chmod 600 "${OUTPUT}"
