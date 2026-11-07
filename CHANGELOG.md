# CHANGELOG

## v2.2 — 2026-11-07 · 结论修正：卸载是可能的（PackageInstaller API）

> v2.1 及之前写的「无 root 不能卸载」**说错了**。准确说法要窄一档：
> **`pm` 命令行卸不掉，`PackageInstaller` API 卸得掉。**

### 实测（一台零售版 HyperOS 4.0 设备 / Android 17 / API 37 / 未 root / BL 未解锁）

- 工具：Canta（`io.github.samolego.canta`）+ Shizuku（`moe.shizuku.privileged.api`），两个都不需要 root；Shizuku 本身用无线 adb 启动
- 结果：`cmd package list packages | grep mobiletools` → 空；`dumpsys package` → `installed=false`、`ceDataInode=-1`、`deDataInode=-1`
- 可恢复：`cmd package list packages -u` 仍列得出包名 → `cmd package install-existing --user 0 <pkg>` 一条命令还原
- 影响面：497 包全量快照 diff，**只少了这一个包**，新增的只有 Canta 本体与一条无关应用更新；`com.qualcomm.qti.services.systemhelper`、`com.miui.guardprovider` 未动
- 顺手清掉遗留：`cmd netpolicy remove restrict-background-blacklist <uid>`（包没了，uid 会被系统回收）

### 根因

`only root can delete system app for a particular user` 这句判断在 `PackageManagerShellCommand`（CLI 壳）里，
不在 `PackageManagerService`（服务层）。绕开 CLI、用 `PackageInstaller.uninstall()` 发同一个请求，就不受这道检查约束。
这也解释了为什么 `pm hide / disable-user / uninstall` 全拦、而 GUI 工具能过。

### 文档

- `docs/matrix-hyperos4.md` §8 / `docs/zh-CN/matrix-hyperos4.md` 八：新增「真正走得通的一条路」
- `docs/verification.md` §7 / `docs/zh-CN/verification.md` 七：新增「口径五：卸载（`installed=false`）」
- `README.md` / `README.zh-CN.md`：首段与 §0 的结论修正；回滚段落补「已卸载时该做什么」
- 顺带完成软信息泛化：机型 / 版本号 / 账号名全仓库清零（`grep -rin "Redmi\|K80\|XOKCNXM\|24117RK2CC\|XIAN0803"` → 0 命中）

## v2.1 — 2026-11-07 · 软件处置系统 + 工程化重构

真机基线：一台零售版 HyperOS 4.0 设备（Android 17 / API 37）/ 未 root / BL 未解锁。

### 新增：公共库 `scripts/lib/`（9 个）
| 文件 | 职责 |
|---|---|
| `common.sh` | 四值状态机（SUCCESS/FAILED/SKIPPED/UNKNOWN）、保护名单、精确确认串 |
| `adb.sh` | 设备选择、多设备拒绝、shell 封装、超时 |
| `package.sh` | 包/UID/多用户切段/组件/split/sharedUser |
| `permissions.sh` | 权限三层判定 + `revoke` 配 `USER_FIXED` |
| `appops.sh` | AppOps 读写 + 强制回读 |
| `network.sh` | netpolicy + netstats 按 UID/按 iface 采样 |
| `process.sh` | 进程/服务/Alarm/Job/standby 取证 |
| `snapshot.sh` | 快照目录结构（JSON + original_state） |
| `report.sh` | 六层报告 A–F + 判定与退出码 |

### 新增：顶层脚本
- `scripts/audit.sh` —— 只读审计（4.1 APK / 4.2 权限三层 / 4.3 后台 / 4.4 五级证据 / 网络 IOC），输出 `audit-report.md`
- `scripts/preflight.sh` —— 前置检查（adb/多设备/保护名单/系统分区/依赖面）
- `scripts/snapshot.sh` —— 独立快照（device/package/permissions/appops/network + original_state）

