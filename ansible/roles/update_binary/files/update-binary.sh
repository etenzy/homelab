# shellcheck shell=bash
#
# update-binary.sh — generic GitHub-release binary updater (library).
#
#   Sourced by the thin wrappers in /usr/local/sbin (update-blocky, ...).
#   Install to /usr/local/lib/update-binary/update-binary.sh.
#
#   Flow: look up latest release -> download + verify SHA256 -> smoke test ->
#   optional preflight -> backup -> atomic swap -> restart -> health check ->
#   rollback on failure -> prune old backups.
#
#   Wrapper contract
#   ----------------
#   Variables (required):
#     NAME        short name, e.g. "redis_exporter"; derives all defaults below
#     REPO        GitHub "owner/repo"
#     CHECKSUMS   file name of the checksum list in the release
#   Variables (optional, default in brackets; a drop-in /etc/default/update-$NAME
#   and the environment can override them):
#     BIN_PATH [/usr/local/bin/$NAME]   SERVICE [$NAME.service]
#     BACKUP_DIR [/var/lib/$NAME/backups]   KEEP_BACKUPS [3]
#     LOCK_FILE [/run/update-$NAME.lock]   METRICS_URL [unset]
#     HEALTH_TIMEOUT [30]   HEALTH_INTERVAL [2]   CURL_OPTS   GITHUB_TOKEN
#   Functions (required):
#     map_arch                 print the upstream arch label for `uname -m`, or die
#     asset_name VERSION ARCH  file name of the release archive
#     asset_binary VERSION ARCH  path of the binary inside the archive
#     binary_version PATH      print the version a binary reports (no "v" prefix)
#     health_check VERSION     return 0 if the running service is healthy and,
#                              where the check can tell, runs VERSION
#   Functions (optional):
#     preflight NEW_BIN VERSION  run after the smoke test, before anything is
#                                installed; die to abort
#     extra_arg ARG              handle a wrapper-specific flag; return 0 if consumed
#
#   Exit codes: 0 ok / nothing to do, 1 error, 2 update available (--check only)

# ---------------------------------------------------------------------- logging
log()  { printf '%s [%s] %s\n' "$(date -Is)" "$1" "${*:2}"; }
info() { log INFO  "$@"; }
warn() { log WARN  "$@" >&2; }
err()  { log ERROR "$@" >&2; }
die()  { err "$@"; exit 1; }

usage() {
  # Print the wrapper's header comment block: line 2 up to the first non-comment line.
  awk 'NR==1 {next} /^#/ {sub(/^# ?/, ""); print; next} {exit}' "$0"
  exit 0
}

# --------------------------------------------------------------------- helpers
# Version of "vX.Y[.Z]" as first match in stdin, without the "v".
parse_vversion() {
  grep -oE 'v[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1 | sed 's/^v//'
}

# Health helper for exporters: succeeds if $METRICS_URL answers and the body
# matches the grep pattern $1. Reads the body first: `curl | grep -q` would
# trip pipefail when grep exits early.
metrics_match() {
  local body
  body="$(curl --silent --fail --max-time 5 "$METRICS_URL" 2>/dev/null)" || return 1
  grep -q -- "$1" <<<"$body"
}

# Returns 0 if $2 is strictly newer than $1.
is_newer() {
  local cur="$1" new="$2"
  [[ "$cur" != "$new" ]] || return 1
  [[ "$(printf '%s\n%s\n' "$cur" "$new" | sort -V | tail -1)" == "$new" ]]
}

# The /releases/latest URL redirects to /releases/tag/<tag>. Reading that
# redirect avoids the GitHub API entirely, so no token and no 60/hour limit.
latest_version() {
  local loc tag
  loc="$(curl "${CURL_ARGS[@]}" --head --output /dev/null --write-out '%{url_effective}' \
           "https://github.com/${REPO}/releases/latest" || true)"
  tag="${loc##*/tag/}"
  if [[ "$tag" =~ ^v?[0-9]+\.[0-9]+(\.[0-9]+)? ]]; then
    echo "${tag#v}"; return 0
  fi
  # Fallback: the API, in case the redirect shape ever changes.
  warn "could not read the release redirect, falling back to the GitHub API"
  local hdr=() body
  [[ -n "$GITHUB_TOKEN" ]] && hdr=(-H "Authorization: Bearer ${GITHUB_TOKEN}")
  body="$(curl "${CURL_ARGS[@]}" "${hdr[@]}" "https://api.github.com/repos/${REPO}/releases/latest")" \
    || die "cannot reach GitHub"
  tag="$(printf '%s' "$body" | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)"
  [[ -n "$tag" ]] || die "could not determine the latest version"
  echo "${tag#v}"
}

installed_version() {
  [[ -x "$BIN_PATH" ]] || { echo ""; return 0; }
  binary_version "$BIN_PATH" || echo ""
}

