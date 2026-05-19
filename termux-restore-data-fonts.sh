#!/system/bin/sh

MODPATH=${0%/*}
TERMUX_RESTORE_ACTION="${1:-repair}"

case "$TERMUX_RESTORE_ACTION" in
  repair|--repair|scan|--scan|saved|--saved)
    EXECUTION_CONTEXT=runtime
    ;;
  original|--original|backup|--backup|backups|--backups)
    EXECUTION_CONTEXT=uninstall
    ;;
  -h|--help|help)
    echo "Usage: sh $0 [repair|saved|original]"
    echo "  repair   re-scan /data/data and re-apply the module emoji font"
    echo "  saved    re-apply only previously remembered /data/data font paths"
    echo "  original restore original /data/data font backups"
    exit 0
    ;;
  *)
    echo "Unknown mode: $TERMUX_RESTORE_ACTION"
    echo "Usage: sh $0 [repair|saved|original]"
    exit 2
    ;;
esac

. "$MODPATH/emoji-common.sh"

prime_saved_data_packages_for_cleanup() {
  local target_path
  local package_name

  [ -f "$DATA_FONT_PATHS_FILE" ] || return 0

  while IFS= read -r target_path; do
    [ -n "$target_path" ] || continue
    remember_data_font_path "$target_path"
    package_name="$(extract_package_from_data_path "$target_path")"
    register_touched_package "$package_name"
  done < "$DATA_FONT_PATHS_FILE"
}

show_recent_log() {
  if [ -f "$PUBLIC_LOG_FILE" ]; then
    tail -n 80 "$PUBLIC_LOG_FILE"
  elif [ -f "$LOGFILE" ]; then
    tail -n 80 "$LOGFILE"
  fi
}

ensure_public_paths

if ! acquire_run_lock; then
  append_log "INFO: Skipping Termux data-font restore because another repair is already in progress"
  echo "MFFMEmoji repair is already running. Try again after it finishes."
  exit 0
fi
trap 'release_run_lock' EXIT

determine_mount_mode

case "$TERMUX_RESTORE_ACTION" in
  original|--original|backup|--backup|backups|--backups)
    append_log "INFO: Termux original data-font restore started"
    update_public_status "Running Termux original data-font restore"
    restore_data_font_backups
    update_public_status "Termux original data-font restore completed"
    append_log "INFO: Termux original data-font restore finished"
    ;;
  saved|--saved)
    append_log "INFO: Termux saved-path data-font restore started"
    update_public_status "Running Termux saved-path data-font restore"
    begin_runtime_tracking
    prime_saved_data_packages_for_cleanup
    ensure_font_payload
    restore_saved_data_font_overrides
    cleanup_runtime_font_dirs
    clear_known_caches
    finalize_runtime_tracking
    persist_package_snapshot
    update_public_status "Termux saved-path data-font restore completed: root=$ROOT_SOLUTION, mount=$MOUNT_MODE"
    append_log "INFO: Termux saved-path data-font restore finished"
    ;;
  *)
    append_log "INFO: Termux data-font scan restore started"
    update_public_status "Running Termux data-font scan restore: root=$ROOT_SOLUTION, mount=$MOUNT_MODE"
    begin_runtime_tracking
    prime_saved_data_packages_for_cleanup
    ensure_font_payload
    restore_saved_data_font_overrides
    replace_data_emoji_fonts
    cleanup_runtime_font_dirs
    clear_known_caches
    finalize_runtime_tracking
    persist_package_snapshot
    update_public_status "Termux data-font scan restore completed: root=$ROOT_SOLUTION, mount=$MOUNT_MODE"
    append_log "INFO: Termux data-font scan restore finished"
    ;;
esac

show_recent_log
exit 0
