#!/usr/bin/env bash
# restriction.sh — SystemHelper Lockdown v2.1 · 软件处置系统统一入口
#
# 七个模式（第一个位置参数；**默认 audit = 只读**）：
#   audit      只读体检：把真机姿态读出来，不改设备
#   plan       只出方案：按真机读数给出每层将执行的命令与预期结果（不改设备）
#   restrict   执行选定级别 + 冻结组合，逐条回读（默认级别 1,2,3）
#   disable    L4 指定用户下停用（本机预期被系统拦，如实上报）
#   uninstall  L5 指定用户下卸载（快照 → 依赖闸门 → 双重确认）
#   restore    第六等级恢复（只恢复 changed.list 登记过的项，原值取快照）
#   verify     验证是否真的生效
#
# 选项：
#   --pkg PKG        目标包名，默认 com.mobiletools.systemhelper
#   --user N         目标用户，默认当前用户（绝不硬编码 user 0 —— v2.1 §六 6.2）
#   --uid N          覆盖 UID（默认运行时解析）
#   --serial S       指定设备（多设备必填，否则 sh_pick_device 直接拒绝）
#   --levels L       配合 restrict：默认 1,2,3；可给 1,2,3,4,5（4/5 本机预期被拦）
#   --no-clear       冻结时跳过 pm clear（保留应用数据）
#   --no-freeze      完全跳过冻结组合（只做 --levels 选定的层）
#   --snapshot DIR   配合 restore：显式指定快照目录
#   --for MODE       配合 verify：restrict|freeze|disable|uninstall|restore|perm|background|network|suspend|all
#   --dry-run        写模式只打印命令，不落设备
#   --assume-yes     跳过交互确认（会打印确认串）；仅在明确知情时用
#   --log-root D     日志根目录，默认 ./logs
#   --quiet          静音（只保留 stderr 警告/错误）
#
# 环境变量：PKG / USER_ID / SERIAL / ADB / LOG_ROOT / LEVELS / SNAPSHOT / SH_ASSUME_YES
#
# 硬纪律（v2.1）：
#   * 默认只读；写操作必须显式给模式名（没给模式就是 audit）
#   * 任何模式都先 sh_pick_device + sh_is_protected（写操作更是必须）
#   * 系统拒绝 → FAILED + BLOCKED(原因)；回读不到 → UNKNOWN；绝不把没生效写成 SUCCESS
#   * 多用户：所有写操作带 --user $USER_ID；dumpsys 读数按 "^    User <id>:" 精确切段
set -uo pipefail

SH_RDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SH_CORE_LIB="$(cd "$SH_RDIR/../lib" && pwd)"
SH_RLIB="$SH_RDIR/lib"
if [ -z "${SH_LIBS_READY:-}" ]; then
  SH_LIBS_READY=1
  for SH__f in "$SH_CORE_LIB/common.sh" "$SH_CORE_LIB/adb.sh" "$SH_CORE_LIB/package.sh" \
               "$SH_RLIB/package_state.sh" "$SH_RLIB/user_manager.sh" "$SH_RLIB/safety_guard.sh" \
               "$SH_RLIB/snapshot.sh" "$SH_RLIB/verification.sh" \
               "$SH_RDIR/dependency_check.sh" "$SH_RDIR/permission_restrict.sh" \
               "$SH_RDIR/background_restrict.sh" "$SH_RDIR/network_restrict.sh" \
               "$SH_RDIR/disable_package.sh" "$SH_RDIR/uninstall_user.sh" \
               "$SH_RDIR/restore_package.sh"; do
    [ -f "$SH__f" ] && . "$SH__f"
  done
fi

DEFAULT_PKG="com.mobiletools.systemhelper"
SH_MODES="audit plan restrict disable uninstall restore verify"

PKG="${PKG:-$DEFAULT_PKG}"
USER_ID="${USER_ID:-}"
SH_UID="${SH_UID:-}"
SH_SERIAL="${SH_SERIAL:-${SERIAL:-}}"
SH_ADB="${SH_ADB:-${ADB:-adb}}"
LOG_ROOT="${LOG_ROOT:-./logs}"
LEVELS="${LEVELS:-1,2,3}"
FREEZE="${FREEZE:-1}"
DO_CLEAR="${DO_CLEAR:-1}"
SNAPSHOT="${SNAPSHOT:-}"
VERIFY_FOR="${VERIFY_FOR:-all}"
SH_DRY_RUN="${SH_DRY_RUN:-0}"
MODE=""

