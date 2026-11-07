# HyperOS 4.0 command matrix (measured)

Test environment: a retail HyperOS 4.0 build (Android 17 / API 37), no root, bootloader locked,
`ro.debuggable=0`. Every output below is copied verbatim (line breaks included) so you can `grep`
it directly.

---

## 1. The uninstall / disable ladder

```bash
pm uninstall -k --user 0 com.mobiletools.systemhelper
# Failure [only root can delete system app for a particular user]            rc=1

pm uninstall --user 0 com.mobiletools.systemhelper
# Failure [only root can delete system app for a particular user]            rc=1

cmd package uninstall --user 0 com.mobiletools.systemhelper
# Failure [only root can delete system app for a particular user]            rc=1

pm hide com.mobiletools.systemhelper
# java.lang.SecurityException: Access denied, requires: android.permission.MANAGE_USERS
#   at com.android.server.pm.PackageManagerService$IPackageManagerImpl.setApplicationHiddenSettingAsUser(...)  rc=255

pm disable-user --user 0 com.mobiletools.systemhelper
# java.lang.SecurityException: Cannot disable system packages.
#   at com.android.server.pm.PackageManagerServiceImpl.shouldRestrictEnabledSettingsChange(PackageManagerServiceImpl.java:1116)
#   at com.android.server.pm.PackageManagerService.setEnabledSettings(...)                                   rc=255

pm disable --user 0 com.mobiletools.systemhelper
# java.lang.SecurityException: Cannot disable system packages.                                              rc=255

pm suspend --user 0 com.mobiletools.systemhelper
# Package com.mobiletools.systemhelper new suspended state: true                                            rc=0   ✅
```

## 2. Other variants (none of them work)

```bash
pm uninstall-system-updates com.mobiletools.systemhelper
# Success (stdout) but rc=1 — this package has no update layer, the APK sits directly in /system

pm revoke com.mobiletools.systemhelper android.permission.ACCESS_LOCAL_NETWORK
# rc=0, but dumpsys package still reads granted=true (Android 16+ privileged default grant, cannot be revoked)
```

## 2.5 Same package name, higher version, empty stub (the signature wall)

The idea: build a harmless stub APK that keeps the package name but carries a higher `versionCode`,
install it as an "update", and let the system replace the telemetry app with it.

Stub used here: `package com.mobiletools.systemhelper`, `versionCode 35` (retested with
`999999999`), `minSdk 31` / `targetSdk 34`, no dex, `android:hasCode="false"`, signed with a
throwaway RSA-2048 key of our own.

| # | Path | Result |
|---|---|---|
| 11 | `adb install -r` | `Failure [INSTALL_FAILED_UPDATE_INCOMPATIBLE: Existing package com.mobiletools.systemhelper signatures do not match newer version; ignoring!]` |
| 12 | `adb install -r -d` (allow downgrade) | same |
| 13 | `adb install -r -t` (allow test package) | same |
| 14 | `pm install -r --user 0` | same |
| 15 | `pm install -r -t -d --user 0` | same |
| 16 | `pm install -r -t -d --user 999` (secondary profile) | same |
| 17 | `cmd package install -r -t -d` | same |
| 18 | `pm install-create -r -t` (OK) → `pm install-write` (OK) → `pm install-commit` | same, on commit |
| 19 | `versionCode 999999999` instead of 35, retried via 11–15 | same |

Note that the installer session in #18 is created successfully and even accepts the payload —
the rejection happens at commit, in signature verification. Version comparison never runs: the
message is a signature mismatch, not a downgrade refusal.

### Control experiment: is the wall the signature, or the `priv-app` status?

Same pipeline on a package we own (`com.probe.lockdown.test`), installed into `data/app`:

| Step | Action | Result |
|---|---|---|
| A | install `com.probe.lockdown.test` vc=1, key **stub** | `Success` |
| B | install `-r` vc=2, **same** key | `Success` (upgrade path works) |
| C | install `-r` vc=3, **different** key (`other`) | `Failure [INSTALL_FAILED_UPDATE_INCOMPATIBLE: Existing package com.probe.lockdown.test signatures do not match newer version; ignoring!]` |

So the upgrade mechanism itself is fine; what blocks the stub is the signing key. To pass, an
"update" must be signed with the **same private key** as the installed app — here the operator's
`O=CU` key, which is not obtainable. Without root there is no way to relax `pm`'s signature check.

## 3. The two additional commands that do succeed

```bash
pm set-distracting-restriction --flag hide-notifications --user 0 com.mobiletools.systemhelper
# rc=0 → dumpsys package reads back distractionFlags=2

am force-stop com.mobiletools.systemhelper
# rc=0 → stopped=true
```

## 4. Two "command runs but does nothing" traps

```bash
pm list packages -d
# rc=0, empty output. On HyperOS 4.0 the pm list subcommands return nothing to shell.
cmd package list packages -d
# package:… (normal output) → always enumerate with cmd package
```

```bash
am set-standby-bucket com.mobiletools.systemhelper restricted
am get-standby-bucket com.mobiletools.systemhelper
# 10 (= ACTIVE, the set did not take effect)
dumpsys usagestats | grep 'package=com.mobiletools.systemhelper u=0 bucket'
# bucket=10 reason=f lastRestrictAttempt=+1s490ms lastRestrictReason=f
# Whatever you set — restricted / rare / working_set — bucket stays 10 and reason stays f (forced)
```

Conclusion: this lever is dead on this device; do not count on the standby bucket to throttle it.

## 5. Component launch attempts (proof it cannot be started)

