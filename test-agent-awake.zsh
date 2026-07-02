#!/bin/zsh

set -euo pipefail

readonly BINARY="${1:?compiled binary path is required}"
readonly JQ="$(command -v jq || true)"
readonly TEST_ROOT="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/agent-awake-test.XXXXXX")"
readonly STATE_DIR="${TEST_ROOT}/state"
readonly BASE_DIR="${TEST_ROOT}/base"
readonly HISTORY_FILE="${BASE_DIR}/history.jsonl"

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

history_json() {
  local file
  for file in "${BASE_DIR}"/history.jsonl*(N); do
    /bin/cat "${file}"
  done
}

assert_history() {
  local expression="$1"
  history_json | "${JQ}" -s -e "${expression}" >/dev/null
}

run_hook 100 start '{"session_id":"codex-session","turn_id":"turn-1","hook_event_name":"UserPromptSubmit"}'
assert_json '.leaseCount == 1 and .sources.codex == 1 and .amphetamineActive == true and .amphetamineOwned == true'

CURSOR_VERSION=3.12 run_hook 101 start '{"conversation_id":"cursor-session","generation_id":"generation-1","hook_event_name":"beforeSubmitPrompt"}'
assert_json '.leaseCount == 2 and .sources.codex == 1 and .sources.cursor == 1'

run_hook 102 stop '{"session_id":"codex-session","turn_id":"turn-1","hook_event_name":"Stop"}'
assert_json '.leaseCount == 1 and .sources.cursor == 1 and .amphetamineActive == true'
assert_history '
  any(.[]; .type == "lease_removed" and .source == "codex" and .reason == "turn_stopped")
  and any(.[]; .type == "reconcile" and .result == "active_leases" and .leaseCountAfter == 1)
'

CURSOR_VERSION=3.12 run_hook 103 stop '{"conversation_id":"cursor-session","generation_id":"generation-1","hook_event_name":"stop"}'
assert_json '.leaseCount == 0 and .amphetamineActive == true and .shutdownNotBefore == 118'

AGENT_AWAKE_DRY_RUN=1 \
AGENT_AWAKE_TEST_NOW=119 \
AGENT_AWAKE_STATE_DIR="${STATE_DIR}" \
AGENT_AWAKE_BASE_DIR="${BASE_DIR}" \
"${BINARY}" reconcile
assert_json '.leaseCount == 0 and .amphetamineActive == false and .amphetamineOwned == false'

run_hook 30000 start '{"session_id":"history-session","turn_id":"history-turn","prompt":"SUPER_SECRET_HISTORY_MARKER"}'
run_hook 30001 heartbeat '{"session_id":"history-session","turn_id":"history-turn","tool_input":"SUPER_SECRET_HISTORY_MARKER"}'
run_hook 30002 heartbeat '{"session_id":"history-session","turn_id":"history-turn"}'
run_hook 30003 heartbeat '{"session_id":"history-session","turn_id":"history-turn"}'
run_hook 30302 heartbeat '{"session_id":"history-session","turn_id":"history-turn"}'
assert_history '
  ([.[] | select(.type == "heartbeat" and .source == "codex")] | length) >= 1
  and any(.[]; .type == "heartbeat_summary" and .source == "codex" and .heartbeatCount == 3)
'
run_hook 30303 heartbeat '{"session_id":"history-session","turn_id":"history-turn"}'
run_hook 30304 stop '{"session_id":"history-session","turn_id":"history-turn"}'
assert_history '
  any(.[]; .type == "heartbeat_summary" and .source == "codex" and .heartbeatCount == 1)
  and any(.[]; .type == "lease_removed" and .source == "codex" and .reason == "turn_stopped")
'
if /usr/bin/grep -qE 'SUPER_SECRET_HISTORY_MARKER|history-session|history-turn' "${HISTORY_FILE}"; then
  print -u2 "structured history exposed raw hook data"
  exit 1
fi

