#!/usr/bin/env bash
# lib/verification.sh — 生效性验证（v2.1 §七 7.x：不许伪造成功，必须回读）
# 依赖：common.sh adb.sh package.sh package_state.sh user_manager.sh snapshot.sh
#
# 判定纪律：
#   * 只有"回读到目标状态"才记 SUCCESS
#   * 命令返回 rc=0 但值没变 → FAILED（本机大量命令就是这种"假成功"）
#   * 回读不到 / 系统特性导致不可达 → UNKNOWN，并在说明里写 UNSUPPORTED(...)
#   * 已知被系统硬墙拦住的能力，说明里写 BLOCKED(...) 与实测原句
set -uo pipefail

: "${SNAP_DIR:=}"

# ---------------------------------------------------------------------------
# L1 权限层
# ---------------------------------------------------------------------------
ver_perm_layer() {  # <pkg> <user>
  local pkg="${1:-}" user="${2:-0}" p g fl
  sh_log "== 验证 L1 权限层（v2.1 §四 4.3）=="
  for p in $SH_DANGEROUS_PERMS; do
    g="$(pst_perm_granted "$pkg" "$user" "$p")"
    fl="$(pst_perm_flags "$pkg" "$user" "$p")"
    if [ -z "$g" ]; then
      sh_state "verify:perm:$p" SKIPPED "该用户下无此权限记录（未声明/未请求）"
      continue
    fi
    case "$g" in
      false)
        case "$fl" in
          *USER_FIXED*) sh_state "verify:perm:$p" SUCCESS "granted=false flags=[$fl]" ;;
          *)            sh_state "verify:perm:$p" UNKNOWN "granted=false 但缺 USER_FIXED（会被系统重算）" ;;
        esac
        ;;
      true) sh_state "verify:perm:$p" FAILED "granted=true（撤销未生效）" ;;
      *)    sh_state "verify:perm:$p" UNKNOWN "读数异常 granted=${g}" ;;
    esac
  done

  # v2.1 §六 6.7：ACCESS_LOCAL_NETWORK 带 REVOKE_WHEN_REQUESTED，撤销被系统忽略
  g="$(pst_perm_granted "$pkg" "$user" "$SH_FORBIDDEN_PERM")"
  if [ -z "$g" ]; then
    sh_state "verify:perm:$SH_FORBIDDEN_PERM" SKIPPED "本包无此权限记录"
  elif [ "$g" = false ]; then
    sh_state "verify:perm:$SH_FORBIDDEN_PERM" SUCCESS "granted=false"
  else
    sh_state "verify:perm:$SH_FORBIDDEN_PERM" UNKNOWN "UNSUPPORTED(REVOKE_WHEN_REQUESTED)：Android16+ 特权 App 默认授予，pm revoke 回 rc=0 但值不变"
  fi
}

# ---------------------------------------------------------------------------
# L2 后台执行层（AppOps + force-standby 证据）
# ---------------------------------------------------------------------------
ver_background_layer() {  # <pkg> <uid> [user]
  local pkg="${1:-}" uid="${2:-}" user="${3:-0}" op v
  sh_log "== 验证 L2 后台执行层（v2.1 §四 4.1 / 4.2）=="
  for op in $SH_BG_OPS_ALL; do
    v="$(pst_appops_uid_value "$uid" "$op")"
    [ -z "$v" ] && v="$(pst_appops_value "$pkg" "$op")"
    case " ${SH_BG_OPS_OPTIONAL:-} " in
      *" $op "*)
        # 非实测 op：只有真读到 ignore 才记成功，其余记 SKIPPED（不参与判定，避免误判成失败）
        if [ "$v" = "ignore" ]; then
          sh_state "verify:appops:$op" SUCCESS "回读 ignore"
        else
          sh_state "verify:appops:$op" SKIPPED "非本机实测 op，回读=${v:-<空>}（只尝试不判死）"
        fi
        continue
        ;;
    esac
    case "$v" in
      ignore) sh_state "verify:appops:$op" SUCCESS "回读 ignore" ;;
      '')     sh_state "verify:appops:$op" FAILED "回读为空（未设置，命令未生效）" ;;
      *)      sh_state "verify:appops:$op" FAILED "回读=$v（期望 ignore）" ;;
    esac
  done
  # force-standby 证据（dumpsys alarm 的 Restricted packages，u<user>a<appid>）
  # 本机该段不保证出现 → 拿不到就记 SKIPPED，不参与判定（不伪造也不污染判定）
  if pst_alarm_restricted "$pkg" "$user" "$uid"; then
    sh_state "verify:alarm-restricted" SUCCESS "force-standby 名单含 $(um_alarm_tag "$user" "$uid")"
  else
    sh_state "verify:alarm-restricted" SKIPPED "dumpsys alarm 未见 $(um_alarm_tag "$user" "$uid")（证据非必需）"
  fi
}

