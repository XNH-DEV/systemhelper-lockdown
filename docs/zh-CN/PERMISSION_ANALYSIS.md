# 权限分析（PERMISSION ANALYSIS）

## 1. 三层结构（必须分开看）

```
Manifest 声明          dumpsys package → requested permissions:
安装期授予             dumpsys package → install permissions:      granted=true（priv-app 自带）
运行时授予（按用户）   dumpsys package → runtime permissions:      granted=true/false + flags
AppOps 实际模式        cmd appops get                               allow / ignore / default
```

**申请 ≠ 授予 ≠ 可用**。本包的 `QUERY_ALL_PACKAGES` 属于声明式权限，无 revoke 通道；`READ_PRIVILEGED_PHONE_STATE` 在安装期就 granted，`pm revoke` 直接报错。

## 2. 本机实测表（HyperOS 4.0 / API 37 / user 0）

| 权限 | 声明 | 安装期 | 运行时 | 可撤销 | 处置后 |
|---|---|---|---|---|---|
| `READ_PHONE_STATE` | 是 | — | true | ✅ | false + USER_FIXED |
| `ACCESS_FINE_LOCATION` | 是 | — | true | ✅ | false + USER_FIXED |
| `ACCESS_COARSE_LOCATION` | 是 | — | true | ✅ | false + USER_FIXED |
| `ACCESS_BACKGROUND_LOCATION` | 是 | — | true | ✅ | false + USER_FIXED |
| `READ_EXTERNAL_STORAGE` | 是 | — | true | ✅ | false + USER_FIXED |
| `BLUETOOTH_CONNECT` | 是 | — | true | ✅ | false + USER_FIXED |
| `ACCESS_LOCAL_NETWORK` | 是 | — | true | ❌ | true（`REVOKE_WHEN_REQUESTED`） |
| `READ_PRIVILEGED_PHONE_STATE` | 是 | true | — | ❌ | true（install-time） |
| `READ_PRECISE_PHONE_STATE` | 是 | true | — | ❌ | true |
| `PACKAGE_USAGE_STATS` | 是 | true | — | AppOps only | AppOps ignore |
| `QUERY_ALL_PACKAGES` | 是 | true | — | ❌ | 无法撤 |
| `INTERNET` / `ACCESS_NETWORK_STATE` | 是 | true | — | ❌ | 靠 netpolicy |

## 3. 撤销的正确写法（唯一在真机上稳定的）

```bash
pm revoke --user 0 <pkg> android.permission.READ_PHONE_STATE
pm set-permission-flags --user 0 <pkg> android.permission.READ_PHONE_STATE user-set user-fixed
```

只做第一句，下一次权限重算就把值改回去（实测：撤销后 `pm clear` 或系统重算即恢复 true）。
`user-fixed` 让用户在系统 UI 里也改不动——对本项目是想要的。

## 4. 顺序坑

```
❌ 先 revoke 再 pm clear     → 权限被重置回默认，白做
✅ 先 pm clear 再 revoke     → 之后加 USER_FIXED，稳定
```

## 5. 判定"撤销是否被系统接受"

`pm revoke` 的返回值**不可信**（rc=0 但值不变）。必须回读：

```bash
dumpsys package <pkg> | awk '/^    User 0:/{f=1} /^    User [0-9]+:/{if(f && $0 !~ /User 0:/) f=0} f' \
  | sed -n '/runtime permissions:/,/^$/p'
```

判据：`granted=false` **且** flags 含 `USER_FIXED`。

## 6. 特权权限与签名权限

- `READ_PRIVILEGED_PHONE_STATE`：只有 `priv-app` + 白名单（`/system/etc/permissions/privapp-permissions-systemhelper.xml`）才授予，撤销通道不存在
- `com.mobiletools.systemhelper.permission`：signature 级，其他应用除非同签名否则无法持有 → 这也是它导出 Service 后第三方无法调用的原因

## 7. 无法通过权限层解决的

| 能拿到的数据 | 靠什么 |
|---|---|
| IMEI/IMSI | 只能靠"进程不跑" |
| 已装应用列表 | 只能靠"进程不跑" |
| 本地网络扫描 | 只能靠"进程不跑" |