readonly MIGRATION_ROOT="${TEST_ROOT}/migration"
/bin/mkdir -p "${MIGRATION_ROOT}/state" "${MIGRATION_ROOT}/base"
print -r -- '{"version":2,"leases":{"old-lease":{"source":"codex","sessionHash":"old-session-hash","turnHash":"old-turn-hash","createdAt":1,"refreshedAt":2,"expiresAt":9999,"owner":{"pid":999,"started":"old-start"}}},"dryRunAmphetamineActive":false}' > "${MIGRATION_ROOT}/state/state.json"
print -r -- '[]' > "${MIGRATION_ROOT}/processes.json"
AGENT_AWAKE_DRY_RUN=1 \
AGENT_AWAKE_TEST_NOW=10 \
AGENT_AWAKE_TEST_PROCESS_SNAPSHOT="${MIGRATION_ROOT}/processes.json" \
AGENT_AWAKE_STATE_DIR="${MIGRATION_ROOT}/state" \
AGENT_AWAKE_BASE_DIR="${MIGRATION_ROOT}/base" \
"${BINARY}" reconcile
AGENT_AWAKE_DRY_RUN=1 \
AGENT_AWAKE_STATE_DIR="${MIGRATION_ROOT}/state" \
AGENT_AWAKE_BASE_DIR="${MIGRATION_ROOT}/base" \
"${BINARY}" status | "${JQ}" -e '.version == 3 and .leaseCount == 0' >/dev/null
"${JQ}" -s -e 'any(.[]; .type == "lease_removed" and .reason == "owner_exited")' \
  "${MIGRATION_ROOT}/base/history.jsonl" >/dev/null

readonly PID_REUSE_ROOT="${TEST_ROOT}/pid-reuse"
/bin/mkdir -p "${PID_REUSE_ROOT}/state" "${PID_REUSE_ROOT}/base"
print -r -- '{"version":2,"leases":{"old-lease":{"source":"cursor","sessionHash":"old-session-hash","createdAt":1,"refreshedAt":2,"expiresAt":9999,"owner":{"pid":999,"started":"old-start"}}},"dryRunAmphetamineActive":false}' > "${PID_REUSE_ROOT}/state/state.json"
print -r -- '[{"pid":999,"parentPID":1,"started":"new-start","command":"/Applications/Cursor.app/Contents/MacOS/Cursor"}]' > "${PID_REUSE_ROOT}/processes.json"
AGENT_AWAKE_DRY_RUN=1 \
AGENT_AWAKE_TEST_NOW=10 \
AGENT_AWAKE_TEST_PROCESS_SNAPSHOT="${PID_REUSE_ROOT}/processes.json" \
AGENT_AWAKE_STATE_DIR="${PID_REUSE_ROOT}/state" \
AGENT_AWAKE_BASE_DIR="${PID_REUSE_ROOT}/base" \
"${BINARY}" reconcile
"${JQ}" -s -e 'any(.[]; .type == "lease_removed" and .reason == "owner_pid_reused")' \
  "${PID_REUSE_ROOT}/base/history.jsonl" >/dev/null

readonly ROTATION_ROOT="${TEST_ROOT}/rotation"
/bin/mkdir -p "${ROTATION_ROOT}/state" "${ROTATION_ROOT}/base"
for index in {1..12}; do
  print -rn -- "{\"session_id\":\"rotation-${index}\",\"turn_id\":\"turn-${index}\"}" | \
    AGENT_AWAKE_DRY_RUN=1 \
    AGENT_AWAKE_TEST_NOW="$((40000 + index))" \
    AGENT_AWAKE_HISTORY_FILE_BYTES=600 \
    AGENT_AWAKE_HISTORY_ARCHIVES=4 \
    AGENT_AWAKE_HISTORY_HOURLY_BYTES=1000000 \
    AGENT_AWAKE_STATE_DIR="${ROTATION_ROOT}/state" \
    AGENT_AWAKE_BASE_DIR="${ROTATION_ROOT}/base" \
    "${BINARY}" hook auto start
done
history_file_count=$(/usr/bin/find "${ROTATION_ROOT}/base" -maxdepth 1 -name 'history.jsonl*' | /usr/bin/wc -l | /usr/bin/tr -d ' ')
[[ "${history_file_count}" == 5 ]] || {
  print -u2 "history rotation did not keep exactly five files"
  exit 1
}

readonly CAP_ROOT="${TEST_ROOT}/cap"
/bin/mkdir -p "${CAP_ROOT}/state" "${CAP_ROOT}/base"
print -rn -- '{"session_id":"cap-session","turn_id":"cap-turn"}' | \
  AGENT_AWAKE_DRY_RUN=1 \
  AGENT_AWAKE_TEST_NOW=1000 \
  AGENT_AWAKE_HISTORY_HOURLY_BYTES=900 \
  AGENT_AWAKE_STATE_DIR="${CAP_ROOT}/state" \
  AGENT_AWAKE_BASE_DIR="${CAP_ROOT}/base" \
  "${BINARY}" hook auto start
"${JQ}" -s -e '([.[] | select(.type == "history_paused")] | length) == 1' \
  "${CAP_ROOT}/base/history.jsonl" >/dev/null
