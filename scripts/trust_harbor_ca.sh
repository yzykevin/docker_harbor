#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

ACTION="status" # install | remove | status
CERT_FILE="${ROOT_DIR}/certs/ca.crt"

# macOS
MACOS_LOGIN_KEYCHAIN="${HOME}/Library/Keychains/login.keychain-db"
MACOS_SYSTEM_KEYCHAIN="/Library/Keychains/System.keychain"

# Linux
LINUX_CA_FILENAME="harbor-local-ca.crt"

# Windows (PowerShell CertStore path suffix)
WINDOWS_STORE="CurrentUser\\Root"

usage() {
  cat <<'EOF'
Preferred unified entry:
  make trust-install
  make trust-remove
  make trust-status

Usage:
  ./scripts/trust_harbor_ca.sh <install|remove|status> [options]

Actions:
  install                     Install and trust Harbor CA cert
  remove                      Remove Harbor CA cert trust
  status                      Show Harbor CA trust status

Options:
  --cert-file <path>          CA cert file (default: ./certs/ca.crt)
  --windows-store <store>     Windows cert store path suffix (default: CurrentUser\Root)
  -h, --help                  Show help

Linux:
  Uses update-ca-certificates (Debian/Ubuntu) or update-ca-trust (RHEL/Fedora).
  May require sudo/root.
EOF
}

log() {
  printf '[harbor-trust] %s\n' "$*"
}

fail() {
  printf '[harbor-trust] ERROR: %s\n' "$*" >&2
  exit 1
}

parse_args() {
  if [[ $# -gt 0 && "$1" != --* ]]; then
    ACTION="$1"
    shift
  fi

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --cert-file)
        CERT_FILE="${2:-}"
        shift 2
        ;;
      --windows-store)
        WINDOWS_STORE="${2:-}"
        shift 2
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        fail "Unknown option: $1"
        ;;
    esac
  done

  case "${ACTION}" in
    install|remove|status) ;;
    *) fail "Action must be one of: install, remove, status" ;;
  esac
}

detect_platform() {
  case "$(uname -s)" in
    Darwin) printf '%s' "macos" ;;
    Linux) printf '%s' "linux" ;;
    MINGW*|MSYS*|CYGWIN*) printf '%s' "windows" ;;
    *)
      if command -v powershell.exe >/dev/null 2>&1; then
        printf '%s' "windows"
      else
        printf '%s' "unknown"
      fi
      ;;
  esac
}

get_cert_sha1() {
  local fp
  fp="$(openssl x509 -in "${CERT_FILE}" -noout -fingerprint -sha1 | awk -F= '{print $2}')"
  fp="${fp//:/}"
  printf '%s' "$(printf '%s' "${fp}" | tr '[:lower:]' '[:upper:]')"
}

to_upper() {
  printf '%s' "$1" | tr '[:lower:]' '[:upper:]'
}

run_as_root() {
  if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
    "$@"
    return
  fi
  if command -v sudo >/dev/null 2>&1; then
    sudo "$@"
    return
  fi
  fail "Need root privileges. Re-run as root or install sudo."
}

# macOS
macos_keychain_has_sha1() {
  local wanted="$1"
  local keychain="$2"
  local wanted_upper
  wanted_upper="$(to_upper "${wanted}")"
  local got
  while IFS= read -r got; do
    [[ "$(to_upper "${got}")" == "${wanted_upper}" ]] && return 0
  done < <(security find-certificate -a -Z "${keychain}" 2>/dev/null | awk '/SHA-1 hash:/{print $3}')
  return 1
}

macos_status() {
  local sha1 installed="false"
  sha1="$(get_cert_sha1)"
  if [[ -f "${MACOS_LOGIN_KEYCHAIN}" ]] && macos_keychain_has_sha1 "${sha1}" "${MACOS_LOGIN_KEYCHAIN}"; then
    log "status(login): installed"
    installed="true"
  else
    log "status(login): not installed"
  fi
  if [[ -f "${MACOS_SYSTEM_KEYCHAIN}" ]] && macos_keychain_has_sha1 "${sha1}" "${MACOS_SYSTEM_KEYCHAIN}"; then
    log "status(system): installed"
    installed="true"
  else
    log "status(system): not installed"
  fi
  if [[ "${installed}" == "true" ]]; then
    log "status: installed"
  else
    log "status: not installed"
  fi
}

macos_install() {
  local sha1
  sha1="$(get_cert_sha1)"
  if [[ -f "${MACOS_LOGIN_KEYCHAIN}" ]] && macos_keychain_has_sha1 "${sha1}" "${MACOS_LOGIN_KEYCHAIN}"; then
    log "already installed in login keychain."
    return
  fi
  security add-trusted-cert -d -r trustRoot -k "${MACOS_LOGIN_KEYCHAIN}" "${CERT_FILE}"
  log "installed to login keychain."
}

macos_remove() {
  local sha1 removed="false"
  sha1="$(get_cert_sha1)"
  if [[ -f "${MACOS_LOGIN_KEYCHAIN}" ]] && macos_keychain_has_sha1 "${sha1}" "${MACOS_LOGIN_KEYCHAIN}"; then
    security delete-certificate -Z "${sha1}" "${MACOS_LOGIN_KEYCHAIN}" >/dev/null 2>&1 || true
    removed="true"
    log "removed from login keychain."
  fi
  if [[ -f "${MACOS_SYSTEM_KEYCHAIN}" ]] && macos_keychain_has_sha1 "${sha1}" "${MACOS_SYSTEM_KEYCHAIN}"; then
    security delete-certificate -Z "${sha1}" "${MACOS_SYSTEM_KEYCHAIN}" >/dev/null 2>&1 || true
    removed="true"
    log "removed from system keychain."
  fi
  [[ "${removed}" == "true" ]] || log "certificate not found in macOS keychains."
}

