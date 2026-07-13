#!/bin/zsh

set -euo pipefail

export PATH=/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin

readonly SCRIPT_DIR="${0:A:h}"
readonly USER_ID="$(/usr/bin/id -u)"
readonly HOME_DIR="${HOME:?HOME is not set}"
readonly SUPPORT_DIR="${HOME_DIR}/Library/Application Support/AgentAwake"
readonly LIVE_BINARY="${SUPPORT_DIR}/agent-awake"
readonly LIVE_PLIST="${HOME_DIR}/Library/LaunchAgents/com.sreekaran.agent-awake.plist"
readonly BACKUP_DIR="${SUPPORT_DIR}/backups/$(/bin/date -u +%Y%m%dT%H%M%SZ)"
readonly JQ="$(command -v jq || true)"
readonly BUILD_ROOT="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/agent-awake-install.XXXXXX")"
readonly BUILD_BINARY="${BUILD_ROOT}/agent-awake"

cleanup() {
  /bin/rm -rf "${BUILD_ROOT}"
}
trap cleanup EXIT

[[ -x "${JQ}" ]] || {
  print -u2 "jq is required for safe JSON config merging"
  exit 1
}

"${SCRIPT_DIR}/build.zsh" "${BUILD_BINARY}"

/bin/mkdir -p "${BACKUP_DIR}" "${HOME_DIR}/Library/LaunchAgents"
/bin/chmod 700 "${SUPPORT_DIR}" "${BACKUP_DIR}"

backup_if_present() {
  local path="$1"
  if [[ -e "${path}" ]]; then
    /bin/cp -p "${path}" "${BACKUP_DIR}/$(print -r -- "${path}" | /usr/bin/sed 's#/#__#g')"
  fi
}

backup_if_present "${LIVE_BINARY}"
backup_if_present "${LIVE_PLIST}"
backup_if_present "${HOME_DIR}/.codex/hooks.json"
backup_if_present "${HOME_DIR}/.claude/settings.json"
backup_if_present "${HOME_DIR}/.cursor/hooks.json"

/bin/launchctl bootout "gui/${USER_ID}/com.sreekaran.agent-awake" 2>/dev/null || true

/bin/cp "${BUILD_BINARY}" "${SUPPORT_DIR}/agent-awake.new"
/bin/chmod 700 "${SUPPORT_DIR}/agent-awake.new"
/bin/mv -f "${SUPPORT_DIR}/agent-awake.new" "${LIVE_BINARY}"

"${SCRIPT_DIR}/render-launch-agent.zsh" \
  "${SCRIPT_DIR}/com.sreekaran.agent-awake.plist" \
  "${LIVE_PLIST}.new" \
  "${LIVE_BINARY}" \
  "${HOME_DIR}/Library/Logs"
/bin/mv -f "${LIVE_PLIST}.new" "${LIVE_PLIST}"

merge_json() {
  local target="$1"
  local filter="$2"
  local target_dir="${target:h}"
  local source_file="${target}"
  local empty_file=""
  local temporary_file="${target}.agent-awake.$$"

  /bin/mkdir -p "${target_dir}"
  if [[ ! -f "${source_file}" ]]; then
    empty_file="$(/usr/bin/mktemp "${TMPDIR:-/tmp}/agent-awake-json.XXXXXX")"
    print -r -- '{}' > "${empty_file}"
    source_file="${empty_file}"
  fi

  "${JQ}" --arg binary "${LIVE_BINARY}" -f "${filter}" "${source_file}" > "${temporary_file}"
  "${JQ}" -e . "${temporary_file}" >/dev/null
  /bin/chmod 600 "${temporary_file}"
  /bin/mv -f "${temporary_file}" "${target}"

  if [[ -n "${empty_file}" ]]; then
    /bin/rm -f "${empty_file}"
  fi
}

merge_json "${HOME_DIR}/.codex/hooks.json" "${SCRIPT_DIR}/merge-codex.jq"
merge_json "${HOME_DIR}/.claude/settings.json" "${SCRIPT_DIR}/merge-claude.jq"
merge_json "${HOME_DIR}/.cursor/hooks.json" "${SCRIPT_DIR}/merge-cursor.jq"

/bin/launchctl bootstrap "gui/${USER_ID}" "${LIVE_PLIST}"
/bin/launchctl kickstart -k "gui/${USER_ID}/com.sreekaran.agent-awake"

print "Agent Awake v2 installed"
print "Backups: ${BACKUP_DIR}"