# ---------------------------------------------------------------------------
# 退出码说明：入口自带一份，不依赖 lib 的加载顺序（lib 里也有同名实现，行为一致）
sh_exit_code_doc() {
  sh_log "退出码: 0=全部 SUCCESS 1=有 FAILED 2=有 UNKNOWN 3=保护名单拒绝 4=设备/参数错误 5=确认串不匹配 6=快照问题"
}

usage() {
  sed -n '2,40p' "$0" | sed -n '/^set -uo pipefail/q;p' | sed 's/^# \{0,1\}//'
  sh_exit_code_doc
}

log_init() {  # <mode>
  local mode="${1:-audit}" ts dir
  ts="$(sh_stamp)"
  dir="${LOG_ROOT}/${mode}_${ts}"
  if ! mkdir -p "$dir"; then
    sh_err "无法创建日志目录 $dir"
    return 6
  fi
  SH_LOG_DIR="$dir"
  SH_STATE_FILE="$dir/state.tsv"
  : >"$SH_STATE_FILE"
  # 快照根与运行日志分离：restore 要能跨运行找到历史快照
  SNAP_ROOT="${SNAP_ROOT:-$LOG_ROOT/snapshots}"
  sh_log "== SystemHelper Lockdown v2.1 · 模式 $mode =="
  sh_log "  时间 $(sh_ts)"
  sh_log "  日志 $dir"
  sh_log "  快照根 $SNAP_ROOT"
  return 0
}

# 所有模式共用：设备闸门 + 保护名单闸门 + 用户/UID 解析
resolve_context() {
  guard_device
  case "$MODE" in
    # 恢复场景里包可能已被卸载 → 只查保护名单，不要求 pm path 存在
    restore) guard_protected_only "$PKG" ;;
    *)       guard_target_pkg "$PKG" ;;
  esac
  USER_ID="$(um_resolve_user "$USER_ID")"
  if [ -z "$SH_UID" ]; then
    SH_UID="$(pst_uid "$PKG")"
  fi
  sh_log "  设备 $(sh_shell getprop ro.product.model) / $(pst_os_version) / API $(pst_api_level) / serial $SH_SERIAL"
  sh_log "  目标 $PKG  user=$USER_ID  uid=${SH_UID:-?}"
  um_show_users
  return 0
}

# ---------------------------------------------------------------------------
# 1) audit —— 只读
# ---------------------------------------------------------------------------
do_audit() {
  local ins en p g op v apk sha
  sh_log ""
  sh_log "== audit（只读：不写设备，只落日志）=="
  apk="$(pst_path "$PKG")"
  sha="$(pst_apk_sha256 "$apk")"
  if pst_installed "$PKG" "$USER_ID"; then ins=true; else ins=false; fi
  en="$(pst_enabled_code "$PKG" "$USER_ID")"
  sh_log "  安装 installed=$ins  enabled=$en($(pst_enabled_label "$en"))  suspended=$(pst_flag "$PKG" "$USER_ID" suspended)  stopped=$(pst_flag "$PKG" "$USER_ID" stopped)"
  sh_log "  APK $apk  splits=$(pst_splits "$PKG")  系统分区=$(pst_is_system "$PKG" && echo yes || echo no)"
  sh_log "  版本 $(pst_version_name "$PKG") ($(pst_version_code "$PKG"))"
  sh_log "  签名 SHA-256 ${sha:-<取不到：设备端 sha256sum 失败>}"
  sh_log "  运行时权限（只列本机有记录的）："
  for p in $SH_DANGEROUS_PERMS $SH_FORBIDDEN_PERM; do
    g="$(pst_perm_granted "$PKG" "$USER_ID" "$p")"
    if [ -n "$g" ]; then
      sh_log "    $p = $g  flags=[$(pst_perm_flags "$PKG" "$USER_ID" "$p")]"
    fi
  done
  sh_log "  AppOps（目标集，UID 级优先）："
  for op in $SH_BG_OPS_ALL; do
    v="$(pst_appops_uid_value "$SH_UID" "$op")"
    [ -z "$v" ] && v="$(pst_appops_value "$PKG" "$op")"
    sh_log "    $op = ${v:-default/未设置}"
  done
  sh_log "  网络 blacklist=$(pst_netpolicy_has_uid "$SH_UID" && echo yes || echo no)  $(pst_netpolicy_policy)"
  sh_log "  干扰限制 distractionFlags=$(pst_distraction_flags "$PKG" "$USER_ID")"
  sh_log "  进程=$(pst_process_count "$PKG")  服务=$(pst_service_count "$PKG")  alarm 引用=$(pst_alarm_refs "$PKG" | wc -l | tr -d '[:space:]')"
  sh_log "  依赖 device_admin=$(dep_device_admin "$PKG") a11y=$(dep_a11y "$PKG") notif=$(dep_notif_listener "$PKG") sharedUser=$(pst_shared_uid "$PKG") 签名权限持有者=$(dep_sig_perm_holders "$PKG" | sed '/^$/d' | wc -l | tr -d '[:space:]') launcher=$(dep_launcher "$PKG")"
  sh_log "  注意：suspend / clear / distraction / netpolicy / appops 是通的；disable / hide / uninstall 在 HyperOS 4.0 被系统拦（README §3）"
  sh_state "audit:read" SUCCESS "只读体检完成，未写设备"
  sh_state "audit:protection" SKIPPED "未命中保护名单（v2.1 §九 9.1）"
  return 0
}

