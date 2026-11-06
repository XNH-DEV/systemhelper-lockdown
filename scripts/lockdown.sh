#!/usr/bin/env bash
# SystemHelper Lockdown — 无 root 处置脚本（默认目标 com.mobiletools.systemhelper）
#
# 用法:
#   bash lockdown.sh                # 直接处置
#   bash lockdown.sh --dry-run      # 只打印将执行的命令
#   bash lockdown.sh --no-suspend   # 跳过 pm suspend（有些 ROM 上挂起会导致系统弹窗）
#   bash lockdown.sh --pkg <包名> --serial <序列号>
#
# 只碰 PKG 这一个包；默认白名单会拒绝 com.qualcomm.* / com.android.* / com.miui.* / com.google.*
# 除非显式加 --force。

set -u

PKG="com.mobiletools.systemhelper"
SERIAL="${SERIAL:-}"
DRY=0
SUSPEND=1
FORCE=0
LOG_ROOT="./logs"
ADB="${ADB:-adb}"

while [ $# -gt 0 ]; do
  case "$1" in
    --pkg) PKG="$2"; shift 2 ;;
    --serial) SERIAL="$2"; shift 2 ;;
    --dry-run) DRY=1; shift ;;
    --no-suspend) SUSPEND=0; shift ;;
    --force) FORCE=1; shift ;;
    --log-dir) LOG_ROOT="$2"; shift 2 ;;
    -h|--help) sed -n '2,14p' "$0"; exit 0 ;;
    *) echo "未知参数: $1" >&2; exit 2 ;;
  esac
done

case "$PKG" in
  com.qualcomm.*|com.android.*|com.miui.*|com.google.*|android)
    if [ "$FORCE" != 1 ]; then
      echo "拒绝处置 $PKG：命中默认保护名单。确认要动它请加 --force。" >&2
      exit 3
    fi ;;
esac

TS="$(date +%Y%m%d-%H%M%S)"
LOGDIR="$LOG_ROOT/$TS"

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

run() {                       # run <说明> <设备端 shell 命令...>
  local desc="$1"; shift
  local cmd="$*"
  printf '\n[%s]\n  $ adb shell %s\n' "$desc" "$cmd"
  [ "$DRY" = 1 ] && { printf '  (dry-run, 未执行)\n'; return 0; }
  local out rc
  out="$(S "$cmd" 2>&1)"; rc=$?
  if [ -n "$out" ]; then printf '%s\n' "$out" | head -n 6 | sed 's/^/    /'; fi
  printf '  -> rc=%s\n' "$rc"
  return 0
}

# ---------- 0. 前置检查 ----------
say "== SystemHelper Lockdown =="
say "target : $PKG"
say "adb    : $ADB${SERIAL:+ ($SERIAL)}"
say "dry-run: $DRY"

if [ "$DRY" != 1 ]; then
  if ! A get-state >/dev/null 2>&1; then
    say "✗ adb 连不上设备。先跑 adb devices 确认。" >&2; exit 4
  fi
fi

PATHS="$(A shell "pm path $PKG" 2>&1 | tr -d '\r')"
if ! printf '%s' "$PATHS" | grep -q '^package:'; then
  say "✗ 设备上没有 $PKG（pm path 为空）。" >&2; exit 5
fi
say "path   : $(printf '%s' "$PATHS" | head -n1)"

UID_="$(resolve_uid)"
if [ -z "$UID_" ]; then
  say "✗ 解析不到 uid（dumpsys package 里没有 userId=）。" >&2; exit 6
fi
say "uid    : ${UID_:-<未知>}"

# ---------- 1. 存档（改之前先留证据） ----------
if [ "$DRY" != 1 ]; then
  mkdir -p "$LOGDIR"
  A shell "dumpsys package $PKG" > "$LOGDIR/dumpsys-package.txt"  2>&1
  A shell "cmd appops get $PKG"  > "$LOGDIR/appops-before.txt"    2>&1
  A shell "cmd package list packages -d" > "$LOGDIR/pkg-disabled-before.txt" 2>&1
  A shell "cmd package list packages -e" > "$LOGDIR/pkg-enabled-before.txt"  2>&1
  A shell "dumpsys netstats detail"      > "$LOGDIR/netstats-before.txt"     2>&1
  say "存档   : $LOGDIR/"
fi

# ---------- 2. 权限层 ----------
for P in READ_PHONE_STATE ACCESS_FINE_LOCATION ACCESS_COARSE_LOCATION \
         ACCESS_BACKGROUND_LOCATION READ_EXTERNAL_STORAGE BLUETOOTH_CONNECT; do
  run "revoke android.permission.$P" "pm revoke $PKG android.permission.$P"
done
# Android 16+ 新权限：多半撤不掉（rc=0 但值不变），试一下无妨
run "revoke ACCESS_LOCAL_NETWORK（可能无效）" "pm revoke $PKG android.permission.ACCESS_LOCAL_NETWORK"

# ---------- 3. 执行层（appops） ----------
for OP in RUN_ANY_IN_BACKGROUND RUN_IN_BACKGROUND START_FOREGROUND WAKE_LOCK POST_NOTIFICATION SCHEDULE_EXACT_ALARM; do
  run "appops $OP=ignore" "cmd appops set $PKG $OP ignore"
done

# ---------- 4. 网络层 ----------
if [ -n "$UID_" ]; then
  run "netpolicy 拉黑后台流量" "cmd netpolicy add restrict-background-blacklist $UID_"
else
  say "! uid 未知，跳过 netpolicy"
fi

# ---------- 5. 挂起 + 通知限制 ----------
if [ "$SUSPEND" = 1 ]; then
  run "系统级挂起" "pm suspend --user 0 $PKG"
fi
run "隐藏通知（distraction restriction）" "pm set-distracting-restriction --flag hide-notifications --user 0 $PKG"

# ---------- 6. 强停（必须最后做，把 stopped 标记打上） ----------
run "待机标记" "am set-inactive $PKG true"
run "强停" "am force-stop $PKG"

# ---------- 7. 打印结果 ----------
if [ "$DRY" != 1 ]; then
  printf '\n== 处置后状态 ==\n'
  A shell "dumpsys package $PKG" 2>&1 | grep -E 'stopped=|suspended=|distractionFlags=' | sed 's/^ */  /' | head -n 2
  A shell "cmd appops get $PKG" 2>&1 | grep -E 'RUN_ANY_IN_BACKGROUND|RUN_IN_BACKGROUND|START_FOREGROUND|WAKE_LOCK|POST_NOTIFICATION|SCHEDULE_EXACT_ALARM' | sed 's/^ */  /'
  A shell "cmd netpolicy list restrict-background-blacklist" 2>&1 | sed 's/^ */  /'
  A shell "ps -A | grep -i ${PKG##*.}" 2>&1 | sed 's/^ */  /' | head -n 3
fi

cat <<EOF

下一步:
  1) bash verify.sh            # 出验证数据（默认采样 300 秒）
  2) 可选：设置 → 应用 → 应用管理 → SystemHelper → 应用联网
     把 数据-卡1 / 数据-卡2 / WLAN / 后台运行时联网 四个开关全关（唯一能挡住"前台联网"的无 root 手段）
  3) 回滚: bash rollback.sh

EOF
