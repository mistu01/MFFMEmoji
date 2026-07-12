#!/system/bin/sh

MODPATH=${MODPATH:-${0%/*}}
EMOJI_CONFIG="$MODPATH/targets.conf"
STATE_DIR="$MODPATH/var"
LOGFILE="$MODPATH/service.log"
PUBLIC_LOG_DIR="/sdcard/EmojiModule"
PUBLIC_LOG_FILE="$PUBLIC_LOG_DIR/service.log"
PUBLIC_STATUS_FILE="$PUBLIC_LOG_DIR/last-status.txt"
PUBLIC_DEBUG_HINT_FILE="$PUBLIC_LOG_DIR/README.txt"
DATA_FONT_PATHS_FILE="$STATE_DIR/data-font-paths.list"
RUN_DATA_FONT_PATHS_FILE="$STATE_DIR/data-font-paths.run"
TOUCHED_PACKAGES_FILE="$STATE_DIR/touched-packages.list"
RUN_TOUCHED_PACKAGES_FILE="$STATE_DIR/touched-packages.run"
FORCE_STOPPED_PACKAGES_FILE="$STATE_DIR/force-stopped-packages.list"
LEGACY_DATA_FONT_BACKUP_DIR="$STATE_DIR/data-font-backups"
LEGACY_DATA_FONT_BACKUP_MANIFEST="$STATE_DIR/data-font-backups.list"
PACKAGE_SNAPSHOT_FILE="$STATE_DIR/packages.snapshot"
PACKAGE_SNAPSHOT_CURRENT_FILE="$STATE_DIR/packages.snapshot.current"
LOCKDIR="$STATE_DIR/run.lock"
UNINSTALLING_FLAG="$STATE_DIR/uninstalling"
RESTORED_DATA_FONT_TARGETS_FILE=""

FONT_NAME="${FONT_NAME:-NotoColorEmoji.ttf}"
FONT_DIR="${FONT_DIR:-$MODPATH/system/fonts}"
FONT_PATH="${FONT_PATH:-$FONT_DIR/$FONT_NAME}"
SOURCE_FONT="${SOURCE_FONT:-$MODPATH/Emoji.ttf}"
EXECUTION_CONTEXT="${EXECUTION_CONTEXT:-runtime}"
MODULE_ID="$(grep -m1 '^id=' "$MODPATH/module.prop" 2>/dev/null | cut -d'=' -f2-)"
[ -n "$MODULE_ID" ] || MODULE_ID="$(basename "$MODPATH")"
PERSISTENT_STATE_DIR="/data/adb/emoji-module-state/$MODULE_ID"
DATA_FONT_BACKUP_DIR="$PERSISTENT_STATE_DIR/data-font-backups"
DATA_FONT_BACKUP_MANIFEST="$PERSISTENT_STATE_DIR/data-font-backups.list"

MODE="aggressive"
CLEAR_GMS_DOWNLOADED_FONTS=false
DEBUG_ENABLED=true
TRACE_SCAN_DETAILS=true
SHOW_TRACE_ON_SCREEN=false

DEBUG_FLAG_PATHS="
/sdcard/EmojiModule/debug
/sdcard/Android/media/EmojiModule/debug
"

PROTECTED_INSTALLER_PACKAGES="
com.topjohnwu.magisk
io.github.vvb2060.magisk
me.weishu.kernelsu
me.bmax.apatch
"

SYSTEM_FONT_SCAN_DIRS="
/system/fonts
"

[ -f "$EMOJI_CONFIG" ] && . "$EMOJI_CONFIG"

mkdir -p "$STATE_DIR" 2>/dev/null

append_log() {
  mkdir -p "$STATE_DIR" 2>/dev/null
  echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$LOGFILE"
  ensure_public_paths
  [ -d "$PUBLIC_LOG_DIR" ] && echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$PUBLIC_LOG_FILE"
}

ui_note() {
  if command -v ui_print >/dev/null 2>&1; then
    ui_print "$1"
  else
    echo "$1"
  fi
}

command -v abort >/dev/null 2>&1 || abort() {
  append_log "ERROR: $1"
  ui_note "$1"
  exit 1
}

ensure_public_paths() {
  mkdir -p "$PUBLIC_LOG_DIR" 2>/dev/null
  [ -d "$PUBLIC_LOG_DIR" ] || return 0

  cat > "$PUBLIC_DEBUG_HINT_FILE" <<'EOF'
Emoji Module runtime files

- service.log      : runtime repair log
- last-status.txt  : latest status summary
- debug            : optional marker file; debug logging is already enabled by default

Example:
  touch /sdcard/EmojiModule/debug
EOF
}

update_public_status() {
  ensure_public_paths
  [ -d "$PUBLIC_LOG_DIR" ] || return 0
  printf '%s\n' "$1" > "$PUBLIC_STATUS_FILE"
}

runtime_notify() {
  local title="$1"
  local text="$2"

  if command -v cmd >/dev/null 2>&1; then
    cmd notification post -S bigtext -t "$title" EmojiModule "$text" >/dev/null 2>&1
  fi
}

diagnostics_enabled() {
  [ "$DEBUG_ENABLED" = "true" ] && return 0

  local flag
  for flag in $DEBUG_FLAG_PATHS; do
    [ -e "$flag" ] && return 0
  done
  return 1
}

debug_log() {
  diagnostics_enabled || return 0
  append_log "DEBUG: $1"
}

trace_log() {
  diagnostics_enabled || return 0
  [ "$TRACE_SCAN_DETAILS" = "true" ] || return 0
  append_log "TRACE: $1"
  [ "$SHOW_TRACE_ON_SCREEN" = "true" ] && ui_note "- TRACE: $1"
}

set_state() {
  mkdir -p "$STATE_DIR" 2>/dev/null
  printf '%s' "$2" > "$STATE_DIR/$1"
}

get_state() {
  [ -f "$STATE_DIR/$1" ] && cat "$STATE_DIR/$1"
}

append_unique_line() {
  local target_file="$1"
  local value="$2"
  local target_dir

  [ -n "$target_file" ] || return 0
  [ -n "$value" ] || return 0

  target_dir="${target_file%/*}"
  if [ "$target_dir" != "$target_file" ]; then
    mkdir -p "$target_dir" 2>/dev/null
  else
    mkdir -p "$STATE_DIR" 2>/dev/null
  fi

  touch "$target_file" 2>/dev/null || return 0
  grep -Fxq "$value" "$target_file" 2>/dev/null && return 0
  printf '%s\n' "$value" >> "$target_file"
}

path_checksum() {
  local checksum

  checksum="$(printf '%s' "$1" | cksum)"
  echo "${checksum%% *}"
}

file_checksum() {
  local checksum

  [ -f "$1" ] || return 1
  checksum="$(cksum "$1" 2>/dev/null)" || return 1
  echo "${checksum%% *}"
}

files_are_same() {
  local first="$1"
  local second="$2"
  local first_sum
  local second_sum

  [ -f "$first" ] || return 1
  [ -f "$second" ] || return 1

  if command -v cmp >/dev/null 2>&1; then
    cmp -s "$first" "$second"
    return $?
  fi

  first_sum="$(file_checksum "$first")" || return 1
  second_sum="$(file_checksum "$second")" || return 1
  [ "$first_sum" = "$second_sum" ]
}

data_font_backup_path_for() {
  local target_path="$1"
  local checksum
  local base_name

  checksum="$(path_checksum "$target_path")"
  base_name="$(basename "$target_path")"
  echo "$DATA_FONT_BACKUP_DIR/${checksum}-${base_name}"
}

copy_file_preserving_metadata() {
  local source_path="$1"
  local target_path="$2"

  cp -p "$source_path" "$target_path" 2>/dev/null || cp -f "$source_path" "$target_path" 2>/dev/null || return 1
  return 0
}

capture_file_metadata() {
  local target_path="$1"
  local meta_path="$2"
  local uid
  local gid
  local mode
  local context

  uid="$(stat -c '%u' "$target_path" 2>/dev/null)"
  gid="$(stat -c '%g' "$target_path" 2>/dev/null)"
  mode="$(stat -c '%a' "$target_path" 2>/dev/null)"
  context="$(stat -c '%C' "$target_path" 2>/dev/null)"
  [ -n "$context" ] || context="$(ls -Zd "$target_path" 2>/dev/null | sed 's/[[:space:]].*//')"
  [ "$context" = "?" ] && context=""

  {
    printf 'target=%s\n' "$target_path"
    [ -n "$uid" ] && printf 'uid=%s\n' "$uid"
    [ -n "$gid" ] && printf 'gid=%s\n' "$gid"
    [ -n "$mode" ] && printf 'mode=%s\n' "$mode"
    [ -n "$context" ] && printf 'context=%s\n' "$context"
  } > "$meta_path"
}

restore_file_metadata() {
  local target_path="$1"
  local meta_path="$2"
  local uid
  local gid
  local mode
  local context

  [ -f "$meta_path" ] || return 0

  uid="$(sed -n 's/^uid=//p' "$meta_path" | sed -n '1p')"
  gid="$(sed -n 's/^gid=//p' "$meta_path" | sed -n '1p')"
  mode="$(sed -n 's/^mode=//p' "$meta_path" | sed -n '1p')"
  context="$(sed -n 's/^context=//p' "$meta_path" | sed -n '1p')"

  if [ -n "$uid" ] && [ -n "$gid" ]; then
    chown "$uid:$gid" "$target_path" 2>/dev/null
  fi

  [ -n "$mode" ] && chmod "$mode" "$target_path" 2>/dev/null
  [ -n "$context" ] && chcon "$context" "$target_path" 2>/dev/null
}

backup_data_font_once() {
  local target_path="$1"
  local backup_path
  local meta_path

  [ -f "$target_path" ] || return 1
  mkdir -p "$DATA_FONT_BACKUP_DIR" 2>/dev/null || return 1

  backup_path="$(data_font_backup_path_for "$target_path")"
  meta_path="$backup_path.meta"

  if [ -f "$backup_path" ]; then
    if files_are_same "$target_path" "$FONT_PATH"; then
      append_unique_line "$DATA_FONT_BACKUP_MANIFEST" "$backup_path|$target_path"
      trace_log "Existing backup kept; target already matches module font: $target_path"
      return 0
    fi

    if files_are_same "$target_path" "$backup_path"; then
      append_unique_line "$DATA_FONT_BACKUP_MANIFEST" "$backup_path|$target_path"
      trace_log "Existing backup already matches target: $target_path"
      return 0
    fi

    append_log "INFO: Refreshing data emoji font backup after target changed: $target_path"
  elif files_are_same "$target_path" "$FONT_PATH"; then
    append_log "WARN: Skipping backup because target already matches module font: $target_path"
    return 1
  fi

  copy_file_preserving_metadata "$target_path" "$backup_path" || return 1
  capture_file_metadata "$target_path" "$meta_path"
  append_unique_line "$DATA_FONT_BACKUP_MANIFEST" "$backup_path|$target_path"
  append_log "INFO: Backed up original data emoji font: $target_path"
  return 0
}

restore_data_font_backup_manifest() {
  local manifest_file="$1"
  local manifest_line
  local backup_path
  local meta_path
  local target_path
  local package_name
  local restored_packages=""
  local restored=0
  local failed=0
  local missing=0
  local skipped=0

  [ -f "$manifest_file" ] || {
    append_log "INFO: No data font backups found for uninstall restore"
    return 0
  }

  while IFS= read -r manifest_line; do
    [ -n "$manifest_line" ] || continue
    backup_path="${manifest_line%%|*}"
    target_path="${manifest_line#*|}"
    meta_path="$backup_path.meta"

    if [ -n "$RESTORED_DATA_FONT_TARGETS_FILE" ] && grep -Fxq "$target_path" "$RESTORED_DATA_FONT_TARGETS_FILE" 2>/dev/null; then
      skipped=$((skipped + 1))
      trace_log "Backup restore skipped; target already restored: $target_path"
      continue
    fi

    if [ ! -f "$backup_path" ] || [ ! -f "$target_path" ]; then
      missing=$((missing + 1))
      trace_log "Backup restore skipped missing path: backup=$backup_path target=$target_path"
      continue
    fi

    if files_are_same "$backup_path" "$FONT_PATH"; then
      skipped=$((skipped + 1))
      append_log "WARN: Skipped contaminated data font backup matching module font: $target_path"
      continue
    fi

    umount "$target_path" >/dev/null 2>&1
    if copy_file_preserving_metadata "$backup_path" "$target_path"; then
      restore_file_metadata "$target_path" "$meta_path"
      [ -n "$RESTORED_DATA_FONT_TARGETS_FILE" ] && append_unique_line "$RESTORED_DATA_FONT_TARGETS_FILE" "$target_path"
      package_name="$(extract_package_from_data_path "$target_path")"
      case " $restored_packages " in
        *" $package_name "*) ;;
        *) restored_packages="$restored_packages $package_name" ;;
      esac
      restored=$((restored + 1))
      append_log "INFO: Restored original data emoji font: $target_path"
    else
      failed=$((failed + 1))
      append_log "WARN: Failed to restore original data emoji font: $target_path"
    fi
  done < "$manifest_file"

  for package_name in $restored_packages; do
    [ -n "$package_name" ] || continue
    clear_package_cache "$package_name"
  done

  append_log "INFO: Data font backup restore summary: restored=$restored failed=$failed missing=$missing skipped=$skipped"
}

