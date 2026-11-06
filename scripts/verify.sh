#!/usr/bin/env bash
# verify.sh — 验证处置效果并给出可复现的数据
#
# 用法:
#   bash verify.sh                  # 默认采样 300 秒
#   bash verify.sh --seconds 60     # 缩短采样
#   bash verify.sh --pkg <包名> --serial <序列号>

set -u

PKG="com.mobiletools.systemhelper"
SERIAL="${SERIAL:-}"
SECONDS_=300
ADB="${ADB:-adb}"
OUT="./logs"

while [ $# -gt 0 ]; do
  case "$1" in
    --pkg) PKG="$2"; shift 2 ;;
    --serial) SERIAL="$2"; shift 2 ;;
    --seconds) SECONDS_="$2"; shift 2 ;;
    --out) OUT="$2"; shift 2 ;;
    -h|--help) sed -n '2,8p' "$0"; exit 0 ;;
    *) echo "未知参数: $1" >&2; exit 2 ;;
  esac
done

A() { if [ -n "$SERIAL" ]; then "$ADB" -s "$SERIAL" "$@"; else "$ADB" "$@"; fi; }
S() { A shell "$@"; }

resolve_uid() {
  local u
  u="$(A shell "cmd package list packages -U $PKG" 2>&1 | grep -oE 'uid:[0-9]+' | head -n1 | tr -dc '0-9')"
  [ -z "$u" ] && u="$(A shell "dumpsys package $PKG" 2>&1 | grep -m1 -oE 'userId=[0-9]+' | tr -dc '0-9')"
  [ -z "$u" ] && u="$(A shell "dumpsys package $PKG" 2>&1 | grep -m1 -oE 'uid=[0-9]+' | tr -dc '0-9')"
  printf '%s' "$u"
}
say() { printf '%s\n' "$*"; }

TS="$(date +%Y%m%d-%H%M%S)"
mkdir -p "$OUT"
T0F="$OUT/netstats-T0-$TS.txt"
T1F="$OUT/netstats-T1-$TS.txt"

if ! A get-state >/dev/null 2>&1; then say "✗ adb 连不上设备" >&2; exit 4; fi

UID_="$(resolve_uid)"
[ -z "$UID_" ] && { say "✗ 解析不到 uid（包不存在？）" >&2; exit 5; }

say "== 验证 $PKG (uid=$UID_) =="

# ---------- 1. 进程 ----------
PROC="$(S "ps -A | grep -i ${PKG##*.}" 2>&1 | tr -d '\r')"
if [ -z "$PROC" ]; then PROC_R="PASS 无进程"; else PROC_R="FAIL 仍有进程"; fi

# ---------- 2. 包状态 ----------
FLAGS="$(S "dumpsys package $PKG" 2>&1 | grep -m1 'User 0:' | tr -d '\r')"
flag() { printf '%s' "$FLAGS" | grep -oE "$1=[a-z0-9]+" | head -n1 | cut -d= -f2; }
STOPPED="$(flag stopped)"; SUSP="$(flag suspended)"; DISTR="$(flag distractionFlags)"

# ---------- 3. appops ----------
AO="$(S "cmd appops get $PKG" 2>&1 | tr -d '\r')"
ao() { printf '%s' "$AO" | grep -E "^$1:" | head -n1 | sed 's/.*: //;s/;.*//'; }
AO_BG="$(ao RUN_ANY_IN_BACKGROUND)"; AO_SF="$(ao START_FOREGROUND)"; AO_EX="$(ao SCHEDULE_EXACT_ALARM)"

# ---------- 4. netpolicy ----------
NP="$(S "cmd netpolicy list restrict-background-blacklist" 2>&1 | tr -d '\r')"
case "$NP" in *"$UID_"*) NP_R="PASS 已拉黑";; *) NP_R="FAIL 未拉黑";; esac