# ---------------------------------------------------------------------------
# 2) plan —— 只出方案（读数来自真机，但不写设备）
# ---------------------------------------------------------------------------
do_plan() {
  local perms apk sha
  perms="$(pst_perm_targets "$PKG" "$USER_ID" | paste -sd, - | sed 's/,/, /g')"
  apk="$(pst_path "$PKG")"
  sha="$(pst_apk_sha256 "$apk")"
  sh_log ""
  sh_log "== plan（只读：不改设备，只给可执行方案）=="
  sh_log "  目标   $PKG  user=$USER_ID  uid=${SH_UID:-?}"
  sh_log "  设备   $(sh_shell getprop ro.product.model) / $(pst_os_version) / API $(pst_api_level)"
  sh_log "  APK    $apk（sha256 ${sha:-<取不到>}）"
  sh_log "  系统分区=$(pst_is_system "$PKG" && echo yes || echo no)  enabled=$(pst_enabled_code "$PKG" "$USER_ID")($(pst_enabled_label "$(pst_enabled_code "$PKG" "$USER_ID")"))  installed=$(pst_installed "$PKG" "$USER_ID" && echo true || echo false)"
  sh_log ""
  sh_log "  第 0 步 快照（v2.1 §六 6.5）：$SNAP_ROOT/<时间戳>_${PKG}_u${USER_ID}/"
  sh_log "           含 设备型号/ROM/API/当前用户/包名/UID/安装状态/APK 路径/版本/签名 SHA-256/"
  sh_log "               原始 enabled/原始权限/原始 appops/原始网络策略/原始组件状态/已知依赖"
  sh_log ""
  sh_log "  L1 权限（README §4.3）：撤销 [${perms:-<本机无敏感运行时权限>}]"
  sh_log "           每条：pm revoke --user $USER_ID $PKG <perm>  +  pm set-permission-flags ... user-set user-fixed"
  sh_log "           顺序：pre → pm clear → post 复跑（实测 pm clear 会把运行时权限重置为默认授予）"
  sh_log "           $SH_FORBIDDEN_PERM：预期 UNKNOWN(UNSUPPORTED, REVOKE_WHEN_REQUESTED)"
  sh_log ""
  sh_log "  L2 后台（README §4.1 / §4.2）：cmd appops set --uid ${SH_UID:-UID} <OP> ignore，OP ∈ [ $SH_BG_OPS_ALL ]"
  sh_log "           另有 am set-inactive --user $USER_ID $PKG true；force-stop 由冻结步骤执行（重启后需补跑，README §8.2）"
  sh_log ""
  sh_log "  L3 网络（README §4.4）：cmd netpolicy add restrict-background-blacklist ${SH_UID:-UID}"
  sh_log "           只限后台流量（netd 层），不是全断网；前台要断只能走 MIUI 联网控制（手点）或 DNS 黑洞"
  sh_log ""
  sh_log "  L4 停用（README §3 第 5/6 行）：pm disable-user --user $USER_ID $PKG"
  sh_log "           预期 FAILED BLOCKED：SecurityException: Cannot disable system packages"
  sh_log ""
  sh_log "  L5 卸载（README §3 第 1-3 行）：pm uninstall --user $USER_ID $PKG"
  sh_log "           预期 FAILED BLOCKED：Failure [only root can delete system app for a particular user]"
  sh_log "           确认串：UNINSTALL $PKG USER $USER_ID"
  sh_log ""
  sh_log "  冻结组合（无 root 可达上限，README §4.1 / §4.5）："
  sh_log "           pm clear --user $USER_ID  →  pm set-distracting-restriction --flag hide-notifications --flag hide-from-suggestions  →  am force-stop  →  pm suspend"
  sh_log ""
  sh_log "  第六等级 恢复（v2.1 §六 6.6）：bash $0 restore --snapshot <快照目录>"
  sh_log "           只还原 changed.list 登记过的项；原值 granted=false 的权限保持 denied（不授予）"
  sh_log ""
  sh_log "  验证：bash $0 verify --for restrict"
  sh_state "plan" SKIPPED "只读模式：未执行任何写操作"
  return 0
}

