#!/usr/bin/env bash
# tests/mock_adb.sh — 离线假 adb（只给测试用，永远不连真机）
#
# 拦截范围：
#   adb [-s SERIAL] devices | get-state | shell <cmd...> | exec-out <cmd...>
#   adb version / start-server / kill-server / wait-for-device / root
#
# 环境变量：
#   MOCK_SCENARIO   场景名（见 init_state 的 case）
#   MOCK_FIXTURES   夹具目录，默认 <脚本目录>/fixtures
#   MOCK_STATE_DIR  状态目录：跨多次调用持久（suspend 之后 dumpsys 必须跟着变）
#   MOCK_LOG        调用记录文件；每条调用一行，供断言"没发写命令"
#
# 夹具派生自 HyperOS 4.0 真机 dump（logs/2026-11-07_003534/raw）。
# 真机行为要点：pm list packages 恒 rc=0 零输出；pm uninstall 回 only root can delete
# system app；pm disable-user 回 SecurityException + rc=255。
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FX="${MOCK_FIXTURES:-$SELF_DIR/fixtures}"
SCEN="${MOCK_SCENARIO:-normal}"
STATE_DIR="${MOCK_STATE_DIR:-${TMPDIR:-/tmp}/mock_adb_state}"
PKG_DEFAULT="com.mobiletools.systemhelper"
TRACKED_OPS="RUN_IN_BACKGROUND RUN_ANY_IN_BACKGROUND START_FOREGROUND WAKE_LOCK GET_USAGE_STATS ACTIVATE_VPN POST_NOTIFICATION SYSTEM_ALERT_WINDOW SCHEDULE_EXACT_ALARM"
TRACKED_PERMS="READ_PHONE_STATE READ_EXTERNAL_STORAGE ACCESS_FINE_LOCATION ACCESS_COARSE_LOCATION ACCESS_BACKGROUND_LOCATION BLUETOOTH_CONNECT ACCESS_LOCAL_NETWORK"

if [ -n "${MOCK_LOG:-}" ]; then
  printf '%s\n' "$*" >>"$MOCK_LOG"
fi

# ---------- 夹具/状态基础 ----------
fx() {
  [ -f "$FX/$1" ] && cat "$FX/$1"
  return 0
}

state_get() {
  local v=""
  if [ -f "$STATE_DIR/$1" ]; then
    IFS= read -r v <"$STATE_DIR/$1" || true
  fi
  if [ -z "$v" ]; then v="${2-}"; fi
  printf '%s' "$v"
}

state_set() {
  printf '%s' "$2" >"$STATE_DIR/$1"
}

# fork-free 读状态：st <key> [默认值] → 结果在 $SV（不走子 shell）
st() {
  SV="${2-}"
  if [ -f "$STATE_DIR/$1" ]; then
    IFS= read -r SV <"$STATE_DIR/$1" || true
  fi
}

# 0/1 → true/false（只 fork 一次，别在调用点套两层）
state_bool() {
  local v=""
  if [ -f "$STATE_DIR/$1" ]; then
    IFS= read -r v <"$STATE_DIR/$1" || true
  fi
  if [ -z "$v" ]; then v="${2-0}"; fi
  if [ "$v" = "1" ]; then
    printf 'true'
  else
    printf 'false'
  fi
}

# 就地改文件（不用 sed -i：macOS/BSD 的 -i 语义不同）
sed_apply() {
  local f="$1"
  shift
  sed "$@" "$f" >"$f.n"
  mv "$f.n" "$f"
}