# ---------- 5. alarm ----------
AL="$(S "dumpsys alarm" 2>&1 | tr -d '\r')"
# 注意：dumpsys alarm 里不是 uid，而是 u<user>a<appId>，appId = uid - 10000（应用 uid 从 10000 起）
if [ "$UID_" -gt 10000 ]; then APPID=$((UID_ - 10000)); else APPID="$UID_"; fi
if printf '%s' "$AL" | grep -A30 'Restricted packages' | grep -q "$PKG"; then
  FSB="PASS force-standby"
else
  FSB="WARN 未见 force-standby"
fi
if printf '%s' "$AL" | grep 'Last OP_SCHEDULE_EXACT_ALARM' | grep -q "u0a${APPID}:ignore"; then
  EXA="PASS exact-alarm 已禁"
else
  EXA="WARN exact-alarm 未禁"
fi

# ---------- 6. 流量采样 ----------
sum_uid() {   # sum_uid <file> -> "entries rb tb"
  awk -v U="uid=$UID_ " '
    /^  ident=/ { on = (index($0, U) > 0) && (index($0, "tag=0x0") > 0); next }
    on && /st=/ {
      for (i = 1; i <= NF; i++) { split($i, p, "=")
        if (p[1] == "rb") rb += p[2]; else if (p[1] == "tb") tb += p[2]
        else if (p[1] == "rp") rp += p[2]; else if (p[1] == "tp") tp += p[2] }
      n++
    }
    END { printf "%d %d %d %d %d\n", n, rb, tb, rp, tp }
  ' "$1"
}
count_all() { grep -cE 'uid=[0-9]+ set=' "$1" 2>/dev/null || echo 0; }

S "dumpsys netstats detail" > "$T0F" 2>&1
set -- $(sum_uid "$T0F"); E0=$1; RB0=$2; TB0=$3; RP0=$4; TP0=$5
ALL0="$(count_all "$T0F")"

say "采样中 … ${SECONDS_} 秒（窗口内请勿主动打开这个 App）"
sleep "$SECONDS_"

S "dumpsys netstats detail" > "$T1F" 2>&1
set -- $(sum_uid "$T1F"); E1=$1; RB1=$2; TB1=$3; RP1=$4; TP1=$5
ALL1="$(count_all "$T1F")"

D_RB=$((RB1 - RB0)); D_TB=$((TB1 - TB0)); D_RP=$((RP1 - RP0)); D_TP=$((TP1 - TP0))
if [ "$E1" = 0 ] && [ "$E0" = 0 ]; then
  TRAF_R="PASS 窗口内 0 条记录（0 字节）"
elif [ "$D_RB" -eq 0 ] && [ "$D_TB" -eq 0 ] && [ "$D_RP" -eq 0 ] && [ "$D_TP" -eq 0 ]; then
  TRAF_R="PASS 增量 0 字节（历史记录仍在）"
else
  TRAF_R="FAIL 有增量"
fi

cat <<EOF

== 结果 ==

[执行]   进程           : $PROC_R
[执行]   stopped        : ${STOPPED:-?}    suspended: ${SUSP:-?}    distractionFlags: ${DISTR:-?}
[执行]   RUN_ANY_IN_BG  : ${AO_BG:-?}    START_FOREGROUND: ${AO_SF:-?}    EXACT_ALARM: ${AO_EX:-?}
[网络]   netpolicy      : $NP_R
[时钟]   force-standby  : $FSB    $EXA
[流量]   T0             : entries=$E0 rb=$RB0 tb=$TB0 rp=$RP0 tp=$TP0 （全机 uid 行 $ALL0）
[流量]   T1(+${SECONDS_}s)     : entries=$E1 rb=$RB1 tb=$TB1 rp=$RP1 tp=$TP1 （全机 uid 行 $ALL1）
[流量]   增量           : rb=$D_RB tb=$D_TB rp=$D_RP tp=$D_TP  ->  $TRAF_R
[口径]   全机 uid 行数从 $ALL0 → $ALL1（>0 变化说明 netstats 采集本身是活的，0 增量才有意义）
[原始]   $T0F  /  $T1F

EOF

# 退出码：进程为 PASS 且流量为 PASS 才算通过
case "$PROC_R$TRAF_R" in
  PASS*PASS*) exit 0 ;;
  *) exit 1 ;;
esac
