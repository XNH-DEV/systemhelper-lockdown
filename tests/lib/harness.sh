#!/usr/bin/env bash
# tests/lib/harness.sh — 纯 bash 断言框架（不依赖 bats）
#
# 用法：测试文件写 `t_case "名字" 函数名`；函数里用 assert_* 断言，全部断言跑完再判定。
# 用例函数 return 77 = SKIP（用 t_skip 设置原因）。
# 兼容 macOS 自带 bash 3.2：只用索引数组，不用 mapfile / 关联数组 / 反斜杠续行。

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TESTS_DIR="$REPO_ROOT/tests"
MOCK_ADB="$TESTS_DIR/mock_adb.sh"
FIXTURES_DIR="$TESTS_DIR/fixtures"
# shellcheck disable=SC2034  # 供各 test_*.sh 使用（库级常量）
S_LOCKDOWN="$REPO_ROOT/scripts/lockdown.sh"
S_ROLLBACK="$REPO_ROOT/scripts/rollback.sh"
S_VERIFY="$REPO_ROOT/scripts/verify.sh"
S_RESTRICT="$REPO_ROOT/scripts/restriction/restriction.sh"
L_COMMON="$REPO_ROOT/scripts/lib/common.sh"
L_PKG="$REPO_ROOT/scripts/lib/package.sh"
L_NET="$REPO_ROOT/scripts/lib/network.sh"

# 写命令黑名单：只读/演练断言用它
WRITE_RE='pm (uninstall|disable|disable-user|enable|suspend|unsuspend|clear|revoke|grant|set-permission-flags|clear-permission-flags|set-distracting-restriction|hide|install-existing)|cmd (appops set|netpolicy (add|remove))|am (force-stop|set-inactive)'

T_NAMES=()
T_FNS=()
T_PASS=0
T_FAIL=0
T_SKIP=0
FAILN=0
LAST_MSG=""
SKIP_MSG=""
DEFECT_LIST=""
KEEP_ARTIFACTS="${KEEP_ARTIFACTS:-0}"
CASE_DIR=""
MOCK_LOG=""
MOCK_STATE_DIR=""
MOCK_SCENARIO="normal"
LOGDIR=""
RUN_OUT=""
RUN_RC=0
STDIN_DATA=""
SERIAL_ARG=""
PKG_ARG=""
USER_ARG=""

# ---------- 用例沙箱 ----------
case_cleanup() {
  if [ -n "$CASE_DIR" ] && [ -d "$CASE_DIR" ]; then
    if [ "$KEEP_ARTIFACTS" = "1" ]; then
      printf '[保留] 用例现场: %s\n' "$CASE_DIR" >&2
    else
      rm -rf "$CASE_DIR"
    fi
  fi
  CASE_DIR=""
}

# case_setup [场景名]
case_setup() {
  case_cleanup
  MOCK_SCENARIO="${1:-normal}"
  CASE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/shlock.XXXXXX")"
  MOCK_STATE_DIR="$CASE_DIR/state"
  mkdir -p "$MOCK_STATE_DIR"
  MOCK_LOG="$CASE_DIR/mock.log"
  : >"$MOCK_LOG"
  LOGDIR="$CASE_DIR/logs"
  mkdir -p "$LOGDIR"
  RUN_OUT=""
  RUN_RC=0
  FAILN=0
  LAST_MSG=""
  SKIP_MSG=""
  STDIN_DATA=""
  SERIAL_ARG=""
  PKG_ARG=""
  USER_ARG=""
  export MOCK_SCENARIO MOCK_LOG MOCK_STATE_DIR
  export MOCK_FIXTURES="$FIXTURES_DIR"
}

# 直接写夹具状态（跨 mock 调用持久）
mock_seed() {
  printf '%s' "$2" >"$MOCK_STATE_DIR/$1"
}

state_of() {
  cat "$MOCK_STATE_DIR/$1" 2>/dev/null
}

# 直接问一遍 mock（不经过被测脚本）
mock_shell() {
  (
    export MOCK_SCENARIO MOCK_LOG MOCK_STATE_DIR MOCK_FIXTURES="$FIXTURES_DIR"
    bash "$MOCK_ADB" shell "$1"
  )
}

# 被测脚本的运行环境
_run_target() {
  cd "$REPO_ROOT" || exit 1
  export ADB="$MOCK_ADB" SH_ADB="$MOCK_ADB"
  export LOG_ROOT="$LOGDIR" SH_LOG_DIR="$LOGDIR" SH_QUIET=0
  export MOCK_SCENARIO MOCK_LOG MOCK_STATE_DIR MOCK_FIXTURES="$FIXTURES_DIR"
  if [ -n "$SERIAL_ARG" ]; then
    export SERIAL="$SERIAL_ARG" SH_SERIAL="$SERIAL_ARG"
  fi
  if [ -n "$PKG_ARG" ]; then export PKG="$PKG_ARG"; fi
  if [ -n "$USER_ARG" ]; then export USER_ID="$USER_ARG"; fi
  bash "$@"
}