init_state() {
  local installed=1 suspended=0 stopped=true enabled=0 running=1 distraction=2
  local dump_shape=base multi_user=0 user999=0 uid_mode=normal alarm_mode=ok
  local traffic_mode=static netpolicy_uid="" appops_base=default apk_missing=0
  local uninstall_mode=deny disable_mode=deny suspend_mode=ok grant_mode=ok
  local appops_set_mode=ok install_existing=ok device_admin=0 listed=1

  case "$SCEN" in
    uninstalled) installed=0 dump_shape=uninstalled running=0 listed=0 ;;
    disabled) enabled=3 dump_shape=disabled ;;
    uninstall_ok) uninstall_mode=allow ;;
    uninstall_unsupported) uninstall_mode=unsupported ;;
    no_apk) apk_missing=1 ;;
    pkg_missing) apk_missing=1 dump_shape=empty listed=0 ;;
    users_multi) multi_user=1 ;;
    device_admin_blocked) device_admin=1 uninstall_mode=policy ;;
    partial_fail) grant_mode=fail appops_set_mode=fail suspend_mode=fail ;;
    uid_unavailable) uid_mode=unavailable ;;
    shared_uid) dump_shape=shared ;;
    install_existing_unsupported) install_existing=unsupported ;;
    deny_suspend) suspend_mode=fail ;;
    deny_disable) disable_mode=deny ;;
  esac

  [ -f "$STATE_DIR/.init" ] && return 0
  local k v
  while read -r k v; do
    [ -n "$k" ] || continue
    [ -f "$STATE_DIR/$k" ] || printf '%s' "$v" >"$STATE_DIR/$k"
  done <<EOF
installed $installed
suspended $suspended
stopped $stopped
enabled $enabled
running $running
distraction $distraction
dump_shape $dump_shape
multi_user $multi_user
user999_installed $user999
uid_mode $uid_mode
alarm_mode $alarm_mode
traffic_mode $traffic_mode
netpolicy_uid $netpolicy_uid
appops_base $appops_base
apk_missing $apk_missing
uninstall_mode $uninstall_mode
disable_mode $disable_mode
suspend_mode $suspend_mode
grant_mode $grant_mode
appops_set_mode $appops_set_mode
install_existing $install_existing
device_admin $device_admin
listed $listed
EOF
  : >"$STATE_DIR/.init"
}

# ---------- 设备输出生成 ----------

# 把用户段里的字段替换成状态值（只动带 installed= 的那一行）
pkg_dump() {
  local shape base inst susp stopped en distr multi u999 tmp perm g f
  st dump_shape base
  shape="$SV"
  case "$shape" in
    empty) return 0 ;;
    uninstalled) base="$FX/pkg_uninstalled.txt" ;;
    disabled) base="$FX/pkg_disabled.txt" ;;
    partial) base="$FX/pkg_system_partial.txt" ;;
    shared) base="$FX/pkg_shared_uid.txt" ;;
    *) base="$FX/pkg_system.txt" ;;
  esac
  [ -f "$base" ] || return 0
  st installed 1
  if [ "$SV" = "1" ]; then inst=true; else inst=false; fi
  st suspended 0
  if [ "$SV" = "1" ]; then susp=true; else susp=false; fi
  st stopped true
  stopped="$SV"
  st enabled 0
  en="$SV"
  st distraction 2
  distr="$SV"
  st multi_user 0
  multi="$SV"
  st user999_installed 0
  if [ "$SV" = "1" ]; then u999=true; else u999=false; fi

  tmp="$STATE_DIR/dump.$$"
  awk -v inst="$inst" -v susp="$susp" -v stopped="$stopped" -v en="$en" \
    -v distr="$distr" -v multi="$multi" -v u999="$u999" '
    /^    User 0:/ && /installed=/ {
      gsub(/installed=[a-z]+/, "installed=" inst)
      gsub(/suspended=[a-z]+/, "suspended=" susp)
      gsub(/stopped=[a-z]+/, "stopped=" stopped)
      gsub(/enabled=[0-9]+/, "enabled=" en)
      gsub(/distractionFlags=[0-9]+/, "distractionFlags=" distr)
      print
      if (multi == 1) {
        printf "    User 999: ceDataInode=0 deDataInode=0 pccCeDataInode=0 pccDeDataInode=0 installed=%s hidden=false suspended=false appLockEnabled=false distractionFlags=0 stopped=false notLaunched=false enabled=0 instant=false virtual=false quarantined=false\n", u999
      }
      next
    }
    { print }
  ' "$base" >"$tmp"

  # 运行时权限：按状态改写 granted= 与 flags（模拟 revoke / grant / USER_FIXED）
  # 所有表达式写进一个 sed 脚本，只 fork 一次
  : >"$tmp.sed"
  for perm in $TRACKED_PERMS; do
    g=""
    f=""
    st "perm_granted_$perm" ''
    g="$SV"
    st "perm_fixed_$perm" ''
    f="$SV"
    if [ -n "$g" ]; then
      printf 's#\\(android\\.permission\\.%s: granted=\\)[a-z]*#\\1%s#\n' "$perm" "$g" >>"$tmp.sed"
    fi
    if [ -n "$f" ]; then
      printf 's#\\(android\\.permission\\.%s: granted=[a-z]*\\), flags=\\[ *#\\1, flags=[ USER_SET|USER_FIXED #\n' "$perm" >>"$tmp.sed"
    fi
  done
  if [ -s "$tmp.sed" ]; then
    sed -f "$tmp.sed" "$tmp" >"$tmp.n"
    mv "$tmp.n" "$tmp"
  fi
  rm -f "$tmp.sed"

  cat "$tmp"
  rm -f "$tmp"
}

