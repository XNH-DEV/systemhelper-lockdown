#!/usr/bin/env bash
# lib/appops.sh — AppOps 读写（v2.1 第三等级 / 执行层）
# 依赖：common.sh adb.sh

# 我们的目标 op 集合（按"机制"分组，不混成一个总开关 —— v2.1 明确禁止笼统开关）
SH_OP_EXEC="RUN_IN_BACKGROUND RUN_ANY_IN_BACKGROUND START_FOREGROUND WAKE_LOCK"
SH_OP_CLOCK="SCHEDULE_EXACT_ALARM"
SH_OP_NET="ACTIVATE_VPN"
SH_OP_NOTIFY="POST_NOTIFICATION"
SH_OP_PRIV="GET_USAGE_STATS SYSTEM_ALERT_WINDOW"

sh_appops_get() {  # <pkg 或 --uid UID>
  if [ "$1" = "--uid" ]; then
    sh_shell cmd appops get --uid "$2"
  else
    sh_shell cmd appops get "$1"
  fi
}

sh_appops_value() {  # <pkg> <OP>
  sh_shell cmd appops get "$1" 2>/dev/null | grep -E "^$2:" | head -1 | sed 's/.*: //;s/;.*//'
}

sh_appops_set() {  # <pkg> <OP> <ignore|default|allow> [--uid UID]
  local pkg="$1" op="$2" val="$3" uid="${4:-}"
  local out
  if [ -n "$uid" ]; then
    out="$(sh_shell cmd appops set --uid "$uid" "$op" "$val")"
  else
    out="$(sh_shell cmd appops set "$pkg" "$op" "$val")"
  fi
  case "$out" in
    ""|*"No such op"*) [ -z "$out" ] && return 0 || { printf '%s' "$out"; return 1; } ;;
    *) printf '%s' "$out"; return 1 ;;
  esac
}

# 设完必须回读（v2.1：不能只看命令返回）
sh_appops_verify() {  # <pkg> <OP> <expected>
  local v; v="$(sh_appops_value "$1" "$2")"
  [ "$v" = "$3" ]
}

sh_appops_apply_group() {  # <pkg> <uid> <ignore|default> <"OP OP ...">
  local pkg="$1" uid="$2" val="$3" ops="$4" op
  for op in $ops; do
    if [ "$val" = "ignore" ]; then
      sh_appops_set "$pkg" "$op" "$val" "$uid" >/dev/null 2>&1
    else
      sh_appops_set "$pkg" "$op" "$val" >/dev/null 2>&1
    fi
    if sh_appops_verify "$pkg" "$op" "$val"; then
      sh_state "appops:$op" SUCCESS "$val"
    else
      # UID 级设置回读可能显示在别的段落，宁可报 UNKNOWN 也不报成功
      sh_state "appops:$op" UNKNOWN "回读=$(sh_appops_value "$pkg" "$op")"
    fi
  done
}
