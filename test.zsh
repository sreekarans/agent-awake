#!/bin/zsh

set -euo pipefail

readonly SCRIPT_DIR="${0:A:h}"
readonly TEST_ROOT="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/agent-awake-suite.XXXXXX")"
readonly BINARY="${TEST_ROOT}/agent-awake"

cleanup() {
  /bin/rm -rf "${TEST_ROOT}"
}
trap cleanup EXIT

"${SCRIPT_DIR}/build.zsh" "${BINARY}"
"${SCRIPT_DIR}/Tests/Integration/controller.zsh" "${BINARY}"
"${SCRIPT_DIR}/Tests/Integration/config-merges.zsh"
"${SCRIPT_DIR}/Tests/Integration/install-plist.zsh"

print "all Agent Awake tests passed"
