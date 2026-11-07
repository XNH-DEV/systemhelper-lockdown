#!/usr/bin/env bash
# tests/test_safety.sh — 安全类：保护名单 / 确认串 / 多设备 / 只读不写 / 快照完整性
#
# 全部走 mock adb，且每条用例都带超时（防止某个 mock 分支卡住整套 CI）。
set -uo pipefail
# shellcheck disable=SC2034  # RUN_OUT/RUN_RC/STDIN_DATA 由 harness 消费

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/harness.sh"

S_AUDIT="$REPO_ROOT/scripts/audit.sh"

# 直接给被测脚本一个 mock 环境（不走 harness 的 _run_target，因为要套 timeout）
run_to() {  # run_to <秒> <脚本> [参数...]
  local secs="$1"; shift
  local out rc
  out="$(cd "$REPO_ROOT" && \
        ADB="$MOCK_ADB" SH_ADB="$MOCK_ADB" \
        MOCK_SCENARIO="$MOCK_SCENARIO" MOCK_LOG="$MOCK_LOG" \
        MOCK_STATE_DIR="$MOCK_STATE_DIR" MOCK_FIXTURES="$FIXTURES_DIR" \
        LOG_ROOT="$LOGDIR" SH_LOG_DIR="$LOGDIR" SERIAL="${SERIAL_ARG:-}" SH_SERIAL="${SERIAL_ARG:-}" \
        PKG="${PKG_ARG:-}" USER_ID="${USER_ARG:-0}" \
        timeout "$secs" bash "$@" </dev/null 2>&1)"
  rc=$?
  RUN_OUT="$out"; RUN_RC="$rc"
}

# S1 保护名单：高通同名组件必须被拒绝（规格书单列红线）
t_protected_qualcomm() {
  case_setup normal
  run_to 25 "$REPO_ROOT/scripts/lockdown.sh" --pkg com.qualcomm.qti.services.systemhelper --dry-run
  assert_rc 3 "高通同名组件应被拒绝(3)"
  assert_out_has "保护名单" "应说明命中保护名单"
  assert_no_writes "拒绝时不得下发任何写命令"
}

# S2 保护名单：系统核心包同样拒绝
t_protected_system_ui() {
  case_setup normal
  run_to 25 "$REPO_ROOT/scripts/lockdown.sh" --pkg com.android.systemui --dry-run
  assert_rc 3 "SystemUI 应被拒绝(3)"
}

# S3 双重确认：空输入必须拒绝（函数级，避免触发完整卸载流程）
t_confirm_rejects_empty() {
  case_setup normal
  local out
  out="$(core_eval 'SH_ASSUME_YES=0; printf "" | sh_confirm_exact "UNINSTALL com.mobiletools.systemhelper USER 0" && echo YES || echo NO')"
  assert_text_has "$out" "NO" "空输入必须拒绝"
}

# S3b 双重确认：输入错串也必须拒绝
t_confirm_rejects_wrong() {
  case_setup normal
  local out
  out="$(core_eval 'SH_ASSUME_YES=0; printf "uninstall it\n" | sh_confirm_exact "UNINSTALL com.mobiletools.systemhelper USER 0" && echo YES || echo NO')"
  assert_text_has "$out" "NO" "错串必须拒绝"
}

# S3c 双重确认：精确串才放行
t_confirm_accepts_exact() {
  case_setup normal
  local out
  out="$(core_eval 'SH_ASSUME_YES=0; printf "UNINSTALL com.mobiletools.systemhelper USER 0\n" | sh_confirm_exact "UNINSTALL com.mobiletools.systemhelper USER 0" && echo YES || echo NO')"
  assert_text_has "$out" "YES" "精确串应放行"
}

# S4 多设备：未指定 serial 必须拒绝
t_multi_device_refused() {
  case_setup multi_device
  run_to 25 "$REPO_ROOT/scripts/lockdown.sh" --dry-run
  assert_rc 4 "多设备未指定 serial 应拒绝(4)"
  assert_out_has "SERIAL" "应提示用 SERIAL 指定"
}

# S5 dry-run 一条写命令都不许发
t_dry_run_no_writes() {
  case_setup normal
  run_to 40 "$REPO_ROOT/scripts/lockdown.sh" --dry-run
  assert_rc 0 "dry-run 应以 0 结束"
  assert_no_writes "dry-run 出现写命令"
  assert_out_has "dry-run" "应明确标注 dry-run"
}