### 新增：处置系统 `scripts/restriction/`
- `restriction.sh` 统一入口：`audit | plan | restrict | disable | uninstall | verify | restore`（默认 audit）
- `permission_restrict.sh` / `background_restrict.sh` / `network_restrict.sh`
- `disable_package.sh` / `uninstall_user.sh` / `restore_package.sh` / `dependency_check.sh`
- `lib/`：`package_state.sh` / `user_manager.sh` / `safety_guard.sh` / `snapshot.sh` / `verification.sh`

### 重构
- **`lockdown.sh`**：`run()` 不再无条件 `return 0`（规格书 §2.1 点名的缺陷）。每条命令按 rc + 回读判四值；先快照后动刀；`--force` 需要精确确认串。
- **`verify.sh`**：改为 A–F 六层报告（执行/权限/定时/网络/流量/长时），每层单独出 PASS/FAIL/WARN/UNKNOWN；流量口径只算 `uid=` 行并同时输出全机 uid 行数（证明统计活性）。
- **`rollback.sh`**：不再"AppOps 全 default + 权限全 grant"。改为读 `original_state/` 逐项比对：原本 deny 的权限不授、原本 ignore 的 op 不改、原本不在黑名单的不移除；快照不完整直接拒绝。

### 修复
| 问题 | 修法 |
|---|---|
| 失败被当成功 | 四值状态 + 回读校验，异常文本/rc≠0 一律 FAILED |
| `pm revoke` 被系统重算覆盖 | 紧跟 `set-permission-flags user-set user-fixed` |
| `pm clear` 重置权限 | 执行顺序改为 clear → revoke → USER_FIXED（并在 restriction 里复跑一次） |
| 多用户读数误判 | `dumpsys package` 按 `^    User <id>:` 用 awk 切段 |
| `pm list packages` 空输出 | 全部改用 `cmd package list packages` |
| `getprop sdk/release` 空 | 改用 `ro.mi.os.version.name` / `ro.build.version.incremental` |
| APK SHA-256 取不到（Git Bash 路径转换） | 设备端整串执行 `sha256sum '<path>'` |
| `sh_rpt` 返回非 0 导致 `&& ||` 双打印 | 显式 `return 0` |
| `SERIAL=` 环境变量不生效 | `lib/adb.sh` 里 `SH_SERIAL:=${SERIAL}` |

### 文档
新增 14 份：ARCHITECTURE / THREAT_MODEL / PRIVACY_AUDIT / NETWORK_ANALYSIS / PERMISSION_ANALYSIS /
COMPATIBILITY / COMPATIBILITY-hyperos4 / RECOVERY / RESTORE_GUIDE / RESTRICTION_GUIDE /
DISABLE_GUIDE / UNINSTALL_GUIDE / UNINSTALL_RISK_MATRIX / TEST_PLAN / SECURITY_LIMITATIONS。
README 中英同步更新（新增分层入口与文档索引）。

### 测试与 CI
- `tests/mock_adb.sh` + 20 个场景 + `tests/run_tests.sh`
- `.github/workflows/ci.yml`：`bash -n` → shellcheck → shfmt → 跑测试

### 实测结论（写进代码分支，不是推测）
- `pm uninstall --user` 四种写法全部 `only root can delete system app for a particular user`
- `pm disable-user` / 组件级 disable / `pm hide` 全部被 HyperOS 4.0 拒绝
- `pm suspend` / `pm clear` / `set-distracting-restriction` / `appops` / `netpolicy` 可用
- `ACCESS_LOCAL_NETWORK` 带 `REVOKE_WHEN_REQUESTED`，撤销被忽略

### 未完成（受系统限制）
- 物理删除 `/system/priv-app` APK：需 root 或改 system 分区
- 撤销特权权限（`READ_PRIVILEGED_PHONE_STATE` 等）
- per-UID 全断网（MIUI 联网控制是私有库，adb 写不进）
