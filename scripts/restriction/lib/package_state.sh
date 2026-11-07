#!/usr/bin/env bash
# lib/package_state.sh — 目标包状态读数（只读，所有判定的单一口径）
# 依赖：scripts/lib/{common,adb,package}.sh
#
# 读数口径（真机实测结论，不是猜测）：
#   * pm list packages（含 -u/-d）在 HyperOS 4.0 上 rc=0 但零输出 → 一律用 cmd package list packages
#     （README.zh-CN §3「顺带记录两个反直觉的坑」；docs/zh-CN/COMPATIBILITY-hyperos4.md §3）
#   * dumpsys package 的 runtime permissions / 用户状态每用户各一份，必须按 "^    User <id>:" 切段，
#     否则会把 User 999 的默认值当成 User 0 的结果（CHANGELOG v2.1「读数误判」）
#   * getprop ro.build.version.sdk / release 在本机无输出；可靠的是 ro.mi.os.version.name /
#     ro.build.version.incremental（lib/adb.sh 的 sh_device_facts 已按此实现）
#   * am set-standby-bucket 恒为 bucket=10 reason=f，读数无意义，不做判定依据
#
# 本文件只读设备，绝不产生写操作。
set -uo pipefail

# --- 共享常量（v2.1 §四 4.1 / §四 4.3 / §六 6.7）---
# 用 := 形式，重复 source 不会覆盖调用方的显式设置。
: "${SH_DANGEROUS_PERMS:=READ_PHONE_STATE ACCESS_FINE_LOCATION ACCESS_COARSE_LOCATION ACCESS_BACKGROUND_LOCATION READ_EXTERNAL_STORAGE BLUETOOTH_CONNECT}"
: "${SH_FORBIDDEN_PERM:=ACCESS_LOCAL_NETWORK}"
: "${SH_BG_OPS_EXEC:=RUN_IN_BACKGROUND RUN_ANY_IN_BACKGROUND START_FOREGROUND WAKE_LOCK}"
: "${SH_BG_OPS_CLOCK:=SCHEDULE_EXACT_ALARM}"
: "${SH_BG_OPS_NET:=ACTIVATE_VPN}"
: "${SH_BG_OPS_NOTIFY:=POST_NOTIFICATION}"
: "${SH_BG_OPS_PRIV:=GET_USAGE_STATS SYSTEM_ALERT_WINDOW}"
# 非本机实测项：只尝试设置，不拿来判死（SYSTEM_ALERT_WINDOW 是特殊 op，回读常为 default）
: "${SH_BG_OPS_OPTIONAL:=SYSTEM_ALERT_WINDOW}"
: "${SH_BG_OPS_ALL:=}"
if [ -z "$SH_BG_OPS_ALL" ]; then
  SH_BG_OPS_ALL="$SH_BG_OPS_EXEC $SH_BG_OPS_CLOCK $SH_BG_OPS_NET $SH_BG_OPS_NOTIFY $SH_BG_OPS_PRIV"
fi

# ---------------------------------------------------------------------------
# 身份与路径
# ---------------------------------------------------------------------------
pst_uid() { sh_pkg_uid "${1:-}"; }

pst_path() { sh_pkg_path "${1:-}"; }

pst_splits() { sh_pkg_splits "${1:-}"; }

pst_is_system() { sh_pkg_is_system "${1:-}"; }

pst_shared_uid() {
  local v
  v="$(sh_pkg_shared_uid "${1:-}")"
  case "$v" in
    SharedUserSetting\{*)
      # SharedUserSetting{2ff9203 com.mobiletools.systemhelper.uid/10100} → com.mobiletools.systemhelper.uid/10100
      printf '%s' "$v" | sed 's/^SharedUserSetting{[^ ]* //; s/}$//'
      ;;
    *) printf '%s' "$v" ;;
  esac
}

# API level：ro.build.version.sdk 在本机是空的（README §3 坑），
# 依次退到 ro.system.build.version.sdk（实测=37）→ vendor/product/odm
pst_api_level() {
  local prop v
  for prop in ro.build.version.sdk ro.system.build.version.sdk ro.product.build.version.sdk \
              ro.vendor.build.version.sdk ro.odm.build.version.sdk; do
    v="$(sh_shell getprop "$prop" 2>/dev/null | tr -d '[:space:]')"
    case "$v" in
      ''|*[!0-9]*) continue ;;
      *) printf '%s' "$v"; return 0 ;;
    esac
  done
  printf 'unknown'
}

