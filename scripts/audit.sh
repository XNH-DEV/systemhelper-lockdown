#!/usr/bin/env bash
# scripts/audit.sh — 只读审计（v2.0 第三阶段 4.1–4.4 + 第五阶段网络审计）
#
# 默认完全只读：不发任何会改设备状态的命令。
# 用法:
#   bash scripts/audit.sh                     # 审计默认包/用户 0
#   bash scripts/audit.sh --pkg <包名> --user 999 --serial <序列号>
#   bash scripts/audit.sh --spacing short     # 不采样 netstats
#
# 退出码: 0=审计完成（不代表安全） 2=部分 UNKNOWN 4=设备/参数问题
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
# shellcheck source=lib/report.sh
. "$HERE/lib/report.sh"

PKG="${PKG:-com.mobiletools.systemhelper}"
USER_ID="${USER_ID:-0}"
OUT="${OUT:-$HERE/../logs}"
SAMPLE=1

while [ $# -gt 0 ]; do
  case "$1" in
    --pkg)      PKG="$2"; shift 2 ;;
    --user)     USER_ID="$2"; shift 2 ;;
    --serial)   SH_SERIAL="$2"; shift 2 ;;
    --out)      OUT="$2"; shift 2 ;;
    --no-sample) SAMPLE=0; shift ;;
    -h|--help)  sed -n '2,12p' "$0"; exit 0 ;;
    *) sh_die "未知参数: $1" 2 ;;
  esac
done

