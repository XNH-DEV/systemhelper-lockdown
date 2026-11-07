#!/usr/bin/env bash
# lib/user_manager.sh — 多用户解析（v2.1 §六 6.2：所有写操作带 --user，绝不硬编码 user 0）
# 依赖：common.sh adb.sh package_state.sh
#
# 真机事实：本机有 User 0 与 User 999（双开/工作资料）。
#   * dumpsys package 每个用户各一段，读错段会把 User 999 的默认值当成 User 0（CHANGELOG v2.1）
#   * AppOps / 权限 / 卸载都有 --user 语义；netpolicy 是 UID 级（UID 本身含用户信息）
#   * dumpsys alarm 里写成 u<user>a<appid>，appid = uid - 10000（uid ≥ 10000 时）
set -uo pipefail

um_current_user() {
  local u
  u="$(sh_shell am get-current-user 2>/dev/null | tr -d '[:space:]')"
  case "$u" in
    ''|*[!0-9]*) printf '0' ;;
    *) printf '%s' "$u" ;;
  esac
}

# 输出 "id<TAB>名字"，每行一个用户
um_users() {
  sh_shell pm list users 2>/dev/null \
    | sed -n 's/.*UserInfo{\([0-9]*\):\([^:]*\):.*/\1\t\2/p'
}

um_user_exists() {
  um_users | awk -F'\t' -v id="${1:-}" '$1 == id { f = 1 } END { exit(f ? 0 : 1) }'
}

um_user_name() {  # <id>
  local n
  n="$(um_users | awk -F'\t' -v id="${1:-}" '$1 == id { print $2; exit }')"
  printf '%s' "${n:-?}"
}

# 解析目标用户：空 → 取当前用户（并在多用户设备上明确提示没有硬编码 0）
um_resolve_user() {
  local want="${1:-}" cur n
  cur="$(um_current_user)"
  if [ -z "$want" ]; then
    n="$(um_users | wc -l | tr -d '[:space:]')"
    if [ "${n:-0}" -gt 1 ]; then
      sh_warn "多用户设备（$n 个用户）：未指定 --user，取当前用户 $cur；写操作请显式 --user（v2.1 §六 6.2）"
    fi
    printf '%s' "$cur"
    return 0
  fi
  case "$want" in
    *[!0-9]*) sh_die "USER_ID 必须是数字，收到：$want" 2 ;;
  esac
  if [ "$want" != "$cur" ] && ! um_user_exists "$want"; then
    sh_die "用户 $want 不存在（pm list users 无该行）" 4
  fi
  printf '%s' "$want"
}

# uid → appid（dumpsys alarm 用 u<user>a<appid> 记账）
um_appid() {
  local u="${1:-0}"
  case "$u" in
    ''|*[!0-9]*) printf '0' ;;
    *) if [ "$u" -ge 10000 ]; then printf '%s' $((u - 10000)); else printf '%s' "$u"; fi ;;
  esac
}

um_alarm_tag() {  # <user> <uid> → u0a10100
  printf 'u%sa%s' "${1:-0}" "$(um_appid "${2:-0}")"
}

# 目标用户下确实装有该包吗（cmd package，不用 pm list packages）
um_app_installed_for() {  # <pkg> <user>
  pst_installed "${1:-}" "${2:-0}"
}

um_user_summary() {
  um_users | awk -F'\t' '{ printf "  user %s = %s\n", $1, $2 }'
}

# 打印全部用户（audit / plan 用），不参与判定
um_show_users() {
  local cur
  cur="$(um_current_user)"
  sh_log "  用户列表（当前 $cur）："
  um_user_summary
}
