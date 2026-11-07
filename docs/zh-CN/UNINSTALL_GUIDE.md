# 用户级卸载指南（UNINSTALL GUIDE）

> 目标：判断"能不能把 `com.mobiletools.systemhelper` 从用户空间拿掉"，以及系统拒绝时的准确原因。

## 1. 工作原理

`pm uninstall --user <id> <pkg>` 不删系统分区，只把包从**指定用户**的安装记录里摘掉；APK 仍在 `/data` 或 `/system`，可用 `cmd package install-existing --user <id> <pkg>` 恢复。

理论上这是无 root 最"干净"的处置。**但在 HyperOS 4.0 / API 37 上它被系统性封死。**

## 2. 实测（HyperOS 4.0）

| 命令 | rc | 原文 |
|---|---|---|
| `pm uninstall --user 0` | 1 | `Failure [only root can delete system app for a particular user]` |
| `pm uninstall -k --user 0` | 1 | 同上 |
| `pm uninstall --user current` | 1 | 同上 |
| `cmd package uninstall --user 0` | 1 | 同上 |
| `pm uninstall-system-updates` | 0（stdout `Success`） | 无更新层可卸，等于空跑 |

**结论**：不是权限不足、不是包状态问题，是 PackageManager 的硬判定（系统应用 + 非 root → 拒绝按用户删除）。

## 3. 卸载前必须检查的 13 项（脚本 `dependency_check.sh` 实现）

1. 目标包是否存在
2. 是否系统预装（`pm path` 落在 `/system|/product|/system_ext|/vendor`）
3. 是否有 `/system/priv-app` 原始 APK
4. 是否有 `/product/priv-app` 原始 APK
5. 是否有 `/system_ext/priv-app` 原始 APK
6. 是否有 `/data/app` 更新版本
7. 是否多 split（`pm path` 行数 > 1）
8. 是否 sharedUserId
9. 是否有其他用户安装（`User 999` 等）
10. 是否有工作资料（managed profile）
11. 是否设备管理角色
12. 是否有系统关键服务依赖（`dumpsys` 引用计数）
13. 是否有其他应用显式 Intent/ContentProvider 依赖

## 4. 风险分级（对应 UNINSTALL_RISK_MATRIX.md）

| 级别 | 含义 | 本项目策略 |
|---|---|---|
| SAFE | 有充分证据、风险低 | 允许（仍需双重确认） |
| CAUTION | 有依赖或功能不确定 | 先停用测试 |
| HIGH_RISK | 可能影响系统重要功能 | 禁止自动执行 |
| BLOCKED | 关键组件/受保护 | 直接拒绝 |

**本包定级：CAUTION** —— 无 device admin、无 a11y、无通知监听、无其他包持有其签名权限；但它是运营商定制层，`RegisterHelperService` 被渠道 App（拼多多/京东）用 `<queries>` 点名做机型识别，卸载后这些 App 的识别逻辑会退化（不影响使用）。

## 5. 双重确认

```
UNINSTALL com.mobiletools.systemhelper USER 0
```

必须原样输入；`SH_ASSUME_YES=1` 只在自动化测试里用。

## 6. 如果系统允许（Android ≤14 或非系统应用）

```bash
bash scripts/restriction/uninstall_user.sh --user 0
# 等价手动：
pm uninstall --user 0 com.mobiletools.systemhelper
# 验证：
cmd package list packages --user 0 | grep com.mobiletools.systemhelper   # 应无输出
dumpsys package com.mobiletools.systemhelper | grep "User 0:"            # installed=false
```

## 7. 常见错误

| 输出 | 含义 |
|---|---|
| `only root can delete system app for a particular user` | API 35+ 硬墙，放弃此路 |
| `DELETE_FAILED_DEVICE_POLICY_MANAGER` | 是设备管理员，先 `dpm remove-active-admin` |
| `DELETE_FAILED_INTERNAL_ERROR` | 系统包被其他组件占用，先 `am force-stop` |
| `Unknown package` | 已经卸载过，或包名拼错 |

## 8. 恢复

```bash
cmd package install-existing --user 0 com.mobiletools.systemhelper
```

**数据不会回来**（`--user` 卸载会删该用户数据目录）；`install-existing` 只恢复 APK 注册，不恢复 SQLite 队列、SharedPreferences、缓存。

## 9. 版本差异

| 版本 | 行为 |
|---|---|
| Android 11–14 | 系统应用的 `--user` 卸载在多数 ROM 上允许（部分 OEM 已收紧） |
| Android 15+ | AOSP 引入 `only root can delete system app for a particular user` |
| HyperOS 4.0 | 上述硬墙 + 额外的 `Cannot disable system packages` |
