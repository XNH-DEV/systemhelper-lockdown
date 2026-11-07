#!/usr/bin/env bash
# tests/test_verify.sh — 验证类：PASS / FAIL / UNKNOWN 三态判定
#
# verify.sh 的纪律：分 A–F 六层出结论，禁止用一个 PASS 覆盖全部；
# UNKNOWN = "无法证明"，不是失败，但也不许当成功。
set -uo pipefail

# shellcheck source=./lib/harness.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/harness.sh"

# 造一份"处置后"的姿态：挂起、无进程、AppOps ignore、uid 已在黑名单
seed_treated() {
  local op
  for op in RUN_IN_BACKGROUND RUN_ANY_IN_BACKGROUND START_FOREGROUND WAKE_LOCK \
    GET_USAGE_STATS ACTIVATE_VPN POST_NOTIFICATION SYSTEM_ALERT_WINDOW SCHEDULE_EXACT_ALARM; do
    mock_seed "op_$op" ignore
  done
  mock_seed suspended 1
  mock_seed stopped true
  mock_seed running 0
  mock_seed netpolicy_uid 10100
}

# V1 全绿：六层各有 PASS，退出码 0
t_verify_pass() {
  case_setup normal
  seed_treated
  run_script "$S_VERIFY" --seconds 0 --out "$LOGDIR"
  assert_rc 0 "全绿应 exit 0"
  assert_report_row A "进程" PASS "A 层进程判定"
  assert_report_row A "suspended" PASS "A 层挂起判定"
  assert_report_row D "netpolicy 黑名单" PASS "D 层网络策略"
  assert_report_row E "UID 流量增量" PASS "E 层流量增量"
  assert_report_row C "force-standby" PASS "C 层 force-standby"
}

# V2 仍有进程：A 层必须 FAIL，整体非 0
t_verify_fail_process() {
  case_setup normal
  seed_treated
  mock_seed running 1
  run_script "$S_VERIFY" --seconds 0 --out "$LOGDIR"
  assert_rc 1 "有进程应 exit 1"
  assert_report_row A "进程" FAIL "有进程必须判 FAIL"
  assert_out_lacks "全部 PASS" "有 FAIL 时不许宣称全通过"
}

# V3 UID 不匹配（场景 16）：dumpsys uid=10100，但黑名单里没有它
t_verify_uid_mismatch() {
  case_setup normal
  seed_treated
  mock_seed netpolicy_uid ""
  run_script "$S_VERIFY" --seconds 0 --out "$LOGDIR"
  assert_rc 1 "uid 不在黑名单应 exit 1"
  assert_report_row D "netpolicy 黑名单" FAIL "uid 不匹配必须判 FAIL"
}

# V4 流量有增量：E 层必须 FAIL
t_verify_traffic_growth() {
  case_setup normal
  seed_treated
  mock_seed traffic_mode grow
  run_script "$S_VERIFY" --seconds 0 --out "$LOGDIR"
  assert_rc 1 "有流量增量应 exit 1"
  assert_report_row E "UID 流量增量" FAIL "增量非 0 必须判 FAIL"
}

# V5 UNKNOWN 不冒充失败，也不冒充成功：读数缺失时只能给 UNKNOWN/WARN
t_verify_unknown_not_pass() {
  case_setup normal
  seed_treated
  mock_seed dump_shape partial
  mock_seed installed 0
  run_script "$S_VERIFY" --seconds 0 --out "$LOGDIR"
  assert_rc 0 "UNKNOWN/WARN 不应把整体判失败（exit 2 才是全无 PASS）"
  assert_report_row B "READ_PHONE_STATE" UNKNOWN "读不到的权限必须记 UNKNOWN"
  assert_report_row A "suspended" WARN "缺读数时必须 WARN 而不是 PASS"
  assert_report_row F "长时无联网" UNKNOWN "长时结论只能是 UNKNOWN"
}

t_case "V1 全绿 PASS（六层分判）" t_verify_pass
t_case "V2 仍有进程 → FAIL" t_verify_fail_process
t_case "V3 UID 不匹配 → FAIL" t_verify_uid_mismatch
t_case "V4 流量有增量 → FAIL" t_verify_traffic_growth
t_case "V5 UNKNOWN 不冒充 PASS/FAIL" t_verify_unknown_not_pass

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  t_exec_all
  t_summary
  exit $?
fi
