#!/usr/bin/env bash
# lib/network.sh — 网络策略与 UID 流量观测（v2.1 第四等级）
# 依赖：common.sh adb.sh
#
# 注意（v2.1 明确）：后台流量限制 ≠ 全部断网。
# 无 root 下这里只能做 netd 层的 restrict-background + 观测，不能做 per-uid 全断。

sh_net_blacklist_add()    { sh_shell cmd netpolicy add restrict-background-blacklist "$1"; }
sh_net_blacklist_remove() { sh_shell cmd netpolicy remove restrict-background-blacklist "$1"; }
sh_net_blacklist_list()   { sh_shell cmd netpolicy list restrict-background-blacklist; }
sh_net_whitelist_list()   { sh_shell cmd netpolicy list restrict-background-whitelist; }

sh_net_blacklisted() {
  sh_net_blacklist_list 2>/dev/null | grep -qw "$1"
}

sh_net_policy() { sh_shell dumpsys netpolicy 2>/dev/null | grep -E 'policy=|restrict_background' | head -5; }

# 采一次 netstats 到文件
sh_net_sample() {  # <outfile>
  sh_shell dumpsys netstats detail >"$1" 2>&1
  wc -l <"$1" | tr -d ' '
}

# 汇总某 uid 的 UID 级流量（只算 uid=，不算 uid_tag，避免重复计数 —— README §6 口径）
sh_net_uid_bytes() {  # <file> <uid> → "entries rb tb rp tp"
  awk -v U="uid=$2 " '
    /^  ident=/ { on = (index($0, U) > 0); next }
    on && /st=/ {
      for (i = 1; i <= NF; i++) { split($i, p, "=")
        if (p[1] == "rb") rb += p[2]; else if (p[1] == "tb") tb += p[2]
        else if (p[1] == "rp") rp += p[2]; else if (p[1] == "tp") tp += p[2] }
      n++
    }
    END { printf "%d %d %d %d %d\n", n, rb+0, tb+0, rp+0, tp+0 }
  ' "$1"
}

# 按接口分别统计（wlan / mobile），v2.1 要求"分别记录"
sh_net_uid_by_iface() {  # <file> <uid> → "iface rb tb" 每行一条
  awk -v U="uid=$2 " '
    /^  ident=/ { on = (index($0, U) > 0); ifc="unknown"; next }
    on && /iface=/ { match($0, /iface=[^ ]+/); if (RSTART) ifc = substr($0, RSTART+6, RLENGTH-6) }
    on && /st=/ {
      for (i = 1; i <= NF; i++) { split($i, p, "=")
        if (p[1] == "rb") rb[ifc] += p[2]; else if (p[1] == "tb") tb[ifc] += p[2] }
    }
    END { for (k in rb) printf "%s %d %d\n", k, rb[k], tb[k] }
  ' "$1"
}

# 全机 uid 行数（用于证明"统计本身是活的"，README §6）
sh_net_all_uid_lines() { grep -cE 'uid=[0-9]+ set=' "$1" 2>/dev/null || echo 0; }

# 两窗口对比：打印增量并给判定
sh_net_delta() {  # <f0> <f1> <uid>
  local a b
  a="$(sh_net_uid_bytes "$1" "$3")"; b="$(sh_net_uid_bytes "$2" "$3")"
  set -- $a; local e0=$1 rb0=$2 tb0=$3 rp0=$4 tp0=$5
  set -- $b; local e1=$1 rb1=$2 tb1=$3 rp1=$4 tp1=$5
  printf 'entries %d→%d rb %d→%d tb %d→%d rp %d→%d tp %d→%d\n' \
    "$e0" "$e1" "$rb0" "$rb1" "$tb0" "$tb1" "$rp0" "$rp1" "$tp0" "$tp1"
  if [ $((rb1 - rb0)) -eq 0 ] && [ $((tb1 - tb0)) -eq 0 ] && [ $((rp1 - rp0)) -eq 0 ] && [ $((tp1 - tp0)) -eq 0 ]; then
    return 0
  fi
  return 1
}
