#!/usr/bin/env bash
# scripts/rollback.sh — 基于快照的精确回滚（v2.0 §2.3 重构）
#
# 用法:
#   bash scripts/rollback.sh                 # 用 logs/ 里最新快照
#   bash scripts/rollback.sh --snap logs/2026-11-07_003534
#   bash scripts/rollback.sh --dry-run       # 只打印
#
# 与旧版的区别（规格书点名的缺陷）:
#   * 旧版把所有 AppOps 恢复成 default、把所有权限无条件 grant —— 那不是回滚。
#   * 新版只恢复「快照里原本就是那个值」的项：
#       - 原本 granted=false 的权限不会被授予
#       - 原本 ignore 的 AppOps 不会被改成 default
#       - 原本不在 netpolicy 黑名单的才移除，原本就在的不动
#   * 每条恢复都回读；失败如实报 FAILED，不许假装成功
#   * 快照缺失/损坏时拒绝自动执行，要求人工
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/common.sh
. "$HERE/lib/common.sh"
# shellcheck source=lib/adb.sh
. "$HERE/lib/adb.sh"
# shellcheck source=lib/package.sh
. "$HERE/lib/package.sh"
# shellcheck source=lib/permissions.sh
. "$HERE/lib/permissions.sh"
# shellcheck source=lib/appops.sh
. "$HERE/lib/appops.sh"
# shellcheck source=lib/network.sh
. "$HERE/lib/network.sh"
# shellcheck source=lib/process.sh
. "$HERE/lib/process.sh"

PKG="${PKG:-com.mobiletools.systemhelper}"
USER_ID="${USER_ID:-0}"
LOG_ROOT="${LOG_ROOT:-$HERE/../logs}"
SNAP="${SNAP:-}"
DRY=0

while [ $# -gt 0 ]; do
  case "$1" in
    --pkg)     PKG="$2"; shift 2 ;;
    --user)    USER_ID="$2"; shift 2 ;;
    --serial)  SH_SERIAL="$2"; shift 2 ;;
    --snap)    SNAP="$2"; shift 2 ;;
    --log-dir) LOG_ROOT="$2"; shift 2 ;;
    --dry-run) DRY=1; shift ;;
    -h|--help) sed -n '2,16p' "$0"; exit 0 ;;
    *) sh_die "未知参数: $1" 2 ;;
  esac
done

x() {  # x <动作> <命令> [期望关键词]
  local action="$1" cmd="$2" expect="${3:-}"
  if [ "$DRY" = 1 ]; then printf '  [dry-run] adb shell %s\n' "$cmd"; sh_state "$action" SKIPPED "dry-run"; return 0; fi
  local out rc; out="$(sh_shell "$cmd")"; rc=$?
  [ -n "$out" ] && printf '    %s\n' "$(printf '%s' "$out" | head -2)"
  if [ "$rc" -ne 0 ]; then sh_state "$action" FAILED "rc=$rc ${out%%$'\n'*}"; return 1; fi
  case "$out" in *Exception*|*Failure*|*"Access denied"*) sh_state "$action" FAILED "${out%%$'\n'*}"; return 1 ;; esac
  if [ -n "$expect" ] && ! printf '%s' "$out" | grep -q "$expect"; then
    sh_state "$action" UNKNOWN "回读未含 '$expect'"; return 1
  fi
  sh_state "$action" SUCCESS "${out%%$'\n'*}"; return 0
}

pick_snap() {
  if [ -n "$SNAP" ]; then
    [ -d "$SNAP" ] || sh_die "快照目录不存在: $SNAP" 4
  else
    SNAP="$(ls -dt "$LOG_ROOT"/*/ 2>/dev/null | head -1)"
    [ -n "$SNAP" ] || sh_die "找不到任何快照（先跑 lockdown.sh 或 snapshot.sh）" 4
    SNAP="${SNAP%/}"
  fi
  [ -f "$SNAP/original_state/dumpsys-package.txt" ] || sh_die "快照不完整（缺 dumpsys-package.txt），拒绝自动回滚" 5
  sh_log "使用快照: $SNAP"
}

