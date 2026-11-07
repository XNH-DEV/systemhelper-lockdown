#!/usr/bin/env bash
# background_restrict.sh — L2 后台执行限制（v2.1 §四 4.1 执行层 / §四 4.2 时钟层）
#
# 本机实测：AppOps / am set-inactive / am force-stop 这三类接口是通的。
#   * cmd appops set --uid <uid> <OP> ignore → 回读 ignore（README §4.1 生效证据）
#   * 分组按"机制"打，不混成一个总开关（v2.1 明确禁止笼统开关）：
#       执行 RUN_IN_BACKGROUND / RUN_ANY_IN_BACKGROUND / START_FOREGROUND / WAKE_LOCK
#       时钟 SCHEDULE_EXACT_ALARM（它挂的 5 个 *walarm* 会以 exact_alarm_permission_revoked 掉线）
#       网络 ACTIVATE_VPN
#       通知 POST_NOTIFICATION
#       隐私 GET_USAGE_STATS / SYSTEM_ALERT_WINDOW
#   * am set-standby-bucket 在本机是死的（恒 bucket=10 reason=f），本脚本不依赖它
#   * am force-stop 会打 stopped=true，但**重启后会被开机流程重置**（README §8.2）→
#     本层只负责 AppOps + idle 标记；force-stop 由入口的冻结步骤统一执行，允许每次开机补跑
#
# 用法：
#   bash background_restrict.sh [--pkg PKG] [--user N] [--uid N] [--serial S] [--dry-run]
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
# 单个 AppOp：写 + 回读（v2.1 §六 6.1：不认 rc，只认回读）
# ---------------------------------------------------------------------------
bg_apply_one() {  # <pkg> <uid> <OP> [ignore|default|allow]
  local pkg="${1:-}" uid="${2:-}" op="${3:-}" val="${4:-ignore}" out v
  out="$(sg_shell cmd appops set --uid "$uid" "$op" "$val")"

  if [ "${SH_DRY_RUN:-0}" = 1 ]; then
    sh_state "appops:$op" SKIPPED "dry-run：未执行 cmd appops set --uid $uid $op $val"
    return 0
  fi

  case "$out" in
    *"No such op"*|*"Unknown operation"*|*"Unknown command"*)
      sh_state "appops:$op" UNKNOWN "UNSUPPORTED(该 ROM 无此 op)：$out"
      return 0
      ;;
    *Exception*|*"Error"*|*"Failure"*)
      sh_state "appops:$op" FAILED "系统拒绝：$out"
      return 0
      ;;
  esac

  v="$(pst_appops_uid_value "$uid" "$op")"
  [ -z "$v" ] && v="$(pst_appops_value "$pkg" "$op")"
  if [ "$v" = "$val" ]; then
    sh_state "appops:$op" SUCCESS "回读 $v"
    [ "$val" = "ignore" ] && snap_changed appops "$op" ignore
  else
    sh_state "appops:$op" FAILED "回读=${v:-<空>}（期望 $val）"
  fi
  return 0
}

# ---------------------------------------------------------------------------
# idle 标记（am set-inactive）
# ---------------------------------------------------------------------------
bg_set_inactive() {  # <pkg> <user>
  local pkg="${1:-}" user="${2:-0}" out v
  out="$(sg_shell am set-inactive --user "$user" "$pkg" true)"
  if [ "${SH_DRY_RUN:-0}" = 1 ]; then
    sh_state "bg:set-inactive" SKIPPED "dry-run：未执行 am set-inactive"
    return 0
  fi
  case "$out" in
    *Exception*|*"Error"*|*"Failure"*|*"Unknown"*)
      sh_state "bg:set-inactive" FAILED "系统拒绝：$out"
      return 0
      ;;
  esac
  v="$(sh_shell am get-inactive "$pkg" 2>/dev/null)"
  case "$v" in
    *"Idle mode=true"*|*"idle=true"*)
      sh_state "bg:set-inactive" SUCCESS "Idle mode=true"
      snap_changed inactive "-" true
      ;;
    *)
      sh_state "bg:set-inactive" UNKNOWN "回读：${v:-<空>}（该 ROM 的 idle 标记不可读，不判死）"
      ;;
  esac
  return 0
}

