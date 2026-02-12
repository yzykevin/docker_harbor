#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
COMPOSE_FILE="${ROOT_DIR}/docker-compose.yml"

usage() {
  cat <<'EOF'
Preferred unified entry:
  make <up|down|restart|status>
  make logs [SERVICE=core]

Usage:
  ./scripts/harbor_ctl.sh <up|down|restart|status|logs> [options]

Commands:
  up                     Start Harbor stack
  down                   Stop Harbor stack (preserve data)
  restart                Restart Harbor stack
  status                 Show Harbor container status
  logs [service]         Show logs, optionally by service

Options:
  --purge                For `down` only: also remove anonymous volumes
  -h, --help             Show help
EOF
}

fail() {
  printf '[harbor-ctl] ERROR: %s\n' "$*" >&2
  exit 1
}

log() {
  printf '[harbor-ctl] %s\n' "$*"
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

main() {
  local cmd="${1:-}"
  local purge="false"
  local service="${2:-}"

  [[ -n "${cmd}" ]] || { usage; exit 1; }
  if [[ "${cmd}" == "-h" || "${cmd}" == "--help" ]]; then
    usage
    exit 0
  fi

  if [[ ! -f "${COMPOSE_FILE}" ]]; then
    fail "docker-compose.yml not found. Run scripts/setup_harbor_local.sh first."
  fi

  detect_compose_cmd

  if [[ "${service}" == "--purge" ]]; then
    purge="true"
    service=""
  fi
  if [[ "${3:-}" == "--purge" ]]; then
    purge="true"
  fi

  case "${cmd}" in
    up)
      log "Starting Harbor..."
      "${COMPOSE_CMD[@]}" -f "${COMPOSE_FILE}" up -d
      ;;
    down)
      log "Stopping Harbor..."
      if [[ "${purge}" == "true" ]]; then
        "${COMPOSE_CMD[@]}" -f "${COMPOSE_FILE}" down -v
      else
        "${COMPOSE_CMD[@]}" -f "${COMPOSE_FILE}" down
      fi
      ;;
    restart)
      log "Restarting Harbor..."
      "${COMPOSE_CMD[@]}" -f "${COMPOSE_FILE}" down
      "${COMPOSE_CMD[@]}" -f "${COMPOSE_FILE}" up -d
      ;;
    status)
      "${COMPOSE_CMD[@]}" -f "${COMPOSE_FILE}" ps
      ;;
    logs)
      if [[ -n "${service}" ]]; then
        "${COMPOSE_CMD[@]}" -f "${COMPOSE_FILE}" logs --tail=200 -f "${service}"
      else
        "${COMPOSE_CMD[@]}" -f "${COMPOSE_FILE}" logs --tail=200 -f
      fi
      ;;
    *)
      fail "Unknown command: ${cmd}"
      ;;
  esac
}

main "$@"