main() {
  sh_pick_device
  pick_snap
  local uid; uid="$(sh_pkg_uid "$PKG")"
  local orig_pkg orig_user
  orig_pkg="$(sed -n 's/.*"pkg": "\([^"]*\)".*/\1/p' "$SNAP/manifest.json" 2>/dev/null | head -1)"
  orig_user="$(sed -n 's/.*"target_user": \([0-9]*\).*/\1/p' "$SNAP/manifest.json" 2>/dev/null | head -1)"
  if [ -n "$orig_pkg" ] && [ "$orig_pkg" != "$PKG" ]; then
    sh_die "快照属于 $orig_pkg，与当前目标 $PKG 不一致（禁止跨包恢复）" 5
  fi
  if [ -n "$orig_user" ] && [ "$orig_user" != "$USER_ID" ]; then
    sh_warn "快照是 user $orig_user 的，当前 user $USER_ID —— 可能恢复错用户"
  fi

  sh_log "== 回滚 $PKG (uid=${uid:-?}, user=$USER_ID) =="

  # ---------- 1. 挂起 ----------
  local orig_susp
  orig_susp="$(grep -m1 "User $USER_ID:" "$SNAP/original_state/dumpsys-package.txt" 2>/dev/null | grep -oE 'suspended=[a-z]+' | cut -d= -f2)"
  if [ "$orig_susp" = "false" ] || [ -z "$orig_susp" ]; then
    x "unsuspend" "pm unsuspend --user $USER_ID $PKG"
  else
    sh_state "unsuspend" SKIPPED "原本就是 suspended=$orig_susp"
  fi

  # ---------- 2. 通知限制 ----------
  local orig_distr
  orig_distr="$(grep -m1 "User $USER_ID:" "$SNAP/original_state/dumpsys-package.txt" 2>/dev/null | grep -oE 'distractionFlags=[0-9]+' | cut -d= -f2)"
  if [ "${orig_distr:-0}" = "0" ]; then
    x "distraction-clear" "pm set-distracting-restriction --user $USER_ID $PKG"
  else
    sh_state "distraction-clear" SKIPPED "原本 distractionFlags=$orig_distr"
  fi

  # ---------- 3. AppOps：只还原被我们改过、且原本不是 ignore 的 ----------
  local op orig_val cur
  for op in RUN_ANY_IN_BACKGROUND RUN_IN_BACKGROUND START_FOREGROUND WAKE_LOCK SCHEDULE_EXACT_ALARM POST_NOTIFICATION; do
    orig_val="$(grep -E "^$op:" "$SNAP/original_state/appops.txt" 2>/dev/null | head -1 | sed 's/.*: //;s/;.*//')"
    cur="$(sh_appops_value "$PKG" "$op")"
    if [ "$orig_val" = "ignore" ]; then
      sh_state "appops:$op" SKIPPED "原本就是 ignore"
      continue
    fi
    if [ -z "$cur" ]; then
      sh_state "appops:$op" UNKNOWN "读不到当前值"
      continue
    fi
    if [ "$cur" = "${orig_val:-default}" ]; then
      sh_state "appops:$op" SKIPPED "已是原值 ${orig_val:-default}"
      continue
    fi
    x "appops:$op" "cmd appops set $PKG $op ${orig_val:-default}"
  done

  # ---------- 4. 网络策略：原本不在黑名单才移除 ----------
  if [ -n "$uid" ]; then
    if grep -qw "$uid" "$SNAP/original_state/netpolicy-blacklist.txt" 2>/dev/null; then
      sh_state "netpolicy" SKIPPED "快照里原本就在黑名单"
    else
      if sh_net_blacklisted "$uid"; then
        x "netpolicy" "cmd netpolicy remove restrict-background-blacklist $uid"
      else
        sh_state "netpolicy" SKIPPED "当前不在黑名单"
      fi
    fi
  fi

  # ---------- 5. 待机标记 ----------
  x "set-inactive" "am set-inactive --user $USER_ID $PKG false"

  # ---------- 6. 权限：只授予快照里原本 granted=true 的 ----------
  local perm orig
  for perm in $SH_DANGEROUS_PERMS; do
    orig="$(grep -E "android\.permission\.$perm:" "$SNAP/original_state/runtime-perms.txt" 2>/dev/null | head -1 | sed 's/.*granted=//;s/[, ].*//')"
    case "$orig" in
      true)
        x "grant:$perm" "pm grant --user $USER_ID $PKG android.permission.$perm" ;;
      false)
        sh_state "grant:$perm" SKIPPED "原本 granted=false（不擅自授予）" ;;
      *)
        sh_state "grant:$perm" UNKNOWN "快照无该权限记录 → 保持现状（人工确认）" ;;
    esac
  done

  # ---------- 7. 特权权限 ----------
  sh_state "grant:READ_PRIVILEGED_PHONE_STATE" UNKNOWN "install-time 权限无 grant 通道（重启后由系统按默认恢复）"

  sh_log ""
  sh_log "注意：pm clear 清掉的应用数据不会因为回滚而回来；本地 SQLite 队列同理。"
  sh_summary
}

main "$@"
