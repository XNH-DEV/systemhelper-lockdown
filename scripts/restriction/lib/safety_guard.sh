#!/usr/bin/env bash
# lib/safety_guard.sh — 安全闸门（v2.1 §六 6.1 / §六 6.4 / §九 9.1）
# 依赖：common.sh adb.sh package.sh package_state.sh user_manager.sh
#
# 三道前置闸门，任何写模式都必须先过：
#   1) guard_device      —— 设备可达（多设备未指定 SERIAL 直接拒绝，不"随便挑一台"）
#   2) guard_target_pkg  —— 保护名单 + 硬保护 + 存在性
#   3) guard_confirm_*   —— 双重确认（必须原样输入整串）
#
# 以及一个 dry-run 执行器 sg_shell：dry-run 时只打印命令，绝不落到设备上。
set -uo pipefail

: "${SH_DRY_RUN:=0}"

# ---------------------------------------------------------------------------
# 闸门 1：设备
# ---------------------------------------------------------------------------
guard_device() {
  local adb_bin="${SH_ADB:-adb}" st
  if ! sh_have "$adb_bin"; then
    sh_die "找不到 adb（SH_ADB=$adb_bin）。先装 platform-tools 或设 ADB=/path/to/adb；没有设备时无法读数，audit/plan 同样要求真机" 3
  fi
  # sh_pick_device 内部：0 台 → exit 4；>1 台且未指定 → exit 4
  sh_pick_device
  st="$(sh_adb -s "$SH_SERIAL" get-state 2>/dev/null | tr -d '\r')"
  if [ "$st" != "device" ]; then
    sh_die "设备 $SH_SERIAL 状态=${st:-unknown}（未连接/未授权/offline）" 4
  fi
  sh_log "  设备 $SH_SERIAL 就绪"
}

# ---------------------------------------------------------------------------
# 闸门 2：目标包（保护名单优先于一切参数 —— v2.1 §九 9.1）
# ---------------------------------------------------------------------------
# 只查保护名单，不查存在性（恢复场景里包可能已被卸载）
guard_protected_only() {
  local pkg="${1:-}"
  if [ -z "$pkg" ]; then
    sh_die "未指定目标包名：用 --pkg 或 PKG=" 2
  fi
  # 硬保护：与高通 SYSTEMHELPER 同名的系统组件，一律不可处置
  if [ "$pkg" = "$SH_EXPLICIT_BAN" ]; then
    sh_die "BLOCKED: $pkg 是硬保护项（v2.1 §九 9.1），永不处置" 3
  fi
  if sh_is_protected "$pkg"; then
    sh_die "BLOCKED: $pkg 命中保护名单（v2.1 §九 9.1）：系统核心 / 安装器 / 权限管理 / SystemUI / 设置 / 电话 / 桌面 / 高通组件" 3
  fi
  return 0
}

guard_target_pkg() {
  local pkg="${1:-}" paths
  guard_protected_only "$pkg"
  # 存在性判定：pm path 比 pm list packages 可靠（HyperOS 上后者 rc=0 零输出，README §3）
  paths="$(sh_shell pm path "$pkg" 2>/dev/null)"
  case "$paths" in
    *"package:"*) : ;;
    *) sh_die "BLOCKED: 设备上没有 $pkg（pm path 无 package: 行）" 4 ;;
  esac
  sh_log "  目标 $pkg 通过保护名单与存在性检查"
}

# ---------------------------------------------------------------------------
# 闸门 3：双重确认（v2.1 §六 6.4）
# ---------------------------------------------------------------------------
guard_confirm_exact() {  # <确认串> <动作说明>
  local want="${1:-}" what="${2:-该操作}"
  sh_log ""
  sh_log "双重确认：即将执行 ${what}，必须原样输入下面的整串（v2.1 §六 6.4）"
  if ! sh_confirm_exact "$want"; then
    sh_err "确认串不匹配或未输入 → 已中止，设备未做任何写操作"
    return 5
  fi
  sh_log "  确认通过"
  return 0
}

guard_confirm_uninstall() {  # <pkg> <user>
  guard_confirm_exact "UNINSTALL ${1:-} USER ${2:-0}" "用户级卸载 $1（user $2）"
}

# ---------------------------------------------------------------------------
# 快照闸门（v2.1 §六 6.5：卸载前必须有快照）
# ---------------------------------------------------------------------------
guard_snapshot_ready() {
  [ -n "${SNAP_DIR:-}" ] || { sh_err "没有快照目录：写操作前必须先快照"; return 6; }
  [ -f "$SNAP_DIR/snapshot.kv" ] || { sh_err "快照不完整（缺 snapshot.kv）：$SNAP_DIR"; return 6; }
  return 0
}

# ---------------------------------------------------------------------------
# dry-run 执行器：SH_DRY_RUN=1 时只打印，不碰设备
# ---------------------------------------------------------------------------
sg_shell() {
  if [ "${SH_DRY_RUN:-0}" = 1 ]; then
    sh_log "    [dry-run] adb shell $*"
    return 0
  fi
  sh_shell "$@"
}

# 统一退出码说明（写进 usage，方便排错）。注意：不能用 UID 做变量名，bash 里 UID 是只读内建变量。
sh_exit_code_doc() {
  sh_log "  退出码：0 成功 / 1 有 FAILED 或 UNKNOWN / 2 参数错 / 3 缺依赖或保护名单 / 4 设备或包不可用 / 5 确认串不匹配 / 6 快照不可用"
}
sg_exit_code_doc() { sh_exit_code_doc; }
