# SystemHelper Lockdown

> A reproducible, root-free containment procedure for an operator (China Unicom) OMA-DM
> telemetry component that ships inside `/system/priv-app` on HyperOS 4.0 and **cannot be
> uninstalled or disabled** without root.

**Target package**: `com.mobiletools.systemhelper` (display name *SystemHelper*) — the China
Unicom OMA-DM device self-registration / telemetry component, baked into `/system/priv-app`,
signed with subject `O=CU`.

**Environment**: a retail HyperOS 4.0 build (Android 17 / API 37), no root, bootloader locked.
Other HyperOS 4.x and MIUI 14+ devices will most likely behave the same: every command in the
scripts is plain `adb shell`, and only the "app network" step is a MIUI-specific UI.

🇨🇳 中文版 / Chinese version: [README.zh-CN.md](README.zh-CN.md)

---

## 0. TL;DR

```bash
adb devices                       # make sure the device is connected
bash scripts/lockdown.sh          # apply (the default run really changes the device)
bash scripts/verify.sh            # print verification data (300 s sampling by default)
bash scripts/rollback.sh          # undo everything
```

State after containment (measured on the test device, 11m09s sampling window):

| Metric | Result |
|---|---|
| Processes (`ps -A`) | 0 |
| Package state | `suspended=true` `stopped=true` `distractionFlags=2` |
| Entries for that uid in `netstats` | **0 entries / 0 bytes** (device-wide entries grew 231 → 246, so accounting was alive) |
| Component launches | 3 attempts, all rejected |
| Background traffic | `REJECT_METERED_BACKGROUND` + `APP_BACKGROUND` at the netd layer |

