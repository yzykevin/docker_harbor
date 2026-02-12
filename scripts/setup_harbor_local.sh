#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
TEMPLATE_FILE="${ROOT_DIR}/harbor.yml.tmpl"
CONFIG_FILE="${ROOT_DIR}/harbor.yml"

HOSTNAME_VALUE=""
HTTP_PORT="8080"
HTTPS_PORT="8443"
MODE="http" # http | self-signed | custom
CERT_FILE=""
KEY_FILE=""
CERT_DIR="${ROOT_DIR}/certs"
CERT_DAYS="825"
CA_DAYS="3650"
ALT_NAMES=""
FORCE_RENEW_CERT="false"
DATA_VOLUME="${ROOT_DIR}/harbor-data"
ADMIN_PASSWORD="Harbor12345"
DB_PASSWORD="root123"
WITH_TRIVY="false"
SKIP_LOAD="false"

usage() {
  cat <<'EOF'
Preferred unified entry:
  make install ARGS="--mode self-signed --hostname <ip> --https-port 8443" [TRUST_CA=1]

Usage:
  ./scripts/setup_harbor_local.sh [options]

Options:
  --hostname <value>         Harbor hostname or IP (default: auto detect LAN IP)
  --http-port <port>         HTTP port (default: 8080)
  --https-port <port>        HTTPS port (default: 8443)
  --mode <http|self-signed|custom>
                             Install mode (default: http)
  --cert-file <path>         TLS cert path when --mode custom
  --key-file <path>          TLS private key path when --mode custom
  --cert-dir <path>          Cert output directory in self-signed mode
  --cert-days <days>         Self-signed cert validity days (default: 825)
  --ca-days <days>           Self-signed CA validity days (default: 3650)
  --alt-names <list>         Extra SAN entries for self-signed cert, comma separated
  --force-renew-cert         Force re-issue self-signed server cert
  --data-volume <path>       Harbor data dir (default: ./harbor-data)
  --admin-password <value>   Harbor admin password (default: Harbor12345)
  --db-password <value>      Harbor DB password (default: root123)
  --with-trivy               Enable Trivy during prepare/install
  --skip-load                Skip `docker load -i harbor*.tar.gz`
  -h, --help                 Show help

Examples:
  ./scripts/setup_harbor_local.sh --mode http --http-port 8080
  ./scripts/setup_harbor_local.sh --mode self-signed --hostname 192.168.1.10 --https-port 8443
  ./scripts/setup_harbor_local.sh --mode self-signed --hostname 192.168.1.10 --https-port 8443 --alt-names DNS:harbor.local
  ./scripts/setup_harbor_local.sh --mode custom --hostname harbor.local --cert-file /path/fullchain.crt --key-file /path/privkey.key
EOF
}

log() {
  printf '[harbor-setup] %s\n' "$*"
}

fail() {
  printf '[harbor-setup] ERROR: %s\n' "$*" >&2
  exit 1
}

detect_local_ip() {
  local ip=""
  local iface=""

  if command -v ip >/dev/null 2>&1; then
    ip="$(ip route get 1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')"
  fi

  if [[ -z "${ip}" ]] && command -v route >/dev/null 2>&1 && command -v ipconfig >/dev/null 2>&1; then
    iface="$(route -n get default 2>/dev/null | awk '/interface:/{print $2; exit}')"
    if [[ -n "${iface}" ]]; then
      ip="$(ipconfig getifaddr "${iface}" 2>/dev/null || true)"
    fi
  fi

  if [[ -z "${ip}" ]] && command -v hostname >/dev/null 2>&1; then
    ip="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"
  fi

  if [[ -z "${ip}" ]] && command -v ipconfig >/dev/null 2>&1; then
    ip="$(ipconfig 2>/dev/null | awk '/IPv4 Address/{gsub(/\r/, "", $NF); print $NF; exit}' || true)"
  fi

  printf '%s' "${ip}"
}

check_port_free() {
  local port="$1"
  if command -v lsof >/dev/null 2>&1; then
    if lsof -nP -iTCP:"${port}" -sTCP:LISTEN >/dev/null 2>&1; then
      fail "Port ${port} is in use, choose another port."
    fi
    return
  fi

  if command -v ss >/dev/null 2>&1; then
    if ss -lnt "( sport = :${port} )" 2>/dev/null | grep -q ":${port}"; then
      fail "Port ${port} is in use, choose another port."
    fi
    return
  fi

  if command -v netstat >/dev/null 2>&1; then
    if netstat -an 2>/dev/null | grep -E "[\.\:]${port}[[:space:]].*(LISTEN|LISTENING)" >/dev/null; then
      fail "Port ${port} is in use, choose another port."
    fi
    return
  fi

  log "Cannot check port occupancy (no lsof/ss), skip pre-check for ${port}."
}

detect_compose_cmd() {
  if docker compose version >/dev/null 2>&1; then
    COMPOSE_CMD=(docker compose)
    return
  fi
  if docker-compose --version >/dev/null 2>&1; then
    COMPOSE_CMD=(docker-compose)
    return
  fi
  fail "docker compose / docker-compose not found."
}

