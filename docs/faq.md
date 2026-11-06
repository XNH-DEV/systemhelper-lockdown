# FAQ / counter-examples

### Q1. Why can it not simply be uninstalled?

Because it is not a normal app in `data/app` — it is a **preinstall at image level** inside
`/system/priv-app`. Removing it requires all three of:

1. `/system` writable → root, plus dm-verity / AVB disabled;
2. an overwrite install that keeps the package name → signed with **the same private key**
   (`O=CU`, held by the operator);
3. changing the enabled state → HyperOS 4.0's
   `PackageManagerServiceImpl.shouldRestrictEnabledSettingsChange` refuses outright
   (see [matrix](matrix-hyperos4.md)).

All three are blocked, so "root-free real uninstall" does not exist on this device. The
`pm uninstall --user 0` that the community reports working on HyperOS 2/3 becomes
`Failure [only root can delete system app for a particular user]` on 4.0.

### Q2. Does `suspend` break other apps?

There is a small effect, mainly: any app that names it in `<queries>` will get "suspended" or an
empty result from `queryIntentActivities` / `getPackageInfo`.

The blast radius is tiny in practice (typically the model/channel-detection branch of a few
e-commerce apps), and it is **uniform** — you cannot "suspend only the parts that help collection".

If that bothers you, skip suspend: `bash lockdown.sh --no-suspend`. The remaining appops + netpolicy
already hold it down.

### Q3. Will this affect WeChat / phone calls / camera / the IME?

This procedure only touches appops, permissions and network policy **for this one package**. No shared
component was modified, no system setting was changed, nothing was uninstalled.

The very first thing the script does is refuse the `com.android.*`, `com.miui.*`, `com.google.*` and
`com.qualcomm.*` prefixes (changing those requires an explicit `--force`) — the lookalike Qualcomm
component `com.qualcomm.qti.services.systemhelper` is on that protected list, so do not confuse them.

### Q4. Why is `pm list packages` empty?

On HyperOS 4.0 it returns nothing to shell: `rc=0` with zero bytes of output. Use instead:

```bash
adb shell cmd package list packages        # all
adb shell cmd package list packages -d     # disabled
adb shell cmd package list packages -e     # enabled
```

### Q5. Can Shizuku / Ice Box / Hail bypass this?

- **Shizuku**: it only sends commands as shell (uid 2000) — exactly the same command set this script
  uses → it hits the same `Cannot disable system packages`.
- **Ice Box / Hail**: without root they work via "device admin + suspend", which is roughly what
  `pm suspend` does here and is not stronger.
- **Xposed / LSPosed**: requires root.

So the "root-free ceiling" is what this repository does; going further needs root or a custom ROM.

### Q6. Do I need to re-run after a reboot?

Recommended, though not always mandatory:

| Item | Across reboot |
|---|---|
| `suspend` | survives |
| appops / netpolicy | survive |
| `distractionFlags` | survives |
| `stopped` | **lost** (the boot flow resets it) |

Cheapest habit: after boot, run
`adb shell am force-stop com.mobiletools.systemhelper`, or `bash scripts/verify.sh` and check whether
`stopped` went back to `false`.

### Q7. Will a system OTA restore it?

It already lives in `/system`, and an OTA only overwrites `/system` — so the APK never left, but the
**default permission grants and appops may be reset**. Re-running `lockdown.sh` after an upgrade is
the safe move.

### Q8. Does turning off WLAN in MIUI "app network" break other features?

No. That switch's granularity is exactly "may this uid use WLAN", so it only affects this package.
The only side effect: apps that use it for channel detection may fall back to defaults (usually just
less accurate recommendations).

### Q9. Why are there no records for it in `dumpsys netstats` at all?

Two possibilities; do not jump to conclusions:

1. **it really has no traffic** (the state after containment);
2. **the accounting window was reset** (reboot, traffic counters cleared).

How to tell: count the device-wide `uid=` rows at the same time. Growing device-wide entries +
zero target uid = a real zero. Details in [verification.md](verification.md).

### Q10. Could it secretly install apps or read my SMS?

No. The APK has no `INSTALL_PACKAGES`, no `READ_SMS` / `READ_CONTACTS` / `READ_CALL_LOG`, no
accessibility service, no notification listener, and no device-admin rights.
Its problem is **collection** (fingerprint + location + app list), not **control**. Do not conflate
the two, or you will spend effort defending the wrong thing.

### Q11. Can I make it "look alive but be useless"?

Without root, this procedure is the closest you get: process cannot start, background traffic is
rejected by netd, timers are dropped by the alarm system.
If you also want "no network even in the foreground", only the four MIUI app-network switches remain
([README §4.6](../README.md)).

### Q12. Why not just hosts / a DNS sinkhole and be done?

DNS stops hostnames only. It cannot stop:

- already-established connections, or direct connections to hard-coded IPs;
- DoH started by the app itself;
- data cached locally first and uploaded later on another network.

So the DNS layer is a **finisher**; the main line of defence remains appops + netpolicy.
