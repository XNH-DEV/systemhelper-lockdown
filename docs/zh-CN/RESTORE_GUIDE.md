# 恢复指南（RESTORE GUIDE）

> 原则：**回滚不是"全部反过来做一遍"，而是"按快照恢复原值"。**

## 1. 为什么旧的回滚是错的

旧版 `rollback.sh`：

```bash
cmd appops set <pkg> RUN_ANY_IN_BACKGROUND default   # ← 原本可能就是 ignore
pm grant <pkg> android.permission.READ_PHONE_STATE   # ← 原本可能就是 denied
```

这会让设备回到一个**从没存在过的状态**：把用户明确拒绝的权限塞回去，把系统原本的 ignore 改成 default。规格书 §2.3 明确禁止。

## 2. 新版怎么做的

1. 处置前 `lockdown.sh` / `snapshot.sh` 先把原始状态落到 `logs/<ts>/original_state/`
2. 回滚时逐项比对：
   - 权限：只有快照里 `granted=true` 的才 `pm grant`
   - AppOps：只有快照里不是 `ignore` 的才设回原值
   - netpolicy：只有快照里**不在**黑名单的才移除
   - suspend / distraction：只有快照里是 `false` / `0` 的才解除
3. 每步回读；失败记 FAILED，不回读到的记 UNKNOWN
4. 快照缺 `dumpsys-package.txt` → 直接拒绝自动执行

## 3. 使用

```bash
bash scripts/rollback.sh --dry-run     # 先看会改什么
bash scripts/rollback.sh               # 用最新快照
bash scripts/rollback.sh --snap logs/2026-11-07_005722
```

## 4. 手动逐条（等价）

```bash
pm unsuspend --user 0 com.mobiletools.systemhelper
pm set-distracting-restriction --user 0 com.mobiletools.systemhelper
cmd appops set com.mobiletools.systemhelper RUN_ANY_IN_BACKGROUND default
cmd appops set com.mobiletools.systemhelper RUN_IN_BACKGROUND default
cmd appops set com.mobiletools.systemhelper START_FOREGROUND default
cmd appops set com.mobiletools.systemhelper WAKE_LOCK default
cmd appops set com.mobiletools.systemhelper SCHEDULE_EXACT_ALARM default
cmd netpolicy remove restrict-background-blacklist <uid>
am set-inactive --user 0 com.mobiletools.systemhelper false
pm grant --user 0 com.mobiletools.systemhelper android.permission.READ_PHONE_STATE   # 仅当原本就授予
```

## 5. 恢复不到的东西（必须提前说清）

| 项 | 能否恢复 | 说明 |
|---|---|---|
| `pm clear` 清掉的数据 | ❌ | 应用数据、SQLite 队列、缓存不可逆 |
| `install-existing` 后的数据 | ❌ | 只恢复 APK 注册，不恢复数据 |
| 特权权限 | 部分 | `READ_PRIVILEGED_PHONE_STATE` 无 grant 通道，重启后由系统按默认恢复 |
| MIUI 联网控制开关 | 需手动 | 私有库，adb 写不进去 |
| 系统分区 APK | 无需恢复 | 从未删除 |

## 6. 恢复后的复核（10 项）

```bash
dumpsys package <pkg> | grep "User 0:"        # installed / enabled / suspended / stopped
cmd appops get <pkg>                           # 6 个 op 是否回到原值
cmd netpolicy list restrict-background-blacklist
pm path <pkg>                                  # APK 仍在？
sha256sum <apk>                                # 哈希是否与快照一致
ps -A | grep <pkg>                             # 进程
dumpsys activity services <pkg>                # 服务
dumpsys alarm | grep <pkg>                     # 定时器
settings get secure enabled_accessibility_services
settings get secure enabled_notification_listeners
```

## 7. 常见错误

| 现象 | 原因 |
|---|---|
| `pm grant` 报 `not a changeable permission type` | 特权权限，正常 |
| 恢复后仍无进程 | stopped 标记还在，等一次开机或 `am start` |
| 网络仍不通 | MIUI 联网控制被手动关过，需要自己打开 |
| 快照目录里没有 `original_state/` | 旧版脚本的产物，不足以精确回滚 → 拒绝执行 |

## 8. 风险提醒

- 回滚会**削弱**已经生效的防护，做完复核再决定是否重新处置。
- 跨设备使用同一份快照是禁止的（`manifest.json` 里有 serial 哈希校验）。