appops_out() {
  local f tmp op m
  f="$FX/appops_default.txt"
  st appops_base default
  if [ "$SV" = "ignore" ]; then f="$FX/appops_ignore.txt"; fi
  [ -f "$f" ] || return 0
  tmp="$STATE_DIR/appops.$$"
  cp "$f" "$tmp"
  : >"$tmp.sed"
  for op in $TRACKED_OPS; do
    st "op_$op" default
    m="$SV"
    if grep -q "^$op:" "$tmp"; then
      printf 's#^%s:.*#%s: %s#\n' "$op" "$op" "$m" >>"$tmp.sed"
    elif [ "$m" != "default" ]; then
      printf '%s: %s\n' "$op" "$m" >>"$tmp"
    fi
  done
  if [ -s "$tmp.sed" ]; then
    sed -f "$tmp.sed" "$tmp" >"$tmp.n"
    mv "$tmp.n" "$tmp"
  fi
  rm -f "$tmp.sed"
  cat "$tmp"
  rm -f "$tmp"
}

netpolicy_out() {
  local base extra
  base="$(cat "$FX/netpolicy.txt")"
  extra="$(state_get netpolicy_uid '')"
  if [ -n "$extra" ]; then
    printf '%s %s \n' "$base" "$extra"
  else
    printf '%s\n' "$base"
  fi
}

ps_out() {
  if [ "$(state_get running 1)" = "1" ]; then
    fx ps_running.txt
  else
    fx ps_stopped.txt
  fi
}

traffic_out() {
  local n
  n="$(state_get traffic_calls 0)"
  n=$((n + 1))
  state_set traffic_calls "$n"
  if [ "$(state_get traffic_mode static)" = "grow" ] && [ "$n" -ge 2 ]; then
    fx netstats_t1.txt
  else
    fx netstats_t0.txt
  fi
}

user_arg() {
  local u
  u="$(printf '%s' "$1" | sed -n 's/.*--user[ =]\([0-9][0-9]*\).*/\1/p')"
  printf '%s' "${u:-0}"
}

perm_of() {
  local rest
  case "$1" in
    *android.permission.*)
      rest="${1#*android.permission.}"
      printf '%s' "${rest%% *}"
      ;;
    *) printf '' ;;
  esac
}

installed_for() {
  local u="$1"
  case "$u" in
    0) [ "$(state_get installed 1)" = "1" ] ;;
    *) [ "$(state_get "user${u}_installed" 0)" = "1" ] ;;
  esac
}