restore_data_font_backups() {
  RESTORED_DATA_FONT_TARGETS_FILE="$STATE_DIR/restored-data-font-targets.$$"
  : > "$RESTORED_DATA_FONT_TARGETS_FILE"

  restore_data_font_backup_manifest "$DATA_FONT_BACKUP_MANIFEST"

  if [ "$LEGACY_DATA_FONT_BACKUP_MANIFEST" != "$DATA_FONT_BACKUP_MANIFEST" ]; then
    restore_data_font_backup_manifest "$LEGACY_DATA_FONT_BACKUP_MANIFEST"
  fi

  rm -f "$RESTORED_DATA_FONT_TARGETS_FILE" 2>/dev/null
  RESTORED_DATA_FONT_TARGETS_FILE=""
}

begin_runtime_tracking() {
  mkdir -p "$STATE_DIR" 2>/dev/null
  : > "$RUN_DATA_FONT_PATHS_FILE"
  : > "$RUN_TOUCHED_PACKAGES_FILE"
  LAST_TOUCHED_PACKAGES=""
}

finalize_runtime_tracking() {
  [ -f "$RUN_DATA_FONT_PATHS_FILE" ] && mv -f "$RUN_DATA_FONT_PATHS_FILE" "$DATA_FONT_PATHS_FILE" 2>/dev/null
  [ -f "$RUN_TOUCHED_PACKAGES_FILE" ] && mv -f "$RUN_TOUCHED_PACKAGES_FILE" "$TOUCHED_PACKAGES_FILE" 2>/dev/null
}