**It is not uninstalled.** HyperOS 4.0 blocks every root-free uninstall/disable path with three
different exceptions — see [§3](#3-the-hard-walls-on-hyperos-40-measured-matrix).

---

## 1. What this thing is

| Field | Value |
|---|---|
| Package | `com.mobiletools.systemhelper` |
| Code path | `/system/priv-app/com.mobiletools.systemhelper/` (privileged app) |
| Version | `4.0.0-20260729` (versionCode 34, minSdk 31, targetSdk 34) |
| Signing cert | `CN=NewDM, OU=RI, O=CU, L=BJ, ST=BJ, C=86` → `O=CU` = China Unicom |
| Install source | `installerPackageName=null`, `firstInstallTime=1970` → baked into the system image at the factory |
| Privileged allowlist | `/system/etc/permissions/privapp-permissions-systemhelper.xml`, comment reads `MIUI ADD: CUST_CmctDm` |
| Upload endpoint | `https://dm.wo.com.cn:18081/register`, plaintext fallback `http://dm.wo.com.cn:18080/register` (`usesCleartextTraffic=true`) |

It is **not** malware in the classic sense: no `INSTALL_PACKAGES` (cannot silently install apps),
no `READ_SMS` / `READ_CONTACTS` / `READ_CALL_LOG`, no accessibility service, no notification
listener, not a device admin.

It is an **operator customization layer** — but the "device fingerprint + installed app list" part
is real and collects at full speed by default.

> Side note: manifests of apps such as `com.xunmeng.pinduoduo` and `com.jingdong.app.mall`
> declare `<queries>` for this package, i.e. its exported `RegisterHelperService` (protected by a
> signature-level permission) is used by channel apps for model/channel identification.

---

## 2. What it can actually take (code level)

Fields read straight out of the upload model (`g1/b`) inside the APK:

```
IMEI1 IMEI2  IMSI1 IMSI2  ICCID1 ICCID2  MNC1 MNC2
TAC1 TAC2  CID1 CID2  PCI1 PCI2                     ← cell tower triple, per SIM
BSSID RSSI Frequency LinkSpeed IPv6                  ← Wi-Fi fingerprint
NetworkType1/2  5GEnabled1/2  VoLTE1/2  VoNR1/2
Esim InactiveEsimMNC SatelliteEnabled SatelliteSupport
PairedDevice PairedMacAddress                        ← paired Bluetooth device name + MAC
Manuf Model OS OSVersion HWVersion SWVersion ClientVersion SpecVersion SubType
DeviceType DataSlot RegType AccType Time
appInfoList                                          ← walks PackageManager, filters only com.android*
```

In three sentences:

1. **Who you are**: dual-SIM IMEI / IMSI / ICCID + MNC + eSIM state → "this handset = this person"
   survives a SIM swap.
2. **Where you are**: cell TAC/CID/PCI + Wi-Fi BSSID/RSSI/channel → cell and Wi-Fi triangulation
   without ever requesting a location permission (which is exactly why it asks for
   `ACCESS_FINE_LOCATION`; the APK also bundles a full Baidu Location SDK).
3. **What you use**: the full installed-app list, excluding only the `com.android*` prefix.

**Trigger points** (`RegType` in `h1/p`): `A` boot + app-list change, `B` regular, `F`,
`S`/`T` SIM change, `R` signal change. They map to six components: `OnBootReceiver`
(`BOOT_COMPLETED` + `QUICKBOOT_POWERON`, measured `mPriority=999`), `SIMStateReceiver`,
`ConnectStateReceiver`, `ScheduleRegisterReceiver`, `AppInfoRegisterReceiver`,
`SignalInfoRegisterReceiver`, plus `RegisterJobService`.

**If it cannot upload, it queues locally in SQLite (`i1/e`) and retries when the network comes
back** — so "offline" is not the same as "not collected".

### Why the built-in switch does not help

The Xiaomi branch gates on `Settings.Global.device_provisioned == 1`:

- finishing the out-of-box wizard is enough to open the gate;
- the app exposes **no** user-facing switch;
- `Settings.Secure.operator_service_improve_plan` only affects the generic branch, not the Xiaomi
  one (that key was empty on the test device);
- both strings are directly searchable inside the APK — this is not guesswork.

---

## 3. The hard walls on HyperOS 4.0 (measured matrix)

Every row below was executed on the test device; output is copied verbatim. Short version:
**of six removal paths, only `suspend` works.**

| # | Command | rc | Verbatim output | Verdict |
|---|---|---|---|---|
| 1 | `pm uninstall -k --user 0 <pkg>` | 1 | `Failure [only root can delete system app for a particular user]` | blocked |
| 2 | `pm uninstall --user 0 <pkg>` | 1 | same as above | blocked |
| 3 | `cmd package uninstall --user 0 <pkg>` | 1 | same as above | blocked |
| 4 | `pm hide <pkg>` | 255 | `SecurityException: Access denied, requires: android.permission.MANAGE_USERS` | no permission |
| 5 | `pm disable-user --user 0 <pkg>` | 255 | `SecurityException: Cannot disable system packages.` (`PackageManagerServiceImpl.shouldRestrictEnabledSettingsChange:1116`) | blocked |
| 6 | `pm disable --user 0 <pkg>` | 255 | same as above | blocked |
| 7 | `pm suspend --user 0 <pkg>` | 0 | `Package … new suspended state: true` | **✅ works** |
| 8 | `pm set-distracting-restriction --flag hide-notifications --user 0 <pkg>` | 0 | reads back `distractionFlags=2` | **✅ works** |
| 9 | `pm uninstall-system-updates <pkg>` | 1 (stdout `Success`) | no update layer to remove (APK lives in `/system`) | no effect |
| 10 | `pm revoke <pkg> android.permission.ACCESS_LOCAL_NETWORK` | 0 | still reads back `granted=true` | cannot revoke (Android 16+ permission, granted to privileged apps by default) |

**Conclusion**: HyperOS 4.0 moved "change a system app's enabled state" behind a private check in
`PackageManagerServiceImpl`, so the `pm uninstall --user 0` trick that works on HyperOS 2/3 fails
outright on 4.0. `ro.debuggable=0` (retail build), so `adb root` is not an option either.

> Two counter-intuitive traps worth recording:
> - `pm list packages` (including `-d` / `-e`) returns **rc=0 with zero output**; enumeration must
>   use `cmd package list packages`.
> - `am set-standby-bucket <pkg> restricted|rare|working_set` returns **rc=0 but the value never
>   changes** (`bucket=10 reason=f` is constant in `usagestats`); this lever is dead on this device.

---

## 4. What this procedure switches off (the core)

Five layers, each independently revertible. **Pick the layers you want; you do not have to take all
five.**

### 4.1 Execution layer: stop it from starting

| Action | Command | Evidence |
|---|---|---|
| System-level suspend | `pm suspend --user 0 <pkg>` | `dumpsys package` → `suspended=true` |
| Force-stop + set the stopped flag | `am force-stop <pkg>` | `stopped=true` (boot broadcasts will not wake it until something starts it explicitly) |
| Standby marker | `am set-inactive <pkg> true` | enters the idle list |
| Deny background execution | `cmd appops set <pkg> RUN_ANY_IN_BACKGROUND ignore`<br>`cmd appops set <pkg> RUN_IN_BACKGROUND ignore` | `u0a<uid>` shows up under `Restricted packages` in `dumpsys alarm` / `dumpsys jobscheduler` = force-standby |
| No foreground service | `cmd appops set <pkg> START_FOREGROUND ignore` | `cmd appops get` reads back `ignore` |
| No wake locks | `cmd appops set <pkg> WAKE_LOCK ignore` | same |

### 4.2 Clock layer: cut its timers

| Action | Command | Evidence |
|---|---|---|
| Revoke exact-alarm permission | `cmd appops set <pkg> SCHEDULE_EXACT_ALARM ignore` | `dumpsys alarm` → `Last OP_SCHEDULE_EXACT_ALARM: u0a<uid>:ignore`; all five of its `*walarm*` timers (`SIMStateReceiver` / `OnBootReceiver` / `AppInfoRegisterReceiver` / `ScheduleRegisterReceiver` / `SignalInfoRegisterReceiver`) drop out with `exact_alarm_permission_revoked` |

### 4.3 Permission layer: disconnect the collectors

`pm revoke` × 6, all reading back `granted=false`:

```
android.permission.READ_PHONE_STATE
android.permission.ACCESS_FINE_LOCATION
android.permission.ACCESS_COARSE_LOCATION
android.permission.ACCESS_BACKGROUND_LOCATION
android.permission.READ_EXTERNAL_STORAGE
android.permission.BLUETOOTH_CONNECT
```

> Cannot be revoked: `READ_PRIVILEGED_PHONE_STATE` (install-time privileged permission — IMEI may
> still be readable) and `ACCESS_LOCAL_NETWORK` (Android 16+ permission; `pm revoke` returns rc=0 but
> the value does not change).

### 4.4 Network layer: background traffic rejected inside netd

| Action | Command | Evidence |
|---|---|---|
| Add to the restrict-background blacklist | `cmd netpolicy add restrict-background-blacklist <uid>` | `cmd netpolicy list restrict-background-blacklist` → the uid is listed |
| — | — | `dumpsys netpolicy` → `policy=1 (REJECT_METERED_BACKGROUND)`, `blocked_state={blocked=APP_BACKGROUND\|METERED_USER_RESTRICTED}` |

This layer is the kernel netd iptables chain doing the blocking — independent of whether the app
has a switch or whether it crashes.

### 4.5 Notification layer: hide every interruption

`pm set-distracting-restriction --flag hide-notifications --user 0 <pkg>` → `distractionFlags=2`,
together with `cmd appops set <pkg> POST_NOTIFICATION ignore`.

### 4.6 Optional layer A: MIUI "app network" lockdown (strongest, but manual)

This is the only root-free way on this device to deny it **even in the foreground**, because it is
MIUI's own firewall and its state lives in a private database owned by `com.miui.securitycenter`;
adb cannot write it.

```
Settings → Apps → Manage apps → search "SystemHelper" → App network (应用联网)
```

Turn all four switches off: `Data – SIM 1`, `Data – SIM 2`, `WLAN`, `Background data`.

> One consequence to accept: with WLAN off, the app cannot reach the network even when pulled to the
> foreground — that is what "actually offline" means.

### 4.7 Optional layer B: DNS sinkhole

Wherever you control DNS, resolve `dm.wo.com.cn` to `0.0.0.0` (router static DNS pointing at a local
sinkhole, local DNS filtering, or a hosts file).

- One domain covers both upload ports — `:18081` (HTTPS) and `:18080` (plaintext fallback) — because
  the hostname is the same;
- it does **not** stop hard-coded direct IP connections, so treat this as a finisher on top of
  §4.1 + §4.4, not as the main defence.

---

## 5. Quick start

### Prerequisites

- `adb` on `PATH` (or `ADB=/path/to/adb`)
- USB or wireless debugging enabled, `adb devices` lists the device
- **No** root, **no** unlocked bootloader

### Three steps

```bash
# 1) dry run first — prints what it would change, touches nothing
bash scripts/lockdown.sh --dry-run

# 2) apply
bash scripts/lockdown.sh

# 3) produce verification data (300 s sampling by default; --seconds 60 to shorten)
bash scripts/verify.sh
```

With several devices attached add `--serial <serial>`; for a different package add `--pkg <name>`
(the script carries a deny-list so it will not touch lookalikes such as Qualcomm's
`com.qualcomm.qti.services.systemhelper`).

### Logs

The scripts dump raw `dumpsys package` / `appops` / `netstats` output into `./logs/<timestamp>/` so
you can diff before and after.

---

## 6. Verification: how to prove it is really dead

Do not stop at "no processes" — this app is a short-lived
*wake → collect → upload → exit* process, so an empty `ps` at any given moment says nothing about
whether it ran today.

Four metrics carry the argument:

1. **Processes**: `ps -A | grep mobiletools` → empty
2. **Package state**: `dumpsys package <pkg> | grep -E 'stopped=|suspended=|distractionFlags='` → `stopped=true suspended=true distractionFlags=2`
3. **Traffic delta**: count `uid=<uid>` rows and `rb/tb` in `dumpsys netstats detail`, sampled twice at least 5 minutes apart
   - Methodology note: compare **UID stats only**, never add `UID tag stats` on top, or the same
     bytes get counted twice
   - Zero rows for the whole uid = not a single byte in that accounting window
4. **Alarms**: `dumpsys alarm | grep -A3 'Restricted packages'` → `u0a<uid>` should appear;
   `Last OP_SCHEDULE_EXACT_ALARM` should be `ignore`

`scripts/verify.sh` runs 1–4 and prints PASS/FAIL.

> Caveat: `dumpsys netstats detail` only reflects the **current accounting window**. For "how much
> has it uploaded historically", read the cumulative counters in Settings → Apps → App network
> (a separate persistent counter).

---

## 7. Rollback

```bash
bash scripts/rollback.sh          # reverses appops / netpolicy / suspend / notification restriction
```

Manually, command by command:

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
pm grant com.mobiletools.systemhelper android.permission.READ_PHONE_STATE   # same for the other permissions
```

> Nothing was uninstalled, so `cmd package install-existing` is not needed; if `pm grant` is refused
> (privileged permissions), a reboot normally restores the defaults.

---

## 8. Limits: what this approach cannot do

1. **It is not removed.** The APK stays in `/system/priv-app` and `pm path` still finds it. Real
   removal means either root + `mount -o rw,remount /system`, or an unlocked bootloader and a custom
   ROM. This device is `ro.debuggable=0`, so even `adb root` is unavailable.
2. **A reboot undoes part of it.** `suspend` survives, `stopped` is reset by the boot flow (measured
   baseline after reboot: `stopped=false`) → re-run `am force-stop` after every boot.
3. **OTA restores state.** A system update overwrites `/system`, permissions may return to
   `GRANTED_BY_DEFAULT`, and appops / netpolicy may be reset → re-run everything after upgrading.
4. **Privileged reads such as IMEI cannot be blocked.** `READ_PRIVILEGED_PHONE_STATE` is an
   install-time permission; containment relies on "no execution" + "no network".
5. **The local queue does not disappear.** Whatever it collected sits in SQLite waiting to be
   uploaded; `pm clear` wipes it once, but if it gets started again it will refill.
6. **Do not rely on the DNS layer alone.** It stops neither direct IP connections nor
   already-established ones.

---

## 9. Pitfalls (learned the hard way)

| Pitfall | Detail |
|---|---|
| `pm list packages` prints nothing | On HyperOS 4.0 it returns rc=0 with zero bytes for shell; enumerate with `cmd package list packages` |
| `am set-standby-bucket` has no effect | Constant `bucket=10 reason=f` for this package whatever you set |
| `pm uninstall --user 0` is dead | Success reports for HyperOS 2/3 do not hold on 4.0 |
| `pm hide` needs `MANAGE_USERS` | The shell uid does not have it |
| Component name is not necessarily `.service.RegisterIntentService` | The Service Resolver Table in `dumpsys package` only lists exported ones; the exported one here is `.service.RegisterHelperService` |
| Boot broadcast priority | The internet says `2147483647`; `dumpsys` on this device reports `mPriority=999` |
| Running UI on a virtual display | `settings put global overlay_display_devices …` creates the extra display, but `am start --display N` is blocked by `SafeActivityOptions.checkPermissions` (needs `INTERNAL_SYSTEM_WINDOW`); without root shell cannot use it |

---

## 10. License and scope

- Code and docs: MIT, see [LICENSE](LICENSE).
- Use it only on devices **you own or are explicitly authorized to administer**. This repository
  contains no third-party app binaries and no real device or personal data; every number here comes
  from a single test device, and every path/UID in the scripts is resolved at runtime.
- Package names, certificate DNs and hostnames in this repository come from public Android package
  metadata and APK strings; they are used to describe the problem and imply no vendor position.

## Docs

English (primary):

- [docs/what-it-collects.md](docs/what-it-collects.md) — collected fields and code-level evidence
- [docs/matrix-hyperos4.md](docs/matrix-hyperos4.md) — every command with its verbatim failure text
- [docs/verification.md](docs/verification.md) — measurement methodology: netstats semantics,
  sampling length, sources of false positives
- [docs/faq.md](docs/faq.md) — FAQ and counter-examples

中文 / Chinese:

- [docs/zh-CN/what-it-collects.md](docs/zh-CN/what-it-collects.md)
- [docs/zh-CN/matrix-hyperos4.md](docs/zh-CN/matrix-hyperos4.md)
- [docs/zh-CN/verification.md](docs/zh-CN/verification.md)
- [docs/zh-CN/faq.md](docs/zh-CN/faq.md)
