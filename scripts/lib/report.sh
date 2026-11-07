#!/usr/bin/env bash
# lib/report.sh — 分层报告（v2.0 2.2 A–F 六层，v2.1 PASS/FAIL/WARN/UNKNOWN）
# 依赖：common.sh
#
# 六层：A 执行状态 / B 权限状态 / C 定时与后台 / D 网络策略 / E 流量观测 / F 长时运行
# 每层单独出结论，禁止用一个 PASS 覆盖全部。

SH_RPT_FILE=""

sh_report_init() {  # <file>
  SH_RPT_FILE="$1"
  : >"$SH_RPT_FILE"
  sh_rpt "SystemHelper Lockdown 验证报告"
  sh_rpt "生成时间: $(sh_ts)"
  sh_rpt ""
}

sh_rpt() { printf '%s\n' "$*" >>"${SH_RPT_FILE:-/dev/stdout}"; [ "${SH_RPT_FILE:-}" = "" ] && printf '%s\n' "$*"; return 0; }

# sh_row <层> <项目> <PASS|FAIL|WARN|UNKNOWN> <证据>
sh_row() {
  printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" >>"${SH_RPT_FILE:-/dev/stdout}"
  [ "${SH_RPT_FILE:-}" = "" ] && printf '[%s] %-22s %-8s %s\n' "$1" "$2" "$3" "$4"
  return 0
}

sh_report_table() {
  : >"${SH_RPT_FILE:-/dev/stdout}" 2>/dev/null
}

sh_report_write_group() {  # <layer> <title>
  sh_rpt ""
  sh_rpt "== $1 $2 =="
}

# 最终汇总表：按层统计
sh_report_summary() {
  local f="${SH_RPT_FILE:-}"
  sh_rpt ""
  sh_rpt "== 汇总 =="
  if [ -n "$f" ] && [ -s "$f" ]; then
    awk -F'\t' 'NF==4 && $3 ~ /^(PASS|FAIL|WARN|UNKNOWN)$/ {c[$1" "$3]++} END{for (k in c) print k"\t"c[k]}' "$f" | sort | sed 's/^/  /' | tee -a "$f" >/dev/null
    awk -F'\t' 'NF==4 && $3 ~ /^(PASS|FAIL|WARN|UNKNOWN)$/ {c[$3]++} END{printf "  PASS=%d FAIL=%d WARN=%d UNKNOWN=%d\n", c["PASS"]+0, c["FAIL"]+0, c["WARN"]+0, c["UNKNOWN"]+0}' "$f" | tee -a "$f"
  fi
}

# 退出码：有 FAIL → 1；全 UNKNOWN/WARN → 2（表示"无法证明"而不是"失败"）
sh_report_exit_code() {
  local f="${SH_RPT_FILE:-}"
  [ -z "$f" ] && return 0
  if grep -q $'\tFAIL\t' "$f" 2>/dev/null; then return 1; fi
  if ! grep -q $'\tPASS\t' "$f" 2>/dev/null; then return 2; fi
  return 0
}
