#!/usr/bin/env bash
# scripts/preflight.sh — 前置检查（不改任何状态）
#
# 检查：adb / 设备数量 / 目标包 / 保护名单 / 系统应用属性 / 依赖面 / 工具链
# 退出码: 0 全部通过  1 有阻断项  2 有告警
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/common.sh
. "$HERE/lib/common.sh"
# shellcheck source=lib/adb.sh
. "$HERE/lib/adb.sh"
# shellcheck source=lib/package.sh
. "$HERE/lib/package.sh"
# shellcheck source=lib/process.sh
. "$HERE/lib/process.sh"

PKG="${PKG:-com.mobiletools.systemhelper}"
USER_ID="${USER_ID:-0}"
BLOCK=0
WARN=0

while [ $# -gt 0 ]; do
  case "$1" in
    --pkg)    PKG="$2"; shift 2 ;;
    --user)   USER_ID="$2"; shift 2 ;;
    --serial) SH_SERIAL="$2"; shift 2 ;;
    -h|--help) sed -n '2,5p' "$0"; exit 0 ;;
    *) sh_die "未知参数: $1" 2 ;;
  esac
done

ok()   { printf '[通过] %s\n' "$*"; }
bad()  { printf '[阻断] %s\n' "$*"; BLOCK=$((BLOCK + 1)); }
warn() { printf '[告警] %s\n' "$*"; WARN=$((WARN + 1)); }

echo "== 前置检查 =="

sh_have adb && ok "adb 在 PATH" || bad "找不到 adb（可用 ADB=/path/to/adb）"
[ -n "${SH_ADB:-}" ] && sh_have "$SH_ADB" && ok "ADB=$SH_ADB 可执行"

sh_pick_device >/dev/null 2>&1 && ok "设备 $SH_SERIAL 在线" || bad "设备不可用（用 SERIAL= 指定）"

if sh_pkg_exists "$PKG"; then
  ok "目标包存在: $(sh_pkg_path "$PKG")"
else
  bad "设备上没有 $PKG"
fi

if sh_is_protected "$PKG"; then
  bad "$PKG 命中保护名单（拒绝继续）"
else
  ok "$PKG 不在保护名单"
fi

if sh_pkg_is_system "$PKG" 2>/dev/null; then
  warn "目标位于系统分区（/system|/product|/system_ext）→ 无 root 无法真正卸载，只能冻结"
fi

if [ "$(sh_pkg_uid "$PKG")" = "" ]; then
  warn "解析不到 UID（后续网络/AppOps 步骤会跳过）"
else
  ok "UID=$(sh_pkg_uid "$PKG")"
fi

sh_users | sed 's/^/      用户: /'

if sh_pkg_installed_for "$PKG" "$USER_ID"; then
  ok "user $USER_ID 已安装该包"
else
  warn "user $USER_ID 未安装该包（可能已按用户卸载）"
fi

n_admin="$(sh_shell dumpsys device_policy | grep -cF "$PKG")"
n_a11y="$(sh_shell settings get secure enabled_accessibility_services | grep -cF "$PKG")"
n_notif="$(sh_shell settings get secure enabled_notification_listeners | grep -cF "$PKG")"
[ "$n_admin" -eq 0 ] && ok "不是设备管理员" || bad "被注册为设备管理员（先解除再处置）"
[ "$n_a11y" -eq 0 ]  && ok "没有无障碍服务" || warn "存在无障碍服务注册"
[ "$n_notif" -eq 0 ] && ok "没有通知监听" || warn "存在通知监听注册"

sh_have shellcheck && ok "shellcheck 可用" || warn "无 shellcheck（CI 才需要）"
sh_have jq && ok "jq 可用" || warn "无 jq（快照解析能力受限，不影响处置）"

echo ""
echo "阻断 $BLOCK 项 / 告警 $WARN 项"
[ "$BLOCK" -gt 0 ] && exit 1
[ "$WARN" -gt 0 ] && exit 2
exit 0
