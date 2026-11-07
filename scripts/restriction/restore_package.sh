#!/usr/bin/env bash
# restore_package.sh — 第六等级 恢复（v2.1 §六 6.6 / §八 8.x）
#
# 三条铁律：
#   1) 只恢复本项目改过的项：读 changed.list；台账为空就什么都不动（绝不"顺手"全量授权）
#   2) 原值一律从快照读：granted / flags / appops / enabled / suspended / distraction / netpolicy
#   3) 原来就 deny 的权限不许授予：原值 granted=false → 只清掉我们加的 USER_SET|USER_FIXED，
#      不执行 pm grant（v2.1 §六 6.6 明文要求）
#
# 两句必须如实说清的话：
#   * pm clear 清掉的应用数据不会因为恢复而回来
#   * 挂起/干扰限制/网络策略/AppOps 可以撤回；已经采走的数据在它自己的库里，撤不撤都在
#
# 用法：
#   bash restore_package.sh [--pkg PKG] [--user N] [--snapshot DIR] [--serial S] [--dry-run]
#   （不给 --snapshot 时取该包最新快照）
set -uo pipefail

SH_RDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SH_CORE_LIB="$(cd "$SH_RDIR/../lib" && pwd)"
SH_RLIB="$SH_RDIR/lib"
if [ -z "${SH_LIBS_READY:-}" ]; then
  SH_LIBS_READY=1
  for SH__f in "$SH_CORE_LIB/common.sh" "$SH_CORE_LIB/adb.sh" "$SH_CORE_LIB/package.sh" \
               "$SH_RLIB/package_state.sh" "$SH_RLIB/user_manager.sh" "$SH_RLIB/safety_guard.sh" \
               "$SH_RLIB/snapshot.sh" "$SH_RLIB/verification.sh" \
               "$SH_RDIR/network_restrict.sh"; do
    [ -f "$SH__f" ] && . "$SH__f"
  done
fi

DEFAULT_PKG="com.mobiletools.systemhelper"

# ---------------------------------------------------------------------------
# 单项恢复
# ---------------------------------------------------------------------------
restore_perm_one() {  # <pkg> <user> <PERM>
  local pkg="${1:-}" user="${2:-0}" perm="${3:-}" orig og g out=""
  orig="$(snap_get "perm:$perm")"
  case "$orig" in
    granted=true*)  og=true ;;
    granted=false*) og=false ;;
    *)              og="" ;;
  esac
  if [ -z "$og" ]; then
    sh_state "restore:perm:$perm" UNKNOWN "快照无原值，保持现状（不猜、不盲授）"
    return 0
  fi

  # 1) 把本项目加的锁定标记清掉（原本就带 USER_FIXED 的保留原样）
  case "$orig" in
    *USER_FIXED*) : ;;
    *) out="$(sg_shell pm clear-permission-flags --user "$user" "$pkg" "android.permission.$perm" user-set user-fixed)" ;;
  esac

  if [ "${SH_DRY_RUN:-0}" = 1 ]; then
    sh_state "restore:perm:$perm" SKIPPED "dry-run：未执行（原值 granted=$og）"
    return 0
  fi

  if [ "$og" = "true" ]; then
    out="$(sg_shell pm grant --user "$user" "$pkg" "android.permission.$perm")"
    g="$(pst_perm_granted "$pkg" "$user" "$perm")"
    if [ "$g" = true ]; then
      sh_state "restore:perm:$perm" SUCCESS "已回到 granted=true${out:+（$out）}"
    else
      sh_state "restore:perm:$perm" FAILED "pm grant 后回读 granted=${g:-?}"
    fi
  else
    # 原值就是 denied：不许授予，只确认现在仍是 denied
    g="$(pst_perm_granted "$pkg" "$user" "$perm")"
    if [ "$g" = false ]; then
      sh_state "restore:perm:$perm" SUCCESS "原值即 denied，保持 denied（未误授，v2.1 §六 6.6）"
    else
      sh_state "restore:perm:$perm" FAILED "原值 denied，现值 granted=${g:-?}（需人工查）"
    fi
  fi
  return 0
}