pst_os_version() {
  local v
  v="$(sh_shell getprop ro.mi.os.version.name 2>/dev/null | tr -d '\r')"
  printf '%s' "${v:-unknown}"
}

# ---------------------------------------------------------------------------
# 用户段切分（v2.1 读数纪律）
# ---------------------------------------------------------------------------

# 目标用户那一段的全部行；没有该用户段时输出为空
pst_user_segment() {
  local pkg="${1:-}" user="${2:-0}"
  sh_shell dumpsys package "$pkg" 2>/dev/null | awk -v U="$user" '
    /^    User [0-9]+:/ { on = ($0 ~ ("^    User " U ":")); if (on) print; next }
    on { print }
  '
}

pst_user_line() { pst_user_segment "${1:-}" "${2:-0}" | head -1; }

# pst_flag <pkg> <user> <installed|enabled|suspended|stopped|hidden>
pst_flag() {
  local pkg="${1:-}" user="${2:-0}" key="${3:-installed}"
  pst_user_segment "$pkg" "$user" \
    | grep -oE "(^|[ ,])$key=[A-Za-z0-9_]+" \
    | head -1 | sed 's/^[ ,]//; s/^.*=//'
}

pst_installed() {
  local pkg="${1:-}" user="${2:-0}" v line list
  v="$(pst_flag "$pkg" "$user" installed)"
  case "$v" in
    true)  return 0 ;;
    false) return 1 ;;
  esac
  # dumpsys 没有该用户段 → 退回枚举（必须走 cmd package，pm list packages 在本机是哑的）
  list="$(sh_shell cmd package list packages --user "$user" 2>/dev/null)"
  while IFS= read -r line; do
    [ "$line" = "package:$pkg" ] && return 0
  done <<<"$list"
  return 1
}

pst_enabled_code() { pst_flag "${1:-}" "${2:-0}" enabled; }

# enabled: 0=默认 1=启用 2=禁用 3=用户禁用 4=未使用禁用（Android PackageManager 语义）
pst_enabled_label() {
  case "${1:-}" in
    0) printf '默认(0)' ;;
    1) printf '启用(1)' ;;
    2) printf '禁用(2)' ;;
    3) printf '用户禁用(3)' ;;
    4) printf '未使用禁用(4)' ;;
    '') printf '无记录' ;;
    *) printf '未知(%s)' "$1" ;;
  esac
}

pst_enabled_is_disabled() {
  case "${1:-}" in
    2|3|4) return 0 ;;
    *) return 1 ;;
  esac
}

# ---------------------------------------------------------------------------
# 版本 / APK / 签名
# ---------------------------------------------------------------------------
pst_version_name() {
  sh_shell dumpsys package "${1:-}" 2>/dev/null | grep -m1 -oE 'versionName=[^ ]*' | sed 's/versionName=//'
}

pst_version_code() {
  sh_shell dumpsys package "${1:-}" 2>/dev/null | grep -m1 -oE 'versionCode=[0-9]+' | sed 's/versionCode=//'
}

# 快照要求「签名 SHA-256」：直接对设备上的 APK 做 sha256sum（README §3 的取证口径）
# Git Bash / MSYS 的坑（真机实测）：把设备端路径 /system/... 当本地路径改写，
# 会把命令拆坏成 `sha256 sha256sum:` 这种输出。
# 修法：整串一条命令传过去 + 路径单引号 + 关掉路径转换（MSYS_NO_PATHCONV=1）。
pst_apk_sha256() {
  local apk="${1:-}" out
  [ -n "$apk" ] || return 1
  # 两段兜底：先关路径转换整串传；不行再原样整串传一次（不同 Git Bash 版本行为不一致）
  out="$(MSYS_NO_PATHCONV=1 sh_shell "sha256sum '$apk'" 2>/dev/null)"
  out="$(printf '%s' "$out" | awk '{print $1; exit}')"
  case "$out" in
    *[!0-9a-f]*) out="" ;;   # 含非十六进制（如 "sha256sum:" 报错前缀）→ 判空
  esac
  if [ "${#out}" -ne 64 ]; then
    out="$(sh_shell "sha256sum '$apk'" 2>/dev/null | awk '{print $1; exit}')"
    case "$out" in
      *[!0-9a-f]*) out="" ;;
    esac
  fi
  [ "${#out}" -eq 64 ] || return 1
  printf '%s' "$out"
}

# ---------------------------------------------------------------------------
# 权限三层（manifests / install / runtime）
# ---------------------------------------------------------------------------
pst_perm_lines() {
  local pkg="${1:-}" user="${2:-0}"
  pst_user_segment "$pkg" "$user" | awk '
    /runtime permissions:/ { r = 1; next }
    r && /^[[:space:]]*$/ { r = 0 }
    r { print }
  '
}

