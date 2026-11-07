# 威胁模型（THREAT MODEL）

## 1. 资产

| 资产 | 敏感度 | 被谁读 |
|---|---|---|
| 设备指纹（IMEI/IMSI/ICCID） | 高 | 本包通过 `READ_PRIVILEGED_PHONE_STATE` |
| 位置（基站 TAC/CID/PCI、WiFi BSSID/RSSI） | 高 | 本包 + 内置百度定位 SDK |
| 已安装应用列表 | 中 | 本包 `QUERY_ALL_PACKAGES` |
| 蓝牙配对设备名与 MAC | 中 | 本包 |
| 使用行为（本次处置不涉及） | — | — |

## 2. 威胁主体

| 主体 | 能力 | 动机 |
|---|---|---|
| 运营商（中国联通） | 系统预装、签名 `O=CU`、priv-app 白名单 | 设备自注册、换机识别、网络优化 |
| 渠道 App | 通过 `<queries>` 调用其 `RegisterHelperService` | 机型/渠道识别 |
| 第三方攻击者 | 无（该 Service 受签名级权限保护） | — |

## 3. 信任边界

```
[用户] --授权--> [ADB shell (uid 2000)] --Binder--> [system_server]
                                                        │
                                          PackageManager / AppOps / NetPolicy
```

- shell uid **没有** `MANAGE_USERS`、`INTERNAL_SYSTEM_WINDOW`、`DELETE_PACKAGES` 等高权
- 因此能做的最深操作是 `suspend` / `appops` / `netpolicy`，不能 `uninstall` 系统包
- 本项目的所有能力都落在这条边界内，**不尝试越界**（无 root、不改分区、不伪造签名）

## 4. 攻击面与缓解

| 面 | 风险 | 缓解（本项目） |
|---|---|---|
| 开机自启 | `BOOT_COMPLETED` + `QUICKBOOT_POWERON`，priority 999 | `suspend` + `stopped` + AppOps `RUN_ANY_IN_BACKGROUND` |
| 定时上报 | 6 条 `*walarm*` + JobScheduler | AppOps `SCHEDULE_EXACT_ALARM` ignore → 系统以 `exact_alarm_permission_revoked` 掉线 |
| 换卡/换网触发 | `SIM_STATE_CHANGED` / `CONNECTIVITY_CHANGE` | 同上（广播不投递给 suspended 包） |
| 后台联网 | 无后台限制 | `netpolicy` 黑名单 → netd iptables |
| 采集 | 权限已授予 | `pm revoke` + `USER_FIXED`（6 项）；特权权限无法撤，靠"不执行" |
| 离线积压 | 本地 SQLite 最多 10 条 | `pm clear` 清空；不解除 suspend 就不会再攒 |

## 5. 明确不在范围

- 阻断 IMEI 读取（install-time 特权权限，无 revoke 通道）
- 阻断系统服务对它的间接调用（例如系统级 carrier 配置读取）
- 服务端是否收到过数据（设备侧无法证明）
- 物理镜像取证（无 root）

## 6. 残余风险

| 风险 | 概率 | 影响 |
|---|---|---|
| OTA 后状态被重置 | 高 | 防护失效，需重跑 |
| 用户手动解除 suspend | 中 | 立刻恢复全部能力 |
| 内核/系统层绕过的调用路径 | 低 | 未知 |
| 本地残留 10 条 JSON 在 clear 之前 | 已消除 | `pm clear` 已执行 |
