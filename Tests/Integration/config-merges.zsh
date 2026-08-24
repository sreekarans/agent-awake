#!/bin/zsh

set -euo pipefail

readonly SCRIPT_DIR="${0:A:h}"
readonly REPOSITORY_ROOT="${SCRIPT_DIR:h:h}"
readonly HOOKS_DIR="${REPOSITORY_ROOT}/Resources/Hooks"
readonly JQ="$(command -v jq || true)"
readonly BINARY="/Users/test/Library/Application Support/AgentAwake/agent-awake"
readonly TEST_ROOT="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/agent-awake-merge-test.XXXXXX")"

[[ -x "${JQ}" ]] || {
  print -u2 "jq is required to run the config merge tests"
  exit 1
}

cleanup() {
  /bin/rm -rf "${TEST_ROOT}"
}
trap cleanup EXIT

print -r -- '{"description":"keep","hooks":{"Stop":[{"hooks":[{"type":"command","command":"/existing"}]}]}}' > "${TEST_ROOT}/codex.json"
print -r -- '{"theme":"dark","hooks":{"Stop":[{"hooks":[{"type":"command","command":"/existing"}]}]}}' > "${TEST_ROOT}/claude.json"
print -r -- '{"version":1,"custom":"keep","hooks":{"stop":[{"command":"/existing"}]}}' > "${TEST_ROOT}/cursor.json"

"${JQ}" --arg binary "${BINARY}" -f "${HOOKS_DIR}/codex.jq" "${TEST_ROOT}/codex.json" > "${TEST_ROOT}/codex-1.json"
"${JQ}" --arg binary "${BINARY}" -f "${HOOKS_DIR}/codex.jq" "${TEST_ROOT}/codex-1.json" > "${TEST_ROOT}/codex-2.json"
"${JQ}" --arg binary "${BINARY}" -e '
  .description == "keep"
  and (.hooks.UserPromptSubmit | length) == 1
  and (.hooks.PostToolUse | length) == 1
  and (.hooks.Stop | length) == 2
  and (.hooks.SessionEnd | length) == 1
  and .hooks.SessionEnd[0].hooks[0].timeout == 3
  and .hooks.UserPromptSubmit[0].hooks[0].command == (($binary | @sh) + " hook auto start")
  and .hooks.PostToolUse[0].hooks[0].command == (($binary | @sh) + " hook auto heartbeat")
  and ([.hooks.Stop[].hooks[].command] | map(select(contains("AgentAwake/agent-awake"))) | all(startswith(($binary | @sh) + " hook auto ")))
  and .hooks.SessionEnd[0].hooks[0].command == (($binary | @sh) + " hook auto stop-session")
  and ([.hooks.Stop[].hooks[].command] | map(select(contains("AgentAwake/agent-awake"))) | length) == 1
' "${TEST_ROOT}/codex-2.json" >/dev/null || {
  print -u2 "codex hook command did not shell-quote the Agent Awake binary path"
  exit 1
}

"${JQ}" --arg binary "${BINARY}" -f "${HOOKS_DIR}/claude.jq" "${TEST_ROOT}/claude.json" > "${TEST_ROOT}/claude-1.json"
"${JQ}" --arg binary "${BINARY}" -f "${HOOKS_DIR}/claude.jq" "${TEST_ROOT}/claude-1.json" > "${TEST_ROOT}/claude-2.json"
"${JQ}" --arg binary "${BINARY}" -e '
  .theme == "dark"
  and (.hooks.UserPromptSubmit | length) == 1
  and (.hooks.PostToolUse | length) == 1
  and (.hooks.PostToolUseFailure | length) == 1
  and (.hooks.Stop | length) == 2
  and (.hooks.StopFailure | length) == 1
  and (.hooks.SessionEnd | length) == 1
  and .hooks.UserPromptSubmit[0].hooks[0].command == (($binary | @sh) + " hook auto start")
  and .hooks.PostToolUse[0].hooks[0].command == (($binary | @sh) + " hook auto heartbeat")
  and ([.hooks.Stop[].hooks[].command] | map(select(contains("AgentAwake/agent-awake"))) | all(startswith(($binary | @sh) + " hook auto ")))
  and .hooks.SessionEnd[0].hooks[0].command == (($binary | @sh) + " hook auto stop-session")
  and ([.hooks.Stop[].hooks[].command] | map(select(contains("AgentAwake/agent-awake"))) | length) == 1
' "${TEST_ROOT}/claude-2.json" >/dev/null || {
  print -u2 "claude hook command did not shell-quote the Agent Awake binary path"
  exit 1
}

"${JQ}" --arg binary "${BINARY}" -f "${HOOKS_DIR}/cursor.jq" "${TEST_ROOT}/cursor.json" > "${TEST_ROOT}/cursor-1.json"
"${JQ}" --arg binary "${BINARY}" -f "${HOOKS_DIR}/cursor.jq" "${TEST_ROOT}/cursor-1.json" > "${TEST_ROOT}/cursor-2.json"
"${JQ}" --arg binary "${BINARY}" -e '
  .version == 1
  and .custom == "keep"
  and (.hooks.beforeSubmitPrompt | length) == 1
  and (.hooks.afterAgentThought | length) == 1
  and (.hooks.afterAgentResponse | length) == 1
  and (.hooks.postToolUse | length) == 1
  and (.hooks.postToolUseFailure | length) == 1
  and (.hooks.stop | length) == 2
  and (.hooks.sessionEnd | length) == 1
  and .hooks.beforeSubmitPrompt[0].command == (($binary | @sh) + " hook auto start")
  and .hooks.afterAgentThought[0].command == (($binary | @sh) + " hook auto heartbeat")
  and ([.hooks.stop[].command] | map(select(contains("AgentAwake/agent-awake"))) | all(startswith(($binary | @sh) + " hook auto ")))
  and .hooks.sessionEnd[0].command == (($binary | @sh) + " hook auto stop-session")
  and ([.hooks.stop[].command] | map(select(contains("AgentAwake/agent-awake"))) | length) == 1
' "${TEST_ROOT}/cursor-2.json" >/dev/null || {
  print -u2 "cursor hook command did not shell-quote the Agent Awake binary path"
  exit 1
}

print "hook config merge tests passed"
