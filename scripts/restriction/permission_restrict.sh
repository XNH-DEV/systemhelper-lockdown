#!/usr/bin/env bash
# permission_restrict.sh — L1 权限限制（v2.1 §四 4.3 权限层 / §六 6.7）
#
# 照抄真机实测结论（HyperOS 4.0 / API 37）：
#   * pm revoke 单独用对 GRANTED_BY_DEFAULT 权限不稳定，系统重算就授回去
#     → 必须紧跟 pm set-permission-flags <pkg> <perm> user-set user-fixed
#       （docs/zh-CN/COMPATIBILITY-hyperos4.md §2 第 2 条）
#   * pm clear 会把运行时权限重置为默认授予 → L1 必须在 clear 之后复跑一次
#     （README.zh-CN §3 / CHANGELOG v2.1「执行顺序缺陷」—— 真机踩过的坑）
#   * ACCESS_LOCAL_NETWORK 带 REVOKE_WHEN_REQUESTED：pm revoke 回 rc=0 但值不变 → UNSUPPORTED
#   * READ_PRIVILEGED_PHONE_STATE 是 install-time 特权权限，根本撤不掉（不进撤销集）
#
# 阶段语义（--phase）：
#   pre   清数据前的"占位撤销"：会被 pm clear 一枪打回，所以只记 SKIPPED + 台账
#   post  默认。撤销 + USER_FIXED 锁定 + 回读；只有回读到 granted=false 且带 USER_FIXED 才 SUCCESS
#   both  pre + post（单独跑、不经过 clear 时的兼容写法）
#
# 用法：
#   bash permission_restrict.sh [--pkg PKG] [--user N] [--uid N] [--phase pre|post|both] [--dry-run]
#   （可被 source：只定义函数，不执行 main）
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
# 单项：撤销 + 锁定 + 回读
# ---------------------------------------------------------------------------
perm_apply_one() {  # <pkg> <user> <PERM 短名> <pre|post>
  local pkg="${1:-}" user="${2:-0}" perm="${3:-}" phase="${4:-post}"
  local o1 o2 g fl

  o1="$(sg_shell pm revoke --user "$user" "$pkg" "android.permission.$perm")"
  o2="$(sg_shell pm set-permission-flags --user "$user" "$pkg" "android.permission.$perm" user-set user-fixed)"

  if [ "${SH_DRY_RUN:-0}" = 1 ]; then
    sh_state "perm:$perm" SKIPPED "dry-run：未执行 pm revoke / pm set-permission-flags"
    return 0
  fi

  case "$o1$o2" in
    *Exception*|*Error*|*error*|*Failure*|*Unknown*)
      sh_state "perm:$perm" FAILED "系统报错：$(printf '%s %s' "$o1" "$o2" | tr -s ' ')"
      return 0
      ;;
  esac

  if [ "$phase" = "pre" ]; then
    snap_changed perm "$perm" "revoked(pre)"
    sh_state "perm:$perm" SKIPPED "pre 阶段已撤；pm clear 会重置它，post 阶段复跑确认"
    return 0
  fi

  # 回读：只有 granted=false 且带 USER_FIXED 才算锁定成功（v2.1 §六 6.1 不许伪造成功）
  g="$(pst_perm_granted "$pkg" "$user" "$perm")"
  fl="$(pst_perm_flags "$pkg" "$user" "$perm")"
  case "$g" in
    false)
      case "$fl" in
        *USER_FIXED*)
          sh_state "perm:$perm" SUCCESS "granted=false flags=[$fl]（USER_FIXED 已锁，重启/OTA 不复位）"
          snap_changed perm "$perm" "revoked-fixed"
          ;;
        *)
          sh_state "perm:$perm" UNKNOWN "granted=false 但 flags=[${fl:-空}] 缺 USER_FIXED（系统重算会授回去）"
          ;;
      esac
      ;;
    true)
      sh_state "perm:$perm" FAILED "granted=true：撤销未生效（被系统重算覆盖 / 特权权限撤不掉）"
      ;;
    *)
      sh_state "perm:$perm" UNKNOWN "回读缺失（该用户下无此权限记录？）"
      ;;
  esac
  return 0
}

