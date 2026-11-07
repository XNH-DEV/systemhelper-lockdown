#!/usr/bin/env bash
# scripts/lockdown.sh — 无 root 处置（v2.1 重构版）
#
# 用法:
#   bash scripts/lockdown.sh                 # 真改设备（先自动快照）
#   bash scripts/lockdown.sh --dry-run       # 只打印将执行的命令，一条写命令都不发
#   bash scripts/lockdown.sh --no-suspend    # 跳过 pm suspend（有些 ROM 挂起会弹窗）
#   bash scripts/lockdown.sh --pkg <包名> --serial <序列号> --user 0
#   bash scripts/lockdown.sh --force         # 显式越过默认保护名单（危险，会二次确认）
#
# 相对旧版修复（v2.0 §2.1 点名的缺陷）:
#   * run() 不再无条件 return 0 —— 每条命令的真实 rc 与回读结果决定 SUCCESS/FAILED/UNKNOWN
#   * 每步状态写入 execution.tsv，收尾给四值汇总与整体判定
#   * 先快照后动刀（rollback 才有原始值可依）
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
# shellcheck source=lib/snapshot.sh
. "$HERE/lib/snapshot.sh"

PKG="${PKG:-com.mobiletools.systemhelper}"
USER_ID="${USER_ID:-0}"
LOG_ROOT="${LOG_ROOT:-$HERE/../logs}"
DRY=0
SUSPEND=1
FORCE=0

while [ $# -gt 0 ]; do
  case "$1" in
    --pkg)        PKG="$2"; shift 2 ;;
    --user)       USER_ID="$2"; shift 2 ;;
    --serial)     SH_SERIAL="$2"; shift 2 ;;
    --dry-run)    DRY=1; shift ;;
    --no-suspend) SUSPEND=0; shift ;;
    --force)      FORCE=1; shift ;;
    --log-dir)    LOG_ROOT="$2"; shift 2 ;;
    -h|--help)    sed -n '2,16p' "$0"; exit 0 ;;
    *) sh_die "未知参数: $1" 2 ;;
  esac
done

# 执行器：dry-run 只打印；真跑则按回读判状态
x() {  # x <动作名> <设备端命令> [期望回读的关键词]
  local action="$1" cmd="$2" expect="${3:-}"
  if [ "$DRY" = 1 ]; then
    printf '  [dry-run] adb shell %s\n' "$cmd"
    sh_state "$action" SKIPPED "dry-run"
    return 0
  fi
  local out rc
  out="$(sh_shell "$cmd")"; rc=$?
  if [ -n "$out" ]; then printf '    %s\n' "$(printf '%s' "$out" | head -3)"; fi
  if [ "$rc" -ne 0 ]; then
    sh_state "$action" FAILED "rc=$rc ${out%%$'\n'*}"
    return 1
  fi
  case "$out" in
    *Exception*|*"Permission denial"*|*"Access denied"*|*Failure*|*"Unknown operation"*|*"Cannot "*|*"only root"*)
      sh_state "$action" FAILED "${out%%$'\n'*}"
      return 1 ;;
  esac
  if [ -n "$expect" ] && ! printf '%s' "$out" | grep -q "$expect"; then
    # 命令没报错但回读对不上 → 不报成功
    sh_state "$action" UNKNOWN "回读未含 '$expect'"
    return 1
  fi
  sh_state "$action" SUCCESS "${out%%$'\n'*}"
  return 0
}

