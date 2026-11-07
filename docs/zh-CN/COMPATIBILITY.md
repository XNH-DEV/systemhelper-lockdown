# 兼容性（COMPATIBILITY）

> 本机实测详见 [COMPATIBILITY-hyperos4.md](COMPATIBILITY-hyperos4.md)（逐条原始报错）。

## 1. 已验证环境

| 项 | 值 |
|---|---|
| 设备 | 一台零售版 HyperOS 4.0 设备 |
| ROM | HyperOS 4.0 (Android 17 / API 37) |
| Android | 17 / API 37（`getprop ro.build.version.sdk` 在本机无输出，用 `ro.mi.os.version.name` 判断 ROM） |
| root | 无（`ro.debuggable=0`，`adb root` 不可用） |
| Bootloader | 未解锁 |
| 连接 | 无线调试 `adb connect 192.168.3.88:5555` |

## 2. 能力矩阵（按 Android 版本）

| 能力 | A11–14 | A15/16 (API 35/36) | HyperOS 4.0 (API 37) |
|---|---|---|---|
| `pm uninstall --user` 系统包 | 多数可用 | 被 AOSP 拦 | ❌ `only root can delete...` |
| `pm disable-user` 系统包 | 多数可用 | 多数可用 | ❌ `Cannot disable system packages` |
| 组件级 disable | 可用 | 可用 | ❌ `Shell cannot change component state` |
| `pm hide` | 需 root | 需 root | ❌ 需 MANAGE_USERS |
| `pm suspend` | ✅ | ✅ | ✅ |
| `pm clear` | ✅ | ✅ | ✅ |
| `pm set-distracting-restriction` | ✅ | ✅ | ✅ |
| `cmd appops set` | ✅ | ✅ | ✅ |
| `cmd netpolicy` | ✅ | ✅ | ✅ |
| `pm revoke` + `USER_FIXED` | ✅ | ✅ | ✅ |
| `ACCESS_LOCAL_NETWORK` 撤销 | N/A | ❌ | ❌ |

## 3. 命令差异（必须适配的坑）

| 坑 | 现象 | 适配 |
|---|---|---|
| `pm list packages` | HyperOS 4.0 上 shell 调用 rc=0 但零输出 | 一律用 `cmd package list packages` |
| `getprop ro.build.version.sdk` | 无输出 | 用 `ro.mi.os.version.name` / `ro.build.version.incremental` |
| `am set-standby-bucket` | rc=0 但 `bucket=10 reason=f` 恒定 | 放弃这条杠杆，改用 AppOps + suspend |
| `dumpsys package` 多用户 | 每段用户各一份 `runtime permissions` | 用 awk 按 `^    User <id>:` 切段 |
| `dumpsys alarm` 的 uid 表示 | `u<user>a<appId>`，appId = uid − 10000 | 提供 `sh_alarm_appid` 换算 |

## 4. 未验证环境（明确 UNKNOWN）

- HyperOS 5.x / Android 18
- MIUI 14 / HyperOS 2 / HyperOS 3（README 里说"大概率适用"，但本项目未实测）
- 三星/华为/OPPO 等 OEM 的对应策略
- 模拟器（`am start --display` 被 `SafeActivityOptions.checkPermissions` 拦）

## 5. 结论

**所有命令都是通用 `adb shell`，唯一 OEM 专有的是 MIUI 的「应用联网」UI（手点，adb 写不进）。**
落到别的设备上，能力矩阵要重测，不要照抄结论。
