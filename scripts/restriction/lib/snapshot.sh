#!/usr/bin/env bash
# lib/snapshot.sh — 处置前快照（v2.1 §六 6.5 / §八 8.2）
# 依赖：common.sh adb.sh package.sh package_state.sh user_manager.sh
#
# 快照必须包含（规格书逐项）：
#   设备型号 / ROM / API / 当前用户 / 包名 / UID / 安装状态 / APK 路径 / 版本 /
#   签名 SHA-256（sh_shell sha256sum <apk>）/ 原始 enabled / 原始权限 / 原始 appops /
#   原始网络策略 / 原始组件状态 / 已知依赖
#
# 两条硬纪律：
#   1) 快照只记录"原值"，不做任何推断；restore 只认这里（v2.1 §六 6.6）
#   2) 本项目改过的每一项都要进 changed.list —— restore 只恢复这张表里的项，
#      绝不"顺手"把原本就 deny 的权限授回去
set -uo pipefail

: "${SNAP_ROOT:=}"
: "${SNAP_DIR:=}"
: "${SNAP_RAW:=}"
: "${SNAP_KV:=}"

snap_root() {
  printf '%s' "${SNAP_ROOT:-${SH_LOG_DIR:-./logs}/snapshots}"
}

snap_kv_path() {
  local kv="${SNAP_KV:-}"
  if [ -z "$kv" ]; then
    kv="${SNAP_DIR:-}/snapshot.kv"
  fi
  printf '%s' "$kv"
}

snap_set() {  # <key> <value>
  local kv
  kv="$(snap_kv_path)"
  [ "$kv" != "/snapshot.kv" ] || return 1
  printf '%s\t%s\n' "${1:-}" "${2:-}" >>"$kv"
}

snap_get() {  # <key> → 值（无则空）
  local kv
  kv="$(snap_kv_path)"
  [ -f "$kv" ] || return 0
  awk -F'\t' -v k="${1:-}" '$1 == k { print $2; exit }' "$kv"
}

# 新快照目录（时间戳_包名_u用户）；同时初始化 changed.list
snap_new() {  # <pkg> <user>
  local pkg="${1:-}" user="${2:-0}" stamp
  stamp="$(sh_stamp)"
  SNAP_DIR="$(snap_root)/${stamp}_${pkg}_u${user}"
  SNAP_RAW="$SNAP_DIR/raw"
  SNAP_KV="$SNAP_DIR/snapshot.kv"
  if ! mkdir -p "$SNAP_RAW"; then
    sh_die "SNAPSHOT_DIR_CREATE_FAILED: $SNAP_DIR" 6
  fi
  : >"$SNAP_KV"
  : >"$SNAP_DIR/changed.list"
  snap_set ts "$stamp"
  snap_set pkg "$pkg"
  snap_set user "$user"
  sh_log "  快照目录 $SNAP_DIR"
  return 0
}

# 入口已建过快照就复用；没有就新建并采集
snap_ensure() {  # <pkg> <user>
  local pkg="${1:-}" user="${2:-0}"
  if [ -n "${SNAP_DIR:-}" ] && [ -f "$(snap_kv_path)" ] \
     && [ "$(snap_get pkg)" = "$pkg" ] && [ "$(snap_get user)" = "$user" ]; then
    return 0
  fi
  snap_new "$pkg" "$user"
  snap_collect "$pkg" "$user"
}

snap_load() {  # <dir>
  local d="${1:-}"
  [ -n "$d" ] && [ -d "$d" ] && [ -f "$d/snapshot.kv" ] || return 1
  SNAP_DIR="$d"
  SNAP_RAW="$d/raw"
  SNAP_KV="$d/snapshot.kv"
  return 0
}