main() {
  local uid
  sh_pick_device
  guard_target

  if [ "$DRY" != 1 ]; then
    sh_snap_init "$LOG_ROOT" "$PKG" "$USER_ID"
    sh_snap_device
    sh_snap_package "$PKG" "$USER_ID"
    sh_snap_perms "$PKG" "$USER_ID"
    uid="$(sh_pkg_uid "$PKG")"
    sh_snap_appops "$PKG" "${uid:-0}"
    sh_snap_network "${uid:-0}"
    sh_log "已快照 → $SH_SNAP（rollback.sh 依赖它）"
  else
    uid="$(sh_pkg_uid "$PKG")"
    sh_log "== dry-run：以下命令都不会执行 =="
  fi

  sh_log ""
  sh_log "目标: $PKG  user=$USER_ID  uid=${uid:-?}"

  # ---------- L0 执行层 ----------
  sh_log ""
  sh_log "== L0 执行层：让它起不来 =="
  x "force-stop" "am force-stop --user $USER_ID $PKG"
  x "set-inactive" "am set-inactive --user $USER_ID $PKG true"
  if [ "$SUSPEND" = 1 ]; then
    x "suspend" "pm suspend --user $USER_ID $PKG" "suspended state: true"
  else
    sh_state "suspend" SKIPPED "--no-suspend"
  fi

  # ---------- L1 时钟层 ----------
  sh_log ""
  sh_log "== L1 时钟层：掐掉精确定时 =="
  if [ -n "$uid" ]; then
    x "appops:SCHEDULE_EXACT_ALARM" "cmd appops set --uid $uid SCHEDULE_EXACT_ALARM ignore"
  fi

  # ---------- L2 后台执行 ----------
  sh_log ""
  sh_log "== L2 后台执行层 =="
  for op in RUN_ANY_IN_BACKGROUND RUN_IN_BACKGROUND START_FOREGROUND WAKE_LOCK; do
    if [ -n "$uid" ]; then x "appops:$op" "cmd appops set --uid $uid $op ignore"; fi
  done

  # ---------- L3 权限层（必须在 clear 之后，这里没有 clear，正常顺序即可） ----------
  sh_log ""
  sh_log "== L3 权限层：撤销 + 锁定（USER_FIXED，防系统重算覆盖） =="
  local perm
  for perm in $SH_DANGEROUS_PERMS; do
    if [ "$DRY" = 1 ]; then
      printf '  [dry-run] pm revoke --user %s %s android.permission.%s && pm set-permission-flags ... user-set user-fixed\n' "$USER_ID" "$PKG" "$perm"
      sh_state "perm:$perm" SKIPPED "dry-run"
      continue
    fi
    local o
    o="$(sh_perm_revoke_fixed "$PKG" "$USER_ID" "$perm")"
    if [ "$o" = "OK" ] && sh_perm_verify_revoked "$PKG" "$USER_ID" "$perm"; then
      sh_state "perm:$perm" SUCCESS "granted=false+USER_FIXED"
    else
      sh_state "perm:$perm" FAILED "回读=$(sh_perm_runtime_granted "$PKG" "$USER_ID" "$perm")"
    fi
  done
  # 已知撤不掉的，明确记录
  if [ "$DRY" != 1 ]; then
    o="$(sh_perm_revoke_fixed "$PKG" "$USER_ID" ACCESS_LOCAL_NETWORK)"
    if sh_perm_verify_revoked "$PKG" "$USER_ID" ACCESS_LOCAL_NETWORK; then
      sh_state "perm:ACCESS_LOCAL_NETWORK" SUCCESS "granted=false"
    else
      # 系统行为：REVOKE_WHEN_REQUESTED，shell 无撤销通道 → UNKNOWN 而不是 FAILED
      sh_state "perm:ACCESS_LOCAL_NETWORK" UNKNOWN "UNSUPPORTED(REVOKE_WHEN_REQUESTED)，非本项目失败"
    fi
  fi

  # ---------- L4 网络层 ----------
  sh_log ""
  sh_log "== L4 网络层：后台流量在 netd 层拒绝 =="
  if [ -n "$uid" ]; then
    x "netpolicy:blacklist" "cmd netpolicy add restrict-background-blacklist $uid"
    if [ "$DRY" != 1 ]; then
      if sh_net_blacklisted "$uid"; then
        sh_state "netpolicy:verify" SUCCESS "uid $uid 在黑名单"
      else
        sh_state "netpolicy:verify" UNKNOWN "回读未见 uid"
      fi
    fi
  else
    sh_state "netpolicy:blacklist" SKIPPED "uid 未知"
  fi

  # ---------- L5 通知层 ----------
  sh_log ""
  sh_log "== L5 通知层 =="
  x "distracting-restriction" "pm set-distracting-restriction --user $USER_ID --flag hide-notifications --flag hide-from-suggestions $PKG"
  if [ -n "$uid" ]; then x "appops:POST_NOTIFICATION" "cmd appops set --uid $uid POST_NOTIFICATION ignore"; fi

  # ---------- 收尾 ----------
  sh_log ""
  if [ "$DRY" != 1 ]; then
    sh_snap_after "$PKG" "$USER_ID" "${uid:-0}"
    sh_log "处置后 dump → $SH_SNAP/after_state/"
  fi
  sh_summary
  local rc=$?
  cat <<EOF

下一步:
  bash scripts/verify.sh              # 分层验证（A–F 六层）
  bash scripts/rollback.sh            # 按快照精确回滚
  bash scripts/restriction/restriction.sh audit   # 只读复核

注意:
  * 本方案没有卸载任何东西；/system 里的 APK 仍在。
  * 重启会重置 stopped 标记（suspended 保留）→ 每次开机重跑一次 force-stop。
  * MIUI「联网控制」四个开关 adb 写不进去，需要手点（README §4.6）。
EOF
  return $rc
}

guard_target() {
  if sh_is_protected "$PKG"; then
    if [ "$FORCE" != 1 ]; then
      sh_die "$PKG 命中保护名单（如确要处置请加 --force，并自行承担后果）" 3
    fi
    sh_warn "$PKG 命中保护名单，--force 已开启"
    if [ "$DRY" != 1 ]; then
      sh_confirm_exact "FORCE $PKG" || sh_die "确认串不匹配，已中止" 5
    fi
  fi
  sh_pkg_exists "$PKG" || sh_die "设备上没有 $PKG" 4
}

main "$@"
