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

## 二·五、同包名 + 更高版本的空壳顶替（签名墙）

思路：做一个无害的空壳 APK，包名保持不变、`versionCode` 抬高，当「更新」装进去，让系统用它替换掉采集组件。

实测用的空壳：`package com.mobiletools.systemhelper`、`versionCode 35`（另用 `999999999` 复测过）、`minSdk 31` / `targetSdk 34`、无 dex、`android:hasCode="false"`、用我们自己的临时 RSA-2048 密钥签名。

| # | 方式 | 结果 |
|---|---|---|
| 11 | `adb install -r` | `Failure [INSTALL_FAILED_UPDATE_INCOMPATIBLE: Existing package com.mobiletools.systemhelper signatures do not match newer version; ignoring!]` |
| 12 | `adb install -r -d`（允许降级） | 同上 |
| 13 | `adb install -r -t`（允许测试包） | 同上 |
| 14 | `pm install -r --user 0` | 同上 |
| 15 | `pm install -r -t -d --user 0` | 同上 |
| 16 | `pm install -r -t -d --user 999`（另一个 profile） | 同上 |
| 17 | `cmd package install -r -t -d` | 同上 |
| 18 | `pm install-create -r -t`（成功）→ `pm install-write`（成功）→ `pm install-commit` | 提交时同上 |
| 19 | 把 `versionCode` 换成 `999999999`，重跑 11–15 | 同上 |

注意 #18：安装会话能建成功、payload 也能写进去，**卡在 commit 的签名校验**上。而且报错是签名不匹配、不是「不允许降级」——说明版本比较根本没轮到。

### 对照实验：挡路的是签名，还是 `priv-app` 身份？

用同样的流程，换一个我们自己装的普通包（`com.probe.lockdown.test`，装在 `data/app`）：

| 步骤 | 动作 | 结果 |
|---|---|---|
| A | 装 `com.probe.lockdown.test` vc=1，key=**stub** | `Success` |
| B | `-r` 升到 vc=2，**同一把** key | `Success`（升级链路正常） |
| C | `-r` 升到 vc=3，**换一把** key（`other`） | `Failure [INSTALL_FAILED_UPDATE_INCOMPATIBLE: Existing package com.probe.lockdown.test signatures do not match newer version; ignoring!]` |

结论：升级机制本身没问题，卡的是签名。要过这关，「更新包」必须与已装应用**同一张私钥**——这里是运营商 `O=CU` 的密钥，拿不到；无 root 也没有任何开关能放宽 `pm` 的签名校验。

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

---

## 八、真正走得通的一条路：PackageInstaller API（2026-11-07 补充）

第一节里那串命令全部失败，根因只有一个：`pm uninstall` 走的是 `PackageManagerShellCommand`，而
HyperOS 4.0 把那句 `only root can delete system app for a particular user` 的判断**写在这条命令里**，
不在 PackageManagerService 里。换成 `PackageInstaller.uninstall()` 发同一个卸载请求（Shizuku 系 GUI
就是这么干的），就不受这道检查管。

同一台机器、同一版本、未 root、BL 未解锁，实测：

```text
# 工具：Canta（io.github.samolego.canta）+ Shizuku（moe.shizuku.privileged.api）
# 两个都不需要 root；Shizuku 本身是用无线 adb 拉起来的

# 卸载前
$ adb shell cmd package list packages | grep -i mobiletools
package:com.mobiletools.systemhelper

# 在 Canta 里对 user 0 执行卸载之后
$ adb shell cmd package list packages | grep -i mobiletools
（空）

$ adb shell cmd package list packages -u | grep -i mobiletools
package:com.mobiletools.systemhelper     # 系统仍记得它 → 可恢复，不用重新下载
```

卸载后的状态：

```text
$ adb shell dumpsys package com.mobiletools.systemhelper | grep -m1 'User 0:'
    User 0: ceDataInode=-1 deDataInode=-1 … installed=false hidden=false suspended=true … stopped=true notLaunched=true

$ adb shell cmd package path com.mobiletools.systemhelper
（空）
```

| 字段 | 值 | 含义 |
|---|---|---|
| `installed` | `false` | user 0 上已不安装 |
| `ceDataInode` / `deDataInode` | `-1` | 应用数据已删 |
| `codePath` | 仍是 `/system/priv-app/com.mobiletools.systemhelper` | APK 留在系统镜像里 |

影响面核对：拿前一天存的 497 个包快照，跟卸载后的设备做全量 diff —— **只少了这一个包**
（`com.mobiletools.systemhelper`），新增的只有 Canta 本体和一条无关的应用更新；
`com.qualcomm.qti.services.systemhelper`、`com.miui.guardprovider` 都还在。

恢复：

```bash
adb shell cmd package install-existing --user 0 com.mobiletools.systemhelper
```

对本仓库结论的修正：**「无 root 就不能卸载」这句话说错了**。准确的说法要窄一档——
**`pm` 命令行卸不掉，`PackageInstaller` API 卸得掉。**
如果你更想「留着这个包但把它按住」，`scripts/lockdown.sh` 那套 L1–L5 仍然是对的选择
（OTA 安全、一条命令回滚）。
