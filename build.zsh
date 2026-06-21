#!/bin/zsh

set -euo pipefail

readonly SCRIPT_DIR="${0:A:h}"
readonly OUTPUT="${1:-${SCRIPT_DIR}/build/agent-awake}"
readonly OUTPUT_DIR="${OUTPUT:h}"
readonly MODULE_CACHE="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/agent-awake-module-cache.XXXXXX")"

cleanup() {
  /bin/rm -rf "${MODULE_CACHE}"
}
trap cleanup EXIT

/bin/mkdir -p "${OUTPUT_DIR}"
CLANG_MODULE_CACHE_PATH="${MODULE_CACHE}" \
SWIFT_MODULE_CACHE_PATH="${MODULE_CACHE}" \
/usr/bin/xcrun swiftc -O "${SCRIPT_DIR}/AgentAwake.swift" -o "${OUTPUT}"

print "Built ${OUTPUT}"
