# 测试计划（TEST PLAN）

## 1. 原则

- **不连真机跑测试**：CI 与本地测试全部走 mock adb（`tests/mock_adb.sh`）
- **不编造结果**：任何没跑过的用例标 SKIP 并写原因
- **失败必须显性**：脚本把失败吞成 0 的缺陷（`run()` 无条件 return 0）必须被测试抓到

## 2. 测试分层

| 层 | 文件 | 覆盖 |
|---|---|---|
| 解析 | `test_parsing.sh` | UID 解析、多用户切段、AppOps 解析、netstats 聚合、alarm appId 换算 |
| 处置 | `test_lockdown.sh` | 正常/失败/dry-run/幂等/重复执行 |
| 回滚 | `test_rollback.sh` | 快照正常/缺失/损坏/部分失败/原值不覆盖 |
| 验证 | `test_verify.sh` | PASS/FAIL/WARN/UNKNOWN 判定边界 |
| 安全 | `test_safety.sh` | 保护名单、确认串、多设备拒绝、错误包名 |

## 3. 20 个必测场景（规格书第九等级）

| # | 场景 | 期望 |
|---|---|---|
| 1 | 正常停用 | `enabled=3` 回读一致 |
| 2 | 停用失败 | 记 FAILED，非 0 退出 |
| 3 | 正常恢复 | 状态回到快照原值 |
| 4 | 恢复失败 | 记 FAILED，不报成功 |
| 5 | 正常用户级卸载 | `installed=false` |
| 6 | 卸载命令不支持 | `only root...` → BLOCKED |
| 7 | `install-existing` 不支持 | 记 FAILED/UNKNOWN |
| 8 | 系统 APK 不存在 | `pm path` 空 → 拒绝 |
| 9 | 目标包不存在 | 退出码 4/5 |
| 10 | 多用户环境 | 按 `--user` 精确操作，不误伤 user 999 |
| 11 | sharedUserId | 不误判为独占 UID |
| 12 | 设备管理策略阻止 | 记 BLOCKED |
| 13 | 卸载确认串不匹配 | 拒绝执行 |
| 14 | 用户取消 | 拒绝执行 |
| 15 | 快照文件损坏 | 拒绝自动回滚 |
| 16 | UID 不匹配 | 拒绝 netpolicy/AppOps 操作 |
| 17 | 目标在保护名单 | 直接拒绝（含 `com.qualcomm.qti.services.systemhelper`） |
| 18 | 重复执行停用 | 幂等，第二次 SKIPPED |
| 19 | 重复执行卸载 | 幂等 |
| 20 | 卸载后恢复 | `install-existing` 路径 |

## 4. 关键断言

```bash
# 1) dry-run / audit 不得发出任何写命令
assert_not_called "pm uninstall|pm disable|pm hide|appops set|netpolicy add|pm clear"

# 2) 失败必须非 0
bash scripts/lockdown.sh --pkg com.not.exist; assert_exit_nonzero

# 3) 保护名单
PKG=com.qualcomm.qti.services.systemhelper bash scripts/lockdown.sh; assert_exit 3

# 4) 确认串
(echo "wrong") | bash scripts/restriction/uninstall_user.sh; assert_exit_nonzero

# 5) 多设备
MOCK_SCENARIO=multi_device bash scripts/lockdown.sh; assert_exit 4
```

## 5. 执行方式

```bash
bash tests/run_tests.sh              # 全部
bash tests/run_tests.sh --only safety
```

## 6. CI

`.github/workflows/ci.yml` 在 `ubuntu-latest` 上执行：

1. `bash -n` 全量语法检查
2. `shellcheck --severity=warning`
3. `shfmt -d`（格式差异只告警不阻断）
4. `bash tests/run_tests.sh`

**不允许**在 CI 里连接真机或执行任何设备写操作。

## 7. 未覆盖（明确 UNKNOWN）

- 真机行为差异（不同 ROM）
- 数据面：抓包、DNS 日志
- 长时（>24h）行为
- OTA 后的状态变化