restore_appops_one() {  # <pkg> <uid> <OP>
  local pkg="${1:-}" uid="${2:-}" op="${3:-}" orig now out
  orig="$(snap_get "appops:$op")"
  [ -n "$orig" ] || orig=default
  out="$(sg_shell cmd appops set --uid "$uid" "$op" "$orig")"

  if [ "${SH_DRY_RUN:-0}" = 1 ]; then
    sh_state "restore:appops:$op" SKIPPED "dry-run：未执行（原值 $orig）"
    return 0
  fi
  case "$out" in
    *Exception*|*"Error"*|*"Failure"*)
      sh_state "restore:appops:$op" FAILED "系统拒绝：$out"
      return 0
      ;;
  esac
  now="$(pst_appops_uid_value "$uid" "$op")"
  [ -z "$now" ] && now="$(pst_appops_value "$pkg" "$op")"
  if [ "$now" = "$orig" ] || { [ "$orig" = default ] && [ -z "$now" ]; }; then
    sh_state "restore:appops:$op" SUCCESS "回到 $orig"
  else
    sh_state "restore:appops:$op" FAILED "原值 $orig，现值 ${now:-<空>}"
  fi
  return 0
}

restore_suspend() {  # <pkg> <user>
  local pkg="${1:-}" user="${2:-0}" orig out v
  orig="$(snap_get suspended)"
  if [ "$orig" = "true" ]; then
    sh_state "restore:suspend" SKIPPED "原本就是挂起状态，保持不动（不是本项目加的就别撤）"
    return 0
  fi
  out="$(sg_shell pm unsuspend --user "$user" "$pkg")"
  if [ "${SH_DRY_RUN:-0}" = 1 ]; then
    sh_state "restore:suspend" SKIPPED "dry-run：未执行 pm unsuspend"
    return 0
  fi
  case "$out" in
    *Exception*|*"Error"*|*"Failure"*)
      sh_state "restore:suspend" FAILED "系统拒绝：$out"
      return 0
      ;;
  esac
  v="$(pst_flag "$pkg" "$user" suspended)"
  if [ "$v" = "false" ]; then
    sh_state "restore:suspend" SUCCESS "suspended=false（已解除挂起）"
  else
    sh_state "restore:suspend" FAILED "回读 suspended=${v:-?}"
  fi
  return 0
}

restore_distraction() {  # <pkg> <user>
  local pkg="${1:-}" user="${2:-0}" orig out f
  orig="$(snap_get distraction_flags)"
  out="$(sg_shell pm set-distracting-restriction --user "$user" "$pkg")"
  if [ "${SH_DRY_RUN:-0}" = 1 ]; then
    sh_state "restore:distraction" SKIPPED "dry-run：未执行清除干扰限制"
    return 0
  fi
  case "$out" in
    *Exception*|*"Error"*|*"Failure"*)
      sh_state "restore:distraction" FAILED "系统拒绝：$out"
      return 0
      ;;
  esac
  f="$(pst_distraction_flags "$pkg" "$user")"
  if [ "${orig:-0}" = "0" ] || [ -z "$orig" ]; then
    if [ "${f:-0}" = "0" ] || [ -z "$f" ]; then
      sh_state "restore:distraction" SUCCESS "干扰限制已清除（distractionFlags=${f:-0}）"
    else
      sh_state "restore:distraction" FAILED "回读 distractionFlags=$f（期望 0）"
    fi
  else
    sh_state "restore:distraction" UNKNOWN "原值 distractionFlags=$orig 非 0（不是本项目设的），现值=${f:-0}，按原值无法精确复现"
  fi
  return 0
}