# S6 audit 完全只读
t_audit_readonly() {
  case_setup normal
  run_to 60 "$S_AUDIT" --no-sample
  assert_no_writes "audit 出现写命令"
}

# S7 目标包不存在：早早退出
t_missing_package() {
  case_setup pkg_missing
  run_to 25 "$REPO_ROOT/scripts/lockdown.sh" --dry-run
  assert_rc_nonzero "包不存在应非 0"
  assert_no_writes "包不存在时不得下发写命令"
}

# S8 快照不完整时 rollback 必须拒绝
t_rollback_refuses_broken_snapshot() {
  case_setup normal
  local bad="$CASE_DIR/bad_snap"
  mkdir -p "$bad"
  printf '{"pkg":"com.mobiletools.systemhelper"}\n' >"$bad/manifest.json"
  run_to 25 "$REPO_ROOT/scripts/rollback.sh" --snap "$bad" --dry-run
  assert_rc_nonzero "残缺快照应被拒绝"
  assert_out_has "快照" "应提示快照不完整"
}

# S9 verify 不得发出写命令
t_verify_readonly() {
  case_setup normal
  run_to 60 "$REPO_ROOT/scripts/verify.sh" --seconds 1
  assert_no_writes "verify 出现写命令"
}


# S10 保护名单单一真源：lib/common.sh 的 sh_is_protected 边界（含反例，防误伤）
t_is_protected_unit() {
  case_setup normal
  local got
  got="$(core_eval '
    for p in com.qualcomm.qti.services.systemhelper com.qualcomm.x android              com.android.settings com.android.systemui com.miui.home              com.google.android.packageinstaller; do
      sh_is_protected "$p" || printf "MISS:%s " "$p"
    done
    for p in com.mobiletools.systemhelper com.qualcommx.foo com.example.com.qualcomm.x; do
      sh_is_protected "$p" && printf "FALSEPOS:%s " "$p"
    done
  ')"
  assert_text_lacks "$got" "MISS:" "保护名单漏项"
  assert_text_lacks "$got" "FALSEPOS:" "保护名单误伤"
}

# S11 卸载确认串不匹配（场景 13）：整条流程必须 exit 5 且一条 pm uninstall 都不发
t_uninstall_confirm_mismatch() {
  case_setup normal
  STDIN_DATA="UNINSTALL com.mobiletools.systemhelper USER 999"
  run_script "$S_RESTRICT" uninstall
  assert_rc 5 "确认串不匹配应 exit 5"
  assert_out_has "确认串不匹配" "应说明确认失败"
  assert_log_lacks "pm uninstall" "确认失败后仍执行了卸载"
  assert_state_lacks SUCCESS "uninstall:" "确认失败后不该有卸载 SUCCESS"
}

# S12 用户取消（场景 14）：EOF 等同取消
t_uninstall_cancelled() {
  case_setup normal
  run_script "$S_RESTRICT" uninstall
  assert_rc 5 "无输入应 exit 5"
  assert_no_writes "取消后仍发了写命令"
}

# S13 夹具完整性：mock 不许出现未实现的设备命令（否则测试是自欺）
t_mock_covers_commands() {
  case_setup normal
  run_script "$S_LOCKDOWN" --dry-run
  run_script "$S_RESTRICT" audit
  assert_mock_complete "mock 有未实现的设备命令"
}

t_case "S1 保护名单：com.qualcomm.qti.services.systemhelper" t_protected_qualcomm
t_case "S2 保护名单：com.android.systemui" t_protected_system_ui
t_case "S3 双重确认：空输入拒绝" t_confirm_rejects_empty
t_case "S3b 双重确认：错串拒绝" t_confirm_rejects_wrong
t_case "S3c 双重确认：精确串放行" t_confirm_accepts_exact
t_case "S4 多设备未指定 serial 拒绝" t_multi_device_refused
t_case "S5 dry-run 不发写命令" t_dry_run_no_writes
t_case "S6 audit 完全只读" t_audit_readonly
t_case "S7 目标包不存在" t_missing_package
t_case "S8 残缺快照拒绝回滚" t_rollback_refuses_broken_snapshot
t_case "S9 verify 只读" t_verify_readonly
t_case "S10 sh_is_protected 边界单测" t_is_protected_unit
t_case "S11 卸载确认串不匹配（exit 5）" t_uninstall_confirm_mismatch
t_case "S12 用户取消（EOF）" t_uninstall_cancelled
t_case "S13 mock 命令覆盖完整" t_mock_covers_commands

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  t_exec_all
  t_summary
  exit $?
fi
