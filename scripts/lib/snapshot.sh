#!/usr/bin/env bash
# lib/snapshot.sh — 快照系统（v2.0 第七阶段结构，v2.1 6.3 字段）
# 依赖：common.sh adb.sh package.sh permissions.sh appops.sh network.sh
#
# 目录结构（规格书原文）：
#   logs/<时间戳>/{device,package,permissions,appops,network,execution}.json
#                 original_state/  after_state/  actions.log  manifest.json
#
# 安全：不写 IMEI / 序列号 / MAC；只写型号、ROM、包名、UID、路径、哈希。

SH_SNAP=""
SH_SNAP_JSON_ESC() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }

sh_snap_init() {  # <root> <pkg> <user>
  SH_SNAP="${1%/}/$(sh_stamp)"
  mkdir -p "$SH_SNAP/original_state" "$SH_SNAP/after_state"
  SH_STATE_FILE="$SH_SNAP/execution.tsv"
  : >"$SH_STATE_FILE"
  cat >"$SH_SNAP/manifest.json" <<EOF
{
  "snap_id": "$(sh_stamp)",
  "created": "$(date -Iseconds 2>/dev/null || sh_ts)",
  "host_tool": "systemhelper-lockdown",
  "pkg": "$(SH_SNAP_JSON_ESC "$2")",
  "target_user": $3,
  "serial_hash": "$(printf '%s' "${SH_SERIAL:-none}" | sha256sum | cut -c1-12)",
  "note": "不含 IMEI/MAC/序列号原文；serial 仅存哈希"
}
EOF
  : >"$SH_SNAP/actions.log"
  sh_log "快照目录: $SH_SNAP"
}

sh_snap_action() {  # <动作> <详情>
  printf '%s\t%s\t%s\n' "$(sh_ts)" "$1" "$2" >>"$SH_SNAP/actions.log"
}

sh_snap_device() {
  local m rom os ser
  m="$(sh_shell getprop ro.product.model)"
  rom="$(sh_shell getprop ro.build.version.incremental)"
  os="$(sh_shell getprop ro.mi.os.version.name)"
  cat >"$SH_SNAP/device.json" <<EOF
{
  "model": "$(SH_SNAP_JSON_ESC "$m")",
  "rom": "$(SH_SNAP_JSON_ESC "$rom")",
  "os": "$(SH_SNAP_JSON_ESC "$os")",
  "api": "$(sh_shell getprop ro.build.version.sdk)",
  "current_user": "$(sh_current_user)",
  "users": "$(sh_users | tr '\n' ' ' | sed 's/  */ /g')"
}
EOF
}

sh_snap_package() {  # <pkg> <user>
  local pkg="$1" user="$2" path uid vc vn sys splits shared line sha
  path="$(sh_pkg_path "$pkg")"
  uid="$(sh_pkg_uid "$pkg")"
  line="$(sh_pkg_user_line "$pkg" "$user")"
  sh_pkg_is_system "$pkg" && sys=true || sys=false
  splits="$(sh_pkg_splits "$pkg")"
  shared="$(sh_pkg_shared_uid "$pkg")"
  vc="$(sh_shell dumpsys package "$pkg" 2>/dev/null | grep -m1 -oE 'versionCode=[0-9]+' | cut -d= -f2)"
  vn="$(sh_shell dumpsys package "$pkg" 2>/dev/null | grep -m1 -oE 'versionName=[^ ]+' | cut -d= -f2)"
  sha="$(sh_shell "sha256sum '$path' 2>/dev/null" | awk '{print $1}')"
  cat >"$SH_SNAP/package.json" <<EOF
{
  "pkg": "$(SH_SNAP_JSON_ESC "$pkg")",
  "uid": "${uid:-null}",
  "apk_path": "$(SH_SNAP_JSON_ESC "$path")",
  "is_system": $sys,
  "splits": ${splits:-0},
  "shared_user": "$(SH_SNAP_JSON_ESC "$shared")",
  "version_code": "${vc:-null}",
  "version_name": "$(SH_SNAP_JSON_ESC "$vn")",
  "apk_sha256": "${sha:-unknown}",
  "user_state_raw": "$(SH_SNAP_JSON_ESC "$line")",
  "installed_for_user": $(sh_pkg_installed_for "$pkg" "$user" && echo true || echo false),
  "enabled": "$(sh_pkg_flag "$pkg" "$user" enabled)",
  "stopped": "$(sh_pkg_flag "$pkg" "$user" stopped)",
  "suspended": "$(sh_pkg_flag "$pkg" "$user" suspended)"
}
EOF
  sh_shell dumpsys package "$pkg" >"$SH_SNAP/original_state/dumpsys-package.txt" 2>&1
}

sh_snap_perms() {  # <pkg> <user>
  local pkg="$1" user="$2"
  {
    echo "{"
    echo '  "requested": ['
    sh_perm_requested "$pkg" | sed 's/.*/    "&",/' | sed '$ s/,$//'
    echo '  ],'
    echo '  "runtime_for_user": {'
    sh_pkg_runtime_perms "$pkg" "$user" | sed 's/^ *android\.permission\.\([A-Z_0-9]*\): granted=\([a-z]*\).*/    "\1": "\2",/' | sed '$ s/,$//'
    echo '  }'
    echo "}"
  } >"$SH_SNAP/permissions.json"
  sh_shell dumpsys package "$pkg" | sed -n '/runtime permissions:/,/^$/p' >"$SH_SNAP/original_state/runtime-perms.txt" 2>&1
}

sh_snap_appops() {  # <pkg> <uid>
  sh_appops_get "$1" >"$SH_SNAP/original_state/appops.txt" 2>&1
  sh_appops_get --uid "${2:-0}" >"$SH_SNAP/original_state/appops-uid.txt" 2>&1
  {
    echo "{"
    echo '  "pkg": "'"$(SH_SNAP_JSON_ESC "$1")"'",'
    echo '  "uid": "'"$2"'",'
    echo '  "raw_file": "original_state/appops.txt"'
    echo "}"
  } >"$SH_SNAP/appops.json"
}

sh_snap_network() {  # <uid>
  sh_net_blacklist_list >"$SH_SNAP/original_state/netpolicy-blacklist.txt" 2>&1
  sh_net_policy >"$SH_SNAP/original_state/netpolicy-state.txt" 2>&1
  sh_net_sample "$SH_SNAP/original_state/netstats-t0.txt" >/dev/null
  {
    echo "{"
    echo '  "uid": "'"$1"'",'
    echo '  "blacklisted": '$(sh_net_blacklisted "$1" && echo true || echo false)','
    echo '  "t0_sample": "original_state/netstats-t0.txt",'
    echo '  "t0_bytes": "'"$(sh_net_uid_bytes "$SH_SNAP/original_state/netstats-t0.txt" "$1")"'"'
    echo "}"
  } >"$SH_SNAP/network.json"
}

sh_snap_after() {  # <pkg> <user> <uid>
  local pkg="$1" user="$2" uid="$3"
  sh_shell dumpsys package "$pkg" >"$SH_SNAP/after_state/dumpsys-package.txt" 2>&1
  sh_appops_get "$pkg" >"$SH_SNAP/after_state/appops.txt" 2>&1
  sh_net_blacklist_list >"$SH_SNAP/after_state/netpolicy-blacklist.txt" 2>&1
  sh_net_sample "$SH_SNAP/after_state/netstats-t1.txt" >/dev/null
  sh_proc_list "$pkg" >"$SH_SNAP/after_state/processes.txt" 2>&1
  sh_alarm_refs "$pkg" >"$SH_SNAP/after_state/alarm-refs.txt" 2>&1
}
