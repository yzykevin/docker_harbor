#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

MODE="auto" # auto|http|self-signed|custom
HOSTNAME_VALUE=""
HTTP_PORT="8080"
HTTPS_PORT="8443"
DATA_VOLUME=""
CERT_DIR="${ROOT_DIR}/certs"
CERT_FILE=""
KEY_FILE=""
MIN_FREE_GB="10"

PASS_COUNT=0
WARN_COUNT=0
FAIL_COUNT=0

usage() {
  cat <<'EOF'
Usage:
  ./scripts/preflight_check.sh [options]

Options:
  --mode <auto|http|self-signed|custom>   Check profile (default: auto)
  --hostname <value>                       Harbor hostname/IP (optional)
  --http-port <port>                       HTTP port (default: 8080)
  --https-port <port>                      HTTPS port (default: 8443)
  --data-volume <path>                     Harbor data volume path
  --cert-dir <path>                        Cert directory for self-signed mode
  --cert-file <path>                       Cert path for custom mode
  --key-file <path>                        Key path for custom mode
  --min-free-gb <num>                      Minimum free disk GB threshold (default: 10)
  -h, --help                               Show help
EOF
}

pass() {
  PASS_COUNT=$((PASS_COUNT + 1))
  printf '[PASS] %s\n' "$*"
}

warn() {
  WARN_COUNT=$((WARN_COUNT + 1))
  printf '[WARN] %s\n' "$*"
}

fail() {
  FAIL_COUNT=$((FAIL_COUNT + 1))
  printf '[FAIL] %s\n' "$*"
}

validate_port() {
  local value="$1"
  [[ "${value}" =~ ^[0-9]+$ ]] || return 1
  (( value >= 1 && value <= 65535 ))
}

detect_mode_from_config() {
  local cfg="${ROOT_DIR}/harbor.yml"
  if [[ ! -f "${cfg}" ]]; then
    printf '%s' "self-signed"
    return
  fi
  if grep -qE '^https:' "${cfg}"; then
    printf '%s' "self-signed"
    return
  fi
  printf '%s' "http"
}

detect_data_volume_from_config() {
  local cfg="${ROOT_DIR}/harbor.yml"
  if [[ -f "${cfg}" ]]; then
    local val
    val="$(awk '/^data_volume:/{print $2; exit}' "${cfg}" 2>/dev/null || true)"
    if [[ -n "${val}" ]]; then
      printf '%s' "${val}"
      return
    fi
  fi
  printf '%s' "${ROOT_DIR}/harbor-data"
}

port_listeners() {
  local port="$1"
  if command -v lsof >/dev/null 2>&1; then
    lsof -nP -iTCP:"${port}" -sTCP:LISTEN 2>/dev/null || true
    return
  fi
  if command -v ss >/dev/null 2>&1; then
    ss -lnt "( sport = :${port} )" 2>/dev/null | tail -n +2 || true
    return
  fi
  if command -v netstat >/dev/null 2>&1; then
    netstat -an 2>/dev/null | grep -E "[\.\:]${port}[[:space:]].*(LISTEN|LISTENING)" || true
    return
  fi
  true
}

days_until_expiry() {
  local cert="$1"
  local not_after now expiry days
  not_after="$(openssl x509 -in "${cert}" -noout -enddate | cut -d= -f2-)"
  if command -v date >/dev/null 2>&1; then
    if date -j -f "%b %e %T %Y %Z" "${not_after}" "+%s" >/dev/null 2>&1; then
      now="$(date +%s)"
      expiry="$(date -j -f "%b %e %T %Y %Z" "${not_after}" "+%s")"
    else
      now="$(date +%s)"
      expiry="$(date -d "${not_after}" +%s 2>/dev/null || echo 0)"
    fi
    if [[ "${expiry}" =~ ^[0-9]+$ ]] && (( expiry > 0 )); then
      days=$(( (expiry - now) / 86400 ))
      printf '%s' "${days}"
      return
    fi
  fi
  printf '%s' "unknown"
}

check_docker() {
  if command -v docker >/dev/null 2>&1; then
    pass "docker command found"
  else
    fail "docker command not found"
    return
  fi

  if docker info >/dev/null 2>&1; then
    pass "docker daemon reachable"
  else
    fail "docker daemon not reachable"
  fi
}

check_compose() {
  if docker compose version >/dev/null 2>&1; then
    pass "docker compose plugin available"
    return
  fi
  if docker-compose --version >/dev/null 2>&1; then
    pass "docker-compose available"
    return
  fi
  fail "docker compose / docker-compose not found"
}

check_ports() {
  local listeners
  listeners="$(port_listeners "${HTTP_PORT}")"
  if [[ -z "${listeners}" ]]; then
    pass "port ${HTTP_PORT} is free"
  else
    warn "port ${HTTP_PORT} is in use"
  fi

  if [[ "${MODE}" != "http" ]]; then
    listeners="$(port_listeners "${HTTPS_PORT}")"
    if [[ -z "${listeners}" ]]; then
      pass "port ${HTTPS_PORT} is free"
    else
      warn "port ${HTTPS_PORT} is in use"
    fi
  fi
}

