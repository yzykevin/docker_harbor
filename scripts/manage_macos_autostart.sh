#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
PLIST_NAME="com.harbor.local.autostart"
PLIST_PATH="${HOME}/Library/LaunchAgents/${PLIST_NAME}.plist"
LOG_DIR="${ROOT_DIR}/tmp"
STDOUT_LOG="${LOG_DIR}/harbor-autostart.out.log"
STDERR_LOG="${LOG_DIR}/harbor-autostart.err.log"
ACTION="status"

usage() {
  cat <<'USAGE'
Preferred unified entry:
  make autostart-install
  make autostart-remove
  make autostart-status

Usage:
  ./scripts/manage_macos_autostart.sh <install|remove|status>

Notes:
  - macOS only (launchd).
  - On login, it runs: make boot
USAGE
}

log() {
  printf '[harbor-autostart] %s\n' "$*"
}

fail() {
  printf '[harbor-autostart] ERROR: %s\n' "$*" >&2
  exit 1
}

ensure_macos() {
  [[ "$(uname -s)" == "Darwin" ]] || fail "This command only supports macOS."
}

write_plist() {
  mkdir -p "$(dirname "${PLIST_PATH}")"
  mkdir -p "${LOG_DIR}"

  cat > "${PLIST_PATH}" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${PLIST_NAME}</string>

  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>-lc</string>
    <string>cd '${ROOT_DIR}' && make boot</string>
  </array>

  <key>RunAtLoad</key>
  <true/>

  <key>StandardOutPath</key>
  <string>${STDOUT_LOG}</string>

  <key>StandardErrorPath</key>
  <string>${STDERR_LOG}</string>
</dict>
</plist>
PLIST
}

load_agent() {
  launchctl bootout "gui/$(id -u)/${PLIST_NAME}" >/dev/null 2>&1 || true
  launchctl bootstrap "gui/$(id -u)" "${PLIST_PATH}"
  launchctl enable "gui/$(id -u)/${PLIST_NAME}" >/dev/null 2>&1 || true
}

unload_agent() {
  launchctl bootout "gui/$(id -u)/${PLIST_NAME}" >/dev/null 2>&1 || true
  launchctl disable "gui/$(id -u)/${PLIST_NAME}" >/dev/null 2>&1 || true
}

status_agent() {
  if [[ -f "${PLIST_PATH}" ]]; then
    log "plist: installed (${PLIST_PATH})"
  else
    log "plist: not installed"
  fi

  if launchctl print "gui/$(id -u)/${PLIST_NAME}" >/dev/null 2>&1; then
    log "launchd: loaded"
  else
    log "launchd: not loaded"
  fi

  log "stdout log: ${STDOUT_LOG}"
  log "stderr log: ${STDERR_LOG}"
}

main() {
  if [[ $# -gt 0 ]]; then
    ACTION="$1"
    shift
  fi

  [[ $# -eq 0 ]] || fail "Unexpected arguments: $*"
  ensure_macos

  case "${ACTION}" in
    install)
      write_plist
      load_agent
      log "installed and loaded (${PLIST_PATH})"
      ;;
    remove)
      unload_agent
      rm -f "${PLIST_PATH}"
      log "removed (${PLIST_PATH})"
      ;;
    status)
      status_agent
      ;;
    -h|--help|help)
      usage
      ;;
    *)
      fail "Action must be install|remove|status"
      ;;
  esac
}

main "$@"
