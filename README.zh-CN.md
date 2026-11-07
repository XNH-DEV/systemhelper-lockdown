# SystemHelper Lockdown

> 把 HyperOS 4.0 上删不掉的运营商预装采集组件，按到「零进程、零联网、零通知、零闹钟」的一套可复现处置手册。

> **补充（2026-11-07）**：`pm` 命令行确实卸不掉它，但换成 `PackageInstaller` API（Canta + Shizuku，同样不需要 root）**可以真的卸载**，实测 `installed=false`、数据已删、只掉了这一个包。详见 [matrix 第八节](docs/zh-CN/matrix-hyperos4.md#八真正走得通的一条路packageinstaller-api2026-11-07-补充)。

**目标包**：`com.mobiletools.systemhelper`（显示名 SystemHelper）——中国联通 OMA-DM 设备自注册 / 遥测组件，烧在 `/system/priv-app`，签名 `O=CU`。

**环境**：一台零售版 HyperOS 4.0 设备（Android 17 / API 37），未 root、未解 BL。
其他 HyperOS 4.x、MIUI 14+ 机型大概率同样适用（脚本里所有命令都是通用 adb shell，只有「联网控制」那一项是 MIUI 专有 UI）。

🇬🇧 English version: [README.md](README.md)

---

## 0. TL;DR

```
adb devices                       # 得先连上
bash scripts/lockdown.sh          # 一键处置（默认 dry-run 之外会真改）
bash scripts/verify.sh            # 出验证数据（默认采样 300 秒）
bash scripts/rollback.sh          # 一键还原
```

处置后状态（同一台测试设备实测，11 分 09 秒采样窗口）：

| 指标 | 结果 |
|---|---|
| 进程（`ps -A`） | 0 个 |
| 包状态 | `suspended=true` `stopped=true` `distractionFlags=2` |
| `netstats` 里该 uid 的条目 | **0 条 / 0 字节**（同期其他 uid 从 231 条涨到 246 条，证明统计没停） |
| 组件被拉起 | 3 次尝试全部失败（服务/页面/开机广播） |
| 后台流量 | netd 层 `REJECT_METERED_BACKGROUND` + `APP_BACKGROUND` |

**它没有被卸载**——HyperOS 4.0 用三条不同的异常把无 root 卸载/禁用全堵死了，详见 [§3](#3-hyperos-40-的硬墙实测矩阵)。

---

## 1. 这东西是谁

| 项 | 值 |
|---|---|
| 包名 | `com.mobiletools.systemhelper` |
| 代码路径 | `/system/priv-app/com.mobiletools.systemhelper/`（特权应用） |
| 版本 | `4.0.0-20260729`（versionCode 34，minSdk 31，targetSdk 34） |
| 签名证书 | `CN=NewDM, OU=RI, O=CU, L=BJ, ST=BJ, C=86` → `O=CU` = 中国联通 |
| 安装来源 | `installerPackageName=null`、`firstInstallTime=1970` → 出厂烧在系统镜像里 |
| 特权白名单 | `/system/etc/permissions/privapp-permissions-systemhelper.xml`，注释里写着 `MIUI ADD: CUST_CmctDm` |
| 上报端 | `https://dm.wo.com.cn:18081/register`，失败降级 `http://dm.wo.com.cn:18080/register`（`usesCleartextTraffic=true`） |

它**不是**流氓软件：没有 `INSTALL_PACKAGES`（不能静默装 App）、没有 `READ_SMS` / `READ_CONTACTS` / `READ_CALL_LOG`、没有无障碍服务、没有通知监听、不是设备管理员。
它是**运营商定制层**——但「设备指纹 + 应用列表」这一块是货真价实、默认满速采集的。

> 顺带一提：`com.xunmeng.pinduoduo`、`com.jingdong.app.mall` 等电商的 manifest 里会点名 `<queries>` 本包，也就是说它导出的 `RegisterHelperService`（签名级权限保护）被渠道 App 用来做机型/渠道识别。

---

## 2. 它到底拿得走什么（代码级）

从 APK 里直接读出来的上报 JSON 字段（`g1/b`）：

```
IMEI1 IMEI2  IMSI1 IMSI2  ICCID1 ICCID2  MNC1 MNC2
TAC1 TAC2  CID1 CID2  PCI1 PCI2                     ← 基站三件套 ×2 卡
BSSID RSSI Frequency LinkSpeed IPv6                  ← WiFi 指纹
NetworkType1/2  5GEnabled1/2  VoLTE1/2  VoNR1/2
Esim InactiveEsimMNC SatelliteEnabled SatelliteSupport
PairedDevice PairedMacAddress                        ← 蓝牙配对设备名 + MAC
Manuf Model OS OSVersion HWVersion SWVersion ClientVersion SpecVersion SubType
DeviceType DataSlot RegType AccType Time
appInfoList                                          ← 遍历 PackageManager（只过滤 com.android* 前缀）
```

拆成三句话：

1. **你是谁**：双卡 IMEI / IMSI / ICCID + MNC + eSIM 状态 → 换卡也能把「这台机 = 这个人」对上号
2. **你在哪**：基站 TAC/CID/PCI + WiFi BSSID/RSSI/信道 → 不申请定位权限也能做基站 + WiFi 三角定位（这就是它要 `ACCESS_FINE_LOCATION` 的原因；APK 里还带着一整套百度定位 SDK）
3. **你在用什么**：全量已装应用列表，只排除 `com.android*` 前缀

**触发时机**（`h1/p` 的 `RegType`）：`A` 开机 + 应用列表变化、`B` 常规、`F`、`S`/`T` 换 SIM、`R` 信号变化。
对应 6 个组件：`OnBootReceiver`（`BOOT_COMPLETED` + `QUICKBOOT_POWERON`，实测 `mPriority=999`）、`SIMStateReceiver`、`ConnectStateReceiver`、`ScheduleRegisterReceiver`、`AppInfoRegisterReceiver`、`SignalInfoRegisterReceiver`，外加 `RegisterJobService`。
**发不出去就先落本地 SQLite（`i1/e`），联网后补传**——所以「断网」不等于「没采」。

### 开关为什么没用

小米分支的判定是 `Settings.Global.device_provisioned == 1`：

- 只要你走完开机向导，门禁就是开的；
- App 内**没有**开关；
- `Settings.Secure.operator_service_improve_plan` 只对通用分支生效，对小米分支无效（测试设备该键为空）；
- 这两个字符串都在 APK 里能直接搜到，不是猜测。

---

## 3. HyperOS 4.0 的硬墙（实测矩阵）

逐条在测试设备上跑过，返回原文照抄。想省事的直接看结论：**6 条路只有 `suspend` 通了**。

| # | 命令 | rc | 返回原文 | 判定 |
|---|---|---|---|---|
| 1 | `pm uninstall -k --user 0 <pkg>` | 1 | `Failure [only root can delete system app for a particular user]` | 被拦 |
| 2 | `pm uninstall --user 0 <pkg>` | 1 | 同上 | 被拦 |
| 3 | `cmd package uninstall --user 0 <pkg>` | 1 | 同上 | 被拦 |
| 4 | `pm hide <pkg>` | 255 | `SecurityException: Access denied, requires: android.permission.MANAGE_USERS` | 无权限 |
| 5 | `pm disable-user --user 0 <pkg>` | 255 | `SecurityException: Cannot disable system packages.`（`PackageManagerServiceImpl.shouldRestrictEnabledSettingsChange:1116`） | 被拦 |
| 6 | `pm disable --user 0 <pkg>` | 255 | 同上 | 被拦 |
| 7 | `pm suspend --user 0 <pkg>` | 0 | `Package … new suspended state: true` | **✅ 成功** |
| 8 | `pm set-distracting-restriction --flag hide-notifications --user 0 <pkg>` | 0 | 回读 `distractionFlags=2` | **✅ 成功** |
| 9 | `pm uninstall-system-updates <pkg>` | 1（stdout `Success`） | 无更新可卸（APK 直接在 `/system`） | 无效果 |
| 10 | `pm revoke <pkg> android.permission.ACCESS_LOCAL_NETWORK` | 0 | 回读仍 `granted=true` | 撤不掉（Android 16+ 新权限，特权 App 默认授予） |
| 11 | `adb install -r <空壳.apk>`（同包名，`versionCode` 35，自签 key） | 1 | `INSTALL_FAILED_UPDATE_INCOMPATIBLE: … signatures do not match newer version; ignoring!` | 被拦（签名） |

**结论**：HyperOS 4.0 把「系统应用启用状态」的修改权限收进了 `PackageManagerServiceImpl` 的私有判定，社区在 HyperOS 2/3 上成功的 `pm uninstall --user 0` 在 4.0 上直接失效。
`ro.debuggable=0`（零售版），所以 `adb root` 也不用想。

**「同包名 + 更高版本的空壳顶替」同样不通。** 我们把一个包名相同、`versionCode` 35（另用 `999999999` 复测）的自签空壳，按九条安装路径全跑了一遍——`adb install -r/-t/-d`、`pm install --user 0` 与 `--user 999`、`cmd package install`，以及 `install-create → install-write → install-commit` 会话路径（会话能建、payload 能写，**卡在 commit 的签名校验**）——全部返回同一句签名不匹配。版本比较根本没轮上；详见 [matrix §二·五](docs/zh-CN/matrix-hyperos4.md) 里的对照实验（同 key 升级成功、换 key 必败）。

> 顺带记录两个反直觉的坑：
> - `pm list packages`（含 `-d/-e`）在本机 **rc=0 但零输出**，枚举必须换成 `cmd package list packages`。
> - `am set-standby-bucket <pkg> restricted|rare|working_set` **rc=0 但值不变**（`usagestats` 里 `bucket=10 reason=f` 恒定），本机这条杠杆是死的。

---

## 4. 本方案关掉了什么（核心）

一共五层，每层都能单独撤回。**要「哪一层」自己挑，不必全上。**

### 4.1 执行层：让它起不来

| 动作 | 命令 | 生效证据 |
|---|---|---|
| 系统级挂起 | `pm suspend --user 0 <pkg>` | `dumpsys package` → `suspended=true` |
| 强停 + 打上 stopped 标记 | `am force-stop <pkg>` | `stopped=true`（开机广播不会再叫醒它，直到有人显式启动） |
| 待机标记 | `am set-inactive <pkg> true` | 进入 idle 名单 |
| 后台执行禁掉 | `cmd appops set <pkg> RUN_ANY_IN_BACKGROUND ignore`<br>`cmd appops set <pkg> RUN_IN_BACKGROUND ignore` | `dumpsys alarm` / `dumpsys jobscheduler` 的 `Restricted packages` 出现 `u0a<uid>` = force-standby |
| 不准转前台服务 | `cmd appops set <pkg> START_FOREGROUND ignore` | `cmd appops get` 回读 `ignore` |
| 不准持锁唤醒 | `cmd appops set <pkg> WAKE_LOCK ignore` | 同上 |

### 4.2 时钟层：把它的定时任务掐死

| 动作 | 命令 | 生效证据 |
|---|---|---|
| 撤销精确定时闹钟权限 | `cmd appops set <pkg> SCHEDULE_EXACT_ALARM ignore` | `dumpsys alarm` → `Last OP_SCHEDULE_EXACT_ALARM: u0a<uid>:ignore`，它挂的 5 个 `*walarm*`（`SIMStateReceiver` / `OnBootReceiver` / `AppInfoRegisterReceiver` / `ScheduleRegisterReceiver` / `SignalInfoRegisterReceiver`）全部以 `exact_alarm_permission_revoked` 掉线 |

### 4.3 权限层：把采集源掐掉

`pm revoke` × 6，回读全部 `granted=false`：

```
android.permission.READ_PHONE_STATE
android.permission.ACCESS_FINE_LOCATION
android.permission.ACCESS_COARSE_LOCATION
android.permission.ACCESS_BACKGROUND_LOCATION
android.permission.READ_EXTERNAL_STORAGE
android.permission.BLUETOOTH_CONNECT
```

> 撤不掉的：`READ_PRIVILEGED_PHONE_STATE`（install-time 特权权限，IMEI 仍可能读到）、`ACCESS_LOCAL_NETWORK`（Android 16+ 新权限，`pm revoke` 回 rc=0 但值不变）。

### 4.4 网络层：后台流量在 netd 层被拒

| 动作 | 命令 | 生效证据 |
|---|---|---|
| 加进 restrict-background 黑名单 | `cmd netpolicy add restrict-background-blacklist <uid>` | `cmd netpolicy list restrict-background-blacklist` → 列表含该 uid |
| — | — | `dumpsys netpolicy` → `policy=1 (REJECT_METERED_BACKGROUND)`、`blocked_state={blocked=APP_BACKGROUND\|METERED_USER_RESTRICTED}` |

这一层是**内核 netd 的 iptables 链**在拦，跟 App 里有没有开关、有没有崩都无关。

### 4.5 通知层：藏掉它的一切打扰

`pm set-distracting-restriction --flag hide-notifications --user 0 <pkg>` → `distractionFlags=2`
配合 `cmd appops set <pkg> POST_NOTIFICATION ignore`。

### 4.6 可选层 A：MIUI「联网控制」把它彻底关进小黑屋（最强，但要手点）

这是本机唯一能做到「**连前台也不给网**」的无 root 手段，因为它是 MIUI 自己的防火墙，状态存在 `com.miui.securitycenter` 的私有库里，adb 写不进去。

```
设置 → 应用 → 应用管理 → 搜 SystemHelper → 应用联网
```

四个开关全关：`数据-卡1`、`数据-卡2`、`WLAN`、`后台运行时联网`。

> 后果自负的一点：关掉 WLAN 后，这 App 即使被拉到前台也上不了网——这才是真正的「断网」。

### 4.7 可选层 B：DNS 黑洞

在你能控制 DNS 的地方，把 `dm.wo.com.cn` 解析到 `0.0.0.0`（路由器静态 DNS 指向本地 sinkhole、本地 DNS 过滤、hosts 都行）。

- 它一个域名同时覆盖 `:18081`（HTTPS）和 `:18080`（HTTP 降级）两个上报口，因为域名是同一个；
- 注意它**防不住写死 IP 的直连**，所以这层只能当补刀，主防线还是 §4.1 + §4.4。

---

## 5. 快速开始

### 前置

- `adb` 在 PATH 里（或 `ADB=/path/to/adb`）
- 手机已开 USB/无线调试，`adb devices` 能看到设备
- **不需要** root、不需要解锁 BL

### 三步

```bash
# 0) 先只读：动之前把证据摊开
bash scripts/preflight.sh          # 环境 / 保护名单 / 依赖面
bash scripts/audit.sh --no-sample  # 全量只读审计 → logs/<ts>/audit-report.md
bash scripts/snapshot.sh           # 完整快照（rollback 依赖它）

# 1) 先干跑一遍，看它准备改什么（不会动设备）
bash scripts/lockdown.sh --dry-run

# 2) 真跑
bash scripts/lockdown.sh

# 3) 出验证数据（默认采样 300 秒，可 --seconds 60 缩短）
bash scripts/verify.sh
```

### 分层入口（v2.1）

`scripts/restriction/restriction.sh` 把处置系统拆成七个显式模式，**不点名就不执行**：

```bash
bash scripts/restriction/restriction.sh audit     # 只读（默认）
bash scripts/restriction/restriction.sh plan      # 只出方案，不改设备
bash scripts/restriction/restriction.sh restrict  # L1–L5 冻结
bash scripts/restriction/restriction.sh disable   # 尝试停用（HyperOS 4.0 会拒）
bash scripts/restriction/restriction.sh uninstall # 尝试用户级卸载（需精确确认串）
bash scripts/restriction/restriction.sh verify
bash scripts/restriction/restriction.sh restore
```

每个动作只给四种结果：`SUCCESS / FAILED / SKIPPED / UNKNOWN`；**没回读验证过的一律不记 SUCCESS**。

多设备时加 `--serial <序列号>`，换包名时加 `--pkg <包名>`（脚本默认带白名单，不让它去动 `com.qualcomm.qti.services.systemhelper` 这类同名高通组件）。

### 日志

脚本默认把 `dumpsys package` / `appops` / `netstats` 的原文落到 `./logs/<时间戳>/`，方便事后比对。

---

## 6. 验证：怎么证明它真的死了

别只看「没有进程」——它本来就是用完即走。要看四个指标：

1. **进程**：`ps -A | grep mobiletools` → 空
2. **包状态**：`dumpsys package <pkg> | grep -E 'stopped=|suspended=|distractionFlags='` → `stopped=true suspended=true distractionFlags=2`
3. **流量增量**：`dumpsys netstats detail` 里 `uid=<uid>` 的行数与 `rb/tb`，间隔 ≥5 分钟采两次比差值
   - 口径提醒：只比 **UID stats**，不要叠加 `UID tag stats`，否则同一份流量会被算两遍
   - 若整个 uid 一条记录都没有 = 这个统计窗口里它一个字节都没走
4. **闹钟**：`dumpsys alarm | grep -A3 'Restricted packages'` → 应出现 `u0a<uid>`；`Last OP_SCHEDULE_EXACT_ALARM` 应为 `ignore`

`scripts/verify.sh` 会把 1–4 跑一遍并给出 PASS/FAIL。

> 提醒：`dumpsys netstats detail` 只反映**当前统计窗口**。想知道「历史上传过多少」，看系统「设置 → 应用 → 应用联网」里的累计值（那是另一套持久计数）。

---

## 7. 回滚

```bash
bash scripts/rollback.sh          # 反向撤掉 appops / netpolicy / suspend / 通知限制
```

手动逐条的话：

```bash
pm unsuspend --user 0 com.mobiletools.systemhelper
pm set-distracting-restriction --flag 0 --user 0 com.mobiletools.systemhelper
cmd appops set com.mobiletools.systemhelper RUN_ANY_IN_BACKGROUND default
cmd appops set com.mobiletools.systemhelper RUN_IN_BACKGROUND default
cmd appops set com.mobiletools.systemhelper START_FOREGROUND default
cmd appops set com.mobiletools.systemhelper WAKE_LOCK default
cmd appops set com.mobiletools.systemhelper POST_NOTIFICATION default
cmd appops set com.mobiletools.systemhelper SCHEDULE_EXACT_ALARM default
cmd netpolicy remove restrict-background-blacklist <uid>
am set-inactive com.mobiletools.systemhelper false
pm grant com.mobiletools.systemhelper android.permission.READ_PHONE_STATE   # 其余权限同理
```

> 本方案**没有卸载任何东西**，所以 `cmd package install-existing` 用不上；`pm grant` 若被拒（特权权限），重启一次通常由系统重新默认授予。
>
> **若你已经用 Canta 之类把它卸了**（`installed=false`）：下面这串 `appops/netpolicy` 回滚对已卸载的包没有意义，直接忽略；要恢复只需 `cmd package install-existing --user 0 com.mobiletools.systemhelper`。

---

## 8. 边界：这套方案做不到什么

1. **没卸载**。APK 仍在 `/system/priv-app`，`pm path` 照样能查到。想彻底删掉：`pm` 命令行被 HyperOS 4.0 拦住，但 **`PackageInstaller` API 能过**（Canta + Shizuku，无需 root，实测成功）；再往下才是 root 后 `mount -o rw,remount /system` 删目录或解 BL 换 ROM。本机 `ro.debuggable=0`，连 `adb root` 都不可用。
2. **重启会打回一部分**。`suspend` 会存活，但 `stopped` 会被开机流程重置（实测重启后 baseline 是 `stopped=false`）→ 建议每次重启后补跑一次 `am force-stop`。
3. **OTA 会还原**。系统升级覆盖 `/system` 后，权限可能重新 `GRANTED_BY_DEFAULT`，appops / netpolicy 也可能被重置 → 升级后整套重跑。
4. **IMEI 这类特权读取挡不住**。`READ_PRIVILEGED_PHONE_STATE` 是 install-time 权限，撤不掉；只能靠「不给它执行机会」+「不给它网」。
5. **本地队列不会消失**。它采到的东西会先写 SQLite 等联网补传，`pm clear` 能清一次，但之后它要是又被拉起，还是会重新攒。
6. **别指望 DNS 层单独够用**。它挡不住直连 IP，也挡不住已经建立的连接。

---

## 9. 坑（踩过的）

| 坑 | 说明 |
|---|---|
| `pm list packages` 空输出 | HyperOS 4.0 上 rc=0 但一个字都不打，枚举改用 `cmd package list packages` |
| `am set-standby-bucket` 无效 | 对本包恒定 `bucket=10 reason=f`，怎么设都不变 |
| `pm uninstall --user 0` 失效 | HyperOS 2/3 上的成功案例在 4.0 不成立 |
| `pm hide` 要 `MANAGE_USERS` | shell uid 没有 |
| 组件名不一定是 `.service.RegisterIntentService` | `dumpsys package` 的 Service Resolver Table 只列导出的。本机实际导出的是 `.service.RegisterHelperService` |
| 开机广播优先级 | 网上传 `2147483647`，本机 `dumpsys` 读到的是 `mPriority=999` |
| 虚拟屏里跑 UI | `settings put global overlay_display_devices …` 能建副屏，但 `am start --display N` 会被 `SafeActivityOptions.checkPermissions` 拦（要 `INTERNAL_SYSTEM_WINDOW`），shell 无 root 建了也用不了 |

---

## 10. 许可与适用范围

- 代码与文档：MIT，见 [LICENSE](LICENSE)。
- 仅用于**你自己拥有或在明确授权下管理**的设备。本仓库不含任何第三方 App 的二进制，也不含任何真实设备/个人数据；文中所有数值都来自同一台测试设备，脚本里的路径/UID 全部运行时解析。
- 仓库里出现的包名、证书 DN、域名都来自公开的 Android 包信息与 APK 字符串，用于说明问题，不代表任何厂商立场。

## 附：文档索引

中文（本页）：

- [docs/zh-CN/what-it-collects.md](docs/zh-CN/what-it-collects.md) —— 采集字段与代码定位（代码级证据）
- [docs/zh-CN/matrix-hyperos4.md](docs/zh-CN/matrix-hyperos4.md) —— HyperOS 4.0 处置命令实测矩阵（含异常原文）
- [docs/zh-CN/verification.md](docs/zh-CN/verification.md) —— 验证方法学：netstats 口径、采样时长、误判来源
- [docs/zh-CN/faq.md](docs/zh-CN/faq.md) —— 常见问题与反例

工程文档（v2.0 / v2.1）：

| 文档 | 内容 |
|---|---|
| [ARCHITECTURE.md](docs/zh-CN/ARCHITECTURE.md) | 分层架构、模块边界、数据流、四值状态机 |
| [THREAT_MODEL.md](docs/zh-CN/THREAT_MODEL.md) | 资产、威胁主体、信任边界、残余风险 |
| [PRIVACY_AUDIT.md](docs/zh-CN/PRIVACY_AUDIT.md) | 五级证据分级、采集字段、离线积压机制、开关语义 |
| [NETWORK_ANALYSIS.md](docs/zh-CN/NETWORK_ANALYSIS.md) | 端点、触发条件、观测口径、封锁层次 |
| [PERMISSION_ANALYSIS.md](docs/zh-CN/PERMISSION_ANALYSIS.md) | 权限三层、可撤销性、顺序坑 |
| [COMPATIBILITY.md](docs/zh-CN/COMPATIBILITY.md) | 跨版本能力矩阵与命令差异 |
| [COMPATIBILITY-hyperos4.md](docs/zh-CN/COMPATIBILITY-hyperos4.md) | 本机逐条原始报错 |
| [RECOVERY.md](docs/zh-CN/RECOVERY.md) | 故障恢复（搞坏了怎么救） |
| [RESTORE_GUIDE.md](docs/zh-CN/RESTORE_GUIDE.md) | 正常回滚（按快照恢复原值，不擅自授权） |
| [RESTRICTION_GUIDE.md](docs/zh-CN/RESTRICTION_GUIDE.md) | 五层处置：原理/条件/命令/预期/恢复/版本差异 |
| [DISABLE_GUIDE.md](docs/zh-CN/DISABLE_GUIDE.md) | 停用：为什么 HyperOS 4.0 直接拒绝 |
| [UNINSTALL_GUIDE.md](docs/zh-CN/UNINSTALL_GUIDE.md) | 用户级卸载：13 项检查与硬墙 |
| [UNINSTALL_RISK_MATRIX.md](docs/zh-CN/UNINSTALL_RISK_MATRIX.md) | 卸载风险逐项打分（本包定级 CAUTION） |
| [TEST_PLAN.md](docs/zh-CN/TEST_PLAN.md) | 20 个 mock 场景与 CI |
| [SECURITY_LIMITATIONS.md](docs/zh-CN/SECURITY_LIMITATIONS.md) | 自我限制清单与不可宣称的结论 |

English:

- [docs/what-it-collects.md](docs/what-it-collects.md)
- [docs/matrix-hyperos4.md](docs/matrix-hyperos4.md)
- [docs/verification.md](docs/verification.md)
- [docs/faq.md](docs/faq.md)
