# HyperOS 4.0 / API 37 实测兼容矩阵

设备：一台零售版 HyperOS 4.0 设备（Android 17 / API 37），未 Root、BL 未解锁、ADB 无线调试。
目标：`com.mobiletools.systemhelper`（/system/priv-app，vc34，versionName 4.0.0-20260729，appId 10100）。
实测时间：2026-11-07。

## 1. 能力矩阵

| 能力 | 命令 | 结论 | 原始证据 |
|---|---|---|---|
| 用户级卸载 | `pm uninstall --user 0` | **BLOCKED** | `Failure [only root can delete system app for a particular user]` |
| 用户级卸载（变体） | `-k`、`cmd package uninstall`、`--user current` | **BLOCKED** | 同上，4 种写法同一句 |
| 停用 | `pm disable-user --user 0` | **BLOCKED** | `SecurityException: Cannot disable system packages`（`PackageManagerServiceImpl.shouldRestrictEnabledSettingsChange:1116`） |
| 停用 | `pm disable --user 0` | **BLOCKED** | 同上 |
| 组件级停用 | `pm disable-user --user 0 PKG/.Receiver` | **BLOCKED** | `Shell cannot change component state for ComponentInfo{...} to 3` |
| 隐藏 | `pm hide --user 0` | **BLOCKED** | `SecurityException: Access denied, requires: android.permission.MANAGE_USERS` |
| 卸载更新 | `pm uninstall-system-updates` | NO-OP | 返回 Success，本包无 /data/app 更新 |
| 挂起 | `pm suspend --user 0` | **PASS** | `suspended=true`，`suspendingPackage=<0>com.android.shell`，持久化 |
| 干扰限制 | `pm set-distracting-restriction --flag hide-notifications --flag hide-from-suggestions` | **PASS** | `distractionFlags=3` |
| 清数据 | `pm clear --user 0` | **PASS** | `Success` |
| 运行时权限撤销 | `pm revoke` | **PASS（需配 USER_FIXED）** | 见下节 |
| 特权/系统权限撤销 | `pm revoke READ_PRIVILEGED_PHONE_STATE` | **UNSUPPORTED** | priv-app 由安装授权，install permissions 恒 granted=true |
| ACCESS_LOCAL_NETWORK | `pm revoke` | **UNSUPPORTED** | flags 含 `REVOKE_WHEN_REQUESTED`，撤销被系统忽略 |
| AppOps | `cmd appops set --uid 10100 <OP> ignore` | **PASS** | 52 项 ignore（loc/sms/contacts/camera/mic/phone-state/usage/wakelock/bg-run/fg-service/vpn） |
| 后台网络 | `cmd netpolicy add restrict-background-blacklist 10100` | **PASS** | UID 10100 出现在 blacklist |
| 强停 | `am force-stop --user 0` | **PASS** | 进程归零 |
| 设备管理员 | `dpm list-owners` | 无 | 未设置 device/profile owner |

## 2. 两个致命顺序坑

1. **`pm clear` 会把运行时权限重置为默认授予。** 正确顺序：`pm clear` → `pm revoke` + `set-permission-flags user-set user-fixed`。先撤销后 clear 等于白撤（实测：撤销后 clear，权限回到 granted=true）。
2. **`pm revoke` 单独用时对 `GRANTED_BY_DEFAULT` 权限不稳定**，必须紧跟 `pm set-permission-flags <pkg> <perm> user-set user-fixed`，否则系统重算授权就回来了。冻结后 `flags=[ USER_SET|USER_FIXED|GRANTED_BY_DEFAULT]`、`granted=false`，重启与 OTA 都不会复位。

## 3. `dumpsys package` 读数陷阱

- `runtime permissions:` 每段用户各一份（User 0 / User 999）。直接 `sed -n '/runtime permissions:/,/User 999/p'` 会把 User 999 的默认值当成 User 0 的结果，**造成"撤销失败"的误判**。必须用 awk 按 `^    User <id>:` 切段。
- 本机 `pm list packages`（含 `-u` / `-d`）在 shell 下返回 **0 行**，必须改用 `cmd package list packages [--user]`。
- `getprop ro.build.version.sdk` / `ro.build.version.release` 无输出；可用的是 `ro.mi.os.version.name`、`ro.product.model`、`ro.build.version.incremental`。

## 4. 无 Root 的真实上限

`uninstall` / `disable` / `hide` / 组件禁用四条路在 HyperOS 4.0 全封闭，**冻结组合**才是可达终点：

```
pm suspend  +  AppOps 全 ignore  +  运行时权限 revoke+USER_FIXED
            +  pm clear  +  hide-notifications/from-suggestions
            +  netpolicy 后台黑名单  +  am force-stop
```

残留只三项，均无运行能力：
- `/system/priv-app` 里的 3.9MB APK（只读系统分区，无 root 不可删）
- AlarmManager 里 6 条 PendingIntent（挂起态不投递）
- 组件仍在 PackageManager 注册表中（9 个），但不可被启动

## 5. 若确实要物理删除

只有两条：
1. 解锁 BL + root/改 super.img 后删 `/system/priv-app/com.mobiletools.systemhelper`（破坏 OTA、部分金融/指纹校验环境）。
2. 保持冻结态（推荐）：功能等价于删除，OTA 不会复活。
