#!/bin/zsh

set -euo pipefail

readonly BINARY="${1:?compiled binary path is required}"
readonly JQ="$(command -v jq || true)"
readonly TEST_ROOT="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/agent-awake-test.XXXXXX")"
readonly STATE_DIR="${TEST_ROOT}/state"
readonly BASE_DIR="${TEST_ROOT}/base"

[[ -x "${JQ}" ]] || {
  print -u2 "jq is required to run the fixture tests"
  exit 1
}

cleanup() {
  /bin/rm -rf "${TEST_ROOT}"
}
trap cleanup EXIT

run_hook() {
  local now="$1"
  local action="$2"
  local payload="$3"
  print -rn -- "${payload}" | \
    AGENT_AWAKE_DRY_RUN=1 \
    AGENT_AWAKE_TEST_NOW="${now}" \
    AGENT_AWAKE_STATE_DIR="${STATE_DIR}" \
    AGENT_AWAKE_BASE_DIR="${BASE_DIR}" \
    "${BINARY}" hook auto "${action}"
}

status() {
  AGENT_AWAKE_DRY_RUN=1 \
  AGENT_AWAKE_STATE_DIR="${STATE_DIR}" \
  AGENT_AWAKE_BASE_DIR="${BASE_DIR}" \
  "${BINARY}" status
}

assert_json() {
  local expression="$1"
  status | "${JQ}" -e "${expression}" >/dev/null
}

run_hook 100 start '{"session_id":"codex-session","turn_id":"turn-1","hook_event_name":"UserPromptSubmit"}'
assert_json '.leaseCount == 1 and .sources.codex == 1 and .amphetamineActive == true and .amphetamineOwned == true'

CURSOR_VERSION=3.12 run_hook 101 start '{"conversation_id":"cursor-session","generation_id":"generation-1","hook_event_name":"beforeSubmitPrompt"}'
assert_json '.leaseCount == 2 and .sources.codex == 1 and .sources.cursor == 1'

run_hook 102 stop '{"session_id":"codex-session","turn_id":"turn-1","hook_event_name":"Stop"}'
assert_json '.leaseCount == 1 and .sources.cursor == 1 and .amphetamineActive == true'

CURSOR_VERSION=3.12 run_hook 103 stop '{"conversation_id":"cursor-session","generation_id":"generation-1","hook_event_name":"stop"}'
assert_json '.leaseCount == 0 and .amphetamineActive == true and .shutdownNotBefore == 118'

AGENT_AWAKE_DRY_RUN=1 \
AGENT_AWAKE_TEST_NOW=119 \
AGENT_AWAKE_STATE_DIR="${STATE_DIR}" \
AGENT_AWAKE_BASE_DIR="${BASE_DIR}" \
"${BINARY}" reconcile
assert_json '.leaseCount == 0 and .amphetamineActive == false and .amphetamineOwned == false'

CURSOR_VERSION=3.12 run_hook 200 heartbeat '{"conversation_id":"cursor-session-2","generation_id":"generation-2","hook_event_name":"afterAgentThought"}'
assert_json '.leaseCount == 1 and .sources.cursor == 1 and .amphetamineActive == true'

CURSOR_VERSION=3.12 CURSOR_CODE_REMOTE=true run_hook 201 start '{"conversation_id":"remote-session","generation_id":"remote-generation","hook_event_name":"beforeSubmitPrompt"}'
assert_json '.leaseCount == 1 and .sources.cursor == 1'

run_hook 202 start '{"session_id":"claude-session","hook_event_name":"UserPromptSubmit"}'
run_hook 203 heartbeat '{"session_id":"claude-session","hook_event_name":"PostToolUse"}'
assert_json '.leaseCount == 2 and .sources.cursor == 1 and .sources.claude == 1'

run_hook 204 stop-session '{"session_id":"claude-session","hook_event_name":"SessionEnd"}'
assert_json '.leaseCount == 1 and .sources.cursor == 1'

AGENT_AWAKE_DRY_RUN=1 \
AGENT_AWAKE_TEST_NOW=29004 \
AGENT_AWAKE_STATE_DIR="${STATE_DIR}" \
AGENT_AWAKE_BASE_DIR="${BASE_DIR}" \
"${BINARY}" reconcile
assert_json '.leaseCount == 0 and .amphetamineActive == false and .amphetamineOwned == false'

"${BINARY}" __self-test-large-process-output > "${TEST_ROOT}/large-output-status.json" &
process_test_pid=$!
process_test_finished=false
for _ in {1..30}; do
  if ! /bin/kill -0 "${process_test_pid}" 2>/dev/null; then
    wait "${process_test_pid}"
    process_test_finished=true
    break
  fi
  /bin/sleep 0.1
done
if [[ "${process_test_finished}" != true ]]; then
  /bin/kill "${process_test_pid}" 2>/dev/null || true
  wait "${process_test_pid}" 2>/dev/null || true
  print -u2 "process snapshot reconciliation deadlocked"
  exit 1
fi
"${JQ}" -e \
  '.status == 0 and .bytes > 1000000' \
  "${TEST_ROOT}/large-output-status.json" >/dev/null

print "agent-awake fixture tests passed"
