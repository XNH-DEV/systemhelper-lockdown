#!/usr/bin/env bash
# dependency_check.sh — 依赖检查（v2.1 §六 6.3）
#
# 必须查的七项（规格书逐条）：
#   1) device admin       —— 设备管理员/owner，停用会被系统拒绝
#   2) 无障碍服务         —— 被辅助功能绑定，停用会残废功能或触发系统重拉
#   3) 通知监听           —— NotificationListener 绑定
#   4) 运行中进程 / 服务  —— 处置前必须知道它此刻是否在跑
#   5) sharedUserId       —— 共享 UID，动它会波及同 UID 的其它包
#   6) 其它包持有其签名权限 —— 不能单方面停掉被依赖的包
#   7) launcher 入口       —— 是否还能被用户从桌面点开
#
# 用法：
#   bash dependency_check.sh [--pkg PKG] [--user N] [--serial S]
# 也可以被 source（只定义函数，不执行 main）。
set -uo pipefail

SH_RDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SH_CORE_LIB="$(cd "$SH_RDIR/../lib" && pwd)"
SH_RLIB="$SH_RDIR/lib"
if [ -z "${SH_LIBS_READY:-}" ]; then
  SH_LIBS_READY=1
  for SH__f in "$SH_CORE_LIB/common.sh" "$SH_CORE_LIB/adb.sh" "$SH_CORE_LIB/package.sh" \
               "$SH_RLIB/package_state.sh" "$SH_RLIB/user_manager.sh" "$SH_RLIB/safety_guard.sh"; do
    [ -f "$SH__f" ] && . "$SH__f"
  done
fi

DEFAULT_PKG="com.mobiletools.systemhelper"

# ---------------------------------------------------------------------------
# 七项原始读数（每项只输出值，不判定）
# ---------------------------------------------------------------------------
dep_declared_perms() {  # 包自己"定义"的权限（重点看 signature 级）
  # 真机结构（dumpsys package <pkg>）：
  #     declared permissions:
  #       com.mobiletools.systemhelper.permission: prot=signature
  #     requested permissions:
  #       android.permission.INTERNET
  # 只认 declared 段里带 prot= 的行；绝不能把 requested/install 段算进来
  # （之前的宽松写法把 9 个普通权限当"签名权限"，导致持有者数被算成 258，实测真值是 0）
  sh_shell dumpsys package "${1:-}" 2>/dev/null | awk '
    /^[[:space:]]*declared permissions:/ { on = 1; next }
    on && /^[[:space:]]*(requested|install|runtime) permissions:/ { on = 0 }
    on && /^[[:space:]]*[A-Za-z0-9_.]+: prot=/ {
      line = $0
      sub(/^[[:space:]]*/, "", line)
      sub(/: prot=.*/, "", line)
      print line
    }
  ' | sort -u
}

dep_sig_perm_holders() {  # 持有它签名权限的其它包（按 Package[..] 归属）
  local pkg="${1:-}" perms re
  perms="$(dep_declared_perms "$pkg")"
  [ -n "$perms" ] || return 0
  re="$(printf '%s\n' "$perms" | paste -sd'|' -)"
  sh_shell dumpsys package 2>/dev/null | awk -v RE="^[[:space:]]*(${re}):" '
    /^[[:space:]]*Package \[/ {
      cur = $0
      sub(/^[[:space:]]*Package \[/, "", cur)
      sub(/\].*/, "", cur)
    }
    $0 ~ RE && /granted=true/ && cur != "" { print cur }
  ' | sort -u | grep -vx -- "$pkg"
}

dep_device_admin() {  # <pkg> → 1/0
  local d
  d="$(sh_shell dumpsys device_policy 2>/dev/null)"
  case "$d" in
    *"${1:-}"*) printf '1' ;;
    *) printf '0' ;;
  esac
}

dep_a11y() {  # <pkg> → 1/0
  local v
  v="$(sh_shell settings get secure enabled_accessibility_services 2>/dev/null)"
  case "$v" in
    *"${1:-}"*) printf '1' ;;
    *) printf '0' ;;
  esac
}

dep_notif_listener() {  # <pkg> → 1/0
  local v
  v="$(sh_shell settings get secure enabled_notification_listeners 2>/dev/null)"
  case "$v" in
    *"${1:-}"*) printf '1' ;;
    *) printf '0' ;;
  esac
}

dep_launcher() {  # <pkg> → LAUNCHER 意图出现次数
  local n
  n="$(sh_shell dumpsys package "${1:-}" 2>/dev/null | grep -c 'android.intent.category.LAUNCHER')"
  printf '%s' "${n:-0}"
}

dep_shared_uid() { pst_shared_uid "${1:-}"; }

# 给快照用的 KEY=VALUE 块（snapshot.sh 直接吃）
dep_kv() {
  local pkg="${1:-}" holders n
  holders="$(dep_sig_perm_holders "$pkg")"
  n="$(printf '%s' "$holders" | sed '/^$/d' | wc -l | tr -d '[:space:]')"
  printf 'device_admin=%s\n'       "$(dep_device_admin "$pkg")"
  printf 'a11y=%s\n'               "$(dep_a11y "$pkg")"
  printf 'notif_listener=%s\n'     "$(dep_notif_listener "$pkg")"
  printf 'processes=%s\n'          "$(pst_process_count "$pkg")"
  printf 'services=%s\n'           "$(pst_service_count "$pkg")"
  printf 'shared_uid=%s\n'         "$(pst_shared_uid "$pkg")"
  printf 'sig_perm_holders=%s\n'   "${n:-0}"
  printf 'sig_perm_holder_list=%s\n' "$(printf '%s' "$holders" | paste -sd, -)"
  printf 'launcher=%s\n'           "$(dep_launcher "$pkg")"
}

