# 架构（ARCHITECTURE）

## 1. 分层图

```
┌─────────────────────────────────────────────────────┐
│ 入口脚本 (scripts/*.sh)                              │
│  audit.sh  preflight.sh  snapshot.sh                 │
│  lockdown.sh  verify.sh  rollback.sh                 │
│  restriction/restriction.sh  ← 统一处置入口          │
└───────────────┬─────────────────────────────────────┘
                │ source
┌───────────────▼─────────────────────────────────────┐
│ 公共库 (scripts/lib/)                                │
│  common.sh   状态机 / 保护名单 / 确认串              │
│  adb.sh      设备选择 / shell 封装 / 多设备保护      │
│  package.sh  包 / UID / 多用户 / 组件 / split        │
│  permissions.sh  权限三层 + revoke+USER_FIXED        │
│  appops.sh   AppOps 读写 + 回读校验                  │
│  network.sh  netpolicy + netstats 采样（按 iface）   │
│  process.sh  进程 / 服务 / alarm / job / standby     │
│  snapshot.sh 快照结构（JSON + original_state）       │
│  report.sh   六层报告 A–F + 四值汇总                 │
└───────────────┬─────────────────────────────────────┘
                │ adb shell
┌───────────────▼─────────────────────────────────────┐
│ 设备侧（无 root，shell uid 2000）                     │
│  PackageManager  AppOpsService  NetworkPolicyManager │
│  AlarmManager    JobScheduler   ActivityManager      │
└─────────────────────────────────────────────────────┘
```

## 2. 模块边界（为什么这样切）

| 模块 | 只做 | 不做 |
|---|---|---|
| `common.sh` | 状态枚举、日志、保护名单、确认串 | 任何 adb 调用 |
| `adb.sh` | 设备选择、命令封装、超时 | 业务判断 |
| `package.sh` | 读包状态 | 改状态 |
| `permissions.sh` | 权限查询 + 撤销/恢复 | 决定"要不要撤" |
| `appops.sh` | op 读写 + 回读 | 决定 op 集合 |
| `network.sh` | 策略 + 流量观测 | 全断网（做不到） |
| `process.sh` | 取证（进程/闹钟/任务） | 修改 |
| `snapshot.sh` | 落盘 | 处置 |
| `report.sh` | 汇总判定 | 采集 |

策略（"要不要做、做哪几层"）只出现在入口脚本里，库只提供能力。这样单测可以只测库。

## 3. 数据流

```
audit.sh
  └─ sh_snap_init ─→ logs/<ts>/{manifest,device,package,permissions,appops,network}.json
                     logs/<ts>/original_state/*.txt

lockdown.sh
  ├─ 先快照（同上）
  ├─ L0 执行层 ─→ suspend / force-stop / set-inactive
  ├─ L1 时钟层 ─→ appops SCHEDULE_EXACT_ALARM
  ├─ L2 后台层 ─→ appops RUN_*/WAKE_LOCK/START_FOREGROUND
  ├─ L3 权限层 ─→ revoke + set-permission-flags user-set user-fixed
  ├─ L4 网络层 ─→ netpolicy blacklist
  ├─ L5 通知层 ─→ distracting-restriction
  └─ 写 execution.tsv + after_state/

verify.sh
  └─ A 执行 / B 权限 / C 定时 / D 网络 / E 流量 / F 长时 六层报告

rollback.sh
  └─ 读 original_state/ 逐项比对，只恢复原值
```

## 4. 状态机

所有动作只有四种结果：

| 状态 | 含义 | 判定依据 |
|---|---|---|
| `SUCCESS` | 命令成功 **且** 回读符合预期 | rc=0 + 关键词/回读 |
| `FAILED` | 命令报错，或回读不符 | rc≠0 或异常文本 |
| `SKIPPED` | 前置条件不满足 / dry-run / 原本就是目标值 | 显式跳过 |
| `UNKNOWN` | 拿不到证据（读不到、字段不存在、版本差异） | 默认兜底 |

**没有任何路径会把"没验证的操作"记成 SUCCESS**——这是本项目的第一原则（规格书 §2.1）。

## 5. 目录结构

```
systemhelper-lockdown/
├── scripts/
│   ├── audit.sh  preflight.sh  snapshot.sh
│   ├── lockdown.sh  verify.sh  rollback.sh
│   ├── lib/ (9 个)
│   └── restriction/ (8 个 + lib/5)
├── docs/ (中英各 9 份 + 5 份处置指南)
├── tests/ (mock_adb + 用例)
├── logs/ (gitignore)
└── .github/workflows/ci.yml
```