# run_script <脚本> [参数...]；STDIN_DATA 非空时喂给脚本 stdin（确认串场景）
run_script() {
  if [ -n "$STDIN_DATA" ]; then
    RUN_OUT="$(printf '%s\n' "$STDIN_DATA" | _run_target "$@" 2>&1)"
  else
    RUN_OUT="$(_run_target "$@" </dev/null 2>&1)"
  fi
  RUN_RC=$?
}

# 在 scripts/lib/*.sh 上跑一段代码（解析层单测）
core_eval() {
  (
    cd "$REPO_ROOT" || exit 1
    export SH_ADB="$MOCK_ADB" SH_SERIAL="" SH_QUIET=0 SH_LOG_DIR="$LOGDIR"
    export MOCK_SCENARIO MOCK_LOG MOCK_STATE_DIR MOCK_FIXTURES="$FIXTURES_DIR"
    bash -c '
      for f in common adb package permissions appops network process snapshot report; do
        [ -f "scripts/lib/$f.sh" ] && . "./scripts/lib/$f.sh"
      done
      for f in package_state user_manager safety_guard snapshot verification; do
        [ -f "scripts/restriction/lib/$f.sh" ] && . "./scripts/restriction/lib/$f.sh"
      done
      '"$1"
  ) 2>&1
}

# 最新一条 state.tsv / execution.tsv（restriction.sh 与 lockdown.sh 各自不同）
latest_state_tsv() {
  ls -1t "$LOGDIR"/*/state.tsv "$LOGDIR"/*/execution.tsv 2>/dev/null | head -1
}

state_rows() {
  local t
  t="$(latest_state_tsv)"
  [ -n "$t" ] && cat "$t"
  return 0
}

# ---------- 断言（非致命：累计后统一判） ----------
fail() {
  FAILN=$((FAILN + 1))
  LAST_MSG="$*"
}

assert_eq() {
  if [ "$1" = "$2" ]; then return 0; fi
  fail "${3:-相等断言}: 期望 [$2]，实际 [$1]"
  return 1
}

assert_rc() {
  if [ "$RUN_RC" = "$1" ]; then return 0; fi
  fail "${2:-退出码}: 期望 $1，实际 $RUN_RC"
  return 1
}

assert_rc_nonzero() {
  if [ "$RUN_RC" -ne 0 ]; then return 0; fi
  fail "${1:-退出码}: 期望非 0，实际 0"
  return 1
}

assert_out_has() {
  if printf '%s\n' "$RUN_OUT" | grep -qF -- "$1"; then return 0; fi
  fail "${2:-输出断言}: 输出里找不到 [$1]"
  return 1
}

assert_out_lacks() {
  if printf '%s\n' "$RUN_OUT" | grep -qF -- "$1"; then
    fail "${2:-输出断言}: 输出里不该出现 [$1]"
    return 1
  fi
  return 0
}

assert_text_has() {
  if printf '%s\n' "$1" | grep -qF -- "$2"; then return 0; fi
  fail "${3:-文本断言}: 找不到 [$2]"
  return 1
}

assert_text_lacks() {
  if printf '%s\n' "$1" | grep -qF -- "$2"; then
    fail "${3:-文本断言}: 不该出现 [$2]"
    return 1
  fi
  return 0
}

assert_log_has() {
  if grep -qF -- "$1" "$MOCK_LOG" 2>/dev/null; then return 0; fi
  fail "${2:-MOCK_LOG 断言}: 没有记录 [$1]"
  return 1
}

assert_log_lacks() {
  if grep -qF -- "$1" "$MOCK_LOG" 2>/dev/null; then
    fail "${2:-MOCK_LOG 断言}: 不该记录 [$1]"
    return 1
  fi
  return 0
}

assert_log_count() {
  local n
  n="$(grep -cF -- "$1" "$MOCK_LOG" 2>/dev/null)"
  [ -n "$n" ] || n=0
  assert_eq "$n" "$2" "${3:-MOCK_LOG 计数} [$1]"
}

# 只读/演练断言：MOCK_LOG 里不许出现任何写命令
assert_no_writes() {
  local hits
  hits="$(grep -E "$WRITE_RE" "$MOCK_LOG" 2>/dev/null | grep -v 'UNHANDLED')"
  if [ -z "$hits" ]; then return 0; fi
  fail "${1:-只读断言}: 出现了写命令 -> $(printf '%s' "$hits" | head -3 | tr '\n' ';')"
  return 1
}