# ---------- 单个设备命令 ----------
dev_single() {
  local c="$1" pkg op mode tmp perm
  case "$c" in
    "")
      return 0
      ;;
    "pm path "* | "pm path")
      pkg="${c#pm path}"
      pkg="${pkg# }"
      [ -z "$pkg" ] && return 0
      [ "$(state_get apk_missing 0)" = "1" ] && return 0
      fx pm_path_system.txt
      return 0
      ;;
    "pm list packages"*)
      # HyperOS 4.0 实测：rc=0 但零输出
      fx pm_list_empty.txt
      return 0
      ;;
    "pm list users"*)
      if [ "$(state_get multi_user 0)" = "1" ]; then
        fx users_multi.txt
      else
        fx users_single.txt
      fi
      return 0
      ;;
    "pm uninstall"* | "cmd package uninstall"*)
      case "$(state_get uninstall_mode deny)" in
        allow)
          if [ "$(state_get installed 1)" = "0" ]; then
            printf 'Failure [not installed for 0]\n'
            return 1
          fi
          state_set installed 0
          state_set dump_shape uninstalled
          state_set running 0
          state_set stopped false
          printf 'Success\n'
          return 0
          ;;
        unsupported)
          printf 'Error: java.lang.IllegalArgumentException: Unknown command: uninstall\n'
          return 1
          ;;
        policy)
          printf 'Failure [DELETE_FAILED_DEVICE_POLICY_MANAGER]\n'
          return 1
          ;;
        *)
          fx fail_only_root.txt
          return 1
          ;;
      esac
      ;;
    "cmd package install-existing"* | "pm install-existing"*)
      if [ "$(state_get install_existing ok)" = "unsupported" ]; then
        fx install_existing_unsupported.txt
        return 1
      fi
      state_set installed 1
      state_set dump_shape base
      printf 'Package %s installed for user: 0\n' "$PKG_DEFAULT"
      return 0
      ;;
    "pm disable-user"* | "pm disable "* | "pm disable")
      if [ "$(state_get disable_mode deny)" = "deny" ]; then
        fx fail_cannot_disable.txt
        return 255
      fi
      state_set enabled 3
      state_set dump_shape disabled
      return 0
      ;;
    "pm enable"*)
      state_set enabled 0
      state_set dump_shape base
      return 0
      ;;
    "pm hide"*)
      printf 'java.lang.SecurityException: Access denied, requires: android.permission.MANAGE_USERS\n'
      return 255
      ;;
    "pm suspend"*)
      if [ "$(state_get suspend_mode ok)" != "ok" ]; then
        printf 'Exception occurred while executing suspend: java.lang.SecurityException: Shell cannot change component state\n'
        return 1
      fi
      state_set suspended 1
      state_set stopped true
      state_set running 0
      printf 'Package %s new suspended state: true\n' "$PKG_DEFAULT"
      return 0
      ;;
    "pm unsuspend"*)
      state_set suspended 0
      state_set running 0
      printf 'Package %s new suspended state: false\n' "$PKG_DEFAULT"
      return 0
      ;;
    "pm set-permission-flags"*)
      perm="$(perm_of "$c")"
      [ -n "$perm" ] && state_set "perm_fixed_$perm" 1
      return 0
      ;;
    "pm clear-permission-flags"*)
      perm="$(perm_of "$c")"
      [ -n "$perm" ] && state_set "perm_fixed_$perm" ''
      return 0
      ;;
    "pm clear --user "* | "pm clear "*)
      state_set cleared 1
      state_set suspended 0
      state_set running 0
      printf 'Success\n'
      return 0
      ;;
    "pm grant"*)
      perm="$(perm_of "$c")"
      if [ "$(state_get grant_mode ok)" != "ok" ]; then
        printf 'Operation not allowed: java.lang.SecurityException: Permission is not a changeable permission type\n'
        return 255
      fi
      [ -n "$perm" ] && state_set "perm_granted_$perm" true
      return 0
      ;;
    "pm revoke"*)
      perm="$(perm_of "$c")"
      [ -n "$perm" ] && state_set "perm_granted_$perm" false
      return 0
      ;;
    "pm set-distracting-restriction"*)
      case "$c" in
        *hide-notifications* | *hide-from-suggestions*) state_set distraction 2 ;;
        *) state_set distraction 0 ;;
      esac
      return 0
      ;;
    "pm dump"* | "cmd package dump"*)
      pkg_dump
      return 0
      ;;
    "cmd package list packages -U "*)
      if [ "$(state_get uid_mode normal)" = "unavailable" ]; then
        return 0
      fi
      printf 'package:%s uid:10100\n' "$PKG_DEFAULT"
      return 0
      ;;
    "cmd package list packages --user "*)
      if installed_for "$(user_arg "$c")"; then
        printf 'package:%s\n' "$PKG_DEFAULT"
      fi
      return 0
      ;;
    "cmd package list packages"*)
      if [ "$(state_get listed 1)" = "1" ]; then
        printf 'package:%s\n' "$PKG_DEFAULT"
      fi
      return 0
      ;;
    "cmd package resolve-activity"* | "cmd package query-activities"*)
      return 0
      ;;
    "cmd appops get"*)
      appops_out
      return 0
      ;;
    "cmd appops set"*)
      if [ "$(state_get appops_set_mode ok)" != "ok" ]; then
        printf 'Error: java.lang.SecurityException: uid 10100 does not have MANAGE_APP_OPS_MODES\n'
        return 255
      fi
      mode="${c##* }"
      tmp="${c% *}"
      op="${tmp##* }"
      state_set "op_$op" "$mode"
      return 0
      ;;
    "cmd netpolicy list"*)
      netpolicy_out
      return 0
      ;;
    "cmd netpolicy add"*)
      state_set netpolicy_uid "$(printf '%s' "${c##* }" | tr -dc '0-9')"
      return 0
      ;;
    "cmd netpolicy remove"*)
      state_set netpolicy_uid ""
      return 0
      ;;
    "cmd netpolicy"*)
      return 0
      ;;
    "dumpsys package "* | "dumpsys package")
      pkg_dump
      return 0
      ;;
    "dumpsys alarm"*)
      if [ "$(state_get alarm_mode ok)" = "ok" ]; then
        fx alarm_restricted.txt
      else
        fx alarm_empty.txt
      fi
      return 0
      ;;
    "dumpsys netstats"*)
      traffic_out
      return 0
      ;;
    "dumpsys netpolicy"*)
      printf '  mRestrictBackground=false\n  restrict_background=false\n'
      return 0
      ;;
    "dumpsys device_policy"*)
      if [ "$(state_get device_admin 0)" = "1" ]; then
        fx device_admin.txt
      else
        printf 'Device Policy Manager State:\n  mHasFeature=true\n  Active Admins:\n'
      fi
      return 0
      ;;
    "dumpsys activity"*)
      fx services.txt
      return 0
      ;;
    "dumpsys"*)
      printf 'DUMP OF SERVICE\n'
      return 0
      ;;
    "ps -A" | "ps" | "ps -A "* | "ps "*)
      ps_out
      return 0
      ;;
    "am get-current-user"*)
      printf '0\n'
      return 0
      ;;
    "am get-standby-bucket"*)
      fx standby.txt
      return 0
      ;;
    "am set-inactive"* | "am set-standby-bucket"* | "am force-stop"* | "am kill"*)
      return 0
      ;;
    "getprop ro.product.model")
      printf 'TEST-MODEL\n'
      return 0
      ;;
    "getprop ro.build.version.incremental")
      printf 'HyperOS 4.0\n'
      return 0
      ;;
    "getprop ro.mi.os.version.name")
      printf 'OS4.0\n'
      return 0
      ;;
    "getprop ro.system.build.version.sdk")
      printf '36\n'
      return 0
      ;;
    "getprop ro.build.version.sdk" | "getprop ro.build.version.release")
      # 真机这两项经 adb 取不到，保持空（README §3 坑）
      return 0
      ;;
    "getprop ro.debuggable")
      printf '0\n'
      return 0
      ;;
    "getprop"*)
      return 0
      ;;
    "sha256sum "*)
      printf 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855  %s\n' "${c#sha256sum }"
      return 0
      ;;
    "settings get"*)
      return 0
      ;;
    "logcat"*)
      return 0
      ;;
    "id")
      printf 'uid=2000(shell) gid=2000(shell) groups=2000(shell)\n'
      return 0
      ;;
    "whoami")
      printf 'shell\n'
      return 0
      ;;
    "input"* | "wm size"* | "screencap"* | "service call"*)
      return 0
      ;;
    *)
      if [ -n "${MOCK_LOG:-}" ]; then
        printf 'UNHANDLED: %s\n' "$c" >>"$MOCK_LOG"
      fi
      return 0
      ;;
  esac
}

