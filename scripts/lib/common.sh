#!/usr/bin/env bash
# lib/common.sh — 状态机、日志、退出码（v2.1 契约）
# 所有 lib 都 source 这个文件；调用方必须先 source 它。
#
# 四值状态（prompt 2.1 强制）：SUCCESS / FAILED / SKIPPED / UNKNOWN
# 绝不把未验证的操作写成 SUCCESS。

: "${SH_LOG_DIR:=./logs}"
: "${SH_QUIET:=0}"
: "${SH_STATE_FILE:=}"

SH_SUCCESS=0
SH_FAILED=0
SH_SKIPPED=0
SH_UNKNOWN=0

sh_ts()   { date "+%Y-%m-%d %H:%M:%S"; }
sh_stamp(){ date "+%Y-%m-%d_%H%M%S"; }

sh_log()  { [ "$SH_QUIET" = 1 ] || printf '%s\n' "$*"; }
sh_info() { [ "$SH_QUIET" = 1 ] || printf '[信息] %s\n' "$*"; }
sh_warn() { printf '[注意] %s\n' "$*" >&2; }
sh_err()  { printf '[错误] %s\n' "$*" >&2; }

sh_die() { sh_err "$*"; exit "${2:-1}"; }

sh_have() { command -v "$1" >/dev/null 2>&1; }

# sh_state <动作> <SUCCESS|FAILED|SKIPPED|UNKNOWN> <说明>
sh_state() {
  local action="$1" state="$2"; shift 2
  local detail="${*:-}"
  case "$state" in
    SUCCESS) SH_SUCCESS=$((SH_SUCCESS + 1)) ;;
    FAILED)  SH_FAILED=$((SH_FAILED + 1)) ;;
    SKIPPED) SH_SKIPPED=$((SH_SKIPPED + 1)) ;;
    UNKNOWN) SH_UNKNOWN=$((SH_UNKNOWN + 1)) ;;
    *) sh_warn "非法状态 $state（按 UNKNOWN 记）"; state=UNKNOWN; SH_UNKNOWN=$((SH_UNKNOWN + 1)) ;;
  esac
  [ "$SH_QUIET" = 1 ] || printf '  [%-7s] %-28s %s\n' "$state" "$action" "$detail"
  if [ -n "$SH_STATE_FILE" ]; then
    printf '%s\t%s\t%s\t%s\n' "$(sh_ts)" "$state" "$action" "$detail" >>"$SH_STATE_FILE"
  fi
}

# 整体判定：有任何 FAILED → 失败；全 SKIPPED → 未生效；有 UNKNOWN → 不确定
sh_verdict() {
  if [ "$SH_FAILED" -gt 0 ]; then printf 'FAILED'; return 0; fi
  if [ "$SH_UNKNOWN" -gt 0 ];  then printf 'UNKNOWN'; return 0; fi
  if [ "$SH_SUCCESS" -eq 0 ] && [ "$SH_SKIPPED" -gt 0 ]; then printf 'SKIPPED'; return 0; fi
  printf 'SUCCESS'
}

sh_summary() {
  local v; v="$(sh_verdict)"
  sh_log ""
  sh_log "== 汇总 =="
  sh_log "  SUCCESS=$SH_SUCCESS  FAILED=$SH_FAILED  SKIPPED=$SH_SKIPPED  UNKNOWN=$SH_UNKNOWN"
  sh_log "  判定: $v"
  [ "$SH_STATE_FILE" != "" ] && sh_log "  明细: $SH_STATE_FILE"
  case "$v" in
    SUCCESS|SKIPPED) return 0 ;;
    *) return 1 ;;
  esac
}

# 保护名单（v2.1 第九等级）——单一真源，所有脚本共用
SH_PROTECTED_RE='^(com\.qualcomm\..*|android$|com\.android\.(packageinstaller|permissioncontroller|systemui|settings|phone|server\.telecom|launcher3)|com\.miui\.home|com\.google\.android\.(packageinstaller|permissioncontroller))'
SH_EXPLICIT_BAN='com.qualcomm.qti.services.systemhelper'

sh_is_protected() {
  local p="$1"
  [ "$p" = "$SH_EXPLICIT_BAN" ] && return 0
  printf '%s' "$p" | grep -Eq "$SH_PROTECTED_RE"
}

# 交互确认：必须输入整串才放行（v2.1 6.4 双重确认）
sh_confirm_exact() {
  local want="$1"
  if [ "${SH_ASSUME_YES:-0}" = 1 ]; then sh_log "  (已按 SH_ASSUME_YES=1 跳过确认)"; return 0; fi
  printf '请输入确认串（原样）： %s\n> ' "$want"
  local got=""
  read -r got || true
  [ "$got" = "$want" ]
}