restore_netpolicy() {  # <pkg> <uid>
  local pkg="${1:-}" uid="${2:-}" orig
  orig="$(snap_get netpolicy_blacklisted)"
  case "$orig" in
    no)  net_remove_uid "$uid" ;;
    yes) sh_state "restore:netpolicy" SKIPPED "原本就在黑名单，保持不动" ;;
    *)   sh_state "restore:netpolicy" UNKNOWN "快照无原始网络策略，保持现状" ;;
  esac
  return 0
}

restore_enabled() {  # <pkg> <user>
  local pkg="${1:-}" user="${2:-0}" orig now out
  orig="$(snap_get enabled)"
  now="$(pst_enabled_code "$pkg" "$user")"
  if [ -z "$orig" ]; then
    sh_state "restore:enabled" UNKNOWN "快照无原始 enabled，保持现状"
    return 0
  fi
  if [ "$now" = "$orig" ]; then
    sh_state "restore:enabled" SKIPPED "已等于原值 enabled=$orig($(pst_enabled_label "$orig"))"
    return 0
  fi
  out="$(sg_shell pm enable --user "$user" "$pkg")"
  if [ "${SH_DRY_RUN:-0}" = 1 ]; then
    sh_state "restore:enabled" SKIPPED "dry-run：未执行 pm enable"
    return 0
  fi
  case "$out" in
    *"Cannot"*|*"Exception"*|*"Error"*|*"Failure"*)
      sh_state "restore:enabled" FAILED "系统拒绝：$out"
      return 0
      ;;
  esac
  now="$(pst_enabled_code "$pkg" "$user")"
  if [ "$now" = "$orig" ]; then
    sh_state "restore:enabled" SUCCESS "enabled 已回到 $orig"
  else
    sh_state "restore:enabled" FAILED "回读 enabled=${now:-?}（期望 $orig）"
  fi
  return 0
}

restore_uninstall() {  # <pkg> <user>
  local pkg="${1:-}" user="${2:-0}" orig out
  orig="$(snap_get installed)"
  if [ "$orig" != "true" ]; then
    sh_state "restore:uninstall" SKIPPED "原值 installed=${orig:-?}，不重新安装"
    return 0
  fi
  if pst_installed "$pkg" "$user"; then
    sh_state "restore:uninstall" SKIPPED "仍然装着，无需 install-existing"
    return 0
  fi
  out="$(sg_shell cmd package install-existing --user "$user" "$pkg")"
  if [ "${SH_DRY_RUN:-0}" = 1 ]; then
    sh_state "restore:uninstall" SKIPPED "dry-run：未执行 install-existing"
    return 0
  fi
  case "$out" in
    *"Package"*"installed for user"*)
      sh_state "restore:uninstall" SUCCESS "$out"
      ;;
    *Exception*|*"Error"*|*"Failure"*|*"Unknown"*)
      sh_state "restore:uninstall" FAILED "系统拒绝：$out"
      ;;
    *)
      if pst_installed "$pkg" "$user"; then
        sh_state "restore:uninstall" SUCCESS "installed=true（输出=${out:-<空>}）"
      else
        sh_state "restore:uninstall" FAILED "install-existing 未生效：${out:-<空>}"
      fi
      ;;
  esac
  return 0
}