snap_latest() {  # <pkg> → 最新快照目录
  local pkg="${1:-}" root
  root="$(snap_root)"
  [ -d "$root" ] || return 1
  ls -1dt "$root"/*_"$pkg"_u* 2>/dev/null | head -1
}

# ---------------------------------------------------------------------------
# 变更记账（v2.1 §六 6.6：restore 只恢复这里登记过的项）
# ---------------------------------------------------------------------------
snap_changed() {  # <layer> <key> <value>
  local layer="${1:-}" key="${2:-}" val="${3:-}" f line
  # dry-run 绝不写台账：台账是"本项目真的改过什么"的唯一凭据（v2.1 §六 6.6）
  [ "${SH_DRY_RUN:-0}" = 1 ] && return 0
  [ -n "${SNAP_DIR:-}" ] || { sh_warn "snap_changed: 无 SNAP_DIR，跳过登记 $layer/$key"; return 0; }
  f="$SNAP_DIR/changed.list"
  line="$(printf '%s\t%s\t%s' "$layer" "$key" "$val")"
  if [ -f "$f" ] && grep -Fqx -- "$line" "$f"; then
    return 0
  fi
  printf '%s\n' "$line" >>"$f"
}

snap_changes() {
  if [ -n "${SNAP_DIR:-}" ] && [ -f "$SNAP_DIR/changed.list" ]; then
    cat "$SNAP_DIR/changed.list"
  fi
  return 0
}

# 某层改过的 key（去重）
snap_changed_keys() {
  snap_changes | awk -F'\t' -v l="${1:-}" '$1 == l { print $2 }' | sort -u
}

snap_was_changed() {  # <layer> <key>
  snap_changes | awk -F'\t' -v l="${1:-}" -v k="${2:-}" '$1 == l && $2 == k { f = 1 } END { exit(f ? 0 : 1) }'
}

# ---------------------------------------------------------------------------
# 依赖采集（快照要求"已知依赖"；与 dependency_check.sh 互补，这里只要值）
# ---------------------------------------------------------------------------
snap_sig_perm_holder_count() {  # <pkg>
  local pkg="${1:-}"
  if command -v dep_sig_perm_holders >/dev/null 2>&1; then
    dep_sig_perm_holders "$pkg" | sed '/^$/d' | wc -l | tr -d '[:space:]'
  else
    sh_shell dumpsys package 2>/dev/null | grep -c -- "$pkg.permission" || printf '0'
  fi
}

snap_dep_collect() {  # <pkg>
  local pkg="${1:-}" v
  v="$(sh_shell dumpsys device_policy 2>/dev/null)"
  case "$v" in *"$pkg"*) snap_set dep:device_admin 1 ;; *) snap_set dep:device_admin 0 ;; esac
  v="$(sh_shell settings get secure enabled_accessibility_services 2>/dev/null)"
  case "$v" in *"$pkg"*) snap_set dep:a11y 1 ;; *) snap_set dep:a11y 0 ;; esac
  v="$(sh_shell settings get secure enabled_notification_listeners 2>/dev/null)"
  case "$v" in *"$pkg"*) snap_set dep:notif_listener 1 ;; *) snap_set dep:notif_listener 0 ;; esac
  snap_set dep:processes "$(pst_process_count "$pkg")"
  snap_set dep:services "$(pst_service_count "$pkg")"
  snap_set dep:shared_uid "$(pst_shared_uid "$pkg")"
  snap_set dep:sig_perm_holders "$(snap_sig_perm_holder_count "$pkg")"
  v="$(sh_shell dumpsys package "$pkg" 2>/dev/null | grep -c 'android.intent.category.LAUNCHER')"
  snap_set dep:launcher "${v:-0}"
}

# ---------------------------------------------------------------------------
# 全量采集
# ---------------------------------------------------------------------------
snap_collect() {  # <pkg> <user>
  local pkg="${1:-}" user="${2:-0}"
  local uid path sha vn vc enabled suspended stopped ins sys splits shared
  local model rom os api cur p c

  [ -n "${SNAP_DIR:-}" ] || snap_new "$pkg" "$user"
  sh_log "  采集快照（dumpsys / appops / netpolicy / 组件 / 依赖）…"

  uid="$(pst_uid "$pkg")"
  path="$(pst_path "$pkg")"
  sha="$(pst_apk_sha256 "$path")"
  vn="$(pst_version_name "$pkg")"
  vc="$(pst_version_code "$pkg")"
  enabled="$(pst_enabled_code "$pkg" "$user")"
  suspended="$(pst_flag "$pkg" "$user" suspended)"
  stopped="$(pst_flag "$pkg" "$user" stopped)"
  if pst_installed "$pkg" "$user"; then ins=true; else ins=false; fi
  if pst_is_system "$pkg"; then sys=yes; else sys=no; fi
  splits="$(pst_splits "$pkg")"
  shared="$(pst_shared_uid "$pkg")"
  model="$(sh_shell getprop ro.product.model 2>/dev/null)"
  rom="$(sh_shell getprop ro.build.version.incremental 2>/dev/null)"
  os="$(pst_os_version)"
  api="$(pst_api_level)"
  cur="$(um_current_user)"

  # 原始证据落盘（事后可逐字节对账）
  sh_shell dumpsys package "$pkg"                     >"$SNAP_RAW/dumpsys_package.txt" 2>&1
  sh_shell cmd package dump "$pkg"                    >"$SNAP_RAW/cmd_package_dump.txt" 2>&1
  sh_shell cmd appops get --uid "$uid"                >"$SNAP_RAW/appops_uid.txt" 2>&1
  sh_shell cmd netpolicy list restrict-background-blacklist >"$SNAP_RAW/netpolicy_blacklist.txt" 2>&1
  sh_shell dumpsys netpolicy                          >"$SNAP_RAW/dumpsys_netpolicy.txt" 2>&1
  sh_shell ps -A                                      >"$SNAP_RAW/ps.txt" 2>&1
  sh_shell dumpsys activity services "$pkg"           >"$SNAP_RAW/services.txt" 2>&1
  sh_shell dumpsys device_policy                      >"$SNAP_RAW/device_policy.txt" 2>&1
  sh_shell settings get secure enabled_accessibility_services >"$SNAP_RAW/a11y.txt" 2>&1
  sh_shell settings get secure enabled_notification_listeners >"$SNAP_RAW/notif.txt" 2>&1
  sh_shell pm list users                              >"$SNAP_RAW/users.txt" 2>&1
  # 同样要防 MSYS 路径转换：整串命令 + 单引号（否则 /system/... 会被改写成本地路径）
  MSYS_NO_PATHCONV=1 sh_shell "sha256sum '$path'"     >"$SNAP_RAW/apk_sha256.txt" 2>&1
  sh_device_facts                                     >"$SNAP_RAW/device_facts.txt" 2>&1

  # 设备与目标事实
  snap_set device_model "$model"
  snap_set device_rom "$rom"
  snap_set device_os "${os:-unknown}"
  snap_set device_api "${api:-unknown}"
  snap_set serial "$SH_SERIAL"
  snap_set current_user "$cur"
  snap_set snapshot_user "$user"
  snap_set uid "$uid"
  snap_set installed "$ins"
  snap_set enabled "$enabled"
  snap_set enabled_label "$(pst_enabled_label "$enabled")"
  snap_set suspended "${suspended:-unknown}"
  snap_set stopped "${stopped:-unknown}"
  snap_set apk_path "$path"
  snap_set apk_sha256 "${sha:-unknown}"
  snap_set version_name "$vn"
  snap_set version_code "$vc"
  snap_set splits "${splits:-0}"
  snap_set is_system "$sys"
  snap_set shared_uid "$shared"
  snap_set distraction_flags "$(pst_distraction_flags "$pkg" "$user")"
  if pst_netpolicy_has_uid "$uid"; then
    snap_set netpolicy_blacklisted yes
  else
    snap_set netpolicy_blacklisted no
  fi
  snap_set netpolicy_policy "$(pst_netpolicy_policy)"
  snap_set proc_count "$(pst_process_count "$pkg")"
  snap_set service_count "$(pst_service_count "$pkg")"
  snap_set alarm_ref_count "$(pst_alarm_refs "$pkg" | wc -l | tr -d '[:space:]')"

  # 原始运行时权限（逐条 granted + flags）
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    snap_set "perm:$p" "granted=$(pst_perm_granted "$pkg" "$user" "$p");flags=$(pst_perm_flags "$pkg" "$user" "$p")"
  done <<<"$(pst_perm_lines "$pkg" "$user" | sed -n 's/^[[:space:]]*android\.permission\.\([A-Z_0-9]*\):.*/\1/p')"

  # 原始 appops（ALL，不只目标集 —— 恢复时要按原值写回）
  awk '
    /^[[:space:]]*[A-Za-z_0-9]+:/ {
      op = $1; gsub(/[[:space:]]/, "", op)
      if (op !~ /[A-Z]/) next
      v = $2; gsub(/^[[:space:]]+/, "", v); gsub(/[[:space:]]+$/, "", v)
      printf "appops:%s\t%s\n", op, v
    }' "$SNAP_RAW/appops_uid.txt" >>"$(snap_kv_path)"

  # 原始组件状态
  pst_components "$pkg" >"$SNAP_RAW/components.txt" 2>&1
  pst_disabled_components "$pkg" >"$SNAP_RAW/components_disabled.txt" 2>&1
  while IFS= read -r c; do
    [ -n "$c" ] || continue
    if pst_component_disabled "$pkg" "$c"; then
      snap_set "component:$c" disabled
    else
      snap_set "component:$c" enabled
    fi
  done <<<"$(pst_components "$pkg")"

  # 已知依赖
  snap_dep_collect "$pkg"

  snap_write_summary
  sh_log "  快照采集完成：$(snap_kv_path)"
}

