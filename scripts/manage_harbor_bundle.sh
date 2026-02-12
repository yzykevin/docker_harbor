#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

DOWNLOAD_DIR="${ROOT_DIR}/artifacts/harbor-bundles"
TMP_DIR="${ROOT_DIR}/.tmp-harbor-bundle"
VERSION="latest"          # latest or vX.Y.Z
ARCHIVE_FILE=""
KEEP_EXTRACT="false"
AUTO_DOWNLOAD="true"
CLEAN_ARCHIVE="false"

usage() {
  cat <<'EOF'
Usage:
  ./scripts/manage_harbor_bundle.sh <latest|check|download|extract|upgrade|cleanup> [options]

Commands:
  latest
      Print latest Harbor release tag from GitHub.

  check
      Compare local Harbor image bundle version and latest release.

  download
      Download official offline installer archive to ./artifacts/harbor-bundles/.

  extract
      Extract offline installer archive to temp directory.

  upgrade
      Ensure archive -> extract -> sync official Harbor bundle into project root.
      Your scripts/, certs/, harbor-data/, and generated runtime files are preserved.

  cleanup
      Remove temporary extraction directory.

Options:
  --version <latest|vX.Y.Z|X.Y.Z>   Target version (default: latest)
  --archive <path>                  Use existing offline installer archive
  --download-dir <path>             Download directory (default: ./artifacts/harbor-bundles)
  --tmp-dir <path>                  Temp extraction directory (default: ./.tmp-harbor-bundle)
  --keep-extract                    Keep extracted files after extract/upgrade
  --no-auto-download                Do not auto-download archive when missing
  --clean-archive                   Remove installer archive after successful upgrade
  -h, --help                        Show help
EOF
}

log() {
  printf '[harbor-bundle] %s\n' "$*"
}

fail() {
  printf '[harbor-bundle] ERROR: %s\n' "$*" >&2
  exit 1
}

