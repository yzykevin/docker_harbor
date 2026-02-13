#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
COMPOSE_FILE="${ROOT_DIR}/docker-compose.yml"

usage() {
  cat <<'EOF'
Preferred unified entry:
  make <up|down|restart|recover|status>
  make logs [SERVICE=core]

Usage:
  ./scripts/harbor_ctl.sh <up|down|restart|recover|status|logs> [options]

Commands:
  up                     Start Harbor stack
  down                   Stop Harbor stack (preserve data)
  restart                Restart Harbor stack
  recover                Remove stale exited Harbor containers with fixed names
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

# Harbor uses fixed container_name values. After host reboot/crash, exited
# containers from an old compose project can still occupy those names.
HARBOR_NAMES=(
  harbor-log
  harbor-portal
  harbor-core
  harbor-jobservice
  registry
  redis
  registryctl
  harbor-db
  nginx
)

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

cleanup_stale_containers() {
  local cleaned=0
  local skipped=0
  local name id status
  for name in "${HARBOR_NAMES[@]}"; do
    id="$(docker ps -aq --filter "name=^/${name}$" | head -n 1)"
    [[ -n "${id}" ]] || continue
    status="$(docker inspect -f '{{.State.Status}}' "${id}" 2>/dev/null || echo unknown)"
    if [[ "${status}" == "running" ]]; then
      skipped=$((skipped + 1))
      log "Skip running container: ${name}"
      continue
    fi
    docker rm -f "${id}" >/dev/null 2>&1 || true
    cleaned=$((cleaned + 1))
    log "Removed stale container: ${name} (${status})"
  done
  log "Recover summary: cleaned=${cleaned}, skipped_running=${skipped}"
}

compose_up_with_recovery() {
  local output_file
  output_file="$(mktemp)"
  if "${COMPOSE_CMD[@]}" -f "${COMPOSE_FILE}" up -d >"${output_file}" 2>&1; then
    cat "${output_file}"
    rm -f "${output_file}"
    return 0
  fi

  cat "${output_file}"
  if rg -q "container name \".*\" is already in use by container" "${output_file}"; then
    log "Detected container name conflict, running stale-container recovery..."
    cleanup_stale_containers
    log "Retrying startup..."
    "${COMPOSE_CMD[@]}" -f "${COMPOSE_FILE}" up -d
    rm -f "${output_file}"
    return 0
  fi

  rm -f "${output_file}"
  return 1
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
      compose_up_with_recovery
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
      compose_up_with_recovery
      ;;
    recover)
      log "Cleaning stale Harbor containers..."
      cleanup_stale_containers
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
