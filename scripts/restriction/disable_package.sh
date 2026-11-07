#!/usr/bin/env bash
# disable_package.sh — L4 停用（v2.1 §四 4.x 停用层）
#
# 本机实测（HyperOS 4.0 / API 37，原文照抄，README §3 第 5、6 行）：
#   pm disable-user --user 0 <pkg>  → rc=255
#     SecurityException: Cannot disable system packages.
#     （PackageManagerServiceImpl.shouldRestrictEnabledSettingsChange:1116）
#   pm disable --user 0 <pkg>       → 同上
#   组件级 pm disable-user <pkg>/<comp> → Shell cannot change component state for ComponentInfo{...} to 3
#   pm hide --user 0                → SecurityException: Access denied, requires: android.permission.MANAGE_USERS
#   pm uninstall-system-updates     → 返回 Success 但本包没有 /data/app 更新，等于空转
#
# 所以这个脚本的正确定位是：**如实尝试并把系统原句带回来**。
# 系统拒绝 → 记 FAILED + BLOCKED(原因)，绝不把"没生效"写成 SUCCESS（v2.1 §六 6.1）。
#
# 用法：
#   bash disable_package.sh [--pkg PKG] [--user N] [--serial S] [--dry-run]
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
# 包级停用（两种写法都试，判定只看 enabled 回读）
# ---------------------------------------------------------------------------
disable_try() {  # <pkg> <user> <disable-user|disable>
  local pkg="${1:-}" user="${2:-0}" mode="${3:-disable-user}" out en
  case "$mode" in
    disable-user) out="$(sg_shell pm disable-user --user "$user" "$pkg")" ;;
    disable)      out="$(sg_shell pm disable --user "$user" "$pkg")" ;;
    *) sh_state "disable:$mode" FAILED "内部错误：未知子命令 $mode"; return 0 ;;
  esac

  if [ "${SH_DRY_RUN:-0}" = 1 ]; then
    sh_state "disable:$mode" SKIPPED "dry-run：未执行 pm $mode --user $user $pkg"
    return 0
  fi

  case "$out" in
    *"Cannot disable system packages"*)
      sh_state "disable:$mode" FAILED "BLOCKED(HyperOS PackageManagerServiceImpl.shouldRestrictEnabledSettingsChange:1116)：$out"
      return 0
      ;;
    *"Shell cannot change component state"*)
      sh_state "disable:$mode" FAILED "BLOCKED(Shell cannot change component state)：$out"
      return 0
      ;;
    *MANAGE_USERS*|*"requires:"*)
      sh_state "disable:$mode" FAILED "BLOCKED(权限不足，需 MANAGE_USERS)：$out"
      return 0
      ;;
    *"SecurityException"*|*"Exception"*|*"Failure"*|*"Error"*)
      sh_state "disable:$mode" FAILED "系统拒绝：$out"
      return 0
      ;;
  esac

  # 命令没报错也可能没生效 —— 只认 enabled 回读
  en="$(pst_enabled_code "$pkg" "$user")"
  if pst_enabled_is_disabled "$en"; then
    sh_state "disable:$mode" SUCCESS "enabled=$en($(pst_enabled_label "$en"))"
    snap_changed enabled "-" "$en"
  else
    sh_state "disable:$mode" FAILED "enabled=${en:-?}($(pst_enabled_label "$en")) 未变（命令无报错但没生效）"
  fi
  return 0
}

