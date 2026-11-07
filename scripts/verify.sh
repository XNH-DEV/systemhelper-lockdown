#!/usr/bin/env bash
# scripts/verify.sh — 分层验证（v2.0 §2.2 A–F 六层，v2.1 四值结论）
#
# 用法:
#   bash scripts/verify.sh                  # 默认采样 300 秒
#   bash scripts/verify.sh --seconds 60
#   bash scripts/verify.sh --pkg P --user 0 --serial S --out logs
#
# 设计要点（规格书原文要求）:
#   * 不能用一个 PASS 覆盖全部检查 → 分 A–F 六层各自出结论
#   * 进程空 ≠ 没运行过；短窗口零流量 ≠ 永久没联网 → 结论里必须带时间窗口
#   * 统计口径：只算 uid= 行，不叠加 uid_tag（会重复计数）
#   * 每条判定给出 PASS / FAIL / WARN / UNKNOWN
#
# 退出码: 0=全部 PASS 或有 WARN 但无 FAIL  1=有 FAIL  2=关键项 UNKNOWN
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
# shellcheck source=lib/report.sh
. "$HERE/lib/report.sh"

PKG="${PKG:-com.mobiletools.systemhelper}"
USER_ID="${USER_ID:-0}"
SECS="${SECS:-300}"
OUT="${OUT:-$HERE/../logs}"

while [ $# -gt 0 ]; do
  case "$1" in
    --pkg)     PKG="$2"; shift 2 ;;
    --user)    USER_ID="$2"; shift 2 ;;
    --serial)  SH_SERIAL="$2"; shift 2 ;;
    --seconds) SECS="$2"; shift 2 ;;
    --out)     OUT="$2"; shift 2 ;;
    -h|--help) sed -n '2,14p' "$0"; exit 0 ;;
    *) sh_die "未知参数: $1" 2 ;;
  esac
done

