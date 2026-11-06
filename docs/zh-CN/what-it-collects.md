# 它到底能拿走什么（代码级证据）

> English version: [../what-it-collects.md](../what-it-collects.md)

本文所有结论都能自己复现：`adb pull` 出 APK，`unzip` / `apktool` / `jadx` / `strings` 三选一即可。

```bash
adb shell pm path com.mobiletools.systemhelper
adb pull /system/priv-app/com.mobiletools.systemhelper/com.mobiletools.systemhelper.apk
strings -a com.mobiletools.systemhelper.apk | grep -E 'wo\.com\.cn|register|NetworkStats'
```

---

## 一、身份

| 项 | 值 | 怎么验 |
|---|---|---|
| 包名 | `com.mobiletools.systemhelper` | `pm path` |
| 代码路径 | `/system/priv-app/com.mobiletools.systemhelper` | `pm path` |
| 版本 | `4.0.0-20260729` / vc 34 / minSdk 31 / targetSdk 34 | `dumpsys package` |
| 签名 | `CN=NewDM, OU=RI, O=CU, L=BJ, ST=BJ, C=86` | `dumpsys package` 的 `signatures`/`apksigner` |
| 安装来源 | `installerPackageName=null`、`firstInstallTime=1970-03-09` | `dumpsys package` |
| 特权白名单 | `/system/etc/permissions/privapp-permissions-systemhelper.xml`，内含注释 `MIUI ADD: CUST_CmctDm` | `adb shell cat` |
| 系统策略 | `ro.control_privapp_permissions=enforce` | `getprop` |

`O=CU` 是运营商（中国联通）的证书主体，`CUST_CmctDm` 是小米给「运营商 DM 定制」留的插槽名——也就是说它不是第三方偷偷装的，是**镜像构建阶段就有意放进去的**。

---

## 二、上报数据模型（`g1/b` 的 JSON 字段全集）

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

对应的 Android API（都能在 APK 字符串里搜到）：

| 字段 | API / 字符串 |
|---|---|
| IMEI | `getDeviceId` / `getImeiForSlot` |
| IMSI | `getSubscriberId` |
| ICCID | `getSimSerialNumber`、`ICCID1`/`ICCID2` |
| 基站 | `getAllCellInfo`（`GsmCellLocation` / `CdmaCellLocation`）、`PCI1`、`CID1`、`TAC` |
| WiFi | `getBSSID`、`WifiConfiguration` |
| 蓝牙 | `BluetoothAdapter`、`getBondedDevices`、`le.ScanCallback` |
| 逐应用流量 | `NetworkStatsManager`、`NetworkStats$Bucket` |
| 网络可达性 | `isIPv4Reachable` / `isIPv6Reachable` |
| 位置 | 百度定位 SDK（`loc.map.baidu.com/sdk.php`、`ofloc.map.baidu.com` 等） |
| 应用列表 | 遍历 `PackageManager`，只过滤 `com.android*` 前缀 |

**为什么这一套危险**：IMEI + IMSI + ICCID + 基站三件套 + WiFi BSSID + 蓝牙 MAC，任意三项组合就能把「机器」和「人」钉死；再叠一张全量应用列表，就是长期画像。它**不需要**定位权限也能靠基站/WiFi 反推位置——这正是它申请 `ACCESS_FINE_LOCATION` 的原因。

---

## 三、上报通道

| 项 | 值 |
|---|---|
| 主 | `https://dm.wo.com.cn:18081/register` |
| 降级 | `http://dm.wo.com.cn:18080/register`（`usesCleartextTraffic=true`） |
| 形态 | `POST ?ver=6.0&model=…&manuf=…&sign=…`，body 为加密 JSON |
| 失败处理 | 先落本地 SQLite（`i1/e`），下次联网补传 |

APK 里还能搜到失败分支的日志字符串，可以互证降级逻辑确实存在：

```
HTTPS register fail (cert invalid)
HTTPS register fail (server reject)
```

---

## 四、触发时机（`RegType`）

| 触发源 | 组件 | RegType |
|---|---|---|
| 开机 / 快速开机 | `.control.OnBootReceiver`（`BOOT_COMPLETED` + `QUICKBOOT_POWERON`，实测 `mPriority=999`） | `A` |
| 换 SIM | `.control.SIMStateReceiver` | `S` / `T` |
| 网络状态变化 | `.control.ConnectStateReceiver` | `B` |
| 定时 | `.control.ScheduleRegisterReceiver` | `B` |
| 应用列表变化 | `.control.AppInfoRegisterReceiver` | `A` |
| 信号变化 | `.control.SignalInfoRegisterReceiver` | `R` |
| JobScheduler | `RegisterJobService` | `B` |

APK 里还有一句 `boot delayed for 4 minutes-->`，即开机后刻意延迟 4 分钟再上报，避开开机高峰。这也解释了为什么「重启后马上看没流量」不能证明它不跑。

---

## 五、开关真相

```java
// 小米分支（h1/n）
if (Settings.Global.getInt(cr, "device_provisioned", 0) == 1) { ... 允许上报 ... }

// 通用分支（i1/l）
Settings.Secure.getInt(cr, "operator_service_improve_plan", ...)
```

- 只要你走完开机向导，`device_provisioned` 就是 `1`；
- App 里**没有**任何给用户用的开关；
- `operator_service_improve_plan` 只对通用分支有效，对小米分支是死键（测试设备该键为空值）。

所以「在设置里关掉运营商服务」是**无效**的——这不是传闻，是代码路径。

---

## 六、它做不到什么（别把它妖魔化）

| 能力 | 具备吗 | 依据 |
|---|---|---|
| 静默安装 APK | 否 | 无 `INSTALL_PACKAGES` / `REQUEST_INSTALL_PACKAGES` |
| 读短信 / 通讯录 / 通话记录 | 否 | 无 `READ_SMS` `READ_CONTACTS` `READ_CALL_LOG` |
| 录屏 / 模拟点击 | 否 | 无 `AccessibilityService`、无 `MediaProjection` |
| 读通知 | 否 | 无 `NotificationListenerService` |
| 设备管理员 / 远程锁机 | 否 | `dpm list-owners` 空、`Enabled Device Admins` 空 |
| 采集设备指纹 / 位置指纹 / 应用列表 | **是** | 见 §二 |

它导出的 `.service.RegisterHelperService`（受签名级 `com.mobiletools.systemhelper.permission` 保护）是给渠道 App 查询用的接口——部分电商 App 的 manifest 里能查到对它的 `<queries>` 声明。也就是说「谁在用这个包做机型/渠道识别」本身是可以查的。
