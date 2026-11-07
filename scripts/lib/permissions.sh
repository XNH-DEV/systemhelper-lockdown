#!/usr/bin/env bash
# lib/permissions.sh — 权限三层判定 + 撤销（v2.1 第二等级）
# 依赖：common.sh adb.sh package.sh
#
# 三层必须分开看，不能混：
#   1) Manifest 声明   = dumpsys "requested permissions:"
#   2) 安装期授权      = dumpsys "install permissions:"（priv-app 恒 granted=true，撤不掉）
#   3) 运行时授权      = dumpsys "runtime permissions:"（按用户，可 revoke）
#
# 实测坑（HyperOS 4.0 / API 37）：
#   * pm revoke 单独用会被系统重算覆盖 → 必须紧跟 set-permission-flags user-set user-fixed
#   * pm clear 会把运行时权限重置回默认 → 撤销必须放在 clear 之后
#   * ACCESS_LOCAL_NETWORK 带 REVOKE_WHEN_REQUESTED，撤销被忽略

SH_DANGEROUS_PERMS="READ_PHONE_STATE READ_EXTERNAL_STORAGE ACCESS_FINE_LOCATION ACCESS_COARSE_LOCATION ACCESS_BACKGROUND_LOCATION BLUETOOTH_CONNECT"
SH_PRIV_PERMS="READ_PRIVILEGED_PHONE_STATE READ_PRECISE_PHONE_STATE PACKAGE_USAGE_STATS QUERY_ALL_PACKAGES WRITE_SECURE_SETTINGS"

sh_perm_requested() {  # 声明的权限名列表
  sh_shell dumpsys package "$1" 2>/dev/null | sed -n '/requested permissions:/,/install permissions:/p' \
    | sed -n 's/^ *android\.permission\.\([A-Z_0-9]*\).*/\1/p' | sort -u
}

sh_perm_install_granted() {  # <pkg> <PERM> → true/false
  sh_shell dumpsys package "$1" 2>/dev/null | sed -n '/install permissions:/,/User [0-9]*:/p' \
    | grep -m1 "android.permission.$2:" | sed 's/.*granted=//;s/[ ,].*//'
}

sh_perm_runtime_granted() {  # <pkg> <user> <PERM>
  sh_pkg_runtime_perms "$1" "$2" | grep "android.permission.$3:" | sed 's/.*granted=//;s/[, ].*//' | head -1
}

sh_perm_is_signature() {
  sh_shell dumpsys package "$1" 2>/dev/null | grep -q "Permission \[android.permission.$2\]" && return 0
  return 1
}

# 撤销单个运行时权限 + 锁定（这是唯一在真机上不会被重算覆盖的写法）
sh_perm_revoke_fixed() {  # <pkg> <user> <PERM>
  local pkg="$1" user="$2" perm="$3" o1 o2
  o1="$(sh_shell pm revoke --user "$user" "$pkg" "android.permission.$perm")"
  o2="$(sh_shell pm set-permission-flags --user "$user" "$pkg" "android.permission.$perm" user-set user-fixed)"
  if [ -n "$o1$o2" ]; then
    case "$o1$o2" in
      *Exception*|*Error*|*error*) printf 'FAILED:%s%s' "$o1" "$o2"; return 1 ;;
      *) printf 'FAILED:%s%s' "$o1" "$o2"; return 1 ;;
    esac
  fi
  printf 'OK'
  return 0
}

# 撤销后必须回读，回读不是 false 就当失败（v2.1 "检查撤销后权限状态是否发生变化"）
sh_perm_verify_revoked() {  # <pkg> <user> <PERM>
  local v; v="$(sh_perm_runtime_granted "$1" "$2" "$3")"
  [ "$v" = "false" ]
}

sh_perm_grant() {
  sh_shell pm grant --user "$2" "$1" "android.permission.$3"
}

sh_perm_clear_flags() {
  sh_shell pm clear-permission-flags --user "$2" "$1" "android.permission.$3" user-set user-fixed
}