normalize_version() {
  local raw="$1"
  if [[ "${raw}" == "latest" || -z "${raw}" ]]; then
    printf '%s' "latest"
    return
  fi
  if [[ "${raw}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    printf '%s' "${raw}"
    return
  fi
  if [[ "${raw}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    printf 'v%s' "${raw}"
    return
  fi
  fail "Invalid version: ${raw}. Expected latest or vX.Y.Z"
}

latest_tag() {
  local tag
  tag="$(curl -fsSL https://api.github.com/repos/goharbor/harbor/releases/latest | awk -F'"' '/"tag_name":/{print $4; exit}')"
  [[ -n "${tag}" ]] || fail "Cannot detect latest tag from GitHub API."
  printf '%s' "${tag}"
}

resolve_target_tag() {
  local normalized
  normalized="$(normalize_version "${VERSION}")"
  if [[ "${normalized}" == "latest" ]]; then
    latest_tag
  else
    printf '%s' "${normalized}"
  fi
}

asset_name_from_tag() {
  local tag="$1"
  printf 'harbor-offline-installer-%s.tgz' "${tag}"
}

asset_url_from_tag() {
  local tag="$1"
  printf 'https://github.com/goharbor/harbor/releases/download/%s/%s' "${tag}" "$(asset_name_from_tag "${tag}")"
}

detect_local_bundle_version() {
  local file
  file="$(find "${ROOT_DIR}" -maxdepth 1 -type f -name 'harbor.v*.tar.gz' | sort | tail -n 1 || true)"
  if [[ -z "${file}" ]]; then
    printf '%s' "unknown"
    return
  fi
  basename "${file}" | sed -E 's/^harbor\.(v[0-9]+\.[0-9]+\.[0-9]+)\.tar\.gz$/\1/'
}

archive_path_for_version() {
  local tag="$1"
  printf '%s/%s' "${DOWNLOAD_DIR}" "$(asset_name_from_tag "${tag}")"
}

cmd_latest() {
  latest_tag
  echo
}

cmd_check() {
  local local_ver remote_ver
  local_ver="$(detect_local_bundle_version)"
  remote_ver="$(latest_tag)"
  log "local image bundle: ${local_ver}"
  log "latest release:     ${remote_ver}"
  if [[ "${local_ver}" == "${remote_ver}" ]]; then
    log "status: up-to-date"
  else
    log "status: update available"
  fi
}

download_archive() {
  local tag="$1"
  local out url
  mkdir -p "${DOWNLOAD_DIR}"
  out="$(archive_path_for_version "${tag}")"
  url="$(asset_url_from_tag "${tag}")"
  if [[ -f "${out}" ]]; then
    log "archive exists: ${out}"
    printf '%s' "${out}"
    return
  fi
  log "downloading ${url}"
  curl -fL --retry 3 --connect-timeout 20 -o "${out}" "${url}"
  log "saved: ${out}"
  printf '%s' "${out}"
}

ensure_archive_file() {
  if [[ -n "${ARCHIVE_FILE}" ]]; then
    [[ -f "${ARCHIVE_FILE}" ]] || fail "Archive not found: ${ARCHIVE_FILE}"
    printf '%s' "${ARCHIVE_FILE}"
    return
  fi

  local tag archive
  tag="$(resolve_target_tag)"
  archive="$(archive_path_for_version "${tag}")"
  if [[ -f "${archive}" ]]; then
    printf '%s' "${archive}"
    return
  fi
  if [[ "${AUTO_DOWNLOAD}" == "true" ]]; then
    download_archive "${tag}"
    return
  fi
  fail "Archive missing: ${archive}. Run download first or remove --no-auto-download."
}

extract_archive() {
  local archive="$1"
  rm -rf "${TMP_DIR}"
  mkdir -p "${TMP_DIR}"
  tar -xzf "${archive}" -C "${TMP_DIR}"
  [[ -d "${TMP_DIR}/harbor" ]] || fail "Unexpected archive layout: harbor/ directory missing."
}

sync_official_bundle() {
  if command -v rsync >/dev/null 2>&1; then
    rsync -a "${TMP_DIR}/harbor/" "${ROOT_DIR}/"
    return
  fi
  cp -a "${TMP_DIR}/harbor/." "${ROOT_DIR}/"
}

cmd_download() {
  local tag
  tag="$(resolve_target_tag)"
  download_archive "${tag}" >/dev/null
}

cmd_extract() {
  local archive
  archive="$(ensure_archive_file)"
  extract_archive "${archive}"
  log "extracted to: ${TMP_DIR}/harbor"
}

cmd_upgrade() {
  local archive
  archive="$(ensure_archive_file)"
  extract_archive "${archive}"

  log "syncing official Harbor bundle into ${ROOT_DIR}"
  sync_official_bundle

  chmod +x \
    "${ROOT_DIR}/install.sh" \
    "${ROOT_DIR}/prepare" \
    "${ROOT_DIR}/scripts/setup_harbor_local.sh" \
    "${ROOT_DIR}/scripts/manage_harbor_certs.sh" \
    "${ROOT_DIR}/scripts/harbor_ctl.sh" \
    "${ROOT_DIR}/scripts/trust_harbor_ca.sh" \
    "${ROOT_DIR}/scripts/manage_harbor_bundle.sh" \
    "${ROOT_DIR}/scripts/preflight_check.sh" 2>/dev/null || true

  if [[ "${KEEP_EXTRACT}" != "true" ]]; then
    rm -rf "${TMP_DIR}"
  fi
  if [[ "${CLEAN_ARCHIVE}" == "true" && -f "${archive}" ]]; then
    rm -f "${archive}"
    log "removed archive: ${archive}"
  fi

  log "upgrade completed."
  log "tip: run 'make preflight' then 'make install ARGS=\"--mode self-signed --hostname <ip> --skip-load\"'"
}

cmd_cleanup() {
  rm -rf "${TMP_DIR}"
  log "removed temp dir: ${TMP_DIR}"
}

parse_args() {
  local cmd="${1:-}"
  shift || true
  case "${cmd}" in
    latest|check|download|extract|upgrade|cleanup) ;;
    -h|--help|"")
      usage
      exit 0
      ;;
    *)
      fail "Unknown command: ${cmd}"
      ;;
  esac

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --version)
        VERSION="${2:-}"
        shift 2
        ;;
      --archive)
        ARCHIVE_FILE="${2:-}"
        shift 2
        ;;
      --download-dir)
        DOWNLOAD_DIR="${2:-}"
        shift 2
        ;;
      --tmp-dir)
        TMP_DIR="${2:-}"
        shift 2
        ;;
      --keep-extract)
        KEEP_EXTRACT="true"
        shift
        ;;
      --no-auto-download)
        AUTO_DOWNLOAD="false"
        shift
        ;;
      --clean-archive)
        CLEAN_ARCHIVE="true"
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

  case "${cmd}" in
    latest) cmd_latest ;;
    check) cmd_check ;;
    download) cmd_download ;;
    extract) cmd_extract ;;
    upgrade) cmd_upgrade ;;
    cleanup) cmd_cleanup ;;
  esac
}

main() {
  command -v curl >/dev/null 2>&1 || fail "curl not found."
  command -v tar >/dev/null 2>&1 || fail "tar not found."
  parse_args "$@"
}

main "$@"
