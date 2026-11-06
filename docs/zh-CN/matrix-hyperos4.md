# HyperOS 4.0 处置命令实测矩阵

> English version: [../matrix-hyperos4.md](../matrix-hyperos4.md)

测试环境：零售版 HyperOS 4.0（Android 17 / API 37），未 root、未解 BL、`ro.debuggable=0`。
所有返回原文照抄（含换行），方便直接 `grep` 比对。

---

## 一、卸载 / 禁用阶梯

```bash
pm uninstall -k --user 0 com.mobiletools.systemhelper
# Failure [only root can delete system app for a particular user]            rc=1

pm uninstall --user 0 com.mobiletools.systemhelper
# Failure [only root can delete system app for a particular user]            rc=1

cmd package uninstall --user 0 com.mobiletools.systemhelper
# Failure [only root can delete system app for a particular user]            rc=1

pm hide com.mobiletools.systemhelper
# java.lang.SecurityException: Access denied, requires: android.permission.MANAGE_USERS
#   at com.android.server.pm.PackageManagerService$IPackageManagerImpl.setApplicationHiddenSettingAsUser(...)  rc=255

pm disable-user --user 0 com.mobiletools.systemhelper
# java.lang.SecurityException: Cannot disable system packages.
#   at com.android.server.pm.PackageManagerServiceImpl.shouldRestrictEnabledSettingsChange(PackageManagerServiceImpl.java:1116)
#   at com.android.server.pm.PackageManagerService.setEnabledSettings(...)                                   rc=255

pm disable --user 0 com.mobiletools.systemhelper
# java.lang.SecurityException: Cannot disable system packages.                                              rc=255

pm suspend --user 0 com.mobiletools.systemhelper
# Package com.mobiletools.systemhelper new suspended state: true                                            rc=0   ✅
```

## 二、其他变体（都不成立）

```bash
pm uninstall-system-updates com.mobiletools.systemhelper
# Success（stdout）但 rc=1 —— 本包无更新层，APK 直接在 /system

pm revoke com.mobiletools.systemhelper android.permission.ACCESS_LOCAL_NETWORK
# rc=0，但回读 dumpsys package 仍是 granted=true（Android 16+ 特权默认授予，撤不掉）
```

## 三、验证成功的两条附加命令

```bash
pm set-distracting-restriction --flag hide-notifications --user 0 com.mobiletools.systemhelper
# rc=0 → dumpsys package 回读 distractionFlags=2

am force-stop com.mobiletools.systemhelper
# rc=0 → stopped=true
```

## 四、两个「命令能跑但没用」的坑

```bash
pm list packages -d
# rc=0，输出为空。HyperOS 4.0 的 pm list 子命令对 shell 不下发列表。
cmd package list packages -d
# package:…（正常输出）→ 枚举一律用 cmd package
```

```bash
am set-standby-bucket com.mobiletools.systemhelper restricted
am get-standby-bucket com.mobiletools.systemhelper
# 10（=ACTIVE，设置没生效）
dumpsys usagestats | grep 'package=com.mobiletools.systemhelper u=0 bucket'
# bucket=10 reason=f lastRestrictAttempt=+1s490ms lastRestrictReason=f
# 无论设 restricted / rare / working_set，bucket 恒为 10，reason 恒为 f(forced)
```

结论：本机这条杠杆是死的，别指望靠 standby bucket 降频。

## 五、组件拉起测试（证明它起不来）

```bash
am startservice -n com.mobiletools.systemhelper/.service.RegisterHelperService
# Error: Requires permission com.mobiletools.systemhelper.permission      rc=255

am start-foreground-service -n com.mobiletools.systemhelper/.service.RegisterHelperService
# Error: Requires permission com.mobiletools.systemhelper.permission      rc=255

am start -n com.mobiletools.systemhelper/.Activity.TestActivity
# java.lang.SecurityException: Permission Denial: starting Intent … requires
#   com.mobiletools.systemhelper.permission                               rc=255

am broadcast -a android.intent.action.BOOT_COMPLETED -n com.mobiletools.systemhelper/.control.OnBootReceiver
# java.lang.SecurityException: Permission Denial: not allowed to send broadcast
#   android.intent.action.BOOT_COMPLETED from pid=…, uid=2000              rc=255

ps -A | grep -i mobiletools      # 三次尝试后仍为空
```

> 注意：这三条失败的原因是**组件受签名级权限保护**（shell 也起不来），不是因为我们把它禁用了。
> 好处是第三方 App 同样拉不动它；坏处是这类测试**不能**证明「系统自己也拉不动」——真正的证据是 §6 的流量与闹钟数据。

## 六、能证明「真的没跑」的三个观测

```bash
# 1) 闹钟：它挂的 5 个 walarm 全被拒
dumpsys alarm | grep 'motion.*mobiletools\|mobiletools.*walarm' -A3
# Snapshot: type=ELAPSED_WAKEUP tag=*walarm*:com.mobiletools.systemhelper/.control.SIMStateReceiver
#           policyWhenElapsed: requester=… app_standby=… device_idle=…
# Reason=exact_alarm_permission_revoked ← 关键行，出现即表示该闹钟被系统丢弃

dumpsys alarm | grep -A3 'Restricted packages'
#   u0a<uid> com.mobiletools.systemhelper      ← force-standby 生效

dumpsys alarm | grep 'Last OP_SCHEDULE_EXACT_ALARM'
# … u0a<uid>:ignore …                            ← 精确定时闹钟被禁

# 2) 网络策略
dumpsys netpolicy | grep -A1 'UID=<uid>'
# UID=<uid> policy=1 (REJECT_METERED_BACKGROUND)
# UID=<uid> state=null blocked_state={blocked=APP_BACKGROUND|METERED_USER_RESTRICTED,allowed=NONE,…}

# 3) 流量（口径见 docs/zh-CN/verification.md）
dumpsys netstats detail | grep -A3 'uid=<uid> set='
```

## 七、虚拟屏（记录一个失败尝试，省得别人再踩）

```bash
settings put global overlay_display_devices 720x1600/300     # 成功，多出 Display 4
am start --display 4 -a android.settings.APPLICATION_DETAILS_SETTINGS -d package:<pkg>
# java.lang.SecurityException: Permission Denial: starting Intent … with launchDisplayId=4
#   at com.android.server.wm.SafeActivityOptions.checkPermissions(SafeActivityOptions.java:303)
```

结论：无 root 时 shell 没有 `INTERNAL_SYSTEM_WINDOW`，副屏能建但**没法把 Activity 投进去**，等于空屏。想「不动主屏操作 UI」这条路在 shell 层走不通。