snap_write_summary() {
  local f="$SNAP_DIR/summary.md"
  {
    printf '# 处置前快照 %s\n\n' "$(snap_get ts)"
    printf -- '- 目标包: `%s`（user %s, uid %s）\n' "$(snap_get pkg)" "$(snap_get user)" "$(snap_get uid)"
    printf -- '- 设备: %s / ROM %s / OS %s / API %s / serial %s\n' \
      "$(snap_get device_model)" "$(snap_get device_rom)" "$(snap_get device_os)" "$(snap_get device_api)" "$(snap_get serial)"
    printf -- '- 当前用户: %s\n' "$(snap_get current_user)"
    printf -- '- 安装: installed=%s enabled=%s(%s) suspended=%s stopped=%s\n' \
      "$(snap_get installed)" "$(snap_get enabled)" "$(snap_get enabled_label)" "$(snap_get suspended)" "$(snap_get stopped)"
    printf -- '- APK: %s\n' "$(snap_get apk_path)"
    printf -- '- 版本: %s (%s)  splits=%s  系统分区=%s\n' \
      "$(snap_get version_name)" "$(snap_get version_code)" "$(snap_get splits)" "$(snap_get is_system)"
    printf -- '- 签名 SHA-256: %s\n' "$(snap_get apk_sha256)"
    printf -- '- 网络: blacklisted=%s  policy=%s\n' "$(snap_get netpolicy_blacklisted)" "$(snap_get netpolicy_policy)"
    printf -- '- 干扰限制 distractionFlags=%s\n' "$(snap_get distraction_flags)"
    printf -- '- 依赖: device_admin=%s a11y=%s notif=%s 进程=%s 服务=%s sharedUser=%s 签名权限持有者=%s launcher=%s\n' \
      "$(snap_get dep:device_admin)" "$(snap_get dep:a11y)" "$(snap_get dep:notif_listener)" \
      "$(snap_get dep:processes)" "$(snap_get dep:services)" "$(snap_get dep:shared_uid)" \
      "$(snap_get dep:sig_perm_holders)" "$(snap_get dep:launcher)"
    printf '\n## 原始运行时权限\n\n```\n'
    awk -F'\t' '$1 ~ /^perm:/ { printf "%-22s %s\n", substr($1, 6), $2 }' "$(snap_kv_path)"
    printf '```\n\n## 原始 appops（前 40 条）\n\n```\n'
    awk -F'\t' '$1 ~ /^appops:/ { printf "%-30s %s\n", substr($1, 8), $2 }' "$(snap_kv_path)" | head -40
    printf '```\n\n## 变更台账 changed.list\n\n```\n'
    snap_changes
    printf '```\n'
  } >"$f"
}

snap_show() {  # 打印快照头部（audit / 写模式前置提示用）
  sh_log "  快照: $(snap_kv_path)"
  sh_log "    pkg=$(snap_get pkg) user=$(snap_get user) uid=$(snap_get uid) installed=$(snap_get installed) enabled=$(snap_get enabled)"
  sh_log "    APK=$(snap_get apk_path)"
  sh_log "    sha256=$(snap_get apk_sha256)"
  sh_log "    device=$(snap_get device_model) rom=$(snap_get device_rom) api=$(snap_get device_api)"
}