# ---------------------------------------------------------------------------
# 整层执行（顺序：先撤冻结 → 回权限 → 回 appops → 网络 → enabled → 安装）
# ---------------------------------------------------------------------------
restore_apply() {  # <pkg> <user> <uid>
  local pkg="${1:-}" user="${2:-0}" uid="${3:-}" key

  if [ -z "$(snap_changes)" ]; then
    sh_state "restore" SKIPPED "changed.list 为空：本项目没有登记过任何变更，不动设备（v2.1 §六 6.6）"
    return 0
  fi

  sh_log "== 第六等级 恢复（只恢复 changed.list 里登记过的项）=="
  sh_log "  快照 $(snap_kv_path)"
  sh_log "  台账："
  snap_changes | sed 's/^/    /' | while IFS= read -r line; do sh_log "$line"; done

  if [ -n "$(snap_changed_keys suspend)" ]; then restore_suspend "$pkg" "$user"; fi
  if [ -n "$(snap_changed_keys distraction)" ]; then restore_distraction "$pkg" "$user"; fi

  for key in $(snap_changed_keys perm); do
    restore_perm_one "$pkg" "$user" "$key"
  done
  for key in $(snap_changed_keys appops); do
    restore_appops_one "$pkg" "$uid" "$key"
  done

  if [ -n "$(snap_changed_keys netpolicy)" ]; then restore_netpolicy "$pkg" "$uid"; fi
  if [ -n "$(snap_changed_keys enabled)" ]; then restore_enabled "$pkg" "$user"; fi
  if [ -n "$(snap_changed_keys uninstall)" ]; then restore_uninstall "$pkg" "$user"; fi

  # 不可回滚项，如实登记
  if [ -n "$(snap_changed_keys clear)" ]; then
    sh_state "restore:clear" UNKNOWN "pm clear 清掉的应用数据不会回来（v2.1 §八 8.x 边界）"
  fi
  if [ -n "$(snap_changed_keys force-stop)" ]; then
    sh_state "restore:force-stop" SKIPPED "force-stop/stopped 标记无需恢复（下次启动自动解除）"
  fi
  return 0
}

# ---------------------------------------------------------------------------
main() {
  local pkg="${PKG:-$DEFAULT_PKG}" user="${USER_ID:-}" snap="${SNAPSHOT:-}" uid=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --pkg)      pkg="${2:-}"; shift 2 ;;
      --user)     user="${2:-}"; shift 2 ;;
      --snapshot) snap="${2:-}"; shift 2 ;;
      --serial)   SH_SERIAL="${2:-}"; shift 2 ;;
      --dry-run)  SH_DRY_RUN=1; shift ;;
      -h|--help)
        printf '%s\n' "用法: bash restore_package.sh [--pkg PKG] [--user N] [--snapshot DIR] [--serial S] [--dry-run]"
        printf '%s\n' "第六等级恢复：只恢复 changed.list 登记过的项，原值取快照，原值为 denied 的权限不授予"
        return 0
        ;;
      *) sh_err "未知参数: $1"; return 2 ;;
    esac
  done

  guard_device
  # 恢复场景下包可能已被卸载 → 只做保护名单检查，不要求 pm path 存在
  guard_protected_only "$pkg"

  if [ -z "$snap" ]; then
    snap="$(snap_latest "$pkg")"
  fi
  if [ -z "$snap" ] || [ ! -d "$snap" ]; then
    sh_err "没有可用快照：restore 只依据快照原值（v2.1 §六 6.6）。用 --snapshot DIR 指定，或先跑 restrict 生成快照"
    return 6
  fi
  if ! snap_load "$snap"; then
    sh_err "快照不可读（缺 snapshot.kv）：$snap"
    return 6
  fi

  # 用户以快照为准，避免"快照是 user 0、恢复时给了 user 999"
  local snap_user
  snap_user="$(snap_get user)"
  if [ -n "$snap_user" ] && [ -n "$user" ] && [ "$user" != "$snap_user" ]; then
    sh_err "指定的 --user $user 与快照记录的用户 $snap_user 不一致，请显式对齐"
    return 2
  fi
  [ -n "$user" ] || user="${snap_user:-0}"

  uid="$(pst_uid "$pkg")"
  sh_log "  恢复目标：$pkg  user=$user  uid=${uid:-?}  快照 $(snap_get ts)"
  if [ -z "$uid" ]; then
    uid="$(snap_get uid)"
  fi

  restore_apply "$pkg" "$user" "$uid"
  if [ "${SH_DRY_RUN:-0}" != 1 ]; then
    ver_restore_layer "$pkg" "$user"
    ver_posture "$pkg" "$user"
  fi
  sh_summary
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