# ---------------------------------------------------------------------------
# L3 网络层（netd 的 restrict-background，只限后台，不是全断网 —— README §4.4）
# ---------------------------------------------------------------------------
ver_network_layer() {  # <uid>
  local uid="${1:-}"
  sh_log "== 验证 L3 网络层（README §4.4）=="
  if pst_netpolicy_has_uid "$uid"; then
    sh_state "verify:netpolicy" SUCCESS "UID $uid 在 restrict-background-blacklist"
  else
    sh_state "verify:netpolicy" FAILED "UID $uid 不在黑名单（$(pst_netpolicy_policy)）"
  fi
}

# ---------------------------------------------------------------------------
# L4 停用
# ---------------------------------------------------------------------------
ver_disable_layer() {  # <pkg> <user>
  local pkg="${1:-}" user="${2:-0}" en
  sh_log "== 验证 L4 停用 =="
  en="$(pst_enabled_code "$pkg" "$user")"
  if pst_enabled_is_disabled "$en"; then
    sh_state "verify:disable" SUCCESS "enabled=$en($(pst_enabled_label "$en"))"
  else
    sh_state "verify:disable" FAILED "enabled=${en:-?}($(pst_enabled_label "$en"))：BLOCKED(HyperOS PackageManagerServiceImpl 拒改系统包启用状态)"
  fi
}

# ---------------------------------------------------------------------------
# L5 用户级卸载
# ---------------------------------------------------------------------------
ver_uninstall_layer() {  # <pkg> <user>
  local pkg="${1:-}" user="${2:-0}"
  sh_log "== 验证 L5 用户级卸载 =="
  if pst_installed "$pkg" "$user"; then
    sh_state "verify:uninstall" FAILED "installed=true：BLOCKED(API35+ 仅 root —— only root can delete system app for a particular user)"
  else
    sh_state "verify:uninstall" SUCCESS "installed=false（该用户下已卸载）"
  fi
}

# ---------------------------------------------------------------------------
# 挂起（无 root 可达的最强冻结）
# ---------------------------------------------------------------------------
ver_suspend_layer() {  # <pkg> <user>
  local pkg="${1:-}" user="${2:-0}" v
  sh_log "== 验证挂起（README §3 第 7 行：六条路只有 suspend 通了）=="
  v="$(pst_flag "$pkg" "$user" suspended)"
  case "$v" in
    true)  sh_state "verify:suspend" SUCCESS "suspended=true" ;;
    false) sh_state "verify:suspend" FAILED "suspended=false" ;;
    *)     sh_state "verify:suspend" UNKNOWN "无 suspended 读数" ;;
  esac
}