package_installed() {
  pm list packages | grep -q "^package:$1$"
}

foreground_package() {
  local package_name

  package_name="$(dumpsys activity activities 2>/dev/null | sed -n 's/.*topResumedActivity.* \([^ /]*\)\/.*/\1/p' | head -n 1)"
  [ -n "$package_name" ] && {
    echo "$package_name"
    return 0
  }

  package_name="$(dumpsys window 2>/dev/null | sed -n 's/.*mCurrentFocus=.* \([^ /]*\)\/.*/\1/p' | head -n 1)"
  [ -n "$package_name" ] && {
    echo "$package_name"
    return 0
  }

  return 1
}

detect_root_solution() {
  if [ "$KSU" = "true" ] || [ -d /data/adb/ksu ]; then
    echo "KernelSU"
  elif [ "$APATCH" = "true" ] || [ "$KERNELPATCH" = "true" ] || [ -d /data/adb/ap ]; then
    echo "APatch"
  elif [ -n "$MAGISK_VER_CODE" ] || [ -f /data/adb/magisk/util_functions.sh ]; then
    echo "Magisk"
  else
    echo "Unknown"
  fi
}

metamodule_present() {
  [ -L /data/adb/metamodule ] && return 0
  grep -Rqs '^metamodule=\(1\|true\)$' /data/adb/modules/*/module.prop 2>/dev/null && return 0
  grep -Rqs '^metamodule=\(1\|true\)$' /data/adb/modules_update/*/module.prop 2>/dev/null && return 0
  return 1
}

