#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

ACTION="ensure" # ensure | renew | status
CERT_DIR="${ROOT_DIR}/certs"
HOSTNAME_VALUE=""
ALT_NAMES=""
CERT_DAYS="825"
CA_DAYS="3650"

CA_KEY_FILE=""
CA_CERT_FILE=""
SERVER_KEY_FILE=""
SERVER_CERT_FILE=""
SERVER_FULLCHAIN_FILE=""

usage() {
  cat <<'EOF'
Preferred unified entry:
  make cert-ensure CERT_ARGS="--hostname <ip>"
  make cert-renew CERT_ARGS="--hostname <ip> --alt-names DNS:localhost,IP:127.0.0.1"
  make cert-status

Usage:
  ./scripts/manage_harbor_certs.sh <ensure|renew|status> [options]

Options:
  --hostname <value>       Required for ensure/renew. Harbor hostname or IP.
  --alt-names <list>       Extra SAN entries, comma separated (example: DNS:harbor.local,IP:192.168.1.10)
  --cert-dir <path>        Cert output dir (default: ./certs)
  --cert-days <days>       Server cert validity days (default: 825)
  --ca-days <days>         CA cert validity days (default: 3650)
  -h, --help               Show help

Output files:
  ca.key, ca.crt, harbor.key, harbor.crt, harbor.fullchain.crt
EOF
}

log() {
  printf '[harbor-certs] %s\n' "$*"
}

fail() {
  printf '[harbor-certs] ERROR: %s\n' "$*" >&2
  exit 1
}

validate_number() {
  local value="$1"
  local name="$2"
  if ! [[ "${value}" =~ ^[0-9]+$ ]]; then
    fail "${name} must be a number."
  fi
  if (( value < 1 )); then
    fail "${name} must be positive."
  fi
}

is_ipv4() {
  [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]
}

set_file_paths() {
  CA_KEY_FILE="${CERT_DIR}/ca.key"
  CA_CERT_FILE="${CERT_DIR}/ca.crt"
  SERVER_KEY_FILE="${CERT_DIR}/harbor.key"
  SERVER_CERT_FILE="${CERT_DIR}/harbor.crt"
  SERVER_FULLCHAIN_FILE="${CERT_DIR}/harbor.fullchain.crt"
}

parse_args() {
  if [[ $# -gt 0 && "$1" != --* ]]; then
    ACTION="$1"
    shift
  fi

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --hostname)
        HOSTNAME_VALUE="${2:-}"
        shift 2
        ;;
      --alt-names)
        ALT_NAMES="${2:-}"
        shift 2
        ;;
      --cert-dir)
        CERT_DIR="${2:-}"
        shift 2
        ;;
      --cert-days)
        CERT_DAYS="${2:-}"
        shift 2
        ;;
      --ca-days)
        CA_DAYS="${2:-}"
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
    ensure|renew|status) ;;
    *) fail "Action must be one of: ensure, renew, status" ;;
  esac
}

build_san_list() {
  local san
  if is_ipv4 "${HOSTNAME_VALUE}"; then
    san="IP:${HOSTNAME_VALUE}"
  else
    san="DNS:${HOSTNAME_VALUE}"
  fi

  if [[ -n "${ALT_NAMES}" ]]; then
    san="${san},${ALT_NAMES}"
  fi

  printf '%s' "${san}"
}

create_ca_if_missing() {
  if [[ -f "${CA_KEY_FILE}" && -f "${CA_CERT_FILE}" ]]; then
    return
  fi

  log "Creating local CA certificate..."
  openssl genrsa -out "${CA_KEY_FILE}" 4096 >/dev/null 2>&1
  openssl req -x509 -new -nodes \
    -key "${CA_KEY_FILE}" \
    -sha256 \
    -days "${CA_DAYS}" \
    -subj "/C=CN/ST=Local/L=Local/O=HarborLocal/CN=Harbor Local CA" \
    -out "${CA_CERT_FILE}" >/dev/null 2>&1
}

issue_server_cert() {
  local san_list="$1"
  local tmp_cfg="${CERT_DIR}/.harbor-cert-ext.cnf"
  local tmp_csr="${CERT_DIR}/.harbor-cert.csr"

  cat > "${tmp_cfg}" <<EOF
[req]
distinguished_name=req_distinguished_name
prompt=no

[req_distinguished_name]
CN=${HOSTNAME_VALUE}

[v3_req]
basicConstraints = critical, CA:FALSE
keyUsage = critical, digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = ${san_list}
EOF

  log "Issuing server certificate for ${HOSTNAME_VALUE} ..."
  openssl genrsa -out "${SERVER_KEY_FILE}" 4096 >/dev/null 2>&1
  openssl req -new \
    -key "${SERVER_KEY_FILE}" \
    -out "${tmp_csr}" \
    -config "${tmp_cfg}" >/dev/null 2>&1

  openssl x509 -req \
    -in "${tmp_csr}" \
    -CA "${CA_CERT_FILE}" \
    -CAkey "${CA_KEY_FILE}" \
    -CAcreateserial \
    -out "${SERVER_CERT_FILE}" \
    -days "${CERT_DAYS}" \
    -sha256 \
    -extensions v3_req \
    -extfile "${tmp_cfg}" >/dev/null 2>&1

  cat "${SERVER_CERT_FILE}" "${CA_CERT_FILE}" > "${SERVER_FULLCHAIN_FILE}"

  rm -f "${tmp_cfg}" "${tmp_csr}"
}

show_cert_info() {
  local file="$1"
  local label="$2"
  if [[ ! -f "${file}" ]]; then
    log "${label}: missing (${file})"
    return
  fi

  local subject issuer enddate
  subject="$(openssl x509 -in "${file}" -noout -subject | sed 's/^subject= *//')"
  issuer="$(openssl x509 -in "${file}" -noout -issuer | sed 's/^issuer= *//')"
  enddate="$(openssl x509 -in "${file}" -noout -enddate | sed 's/^notAfter=//')"

  log "${label}: ${file}"
  log "  subject: ${subject}"
  log "  issuer: ${issuer}"
  log "  expires: ${enddate}"
}

run_ensure() {
  [[ -n "${HOSTNAME_VALUE}" ]] || fail "--hostname is required for ensure."
  mkdir -p "${CERT_DIR}"
  create_ca_if_missing

  if [[ ! -f "${SERVER_CERT_FILE}" || ! -f "${SERVER_KEY_FILE}" ]]; then
    issue_server_cert "$(build_san_list)"
  fi

  show_cert_info "${CA_CERT_FILE}" "CA cert"
  show_cert_info "${SERVER_CERT_FILE}" "Server cert"
}

run_renew() {
  [[ -n "${HOSTNAME_VALUE}" ]] || fail "--hostname is required for renew."
  mkdir -p "${CERT_DIR}"
  create_ca_if_missing
  issue_server_cert "$(build_san_list)"

  show_cert_info "${CA_CERT_FILE}" "CA cert"
  show_cert_info "${SERVER_CERT_FILE}" "Server cert"
}

run_status() {
  show_cert_info "${CA_CERT_FILE}" "CA cert"
  show_cert_info "${SERVER_CERT_FILE}" "Server cert"
}

main() {
  parse_args "$@"
  validate_number "${CERT_DAYS}" "cert-days"
  validate_number "${CA_DAYS}" "ca-days"
  command -v openssl >/dev/null 2>&1 || fail "openssl not found."
  set_file_paths

  case "${ACTION}" in
    ensure) run_ensure ;;
    renew) run_renew ;;
    status) run_status ;;
  esac
}

main "$@"
