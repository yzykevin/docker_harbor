#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
HARBOR_CONFIG="${ROOT_DIR}/harbor.yml"

IMAGE="${IMAGE:-}"
PROJECT="${PROJECT:-}"
REGISTRY="${REGISTRY:-}"
REPO="${REPO:-}"
TAG="${TAG:-}"
LOGIN="${LOGIN:-0}"
USERNAME="${USERNAME:-}"

usage() {
  cat <<'USAGE'
Preferred unified entry:
  make push IMAGE=rocky8:dev PROJECT=ic [REGISTRY=harbor.example.com[:port]] [REPO=rocky8] [TAG=dev] [LOGIN=1] [USERNAME=<user>]

Usage:
  ./scripts/push_harbor_image.sh [options]

Options:
  --image <ref>             Local image reference to push (required)
  --project <name>          Harbor project name (required)
  --registry <host[:port]>  Harbor registry host (default: infer from harbor.yml)
  --repo <name>             Destination repository name (default: source image name)
  --tag <tag>               Destination tag (default: source tag or latest)
  --login                   Run docker login before push
  --username <name>         Username for docker login (optional)
  -h, --help                Show help

Notes:
  - Do NOT include http:// or https:// in registry.
  - unauthorized during push is usually permission/account/project-role issue, not CA trust.
USAGE
}

log() {
  printf '[harbor-push] %s\n' "$*"
}

fail() {
  printf '[harbor-push] ERROR: %s\n' "$*" >&2
  exit 1
}

strip_scheme() {
  local value="$1"
  value="${value#http://}"
  value="${value#https://}"
  printf '%s' "${value}"
}

infer_registry_from_config() {
  [[ -f "${HARBOR_CONFIG}" ]] || return 1

  local host https_enabled https_port http_port
  host="$(awk '/^hostname:[[:space:]]*/{print $2; exit}' "${HARBOR_CONFIG}")"
  [[ -n "${host}" ]] || return 1

  https_enabled="$(awk '
    /^https:[[:space:]]*$/ { in_https=1; next }
    /^[^[:space:]#].*:/ { if (in_https==1) in_https=0 }
    in_https==1 && /^[[:space:]]*port:[[:space:]]*/ { print $2; exit }
  ' "${HARBOR_CONFIG}")"

  if [[ -n "${https_enabled}" ]]; then
    https_port="${https_enabled}"
    if [[ "${https_port}" == "443" ]]; then
      printf '%s' "${host}"
    else
      printf '%s' "${host}:${https_port}"
    fi
    return 0
  fi

  http_port="$(awk '
    /^http:[[:space:]]*$/ { in_http=1; next }
    /^[^[:space:]#].*:/ { if (in_http==1) in_http=0 }
    in_http==1 && /^[[:space:]]*port:[[:space:]]*/ { print $2; exit }
  ' "${HARBOR_CONFIG}")"

  if [[ -n "${http_port}" ]]; then
    if [[ "${http_port}" == "80" ]]; then
      printf '%s' "${host}"
    else
      printf '%s' "${host}:${http_port}"
    fi
    return 0
  fi

  printf '%s' "${host}"
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --image)
        IMAGE="${2:-}"
        shift 2
        ;;
      --project)
        PROJECT="${2:-}"
        shift 2
        ;;
      --registry)
        REGISTRY="${2:-}"
        shift 2
        ;;
      --repo)
        REPO="${2:-}"
        shift 2
        ;;
      --tag)
        TAG="${2:-}"
        shift 2
        ;;
      --login)
        LOGIN="1"
        shift
        ;;
      --username)
        USERNAME="${2:-}"
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
}

require_docker() {
  command -v docker >/dev/null 2>&1 || fail "docker command not found"
}

image_exists() {
  docker image inspect "$1" >/dev/null 2>&1
}

derive_source_name() {
  local ref="$1"
  local no_digest no_tag
  no_digest="${ref%%@*}"

  if [[ "${no_digest}" == *:* && "${no_digest##*/}" == *:* ]]; then
    no_tag="${no_digest%:*}"
  else
    no_tag="${no_digest}"
  fi

  printf '%s' "${no_tag##*/}"
}

derive_source_tag() {
  local ref="$1"
  local no_digest
  no_digest="${ref%%@*}"

  if [[ "${no_digest}" == *:* && "${no_digest##*/}" == *:* ]]; then
    printf '%s' "${no_digest##*:}"
  else
    printf '%s' "latest"
  fi
}

run_login_if_needed() {
  local registry="$1"
  if [[ "${LOGIN}" != "1" ]]; then
    return 0
  fi

  log "Running docker login for ${registry}"
  if [[ -n "${USERNAME}" ]]; then
    docker login "${registry}" --username "${USERNAME}"
  else
    docker login "${registry}"
  fi
}

main() {
  parse_args "$@"
  require_docker

  [[ -n "${IMAGE}" ]] || fail "IMAGE is required. Example: make push IMAGE=rocky8:dev PROJECT=ic"
  [[ -n "${PROJECT}" ]] || fail "PROJECT is required. Example: make push IMAGE=rocky8:dev PROJECT=ic"

  if [[ -z "${REGISTRY}" ]]; then
    REGISTRY="$(infer_registry_from_config || true)"
  fi
  [[ -n "${REGISTRY}" ]] || fail "Cannot infer REGISTRY from harbor.yml. Please provide REGISTRY=host[:port]"

  local raw_registry
  raw_registry="${REGISTRY}"
  REGISTRY="$(strip_scheme "${REGISTRY}")"
  if [[ "${raw_registry}" != "${REGISTRY}" ]]; then
    log "Registry scheme removed: '${raw_registry}' -> '${REGISTRY}'"
  fi

  image_exists "${IMAGE}" || fail "Local image not found: ${IMAGE}"

  local dest_repo dest_tag dest_ref
  dest_repo="${REPO:-$(derive_source_name "${IMAGE}")}"
  dest_tag="${TAG:-$(derive_source_tag "${IMAGE}")}"
  dest_ref="${REGISTRY}/${PROJECT}/${dest_repo}:${dest_tag}"

  run_login_if_needed "${REGISTRY}"

  log "Tagging image: ${IMAGE} -> ${dest_ref}"
  docker tag "${IMAGE}" "${dest_ref}"

  log "Pushing image: ${dest_ref}"
  local output_file
  output_file="$(mktemp)"
  if docker push "${dest_ref}" >"${output_file}" 2>&1; then
    cat "${output_file}"
    rm -f "${output_file}"
    log "Push succeeded: ${dest_ref}"
    return 0
  fi

  cat "${output_file}"

  if rg -qi "unauthorized|denied: requested access" "${output_file}"; then
    log "Likely auth/permission issue. Check:"
    log "1) docker login target is exactly ${REGISTRY}"
    log "2) user has push permission in project '${PROJECT}' (Developer+ or project admin)"
    log "3) repo path is correct: ${PROJECT}/${dest_repo}"
  elif rg -qi "x509: certificate signed by unknown authority|certificate verify failed|tls" "${output_file}"; then
    log "Likely certificate trust issue for Docker daemon."
    log "Run: make trust-install"
    log "Then restart Docker Desktop/daemon and retry."
  fi

  rm -f "${output_file}"
  exit 1
}

main "$@"