# 声明的权限短名（不含 android.permission. 前缀）
pst_perm_requested() {
  sh_shell dumpsys package "${1:-}" 2>/dev/null \
    | sed -n '/requested permissions:/,/install permissions:/p' \
    | sed -n 's/^[[:space:]]*android\.permission\.\([A-Z_0-9]*\).*/\1/p' | sort -u
}

pst_perm_granted() {  # <pkg> <user> <PERM 短名> → true/false/空
  local pkg="${1:-}" user="${2:-0}" perm="${3:-}"
  pst_perm_lines "$pkg" "$user" \
    | grep -F "android.permission.$perm:" | head -1 \
    | sed 's/.*granted=//; s/[,[:space:]].*//'
}

pst_perm_flags() {  # <pkg> <user> <PERM> → 如 USER_SET|USER_FIXED|GRANTED_BY_DEFAULT
  local pkg="${1:-}" user="${2:-0}" perm="${3:-}"
  pst_perm_lines "$pkg" "$user" \
    | grep -F "android.permission.$perm:" | head -1 \
    | sed -n 's/.*flags=\[\([^]]*\)\].*/\1/p'
}

pst_perm_install_granted() {  # <pkg> <PERM>（priv-app 的 install-time 权限恒 true，撤不掉）
  sh_shell dumpsys package "${1:-}" 2>/dev/null \
    | sed -n '/install permissions:/,/User [0-9]*:/p' \
    | grep -m1 "android.permission.${2:-}:" | sed 's/.*granted=//; s/[,[:space:]].*//'
}

pst_perm_has_fixed() {  # <pkg> <user> <PERM> → 0 表示带 USER_FIXED
  pst_perm_flags "${1:-}" "${2:-0}" "${3:-}" | grep -q 'USER_FIXED'
}

# 本用户下真正有运行时记录的敏感权限（只对这些做撤销，避免对未声明的权限瞎打）
pst_perm_targets() {
  local pkg="${1:-}" user="${2:-0}" p
  for p in $SH_DANGEROUS_PERMS; do
    if pst_perm_lines "$pkg" "$user" | grep -qF "android.permission.$p:"; then
      printf '%s\n' "$p"
    fi
  done
}

# ---------------------------------------------------------------------------
# AppOps
# ---------------------------------------------------------------------------
pst_appops_dump() {  # pst_appops_dump --uid <uid> | pst_appops_dump <pkg>
  case "${1:-}" in
    --uid) sh_shell cmd appops get --uid "${2:-}" ;;
    *)     sh_shell cmd appops get "${1:-}" ;;
  esac
}

# 从 stdin 的 appops 输出里取某 op 的当前值（统一解析，避免两处口径漂移）
pst_appops_value_stdin() {
  awk -v op="${1:-}" '
    { line = $0; sub(/^[[:space:]]+/, "", line) }
    index(line, op ":") == 1 {
      v = line
      sub(/^[^:]*:[[:space:]]*/, "", v)
      sub(/;.*/, "", v)
      print v
      exit
    }
  '
}

pst_appops_value() {  # <pkg> <OP>
  pst_appops_dump "${1:-}" | pst_appops_value_stdin "${2:-}"
}

pst_appops_uid_value() {  # <uid> <OP>
  pst_appops_dump --uid "${1:-}" | pst_appops_value_stdin "${2:-}"
}

# ---------------------------------------------------------------------------
# 组件
# ---------------------------------------------------------------------------
pst_components() {  # 输出 pkg/<组件名> 形式，去重
  # 坑：APK 路径也长成 pkg/com.x.y.apk 的样子，必须排除掉，否则会拿 APK 当组件去 pm disable-user
  local pkg="${1:-}" line rest
  [ -n "$pkg" ] || return 0
  sh_shell dumpsys package "$pkg" 2>/dev/null \
    | tr ' ' '\n' | grep -F "$pkg/" | sed 's/[,}].*//' \
    | while IFS= read -r line; do
        rest="${line#"$pkg/"}"
        case "$rest" in
          ''|*/*)  continue ;;   # 目录 / 多段路径，不是组件
          *.apk)   continue ;;   # APK 文件
          *[!0-9]*) : ;;         # 正常组件名
          *)       continue ;;   # 纯数字（sharedUser 的 uid/10100 之类）
        esac
        printf '%s\n' "$line"
      done | sort -u | sed '/^$/d'
}

pst_disabled_components() {
  sh_shell dumpsys package "${1:-}" 2>/dev/null \
    | sed -n '/disabledComponents:/,/^[[:space:]]*$/p' \
    | sed 's/^[[:space:]]*//' | grep -F "${1:-}/"
}

