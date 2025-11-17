#!/usr/bin/env bash
#
# auto_disk_cleanup.sh
# Run opinionated cleanup commands when a filesystem crosses a usage threshold.
#
# Intended to be launched by a monitoring alert or scheduled job on a GCP VM.

set -euo pipefail

THRESHOLD="${THRESHOLD:-92}"          # percent
TARGET_MOUNT="${TARGET_MOUNT:-/}"     # filesystem or mount point to monitor
LOG_FILE="${LOG_FILE:-/var/log/disk_cleanup.log}"
DRY_RUN="${DRY_RUN:-false}"
LOG_RETENTION_DAYS="${LOG_RETENTION_DAYS:-7}"
TMP_RETENTION_DAYS="${TMP_RETENTION_DAYS:-3}"
JOURNAL_TARGET_SIZE="${JOURNAL_TARGET_SIZE:-500M}"
B2GOV_LOG_PATTERN="${B2GOV_LOG_PATTERN:-/var/log/b2gov/batchdb.*.out.*}"

log() {
  local timestamp
  timestamp="$(date --iso-8601=seconds)"
  printf '[%s] %s\n' "$timestamp" "$1" | tee -a "$LOG_FILE"
}

require_root() {
  if [[ $EUID -ne 0 ]]; then
    echo "This script must run as root (cleanup commands need elevated privileges)." >&2
    exit 1
  fi
}

percent_used() {
  df -P "$TARGET_MOUNT" | awk 'NR==2 {gsub(/%/, "", $5); print $5}'
}

run_cmd() {
  local description="$1"
  shift
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    log "Skipping ${description}: '$cmd' not installed."
    return 0
  fi

  log "Running ${description}: $*"
  if [[ "$DRY_RUN" == "true" ]]; then
    log "DRY_RUN=true; command not executed."
    return 0
  fi

  "$@" && log "Completed ${description}."
}

cleanup_logs() {
  log "Pruning compressed logs older than ${LOG_RETENTION_DAYS}d in /var/log"
  if [[ "$DRY_RUN" == "true" ]]; then
    log "DRY_RUN=true; skipping log deletion."
    return 0
  fi

  find /var/log -type f -name "*.gz" -mtime +"$LOG_RETENTION_DAYS" -print -delete
}

cleanup_tmp_dirs() {
  local dirs=(/tmp /var/tmp)
  for dir in "${dirs[@]}"; do
    if [[ -d "$dir" ]]; then
      log "Deleting files in ${dir} older than ${TMP_RETENTION_DAYS}d"
      if [[ "$DRY_RUN" == "true" ]]; then
        log "DRY_RUN=true; skipping tmp cleanup for ${dir}."
        continue
      fi
      find "$dir" -mindepth 1 -mtime +"$TMP_RETENTION_DAYS" -print -delete
    fi
  done
}

cleanup_b2gov_logs() {
  if [[ -z "$B2GOV_LOG_PATTERN" ]]; then
    log "B2GOV_LOG_PATTERN empty; skipping b2gov cleanup."
    return 0
  fi

  shopt -s nullglob
  local files=($B2GOV_LOG_PATTERN)
  shopt -u nullglob

  if (( ${#files[@]} == 0 )); then
    log "No files match ${B2GOV_LOG_PATTERN}; skipping."
    return 0
  fi

  log "Deleting ${#files[@]} file(s) matching ${B2GOV_LOG_PATTERN}"
  if [[ "$DRY_RUN" == "true" ]]; then
    log "DRY_RUN=true; would delete: ${files[*]}"
    return 0
  fi

  rm -f -- "${files[@]}"
  log "Removed b2gov files."
}

main() {
  require_root
  mkdir -p "$(dirname "$LOG_FILE")"

  local usage
  usage="$(percent_used)"
  log "Usage on ${TARGET_MOUNT}: ${usage}% (threshold ${THRESHOLD}%)."

  if (( usage < THRESHOLD )); then
    log "Threshold not reached; exiting."
    exit 0
  fi

  log "Threshold met; starting cleanup actions."
  run_cmd "apt cache clean" apt-get clean
  run_cmd "apt autoremove" apt-get autoremove -y
  run_cmd "journal vacuum to ${JOURNAL_TARGET_SIZE}" journalctl --vacuum-size="$JOURNAL_TARGET_SIZE"
  cleanup_logs
  cleanup_tmp_dirs
  cleanup_b2gov_logs
  run_cmd "truncate rotated logs" logrotate -f /etc/logrotate.conf
  run_cmd "docker prune" docker system prune -af --volumes

  log "Cleanup workflow finished."
  usage="$(percent_used)"
  log "Usage after cleanup: ${usage}%."
}

main "$@"