determine_mount_mode() {
  ROOT_SOLUTION="$(detect_root_solution)"
  MOUNT_MODE="full"

  if [ "$ROOT_SOLUTION" = "KernelSU" ] && ! metamodule_present; then
    MOUNT_MODE="data-only"
  fi

  debug_log "Detected root solution: $ROOT_SOLUTION"
  debug_log "Selected mount mode: $MOUNT_MODE"
}

ensure_font_payload() {
  mkdir -p "$FONT_DIR"
  [ -f "$FONT_PATH" ] && {
    debug_log "Font payload already staged at $FONT_PATH"
    return 0
  }

  [ -f "$SOURCE_FONT" ] || abort "! Missing font payload: $SOURCE_FONT"
  cp -f "$SOURCE_FONT" "$FONT_PATH" || abort "! Failed to stage $FONT_NAME"
}

find_emoji_font_candidates() {
  local search_root="$1"

  [ -d "$search_root" ] || return 0
  find "$search_root" -type f \( -name '*Emoji*.ttf' -o -name '*emoji*.ttf' -o -name '*EMOJI*.ttf' \) 2>/dev/null
}

module_font_target_for() {
  local source_path="$1"
  local base_name

  base_name="$(basename "$source_path")"

  case "$source_path" in
    /system/fonts/*|/system/system/fonts/*)
      echo "$MODPATH/system/fonts/$base_name"
      ;;
    /product/fonts/*)
      echo "$MODPATH/product/fonts/$base_name"
      ;;
    /system_ext/fonts/*)
      echo "$MODPATH/system_ext/fonts/$base_name"
      ;;
    /vendor/fonts/*)
      echo "$MODPATH/vendor/fonts/$base_name"
      ;;
    *)
      return 1
      ;;
  esac
}

replace_system_emoji_fonts() {
  local search_root
  local source_path
  local target_path
  local replaced=0
  local failed=0
  local candidate_file

  [ "$MOUNT_MODE" = "full" ] || {
    ui_note "- Skipping system font scan in data-only mode"
    return 0
  }

  ensure_font_payload

  for search_root in $SYSTEM_FONT_SCAN_DIRS; do
    [ -d "$search_root" ] || continue
    debug_log "Scanning system font directory: $search_root"
    candidate_file="$STATE_DIR/system-font-candidates.$$"
    find_emoji_font_candidates "$search_root" > "$candidate_file"

    while IFS= read -r source_path; do
      target_path="$(module_font_target_for "$source_path")" || {
        trace_log "Skipped unsupported system candidate path: $source_path"
        continue
      }

      trace_log "System font candidate: source=$source_path target=$target_path"

      if [ "$target_path" = "$FONT_PATH" ]; then
        replaced=$((replaced + 1))
        append_log "INFO: Replaced system emoji font: $source_path"
        ui_note "- Replaced system font: $source_path"
        trace_log "System replacement success via primary font payload: $source_path"
        continue
      fi

      mkdir -p "$(dirname "$target_path")" 2>/dev/null
      if cp -f "$FONT_PATH" "$target_path" 2>/dev/null; then
        chmod 0644 "$target_path" 2>/dev/null
        replaced=$((replaced + 1))
        append_log "INFO: Replaced system emoji font: $source_path"
        ui_note "- Replaced system font: $source_path"
        trace_log "System replacement success: $source_path"
      else
        failed=$((failed + 1))
        append_log "WARN: Failed system emoji font replacement: $source_path"
        ui_note "- Failed system font: $source_path"
        trace_log "System replacement failed: $source_path"
      fi
    done < "$candidate_file"

    rm -f "$candidate_file" 2>/dev/null
  done

  append_log "INFO: System scan summary: replaced=$replaced failed=$failed"
}

cleanup_runtime_font_dirs() {
  local cleaned=0

  if [ -d /data/fonts ]; then
    rm -rf /data/fonts 2>/dev/null
    debug_log "Cleared /data/fonts"
    cleaned=$((cleaned + 1))
  fi

  if [ "$CLEAR_GMS_DOWNLOADED_FONTS" = "true" ] && [ -d /data/data/com.google.android.gms/files/fonts/opentype ]; then
    find /data/data/com.google.android.gms/files/fonts/opentype -type f -name '*.ttf' -delete 2>/dev/null
    debug_log "Cleared GMS downloaded fonts"
    cleaned=$((cleaned + 1))
  fi
  append_log "INFO: Runtime font cleanup tasks completed: $cleaned"
}

replace_file_with_font() {
  [ -f "$1" ] || return 1
  cp -f "$FONT_PATH" "$1" 2>/dev/null || return 1
  chmod 0644 "$1" 2>/dev/null
}

bind_mount_font() {
  local target_path="$1"

  [ -f "$target_path" ] || return 1
  umount "$target_path" >/dev/null 2>&1
  mount -o bind "$FONT_PATH" "$target_path" >/dev/null 2>&1 && return 0
  mount --bind "$FONT_PATH" "$target_path" >/dev/null 2>&1 && return 0
  return 1
}

apply_data_font_override() {
  local target_path="$1"

  [ -f "$target_path" ] || return 1
  umount "$target_path" >/dev/null 2>&1
  backup_data_font_once "$target_path" || append_log "WARN: Failed to back up data emoji font before replacement: $target_path"
  replace_file_with_font "$target_path" || return 1

  if bind_mount_font "$target_path"; then
    append_log "INFO: Bound data emoji font: $target_path"
    trace_log "Data bind mount active: $target_path"
  else
    append_log "WARN: Data bind mount unavailable, using copied font only: $target_path"
    trace_log "Data bind mount unavailable: $target_path"
  fi

  return 0
}

extract_package_from_data_path() {
  printf '%s\n' "$1" | sed -n 's#^/data/data/\([^/]*\)/.*#\1#p'
}

remember_data_font_path() {
  local target_path="$1"

  [ -n "$target_path" ] || return 0
  append_unique_line "$RUN_DATA_FONT_PATHS_FILE" "$target_path"
}

register_touched_package() {
  local package_name="$1"

  [ -n "$package_name" ] || return 0
  append_unique_line "$RUN_TOUCHED_PACKAGES_FILE" "$package_name"
  case " $LAST_TOUCHED_PACKAGES " in
    *" $package_name "*) ;;
    *) LAST_TOUCHED_PACKAGES="$LAST_TOUCHED_PACKAGES $package_name" ;;
  esac
}

package_was_force_stopped() {
  local package_name="$1"

  [ -n "$package_name" ] || return 1
  [ -f "$FORCE_STOPPED_PACKAGES_FILE" ] || return 1
  grep -Fxq "$package_name" "$FORCE_STOPPED_PACKAGES_FILE" 2>/dev/null
}

remember_force_stopped_package() {
  local package_name="$1"

  [ -n "$package_name" ] || return 0
  append_unique_line "$FORCE_STOPPED_PACKAGES_FILE" "$package_name"
}

package_version_token() {
  local package_name="$1"
  local version_code
  local package_paths

  package_installed "$package_name" || return 1

  version_code="$(dumpsys package "$package_name" 2>/dev/null | sed -n 's/.*versionCode=\([0-9][0-9]*\).*/\1/p' | head -n 1)"
  package_paths="$(pm path "$package_name" 2>/dev/null | sed 's/^package://')"

  [ -n "$version_code$package_paths" ] || return 1
  printf '%s|%s|' "$package_name" "${version_code:-unknown}"
  printf '%s' "$package_paths" | tr '\n' ';'
  printf '\n'
}