pst_component_disabled() {  # <pkg> <component>
  pst_disabled_components "${1:-}" | grep -qF -- "${2:-}"
}

# ---------------------------------------------------------------------------
# 干扰限制 / 网络策略 / 进程
# ---------------------------------------------------------------------------
pst_distraction_flags() {
  local v
  v="$(pst_user_segment "${1:-}" "${2:-0}" | grep -m1 -oE 'distractionFlags=[0-9]+' | sed 's/.*=//')"
  if [ -z "$v" ]; then
    v="$(sh_shell dumpsys package "${1:-}" 2>/dev/null | grep -m1 -oE 'distractionFlags=[0-9]+' | sed 's/.*=//')"
  fi
  printf '%s' "$v"
}

pst_netpolicy_blacklist() { sh_shell cmd netpolicy list restrict-background-blacklist 2>/dev/null; }

pst_netpolicy_has_uid() {  # <uid>
  local uid="${1:-}" line
  while IFS= read -r line; do
    [ "$line" = "$uid" ] && return 0
  done <<<"$(pst_netpolicy_blacklist)"
  # 有些 ROM 把多个 uid 打在一行
  case "$(pst_netpolicy_blacklist)" in
    *"$uid"*) return 0 ;;
  esac
  return 1
}

pst_netpolicy_policy() {
  sh_shell dumpsys netpolicy 2>/dev/null | grep -m1 -oE 'restrict_background=[^ ,]*|policy=[0-9]+ \([^)]*\)'
}

pst_process_count() {
  local n
  n="$(sh_shell ps -A 2>/dev/null | grep -cF -- "${1:-}")"
  printf '%s' "${n:-0}"
}

pst_service_count() {
  local n
  n="$(sh_shell dumpsys activity services "${1:-}" 2>/dev/null | grep -cF -- "${1:-}")"
  printf '%s' "${n:-0}"
}

pst_alarm_refs() {
  sh_shell dumpsys alarm 2>/dev/null | grep -F -- "${1:-}"
}

# 是否被排进 force-standby（u<user>a<appid>）
pst_alarm_restricted() {  # <pkg> <user> <uid>
  local tag
  tag="$(um_alarm_tag "${2:-0}" "${3:-0}")"
  sh_shell dumpsys alarm 2>/dev/null \
    | grep -A80 'Restricted packages' \
    | grep -qE "(^|[[:space:]])${tag}([[:space:]]|$)"
}

# ---------------------------------------------------------------------------
# 汇总（供 audit / plan / 快照复用）
# ---------------------------------------------------------------------------
pst_posture() {  # <pkg> <user>
  local pkg="${1:-}" user="${2:-0}" uid p g
  uid="$(pst_uid "$pkg")"
  printf 'pkg=%s\n' "$pkg"
  printf 'user=%s\n' "$user"
  printf 'uid=%s\n' "${uid:-?}"
  printf 'installed=%s\n' "$(pst_installed "$pkg" "$user" && echo true || echo false)"
  printf 'enabled=%s(%s)\n' "$(pst_enabled_code "$pkg" "$user")" "$(pst_enabled_label "$(pst_enabled_code "$pkg" "$user")")"
  printf 'suspended=%s\n' "$(pst_flag "$pkg" "$user" suspended)"
  printf 'stopped=%s\n' "$(pst_flag "$pkg" "$user" stopped)"
  printf 'distractionFlags=%s\n' "$(pst_distraction_flags "$pkg" "$user")"
  printf 'apk=%s\n' "$(pst_path "$pkg")"
  printf 'versionName=%s versionCode=%s\n' "$(pst_version_name "$pkg")" "$(pst_version_code "$pkg")"
  printf 'sharedUser=%s\n' "$(pst_shared_uid "$pkg")"
  printf 'processes=%s services=%s\n' "$(pst_process_count "$pkg")" "$(pst_service_count "$pkg")"
  for p in $SH_DANGEROUS_PERMS $SH_FORBIDDEN_PERM; do
    g="$(pst_perm_granted "$pkg" "$user" "$p")"
    [ -n "$g" ] && printf 'perm:%s=%s flags=[%s]\n' "$p" "$g" "$(pst_perm_flags "$pkg" "$user" "$p")"
  done
}
