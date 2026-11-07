#!/usr/bin/env bash
# tests/test_lockdown.sh — 处置类：停用 / 冻结 / 卸载 / 重复执行 / 失败传播
#
# 断言锚点是 state.tsv 的 (状态, 动作) 列，不是散文输出：脚本改文案不该让测试变红。
set -uo pipefail

# shellcheck source=./lib/harness.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/harness.sh"

# 造一份真实快照（比跑完整 restrict 便宜），供 restore 类用例用
# 只有 restriction.sh 的快照是恢复层认的格式（snapshot.kv + changed.list）
make_snapshot() {
  run_script "$S_RESTRICT" disable --dry-run >/dev/null 2>&1 || true
  ls -1dt "$LOGDIR"/snapshots/*/ 2>/dev/null | head -1 | sed 's:/$::'
}

# L1 演练：一条写命令都不许发出去
t_dryrun_no_writes() {
  case_setup normal
  run_script "$S_LOCKDOWN" --dry-run
  assert_rc 0 "lockdown --dry-run"
  assert_no_writes "dry-run 发了写命令"
  assert_out_has "dry-run" "dry-run 必须说明未执行"
  assert_out_has "pm suspend" "计划里应出现 pm suspend（README §3 第 7 行）"
  assert_mock_complete
}

# L2 正常停用：suspend 回读 true 才算成功（场景 1）
t_suspend_success() {
  case_setup normal
  run_script "$S_LOCKDOWN"
  assert_rc 0 "lockdown 正常处置"
  assert_state_has SUCCESS "suspend" "suspend 未记 SUCCESS"
  assert_state_lacks FAILED "" "正常处置不该有 FAILED"
  assert_log_has "pm suspend" "没有调用 pm suspend"
  assert_eq "$(state_of suspended)" "1" "回读：mock 侧 suspended 未变 true"
  assert_out_has "判定: SUCCESS" "整体判定应为 SUCCESS"
}

# L3 失败必须非 0 退出（规格书点名缺陷：run() 吞 rc）
t_failure_must_exit_nonzero() {
  case_setup partial_fail
  run_script "$S_LOCKDOWN"
  assert_state_has FAILED "suspend" "系统拒绝时 suspend 必须记 FAILED"
  assert_state_has FAILED "appops:RUN_ANY_IN_BACKGROUND" "appops 被拒必须记 FAILED"
  assert_rc_nonzero "所有写命令都被拒，退出码仍为 0（rc 被吞）"
  assert_out_has "判定: FAILED" "整体判定应为 FAILED"
}

# L4 重复执行停用：第二次仍要如实成功，状态不退化（场景 18）
t_repeat_suspend_idempotent() {
  case_setup normal
  run_script "$S_LOCKDOWN"
  assert_rc 0 "第一次"
  run_script "$S_LOCKDOWN"
  assert_rc 0 "第二次"
  assert_state_has SUCCESS "suspend" "第二次仍应记 SUCCESS"
  assert_eq "$(state_of suspended)" "1" "第二次执行后 suspended 应仍为 true"
  assert_log_count "pm suspend" "2" "两次执行应各发一次 pm suspend"
}

# L5 停用失败（场景 2）：HyperOS 拒绝改系统包启用状态 → FAILED + 非 0
t_disable_blocked() {
  case_setup deny_disable
  run_script "$S_RESTRICT" disable
  assert_state_has FAILED "disable:disable-user" "应记录 disable-user 被拒"
  assert_state_has FAILED "verify:disable" "验证层必须承认没生效"
  assert_state_lacks SUCCESS "disable:disable-user" "被系统拒绝却记 SUCCESS = 伪造"
  assert_rc_nonzero "停用失败必须非 0 退出"
}

# L6 无设备（场景：设备不可用）
t_no_device() {
  case_setup no_device
  run_script "$S_LOCKDOWN"
  assert_rc 4 "无设备应 exit 4"
  assert_out_has "没有可用设备" "应给出无设备原因"
}

# L7 目标包不存在（场景 9）
t_pkg_missing() {
  case_setup pkg_missing
  run_script "$S_RESTRICT" audit
  assert_rc 4 "包不存在应 exit 4"
  assert_out_has "BLOCKED" "应明确 BLOCKED"
  assert_no_writes "包不存在时不该有任何写命令"
}

# L8 系统 APK 不存在（场景 8）：pm path 为空即拒绝，不猜路径
t_apk_missing() {
  case_setup no_apk
  run_script "$S_LOCKDOWN"
  assert_rc 4 "pm path 为空应 exit 4"
  assert_no_writes "APK 取不到时不该写设备"
}

# L9 正常用户级卸载（场景 5）
t_uninstall_ok() {
  case_setup uninstall_ok
  run_script "$S_RESTRICT" uninstall --assume-yes
  assert_rc 0 "卸载成功应 exit 0"
  assert_state_has SUCCESS "uninstall:pm-uninstall" "未记录卸载成功"
  assert_state_has SUCCESS "verify:uninstall" "验证层应确认 installed=false"
  assert_eq "$(state_of installed)" "0" "mock 侧安装状态未变 false"
  assert_log_has "pm uninstall --user 0" "未按 --user 执行卸载"
}

# L10 卸载命令不支持（场景 6）：三种写法全被拦 → FAILED，不许写 SUCCESS
t_uninstall_unsupported() {
  case_setup uninstall_unsupported
  run_script "$S_RESTRICT" uninstall --assume-yes
  assert_rc_nonzero "卸载失败必须非 0 退出"
  assert_state_has FAILED "uninstall:ceiling" "应记录无 root 上限"
  assert_state_lacks SUCCESS "uninstall:" "卸载没成功却记了 SUCCESS"
}

# L11 重复执行卸载（场景 19）：第二次不许伪造成功
t_repeat_uninstall() {
  case_setup uninstall_ok
  run_script "$S_RESTRICT" uninstall --assume-yes
  assert_rc 0 "第一次卸载"
  run_script "$S_RESTRICT" uninstall --assume-yes
  assert_state_lacks SUCCESS "uninstall:pm-uninstall" "已经卸载过，第二次不该再记 SUCCESS"
  assert_state_has FAILED "uninstall:pm-uninstall" "第二次应如实报 not installed"
}

# L12 多用户（场景 10）：写操作必须带 --user，不许硬编码 0
t_multi_user_writes() {
  case_setup users_multi
  USER_ARG="999"  # 由 harness 的 run_script 注入给脚本
  run_script "$S_RESTRICT" disable
  assert_log_has "--user 999" "写命令没带 --user 999"
  assert_log_lacks "--user 0 " "多用户场景不许写 user 0"
  assert_out_has "user=999" "日志应显示目标用户 999"
}

# L13 设备管理策略阻止（场景 12）：依赖闸门必须先拦住
t_device_admin_gate() {
  case_setup device_admin_blocked
  run_script "$S_RESTRICT" uninstall --assume-yes
  assert_state_has FAILED "dep:gate" "设备管理员在场必须拦在闸门"
  assert_state_lacks SUCCESS "uninstall:pm-uninstall" "被闸门拦住却执行了卸载"
  assert_rc_nonzero "闸门拦截必须非 0 退出"
}

# 快照 kv 改写（restore 只认 snapshot.kv 的原值）
# L14 卸载后恢复：install-existing 不支持 → 如实 FAILED（场景 20 + 7）
# 真实语义：快照原值 installed=true，但现在已卸载 → 必须走 install-existing
t_restore_install_existing_unsupported() {
  case_setup normal
  local snap
  snap="$(make_snapshot)"
  if [ -z "$snap" ] || [ ! -f "$snap/snapshot.kv" ]; then
    t_skip "restriction.sh 未产出 snapshot.kv（主脚本改造中）"
    return 77
  fi
  printf 'uninstall	-	pm-uninstall
' >>"$snap/changed.list"
  mock_seed installed 0
  mock_seed dump_shape uninstalled
  mock_seed install_existing unsupported
  run_script "$S_RESTRICT" restore --snapshot "$snap"
  assert_log_has "install-existing" "没有尝试 install-existing"
  assert_state_has FAILED "restore:uninstall" "install-existing 不支持时必须 FAILED"
  assert_eq "$(state_of installed)" "0" "卸载失败后不该假装已装回"
}

# L15 卸载后恢复成功路径（场景 20）
t_restore_install_existing_ok() {
  case_setup normal
  local snap
  snap="$(make_snapshot)"
  if [ -z "$snap" ] || [ ! -f "$snap/snapshot.kv" ]; then
    t_skip "restriction.sh 未产出 snapshot.kv（主脚本改造中）"
    return 77
  fi
  printf 'uninstall	-	pm-uninstall
' >>"$snap/changed.list"
  mock_seed installed 0
  mock_seed dump_shape uninstalled
  run_script "$S_RESTRICT" restore --snapshot "$snap"
  assert_log_has "install-existing" "没有调用 install-existing"
  assert_state_has SUCCESS "restore:uninstall" "install-existing 成功后应记 SUCCESS"
  assert_eq "$(state_of installed)" "1" "mock 侧应回到已安装"
}

t_case "L1 dry-run 不产生写命令" t_dryrun_no_writes
t_case "L2 正常停用（suspend 回读 true）" t_suspend_success
t_case "L3 失败必须非 0 退出（run 吞 rc 缺陷）" t_failure_must_exit_nonzero
t_case "L4 重复执行停用（幂等）" t_repeat_suspend_idempotent
t_case "L5 停用失败（HyperOS 拒绝）" t_disable_blocked
t_case "L6 无设备 exit 4" t_no_device
t_case "L7 目标包不存在 exit 4" t_pkg_missing
t_case "L8 系统 APK 不存在 exit 4" t_apk_missing
t_case "L9 正常用户级卸载" t_uninstall_ok
t_case "L10 卸载命令不支持" t_uninstall_unsupported
t_case "L11 重复执行卸载" t_repeat_uninstall
t_case "L12 多用户写操作带 --user" t_multi_user_writes
t_case "L13 设备管理策略阻止" t_device_admin_gate
t_case "L14 卸载后恢复（install-existing 不支持）" t_restore_install_existing_unsupported
t_case "L15 卸载后恢复成功" t_restore_install_existing_ok

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  t_exec_all
  t_summary
  exit $?
fi