generate_package_snapshot() {
  local output_file="$1"
  local package_name
  local snapshot_line

  : > "$output_file"
  [ -f "$TOUCHED_PACKAGES_FILE" ] || return 0

  while IFS= read -r package_name; do
    [ -n "$package_name" ] || continue
    snapshot_line="$(package_version_token "$package_name")" || continue
    printf '%s\n' "$snapshot_line" >> "$output_file"
  done < "$TOUCHED_PACKAGES_FILE"
}

packages_have_changed() {
  local current_snapshot
  local previous_snapshot

  [ -f "$TOUCHED_PACKAGES_FILE" ] || return 1

  generate_package_snapshot "$PACKAGE_SNAPSHOT_CURRENT_FILE"
  current_snapshot="$(cat "$PACKAGE_SNAPSHOT_CURRENT_FILE" 2>/dev/null)"
  previous_snapshot="$(cat "$PACKAGE_SNAPSHOT_FILE" 2>/dev/null)"
  rm -f "$PACKAGE_SNAPSHOT_CURRENT_FILE" 2>/dev/null

  [ -n "$current_snapshot" ] || return 1
  [ "$current_snapshot" != "$previous_snapshot" ]
}

persist_package_snapshot() {
  local snapshot_tmp="$STATE_DIR/packages.snapshot.run"

  generate_package_snapshot "$snapshot_tmp"
  mv -f "$snapshot_tmp" "$PACKAGE_SNAPSHOT_FILE" 2>/dev/null
}

