# 验证方法学：怎么才敢说「它真的没跑」

> English version: [../verification.md](../verification.md)

结论先行：**「没有进程」是最弱的一条证据**。这个 App 本来就是「被事件叫醒 → 采集 → 上报 → 退出」的短命进程，你在任意时刻 `ps` 看到的空白，跟它今天跑没跑过毫无关系。

真正能站住的证据有四个：**闹钟、网络策略、流量增量、包状态**。下面逐个说口径。

---

## 1. 口径一：包状态（是不是被按住）

```bash
dumpsys package com.mobiletools.systemhelper | grep -m1 'User 0:'
```

一行里看四个字段：

| 字段 | 期望 | 含义 |
|---|---|---|
| `stopped` | `true` | 被 `am force-stop` 打成「停止」状态。**注意**：任何一次显式启动、或开机流程都可能把它清回 `false` |
| `suspended` | `true` | 系统级挂起（API 28+）。跨重启保留 |
| `distractionFlags` | `2` | `HIDE_NOTIFICATIONS`，通知被藏 |
| `enabled` | `0` | `COMPONENT_ENABLED_STATE_DEFAULT`——**不是「已禁用」**。HyperOS 4.0 不给改（见 matrix） |

单看 `stopped=true` 不足以说明问题：重启后它会变回 `false`，但那时 `suspended` 仍在。两者要一起看。

## 2. 口径二：闹钟（它还能不能自己醒来）

```bash
dumpsys alarm | grep -A3 'Restricted packages'   # 应出现 u0a<uid>
dumpsys alarm | grep 'Last OP_SCHEDULE_EXACT_ALARM'  # 应出现 u0a<uid>:ignore
dumpsys alarm | grep 'mobiletools' -A6           # 看 Reason=
```

关键判据是 `Reason=exact_alarm_permission_revoked`：出现这个，说明系统在**丢弃**它的闹钟，而不是「暂时还没到点」。

> 常见误判：只看到 `ps` 空就宣布成功。它的 `ScheduleRegisterReceiver` 一旦到点就会拉起进程，不看闹钟等于没验。

## 3. 口径三：网络策略（netd 层有没有拦）

```bash
cmd netpolicy list restrict-background-blacklist     # 列表里应有 <uid>
dumpsys netpolicy | grep -A1 'UID=<uid>'
```

期望两行：

```
UID=<uid> policy=1 (REJECT_METERED_BACKGROUND)
UID=<uid> state=null blocked_state={blocked=APP_BACKGROUND|METERED_USER_RESTRICTED,allowed=NONE,effective=…}
```

`APP_BACKGROUND` 表示**任何网络上的后台流量**都被拒；`METERED_USER_RESTRICTED` 是计费网额外的一层。
这两条是 netd 的 iptables 链在生效，跟 App 想不想联网无关。

## 4. 口径四：流量增量（最硬的证据，但要讲口径）

### 4.1 采样方式

```bash
adb shell dumpsys netstats detail > T0.txt
sleep 300
adb shell dumpsys netstats detail > T1.txt
```

该 uid 的条目长这样：

```
  ident=[{type=1, ratType=COMBINED, metered=false, …}] uid=<uid> set=DEFAULT tag=0x0
    NetworkStatsHistory: bucketDuration=7200
      st=1793966400 rb=17892 rp=312 tb=27437 tp=298 op=0
```

- `rb`/`tb` = 收到的字节 / 发出的字节（**这是你要比的**）
- `rp`/`tp` = 包数
- `st` = 桶起始时间戳

### 4.2 三个必须在意的口径问题

1. **只比 UID stats，不要叠加 UID tag stats。**
   `netstats` 同时保存 `uid=` 和 `uid=… tag=0x…` 两套视图，同一份流量会出现在两处。用 `tag=0x0` 过滤，或者干脆只取 UID stats 段落。

2. **「没有条目」≠ 统计坏了。**
   必须同时数「全机有多少条 uid 行」。如果全机条目在涨、而目标 uid 一条都没有，才能说明它确实没流量。
   本机实测：T0 全机 231 条 → T1 246 条 → T2 246 条，目标 uid 全程 **0 条**。

3. **`dumpsys netstats detail` 只覆盖当前统计窗口。**
   想看「历史上传过多少」，去系统「设置 → 应用 → 应用联网」看累计值（那是另一套持久计数，测试设备当时显示的是几百 KB 全记在「后台」）。两者不矛盾，别拿一个打另一个。

### 4.3 采样时长

- 最少 5 分钟（`netstats` 的桶粒度是 2 小时，但写入是实时的，5 分钟足以看到增量）；
- 想更有说服力就跑 10 分钟以上，并跨过一次 `SCHEDULE_EXACT_ALARM` 的窗口；
- **采样期间不要主动打开这个 App**，否则你测的是「你自己点出来的流量」。

## 5. 一份合格的验证记录长什么样

| 指标 | T0 | T1（+7m32s） | T2（+11m09s） |
|---|---|---|---|
| 目标 uid 条目 | 0 | 0 | 0 |
| 目标 uid rb/tb | 0/0 | 0/0 | 0/0 |
| 全机 uid 行数 | 231 | 246 | 246 |
| 进程 | 空 | 空 | 空 |

最后一行「全机 uid 行数在涨」是整张表的灵魂——没有它，上面三个 0 都可以被解释成「统计没在跑」。

## 6. 什么时候该怀疑自己

- 目标 uid 条目一直是 0，但全机条目也是 0 → 统计没工作，重采。
- 增量全是 `rp/tp` 而 `rb/tb` 为 0 → 只有 SYN/RST，可能是被 netd 拒绝产生的失败计数，不是真流量。
- 采样窗口里 `stopped` 从 true 变 false → 有东西把它拉起来了，先查 `dumpsys alarm` / `dumpsys jobscheduler` 的最近触发记录，别急着说 OK。
