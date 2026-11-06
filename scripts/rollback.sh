#!/usr/bin/env bash
# rollback.sh — 反向撤掉 lockdown.sh 做过的所有改动
#
# 用法: bash rollback.sh [--pkg <包名>] [--serial <序列号>] [--dry-run]

set -u

PKG="com.mobiletools.systemhelper"
SERIAL="${SERIAL:-}"
DRY=0
ADB="${ADB:-adb}"

while [ $# -gt 0 ]; do
  case "$1" in
    --pkg) PKG="$2"; shift 2 ;;
    --serial) SERIAL="$2"; shift 2 ;;
    --dry-run) DRY=1; shift ;;
    -h|--help) sed -n '2,5p' "$0"; exit 0 ;;
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

run() {
  local desc="$1"; shift
  local cmd="$*"
  printf '\n[%s]\n  $ adb shell %s\n' "$desc" "$cmd"
  [ "$DRY" = 1 ] && { printf '  (dry-run)\n'; return 0; }
  local out rc
  out="$(S "$cmd" 2>&1)"; rc=$?
  [ -n "$out" ] && printf '%s\n' "$out" | head -n 4 | sed 's/^/    /'
  printf '  -> rc=%s\n' "$rc"
  return 0
}

say() { printf '%s\n' "$*"; }

if [ "$DRY" != 1 ] && ! A get-state >/dev/null 2>&1; then
  say "✗ adb 连不上设备" >&2; exit 4
fi

UID_="$(resolve_uid)"
say "== rollback $PKG (uid=${UID_:-?}) =="

# 1. 解挂起 / 清通知限制
run "解除挂起" "pm unsuspend --user 0 $PKG"
run "清除 distraction 限制" "pm set-distracting-restriction --flag 0 --user 0 $PKG"

# 2. appops 还原成 default
for OP in RUN_ANY_IN_BACKGROUND RUN_IN_BACKGROUND START_FOREGROUND WAKE_LOCK POST_NOTIFICATION SCHEDULE_EXACT_ALARM; do
  run "appops $OP=default" "cmd appops set $PKG $OP default"
done

# 3. 网络策略
if [ -n "$UID_" ]; then
  run "移出后台流量黑名单" "cmd netpolicy remove restrict-background-blacklist $UID_"
fi

# 4. 待机标记
run "清除待机标记" "am set-inactive $PKG false"

# 5. 权限（特权权限可能被拒，属正常）
for P in READ_PHONE_STATE ACCESS_FINE_LOCATION ACCESS_COARSE_LOCATION \
         ACCESS_BACKGROUND_LOCATION READ_EXTERNAL_STORAGE BLUETOOTH_CONNECT; do
  run "grant android.permission.$P" "pm grant $PKG android.permission.$P"
done

cat <<EOF

注意:
  * 本方案从未卸载任何东西，所以不需要 cmd package install-existing。
  * 特权权限（READ_PRIVILEGED_PHONE_STATE 等）pm grant 会被拒；重启一次通常由系统按默认值重新授予。
  * 若你手动关过 MIUI「联网控制」的四个开关，需要自己再打开。
EOF
