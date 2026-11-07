# 网络分析（NETWORK ANALYSIS）

## 1. 端点（APK 字符串实证）

| 端点 | 协议 | 用途 |
|---|---|---|
| `https://dm.wo.com.cn:18081/register` | HTTPS | 主上报 |
| `http://dm.wo.com.cn:18080/register` | HTTP 明文 | 证书校验失败时降级（`usesCleartextTraffic=true`） |
| `https://loc.map.baidu.com/*` 等 | HTTPS | 百度定位 SDK（随包内置） |

请求体：`Content-Type: application/encrypted-json`，RSA + AES 双层加密（`i1/c` + `j1/a`）。
URL 参数：`?ver=6.0&model=<机型>&manuf=<厂商>&sign=<签名>`。

## 2. 触发条件（代码级，`g1/g.java`）

```
if (!isUserPermissionOpen) return false;               // 小米分支：device_provisioned
if (mnc 不在中国 460) return false;
if (!网络连通) → 落库
if (联通卡 || WiFi) → 发
  成功 → 顺带补发一条历史
  失败 → 落库
```

**注意**：只在"联通卡"或"WiFi"下发送。用非联通移动数据时它**只存不发**——这正是会产生积压的场景。

## 3. 观测手段（无 root 能做到什么）

| 手段 | 能做 | 做不到 |
|---|---|---|
| `dumpsys netstats detail` | 按 UID 统计 rb/tb/rp/tp；按 iface 分 wlan/mobile | 只看当前记账窗口 |
| `cmd netpolicy` | 查看/设置后台限制 | per-app 全断 |
| Settings 联网管理 | 持久累计流量（与 netstats 不同源） | 读取需要 UI |
| tcpdump / 抓包 | — | ❌ 无 root |
| DNS 查询日志 | 自建 DNS 可看 | 系统 DoH/缓存会绕过 |

## 4. 测量口径（必须遵守）

1. **只算 `uid=<uid>` 行，不叠加 `uid_tag`**——否则同一批字节被计两次
2. **两次采样间隔 ≥ 5 分钟**，否则移动网络统计延迟会造成假 0
3. **同时记录全机 uid 行数**：如果全机行数也没变化，说明 netstats 本身没在记账，0 增量不作数
4. **不要用"某时刻 ps 为空"推断没上传**——这是 wake→collect→upload→exit 的短命进程

## 5. 已知 IOC 的定性

| 指标 | 类型 | 证据等级 |
|---|---|---|
| `dm.wo.com.cn` | 域名 | A（APK 字符串） |
| `:18080` / `:18081` | 端口 | A |
| `loc.map.baidu.com` 等 | 域名 | A（百度 SDK） |

> 域名出现在 APK 里 ≠ 实际发生过连接。等级 B/C/D 需要抓包或服务端证据，本项目不声明。

## 6. 封锁层次（从强到弱）

| 层 | 手段 | 强度 | 局限 |
|---|---|---|---|
| 进程不存在 | `pm suspend` | 最强 | 可被解除 |
| MIUI 联网控制 | 系统防火墙（4 个开关） | 强（连前台都断） | 私有库，adb 写不进；本机 WLAN 开关被锁死 |
| netd 后台策略 | `netpolicy` 黑名单 | 中（仅后台） | 前台仍可发 |
| DNS 黑洞 | `dm.wo.com.cn → 0.0.0.0` | 中 | 防不住硬编码 IP / DoH |
| 主机防火墙 | iptables | 强 | 需要 root |

## 7. 结论

单靠网络层挡不住（前台仍有通道、WLAN 开关锁死、DoH 可绕）。**必须"进程不存在"作主防线，网络层作补刀。**