main() {
  sh_pick_device
  sh_pkg_exists "$PKG" || sh_die "设备上没有 $PKG" 5
  mkdir -p "$OUT"
  local uid stamp rpt
  uid="$(sh_pkg_uid "$PKG")"
  stamp="$(sh_stamp)"
  rpt="$OUT/verify-$stamp.md"
  sh_report_init "$rpt"

  sh_rpt "设备: $(sh_shell getprop ro.product.model) / $(sh_shell getprop ro.build.version.incremental)"
  sh_rpt "目标: $PKG  user=$USER_ID  uid=${uid:-?}"
  sh_rpt "采样窗口: ${SECS}s"

  # ---------- A 执行状态 ----------
  sh_report_write_group "A" "执行状态"
  local line susp stopped enabled distr proc svc
  line="$(sh_pkg_user_line "$PKG" "$USER_ID")"
  susp="$(sh_pkg_flag "$PKG" "$USER_ID" suspended)"
  stopped="$(sh_pkg_flag "$PKG" "$USER_ID" stopped)"
  enabled="$(sh_pkg_flag "$PKG" "$USER_ID" enabled)"
  distr="$(sh_pkg_flag "$PKG" "$USER_ID" distractionFlags)"
  proc="$(sh_proc_count "$PKG")"
  svc="$(sh_services_of "$PKG")"

  [ "$proc" -eq 0 ] && sh_row A "进程" PASS "ps -A 0 命中" || sh_row A "进程" FAIL "命中 $proc"
  [ "$svc" -eq 0 ] && sh_row A "运行服务" PASS "0 命中" || sh_row A "运行服务" FAIL "命中 $svc"
  [ "$susp" = "true" ] && sh_row A "suspended" PASS "true" || sh_row A "suspended" WARN "=${susp:-?}"
  sh_row A "stopped" "$([ "$stopped" = "true" ] && echo PASS || echo WARN)" "=${stopped:-?}（重启后会被重置，属已知）"
  sh_row A "enabled" "$([ "$enabled" = "3" ] && echo PASS || echo WARN)" "=${enabled:-?}（HyperOS 禁止 shell 改系统包，通常恒为 0）"
  sh_row A "通知限制" "$([ -n "$distr" ] && [ "$distr" != "0" ] && echo PASS || echo WARN)" "distractionFlags=$distr"

  # ---------- B 权限状态 ----------
  sh_report_write_group "B" "权限状态（按用户 $USER_ID）"
  local perm v
  for perm in $SH_DANGEROUS_PERMS; do
    v="$(sh_perm_runtime_granted "$PKG" "$USER_ID" "$perm")"
    case "$v" in
      false) sh_row B "$perm" PASS "granted=false" ;;
      true)  sh_row B "$perm" FAIL "granted=true（未撤销或被重置）" ;;
      *)     sh_row B "$perm" UNKNOWN "读不到" ;;
    esac
  done
  v="$(sh_perm_runtime_granted "$PKG" "$USER_ID" ACCESS_LOCAL_NETWORK)"
  sh_row B "ACCESS_LOCAL_NETWORK" "$([ "$v" = "false" ] && echo PASS || echo UNKNOWN)" "=${v:-?}（REVOKE_WHEN_REQUESTED）"
  # 安装期授予的特权权限：只能报告，不能算 PASS
  v="$(sh_perm_install_granted "$PKG" READ_PRIVILEGED_PHONE_STATE)"
  sh_row B "READ_PRIVILEGED_PHONE_STATE" UNKNOWN "install-time=${v:-?}（撤销通道不存在）"

  # ---------- C 定时与后台 ----------
  sh_report_write_group "C" "定时器与后台执行"
  local appid al_refs
  appid="$(sh_alarm_appid "${uid:-10000}")"
  al_refs="$(sh_alarm_refs "$PKG" | wc -l | tr -d ' ')"
  sh_row C "Alarm 引用残留" WARN "$al_refs 行（suspended 下不投递，但记录仍在）"
  if sh_alarm_restricted "$PKG" "${uid:-0}"; then
    sh_row C "force-standby" PASS "Restricted packages 命中"
  else
    sh_row C "force-standby" UNKNOWN "未在 Restricted packages 中找到"
  fi
  local exa; exa="$(sh_exact_alarm_state "$appid")"
  case "$exa" in
    *:ignore) sh_row C "SCHEDULE_EXACT_ALARM" PASS "u0a$appid:ignore" ;;
    "") sh_row C "SCHEDULE_EXACT_ALARM" UNKNOWN "dumpsys 无该字段（格式可能变化）" ;;
    *) sh_row C "SCHEDULE_EXACT_ALARM" WARN "$exa" ;;
  esac

  # ---------- D 网络策略 ----------
  sh_report_write_group "D" "网络策略"
  if [ -n "$uid" ] && sh_net_blacklisted "$uid"; then
    sh_row D "netpolicy 黑名单" PASS "uid $uid 在列表中"
  else
    sh_row D "netpolicy 黑名单" FAIL "uid ${uid:-?} 不在列表"
  fi
  sh_row D "netd 策略" UNKNOWN "$(sh_net_policy | tr '\n' ' ')"

  # ---------- E 流量观测 ----------
  sh_report_write_group "E" "流量观测（窗口 ${SECS}s，只算 uid= 行）"
  local f0 f1 all0 all1 delta
  f0="$OUT/netstats-T0-$stamp.txt"; f1="$OUT/netstats-T1-$stamp.txt"
  sh_net_sample "$f0" >/dev/null
  all0="$(sh_net_all_uid_lines "$f0")"
  sh_rpt "- T0: $(sh_net_uid_bytes "$f0" "${uid:-0}")  全机 uid 行=$all0"
  sh_log "采样 ${SECS}s …（窗口内请勿手动打开该 App）"
  sleep "$SECS"
  sh_net_sample "$f1" >/dev/null
  all1="$(sh_net_all_uid_lines "$f1")"
  sh_rpt "- T1: $(sh_net_uid_bytes "$f1" "${uid:-0}")  全机 uid 行=$all1"

  if sh_net_delta "$f0" "$f1" "${uid:-0}" >/tmp/.sh_delta.$$ 2>/dev/null; then
    sh_row E "UID 流量增量" PASS "$(cat /tmp/.sh_delta.$$)"
  else
    sh_row E "UID 流量增量" FAIL "$(cat /tmp/.sh_delta.$$ 2>/dev/null)"
  fi
  rm -f /tmp/.sh_delta.$$

  if [ "$all1" -gt "$all0" ]; then
    sh_row E "统计系统活性" PASS "全机 uid 行 $all0→$all1（证明 netstats 在记账，0 增量才有意义）"
  elif [ "$all1" -eq "$all0" ] && [ "$all0" -gt 0 ]; then
    sh_row E "统计系统活性" WARN "全机 uid 行未变化（$all0）→ 0 增量不能当作强证据"
  else
    sh_row E "统计系统活性" UNKNOWN "netstats 无 uid 行（格式变化或统计被重置）"
  fi
  sh_rpt "- 原始文件: $f0 / $f1"

  # ---------- F 长时运行状态 ----------
  sh_report_write_group "F" "长时状态与盲区"
  sh_rpt "- 本报告只覆盖 ${SECS}s 窗口；「今天某时跑过」无法从单次采样排除。"
  sh_rpt "- 历史累计流量请看 设置→应用→联网管理（持久计数器，与 netstats 不同源）。"
  sh_rpt "- 重启后 stopped 会回到 false，需重跑 force-stop。"
  sh_rpt "- OTA 升级可能把权限恢复为默认，需重跑 lockdown.sh。"
  sh_row F "长时无联网" UNKNOWN "单窗口无法证明永久"
  sh_row F "历史已采集数据" UNKNOWN "本地 SQLite 队列无法在无 root 下读取"

  # ---------- 汇总 ----------
  sh_report_summary
  sh_log "报告: $rpt"
  sh_report_exit_code
}

main "$@"