# Linux
linux_target_path() {
  if command -v update-ca-certificates >/dev/null 2>&1; then
    printf '/usr/local/share/ca-certificates/%s' "${LINUX_CA_FILENAME}"
    return
  fi
  if command -v update-ca-trust >/dev/null 2>&1; then
    printf '/etc/pki/ca-trust/source/anchors/%s' "${LINUX_CA_FILENAME}"
    return
  fi
  fail "No CA trust tool found (update-ca-certificates / update-ca-trust)."
}

linux_refresh_trust() {
  if command -v update-ca-certificates >/dev/null 2>&1; then
    run_as_root update-ca-certificates >/dev/null
    return
  fi
  if command -v update-ca-trust >/dev/null 2>&1; then
    run_as_root update-ca-trust extract >/dev/null
    return
  fi
  fail "No CA trust refresh tool found."
}

linux_installed_path() {
  local p1 p2 sha1 expected
  expected="$(get_cert_sha1)"
  p1="/usr/local/share/ca-certificates/${LINUX_CA_FILENAME}"
  p2="/etc/pki/ca-trust/source/anchors/${LINUX_CA_FILENAME}"

  for path in "${p1}" "${p2}"; do
    if [[ -f "${path}" ]]; then
      sha1="$(openssl x509 -in "${path}" -noout -fingerprint -sha1 | awk -F= '{print $2}')"
      sha1="${sha1//:/}"
      if [[ "$(to_upper "${sha1}")" == "$(to_upper "${expected}")" ]]; then
        printf '%s' "${path}"
        return
      fi
    fi
  done
}

linux_status() {
  local path
  path="$(linux_installed_path || true)"
  if [[ -n "${path}" ]]; then
    log "status: installed (${path})"
  else
    log "status: not installed"
  fi
}

linux_install() {
  local target
  target="$(linux_target_path)"
  run_as_root mkdir -p "$(dirname "${target}")"
  run_as_root cp "${CERT_FILE}" "${target}"
  run_as_root chmod 0644 "${target}"
  linux_refresh_trust
  log "installed to ${target}"
}

linux_remove() {
  local target removed="false"
  for target in \
    "/usr/local/share/ca-certificates/${LINUX_CA_FILENAME}" \
    "/etc/pki/ca-trust/source/anchors/${LINUX_CA_FILENAME}"; do
    if [[ -f "${target}" ]]; then
      run_as_root rm -f "${target}"
      removed="true"
      log "removed ${target}"
    fi
  done
  if [[ "${removed}" == "true" ]]; then
    linux_refresh_trust
  else
    log "certificate file not found in common Linux trust paths."
  fi
}

# Windows
powershell_cmd() {
  if command -v pwsh >/dev/null 2>&1; then
    printf '%s' "pwsh"
    return
  fi
  if command -v powershell.exe >/dev/null 2>&1; then
    printf '%s' "powershell.exe"
    return
  fi
  if command -v powershell >/dev/null 2>&1; then
    printf '%s' "powershell"
    return
  fi
  fail "PowerShell not found."
}

to_windows_path() {
  local path="$1"
  if command -v cygpath >/dev/null 2>&1; then
    cygpath -w "${path}"
    return
  fi
  printf '%s' "${path}"
}

windows_status() {
  local ps sha1 out store
  ps="$(powershell_cmd)"
  sha1="$(get_cert_sha1)"
  store="${WINDOWS_STORE//\\/\\\\}"
  out="$("${ps}" -NoProfile -Command "\$thumb='${sha1}'; \$hits=Get-ChildItem 'Cert:\\${store}' | Where-Object {\$_.Thumbprint -eq \$thumb}; if (\$hits) { 'installed' } else { 'not installed' }")"
  log "status: ${out}"
}

windows_install() {
  local ps store cert_path
  ps="$(powershell_cmd)"
  store="${WINDOWS_STORE//\\/\\\\}"
  cert_path="$(to_windows_path "${CERT_FILE}")"
  "${ps}" -NoProfile -Command "Import-Certificate -FilePath '${cert_path}' -CertStoreLocation 'Cert:\\${store}' | Out-Null"
  log "installed to Cert:\\${WINDOWS_STORE}"
}

windows_remove() {
  local ps sha1 store
  ps="$(powershell_cmd)"
  sha1="$(get_cert_sha1)"
  store="${WINDOWS_STORE//\\/\\\\}"
  "${ps}" -NoProfile -Command "\$thumb='${sha1}'; \$items=Get-ChildItem 'Cert:\\${store}' | Where-Object {\$_.Thumbprint -eq \$thumb}; if (\$items) { \$items | Remove-Item -Force; 'removed' } else { 'not found' }" >/dev/null
  log "remove attempted from Cert:\\${WINDOWS_STORE}"
}

main() {
  parse_args "$@"
  command -v openssl >/dev/null 2>&1 || fail "openssl command not found."
  [[ -f "${CERT_FILE}" ]] || fail "cert file not found: ${CERT_FILE}"

  local platform
  platform="$(detect_platform)"
  [[ "${platform}" != "unknown" ]] || fail "Unsupported platform for trust automation."

  log "platform: ${platform}"
  log "cert: ${CERT_FILE}"

  case "${platform}:${ACTION}" in
    macos:install) macos_install ;;
    macos:remove) macos_remove ;;
    macos:status) macos_status ;;
    linux:install) linux_install ;;
    linux:remove) linux_remove ;;
    linux:status) linux_status ;;
    windows:install) windows_install ;;
    windows:remove) windows_remove ;;
    windows:status) windows_status ;;
  esac
}

main "$@"
