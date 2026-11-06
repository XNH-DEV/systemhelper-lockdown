# What it can take (code-level evidence)

Everything below is reproducible: `adb pull` the APK and use any of `unzip` / `apktool` / `jadx` /
`strings`.

```bash
adb shell pm path com.mobiletools.systemhelper
adb pull /system/priv-app/com.mobiletools.systemhelper/com.mobiletools.systemhelper.apk
strings -a com.mobiletools.systemhelper.apk | grep -E 'wo\.com\.cn|register|NetworkStats'
```

---

## 1. Identity

| Field | Value | How to verify |
|---|---|---|
| Package | `com.mobiletools.systemhelper` | `pm path` |
| Code path | `/system/priv-app/com.mobiletools.systemhelper` | `pm path` |
| Version | `4.0.0-20260729` / vc 34 / minSdk 31 / targetSdk 34 | `dumpsys package` |
| Signature | `CN=NewDM, OU=RI, O=CU, L=BJ, ST=BJ, C=86` | `signatures` in `dumpsys package` / `apksigner` |
| Install source | `installerPackageName=null`, `firstInstallTime=1970-03-09` | `dumpsys package` |
| Privileged allowlist | `/system/etc/permissions/privapp-permissions-systemhelper.xml`, containing the comment `MIUI ADD: CUST_CmctDm` | `adb shell cat` |
| System policy | `ro.control_privapp_permissions=enforce` | `getprop` |

`O=CU` is the operator's (China Unicom) certificate subject, and `CUST_CmctDm` is the slot name
Xiaomi reserves for "carrier DM customization" — in other words this was put there **deliberately at
image build time**, not smuggled in by a third party.

---

## 2. The upload data model (full JSON field set of `g1/b`)

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

The corresponding Android APIs (all searchable as strings inside the APK):

| Field | API / string |
|---|---|
| IMEI | `getDeviceId` / `getImeiForSlot` |
| IMSI | `getSubscriberId` |
| ICCID | `getSimSerialNumber`, `ICCID1`/`ICCID2` |
| Cell | `getAllCellInfo` (`GsmCellLocation` / `CdmaCellLocation`), `PCI1`, `CID1`, `TAC` |
| Wi-Fi | `getBSSID`, `WifiConfiguration` |
| Bluetooth | `BluetoothAdapter`, `getBondedDevices`, `le.ScanCallback` |
| Per-app traffic | `NetworkStatsManager`, `NetworkStats$Bucket` |
| Reachability | `isIPv4Reachable` / `isIPv6Reachable` |
| Location | Baidu Location SDK (`loc.map.baidu.com/sdk.php`, `ofloc.map.baidu.com`, …) |
| App list | walks `PackageManager`, filters only the `com.android*` prefix |

**Why this set is dangerous**: IMEI + IMSI + ICCID + the cell triple + Wi-Fi BSSID + Bluetooth MAC —
any three of them together pin "this handset" to "this person"; add a full app list and you have a
long-term profile. It does **not** need a location permission to infer position from cell/Wi-Fi —
which is exactly why it requests `ACCESS_FINE_LOCATION`.

---

## 3. Upload channel

| Field | Value |
|---|---|
| Primary | `https://dm.wo.com.cn:18081/register` |
| Fallback | `http://dm.wo.com.cn:18080/register` (`usesCleartextTraffic=true`) |
| Shape | `POST ?ver=6.0&model=…&manuf=…&sign=…`, body is encrypted JSON |
| Failure handling | written to a local SQLite DB (`i1/e`), retried on the next network |

The failure-branch log strings are also in the APK, which cross-confirms the fallback logic really
exists:

```
HTTPS register fail (cert invalid)
HTTPS register fail (server reject)
```

---

## 4. Trigger points (`RegType`)

| Trigger | Component | RegType |
|---|---|---|
| Boot / quick boot | `.control.OnBootReceiver` (`BOOT_COMPLETED` + `QUICKBOOT_POWERON`, measured `mPriority=999`) | `A` |
| SIM swap | `.control.SIMStateReceiver` | `S` / `T` |
| Network state change | `.control.ConnectStateReceiver` | `B` |
| Timer | `.control.ScheduleRegisterReceiver` | `B` |
| App-list change | `.control.AppInfoRegisterReceiver` | `A` |
| Signal change | `.control.SignalInfoRegisterReceiver` | `R` |
| JobScheduler | `RegisterJobService` | `B` |

The APK also contains `boot delayed for 4 minutes-->`: after boot it deliberately waits four minutes
before reporting, to stay out of the boot storm. That is why "no traffic right after a reboot" does
not prove it never runs.

---

## 5. The truth about the switch

```java
// Xiaomi branch (h1/n)
if (Settings.Global.getInt(cr, "device_provisioned", 0) == 1) { ... allow reporting ... }

// Generic branch (i1/l)
Settings.Secure.getInt(cr, "operator_service_improve_plan", ...)
```

- finishing the out-of-box wizard sets `device_provisioned` to `1`;
- the app contains **no** user-facing switch at all;
- `operator_service_improve_plan` only affects the generic branch and is a dead key for the Xiaomi
  branch (empty on the test device).

So "just turn off carrier services in Settings" is **ineffective** — this is a code path, not a
rumour.

---

## 6. What it cannot do (do not demonize it)

| Capability | Present? | Basis |
|---|---|---|
| Silently install APKs | No | no `INSTALL_PACKAGES` / `REQUEST_INSTALL_PACKAGES` |
| Read SMS / contacts / call log | No | no `READ_SMS` `READ_CONTACTS` `READ_CALL_LOG` |
| Screen capture / synthetic input | No | no `AccessibilityService`, no `MediaProjection` |
| Read notifications | No | no `NotificationListenerService` |
| Device admin / remote lock | No | `dpm list-owners` empty, `Enabled Device Admins` empty |
| Collect device fingerprint / location fingerprint / app list | **Yes** | see §2 |

Its exported `.service.RegisterHelperService` (protected by the signature-level
`com.mobiletools.systemhelper.permission`) is a query interface for channel apps — `<queries>`
declarations for it can be found in the manifests of several e-commerce apps. In other words, "who
uses this package for model/channel identification" is itself something you can audit.