is_protected_installer_package() {
  local package_name="$1"
  local protected_package

  for protected_package in $PROTECTED_INSTALLER_PACKAGES; do
    [ "$package_name" = "$protected_package" ] && return 0
  done

  return 1
}

acquire_run_lock() {
  mkdir -p "$STATE_DIR" 2>/dev/null
  if mkdir "$LOCKDIR" 2>/dev/null; then
    printf '%s\n' "$$" > "$LOCKDIR/pid"
    return 0
  fi
  return 1
}

release_run_lock() {
  [ -d "$LOCKDIR" ] && rm -rf "$LOCKDIR"
}

should_skip_package_replacement() {
  local package_name="$1"
  local active_package="$2"

  [ "$EXECUTION_CONTEXT" = "install" ] || return 1
  [ -n "$package_name" ] || return 1

  if [ -n "$active_package" ] && [ "$package_name" = "$active_package" ]; then
    return 0
  fi

  if is_protected_installer_package "$package_name"; then
    return 0
  fi

  return 1
}

replace_data_emoji_fonts() {
  local source_path
  local replaced=0
  local failed=0
  local scanned=0
  local package_name
  local active_package=""
  local skipped_protected=0
  local candidate_file

  ensure_font_payload
  debug_log "Starting broad /data/data emoji font scan"
  if [ "$EXECUTION_CONTEXT" = "install" ]; then
    active_package="$(foreground_package)"
    [ -n "$active_package" ] && debug_log "Foreground package during install-time data scan: $active_package"
  fi

  candidate_file="$STATE_DIR/data-font-candidates.$$"
  find_emoji_font_candidates /data/data > "$candidate_file"

  while IFS= read -r source_path; do
    scanned=$((scanned + 1))
    trace_log "Data font candidate: $source_path"
    package_name="$(extract_package_from_data_path "$source_path")"

    if should_skip_package_replacement "$package_name" "$active_package"; then
      skipped_protected=$((skipped_protected + 1))
      append_log "INFO: Skipped installer-host package font during install: $source_path"
      ui_note "- Skipped install host font: $source_path"
      trace_log "Installer-host package skipped during install-time replacement: package=$package_name path=$source_path"
      continue
    fi

    if apply_data_font_override "$source_path"; then
      replaced=$((replaced + 1))
      remember_data_font_path "$source_path"
      register_touched_package "$package_name"
      append_log "INFO: Replaced data emoji font: $source_path"
      ui_note "- Replaced data font: $source_path"
      trace_log "Data replacement success: $source_path"
    else
      failed=$((failed + 1))
      append_log "WARN: Failed broad replacement for $source_path"
      ui_note "- Failed data font: $source_path"
      trace_log "Data replacement failed: $source_path"
    fi
  done < "$candidate_file"

  rm -f "$candidate_file" 2>/dev/null

  append_log "INFO: Broad data scan summary: scanned=$scanned replaced=$replaced failed=$failed skipped_protected=$skipped_protected"
}