```bash
am startservice -n com.mobiletools.systemhelper/.service.RegisterHelperService
# Error: Requires permission com.mobiletools.systemhelper.permission      rc=255

am start-foreground-service -n com.mobiletools.systemhelper/.service.RegisterHelperService
# Error: Requires permission com.mobiletools.systemhelper.permission      rc=255

am start -n com.mobiletools.systemhelper/.Activity.TestActivity
# java.lang.SecurityException: Permission Denial: starting Intent … requires
#   com.mobiletools.systemhelper.permission                               rc=255

am broadcast -a android.intent.action.BOOT_COMPLETED -n com.mobiletools.systemhelper/.control.OnBootReceiver
# java.lang.SecurityException: Permission Denial: not allowed to send broadcast
#   android.intent.action.BOOT_COMPLETED from pid=…, uid=2000              rc=255

ps -A | grep -i mobiletools      # still empty after all three attempts
```

> Note: these three failures happen because the **components are protected by a signature-level
> permission** (shell cannot start them either) — not because we disabled the package.
> The upside is that third-party apps cannot start it either; the downside is that this kind of test
> **cannot** prove "the system itself cannot start it". The real evidence is the traffic and alarm
> data in §6.

## 6. Three observations that do prove "it really did not run"

```bash
# 1) Alarms: all five of its walarms get dropped
dumpsys alarm | grep 'motion.*mobiletools\|mobiletools.*walarm' -A3
# Snapshot: type=ELAPSED_WAKEUP tag=*walarm*:com.mobiletools.systemhelper/.control.SIMStateReceiver
#           policyWhenElapsed: requester=… app_standby=… device_idle=…
# Reason=exact_alarm_permission_revoked ← the key line: the system is discarding the alarm

dumpsys alarm | grep -A3 'Restricted packages'
#   u0a<uid> com.mobiletools.systemhelper      ← force-standby in effect

dumpsys alarm | grep 'Last OP_SCHEDULE_EXACT_ALARM'
# … u0a<uid>:ignore …                            ← exact alarms denied

# 2) Network policy
dumpsys netpolicy | grep -A1 'UID=<uid>'
# UID=<uid> policy=1 (REJECT_METERED_BACKGROUND)
# UID=<uid> state=null blocked_state={blocked=APP_BACKGROUND|METERED_USER_RESTRICTED,allowed=NONE,…}

# 3) Traffic (methodology in docs/verification.md)
dumpsys netstats detail | grep -A3 'uid=<uid> set='
```

## 7. Virtual display (recorded so nobody else wastes time)

```bash
settings put global overlay_display_devices 720x1600/300     # succeeds, an extra Display 4 appears
am start --display 4 -a android.settings.APPLICATION_DETAILS_SETTINGS -d package:<pkg>
# java.lang.SecurityException: Permission Denial: starting Intent … with launchDisplayId=4
#   at com.android.server.wm.SafeActivityOptions.checkPermissions(SafeActivityOptions.java:303)
```

Conclusion: without root, shell lacks `INTERNAL_SYSTEM_WINDOW`, so the secondary display can be
created but **no Activity can be launched into it** — it is an empty screen. "Drive the UI without
touching the main display" is not achievable from the shell layer.

---

## 8. The path that does work: PackageInstaller API (added 2026-11-07)

Everything in §1 fails for one reason: `pm uninstall` is `PackageManagerShellCommand`, and HyperOS
4.0 puts the `only root can delete system app for a particular user` guard **inside that command**,
not inside the package manager service. The same uninstall issued through
`PackageInstaller.uninstall()` — what a Shizuku-backed GUI does — is not gated by that check.

Measured on the same device, same build, no root, bootloader locked:

```text
# tool: Canta (io.github.samolego.canta) + Shizuku (moe.shizuku.privileged.api)
# both root-free; Shizuku itself was started over wireless adb

# before
$ adb shell cmd package list packages | grep -i mobiletools
package:com.mobiletools.systemhelper

# after uninstalling for user 0 from Canta's UI
$ adb shell cmd package list packages | grep -i mobiletools
(empty)

$ adb shell cmd package list packages -u | grep -i mobiletools
package:com.mobiletools.systemhelper     # still known to the system → restorable, nothing to download
```

State afterwards:

```text
$ adb shell dumpsys package com.mobiletools.systemhelper | grep -m1 'User 0:'
    User 0: ceDataInode=-1 deDataInode=-1 … installed=false hidden=false suspended=true … stopped=true notLaunched=true

$ adb shell cmd package path com.mobiletools.systemhelper
(empty)
```

| Field | Value | Meaning |
|---|---|---|
| `installed` | `false` | no longer installed for user 0 |
| `ceDataInode` / `deDataInode` | `-1` | app data deleted |
| `codePath` | still `/system/priv-app/com.mobiletools.systemhelper` | the APK stays in the image |

Scope check: the 497-package snapshot taken the day before, diffed against the device right after
the uninstall — **exactly one** package gone (`com.mobiletools.systemhelper`); the only additions
were Canta itself and an unrelated app update. `com.qualcomm.qti.services.systemhelper` and
`com.miui.guardprovider` are untouched.

Restore:

```bash
adb shell cmd package install-existing --user 0 com.mobiletools.systemhelper
```

Consequence for this repository: the blanket claim *"cannot be uninstalled without root"* is wrong
as stated. What is true is narrower — **the `pm` CLI cannot do it; the `PackageInstaller` API can.**
The L1–L5 lockdown in `scripts/lockdown.sh` is still the right choice when you would rather keep
the package in place than remove it (OTA-safe, one-command rollback).