# ---------------------------------------------------------------------------
# 组件级停用探针（组件名不一定是 .service.RegisterIntentService，
# 本机 dumpsys 只列导出组件，所以先枚举再打 —— README §9 的坑）
# ---------------------------------------------------------------------------
disable_component_probe() {  # <pkg> <user>
  local pkg="${1:-}" user="${2:-0}" comp out
  comp="$(pst_components "$pkg" | head -1)"
  if [ -z "$comp" ]; then
    sh_state "disable:component" SKIPPED "dumpsys 未枚举到组件（Resolver Table 只列导出组件）"
    return 0
  fi

  out="$(sg_shell pm disable-user --user "$user" "$comp")"
  if [ "${SH_DRY_RUN:-0}" = 1 ]; then
    sh_state "disable:component" SKIPPED "dry-run：未执行 pm disable-user --user $user $comp"
    return 0
  fi

  case "$out" in
    *"Shell cannot change component state"*)
      sh_state "disable:component" FAILED "BLOCKED(Shell cannot change component state)：$comp"
      return 0
      ;;
    *"requires:"*|*MANAGE_USERS*|*"Exception"*|*"Failure"*|*"Error"*)
      sh_state "disable:component" FAILED "BLOCKED：$comp → $out"
      return 0
      ;;
  esac

  if pst_component_disabled "$pkg" "$comp"; then
    sh_state "disable:component" SUCCESS "$comp 已进 disabledComponents"
    snap_changed component "$comp" disabled
  else
    sh_state "disable:component" FAILED "$comp 命令无报错但未进 disabledComponents"
  fi
  return 0
}

# ---------------------------------------------------------------------------
# 整层执行
# ---------------------------------------------------------------------------
disable_apply() {  # <pkg> <user>
  local pkg="${1:-}" user="${2:-0}"
  sh_log "== L4 停用（v2.1 §四 停用层；本机已知被系统硬墙拦住，如实上报）=="
  disable_try "$pkg" "$user" disable-user
  disable_try "$pkg" "$user" disable
  disable_component_probe "$pkg" "$user"
  # pm hide：本机 rc=255，需要 MANAGE_USERS，单独记一条（不做等效替代）
  local out
  out="$(sg_shell pm hide --user "$user" "$pkg")"
  if [ "${SH_DRY_RUN:-0}" = 1 ]; then
    sh_state "disable:hide" SKIPPED "dry-run：未执行 pm hide"
  else
    case "$out" in
      *MANAGE_USERS*|*"requires:"*)
        sh_state "disable:hide" FAILED "BLOCKED(需 MANAGE_USERS)：$out" ;;
      *"Exception"*|*"Failure"*|*"Error"*)
        sh_state "disable:hide" FAILED "系统拒绝：$out" ;;
      *)
        if [ "$(pst_flag "$pkg" "$user" hidden)" = "true" ]; then
          sh_state "disable:hide" SUCCESS "hidden=true"
          snap_changed hidden "-" true
        else
          sh_state "disable:hide" FAILED "hidden=$(pst_flag "$pkg" "$user" hidden)（命令无报错但没生效）"
        fi ;;
    esac
  fi
  return 0
}

# ---------------------------------------------------------------------------
main() {
  local pkg="${PKG:-$DEFAULT_PKG}" user="${USER_ID:-}"
  while [ $# -gt 0 ]; do
    case "$1" in
      --pkg)     pkg="${2:-}"; shift 2 ;;
      --user)    user="${2:-}"; shift 2 ;;
      --serial)  SH_SERIAL="${2:-}"; shift 2 ;;
      --dry-run) SH_DRY_RUN=1; shift ;;
      -h|--help)
        printf '%s\n' "用法: bash disable_package.sh [--pkg PKG] [--user N] [--serial S] [--dry-run]"
        printf '%s\n' "L4 = pm disable-user / pm disable / 组件级 disable / pm hide，逐条如实上报"
        return 0
        ;;
      *) sh_err "未知参数: $1"; return 2 ;;
    esac
  done

  guard_device
  guard_target_pkg "$pkg"
  user="$(um_resolve_user "$user")"
  sh_log "  L4 目标：$pkg  user=$user  uid=$(pst_uid "$pkg")"
  snap_ensure "$pkg" "$user"
  disable_apply "$pkg" "$user"
  if [ "${SH_DRY_RUN:-0}" != 1 ]; then
    ver_disable_layer "$pkg" "$user"
  fi
  sh_summary
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