# ---------------------------------------------------------------------------
# 冻结组合：clear → 干扰限制 → force-stop → suspend
# ---------------------------------------------------------------------------
do_freeze() {
  local out f
  sh_log ""
  sh_log "== 冻结组合（README §4.1 / §4.5）=="

  # 1) pm clear —— 注意：会重置运行时权限，所以调用方必须在它之后复跑 L1
  if [ "$DO_CLEAR" = 1 ]; then
    out="$(sg_shell pm clear --user "$USER_ID" "$PKG")"
    if [ "$SH_DRY_RUN" = 1 ]; then
      sh_state "freeze:clear" SKIPPED "dry-run：未执行 pm clear"
    else
      case "$out" in
        *Success*)
          sh_state "freeze:clear" SUCCESS "已清应用数据（不可回滚）—— 注意它会重置运行时权限"
          snap_changed clear "-" done
          ;;
        *Exception*|*"Error"*|*"Failure"*|*"Unknown"*)
          sh_state "freeze:clear" FAILED "系统拒绝：$out"
          ;;
        *)
          sh_state "freeze:clear" FAILED "回读无 Success：${out:-<空>}"
          ;;
      esac
    fi
  else
    sh_state "freeze:clear" SKIPPED "--no-clear：跳过 pm clear（应用数据保留）"
  fi

  # 2) 干扰限制（hide-notifications / hide-from-suggestions）
  out="$(sg_shell pm set-distracting-restriction --flag hide-notifications --flag hide-from-suggestions --user "$USER_ID" "$PKG")"
  if [ "$SH_DRY_RUN" = 1 ]; then
    sh_state "freeze:distraction" SKIPPED "dry-run：未执行 set-distracting-restriction"
  else
    case "$out" in
      *Exception*|*"Error"*|*"Failure"*|*"Unknown"*)
        sh_state "freeze:distraction" FAILED "系统拒绝：$out"
        ;;
      *)
        f="$(pst_distraction_flags "$PKG" "$USER_ID")"
        if [ -n "$f" ] && [ "$f" != "0" ]; then
          sh_state "freeze:distraction" SUCCESS "distractionFlags=$f"
          snap_changed distraction "-" "$f"
        else
          sh_state "freeze:distraction" FAILED "distractionFlags=${f:-<空>}（期望 2 或 3）"
        fi
        ;;
    esac
  fi

  # 3) 强停
  bg_force_stop "$PKG" "$USER_ID"

  # 4) 挂起（本机唯一稳定生效的冻结手段）
  out="$(sg_shell pm suspend --user "$USER_ID" "$PKG")"
  if [ "$SH_DRY_RUN" = 1 ]; then
    sh_state "freeze:suspend" SKIPPED "dry-run：未执行 pm suspend"
  else
    case "$out" in
      *Exception*|*"Error"*|*"Failure"*|*"Unknown"*)
        sh_state "freeze:suspend" FAILED "系统拒绝：$out"
        ;;
      *)
        if [ "$(pst_flag "$PKG" "$USER_ID" suspended)" = "true" ]; then
          sh_state "freeze:suspend" SUCCESS "suspended=true（持久化，重启存活）"
          snap_changed suspend "-" true
        else
          sh_state "freeze:suspend" FAILED "回读 suspended=$(pst_flag "$PKG" "$USER_ID" suspended)（期望 true）"
        fi
        ;;
    esac
  fi
  return 0
}

