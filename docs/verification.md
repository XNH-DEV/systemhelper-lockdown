# Verification methodology: how to earn the right to say "it is not running"

Short version: **"no process" is the weakest possible evidence.** This app is a short-lived
*wake → collect → upload → exit* process, so an empty `ps` at an arbitrary moment has nothing to do
with whether it ran today.

Four metrics can carry the claim: **alarms, network policy, traffic delta, package state.** Each one
has a methodology caveat; here they are.

---

## 1. Metric 1: package state (is it being held down)

```bash
dumpsys package com.mobiletools.systemhelper | grep -m1 'User 0:'
```

Four fields in one line:

| Field | Expected | Meaning |
|---|---|---|
| `stopped` | `true` | set by `am force-stop`. **Careful**: any explicit start, or the boot flow, can clear it back to `false` |
| `suspended` | `true` | system-level suspend (API 28+). Survives reboot |
| `distractionFlags` | `2` | `HIDE_NOTIFICATIONS`, notifications hidden |
| `enabled` | `0` | `COMPONENT_ENABLED_STATE_DEFAULT` — **not** "disabled". HyperOS 4.0 refuses to change it (see [matrix](matrix-hyperos4.md)) |

`stopped=true` alone proves nothing: after a reboot it flips back to `false`, while `suspended` is
still in place. Read them together.

## 2. Metric 2: alarms (can it still wake itself up)

```bash
dumpsys alarm | grep -A3 'Restricted packages'   # expect u0a<uid>
dumpsys alarm | grep 'Last OP_SCHEDULE_EXACT_ALARM'  # expect u0a<uid>:ignore
dumpsys alarm | grep 'mobiletools' -A6           # inspect Reason=
```

The decisive marker is `Reason=exact_alarm_permission_revoked`: when it appears, the system is
**discarding** the alarm rather than "not having reached it yet".

> Common misjudgement: seeing an empty `ps` and declaring victory. Its `ScheduleRegisterReceiver`
> starts a process the moment it is due; not looking at alarms means you did not verify anything.

## 3. Metric 3: network policy (is netd blocking)

```bash
cmd netpolicy list restrict-background-blacklist     # the uid should be listed
dumpsys netpolicy | grep -A1 'UID=<uid>'
```

Two expected lines:

```
UID=<uid> policy=1 (REJECT_METERED_BACKGROUND)
UID=<uid> state=null blocked_state={blocked=APP_BACKGROUND|METERED_USER_RESTRICTED,allowed=NONE,effective=…}
```

`APP_BACKGROUND` means all background traffic on **any** network is rejected;
`METERED_USER_RESTRICTED` adds a layer for metered networks. Both come from netd's iptables chain,
regardless of whether the app wants to go online.

## 4. Metric 4: traffic delta (the hardest evidence — with caveats)

### 4.1 Sampling

```bash
adb shell dumpsys netstats detail > T0.txt
sleep 300
adb shell dumpsys netstats detail > T1.txt
```

An entry for the uid looks like this:

```
  ident=[{type=1, ratType=COMBINED, metered=false, …}] uid=<uid> set=DEFAULT tag=0x0
    NetworkStatsHistory: bucketDuration=7200
      st=1793966400 rb=17892 rp=312 tb=27437 tp=298 op=0
```

- `rb`/`tb` = received / transmitted bytes (**compare these**)
- `rp`/`tp` = packet counts
- `st` = bucket start timestamp

### 4.2 Three caveats you must respect

1. **Compare UID stats only; never add UID tag stats on top.**
   `netstats` stores both the `uid=` and the `uid=… tag=0x…` views, so the same bytes appear twice.
   Filter with `tag=0x0`, or just take the UID stats section.

2. **"No entries" ≠ "accounting is broken".**
   You must also count how many uid rows exist device-wide. Only when the device-wide count grows
   while the target uid has none can you say it really moved no traffic.
   Measured here: device-wide 231 rows at T0 → 246 at T1 → 246 at T2, target uid **0 rows** throughout.

3. **`dumpsys netstats detail` only covers the current accounting window.**
   For "how much has it uploaded historically", look at the cumulative counters under
   Settings → Apps → App network (a separate persistent counter; on the test device it showed a few
   hundred KB, all attributed to "background"). The two are not contradictory — do not use one to
   attack the other.

### 4.3 Sampling length

- 5 minutes minimum (`netstats` buckets are 2 hours wide but written in real time; 5 minutes is
  enough to see a delta);
- 10+ minutes is more convincing, and make sure the window spans at least one
  `SCHEDULE_EXACT_ALARM` slot;
- **do not open the app yourself during sampling** — you would be measuring your own taps.

## 5. What a decent verification record looks like

| Metric | T0 | T1 (+7m32s) | T2 (+11m09s) |
|---|---|---|---|
| Target uid entries | 0 | 0 | 0 |
| Target uid rb/tb | 0/0 | 0/0 | 0/0 |
| Device-wide uid rows | 231 | 246 | 246 |
| Processes | empty | empty | empty |

The last row — "device-wide rows are growing" — is the soul of that table. Without it, the three
zeros above could all be explained away as "the accounting is not running".

## 6. When to doubt yourself

- Target uid entries stay 0 **and** device-wide entries are 0 too → accounting is dead, sample again.
- The delta is all `rp/tp` with `rb/tb` at 0 → only SYN/RST, probably failure counters produced by
  netd rejections, not real traffic.
- `stopped` flips from true to false inside your window → something started it; check the latest
  trigger records in `dumpsys alarm` / `dumpsys jobscheduler` before saying OK.