# ---------------------------------------------------------------------------
# 干扰限制 + 强停
# ---------------------------------------------------------------------------
ver_distraction_layer() {  # <pkg> <user>
  local pkg="${1:-}" user="${2:-0}" f n
  sh_log "== 验证通知层（README §3 第 8 行 / §4.5）=="
  f="$(pst_distraction_flags "$pkg" "$user")"
  if [ -n "$f" ] && [ "$f" != 0 ]; then
    sh_state "verify:distraction" SUCCESS "distractionFlags=$f"
  else
    sh_state "verify:distraction" FAILED "distractionFlags=${f:-<空>}（期望 2 或 3）"
  fi
  n="$(pst_process_count "$pkg")"
  if [ "${n:-0}" -eq 0 ]; then
    sh_state "verify:force-stop" SUCCESS "无运行中进程"
  else
    sh_state "verify:force-stop" FAILED "仍有 ${n} 个进程（force-stop 未生效或已被重拉）"
  fi
  # stopped 标记只用于说明：重启后会被开机流程重置为 false（README §8.2），不参与判定
  sh_state "verify:stopped-flag" SKIPPED "stopped=$(pst_flag "$pkg" "$user" stopped)（重启后会被重置，需补跑 force-stop）"
}

# ---------------------------------------------------------------------------
# 第六等级：恢复是否回到快照原值
# ---------------------------------------------------------------------------
ver_restore_layer() {  # <pkg> <user>
  local pkg="${1:-}" user="${2:-0}" layer key orig now ok=0 bad=0
  sh_log "== 验证恢复（对照快照原值；只比对 changed.list 里登记过的项）=="
  if [ -z "$(snap_changes)" ]; then
    sh_state "verify:restore" SKIPPED "changed.list 为空：本项目未记录任何变更"
    return 0
  fi
  while IFS=$'\t' read -r layer key _; do
    [ -n "$layer" ] || continue
    case "$layer" in
      perm)
        orig="$(snap_get "perm:$key")"
        now="granted=$(pst_perm_granted "$pkg" "$user" "$key");flags=$(pst_perm_flags "$pkg" "$user" "$key")"
        case "$orig" in
          granted=true*) 
            case "$now" in *granted=true*) sh_state "verify:restore:perm:$key" SUCCESS "已回到 granted=true" ; ok=$((ok+1)) ;;
                          *) sh_state "verify:restore:perm:$key" FAILED "原值 $orig，现值 $now" ; bad=$((bad+1)) ;; esac ;;
          granted=false*)
            case "$now" in *granted=false*) sh_state "verify:restore:perm:$key" SUCCESS "原值就是 denied，保持 denied（未误授）" ; ok=$((ok+1)) ;;
                          *) sh_state "verify:restore:perm:$key" FAILED "原值 $orig，现值 $now" ; bad=$((bad+1)) ;; esac ;;
          *) sh_state "verify:restore:perm:$key" UNKNOWN "快照无原值" ;;
        esac
        ;;
      appops)
        orig="$(snap_get "appops:$key")"
        [ -n "$orig" ] || orig=default
        now="$(pst_appops_uid_value "$(pst_uid "$pkg")" "$key")"
        [ -z "$now" ] && now="$(pst_appops_value "$pkg" "$key")"
        [ -z "$now" ] && now=default
        if [ "$now" = "$orig" ]; then
          sh_state "verify:restore:appops:$key" SUCCESS "回到 $orig" ; ok=$((ok+1))
        else
          sh_state "verify:restore:appops:$key" FAILED "原值 $orig，现值 $now" ; bad=$((bad+1))
        fi
        ;;
      netpolicy)
        if pst_netpolicy_has_uid "$key"; then now=yes; else now=no; fi
        orig="$(snap_get netpolicy_blacklisted)"
        if [ "$now" = "$orig" ]; then
          sh_state "verify:restore:netpolicy" SUCCESS "回到黑名单状态=$orig" ; ok=$((ok+1))
        else
          sh_state "verify:restore:netpolicy" FAILED "原值 $orig，现值 $now" ; bad=$((bad+1))
        fi
        ;;
      suspend)
        orig="$(snap_get suspended)"
        now="$(pst_flag "$pkg" "$user" suspended)"
        if [ "$now" = "$orig" ]; then
          sh_state "verify:restore:suspend" SUCCESS "suspended=$now" ; ok=$((ok+1))
        else
          sh_state "verify:restore:suspend" FAILED "原值 $orig，现值 $now" ; bad=$((bad+1))
        fi
        ;;
      enabled)
        orig="$(snap_get enabled)"
        now="$(pst_enabled_code "$pkg" "$user")"
        if [ "$now" = "$orig" ]; then
          sh_state "verify:restore:enabled" SUCCESS "enabled=$now" ; ok=$((ok+1))
        else
          sh_state "verify:restore:enabled" FAILED "原值 $orig，现值 $now" ; bad=$((bad+1))
        fi
        ;;
      distraction)
        orig="$(snap_get distraction_flags)"
        now="$(pst_distraction_flags "$pkg" "$user")"
        if [ "$now" = "$orig" ]; then
          sh_state "verify:restore:distraction" SUCCESS "distractionFlags=$now" ; ok=$((ok+1))
        else
          sh_state "verify:restore:distraction" FAILED "原值 $orig，现值 $now" ; bad=$((bad+1))
        fi
        ;;
      uninstall)
        orig="$(snap_get installed)"
        if pst_installed "$pkg" "$user"; then now=true; else now=false; fi
        if [ "$now" = "$orig" ]; then
          sh_state "verify:restore:uninstall" SUCCESS "installed=$now" ; ok=$((ok+1))
        else
          sh_state "verify:restore:uninstall" FAILED "原值 $orig，现值 $now" ; bad=$((bad+1))
        fi
        ;;
      clear|inactive|force-stop|component)
        sh_state "verify:restore:$layer" UNKNOWN "该层不可回滚（$key）：pm clear 清掉的数据不会回来"
        ;;
      *)
        sh_state "verify:restore:$layer" UNKNOWN "未知层 $layer（$key）"
        ;;
    esac
  done <<<"$(snap_changes)"
  return 0
}