# ---------------------------------------------------------------------------
# 3) restrict —— 执行选定级别 + 冻结组合
# ---------------------------------------------------------------------------
do_restrict() {
  local l
  sh_log ""
  sh_log "== restrict（levels=$LEVELS  freeze=$FREEZE  clear=$DO_CLEAR  dry-run=$SH_DRY_RUN）=="
  case ",$LEVELS," in
    *[!0-9,]*|,,*) sh_err "LEVELS 只能是逗号分隔的数字（如 1,2,3）"; return 2 ;;
  esac

  snap_ensure "$PKG" "$USER_ID"
  snap_show

  # L1 pre：清数据前的占位撤销（会被 pm clear 打回，只为台账留痕）
  case ",$LEVELS," in *,1,*) perm_restrict_apply "$PKG" "$USER_ID" pre ;; esac
  # L2 后台执行
  case ",$LEVELS," in *,2,*) bg_restrict_apply "$PKG" "$SH_UID" "$USER_ID" ;; esac
  # L3 网络
  case ",$LEVELS," in *,3,*) net_add_uid "$SH_UID" ;; esac
  # L4 停用（本机预期被拦）
  case ",$LEVELS," in *,4,*) disable_apply "$PKG" "$USER_ID" ;; esac
  # L5 卸载（本机预期被拦；必须先过双重确认 —— v2.1 §六 6.4）
  case ",$LEVELS," in
    *,5,*)
      if [ "$SH_DRY_RUN" = 1 ]; then
        uninstall_apply "$PKG" "$USER_ID"
      elif guard_confirm_uninstall "$PKG" "$USER_ID"; then
        uninstall_apply "$PKG" "$USER_ID"
      else
        sh_state "uninstall:confirm" SKIPPED "确认串不匹配，跳过 L5（其余级别不受影响）"
      fi
      ;;
  esac

  # 冻结组合
  if [ "$FREEZE" = 1 ]; then
    do_freeze
  fi

  # L1 post：pm clear 之后必须复跑（v2.1 §六 6.5 / README §3 实测坑）
  case ",$LEVELS," in *,1,*) perm_restrict_apply "$PKG" "$USER_ID" post ;; esac

  if [ "$SH_DRY_RUN" != 1 ]; then
    ver_all restrict "$PKG" "$USER_ID" "$SH_UID"
    ver_posture "$PKG" "$USER_ID"
  else
    sh_state "verify" SKIPPED "dry-run：未落设备，跳过验证"
  fi
  return 0
}

# ---------------------------------------------------------------------------
# 4) disable —— L4
# ---------------------------------------------------------------------------
do_disable() {
  sh_log ""
  sh_log "== disable（L4：pm disable-user / pm disable / 组件级 / pm hide）=="
  snap_ensure "$PKG" "$USER_ID"
  disable_apply "$PKG" "$USER_ID"
  if [ "$SH_DRY_RUN" != 1 ]; then
    ver_disable_layer "$PKG" "$USER_ID"
  fi
  return 0
}

# ---------------------------------------------------------------------------
# 5) uninstall —— L5
# ---------------------------------------------------------------------------
do_uninstall() {
  sh_log ""
  sh_log "== uninstall（L5：快照 → 依赖闸门 → 双重确认 → 三种卸载写法）=="
  snap_new "$PKG" "$USER_ID"
  snap_collect "$PKG" "$USER_ID"
  guard_snapshot_ready || return 6
  snap_show

  if ! dep_gate_uninstall "$PKG"; then
    return 1
  fi
  if [ "$SH_DRY_RUN" != 1 ]; then
    if ! guard_confirm_uninstall "$PKG" "$USER_ID"; then
      sh_state "uninstall:confirm" SKIPPED "确认串不匹配，未执行卸载"
      return 5
    fi
  fi
  uninstall_apply "$PKG" "$USER_ID"
  if [ "$SH_DRY_RUN" != 1 ]; then
    ver_uninstall_layer "$PKG" "$USER_ID"
  fi
  return 0
}