restore_saved_data_font_overrides() {
  local target_path
  local restored=0
  local failed=0
  local missing=0

  [ -f "$DATA_FONT_PATHS_FILE" ] || return 0

  ensure_font_payload
  while IFS= read -r target_path; do
    [ -n "$target_path" ] || continue

    if [ ! -f "$target_path" ]; then
      missing=$((missing + 1))
      trace_log "Saved data font path missing during restore: $target_path"
      continue
    fi

    if apply_data_font_override "$target_path"; then
      restored=$((restored + 1))
      trace_log "Saved data font restore success: $target_path"
    else
      failed=$((failed + 1))
      append_log "WARN: Saved data font restore failed: $target_path"
      trace_log "Saved data font restore failed: $target_path"
    fi
  done < "$DATA_FONT_PATHS_FILE"

  append_log "INFO: Saved data font restore summary: restored=$restored failed=$failed missing=$missing"
}

clear_package_cache() {
  local package_name="$1"
  local cache_dir
  local force_stop_mode="first-only"

  if [ "$EXECUTION_CONTEXT" = "install" ]; then
    trace_log "Cache cleanup skipped during install context: $package_name"
    return 0
  fi

  if ! package_installed "$package_name"; then
    trace_log "Cache cleanup skipped; package not installed: $package_name"
    return 0
  fi

  for cache_dir in \
    "/data/data/$package_name/cache" \
    "/data/data/$package_name/code_cache" \
    "/data/data/$package_name/app_webview" \
    "/data/data/$package_name/files/GCache"; do
    if [ -d "$cache_dir" ]; then
      trace_log "Removing cache directory: $cache_dir"
      rm -rf "$cache_dir" 2>/dev/null
    fi
  done

  if [ "$package_name" = "com.google.android.gms" ]; then
    append_log "INFO: Cleared cache for com.google.android.gms without force-stop"
    trace_log "Skipped force-stop for com.google.android.gms"
    return 0
  fi

  # Uninstall restore always force-stops so apps reload original fonts.
  # Runtime repairs force-stop only on the first cleanup for each package;
  # later scans still replace fonts and clear caches without killing apps.
  if [ "$EXECUTION_CONTEXT" = "uninstall" ]; then
    force_stop_mode="always"
  elif package_was_force_stopped "$package_name"; then
    append_log "INFO: Cleared cache for $package_name without force-stop (already force-stopped once)"
    trace_log "Skipped force-stop; package already force-stopped on an earlier attempt: $package_name"
    return 0
  fi

  am force-stop "$package_name" >/dev/null 2>&1
  if [ "$force_stop_mode" = "first-only" ]; then
    remember_force_stopped_package "$package_name"
  fi
  append_log "INFO: Force-stopped package after cleanup: $package_name"
  trace_log "Force-stopped package after cleanup: $package_name"
}

