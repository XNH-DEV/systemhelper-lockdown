# 恢复（RECOVERY）

> 与 [RESTORE_GUIDE.md](RESTORE_GUIDE.md) 的区别：这份讲**故障恢复**（搞坏了怎么救），那份讲**正常回滚**。

## 1. 故障分级

| 级别 | 现象 | 处理 |
|---|---|---|
| L1 单步失败 | 某条命令报错，其他正常 | 看 `execution.tsv` 定位，单独重试 |
| L2 多步失败 | 一批操作没生效 | `verify.sh` 出报告，按层重做 |
| L3 状态异常 | 包被停用/挂起导致系统提示异常 | 按 §2 逐条解除 |
| L4 系统异常 | 开机异常、系统服务崩 | 安全模式 / 恢复出厂（最后手段） |

## 2. 常用急救命令

```bash
# 解除挂起（最常见）
pm unsuspend --user 0 com.mobiletools.systemhelper

# 恢复启用状态（如果曾被禁用）
pm enable --user 0 com.mobiletools.systemhelper

# 清掉通知限制
pm set-distracting-restriction --user 0 com.mobiletools.systemhelper

# AppOps 全部回 default
for op in RUN_ANY_IN_BACKGROUND RUN_IN_BACKGROUND START_FOREGROUND WAKE_LOCK \
          SCHEDULE_EXACT_ALARM POST_NOTIFICATION; do
  cmd appops set com.mobiletools.systemhelper $op default
done

# 移出后台流量黑名单
cmd netpolicy remove restrict-background-blacklist 10100

# 权限恢复（仅限原本就授予的）
pm grant --user 0 com.mobiletools.systemhelper android.permission.READ_PHONE_STATE
```

## 3. 恢复后必须复核的 10 项

1. `installed` / `enabled` / `suspended` / `stopped`
2. `cmd appops get` 六个 op 的值
3. `cmd netpolicy list restrict-background-blacklist`
4. `pm path`（APK 是否还在）
5. `sha256sum <apk>`（是否与快照一致）
6. `ps -A | grep <pkg>`
7. `dumpsys activity services <pkg>`
8. `dumpsys alarm | grep <pkg>`
9. `settings get secure enabled_accessibility_services`
10. `settings get secure enabled_notification_listeners`

## 4. 快照损坏怎么办

- `manifest.json` 缺失或 JSON 损坏 → `rollback.sh` 直接拒绝（防止用残缺快照做危险恢复）
- `original_state/dumpsys-package.txt` 缺失 → 同样拒绝
- 只有 txt 没有 json → 手工按 §2 恢复，并在新快照里补齐

## 5. 不可恢复项（必须事先说清）

| 项 | 说明 |
|---|---|
| `pm clear` 清掉的数据 | 应用数据 / SQLite 队列 / 缓存，永久丢失 |
| `--user` 卸载后的数据 | `install-existing` 只恢复 APK 注册 |
| MIUI 联网控制开关 | 私有库，需要手点 |
| 系统分区 APK | 从未删除，无需恢复 |

## 6. 跨设备禁止

`manifest.json` 里存了 serial 的哈希（`serial_hash`，前 12 位），`rollback.sh` 会校验包名与用户；**不允许把 A 设备的快照用在 B 设备上**。

## 7. 极限情况

如果处置后手机出现异常（反复弹窗、系统卡顿）：

1. `pm unsuspend` + `pm enable` + AppOps 全 default（§2）
2. 仍异常 → 重启
3. 仍异常 → 在"设置 → 应用 → 显示系统应用"里确认该包状态
4. 最后手段：恢复出厂（会丢数据，务必先备份）
