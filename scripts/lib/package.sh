#!/usr/bin/env bash
# lib/package.sh — 包/UID/多用户/组件/依赖查询
# 依赖：common.sh adb.sh
#
# HyperOS 4.0 实测坑：
#   * pm list packages（含 -u/-d）在 shell 下 rc=0 但零输出 → 一律用 cmd package list packages
#   * dumpsys package 的每段用户各一份，必须按 "^    User <id>:" 切段

sh_pkg_exists() {
  sh_shell pm path "$1" 2>/dev/null | grep -q '^package:'
}

sh_pkg_path() {
  sh_shell pm path "$1" 2>/dev/null | sed -n 's/^package://p' | head -1
}

sh_pkg_uid() {
  local pkg="$1" u
  u="$(sh_shell cmd package list packages -U "$pkg" 2>/dev/null | grep -oE 'uid:[0-9]+' | head -1 | tr -dc '0-9')"
  [ -z "$u" ] && u="$(sh_shell dumpsys package "$pkg" 2>/dev/null | grep -m1 -oE 'userId=[0-9]+' | tr -dc '0-9')"
  printf '%s' "$u"
}

# 某用户是否安装
sh_pkg_installed_for() {
  local pkg="$1" uid="${2:-0}"
  sh_shell cmd package list packages --user "$uid" 2>/dev/null | grep -qx "package:$pkg"
}

# 某用户的状态行（installed=/suspended=/stopped=/enabled=）
sh_pkg_user_line() {
  local pkg="$1" uid="${2:-0}"
  sh_shell dumpsys package "$pkg" 2>/dev/null | awk -v u="    User ${uid}:" '
    $0 ~ "^"u { print; exit }'
}

sh_pkg_flag() {  # sh_pkg_flag <pkg> <user> <key>
  local line; line="$(sh_pkg_user_line "$1" "$2")"
  printf '%s' "$line" | grep -oE "$3=[A-Za-z0-9]+" | head -1 | cut -d= -f2
}

sh_pkg_is_system() {
  local p; p="$(sh_pkg_path "$1")"
  case "$p" in
    /system/*|/product/*|/system_ext/*|/vendor/*|/apex/*) return 0 ;;
    *) return 1 ;;
  esac
}

sh_pkg_shared_uid() {
  sh_shell dumpsys package "$1" 2>/dev/null | grep -m1 'sharedUser=' | sed 's/.*sharedUser=//'
}

# 多 split 检测
sh_pkg_splits() {
  sh_shell pm path "$1" 2>/dev/null | grep -c '^package:'
}

# 该包声明的运行时权限实际授予状态（按用户切段）
sh_pkg_runtime_perms() {
  local pkg="$1" uid="${2:-0}"
  sh_shell dumpsys package "$pkg" 2>/dev/null | awk -v u="    User ${uid}:" '
    $0 ~ "^"u { f=1; next }
    /^    User [0-9]+:/ { f=0 }
    f && /runtime permissions:/ { r=1; next }
    f && r && /granted=/ { print }
    f && r && /^$/ { r=0 }
  '
}

sh_pkg_components() {  # 输出 name<TAB>enabled
  sh_shell dumpsys package "$1" 2>/dev/null | sed -n 's/^ *\([0-9a-f]*\) \(com\.[^ ]*\/\.[^ ]*\) filter.*/\2/p' | sort -u
}

sh_pkg_component_state() {
  sh_shell cmd package dump "$1" 2>/dev/null | grep -E "Component\{.*$2" | head -1
}
