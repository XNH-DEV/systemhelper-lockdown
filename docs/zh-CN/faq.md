# FAQ / 反例

> English version: [../faq.md](../faq.md)

### Q1. 为什么不能直接卸载？

因为它不是 `data/app` 里的普通应用，而是 `/system/priv-app` 里的**镜像级预装**。要删它得同时满足三个条件：

1. `/system` 可写 → 需要 root + 关掉 dm-verity / AVB；
2. 不改包名覆盖安装 → 需要**同一张私钥**签名（`O=CU`，在运营商手里）；
3. 改启用状态 → HyperOS 4.0 的 `PackageManagerServiceImpl.shouldRestrictEnabledSettingsChange` 直接拒绝（见 [matrix](matrix-hyperos4.md)）。

三条都堵死，所以「无 root 真卸载」在本机不存在。社区在 HyperOS 2/3 上成功的 `pm uninstall --user 0`，到 4.0 变成了 `Failure [only root can delete system app for a particular user]`。

### Q2. 那 `suspend` 会不会导致别的 App 报错？

会有轻微影响，主要是：任何通过 `<queries>` 点名查它的 App，`queryIntentActivities` / `getPackageInfo` 会拿到「已挂起」或空结果。

实际影响面很小（典型是几个电商 App 的机型/渠道识别分支），而且**它对所有 App 一视同仁**——你也没法「只挂起对采集有利的那部分」。

如果你介意，跳过 suspend：`bash lockdown.sh --no-suspend`。剩下的 appops + netpolicy 已经能把它压住。

### Q3. 会不会影响微信 / 电话 / 相机 / 输入法？

本次处置只碰了**这一个包**的 appops / 权限 / 网络策略，没有动任何共享组件、没有改系统设置、没有卸载。

脚本第一件事就是拒绝 `com.android.*`、`com.miui.*`、`com.google.*`、`com.qualcomm.*` 这些前缀（要动得显式 `--force`）——同名的高通组件 `com.qualcomm.qti.services.systemhelper` 就在保护名单里，别混了。

### Q4. 为什么 `pm list packages` 是空的？

HyperOS 4.0 上它对 shell 不下发列表，`rc=0` 但零字节输出。改用：

```bash
adb shell cmd package list packages        # 全部
adb shell cmd package list packages -d     # 已禁用
adb shell cmd package list packages -e     # 已启用
```

### Q5. 用 Shizuku / 冰箱 / 小黑屋能不能绕过？

- **Shizuku**：它只是把命令以 shell(uid 2000) 身份发出去，你能跑的命令和本脚本完全一样 → 同样撞 `Cannot disable system packages`。
- **冰箱 / 小黑屋**：无 root 时靠「设备管理员 + 挂起」实现，效果≈本方案的 `pm suspend`，不会更强。
- **Xposed / LSPosed**：需要 root。

所以「无 root 的上限」就是本仓库这一套；再往上必须 root 或换 ROM。

### Q6. 重启之后还要重跑吗？

建议跑，但不一定每次都必要：

| 项 | 跨重启 |
|---|---|
| `suspend` | 保留 |
| appops / netpolicy | 保留 |
| `distractionFlags` | 保留 |
| `stopped` | **会掉**（开机流程重置） |

最省事的做法：重启后跑一次 `adb shell am force-stop com.mobiletools.systemhelper`，或者 `bash scripts/verify.sh` 看 `stopped` 是不是又变回 `false` 了。

### Q7. 系统 OTA 会把它放回来吗？

它本来就在 `/system`，OTA 只会覆盖 `/system`——所以 APK 一直在，但**权限的默认授予状态和 appops 有可能被重置**。升级完重跑一遍 `lockdown.sh` 最稳。

### Q8. 关掉 MIUI「联网控制」的 WLAN 会不会把别的功能搞坏？

不会。那条开关的粒度就是「这个 uid 能不能走 WLAN」，只影响它自己。
唯一副作用：某些用它的渠道识别的 App，可能拿不到机型信息而走默认分支（一般就是推荐位不准）。

### Q9. 为什么 `dumpsys netstats` 里一条它的记录都没有？

两种可能，别急着下结论：

1. **它确实没流量**（我们处置后就是这个状态）；
2. **统计窗口重置了**（重启、流量统计清零）。

区分办法：同时数全机有多少条 `uid=` 行。全机条目正常上涨 + 目标 uid 为 0，才是真的 0。详见 [verification.md](verification.md)。

### Q10. 它会不会偷偷装 App / 读我短信？

不会。APK 里没有 `INSTALL_PACKAGES`、没有 `READ_SMS` / `READ_CONTACTS` / `READ_CALL_LOG`、没有无障碍服务、没有通知监听、也没有设备管理员资格。
它的问题是**采集**（指纹 + 位置 + 应用列表），不是**控制**。别把两件事混为一谈，否则容易把精力花在防错地方。

### Q11. 有没有办法让它「看起来还在，但一点用没有」？

无 root 下最接近的就是本方案：进程起不来 + 后台流量被 netd 拒 + 定时任务被闹钟系统丢弃。
真要「连前台也不给网」，只剩 MIUI 联网控制那四个开关（[README.zh-CN §4.6](../../README.zh-CN.md)）。

### Q12. 为什么不用 hosts / DNS 黑洞一把梭？

DNS 只能拦域名，拦不住：

- 已建立的连接 / 写死 IP 直连；
- App 自己启动的 DoH；
- 先把数据落本地、换个网络再补传。

所以 DNS 层只能当**补刀**，主防线还是 appops + netpolicy。
