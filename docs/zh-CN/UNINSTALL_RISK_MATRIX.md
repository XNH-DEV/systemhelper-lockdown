# 卸载风险矩阵（UNINSTALL RISK MATRIX）

> 对 `com.mobiletools.systemhelper` 逐项打分。**任何一项拿不到证据就记 UNKNOWN，不许猜 SAFE。**

## 1. 判据

| 维度 | 检查方法 | 本机结果 |
|---|---|---|
| 设备管理员 | `dumpsys device_policy \| grep <pkg>` | 0 命中 → 不是 |
| 无障碍服务 | `settings get secure enabled_accessibility_services` | 未注册 |
| 通知监听 | `settings get secure enabled_notification_listeners` | 未注册 |
| 签名权限持有者 | `dumpsys package \| grep '<pkg>.permission'` | 仅定义体 + 自身 Service 声明，无第三方持有 |
| sharedUserId | `dumpsys package <pkg> \| grep sharedUser` | 独占 `com.mobiletools.systemhelper.uid/10100`，无同伴包 |
| 多 split | `pm path <pkg> \| wc -l` | 1 |
| 工作资料 | `pm list users` | 无 managed profile（只有 0 与 999 XSpace） |
| 系统关键服务依赖 | `dumpsys package` 中 `RegisterHelperService` 的 permission | 签名级，无外部绑定方 |
| 渠道 App 依赖 | 第三方 manifest `<queries>` | 拼多多/京东等点名查询（只影响机型识别，不影响功能） |
| 开机广播 | `dumpsys package` → `OnBootReceiver` | `BOOT_COMPLETED` + `QUICKBOOT_POWERON`，`mPriority=999` |
| 定时任务 | `dumpsys alarm` | 6 条 `*walarm*`（SIM/开机/应用列表/信号） |
| JobScheduler | `dumpsys jobscheduler` | `RegisterJobService`，已进 Restricted packages |
| 网络 IOC | APK 字符串 | `dm.wo.com.cn:18080`（HTTP）/ `:18081`（HTTPS） |
| 采集合规性 | APK 读取调用 | `getDeviceId/getSubscriberId/getCellLocation/getAllCellInfo/getSignalStrength/BSSID` |

## 2. 分级

| 级别 | 本项目结论 |
|---|---|
| **BLOCKED** | 否（不是 `com.qualcomm.*`、不是系统核心） |
| **HIGH_RISK** | 否（无 device admin、无关键服务依赖） |
| **CAUTION** | **是** —— 运营商定制层，卸载会影响渠道 App 的机型识别与运营商自注册 |
| SAFE | 证据不足，不表态 |

## 3. 逐项风险表

| # | 风险点 | 影响 | 缓解 |
|---|---|---|---|
| 1 | 运营商自注册中断 | 可能影响联通侧的开卡/换机识别 | 本项目场景不需要 |
| 2 | 渠道 App 机型识别退化 | 极少数 App 的机型推荐失准 | 可接受 |
| 3 | 系统分区残留 | 占 3.9 MB | 无 root 无法消除 |
| 4 | OTA 复活 | 升级后状态可能回默认 | 每次升级重跑 |
| 5 | 数据无法备份 | `--user` 卸载会清数据 | 事先 `pm clear` 也不可逆 |

## 4. 执行门槛

- 必须通过 13 项前置检查
- 必须双重确认串精确匹配
- 必须先生成快照（`manifest.json` + `original_state/`）
- **在 HyperOS 4.0 上实际操作会被系统拒绝**（`only root can delete system app for a particular user`），因此本矩阵在本机只用于"判断该不该试"，不用于"能不能成功"

## 5. UNKNOWN 清单（本机拿不到证据的项）

- 服务端是否真的收到过上报：需要抓包或服务端日志，设备侧无法证明
- 历史累计流量：Settings 里的联网统计是另一套持久计数器，与 `netstats` 不同源
- 卸载后系统是否会出现隐性异常：本机被拒绝执行，无法实测