dev_pipeline() {
  local norm="$1" head rest out rc
  head="${norm%%|*}"
  rest="${norm#*|}"
  out="$(dev_single "$head")"
  rc=$?
  if [ "$rest" = "$norm" ]; then
    printf '%s\n' "$out"
    return "$rc"
  fi
  printf '%s\n' "$out" | bash -c "$rest"
}

dispatch() {
  local norm="" w
  set -f
  # shellcheck disable=SC2086
  for w in $1; do
    norm="$norm $w"
  done
  set +f
  norm="${norm# }"
  case "$norm" in
    *"|"*)
      dev_pipeline "$norm"
      return $?
      ;;
    *)
      dev_single "$norm"
      return $?
      ;;
  esac
}

cmd_devices() {
  case "$SCEN" in
    no_device)
      printf 'List of devices attached\n\n'
      ;;
    multi_device)
      printf 'List of devices attached\nZZTEST0001\tdevice\nZZTEST0002\tdevice\n'
      ;;
    *)
      printf 'List of devices attached\nZZTEST0001\tdevice\n'
      ;;
  esac
  return 0
}

cmd_get_state() {
  local serial="$1"
  case "$SCEN" in
    no_device)
      printf "error: device '%s' not found\n" "${serial:-ZZTEST0001}"
      return 1
      ;;
    *)
      printf 'device\n'
      return 0
      ;;
  esac
}

main() {
  mkdir -p "$STATE_DIR" 2>/dev/null
  init_state
  local serial=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      -s)
        serial="${2-}"
        shift 2
        ;;
      -s*)
        serial="${1#-s}"
        shift
        ;;
      -d | -e | -H | -P | --exit-on-write-error)
        shift
        ;;
      devices)
        cmd_devices
        return $?
        ;;
      get-state)
        cmd_get_state "$serial"
        return $?
        ;;
      shell | exec-out)
        shift
        dispatch "$*"
        return $?
        ;;
      version)
        printf 'Android Debug Bridge version 1.0.41\n'
        return 0
        ;;
      start-server | kill-server | wait-for-device | root | unroot | remount | tcpip | reconnect)
        return 0
        ;;
      uninstall)
        shift
        dispatch "pm uninstall $*"
        return $?
        ;;
      install)
        printf 'Success\n'
        return 0
        ;;
      pull | push | forward | reverse | logcat | bugreport)
        return 0
        ;;
      *)
        if [ -n "${MOCK_LOG:-}" ]; then
          printf 'UNHANDLED-ADB: %s\n' "$*" >>"$MOCK_LOG"
        fi
        return 0
        ;;
    esac
  done
  return 0
}

main "$@"
