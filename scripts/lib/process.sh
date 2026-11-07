#!/usr/bin/env bash
# lib/process.sh — 进程 / 服务 / 定时器取证（v2.1 第三等级 + 真相核查）
# 依赖：common.sh adb.sh
#
# 原则：ps 空 ≠ 没运行过（这是 wake→collect→upload→exit 的短命进程）。
# 所以这里同时提供"活着没"和"有没有被排过"两类证据。

sh_proc_list() { sh_shell ps -A 2>/dev/null | grep -F "$1"; }
sh_proc_count() { sh_shell ps -A 2>/dev/null | grep -cF "$1"; }

sh_services_of() { sh_shell dumpsys activity services "$1" 2>/dev/null | grep -cF "$1"; }
sh_service_table() { sh_shell dumpsys package "$1" 2>/dev/null | sed -n '/Service Resolver Table/,/Domain verification/p'; }

# Alarm：dumpsys alarm 里是 u<user>a<appId>，appId = uid - 10000（uid ≥ 10000 时）
sh_alarm_appid() { local u="$1"; if [ "$u" -ge 10000 ]; then echo $((u - 10000)); else echo "$u"; fi; }

sh_alarm_refs() {  # <pkg> → 引用行
  sh_shell dumpsys alarm 2>/dev/null | grep -F "$1"
}

sh_alarm_restricted() {  # <pkg> <uid>
  local appid; appid="$(sh_alarm_appid "$2")"
  sh_shell dumpsys alarm 2>/dev/null | grep -A50 'Restricted packages' | grep -qF "$1" && return 0
  sh_shell dumpsys alarm 2>/dev/null | grep -q "u0a${appid}" && return 0
  return 1
}

sh_exact_alarm_state() {  # <appid>
  sh_shell dumpsys alarm 2>/dev/null | grep 'Last OP_SCHEDULE_EXACT_ALARM' | grep -o "u[0-9]*a$1:[a-z]*" | head -1
}

sh_jobs_restricted() {
  sh_shell dumpsys jobscheduler 2>/dev/null | grep -A20 'Restricted packages' | grep -cF "$1"
}

sh_standby_bucket() { sh_shell am get-standby-bucket "$1"; }

sh_force_stop() { sh_shell am force-stop --user "$2" "$1"; }
sh_set_inactive() { sh_shell am set-inactive "$2" "$1" "${3:-true}"; }

# 组件是否还会被拉起：看最近有没有启动尝试/失败（logcat 抽样）
sh_recent_launch_attempts() {  # <pkg> <lines>
  sh_shell "logcat -d -t ${2:-300} 2>/dev/null | grep -i '${1}' | tail -5"
}
