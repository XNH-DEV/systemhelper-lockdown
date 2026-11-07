#!/usr/bin/env bash
# lib/adb.sh — 设备选择、shell 封装、多设备保护
# 依赖：common.sh

: "${SERIAL:=}"
: "${SH_SERIAL:=${SERIAL}}"
: "${SH_ADB:=${ADB:-adb}}"
: "${SH_SHELL_TIMEOUT:=30}"

sh_adb()   { if [ -n "$SH_SERIAL" ]; then "$SH_ADB" -s "$SH_SERIAL" "$@"; else "$SH_ADB" "$@"; fi; }
sh_shell() { sh_adb shell "$@" 2>&1 | tr -d '\r'; }

# 有超时的 shell（GNU timeout 可用时）
sh_shell_to() {
  local secs="$1"; shift
  if sh_have timeout; then
    timeout "$secs" "$SH_ADB" ${SH_SERIAL:+-s "$SH_SERIAL"} shell "$@" 2>&1 | tr -d '\r'
  else
    sh_shell "$@"
  fi
}

# 设备选择：未指定且只连一台则自动取；多于一台直接拒绝（prompt 2.1 多设备误操作）
sh_pick_device() {
  local n
  n="$(sh_adb devices | awk 'NR>1 && $2=="device"{c++} END{print c+0}')"
  if [ -z "$SH_SERIAL" ]; then
    if [ "$n" -eq 0 ]; then sh_die "没有可用设备（adb devices 无 device 行）" 4; fi
    if [ "$n" -gt 1 ]; then
      sh_err "检测到 $n 台设备，必须用 SERIAL= 或 --serial 指定："
      sh_adb devices | sed 's/^/    /' >&2
      exit 4
    fi
    SH_SERIAL="$(sh_adb devices | awk 'NR>1 && $2=="device"{print $1; exit}')"
    sh_info "自动选择设备: $SH_SERIAL"
  fi
  local st; st="$(sh_adb -s "$SH_SERIAL" get-state 2>/dev/null | tr -d '\r')"
  [ "$st" = "device" ] || sh_die "设备 $SH_SERIAL 状态=${st:-unknown}" 4
}

# HyperOS 上 sdk/release 的 getprop 无输出，只有这几个可靠
sh_device_facts() {
  local m rom rel
  m="$(sh_shell getprop ro.product.model)"
  rom="$(sh_shell getprop ro.build.version.incremental)"
  rel="$(sh_shell getprop ro.mi.os.version.name)"
  printf 'model=%s\nrom=%s\nos=%s\napi=%s\nserial=%s\n' \
    "$m" "$rom" "${rel:-unknown}" "$(sh_shell getprop ro.build.version.sdk)" "$SH_SERIAL"
}

sh_current_user() {
  local u; u="$(sh_shell am get-current-user)"
  case "$u" in ''|*[!0-9]*) printf '0' ;; *) printf '%s' "$u" ;; esac
}

sh_users() {
  sh_shell pm list users | sed -n 's/.*UserInfo{\([0-9]*\):\([^:]*\):\([^}]*\)}.*/\1\t\2/p'
}