# ---------------------------------------------------------------------------
# 6) restore —— 第六等级
# ---------------------------------------------------------------------------
do_restore() {
  local snap="${SNAPSHOT:-}" snap_user
  if [ -z "$snap" ]; then
    snap="$(snap_latest "$PKG")"
  fi
  if [ -z "$snap" ] || [ ! -d "$snap" ]; then
    sh_err "没有可用快照：restore 只依据快照原值（v2.1 §六 6.6）。用 --snapshot DIR 指定，或先跑 restrict 生成快照"
    return 6
  fi
  if ! snap_load "$snap"; then
    sh_err "快照不可读（缺 snapshot.kv）：$snap"
    return 6
  fi
  snap_user="$(snap_get user)"
  if [ -n "$snap_user" ] && [ "$snap_user" != "$USER_ID" ]; then
    sh_err "快照记录的用户是 $snap_user，当前目标是 $USER_ID：请加 --user $snap_user 或改用对应快照"
    return 2
  fi
  if [ -z "$SH_UID" ]; then
    SH_UID="$(snap_get uid)"
  fi
  sh_log "  使用快照 $snap（ts=$(snap_get ts)）"
  restore_apply "$PKG" "$USER_ID" "$SH_UID"
  if [ "$SH_DRY_RUN" != 1 ]; then
    ver_restore_layer "$PKG" "$USER_ID"
    ver_posture "$PKG" "$USER_ID"
  fi
  return 0
}

# ---------------------------------------------------------------------------
# 7) verify
# ---------------------------------------------------------------------------
do_verify() {
  ver_all "$VERIFY_FOR" "$PKG" "$USER_ID" "$SH_UID"
  ver_posture "$PKG" "$USER_ID"
  return 0
}

# ---------------------------------------------------------------------------
main() {
  while [ $# -gt 0 ]; do
    case "$1" in
      -h|--help) usage; return 0 ;;
      --pkg)        PKG="${2:-}"; shift 2 ;;
      --user)       USER_ID="${2:-}"; shift 2 ;;
      --uid)        SH_UID="${2:-}"; shift 2 ;;
      --serial)     SH_SERIAL="${2:-}"; shift 2 ;;
      --adb)        SH_ADB="${2:-}"; shift 2 ;;
      --levels)     LEVELS="${2:-}"; shift 2 ;;
      --no-clear)   DO_CLEAR=0; shift ;;
      --no-freeze)  FREEZE=0; shift ;;
      --snapshot)   SNAPSHOT="${2:-}"; shift 2 ;;
      --for)        VERIFY_FOR="${2:-all}"; shift 2 ;;
      --log-root)   LOG_ROOT="${2:-./logs}"; shift 2 ;;
      --dry-run)    SH_DRY_RUN=1; shift ;;
      --assume-yes) SH_ASSUME_YES=1; shift ;;
      --quiet)      SH_QUIET=1; shift ;;
      -*) sh_err "未知选项：$1"; usage; return 2 ;;
      *)
        if [ -z "$MODE" ]; then
          MODE="$1"
        else
          sh_err "多余参数：$1"
          return 2
        fi
        shift
        ;;
    esac
  done

  # 默认只读：没给模式名就是 audit，绝不因为"忘了给"就写设备
  [ -n "$MODE" ] || MODE=audit
  case " $SH_MODES " in
    *" $MODE "*) : ;;
    *) sh_err "未知模式：$MODE"; usage; return 2 ;;
  esac

  if ! log_init "$MODE"; then
    return 6
  fi
  sh_log "  参数 pkg=$PKG user=${USER_ID:-<当前用户>} uid=${SH_UID:-<自动>} levels=$LEVELS freeze=$FREEZE clear=$DO_CLEAR dry-run=$SH_DRY_RUN"
  sh_exit_code_doc

  # dry-run 对只读模式没有意义
  if [ "$SH_DRY_RUN" = 1 ]; then
    case "$MODE" in
      audit|plan|verify)
        sh_warn "--dry-run 对只读模式无意义，已忽略"
        SH_DRY_RUN=0
        ;;
    esac
  fi

  resolve_context

  case "$MODE" in
    audit)     do_audit ;;
    plan)      do_plan ;;
    restrict)  do_restrict ;;
    disable)   do_disable ;;
    uninstall) do_uninstall ;;
    restore)   do_restore ;;
    verify)    do_verify ;;
  esac

  local rc=0
  sh_summary || rc=1
  return "$rc"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
