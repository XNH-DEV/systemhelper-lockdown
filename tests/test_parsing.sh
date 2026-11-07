#!/usr/bin/env bash
# tests/test_parsing.sh — 解析类：UID / 用户切段 / appops / netstats / sharedUserId / 版本
#
# 夹具来自 HyperOS 4.0 真机 dump（logs/2026-11-07_003534/raw）。
# 关键坑：dumpsys 里没有 userId=，只有 uid=10100 与 appId=10100；
#         pm list packages 恒空（rc=0），枚举必须走 cmd package list packages。
set -uo pipefail

# shellcheck source=./lib/harness.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/harness.sh"

# P1 UID 解析：cmd package list packages -U → uid:10100
t_uid_primary() {
  case_setup normal
  assert_eq "$(core_eval 'pst_uid com.mobiletools.systemhelper')" "10100" "pst_uid"
  assert_eq "$(core_eval 'sh_pkg_uid com.mobiletools.systemhelper')" "10100" "sh_pkg_uid"
}

# P2 UID 取不到时不许猜：必须显式报未知，并把依赖 UID 的层标 SKIPPED
t_uid_unknown_not_guessed() {
  case_setup uid_unavailable
  run_script "$S_LOCKDOWN" --dry-run
  assert_out_has "uid=?" "取不到 UID 时必须打印 ?（不许猜 10100/0）"
  assert_out_lacks "uid=10100" "UID 缺失却给出了具体值"
  assert_out_has "netpolicy" "netpolicy 层仍要出现在计划里"
}

# P3 用户切段：User 0 与 User 999 各一份，不能把 999 的默认值当 0
t_user_sections() {
  case_setup users_multi
  local seg0 seg999 en999 susp0
  seg0="$(core_eval 'pst_user_line com.mobiletools.systemhelper 0')"
  seg999="$(core_eval 'pst_user_line com.mobiletools.systemhelper 999')"
  en999="$(core_eval 'pst_flag com.mobiletools.systemhelper 999 enabled')"
  susp0="$(core_eval 'pst_flag com.mobiletools.systemhelper 0 suspended')"
  assert_text_has "$seg0" "installed=true" "User 0 段"
  assert_text_has "$seg999" "installed=false" "User 999 段"
  assert_eq "$en999" "0" "User 999 enabled"
  assert_eq "$susp0" "false" "User 0 suspended"
  assert_eq "$(core_eval 'pst_installed com.mobiletools.systemhelper 999 && echo YES || echo NO')" "NO" "User 999 未安装"
}

# P4 HyperOS 坑：pm list packages 零输出（所有场景都恒空），安装判定仍要正确
t_pm_list_empty_trap() {
  case_setup pm_list_empty
  local raw vis
  raw="$(core_eval 'sh_shell pm list packages')"
  vis="$(core_eval 'pst_installed com.mobiletools.systemhelper 0 && echo YES || echo NO')"
  assert_eq "$raw" "" "pm list packages 应零输出（rc=0）"
  assert_eq "$vis" "YES" "cmd package list packages 判定安装"
  case_setup users_multi
  assert_text_has "$(core_eval 'um_users')" "XSpace" "um_users 解析（多用户夹具）"
}

# P5 appops 解析：pkg 级与 uid 级两种读法都要取到值
t_appops_parse() {
  case_setup normal
  mock_seed op_RUN_ANY_IN_BACKGROUND ignore
  mock_seed op_SCHEDULE_EXACT_ALARM ignore
  assert_eq "$(core_eval 'pst_appops_value com.mobiletools.systemhelper RUN_ANY_IN_BACKGROUND')" "ignore" "pkg 级 appops"
  assert_eq "$(core_eval 'pst_appops_uid_value 10100 SCHEDULE_EXACT_ALARM')" "ignore" "uid 级 appops"
  assert_eq "$(core_eval 'pst_appops_value com.mobiletools.systemhelper WAKE_LOCK')" "default" "未设置的 op 回 default"
}

# P6 netstats 解析：只算 uid= 行，增量与全机行数都要对
t_netstats_parse() {
  case_setup normal
  mock_seed suspended 1
  mock_seed running 0
  mock_seed netpolicy_uid 10100
  local t0 f0 f1
  f0="$CASE_DIR/t0.txt"
  f1="$CASE_DIR/t1.txt"
  mock_shell "dumpsys netstats detail" >"$f0"
  t0="$(core_eval "sh_net_uid_bytes '$f0' 10100")"
  assert_eq "$t0" "1 1024 2048 8 16" "uid 段求和（entries rb tb rp tp）"
  assert_eq "$(core_eval "sh_net_all_uid_lines '$f0'")" "3" "全机 uid 行数"
  printf '%s\n' "$(cat "$FIXTURES_DIR/netstats_t0.txt")" >"$f1"
  assert_eq "$(core_eval "sh_net_delta '$f0' '$f1' 10100 >/dev/null && echo SAME || echo GROW")" "SAME" "同夹具应零增量"
  printf '%s\n' "$(cat "$FIXTURES_DIR/netstats_t1.txt")" >"$f1"
  assert_eq "$(core_eval "sh_net_delta '$f0' '$f1' 10100 >/dev/null && echo SAME || echo GROW")" "GROW" "有增量必须报 GROW"
}

# P7 sharedUserId：共用 appId 的第二个包必须能被发现
t_shared_uid() {
  case_setup shared_uid
  local su cnt
  su="$(core_eval 'pst_shared_uid com.mobiletools.systemhelper')"
  cnt="$(core_eval 'sh_shell dumpsys package com.mobiletools.systemhelper | grep -c PackageSetting')"
  assert_eq "$su" "com.mobiletools.systemhelper.uid/10100" "pst_shared_uid 归一化"
  assert_eq "$cnt" "2" "共用 uid 的包数量（含 com.mobiletools.companion）"
}

# P8 版本 / 路径 / 分区 / split
t_version_and_path() {
  case_setup normal
  assert_eq "$(core_eval 'pst_version_name com.mobiletools.systemhelper')" "4.0.0-20260729" "versionName"
  assert_eq "$(core_eval 'pst_version_code com.mobiletools.systemhelper')" "34" "versionCode"
  assert_eq "$(core_eval 'pst_path com.mobiletools.systemhelper')" "/system/priv-app/com.mobiletools.systemhelper/com.mobiletools.systemhelper.apk" "pm path"
  assert_eq "$(core_eval 'pst_splits com.mobiletools.systemhelper')" "1" "splits"
  assert_eq "$(core_eval 'pst_is_system com.mobiletools.systemhelper && echo SYS || echo APP')" "SYS" "系统分区判定"
  assert_eq "$(core_eval 'pst_apk_sha256 /system/priv-app/x/x.apk' | wc -c | tr -d " ")" "64" "APK SHA-256 长度"
}

t_case "P1 UID 解析（cmd package list packages -U）" t_uid_primary
t_case "P2 UID 取不到时不许猜" t_uid_unknown_not_guessed
t_case "P3 多用户切段（User 0 / User 999）" t_user_sections
t_case "P4 HyperOS 坑：pm list packages 零输出" t_pm_list_empty_trap
t_case "P5 appops 解析（pkg 级 + uid 级）" t_appops_parse
t_case "P6 netstats 解析（uid= 行口径）" t_netstats_parse
t_case "P7 sharedUserId 解析" t_shared_uid
t_case "P8 版本 / 路径 / 分区 / split" t_version_and_path

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  t_exec_all
  t_summary
  exit $?
fi