main() {
  sh_pick_device

  if ! sh_pkg_exists "$PKG"; then
    sh_die "设备上没有 $PKG（pm path 为空）" 5
  fi

  sh_snap_init "$OUT" "$PKG" "$USER_ID"
  sh_report_init "$SH_SNAP/audit-report.md"
  local uid; uid="$(sh_pkg_uid "$PKG")"

  # ---------- 0. 设备 ----------
  sh_snap_device
  sh_report_write_group "0" "设备与用户"
  sh_rpt "- 型号: $(sh_shell getprop ro.product.model)"
  sh_rpt "- ROM : $(sh_shell getprop ro.build.version.incremental)"
  sh_rpt "- OS  : $(sh_shell getprop ro.mi.os.version.name)"
  sh_rpt "- 当前用户: $(sh_current_user) / 目标用户: $USER_ID"
  sh_rpt "- 用户列表:"
  sh_users | sed 's/^/    /' >>"$SH_RPT_FILE"

  # ---------- 1. APK 信息（4.1） ----------
  sh_snap_package "$PKG" "$USER_ID"
  sh_report_write_group "1" "APK 信息"
  local path; path="$(sh_pkg_path "$PKG")"
  sh_rpt "- 包名: $PKG"
  sh_rpt "- 路径: $path"
  sh_pkg_is_system "$PKG" && sh_rpt "- 系统分区应用: 是" || sh_rpt "- 系统分区应用: 否"
  sh_rpt "- UID: ${uid:-UNKNOWN}"
  sh_rpt "- VersionCode: $(sh_shell dumpsys package "$PKG" | grep -m1 -oE 'versionCode=[0-9]+' | cut -d= -f2)"
  sh_rpt "- VersionName: $(sh_shell dumpsys package "$PKG" | grep -m1 -oE 'versionName=[^ ]+' | cut -d= -f2)"
  sh_rpt "- targetSdk: $(sh_shell dumpsys package "$PKG" | grep -m1 -oE 'targetSdk=[0-9]+' | cut -d= -f2)"
  sh_rpt "- minSdk: $(sh_shell dumpsys package "$PKG" | grep -m1 -oE 'minSdk=[0-9]+' | cut -d= -f2)"
  sh_rpt "- APK SHA-256: $(sh_shell "sha256sum '$path' 2>/dev/null" | awk '{print $1}')"
  sh_rpt "- APK split 数: $(sh_pkg_splits "$PKG")"
  sh_rpt "- sharedUser: $(sh_pkg_shared_uid "$PKG")"
  sh_rpt "- 签名: 见 original_state/dumpsys-package.txt 的 signatures 段（本机 dumpsys 不打印摘要时记 UNKNOWN）"

  # 签名（优先 apksigner：PATH → ANDROID_HOME/build-tools/*）
  local apksigner_bin=""
  if sh_have apksigner; then apksigner_bin="apksigner"
  elif [ -n "${ANDROID_HOME:-}" ]; then
    apksigner_bin="$(ls -1 "$ANDROID_HOME"/build-tools/*/apksigner 2>/dev/null | tail -1)"
  fi
  if [ -n "$apksigner_bin" ]; then
    sh_adb pull "$path" "$SH_SNAP/original_state/pkg.apk" >/dev/null 2>&1 && \
      "$apksigner_bin" verify --print-certs "$SH_SNAP/original_state/pkg.apk" >"$SH_SNAP/original_state/certs.txt" 2>&1 && \
      sh_rpt "- 证书: $(grep -m1 'certificate DN' "$SH_SNAP/original_state/certs.txt" || echo UNKNOWN)"
  else
    sh_rpt "- 证书: UNKNOWN（本机无 apksigner；APK 已拉到 original_state/pkg.apk，可离线验）"
    sh_adb pull "$path" "$SH_SNAP/original_state/pkg.apk" >/dev/null 2>&1 || true
  fi

  # ---------- 2. 权限三层（4.2） ----------
  sh_snap_perms "$PKG" "$USER_ID"
  sh_report_write_group "2" "权限三层（Manifest / 安装期 / 运行时）"
  sh_rpt ""
  sh_rpt "| 权限 | 声明 | 安装期授予 | 运行时(用户$USER_ID) | 类型 |"
  sh_rpt "|---|---|---|---|---|"
  local perm ig rt typ
  for perm in $SH_DANGEROUS_PERMS $SH_PRIV_PERMS ACCESS_LOCAL_NETWORK INTERNET ACCESS_NETWORK_STATE; do
    sh_perm_requested "$PKG" | grep -qx "$perm" && declared=是 || declared=否
    [ "$declared" = "否" ] && continue
    ig="$(sh_perm_install_granted "$PKG" "$perm")"
    rt="$(sh_perm_runtime_granted "$PKG" "$USER_ID" "$perm")"
    case " $SH_PRIV_PERMS " in *" $perm "*) typ="特权/签名" ;; *) typ="运行时危险" ;; esac
    sh_rpt "| $perm | $declared | ${ig:-none} | ${rt:-none} | $typ |"
  done
  sh_rpt ""
  sh_rpt "> 安装期授予的权限无法用 pm revoke 撤销（priv-app）；本方案不依赖撤销它们，靠「不执行 + 不联网」。"
  sh_rpt "> ACCESS_LOCAL_NETWORK 在 API 36+ 带 REVOKE_WHEN_REQUESTED，撤销会被忽略。"

  # ---------- 3. 组件与触发面（4.1 后半） ----------
  sh_report_write_group "3" "组件与触发面"
  sh_rpt '```'
  sh_service_table "$PKG" | head -60 >>"$SH_RPT_FILE"
  sh_rpt '```'
  sh_rpt "- Activity 引用: $(sh_shell dumpsys activity activities | grep -cF "$PKG")"
  sh_rpt "- 广播注册: $(sh_shell dumpsys activity broadcasts | grep -cF "$PKG")"

  # ---------- 4. 后台与定时（4.3） ----------
  sh_report_write_group "4" "后台执行与定时（当前观测值）"
  sh_row A "进程数" "$([ "$(sh_proc_count "$PKG")" -eq 0 ] && echo PASS || echo FAIL)" "ps -A 命中 $(sh_proc_count "$PKG")"
  sh_row A "运行中服务" "$([ "$(sh_services_of "$PKG")" -eq 0 ] && echo PASS || echo FAIL)" "dumpsys activity services 命中 $(sh_services_of "$PKG")"
  sh_row A "Alarm 引用" "WARN" "dumpsys alarm 命中 $(sh_alarm_refs "$PKG" | wc -l) 行"
  sh_row A "JobScheduler 受限" "$([ "$(sh_jobs_restricted "$PKG")" -gt 0 ] && echo PASS || echo UNKNOWN)" "Restricted packages 命中 $(sh_jobs_restricted "$PKG")"
  sh_row C "精确闹钟" "UNKNOWN" "Last OP_SCHEDULE_EXACT_ALARM=$(sh_exact_alarm_state "$(sh_alarm_appid "${uid:-10000}")")"
  sh_rpt "- 待机桶: $(sh_standby_bucket "$PKG")（本机 am set-standby-bucket 实测无效，属已知坑）"
  sh_rpt "- 包状态: $(sh_pkg_user_line "$PKG" "$USER_ID")"

  # ---------- 5. 网络（第五阶段） ----------
  sh_snap_network "${uid:-0}"
  sh_report_write_group "5" "网络审计"
  sh_rpt "- netpolicy 黑名单: $(sh_net_blacklisted "${uid:-0}" && echo 已加入 || echo 未加入)"
  sh_rpt "- 网络策略: $(sh_net_policy | tr '\n' ' ')"
  sh_rpt "- UID 流量(T0): $(sh_net_uid_bytes "$SH_SNAP/original_state/netstats-t0.txt" "${uid:-0}")"
  sh_rpt "- 已知 IOC（来自 APK 字符串，非运行证据）: dm.wo.com.cn:18080 / :18081"
  sh_rpt ""
  sh_rpt "证据分级（v2.0 4.4）："
  sh_rpt "- A 代码中存在读取逻辑：已确认（getDeviceId/getSubscriberId/getAllCellInfo/BSSID 等引用）"
  sh_rpt "- B 运行时确实读取：$(sh_row E '运行时读取' UNKNOWN '需 logcat/审计钩子，本脚本不声明')" >/dev/null
  sh_row E "运行时读取" UNKNOWN "静态审计无法证明"
  sh_row E "进入上传请求" UNKNOWN "无抓包（无 root 无法 tcpdump 归属）"
  sh_row E "服务端已接收" UNKNOWN "无法从设备侧证明"

  if [ "$SAMPLE" = 1 ]; then
    sh_rpt ""
    sh_rpt "采样 60 秒后再取一次 netstats（只观测，不改设备）…"
    sleep 60
    sh_net_sample "$SH_SNAP/after_state/netstats-t2.txt" >/dev/null
    sh_rpt "- UID 流量(T2): $(sh_net_uid_bytes "$SH_SNAP/after_state/netstats-t2.txt" "${uid:-0}")"
    sh_rpt "- 增量: $(sh_net_delta "$SH_SNAP/original_state/netstats-t0.txt" "$SH_SNAP/after_state/netstats-t2.txt" "${uid:-0}" || echo '无增量（0 字节）')"
  fi

  # ---------- 6. 依赖面（4.4 后半） ----------
  sh_report_write_group "6" "依赖面"
  sh_rpt "- 设备管理员引用: $(sh_shell dumpsys device_policy | grep -cF "$PKG")"
  sh_rpt "- 无障碍服务: $(sh_shell settings get secure enabled_accessibility_services | grep -cF "$PKG")"
  sh_rpt "- 通知监听: $(sh_shell settings get secure enabled_notification_listeners | grep -cF "$PKG")"
  sh_rpt "- 持有其签名权限的其他包: $(sh_shell dumpsys package | grep -c "com.mobiletools.systemhelper.permission") 处引用（含定义体，不等于外部依赖）"
  sh_rpt "- launcher 入口: $(sh_shell cmd package resolve-activity --brief "$PKG" 2>/dev/null | tail -1)"

  # ---------- 7. 结论 ----------
  sh_report_write_group "7" "结论"
  sh_rpt "- 本报告全部只读，未修改设备任何状态。"
  sh_rpt "- 审计完成 ≠ 安全；处置请用 scripts/restriction/restriction.sh plan 看方案。"
  sh_rpt "- 报告文件: $SH_SNAP/audit-report.md"
  sh_rpt "- 原始 dump: $SH_SNAP/"

  sh_log ""
  sh_log "审计完成 → $SH_SNAP/audit-report.md"
  if grep -q 'UNKNOWN' "$SH_SNAP/audit-report.md" 2>/dev/null; then exit 2; fi
  exit 0
}

main "$@"
