# 处置指南（RESTRICTION GUIDE）

> 面向：想在无 root 设备上把 `com.mobiletools.systemhelper` 压到"零进程、零联网、零通知、零闹钟"的人。
> 对应实现：`scripts/restriction/restriction.sh`（统一入口）+ `scripts/lib/*`。

## 1. 工作原理

分五层，每层可单独执行、单独验证、单独回滚。**不要把它当成一个总开关**——规格书明确禁止"把多个机制混成一个笼统的后台限制开关"。

| 层 | 机制 | 依赖的系统能力 | 无 root 可行性 |
|---|---|---|---|
| L1 权限 | `pm revoke` + `set-permission-flags user-set user-fixed` | PackageManager 运行时权限 | ✅ |
| L2 后台 | AppOps：`RUN_IN_BACKGROUND` / `RUN_ANY_IN_BACKGROUND` / `START_FOREGROUND` / `WAKE_LOCK` / `GET_USAGE_STATS` / `ACTIVATE_VPN` | AppOpsService | ✅ |
| L3 网络 | `cmd netpolicy add restrict-background-blacklist <uid>` | NetworkPolicyManager → netd iptables | ✅（仅后台） |
| L4 冻结 | `pm suspend` + `am force-stop` + `am set-inactive` | PackageManager suspend API | ✅（唯一能"停"的方式） |
| L5 收尾 | `pm clear` + `pm set-distracting-restriction` | 同上 | ✅ |

## 2. 适用条件

- Android 11+（API 30+），`pm suspend` 存在
- 该包**已安装**（`pm path` 有输出）
- 目标不是 `com.qualcomm.qti.services.systemhelper`、不是系统核心包（保护名单会自动拒绝）

## 3. 不适用条件

- 目标已从当前用户卸载（`installed=false`）→ 先 `cmd package install-existing`
- 目标是设备管理员 / 无障碍服务 / 通知监听者 → 先解除绑定，否则处置不彻底
- 想"彻底删除 APK" → 无 root 做不到，见 UNINSTALL_GUIDE

## 4. 使用命令

```bash
# 0) 先看清楚，什么都不改
bash scripts/audit.sh --no-sample
bash scripts/restriction/restriction.sh audit

# 1) 出方案（打印将执行的命令，不动设备）
bash scripts/restriction/restriction.sh plan

# 2) 执行冻结（会先自动快照）
bash scripts/lockdown.sh

# 3) 验证（六层报告）
bash scripts/verify.sh --seconds 120
```

## 5. 预期结果

```
User 0: installed=true suspended=true stopped=true distractionFlags=3 enabled=0
进程 0 / 运行中服务 0 / netstats 该 uid 0 条
AppOps: 定位、短信、通讯录、相机、麦克风、电话状态、用量统计、WakeLock、后台运行、前台服务、VPN 全 ignore
运行时权限: 6 项 granted=false + USER_FIXED
```

## 6. 常见错误

| 现象 | 原因 | 处理 |
|---|---|---|
| `pm revoke` 返回 rc=0 但值还是 true | 单独 revoke 会被系统重算覆盖 | 必须紧跟 `pm set-permission-flags ... user-set user-fixed` |
| `pm clear` 之后权限全回来了 | clear 会重置运行时权限 | 顺序必须是 clear → revoke → USER_FIXED |
| `pm disable-user` 报 `Cannot disable system packages` | HyperOS 4.0 私有检查 | 这是硬墙，改用 suspend |
| `pm uninstall --user 0` 报 `only root can delete...` | API 35+ 收紧 | 同上，改用 suspend |
| `pm list packages` 零输出 | HyperOS 的 shell 限制 | 改用 `cmd package list packages` |
| 重启后 `stopped=false` | 开机流程会重置 stopped | 每次开机重跑 `am force-stop` |

## 7. 如何恢复

```bash
bash scripts/rollback.sh --dry-run   # 先看会改什么
bash scripts/rollback.sh             # 按快照精确回滚
```

回滚只恢复"快照里原本就是那个值"的项：原本 deny 的权限不会被授予，原本 ignore 的 AppOps 不会被改成 default。

## 8. 风险提醒

- **不是删除**：APK 仍在 `/system/priv-app`，`pm path` 仍能找到。
- **OTA 会重置**：系统升级后权限/AppOps/netpolicy 可能全部恢复，需要重跑。
- **本地队列不清空**：`pm clear` 只能清一次；一旦它被启动，会重新攒数据（见下节）。
- **MIUI 联网控制写不进去**：那是 `com.miui.securitycenter` 的私有库，只能手点。

## 9. Android 版本差异

| 版本 | 差异 |
|---|---|
| Android 11–14 | `pm uninstall --user 0` 对部分预装应用有效；`pm disable-user` 可用 |
| Android 15/16（API 35/36） | `only root can delete system app for a particular user` 开始出现；`ACCESS_LOCAL_NETWORK` 引入且带 `REVOKE_WHEN_REQUESTED` |
| HyperOS 4.0（API 37）实测 | uninstall / disable / hide / 组件禁用 全封；只有 suspend / clear / appops / netpolicy / distracting 可用 |