# ---------------------------------------------------------------------------
# 强停（冻结步骤与开机补跑都用它）
# ---------------------------------------------------------------------------
bg_force_stop() {  # <pkg> <user>
  local pkg="${1:-}" user="${2:-0}" out n
  out="$(sg_shell am force-stop --user "$user" "$pkg")"
  if [ "${SH_DRY_RUN:-0}" = 1 ]; then
    sh_state "bg:force-stop" SKIPPED "dry-run：未执行 am force-stop"
    return 0
  fi
  case "$out" in
    *Exception*|*"Error"*|*"Failure"*)
      sh_state "bg:force-stop" FAILED "系统拒绝：$out"
      return 0
      ;;
  esac
  n="$(pst_process_count "$pkg")"
  if [ "${n:-0}" -eq 0 ]; then
    sh_state "bg:force-stop" SUCCESS "进程归零（stopped=true，重启后会被重置，需补跑）"
    snap_changed force-stop "-" done
  else
    sh_state "bg:force-stop" FAILED "仍有 ${n} 个进程（可能被系统立刻重拉）"
  fi
  return 0
}

# ---------------------------------------------------------------------------
# 整层执行
# ---------------------------------------------------------------------------
bg_restrict_apply() {  # <pkg> <uid> [user]
  local pkg="${1:-}" uid="${2:-}" user="${3:-0}" op
  sh_log "== L2 后台执行限制（v2.1 §四 4.1 / 4.2；AppOps UID 级 + idle）=="
  for op in $SH_BG_OPS_ALL; do
    bg_apply_one "$pkg" "$uid" "$op" ignore
  done
  bg_set_inactive "$pkg" "$user"
  return 0
}

# 还原用：把所有目标 op 写回 default（仅当快照没有原值时作为兜底）
bg_reset() {  # <pkg> <uid>
  local pkg="${1:-}" uid="${2:-}" op
  sh_log "== L2 复位（AppOps → default）=="
  for op in $SH_BG_OPS_ALL; do
    bg_apply_one "$pkg" "$uid" "$op" default
  done
  return 0
}

# ---------------------------------------------------------------------------
main() {
  local pkg="${PKG:-$DEFAULT_PKG}" user="${USER_ID:-}" uid=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --pkg)     pkg="${2:-}"; shift 2 ;;
      --user)    user="${2:-}"; shift 2 ;;
      --uid)     uid="${2:-}"; shift 2 ;;
      --serial)  SH_SERIAL="${2:-}"; shift 2 ;;
      --force-stop) DO_FORCE_STOP=1; shift ;;
      --dry-run) SH_DRY_RUN=1; shift ;;
      -h|--help)
        printf '%s\n' "用法: bash background_restrict.sh [--pkg PKG] [--user N] [--uid N] [--serial S] [--force-stop] [--dry-run]"
        printf '%s\n' "L2 = AppOps UID 级 ignore（执行/时钟/网络/通知/隐私）+ am set-inactive；--force-stop 额外强停一次"
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
    sh_err "拿不到 $pkg 的 UID（cmd package list packages -U / dumpsys 都为空）"
    return 4
  fi
  sh_log "  L2 目标：$pkg  user=$user  uid=$uid"
  snap_ensure "$pkg" "$user"
  bg_restrict_apply "$pkg" "$uid" "$user"
  if [ "${DO_FORCE_STOP:-0}" = 1 ]; then
    bg_force_stop "$pkg" "$user"
  fi
  if [ "${SH_DRY_RUN:-0}" != 1 ]; then
    ver_background_layer "$pkg" "$uid" "$user"
  fi
  sh_summary
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