# ---------------------------------------------------------------------------
# ACCESS_LOCAL_NETWORK：已知撤销被忽略，单独探针（v2.1 §六 6.7）
# ---------------------------------------------------------------------------
perm_forbidden_probe() {  # <pkg> <user>
  local pkg="${1:-}" user="${2:-0}" before after out
  before="$(pst_perm_granted "$pkg" "$user" "$SH_FORBIDDEN_PERM")"
  if [ -z "$before" ]; then
    sh_state "perm:$SH_FORBIDDEN_PERM" SKIPPED "本包无此权限运行时记录"
    return 0
  fi
  out="$(sg_shell pm revoke --user "$user" "$pkg" "android.permission.$SH_FORBIDDEN_PERM")"
  if [ "${SH_DRY_RUN:-0}" = 1 ]; then
    sh_state "perm:$SH_FORBIDDEN_PERM" SKIPPED "dry-run：未执行 pm revoke"
    return 0
  fi
  after="$(pst_perm_granted "$pkg" "$user" "$SH_FORBIDDEN_PERM")"
  if [ "$after" = "false" ]; then
    sh_state "perm:$SH_FORBIDDEN_PERM" SUCCESS "granted=false（本机通常做不到，出现即复测确认）"
  else
    sh_state "perm:$SH_FORBIDDEN_PERM" UNKNOWN "UNSUPPORTED(REVOKE_WHEN_REQUESTED)：撤销被系统忽略（before=$before after=${after:-?}）；证据见 README §3 第 10 行${out:+，输出=$out}"
  fi
}

# ---------------------------------------------------------------------------
# 整层执行
# ---------------------------------------------------------------------------
perm_restrict_apply() {  # <pkg> <user> <pre|post|both>
  local pkg="${1:-}" user="${2:-0}" phase="${3:-post}" list p n=0
  sh_log "== L1 权限限制（phase=$phase；v2.1 §四 4.3）=="
  list="$(pst_perm_targets "$pkg" "$user")"
  for p in $list; do
    if [ "$phase" = "both" ]; then
      perm_apply_one "$pkg" "$user" "$p" pre
      perm_apply_one "$pkg" "$user" "$p" post
    else
      perm_apply_one "$pkg" "$user" "$p" "$phase"
    fi
    n=$((n + 1))
  done
  if [ "$n" -eq 0 ]; then
    sh_state "perm:set" SKIPPED "该用户下没有需要撤销的敏感运行时权限"
  fi
  # pre 阶段不碰 ACCESS_LOCAL_NETWORK（撤了也会被 clear 打回）
  if [ "$phase" != "pre" ]; then
    perm_forbidden_probe "$pkg" "$user"
  fi
  return 0
}

# ---------------------------------------------------------------------------
main() {
  local pkg="${PKG:-$DEFAULT_PKG}" user="${USER_ID:-}" uid="" phase="post"
  while [ $# -gt 0 ]; do
    case "$1" in
      --pkg)     pkg="${2:-}"; shift 2 ;;
      --user)    user="${2:-}"; shift 2 ;;
      --uid)     uid="${2:-}"; shift 2 ;;
      --phase)   phase="${2:-post}"; shift 2 ;;
      --serial)  SH_SERIAL="${2:-}"; shift 2 ;;
      --dry-run) SH_DRY_RUN=1; shift ;;
      -h|--help)
        printf '%s\n' "用法: bash permission_restrict.sh [--pkg PKG] [--user N] [--uid N] [--phase pre|post|both] [--serial S] [--dry-run]"
        printf '%s\n' "L1 = pm revoke + set-permission-flags user-set user-fixed，回读确认（v2.1 §四 4.3）"
        return 0
        ;;
      *) sh_err "未知参数: $1"; return 2 ;;
    esac
  done
  case "$phase" in
    pre|post|both) ;;
    *) sh_err "--phase 只能是 pre|post|both"; return 2 ;;
  esac

  guard_device
  guard_target_pkg "$pkg"
  user="$(um_resolve_user "$user")"
  [ -n "$uid" ] || uid="$(pst_uid "$pkg")"
  sh_log "  L1 目标：$pkg  user=$user  uid=${uid:-?}"
  snap_ensure "$pkg" "$user"
  perm_restrict_apply "$pkg" "$user" "$phase"
  if [ "${SH_DRY_RUN:-0}" != 1 ]; then
    ver_perm_layer "$pkg" "$user"
  fi
  sh_summary
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
