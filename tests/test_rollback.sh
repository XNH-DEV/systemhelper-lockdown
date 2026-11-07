#!/usr/bin/env bash
# tests/test_rollback.sh — 回滚类：正常 / 快照缺失 / 快照损坏 / 部分失败
#
# 回滚的硬要求（v2.0 §2.3）：只恢复快照里"原本如此"的项，
# 原本 granted=false 的权限不许擅自授予，原本就在黑名单的 uid 不许移除。
set -uo pipefail

# shellcheck source=./lib/harness.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/harness.sh"

# 先做一次真处置，产生 rollback 依赖的快照
lockdown_once() {
  run_script "$S_LOCKDOWN"
}

# R1 演练：rollback --dry-run 一条写命令都不发
t_rollback_dryrun() {
  case_setup normal
  lockdown_once
  local wl
  wl="$(wc -l <"$MOCK_LOG" | tr -d ' ')"
  run_script "$S_ROLLBACK" --dry-run
  assert_rc 0 "rollback --dry-run"
  assert_out_has "dry-run" "演练必须说明未执行"
  assert_no_writes "rollback --dry-run 发了写命令"
  assert_log_lacks "pm unsuspend" "演练阶段就调了 pm unsuspend"
  assert_eq "$(wc -l <"$MOCK_LOG" | tr -d ' ')" "$wl" "演练阶段不应再产生任何设备调用"
}

# R2 正常回滚（场景 3）：解挂起 + AppOps 回原值；原本 denied 的权限不许授予
t_rollback_normal() {
  case_setup normal
  lockdown_once
  assert_eq "$(state_of suspended)" "1" "前置：处置后应处于挂起"
  run_script "$S_ROLLBACK"
  assert_row_has SUCCESS "unsuspend" "没有解除挂起"
  assert_row_has SUCCESS "appops:RUN_ANY_IN_BACKGROUND" "AppOps 未回到原值"
  assert_row_has SKIPPED "grant:READ_PHONE_STATE" "原本 granted=false 的权限不该授予"
  assert_row_lacks FAILED "" "正常回滚不该有 FAILED"
  assert_eq "$(state_of suspended)" "0" "回读：mock 侧应已解除挂起"
  assert_eq "$(state_of netpolicy_uid)" "" "回读：uid 应已移出后台黑名单"
}

# R3 快照缺失：不许瞎猜原值，直接拒绝
t_rollback_no_snapshot() {
  case_setup normal
  run_script "$S_ROLLBACK"
  assert_rc 4 "没有快照应 exit 4"
  assert_out_has "找不到任何快照" "应说明缺快照"
  assert_no_writes "没有快照时不该写设备"
}

# R4 快照损坏（场景 15）：缺 original_state 就拒绝自动回滚
t_rollback_broken_snapshot() {
  case_setup normal
  local bad="$LOGDIR/2026-01-01_000000"
  mkdir -p "$bad"
  printf '{\n  "pkg": "com.mobiletools.systemhelper"\n}\n' >"$bad/manifest.json"
  printf 'ts\tboom\n' >"$bad/snapshot.kv"
  run_script "$S_ROLLBACK"
  assert_rc 5 "快照不完整应 exit 5"
  assert_out_has "快照不完整" "应说明快照损坏"
  assert_no_writes "缺 original_state 时不该写设备"
}

# R5 恢复失败（场景 4）：快照原值 granted=true，但 pm grant 被系统拒 → FAILED 且非 0
t_rollback_grant_failed() {
  case_setup normal
  # 处置前该权限是 granted=true，快照才会记成 true
  mock_seed perm_granted_READ_PHONE_STATE true
  lockdown_once
  mock_seed grant_mode fail
  run_script "$S_ROLLBACK"
  assert_row_has FAILED "grant:READ_PHONE_STATE" "授权被拒必须记 FAILED"
  assert_rc_nonzero "恢复失败必须非 0 退出"
}

# R6 无设备
t_rollback_no_device() {
  case_setup no_device
  run_script "$S_ROLLBACK"
  assert_rc 4 "无设备应 exit 4"
}

t_case "R1 rollback --dry-run 不产生写命令" t_rollback_dryrun
t_case "R2 正常回滚（按快照原值）" t_rollback_normal
t_case "R3 快照缺失 exit 4" t_rollback_no_snapshot
t_case "R4 快照损坏 exit 5" t_rollback_broken_snapshot
t_case "R5 恢复失败（grant 被拒）非 0 退出" t_rollback_grant_failed
t_case "R6 无设备 exit 4" t_rollback_no_device

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  t_exec_all
  t_summary
  exit $?
fi