# ---------------------------------------------------------------------------
# 汇总入口
# ---------------------------------------------------------------------------
ver_all() {  # <mode> <pkg> <user> [uid]
  local mode="${1:-all}" pkg="${2:-}" user="${3:-0}" uid="${4:-}"
  [ -n "$uid" ] || uid="$(pst_uid "$pkg")"
  sh_log ""
  sh_log "== 验证（mode=$mode  pkg=$pkg  user=$user  uid=$uid）=="
  case "$mode" in
    restrict|freeze|all)
      ver_perm_layer "$pkg" "$user"
      ver_background_layer "$pkg" "$uid" "$user"
      ver_network_layer "$uid"
      ver_suspend_layer "$pkg" "$user"
      ver_distraction_layer "$pkg" "$user"
      if [ "$mode" = all ]; then
        ver_disable_layer "$pkg" "$user"
        ver_uninstall_layer "$pkg" "$user"
      fi
      ;;
    disable)   ver_disable_layer "$pkg" "$user" ;;
    uninstall) ver_uninstall_layer "$pkg" "$user" ;;
    restore)   ver_restore_layer "$pkg" "$user" ;;
    perm)      ver_perm_layer "$pkg" "$user" ;;
    background) ver_background_layer "$pkg" "$uid" "$user" ;;
    network)   ver_network_layer "$uid" ;;
    suspend)   ver_suspend_layer "$pkg" "$user" ;;
    *) sh_state "verify:mode" UNKNOWN "未知验证目标 $mode" ;;
  esac
}

# 现场姿态快照（人看的，不参与判定）
ver_posture() {  # <pkg> <user>
  local pkg="${1:-}" user="${2:-0}"
  sh_log ""
  sh_log "== 当前姿态 =="
  pst_posture "$pkg" "$user" | sed 's/^/  /'
}
