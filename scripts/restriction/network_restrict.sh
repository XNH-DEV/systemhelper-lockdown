#!/usr/bin/env bash
# network_restrict.sh — L3 网络限制（v2.1 §四 4.4 网络层）
#
# 本机能做到的与做不到的，必须说清楚：
#   * 能做：cmd netpolicy add restrict-background-blacklist <uid>
#     生效证据 = cmd netpolicy list restrict-background-blacklist 含该 uid，
#     且 dumpsys netpolicy 出现 policy=1 (REJECT_METERED_BACKGROUND) /
#     blocked_state={blocked=APP_BACKGROUND|METERED_USER_RESTRICTED}
#     拦截发生在 netd 的 iptables 链上，跟 App 内开关/是否崩无关（README §4.4）
#   * 做不到：per-uid 全断网。前台流量这条无 root 手段管不了（README §4.6 的 MIUI
#     「联网控制」要手点，脚本不碰；DNS 黑洞属于可选补刀层，见 README §4.7）
#
# 口径提醒：这一层是"后台限制"，不是"断网"。判定里绝不写成"已彻底断网"。
#
# 用法：
#   bash network_restrict.sh [--pkg PKG] [--user N] [--uid N] [--remove] [--serial S] [--dry-run]
set -uo pipefail

SH_RDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SH_CORE_LIB="$(cd "$SH_RDIR/../lib" && pwd)"
SH_RLIB="$SH_RDIR/lib"
if [ -z "${SH_LIBS_READY:-}" ]; then
  SH_LIBS_READY=1
  for SH__f in "$SH_CORE_LIB/common.sh" "$SH_CORE_LIB/adb.sh" "$SH_CORE_LIB/package.sh" \
               "$SH_RLIB/package_state.sh" "$SH_RLIB/user_manager.sh" "$SH_RLIB/safety_guard.sh" \
               "$SH_RLIB/snapshot.sh" "$SH_RLIB/verification.sh"; do
    [ -f "$SH__f" ] && . "$SH__f"
  done
fi

DEFAULT_PKG="com.mobiletools.systemhelper"

# ---------------------------------------------------------------------------
# 加入后台黑名单
# ---------------------------------------------------------------------------
net_add_uid() {  # <uid>
  local uid="${1:-}" out
  if [ -z "$uid" ]; then
    sh_state "net:blacklist" FAILED "UID 为空，无法加黑名单"
    return 0
  fi
  if pst_netpolicy_has_uid "$uid"; then
    # 本来就在黑名单 = 不是本项目改的 → 不写台账（否则 restore 会把它当成我们的变更）
    sh_state "net:blacklist" SKIPPED "UID $uid 已在 restrict-background-blacklist（幂等，不重复写）"
    return 0
  fi

  out="$(sg_shell cmd netpolicy add restrict-background-blacklist "$uid")"
  if [ "${SH_DRY_RUN:-0}" = 1 ]; then
    sh_state "net:blacklist" SKIPPED "dry-run：未执行 cmd netpolicy add"
    return 0
  fi
  case "$out" in
    *Exception*|*"Error"*|*"Failure"*|*"Unknown"*)
      sh_state "net:blacklist" FAILED "系统拒绝：$out"
      return 0
      ;;
  esac

  if pst_netpolicy_has_uid "$uid"; then
    sh_state "net:blacklist" SUCCESS "UID $uid 已在 restrict-background-blacklist（后台流量被 netd 拒）"
    snap_changed netpolicy "$uid" add
  else
    sh_state "net:blacklist" FAILED "回读未见 UID $uid（命令无报错但未生效）"
  fi
  sh_log "  netpolicy: $(pst_netpolicy_policy)"
  return 0
}

# ---------------------------------------------------------------------------
# 移出后台黑名单（第六等级恢复用）
# ---------------------------------------------------------------------------
net_remove_uid() {  # <uid>
  local uid="${1:-}" out
  if [ -z "$uid" ]; then
    sh_state "net:unblacklist" FAILED "UID 为空，无法移出黑名单"
    return 0
  fi
  if ! pst_netpolicy_has_uid "$uid"; then
    sh_state "net:unblacklist" SKIPPED "UID $uid 本来就不在黑名单（幂等）"
    return 0
  fi

  out="$(sg_shell cmd netpolicy remove restrict-background-blacklist "$uid")"
  if [ "${SH_DRY_RUN:-0}" = 1 ]; then
    sh_state "net:unblacklist" SKIPPED "dry-run：未执行 cmd netpolicy remove"
    return 0
  fi
  case "$out" in
    *Exception*|*"Error"*|*"Failure"*|*"Unknown"*)
      sh_state "net:unblacklist" FAILED "系统拒绝：$out"
      return 0
      ;;
  esac

  if pst_netpolicy_has_uid "$uid"; then
    sh_state "net:unblacklist" FAILED "回读仍在黑名单里（UID $uid）"
  else
    sh_state "net:unblacklist" SUCCESS "UID $uid 已移出黑名单"
  fi
  return 0
}

# ---------------------------------------------------------------------------
main() {
  local pkg="${PKG:-$DEFAULT_PKG}" user="${USER_ID:-}" uid="" remove=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --pkg)     pkg="${2:-}"; shift 2 ;;
      --user)    user="${2:-}"; shift 2 ;;
      --uid)     uid="${2:-}"; shift 2 ;;
      --serial)  SH_SERIAL="${2:-}"; shift 2 ;;
      --remove)  remove=1; shift ;;
      --dry-run) SH_DRY_RUN=1; shift ;;
      -h|--help)
        printf '%s\n' "用法: bash network_restrict.sh [--pkg PKG] [--user N] [--uid N] [--remove] [--serial S] [--dry-run]"
        printf '%s\n' "L3 = cmd netpolicy add restrict-background-blacklist UID（只限后台流量，不是全断网）"
        return 0
        ;;
      *) sh_err "未知参数: $1"; return 2 ;;
    esac
  done

  guard_device
  guard_target_pkg "$pkg"
  user="$(um_resolve_user "$user")"
  [ -n "$uid" ] || uid="$(pst_uid "$pkg")"
  if [ -z "$uid" ]; then
    sh_err "拿不到 $pkg 的 UID，无法设置 UID 级网络策略"
    return 4
  fi
  sh_log "  L3 目标：$pkg  user=$user  uid=$uid"
  snap_ensure "$pkg" "$user"

  if [ "$remove" = 1 ]; then
    net_remove_uid "$uid"
  else
    net_add_uid "$uid"
  fi

  if [ "${SH_DRY_RUN:-0}" != 1 ]; then
    ver_network_layer "$uid"
  fi
  sh_summary
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
