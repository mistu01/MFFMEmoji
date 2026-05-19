##########################################################################################
#
# Installer Script
#
##########################################################################################
#!/system/bin/sh

AUTOMOUNT=true
SKIPMOUNT=false
PROPFILE=false
POSTFSDATA=true
LATESTARTSERVICE=true

FONT_NAME="NotoColorEmoji.ttf"
FONT_DIR="$MODPATH/system/fonts"
FONT_PATH="$FONT_DIR/$FONT_NAME"
SOURCE_FONT="$MODPATH/Emoji.ttf"
EXECUTION_CONTEXT=install

. "$MODPATH/emoji-common.sh"

ensure_public_paths

ui_print " __  __ _____ __  __ "
ui_print "|  \\/  |  ___|  \\/  |"
ui_print "| |\\/| | |_  | |\\/| |"
ui_print "|_|  |_|_|   |_|  |_|"
ui_print "     Emoji Module    "
ui_print ""

determine_mount_mode
run_aggressive_repair

persist_snapshot

set_perm_recursive "$MODPATH" 0 0 0755 0644
set_perm "$FONT_PATH" 0 0 0644
[ -f "$MODPATH/action.sh" ] && set_perm "$MODPATH/action.sh" 0 0 0755
[ -f "$MODPATH/service.sh" ] && set_perm "$MODPATH/service.sh" 0 0 0755
[ -f "$MODPATH/post-fs-data.sh" ] && set_perm "$MODPATH/post-fs-data.sh" 0 0 0755
[ -f "$MODPATH/uninstall.sh" ] && set_perm "$MODPATH/uninstall.sh" 0 0 0755
[ -f "$MODPATH/termux-restore-data-fonts.sh" ] && set_perm "$MODPATH/termux-restore-data-fonts.sh" 0 0 0755
[ -f "$MODPATH/emoji-common.sh" ] && set_perm "$MODPATH/emoji-common.sh" 0 0 0755
[ -f "$MODPATH/targets.conf" ] && set_perm "$MODPATH/targets.conf" 0 0 0644