# ---------------------------------------------------------------------------
# 判定（v2.1 §六 6.3：依赖没查清不许写）
# ---------------------------------------------------------------------------
dep_check_all() {  # <pkg> → 每项一条 sh_state；有硬阻断（设备管理员）时返回 1
  local pkg="${1:-}" n holders blocked=0
  sh_log "== 依赖检查（v2.1 §六 6.3）=="

  if [ "$(dep_device_admin "$pkg")" != 0 ]; then
    sh_state "dep:device-admin" UNKNOWN "已激活设备管理员/owner：停用会被系统拒绝，需先手动撤销"
    blocked=1
  else
    sh_state "dep:device-admin" SUCCESS "无 device owner / 管理员引用"
  fi

  if [ "$(dep_a11y "$pkg")" != 0 ]; then
    sh_state "dep:a11y" UNKNOWN "已绑定无障碍服务：停用会残废功能，系统可能重拉"
  else
    sh_state "dep:a11y" SUCCESS "未绑定无障碍"
  fi

  if [ "$(dep_notif_listener "$pkg")" != 0 ]; then
    sh_state "dep:notif-listener" UNKNOWN "已绑定通知监听：停用会静默丢通知"
  else
    sh_state "dep:notif-listener" SUCCESS "未绑定通知监听"
  fi

  n="$(pst_process_count "$pkg")"
  if [ "${n:-0}" -gt 0 ]; then
    sh_state "dep:processes" UNKNOWN "有 ${n} 个进程在跑（处置前先 force-stop）"
  else
    sh_state "dep:processes" SUCCESS "无运行中进程"
  fi

  n="$(pst_service_count "$pkg")"
  if [ "${n:-0}" -gt 0 ]; then
    sh_state "dep:services" UNKNOWN "有 ${n} 处服务引用（dumpsys activity services）"
  else
    sh_state "dep:services" SUCCESS "无运行中服务"
  fi

  n="$(pst_shared_uid "$pkg")"
  if [ -n "$n" ]; then
    sh_state "dep:shared-uid" UNKNOWN "共享 $n：动它会波及同 UID 的其它包"
  else
    sh_state "dep:shared-uid" SUCCESS "无 sharedUserId"
  fi

  holders="$(dep_sig_perm_holders "$pkg")"
  n="$(printf '%s' "$holders" | sed '/^$/d' | wc -l | tr -d '[:space:]')"
  if [ "${n:-0}" -gt 0 ]; then
    sh_state "dep:sig-perm-holders" UNKNOWN "${n} 个包持有其签名权限：$(printf '%s' "$holders" | paste -sd, -)"
  else
    sh_state "dep:sig-perm-holders" SUCCESS "无其它包持有其签名权限"
  fi

  n="$(dep_launcher "$pkg")"
  if [ "${n:-0}" -gt 0 ]; then
    sh_state "dep:launcher" UNKNOWN "有 LAUNCHER 入口（${n} 处）：桌面仍可点开，靠 suspend/force-stop 拦"
  else
    sh_state "dep:launcher" SUCCESS "无 LAUNCHER 入口"
  fi

  return "$blocked"
}

# 卸载/停用前的硬闸门：设备管理员在场就不许往下走
dep_gate_uninstall() {  # <pkg>
  local pkg="${1:-}"
  if [ "$(dep_device_admin "$pkg")" != 0 ]; then
    sh_state "dep:gate" FAILED "BLOCKED(设备管理员已激活：先在系统设置撤管，再谈停用/卸载)"
    return 1
  fi
  sh_state "dep:gate" SUCCESS "无设备管理员阻断"
  return 0
}

# ---------------------------------------------------------------------------
main() {
  local pkg="${PKG:-$DEFAULT_PKG}" user="${USER_ID:-}"
  while [ $# -gt 0 ]; do
    case "$1" in
      --pkg)    pkg="${2:-}"; shift 2 ;;
      --user)   user="${2:-}"; shift 2 ;;
      --serial) SH_SERIAL="${2:-}"; shift 2 ;;
      -h|--help)
        printf '%s\n' "用法: bash dependency_check.sh [--pkg PKG] [--user N] [--serial S]"
        printf '%s\n' "只读：查 device admin / 无障碍 / 通知监听 / 进程 / 服务 / sharedUserId / 签名权限 / launcher"
        return 0 ;;
      *) sh_err "未知参数: $1"; return 2 ;;
    esac
  done
  guard_device
  guard_target_pkg "$pkg"
  user="$(um_resolve_user "$user")"
  sh_log "  目标 $pkg  user=$user  uid=$(pst_uid "$pkg")"
  dep_check_all "$pkg"
  local blocked=$?
  local rc=0
  sh_summary || rc=1
  # 设备管理员是硬阻断（blocked=1），其余 UNKNOWN 只是"有依赖需要人看一眼"
  [ "$blocked" -eq 0 ] || return 1
  return "$rc"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