clear_known_caches() {
  local package_name
  local cleared=0

  for package_name in $LAST_TOUCHED_PACKAGES; do
    clear_package_cache "$package_name"
    cleared=$((cleared + 1))
  done

  append_log "INFO: Cache cleanup attempted for packages: $cleared"
}

disable_gms_font_components() {
  append_log "INFO: Skipped GMS service disable step"
}

build_snapshot() {
  echo "mode=$MODE"
  echo "debug=$DEBUG_ENABLED"
  echo "trace=$TRACE_SCAN_DETAILS"
  echo "build=$(getprop ro.build.fingerprint)"
  echo "sdk=$(getprop ro.build.version.sdk)"
  echo "root=$ROOT_SOLUTION"
  echo "mount=$MOUNT_MODE"
}

snapshot_has_changed() {
  local current previous

  current="$(build_snapshot)"
  previous="$(get_state env_snapshot)"
  [ "$current" != "$previous" ]
}

persist_snapshot() {
  set_state env_snapshot "$(build_snapshot)"
}

repair_reason() {
  local current previous

  current="$(build_snapshot)"
  previous="$(get_state env_snapshot)"

  if [ -z "$previous" ]; then
    echo "initial run"
  elif [ "$(echo "$current" | sed -n 's/^build=//p')" != "$(echo "$previous" | sed -n 's/^build=//p')" ]; then
    echo "build fingerprint changed"
  elif [ "$(echo "$current" | sed -n 's/^root=//p')" != "$(echo "$previous" | sed -n 's/^root=//p')" ]; then
    echo "root method changed"
  elif [ "$(echo "$current" | sed -n 's/^mount=//p')" != "$(echo "$previous" | sed -n 's/^mount=//p')" ]; then
    echo "mount mode changed"
  else
    echo "runtime configuration changed"
  fi
}

run_aggressive_repair() {
  if [ -f "$UNINSTALLING_FLAG" ]; then
    append_log "INFO: Repair skipped because module uninstall is in progress"
    return 0
  fi

  determine_mount_mode
  append_log "INFO: Repair context root=$ROOT_SOLUTION mount=$MOUNT_MODE mode=$MODE"
  diagnostics_enabled && append_log "DEBUG: Trace logging is enabled"
  begin_runtime_tracking
  ensure_font_payload
  replace_system_emoji_fonts
  replace_data_emoji_fonts
  cleanup_runtime_font_dirs
  clear_known_caches
  disable_gms_font_components
  finalize_runtime_tracking
  update_public_status "Completed repair: root=$ROOT_SOLUTION, mount=$MOUNT_MODE, mode=$MODE"
  diagnostics_enabled && runtime_notify "Emoji Module" "Repair completed. Log: $PUBLIC_LOG_FILE"
}