cap_size_before=$(/usr/bin/stat -f '%z' "${CAP_ROOT}/base/history.jsonl")
AGENT_AWAKE_DRY_RUN=1 \
AGENT_AWAKE_TEST_NOW=1001 \
AGENT_AWAKE_HISTORY_HOURLY_BYTES=900 \
AGENT_AWAKE_STATE_DIR="${CAP_ROOT}/state" \
AGENT_AWAKE_BASE_DIR="${CAP_ROOT}/base" \
"${BINARY}" reconcile
cap_size_after=$(/usr/bin/stat -f '%z' "${CAP_ROOT}/base/history.jsonl")
[[ "${cap_size_before}" == "${cap_size_after}" ]] || {
  print -u2 "history continued writing after the hourly limit"
  exit 1
}
AGENT_AWAKE_DRY_RUN=1 \
AGENT_AWAKE_TEST_NOW=3700 \
AGENT_AWAKE_HISTORY_HOURLY_BYTES=900 \
AGENT_AWAKE_STATE_DIR="${CAP_ROOT}/state" \
AGENT_AWAKE_BASE_DIR="${CAP_ROOT}/base" \
"${BINARY}" reconcile
"${JQ}" -s -e '([.[] | select(.type == "history_resumed")] | length) == 1' \
  "${CAP_ROOT}/base/history.jsonl" >/dev/null

readonly FAILURE_ROOT="${TEST_ROOT}/history-failure"
/bin/mkdir -p "${FAILURE_ROOT}/state" "${FAILURE_ROOT}/base/history.jsonl"
print -rn -- '{"session_id":"failure-session","turn_id":"failure-turn"}' | \
  AGENT_AWAKE_DRY_RUN=1 \
  AGENT_AWAKE_TEST_NOW=50000 \
  AGENT_AWAKE_STATE_DIR="${FAILURE_ROOT}/state" \
  AGENT_AWAKE_BASE_DIR="${FAILURE_ROOT}/base" \
  "${BINARY}" hook auto start
AGENT_AWAKE_DRY_RUN=1 \
AGENT_AWAKE_STATE_DIR="${FAILURE_ROOT}/state" \
AGENT_AWAKE_BASE_DIR="${FAILURE_ROOT}/base" \
"${BINARY}" status | "${JQ}" -e '.leaseCount == 1 and .amphetamineOwned == true' >/dev/null

CURSOR_VERSION=3.12 run_hook 200 heartbeat '{"conversation_id":"cursor-session-2","generation_id":"generation-2","hook_event_name":"afterAgentThought"}'
assert_json '.leaseCount == 1 and .sources.cursor == 1 and .amphetamineActive == true'
assert_history '
  any(.[]; .type == "missed_start_recovered" and .source == "cursor")
  and any(.[]; .type == "heartbeat" and .source == "cursor")
'

CURSOR_VERSION=3.12 CURSOR_CODE_REMOTE=true run_hook 201 start '{"conversation_id":"remote-session","generation_id":"remote-generation","hook_event_name":"beforeSubmitPrompt"}'
assert_json '.leaseCount == 1 and .sources.cursor == 1'
assert_history 'any(.[]; .type == "hook_ignored" and .source == "cursor" and .reason == "remote_or_background_cursor")'

run_hook 202 start '{"session_id":"claude-session","hook_event_name":"UserPromptSubmit"}'
run_hook 203 heartbeat '{"session_id":"claude-session","hook_event_name":"PostToolUse"}'
assert_json '.leaseCount == 2 and .sources.cursor == 1 and .sources.claude == 1'

run_hook 204 stop-session '{"session_id":"claude-session","hook_event_name":"SessionEnd"}'
assert_json '.leaseCount == 1 and .sources.cursor == 1'
assert_history '
  any(.[]; .type == "heartbeat" and .source == "claude")
  and any(.[]; .type == "lease_removed" and .source == "claude" and .reason == "session_ended")
'

AGENT_AWAKE_DRY_RUN=1 \
AGENT_AWAKE_TEST_NOW=29004 \
AGENT_AWAKE_STATE_DIR="${STATE_DIR}" \
AGENT_AWAKE_BASE_DIR="${BASE_DIR}" \
"${BINARY}" reconcile
assert_json '.leaseCount == 0 and .amphetamineActive == false and .amphetamineOwned == false'
assert_history '
  any(.[]; .type == "lease_removed" and .source == "cursor" and .reason == "expired")
  and any(.[]; .type == "amphetamine_stopped" and .result == "stopped")
'

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