check_disk() {
  local target free_kb free_gb
  target="${DATA_VOLUME}"
  if [[ ! -d "${target}" ]]; then
    target="$(dirname "${target}")"
  fi
  if [[ ! -d "${target}" ]]; then
    warn "disk check skipped: path does not exist (${target})"
    return
  fi
  free_kb="$(df -Pk "${target}" | awk 'NR==2{print $4}' 2>/dev/null || echo 0)"
  if ! [[ "${free_kb}" =~ ^[0-9]+$ ]]; then
    warn "disk check skipped: cannot parse free space"
    return
  fi
  free_gb=$(( free_kb / 1024 / 1024 ))
  if (( free_gb < MIN_FREE_GB )); then
    fail "low disk space on ${target}: ${free_gb}GB free (< ${MIN_FREE_GB}GB)"
  else
    pass "disk space on ${target}: ${free_gb}GB free"
  fi
}

check_bundle() {
  local bundle
  bundle="$(find "${ROOT_DIR}" -maxdepth 1 -type f -name 'harbor.v*.tar.gz' | head -n 1 || true)"
  if [[ -n "${bundle}" ]]; then
    pass "offline image bundle found: $(basename "${bundle}")"
  else
    warn "offline image bundle harbor.v*.tar.gz not found (skip if using --skip-load)"
  fi
}

check_certificates() {
  local cert key days
  if [[ "${MODE}" == "http" ]]; then
    pass "HTTP mode selected, certificate checks skipped"
    return
  fi

  if [[ "${MODE}" == "custom" ]]; then
    cert="${CERT_FILE}"
    key="${KEY_FILE}"
    [[ -n "${cert}" ]] || fail "custom mode requires --cert-file"
    [[ -n "${key}" ]] || fail "custom mode requires --key-file"
  else
    cert="${CERT_DIR}/harbor.fullchain.crt"
    key="${CERT_DIR}/harbor.key"
  fi

  if [[ -f "${cert}" ]]; then
    pass "certificate exists: ${cert}"
    days="$(days_until_expiry "${cert}")"
    if [[ "${days}" == "unknown" ]]; then
      warn "certificate expiry check skipped: cannot parse date"
    elif (( days < 0 )); then
      fail "certificate expired ${days#-} days ago: ${cert}"
    elif (( days < 30 )); then
      warn "certificate expires soon (${days} days): ${cert}"
    else
      pass "certificate expiry OK (${days} days left)"
    fi
  else
    fail "certificate missing: ${cert}"
  fi

  if [[ -f "${key}" ]]; then
    pass "private key exists: ${key}"
  else
    fail "private key missing: ${key}"
  fi
}

check_hostname_hint() {
  if [[ -z "${HOSTNAME_VALUE}" ]]; then
    warn "hostname not provided; ensure Harbor hostname is reachable from clients"
    return
  fi
  if [[ "${HOSTNAME_VALUE}" == "localhost" || "${HOSTNAME_VALUE}" == "127.0.0.1" ]]; then
    fail "hostname should not be localhost/127.0.0.1 for Harbor external clients"
  else
    pass "hostname set: ${HOSTNAME_VALUE}"
  fi
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --mode)
        MODE="${2:-}"
        shift 2
        ;;
      --hostname)
        HOSTNAME_VALUE="${2:-}"
        shift 2
        ;;
      --http-port)
        HTTP_PORT="${2:-}"
        shift 2
        ;;
      --https-port)
        HTTPS_PORT="${2:-}"
        shift 2
        ;;
      --data-volume)
        DATA_VOLUME="${2:-}"
        shift 2
        ;;
      --cert-dir)
        CERT_DIR="${2:-}"
        shift 2
        ;;
      --cert-file)
        CERT_FILE="${2:-}"
        shift 2
        ;;
      --key-file)
        KEY_FILE="${2:-}"
        shift 2
        ;;
      --min-free-gb)
        MIN_FREE_GB="${2:-}"
        shift 2
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        printf '[FAIL] Unknown option: %s\n' "$1"
        exit 2
        ;;
    esac
  done
}

main() {
  parse_args "$@"

  if [[ "${MODE}" == "auto" ]]; then
    MODE="$(detect_mode_from_config)"
  fi
  case "${MODE}" in
    http|self-signed|custom) ;;
    *)
      printf '[FAIL] Invalid mode: %s\n' "${MODE}"
      exit 2
      ;;
  esac
  validate_port "${HTTP_PORT}" || { printf '[FAIL] Invalid http port: %s\n' "${HTTP_PORT}"; exit 2; }
  validate_port "${HTTPS_PORT}" || { printf '[FAIL] Invalid https port: %s\n' "${HTTPS_PORT}"; exit 2; }
  [[ "${MIN_FREE_GB}" =~ ^[0-9]+$ ]] || { printf '[FAIL] Invalid --min-free-gb: %s\n' "${MIN_FREE_GB}"; exit 2; }

  if [[ -z "${DATA_VOLUME}" ]]; then
    DATA_VOLUME="$(detect_data_volume_from_config)"
  fi

  printf '[INFO] project root: %s\n' "${ROOT_DIR}"
  printf '[INFO] mode: %s\n' "${MODE}"
  printf '[INFO] data volume: %s\n' "${DATA_VOLUME}"

  check_docker
  check_compose
  check_ports
  check_disk
  check_bundle
  check_certificates
  check_hostname_hint

  printf '[INFO] summary: PASS=%d WARN=%d FAIL=%d\n' "${PASS_COUNT}" "${WARN_COUNT}" "${FAIL_COUNT}"
  if (( FAIL_COUNT > 0 )); then
    exit 1
  fi
}

main "$@"
