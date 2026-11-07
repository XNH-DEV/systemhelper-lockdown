#!/usr/bin/env bash
# tests/run_tests.sh — 测试总入口（自动发现 tests/test_*.sh）
#
# 用法:
#   bash tests/run_tests.sh              # 全部
#   bash tests/run_tests.sh --only safety
#   KEEP_ARTIFACTS=1 bash tests/run_tests.sh   # 保留用例现场
#
# 退出码: 0 全过 / 1 有失败 / 2 有失败且存在跳过
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ONLY=""

while [ $# -gt 0 ]; do
  case "$1" in
    --only) ONLY="$2"; shift 2 ;;
    -h|--help) sed -n '2,10p' "$0"; exit 0 ;;
    *) echo "未知参数: $1" >&2; exit 2 ;;
  esac
done

TP=0; TF=0; TS=0; TRUN=0; FAILED_FILES=""

echo "=============================================="
echo " SystemHelper Lockdown · 测试总入口（离线 mock）"
echo " 仓库: $HERE/.."
echo " 真机: 不使用（ADB 被替换为 tests/mock_adb.sh）"
echo "=============================================="

for f in "$HERE"/test_*.sh; do
  [ -f "$f" ] || continue
  base="$(basename "$f" .sh)"
  if [ -n "$ONLY" ]; then
    case "$base" in *"$ONLY"*) ;; *) continue ;; esac
  fi
  TRUN=$((TRUN + 1))
  echo ""
  echo "---- $base ----"
  out="$(bash "$f" 2>&1)"; rc=$?
  # 只打印最后几行（各测试文件自己会打印每例结果）
  printf '%s\n' "$out" | tail -6
  # 解析 "通过 N / 失败 M（跳过 K）"
  line="$(printf '%s\n' "$out" | grep -E '通过 [0-9]+ / 失败 [0-9]+' | tail -1)"
  if [ -n "$line" ]; then
    p="$(printf '%s' "$line" | sed -n 's/.*通过 \([0-9]*\) .*/\1/p')"
    fi_="$(printf '%s' "$line" | sed -n 's/.*失败 \([0-9]*\).*/\1/p')"
    s="$(printf '%s' "$line" | sed -n 's/.*跳过 \([0-9]*\).*/\1/p')"
    TP=$((TP + ${p:-0})); TF=$((TF + ${fi_:-0})); TS=$((TS + ${s:-0}))
  else
    # 没有标准摘要行 → 按退出码记 1 个失败
    if [ "$rc" -ne 0 ]; then
      TF=$((TF + 1)); FAILED_FILES="$FAILED_FILES $base(no-summary)"
    fi
  fi
  [ "$rc" -ne 0 ] && FAILED_FILES="$FAILED_FILES $base"
done

echo ""
echo "=============================================="
echo " 总计: 通过 $TP / 失败 $TF / 跳过 $TS（$TRUN 个测试文件）"
[ -n "$FAILED_FILES" ] && echo " 失败文件:$FAILED_FILES"
echo "=============================================="

if [ "$TF" -gt 0 ]; then
  [ "$TS" -gt 0 ] && exit 2
  exit 1
fi
exit 0
