# 隐私审计（PRIVACY AUDIT）

> 五级证据分级，**不许把"代码里出现"说成"已经上传"**。

## 1. 五级证据

| 级别 | 定义 | 本机状态 | 判据 |
|---|---|---|---|
| A | 代码中存在读取逻辑 | **已确认** | APK 里 `getDeviceId` / `getSubscriberId` / `getCellLocation` / `getAllCellInfo` / `getSignalStrength` / `BSSID` 引用 |
| B | 运行时确实读取 | **UNKNOWN** | 需要 logcat/审计钩子；本脚本不声明 |
| C | 数据进入上传请求 | **UNKNOWN** | 无抓包（无 root 无法做 UID 归属的 tcpdump） |
| D | 服务端已接收 | **UNKNOWN** | 设备侧无法证明 |
| E | 历史累计流量 | **部分可证** | Settings → 应用 → 联网管理 有持久计数器（本机曾显示后台 360.8 KB） |

## 2. 采集字段（APK 静态，`g1/b`）

```
IMEI1 IMEI2  IMSI1 IMSI2  ICCID1 ICCID2  MNC1 MNC2
TAC1 TAC2  CID1 CID2  PCI1 PCI2
BSSID RSSI Frequency LinkSpeed IPv6
NetworkType1/2  5GEnabled1/2  VoLTE1/2  VoNR1/2
Esim InactiveEsimMNC SatelliteEnabled SatelliteSupport
PairedDevice PairedMacAddress
Manuf Model OS OSVersion HWVersion SWVersion ClientVersion SpecVersion SubType
DeviceType DataSlot RegType AccType Time
appInfoList
```

## 3. 权限 → 能力映射

| 权限 | 能拿到 | 能否撤销 |
|---|---|---|
| `READ_PRIVILEGED_PHONE_STATE` | IMEI/IMSI（特权） | ❌ install-time |
| `READ_PHONE_STATE` | 状态、部分标识 | ✅ |
| `ACCESS_FINE_LOCATION` / `COARSE` / `BACKGROUND` | 定位 | ✅ |
| `READ_EXTERNAL_STORAGE` | 外部存储 | ✅ |
| `BLUETOOTH_CONNECT` | 配对设备 | ✅ |
| `PACKAGE_USAGE_STATS` | 使用统计 | AppOps 可禁 |
| `QUERY_ALL_PACKAGES` | 全量应用列表 | 无法撤（Android 11+ 声明式） |
| `ACCESS_LOCAL_NETWORK` | 本地网络扫描 | ❌ `REVOKE_WHEN_REQUESTED` |
| `SCHEDULE_EXACT_ALARM` | 精确定时 | ✅ AppOps |

## 4. 离线积压机制（代码级）

`i1/e.java`（HistoryDatabaseHelper）：

```java
create table if not exists dmregister (ID integer primary key autoincrement, jsonString text)
int iMax = Math.max(0, rowCount - 10);   // 最多 10 条，超出删最旧
```

`g1/g.java`（RegisterThread）：网络不通或发送失败 → `eVarA.b(json)` 写入；日志原文 `save to database!` / `Not post!`。
`g1/e.java`（HistoryPostThread）：下次发送成功时 `eVar.c()` 取一条 → **立即 delete** → 再补发（补发失败即丢，不重试）。

**结论**："断网 = 没采集"是错的，但积压窗口只有 10 条，且必须"先成功发一条"才会触发补发。

## 5. 开关的真实语义

| 键 | 作用范围 | 本机值 |
|---|---|---|
| `Settings.Global.device_provisioned` | **小米分支的总门** | 1（门是开的） |
| `Settings.Secure.operator_service_improve_plan` | 仅通用分支 | 0（对小米分支无效） |

> 上一轮把 `operator_service_improve_plan=0` 当成"总闸关着所以没在传"，是错的：小米分支只看 `device_provisioned`。本月那 360.8 KB 后台流量与此一致。

## 6. 本次处置对隐私的实际影响

| 能力 | 处置前 | 处置后 |
|---|---|---|
| 读取 IMEI/IMSI | ✅（特权权限） | ❌ 进程不跑，读不到 |
| 读取定位/基站 | ✅ | ❌ 权限已撤 + 进程不跑 |
| 读取应用列表 | ✅ | ❌ 进程不跑 |
| 联网上报 | ✅ | ❌ 进程不跑 + 后台流量被拒 |
| 本地留存 | 最多 10 条 | 已清空，且不会再攒 |

## 7. 不宣称的东西

- ❌ "100% 阻止监听"——没有证据，也不做这个断言
- ❌ "永久零联网"——只证了观测窗口内 0 增量
- ❌ "彻底消灭数据采集"——系统级间接调用路径未穷尽
