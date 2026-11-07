# 停用指南（DISABLE GUIDE）

> 目标：对指定用户"停用"这个包（`enabled=DENIED`），并说明为什么在 HyperOS 4.0 上做不到。

## 1. 工作原理

`pm disable-user --user <id> <pkg>` → `PackageManager.setApplicationEnabledSetting(pkg, COMPONENT_ENABLED_STATE_DISABLED_USER)`。
停用后：组件不可启动、广播不投递、Activity 不可见，但 APK 仍在、数据仍在、可一键 `pm enable` 恢复。

## 2. 实测结果（HyperOS 4.0）

```
$ pm disable-user --user 0 com.mobiletools.systemhelper
Exception occurred while executing 'disable-user':
java.lang.SecurityException: Cannot disable system packages.
    at com.android.server.pm.PackageManagerServiceImpl.shouldRestrictEnabledSettingsChange(PackageManagerServiceImpl.java:1116)
    at com.android.server.pm.PackageManagerService.setEnabledSettings(PackageManagerService.java:4530)
```

`pm disable --user 0` → 同一异常。
组件级 `pm disable-user --user 0 <pkg>/.control.OnBootReceiver` →

```
SecurityException: Shell cannot change component state for ComponentInfo{...} to 3
    at com.android.server.pm.PackageManagerService.setEnabledSettings(PackageManagerService.java:4553)
```

**结论**：HyperOS 4.0 在 `PackageManagerServiceImpl` 里加了一层"系统包不允许 shell 改 enabled 状态"的私有判定，包级和组件级都被拦。

## 3. 适用条件

- Android ≤ 14：`pm disable-user` 对多数预装应用有效
- 非系统应用（`pm path` 不在 `/system|/product|/system_ext`）
- 部分 OEM（MIUI 14 之前、HyperOS 2/3）系统包也可停用

## 4. 不适用条件

- HyperOS 4.0 系统包（本机）→ 直接报 BLOCKED
- 目标是设备管理员 → 先解除
- 目标正被其他进程持有（先 `am force-stop`）

## 5. 使用命令

```bash
bash scripts/restriction/disable_package.sh --user 0
# 手动等价：
pm disable-user --user 0 com.mobiletools.systemhelper
pm list packages -d | grep com.mobiletools.systemhelper    # 期望出现在 disabled 列表
dumpsys package com.mobiletools.systemhelper | grep "User 0:"   # 期望 enabled=3
```

## 6. 预期结果

- 成功：`enabled=3`（`COMPONENT_ENABLED_STATE_DISABLED_USER`），`pm list packages -d` 能看到
- 本机：抛 `Cannot disable system packages`，脚本记录 `FAILED: BLOCKED(HyperOS)`，**不会报成功**

## 7. 常见错误

| 现象 | 原因 |
|---|---|
| `Cannot disable system packages` | HyperOS 私有判定 |
| `Shell cannot change component state` | 组件级同样受限 |
| `Unknown package` | 包名错 / 已卸载 |
| 停用后仍被拉起 | 有别的应用显式 bind 其 Service → 先查依赖 |

## 8. 如何恢复

```bash
pm enable --user 0 com.mobiletools.systemhelper
```

恢复时要检查快照：**原来就被用户禁用的应用不应被无条件启用**（`rollback.sh` 会读 `original_state/dumpsys-package.txt` 的 `enabled=` 原值）。

## 9. 版本差异

| 版本 | `pm disable-user` 对系统包 |
|---|---|
| Android 9–12 | 多数可用 |
| MIUI 13/14 | 多数可用 |
| HyperOS 2/3 | 部分可用 |
| **HyperOS 4.0（API 37）** | **全部被拒（实测）** |

## 10. 替代方案

停用不可用时，等效能力由以下组合提供（见 RESTRICTION_GUIDE）：

- `pm suspend`（系统级挂起，最强）
- AppOps 全禁
- `am force-stop` + `am set-inactive`
