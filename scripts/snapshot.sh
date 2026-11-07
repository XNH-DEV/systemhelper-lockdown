#!/usr/bin/env bash
# scripts/snapshot.sh — 独立快照（v2.0 第七阶段）
# 只读：把处置前的状态完整落盘，供 rollback 精确还原。
#
# 用法: bash scripts/snapshot.sh [--pkg P] [--user N] [--out DIR]
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/common.sh
. "$HERE/lib/common.sh"
# shellcheck source=lib/adb.sh
. "$HERE/lib/adb.sh"
# shellcheck source=lib/package.sh
. "$HERE/lib/package.sh"
# shellcheck source=lib/permissions.sh
. "$HERE/lib/permissions.sh"
# shellcheck source=lib/appops.sh
. "$HERE/lib/appops.sh"
# shellcheck source=lib/network.sh
. "$HERE/lib/network.sh"
# shellcheck source=lib/process.sh
. "$HERE/lib/process.sh"
# shellcheck source=lib/snapshot.sh
. "$HERE/lib/snapshot.sh"

PKG="${PKG:-com.mobiletools.systemhelper}"
USER_ID="${USER_ID:-0}"
OUT="${OUT:-$HERE/../logs}"

while [ $# -gt 0 ]; do
  case "$1" in
    --pkg)    PKG="$2"; shift 2 ;;
    --user)   USER_ID="$2"; shift 2 ;;
    --serial) SH_SERIAL="$2"; shift 2 ;;
    --out)    OUT="$2"; shift 2 ;;
    -h|--help) sed -n '2,5p' "$0"; exit 0 ;;
    *) sh_die "未知参数: $1" 2 ;;
  esac
done

sh_pick_device
sh_pkg_exists "$PKG" || sh_die "设备上没有 $PKG" 5

sh_snap_init "$OUT" "$PKG" "$USER_ID"
uid="$(sh_pkg_uid "$PKG")"
sh_snap_device
sh_snap_package "$PKG" "$USER_ID"
sh_snap_perms "$PKG" "$USER_ID"
sh_snap_appops "$PKG" "${uid:-0}"
sh_snap_network "${uid:-0}"
sh_shell dumpsys package "$PKG" >"$SH_SNAP/original_state/full-dumpsys.txt" 2>&1
sh_shell cmd appops get "$PKG" >"$SH_SNAP/original_state/full-appops.txt" 2>&1
sh_shell dumpsys alarm >"$SH_SNAP/original_state/alarm.txt" 2>&1
sh_shell dumpsys jobscheduler >"$SH_SNAP/original_state/jobscheduler.txt" 2>&1
sh_shell dumpsys device_policy >"$SH_SNAP/original_state/device_policy.txt" 2>&1
sh_shell cmd netpolicy list restrict-background-blacklist >"$SH_SNAP/original_state/netpolicy-blacklist.txt" 2>&1
sh_shell settings get secure enabled_accessibility_services >"$SH_SNAP/original_state/a11y.txt" 2>&1
sh_shell settings get secure enabled_notification_listeners >"$SH_SNAP/original_state/notif.txt" 2>&1

sh_snap_action "snapshot" "pkg=$PKG user=$USER_ID uid=${uid:-?}"
sh_log "快照完成: $SH_SNAP"
sh_log "  device.json package.json permissions.json appops.json network.json manifest.json"
sh_log "  original_state/ (dumpsys-package, appops, alarm, jobscheduler, netstats-t0 …)"
exit 0