# copy_caps SRC DST: carry file capabilities over (install(1) drops them).
copy_caps() {
  local caps
  command -v getcap >/dev/null 2>&1 && command -v setcap >/dev/null 2>&1 || return 0
  caps="$(getcap "$1" 2>/dev/null || true)"
  [[ -n "$caps" ]] || return 0
  caps="${caps#* }"; caps="${caps#= }"
  setcap "$caps" "$2" || return 1
  info "restored file capabilities: ${caps}"
}

# Replace BIN_PATH with $1: write next to the target, then rename. rename(2) is
# atomic and swaps the directory entry, so a running process keeps its old inode
# and there is never a truncated binary on disk. Capabilities come from $2.
swap_binary() {
  local src="$1" caps_from="${2:-}"
  STAGED="$(dirname "$BIN_PATH")/.${NAME}.new.$$"
  install -o root -g root -m 0755 "$src" "$STAGED"
  [[ -z "$caps_from" ]] || copy_caps "$caps_from" "$STAGED" \
    || die "could not restore file capabilities on ${STAGED} — ${BIN_PATH} untouched"
  mv -f "$STAGED" "$BIN_PATH"
  STAGED=""
  if command -v restorecon >/dev/null 2>&1; then
    restorecon "$BIN_PATH" >/dev/null 2>&1 || true
  fi
}

health_ok() {
  local expect="$1" deadline=$(( SECONDS + HEALTH_TIMEOUT ))
  while (( SECONDS < deadline )); do
    if systemctl is-active --quiet "$SERVICE" && health_check "$expect"; then
      return 0
    fi
    sleep "$HEALTH_INTERVAL"
  done
  return 1
}

rollback() {
  if [[ -z "$BACKUP" ]]; then
    err "no backup available to roll back to — ${BIN_PATH} is at ${TARGET} but unhealthy"
    return 1
  fi
  warn "rolling back to ${CURRENT}"
  swap_binary "$BACKUP" "$BACKUP"
  systemctl restart "$SERVICE" || true
  if health_ok "$CURRENT"; then
    warn "rollback to ${CURRENT} succeeded; ${TARGET} was NOT applied"
  else
    err "rollback restarted the unit but it is still unhealthy — manual intervention needed"
  fi
  return 1
}