validate_number() {
  local value="$1"
  local name="$2"
  if ! [[ "${value}" =~ ^[0-9]+$ ]]; then
    fail "${name} must be a number."
  fi
  if (( value < 1 || value > 65535 )); then
    fail "${name} must be in range 1-65535."
  fi
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
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
      --mode)
        MODE="${2:-}"
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
      --alt-names)
        ALT_NAMES="${2:-}"
        shift 2
        ;;
      --force-renew-cert)
        FORCE_RENEW_CERT="true"
        shift
        ;;
      --data-volume)
        DATA_VOLUME="${2:-}"
        shift 2
        ;;
      --admin-password)
        ADMIN_PASSWORD="${2:-}"
        shift 2
        ;;
      --db-password)
        DB_PASSWORD="${2:-}"
        shift 2
        ;;
      --with-trivy)
        WITH_TRIVY="true"
        shift
        ;;
      --skip-load)
        SKIP_LOAD="true"
        shift
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
}

render_config() {
  [[ -f "${TEMPLATE_FILE}" ]] || fail "Missing template: ${TEMPLATE_FILE}"

  awk \
    -v host="${HOSTNAME_VALUE}" \
    -v http_port="${HTTP_PORT}" \
    -v https_port="${HTTPS_PORT}" \
    -v mode="${MODE}" \
    -v cert="${CERT_FILE}" \
    -v key="${KEY_FILE}" \
    -v admin_pwd="${ADMIN_PASSWORD}" \
    -v db_pwd="${DB_PASSWORD}" \
    -v data_volume="${DATA_VOLUME}" \
    '
    BEGIN {
      section = "";
      comment_https = 0;
    }
    {
      line = $0;

      if (line ~ /^hostname:/) {
        print "hostname: " host;
        next;
      }
      if (line ~ /^harbor_admin_password:/) {
        print "harbor_admin_password: " admin_pwd;
        next;
      }
      if (line ~ /^data_volume:/) {
        print "data_volume: " data_volume;
        next;
      }

      if (line ~ /^http:/) {
        section = "http";
        print line;
        next;
      }
      if (section == "http" && line ~ /^  port:/) {
        print "  port: " http_port;
        next;
      }

      if (line ~ /^https:/) {
        section = "https";
        if (mode == "http") {
          print "# https disabled in http mode";
          print "#" line;
          comment_https = 1;
          next;
        }
        print line;
        next;
      }

      if (comment_https == 1) {
        if (line ~ /^[^[:space:]#]/) {
          comment_https = 0;
        } else {
          print "#" line;
          next;
        }
      }

      if (section == "https") {
        if (line ~ /^  port:/) {
          print "  port: " https_port;
          next;
        }
        if (line ~ /^  certificate:/) {
          print "  certificate: " cert;
          next;
        }
        if (line ~ /^  private_key:/) {
          print "  private_key: " key;
          next;
        }
      }

      if (line ~ /^database:/) {
        section = "database";
        print line;
        next;
      }
      if (section == "database" && line ~ /^  password:/) {
        print "  password: " db_pwd;
        next;
      }

      if (line ~ /^[^[:space:]#].*:/) {
        section = "";
      }

      print line;
    }
    ' "${TEMPLATE_FILE}" > "${CONFIG_FILE}"
}

apply_registry_mount_workaround() {
  local compose_file="${ROOT_DIR}/docker-compose.yml"
  local secret_root_crt="${DATA_VOLUME%/}/secret/registry/root.crt"
  local config_root_crt="${ROOT_DIR}/common/config/registry/root.crt"
  local tmp_file="${compose_file}.tmp"

  [[ -f "${compose_file}" ]] || return 0

  if [[ -f "${secret_root_crt}" ]]; then
    cp "${secret_root_crt}" "${config_root_crt}"
  fi

  awk '
    {
      if ($0 ~ /^[[:space:]]*- type: bind[[:space:]]*$/) {
        first = $0
        if ((getline second) <= 0) { print first; exit }
        if ((getline third) <= 0) { print first; print second; exit }

        if (second ~ /source:[[:space:]].*\/secret\/registry\/root\.crt[[:space:]]*$/ &&
            third ~ /target:[[:space:]]*\/etc\/registry\/root\.crt[[:space:]]*$/) {
          next
        }

        print first
        print second
        print third
        next
      }
      print
    }
  ' "${compose_file}" > "${tmp_file}"

  mv "${tmp_file}" "${compose_file}"
}

main() {
  parse_args "$@"

  case "${MODE}" in
    http|self-signed|custom) ;;
    *) fail "--mode must be one of: http, self-signed, custom" ;;
  esac

  validate_number "${HTTP_PORT}" "HTTP port"
  validate_number "${HTTPS_PORT}" "HTTPS port"
  validate_number "${CERT_DAYS}" "cert-days"
  validate_number "${CA_DAYS}" "ca-days"

  if [[ -z "${HOSTNAME_VALUE}" ]]; then
    HOSTNAME_VALUE="$(detect_local_ip)"
    if [[ -z "${HOSTNAME_VALUE}" ]]; then
      fail "Cannot auto-detect LAN IP. Please pass --hostname explicitly."
    fi
  fi

  if [[ "${HOSTNAME_VALUE}" == "localhost" || "${HOSTNAME_VALUE}" == "127.0.0.1" ]]; then
    fail "Do not use localhost/127.0.0.1. Use a LAN IP or DNS name."
  fi

  [[ -f "${ROOT_DIR}/prepare" ]] || fail "Missing prepare script in ${ROOT_DIR}"
  if [[ "${SKIP_LOAD}" != "true" ]]; then
    if ! find "${ROOT_DIR}" -maxdepth 1 -type f -name 'harbor*.tar.gz' | grep -q .; then
      fail "Cannot find offline package harbor*.tar.gz in ${ROOT_DIR}"
    fi
  fi

  command -v docker >/dev/null 2>&1 || fail "docker not found."
  docker info >/dev/null 2>&1 || fail "docker daemon is not reachable."
  detect_compose_cmd

  check_port_free "${HTTP_PORT}"
  if [[ "${MODE}" != "http" ]]; then
    check_port_free "${HTTPS_PORT}"
  fi

  mkdir -p "${DATA_VOLUME}"

  if [[ "${MODE}" == "self-signed" ]]; then
    local cert_action="ensure"
    local cert_args=()
    [[ -f "${SCRIPT_DIR}/manage_harbor_certs.sh" ]] || fail "manage_harbor_certs.sh not found."
    if [[ "${FORCE_RENEW_CERT}" == "true" ]]; then
      cert_action="renew"
    fi
    cert_args+=(
      --hostname "${HOSTNAME_VALUE}"
      --cert-dir "${CERT_DIR}"
      --cert-days "${CERT_DAYS}"
      --ca-days "${CA_DAYS}"
    )
    if [[ -n "${ALT_NAMES}" ]]; then
      cert_args+=(--alt-names "${ALT_NAMES}")
    fi
    "${SCRIPT_DIR}/manage_harbor_certs.sh" "${cert_action}" "${cert_args[@]}"
    CERT_FILE="${CERT_DIR}/harbor.fullchain.crt"
    KEY_FILE="${CERT_DIR}/harbor.key"
  elif [[ "${MODE}" == "custom" ]]; then
    [[ -n "${CERT_FILE}" && -n "${KEY_FILE}" ]] || fail "--mode custom requires --cert-file and --key-file"
    [[ -f "${CERT_FILE}" ]] || fail "cert file not found: ${CERT_FILE}"
    [[ -f "${KEY_FILE}" ]] || fail "key file not found: ${KEY_FILE}"
  fi

  render_config
  log "Generated config: ${CONFIG_FILE}"

  if [[ "${SKIP_LOAD}" != "true" ]]; then
    local tar_file
    tar_file="$(find "${ROOT_DIR}" -maxdepth 1 -type f -name 'harbor*.tar.gz' | head -n 1)"
    [[ -n "${tar_file}" ]] || fail "Cannot find harbor*.tar.gz"
    log "Loading offline images: ${tar_file}"
    docker load -i "${tar_file}"
  fi

  local prepare_args=()
  if [[ "${WITH_TRIVY}" == "true" ]]; then
    prepare_args+=(--with-trivy)
  fi

  log "Preparing Harbor assets..."
  if [[ ${#prepare_args[@]} -gt 0 ]]; then
    "${ROOT_DIR}/prepare" "${prepare_args[@]}"
  else
    "${ROOT_DIR}/prepare"
  fi

  apply_registry_mount_workaround

  log "Stopping old Harbor stack (if exists)..."
  "${COMPOSE_CMD[@]}" -f "${ROOT_DIR}/docker-compose.yml" down >/dev/null 2>&1 || true

  log "Starting Harbor..."
  "${COMPOSE_CMD[@]}" -f "${ROOT_DIR}/docker-compose.yml" up -d

  if [[ "${MODE}" == "http" ]]; then
    log "Harbor is up: http://${HOSTNAME_VALUE}:${HTTP_PORT}"
    log "Default user/password: admin / ${ADMIN_PASSWORD}"
    log "HTTP mode note: Docker client needs insecure-registry for ${HOSTNAME_VALUE}:${HTTP_PORT}."
  else
    log "Harbor is up: https://${HOSTNAME_VALUE}:${HTTPS_PORT}"
    log "Default user/password: admin / ${ADMIN_PASSWORD}"
    log "If using self-signed/custom cert, trust CA on client side before push/pull."
    if [[ "${MODE}" == "self-signed" ]]; then
      log "Self-signed CA cert: ${CERT_DIR}/ca.crt"
      log "Server cert/key: ${CERT_DIR}/harbor.fullchain.crt and ${CERT_DIR}/harbor.key"
    fi
  fi
}

main "$@"
