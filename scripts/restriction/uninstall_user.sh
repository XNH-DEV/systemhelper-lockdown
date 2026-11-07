#!/usr/bin/env bash
# uninstall_user.sh — L5 用户级卸载（v2.1 §四 卸载层 / §六 6.4 双重确认 / §六 6.5 快照）
#
# 本机实测（HyperOS 4.0 / API 37，README §3 第 1-3 行）：
#   pm uninstall --user 0 <pkg>      → Failure [only root can delete system app for a particular user]
#   pm uninstall -k --user 0 <pkg>   → 同上
#   cmd package uninstall --user 0   → 同上
#   即 API 35+ 对系统应用收紧了用户级删除，只有 root 能删。
#   同包名 + 更高 versionCode 的自签空壳顶替也不通（签名校验在 commit 阶段拦，README §3）。
#
# 三条写法都试，全部失败就如实写 BLOCKED，并把"无 root 可达上限 = restrict 冻结组合"指出来。
#
# 强制流程（缺一不可）：
#   1) 快照（设备/ROM/API/用户/包名/UID/安装状态/APK 路径/版本/签名 SHA-256/原始 enabled/
#      原始权限/原始 appops/原始网络策略/原始组件状态/已知依赖）—— v2.1 §六 6.5
#   2) 依赖闸门（device admin 在场直接拦）—— v2.1 §六 6.3
#   3) 双重确认：必须原样输入 `UNINSTALL <pkg> USER <id>` —— v2.1 §六 6.4
#
# 用法：
#   bash uninstall_user.sh [--pkg PKG] [--user N] [--serial S] [--assume-yes] [--dry-run]
set -uo pipefail

SH_RDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SH_CORE_LIB="$(cd "$SH_RDIR/../lib" && pwd)"
SH_RLIB="$SH_RDIR/lib"
if [ -z "${SH_LIBS_READY:-}" ]; then
  SH_LIBS_READY=1
  for SH__f in "$SH_CORE_LIB/common.sh" "$SH_CORE_LIB/adb.sh" "$SH_CORE_LIB/package.sh" \
               "$SH_RLIB/package_state.sh" "$SH_RLIB/user_manager.sh" "$SH_RLIB/safety_guard.sh" \
               "$SH_RLIB/snapshot.sh" "$SH_RLIB/verification.sh" \
               "$SH_RDIR/dependency_check.sh"; do
    [ -f "$SH__f" ] && . "$SH__f"
  done
fi

DEFAULT_PKG="com.mobiletools.systemhelper"

# ---------------------------------------------------------------------------
# 单次尝试：判定只看 installed 回读，不看命令行输出里的 Success
# ---------------------------------------------------------------------------
uninstall_attempt() {  # <pkg> <user> <标签> <设备命令...>
  local pkg="${1:-}" user="${2:-0}" label="${3:-attempt}"
  shift 3
  local out

  out="$(sg_shell "$@")"
  if [ "${SH_DRY_RUN:-0}" = 1 ]; then
    sh_state "uninstall:$label" SKIPPED "dry-run：未执行 $*"
    return 0
  fi

  case "$out" in
    *"only root can delete system app for a particular user"*)
      sh_state "uninstall:$label" FAILED "BLOCKED(API35+ 仅 root)：only root can delete system app for a particular user"
      return 1
      ;;
    *"DELETE_FAILED"*|*"Exception"*|*"Failure"*|*"Error"*|*"denied"*)
      sh_state "uninstall:$label" FAILED "系统拒绝：$out"
      return 1
      ;;
  esac

  if pst_installed "$pkg" "$user"; then
    sh_state "uninstall:$label" FAILED "installed 仍为 true（命令输出=${out:-<空>}，不伪造成功）"
    return 1
  fi

  sh_state "uninstall:$label" SUCCESS "installed=false（输出=${out:-Success}）"
  snap_changed uninstall "-" "$label"
  return 0
}

# ---------------------------------------------------------------------------
# 整层执行：三种写法依次试，任一成功即止
# ---------------------------------------------------------------------------
uninstall_apply() {  # <pkg> <user>
  local pkg="${1:-}" user="${2:-0}" ok=0
  sh_log "== L5 用户级卸载（三种写法全试；本机预期 BLOCKED）=="

  uninstall_attempt "$pkg" "$user" "pm-uninstall" pm uninstall --user "$user" "$pkg" && ok=1
  if [ "$ok" -eq 0 ]; then
    uninstall_attempt "$pkg" "$user" "pm-uninstall-k" pm uninstall -k --user "$user" "$pkg" && ok=1
  fi
  if [ "$ok" -eq 0 ]; then
    uninstall_attempt "$pkg" "$user" "cmd-package-uninstall" cmd package uninstall --user "$user" "$pkg" && ok=1
  fi

  if [ "$ok" -eq 0 ]; then
    sh_state "uninstall:ceiling" FAILED "BLOCKED(无 root：三条用户级卸载写法全被拦)。无 root 可达上限是 restrict 冻结组合：suspend + AppOps ignore + revoke/USER_FIXED + clear + 干扰限制 + netpolicy + force-stop"
    return 1
  fi
  return 0
}

# ---------------------------------------------------------------------------
main() {
  local pkg="${PKG:-$DEFAULT_PKG}" user="${USER_ID:-}" uid=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --pkg)        pkg="${2:-}"; shift 2 ;;
      --user)       user="${2:-}"; shift 2 ;;
      --serial)     SH_SERIAL="${2:-}"; shift 2 ;;
      --assume-yes) SH_ASSUME_YES=1; shift ;;
      --dry-run)    SH_DRY_RUN=1; shift ;;
      -h|--help)
        printf '%s\n' "用法: bash uninstall_user.sh [--pkg PKG] [--user N] [--serial S] [--assume-yes] [--dry-run]"
        printf '%s\n' "L5 = pm uninstall --user，需先快照 + 依赖检查 + 输入确认串 UNINSTALL <pkg> USER <id>"
        return 0
        ;;
      *) sh_err "未知参数: $1"; return 2 ;;
    esac
  done

  guard_device
  guard_target_pkg "$pkg"
  user="$(um_resolve_user "$user")"
  uid="$(pst_uid "$pkg")"
  sh_log "  L5 目标：$pkg  user=$user  uid=${uid:-?}"

  # 1) 快照必须先落盘（v2.1 §六 6.5）—— 卸载之后没快照就没法恢复
  snap_new "$pkg" "$user"
  snap_collect "$pkg" "$user"
  guard_snapshot_ready || return 6
  snap_show

  # 2) 依赖闸门（v2.1 §六 6.3）
  if ! dep_gate_uninstall "$pkg"; then
    sh_summary
    return 1
  fi

  # 3) 双重确认（v2.1 §六 6.4）
  if ! guard_confirm_uninstall "$pkg" "$user"; then
    sh_state "uninstall:confirm" SKIPPED "确认串不匹配，未执行卸载"
    sh_summary
    return 5
  fi

  uninstall_apply "$pkg" "$user"
  if [ "${SH_DRY_RUN:-0}" != 1 ]; then
    ver_uninstall_layer "$pkg" "$user"
  fi
  sh_summary
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