prune_backups() {
  [[ -d "$BACKUP_DIR" ]] || return 0
  local old
  mapfile -t old < <(find "$BACKUP_DIR" -maxdepth 1 -type f -name "${NAME}-*" -printf '%T@ %p\n' \
                       | sort -rn | tail -n +$((KEEP_BACKUPS + 1)) | cut -d' ' -f2-)
  if (( ${#old[@]} )); then
    rm -f -- "${old[@]}"
    info "pruned ${#old[@]} old backup(s), keeping ${KEEP_BACKUPS}"
  fi
}

# ------------------------------------------------------------------- main logic
update_binary_main() {
  local f
  for f in NAME REPO CHECKSUMS; do
    [[ -n "${!f:-}" ]] || die "wrapper bug: ${f} is not set"
  done
  for f in map_arch asset_name asset_binary binary_version health_check; do
    declare -F "$f" >/dev/null || die "wrapper bug: function ${f} is not defined"
  done

  # Drop-in overrides, then defaults for whatever is still unset.
  # shellcheck source=/dev/null
  [[ -r "/etc/default/update-${NAME}" ]] && . "/etc/default/update-${NAME}"
  : "${BIN_PATH:=/usr/local/bin/${NAME}}"
  : "${SERVICE:=${NAME}.service}"
  : "${BACKUP_DIR:=/var/lib/${NAME}/backups}"
  : "${KEEP_BACKUPS:=3}"
  : "${LOCK_FILE:=/run/update-${NAME}.lock}"
  : "${METRICS_URL:=}"
  : "${HEALTH_TIMEOUT:=30}"
  : "${HEALTH_INTERVAL:=2}"
  : "${CURL_OPTS:=--silent --show-error --location --retry 3 --retry-delay 2 --max-time 120}"
  # Optional, only raises the GitHub API rate limit on the fallback path:
  : "${GITHUB_TOKEN:=}"
  read -r -a CURL_ARGS <<<"$CURL_OPTS"

  local mode="update" force=0 do_restart=1 pin_version=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --check)      mode="check" ;;
      --dry-run)    mode="dry-run" ;;
      --force)      force=1 ;;
      --no-restart) do_restart=0 ;;
      --version)    pin_version="${2:-}"; [[ -n "$pin_version" ]] || die "--version needs an argument"; shift ;;
      -h|--help)    usage ;;
      *)            if declare -F extra_arg >/dev/null && extra_arg "$1"; then :; else
                      die "unknown argument: $1 (try --help)"
                    fi ;;
    esac
    shift
  done

  [[ "$mode" == "check" || $EUID -eq 0 ]] || die "must run as root (installs to ${BIN_PATH})"

  for f in curl tar sha256sum install flock awk; do
    command -v "$f" >/dev/null || die "missing required command: $f"
  done

  # Serialise runs so a timer firing twice cannot race a half-finished install.
  if [[ "$mode" != "check" ]]; then
    exec 9>"$LOCK_FILE"
    flock -n 9 || { info "another update run holds the lock, exiting"; exit 0; }
  fi

  local arch asset base
  arch="$(map_arch)"
  CURRENT="$(installed_version)"
  TARGET="${pin_version#v}"
  [[ -n "$TARGET" ]] || TARGET="$(latest_version)"

  info "installed: ${CURRENT:-<none>} | available: ${TARGET} | arch: ${arch}"

  if [[ -z "$CURRENT" ]]; then
    info "no binary at ${BIN_PATH} yet — performing a fresh install"
  elif [[ "$CURRENT" == "$TARGET" ]]; then
    if (( force )); then
      info "already at ${TARGET}, reinstalling because --force was given"
    else
      info "already up to date"
      exit 0
    fi
  elif ! is_newer "$CURRENT" "$TARGET"; then
    if (( force )); then
      warn "downgrading ${CURRENT} -> ${TARGET} because --force was given"
    else
      warn "installed version ${CURRENT} is newer than ${TARGET}; refusing to downgrade (use --force)"
      exit 0
    fi
  fi

  if [[ "$mode" == "check" ]]; then
    info "update available: ${CURRENT:-<none>} -> ${TARGET}"
    exit 2
  fi

  # Everything is fetched BEFORE the live binary is touched: if the service is
  # this host's resolver, a rollback that still needed the network could not run.
  workdir="$(mktemp -d -t "update-${NAME}.XXXXXXXX")"
  STAGED=""
  trap 'rm -rf "$workdir"; if [[ -n "${STAGED:-}" ]]; then rm -f "$STAGED"; fi' EXIT

  asset="$(asset_name "$TARGET" "$arch")"
  base="https://github.com/${REPO}/releases/download/v${TARGET}"

  info "downloading ${asset}"
  curl "${CURL_ARGS[@]}" --fail --output "${workdir}/${asset}" "${base}/${asset}" \
    || die "download failed — does a ${arch} build exist for v${TARGET}?"
  curl "${CURL_ARGS[@]}" --fail --output "${workdir}/${CHECKSUMS}" "${base}/${CHECKSUMS}" \
    || die "could not download ${CHECKSUMS}"

  info "verifying checksum"
  ( cd "$workdir" && awk -v a="$asset" '$2 == a || $2 == "*" a' "$CHECKSUMS" | sha256sum --check --status - ) \
    || die "CHECKSUM MISMATCH for ${asset} — aborting, nothing was installed"

  mkdir -p "${workdir}/extract"
  tar -xzf "${workdir}/${asset}" -C "${workdir}/extract"
  local new_bin
  new_bin="${workdir}/extract/$(asset_binary "$TARGET" "$arch")"
  [[ -f "$new_bin" ]] || die "binary not found inside the archive"
  chmod 0755 "$new_bin"

  # Smoke test before it ever touches the live path.
  local reported
  reported="$(binary_version "$new_bin")" || die "the downloaded binary does not execute on this host"
  [[ "$reported" == "$TARGET" ]] \
    || die "version mismatch: archive says ${TARGET}, binary reports ${reported}"
  info "verified ${asset} (binary reports ${reported})"

  if declare -F preflight >/dev/null; then
    preflight "$new_bin" "$TARGET"
  fi

  if [[ "$mode" == "dry-run" ]]; then
    info "dry run — would install ${TARGET} to ${BIN_PATH} and restart ${SERVICE}"
    exit 0
  fi

  BACKUP=""
  if [[ -x "$BIN_PATH" ]]; then
    mkdir -p "$BACKUP_DIR"
    BACKUP="${BACKUP_DIR}/${NAME}-${CURRENT:-unknown}-$(date +%Y%m%d%H%M%S)"
    cp -a "$BIN_PATH" "$BACKUP"
    info "backed up current binary to ${BACKUP}"
  fi

  swap_binary "$new_bin" "$BACKUP"
  info "installed ${TARGET} to ${BIN_PATH}"

  if (( ! do_restart )); then
    info "--no-restart given; ${SERVICE} still runs the old binary until you restart it"
    exit 0
  fi

  if ! systemctl cat "$SERVICE" >/dev/null 2>&1; then
    warn "${SERVICE} is not installed; binary updated, nothing to restart"
    exit 0
  fi

  info "restarting ${SERVICE}"
  if ! systemctl restart "$SERVICE"; then
    err "systemctl restart failed"
    rollback || exit 1
    exit 1
  fi

  if health_ok "$TARGET"; then
    info "update complete: ${CURRENT:-<none>} -> ${TARGET}"
  else
    err "${SERVICE} did not become healthy within ${HEALTH_TIMEOUT}s"
    systemctl status "$SERVICE" --no-pager --lines=20 >&2 || true
    rollback || exit 1
    exit 1
  fi

  prune_backups
  exit 0
}
