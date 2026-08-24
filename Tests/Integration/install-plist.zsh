#!/bin/zsh

set -euo pipefail

readonly SCRIPT_DIR="${0:A:h}"
readonly REPOSITORY_ROOT="${SCRIPT_DIR:h:h}"
readonly JQ="$(command -v jq || true)"
readonly TEST_ROOT="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/agent-awake-plist-test.XXXXXX")"
readonly OUTPUT="${TEST_ROOT}/com.sreekaran.agent-awake.plist"
readonly BINARY="/Users/test/Library/Application Support/AgentAwake/agent-awake"
readonly LOG_DIRECTORY="/Users/test/Library/Logs"

cleanup() {
  /bin/rm -rf "${TEST_ROOT}"
}
trap cleanup EXIT

"${REPOSITORY_ROOT}/Scripts/render-launch-agent.zsh" \
  "${REPOSITORY_ROOT}/Resources/LaunchAgents/com.sreekaran.agent-awake.plist" \
  "${OUTPUT}" \
  "${BINARY}" \
  "${LOG_DIRECTORY}"

arguments_json="$(/usr/bin/plutil -extract ProgramArguments json -o - "${OUTPUT}")"
if ! print -r -- "${arguments_json}" | "${JQ}" -e \
  --arg binary "${BINARY}" \
  '. == [$binary, "reconcile"]' >/dev/null; then
  print -u2 "rendered LaunchAgent must contain only the binary path and reconcile"
  print -u2 -- "${arguments_json}"
  exit 1
fi

[[ "$(/usr/bin/plutil -extract StandardErrorPath raw -o - "${OUTPUT}")" == "${LOG_DIRECTORY}/AgentAwake.error.log" ]]
[[ "$(/usr/bin/plutil -extract StandardOutPath raw -o - "${OUTPUT}")" == "${LOG_DIRECTORY}/AgentAwake.log" ]]

print "LaunchAgent plist render tests passed"