# mock 没接住的命令 = 夹具漏洞，必须暴露
assert_mock_complete() {
  local hits
  hits="$(grep -E 'UNHANDLED' "$MOCK_LOG" 2>/dev/null)"
  if [ -z "$hits" ]; then return 0; fi
  fail "${1:-夹具完整性}: mock 未实现 $(printf '%s' "$hits" | head -3 | tr '\n' ';')"
  return 1
}

# state.tsv 断言：<STATE> <action 子串> [说明]
assert_state_has() {
  local rows
  rows="$(state_rows)"
  if printf '%s\n' "$rows" | awk -F'\t' -v s="$1" -v a="$2" '$2 == s && index($3, a) > 0 { f = 1 } END { exit(f ? 0 : 1) }'; then
    return 0
  fi
  fail "${3:-状态断言}: 没有 [$1] $2"
  return 1
}

assert_state_lacks() {
  local rows
  rows="$(state_rows)"
  if printf '%s\n' "$rows" | awk -F'\t' -v s="$1" -v a="$2" '$2 == s && index($3, a) > 0 { f = 1 } END { exit(f ? 0 : 1) }'; then
    fail "${3:-状态断言}: 不该出现 [$1] $2"
    return 1
  fi
  return 0
}

# stdout 行断言（rollback 这类没有 state.tsv 的脚本）
assert_row_has() {
  if printf '%s\n' "$RUN_OUT" | grep -qE "^ *\[$1\] +$2"; then return 0; fi
  fail "${3:-行断言}: 输出里没有 [$1] $2"
  return 1
}

assert_row_lacks() {
  if printf '%s\n' "$RUN_OUT" | grep -qE "^ *\[$1\] +$2"; then
    fail "${3:-行断言}: 输出里不该有 [$1] $2"
    return 1
  fi
  return 0
}

# verify 报告是 TSV：层 / 项目 / 判定 / 证据
latest_verify_report() {
  ls -1t "$LOGDIR"/verify-*.md 2>/dev/null | head -1
}

assert_report_row() {
  local f
  f="$(latest_verify_report)"
  if [ -z "$f" ]; then
    fail "找不到 verify 报告（$LOGDIR）"
    return 1
  fi
  if awk -F'	' -v l="$1" -v i="$2" -v s="$3" '$1 == l && $2 == i && $3 == s { f = 1 } END { exit(f ? 0 : 1) }' "$f"; then
    return 0
  fi
  fail "${4:-报告断言}: 没有 $1/$2=$3"
  return 1
}

# ---------- SKIP / 缺陷登记 ----------
t_skip() {
  SKIP_MSG="$*"
  return 77
}

t_defect() {
  DEFECT_LIST="${DEFECT_LIST}
  - $*"
}

# 主脚本是否已接 v2.1 契约（决定"失败必须非 0"这类断言该 FAIL 还是 SKIP）
has_state_contract() {
  grep -qE 'sh_state|lib/common\.sh' "$1" 2>/dev/null
}

# ---------- 用例调度 ----------
t_case() {
  T_NAMES[${#T_NAMES[@]}]="$1"
  T_FNS[${#T_FNS[@]}]="$2"
}

t_exec() {
  local name="$1"
  local fn="$2"
  local rc=0
  FAILN=0
  LAST_MSG=""
  SKIP_MSG=""
  "$fn"
  rc=$?
  case_cleanup
  if [ "$rc" = 77 ]; then
    T_SKIP=$((T_SKIP + 1))
    printf 'SKIP %s — %s\n' "$name" "${SKIP_MSG:-未说明}"
  elif [ "$rc" -ne 0 ] || [ "$FAILN" -gt 0 ]; then
    T_FAIL=$((T_FAIL + 1))
    printf 'FAIL %s — %s\n' "$name" "${LAST_MSG:-用例返回 $rc}"
  else
    T_PASS=$((T_PASS + 1))
    printf 'PASS %s\n' "$name"
  fi
}

t_exec_all() {
  local i=0
  local n=${#T_NAMES[@]}
  while [ "$i" -lt "$n" ]; do
    case "${T_ONLY:-}" in
      "") t_exec "${T_NAMES[$i]}" "${T_FNS[$i]}" ;;
      *)
        case "${T_NAMES[$i]}" in
          *"${T_ONLY}"*) t_exec "${T_NAMES[$i]}" "${T_FNS[$i]}" ;;
        esac
        ;;
    esac
    i=$((i + 1))
  done
}

t_summary() {
  printf '\n'
  if [ -n "$DEFECT_LIST" ]; then
    printf '已知缺陷（主脚本未改造，相关用例 SKIP）:%s\n\n' "$DEFECT_LIST"
  fi
  printf '通过 %d / 失败 %d（跳过 %d）\n' "$T_PASS" "$T_FAIL" "$T_SKIP"
  [ "$T_FAIL" -eq 0 ]
}
