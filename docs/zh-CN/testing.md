# 测试

[← 返回 README](../../README.zh-CN.md) · [English](../testing.md) · [Русский](../ru/testing.md)

---

## 本地检出校验

```bash
bash -n xrayebator install.sh update.sh uninstall.sh
for test_file in validation/*.sh; do bash "$test_file" || exit; done
```

这是本地检查的最小门槛。`shellcheck` 可以额外运行，但不是 CI 的必要 gate（见下文）。

## 测试覆盖范围

`validation/` 中有 42 个静态与本地回归测试：

| 测试 | 检查内容 |
|---|---|
| `test-transaction-safety.sh` | 配置操作的事务安全性 |
| `test-project-update-rollback.sh` | 项目更新失败后的回滚 |
| `test-xhttp-route-path-repair.sh` | 迁移过程中 XHTTP 路径的修复 |
| `test-multiroute-argument-preservation.sh` | 多线路配置档传输参数的保留 |
| `test-happ-subscription-static.sh` | HAPP 订阅处理器（routing 占位符、校验顺序） |
| `test-happ-client-routing.sh` | HAPP 客户端分流配置：基于 bypass 集合的生成器（258 个域名、占位符、`geoip:ru`）、nginx 缓冲区、菜单接线 |
| `test-legacy-profile-port-sync.sh` | 无 `routes` 的旧版配置档仍能收到 SNI/端口同步 |
| `test-subscription-server-name.sh` | 客户端中显示的订阅服务器名 |
| `test-fingerprint-subscription-sync.sh` | 更换指纹时线路与订阅的同步 |
| `test-dead-stealth-route-pruning.sh` | 失效 stealth 线路的清理 |
| `test-cascade-routing.sh` | 级联路由 |
| `test-cascade-upstream-import.sh` | 从链接导入级联上游 |
| `test-update-branch-pinning.sh` | `update <branch>` 在 `.current_branch` 固定分支；GUI 更新不会切回其它分支 |
| `test-update-xray-core-sync.sh` | Xray-core 更新同步 |
| `test-vless-url-generation.sh` | `vless://` 链接生成 |
| `test-installer-network-fallbacks.sh` | 安装脚本网络回退 |
| `test-bbr-removal-migration.sh` | 已删除 BBR/TCP 调优在所有路径上的安全清理 |
| `test-legacy-udp443-migration.sh` | 一次性清理旧版 UDP/443 阻断规则 |
| `test-main-menu-numbering.sh` | 主菜单条目编号连续并与处理函数一致（含后端条目与监控的 1..14） |
| `test-backend-registry.sh` | 后端注册表（多协议阶段）：source-mode 下的注册表 CRUD（经 `safe_jq_write`）、installed/field 读取、生命周期入口的安全 no-op、`backend-status` JSON 结构 |
| `test-hysteria2-lifecycle.sh` | Hysteria 2 后端：`server.yaml` 渲染（userpass 映射、占位回退）、systemd 单元安全模型、架构映射、TLS 探测、授权/吊销/过期-恢复事件、预删除配置档后的 deleted 重生成、created 为无操作（不自动签发）、纯函数 `hysteria2://` 构造器、CLI 分发与订阅接线 |
| `test-awg-lifecycle.sh` | AmneziaWG 后端：Amnezia 默认 junk 方言（Jc=5、Jmin=10、Jmax=50、H1–H4=1..4、S1–S4 互不相同）、密钥生成、服务端配置渲染（PostUp MASQUERADE、安装时无 peer）、peer 地址分配、客户端 `.conf` 内容、revoke/expire/restore 事件、预删除配置档后的 deleted 重生成、created 为无操作（不自动签发）、CLI 分发、`/etc/modules-load.d` 的开机模块登记（仅在模块可用时写入）、`backend-start`（「已安装」≠「正在运行」）、以及安装成功判定：内核模块必须针对**当前**内核（`AWG_MODULES_ROOT` 为测试接缝） |
| `test-main-readiness-regressions.sh` | 审计后的 readiness 回归：certbot manifest、UFW manifest、nginx 回滚、权限与 SSH 端口 |
| `test-sni-change-cli.sh` | `sni-change` CLI：JSON 输出、Reality、XHTTP host、配置档同步与回滚 |
| `test-bypass-cli.sh` | `bypass` CLI：JSON 输出、路由规则更新、带 SNI 探测的 add |
| `test-port-change-cli.sh` | `port-change` CLI：unit/shared/move 入站场景、无效端口、缺少配置档、多线路 `--route` |
| `test-profile-revoke-expire-cli.sh` | `profile-revoke`（仅令牌 / 轮换 uuid 且保留共享端口上的其他客户端）与配置档有效期（停用、从快照恢复、无快照重建、幂等的 `expire-check`） |
| `test-apt-lock-race.sh` | apt-lock 竞态：安装命令携带 `DPkg::Lock::Timeout`、检测 `unattended-upgrade` 工作进程、quickstart 12 分钟预算 |
| `test-quickstart-email-and-inspect.sh` | `quickstart` 的显式 email 模式（`--without-email` 不使用虚假地址）以及 `inspect --json` 的只读不变量 |
| `test-quickstart-migration-parity.sh` | `quickstart` 执行与 `main_menu` 相同的关键迁移 |
| `test-quickstart-subscription-port.sh` | 确认 `quickstart` 使用规范的订阅基础地址 helper，不回退到无关的硬编码 URL |
| `test-quickstart-tls-fallback.sh` | `http_tls` 优雅降级分支：SUB_TLS_MODE 切换、HTTP-only vhost（无 ssl/无 proxy）、按模式写入标记、仅 ip_tls 设置续期定时器以及 JSON 的 degraded 元数据 |
| `test-audit-functional.sh` | HowDeploy 审计（P0/P1）的功能回归检查 |
| `test-audit-privilege-regressions.sh` | 权限边界回归 |
| `test-traffic-limit-cli.sh` | 配置档流量统计：限额单位归一化、增量累计与 watermark 重置、保留 flow 的即时封禁/解封、`expire` × 流量的交叉守卫、端口冲突下的 Stats 入站迁移、`profiles` 输出中的流量字段、迁移注册 |
| `test-alerts-monitor.sh` | 监控的 Telegram 告警：`alerts-setup/status/enable/disable/test`、测试未投递时不保存配置、定时器单元与迁移、服务与后端（hysteria2、AWG）检测、订阅及其降级到 `http_tls`、SNI 探测（部分/完全不可达、恢复、间隔、重试时不重跑探测）、重启的边沿触发 |
| `test-subscription-formats.sh` | 订阅格式：`vless://`（7 种传输方式）与 `hysteria2://` 的归一化、IPv6/percent-decoding、Clash/mihomo YAML（reality-opts、flow、packet-encoding、grpc-opts、hysteria2，有 PyYAML 时做校验）、通过 `jq` 校验 sing-box JSON、带说明地跳过 PQ 与 xhttp、边界情况（无存活线路、只有 PQ）、处理器 heredoc 中的内容协商、迁移注册与 `profiles` 的 CLI 契约 |
| `test-dns01-certbot.sh` | DNS-01（Cloudflare/Route53）：域名与提供商校验（IP 与单标签名称会被拒绝）、按提供商组装 certbot 参数（插件、凭据、propagation、deploy-hook、`-m` 或免邮箱注册）、按提供商写入 `0600` 凭据内容、nginx vhost **不含** `listen 80` 与 ACME location、CLI 校验失败时不写盘，以及静态接线（分发器、菜单项、插件包、UFW 端口、`domain_tls` 标记、certbot 清单、uninstall 清理） |
| `test-channel-test-cli.sh` | `channel-test` 的纯函数与 CLI 契约：由链接记录构造客户端配置（Reality/TLS、flow、gRPC serviceName、xhttp path/host/mode、PQ 的 ML-KEM encryption）、stdout 只有 JSON（进度走 `exec 3>&1`）、不依赖 Let's Encrypt 与订阅标记；真实网络运行只在实机进行，CI 不跑 |
| `test-jq-keyword-compat.sh` | 守护一类在 jq 1.6（Ubuntu 22.04、Debian 12）上会静默编译失败的写法：「关键字作键、同名变量作值」的对象对（如 `label: $label`）与 `{$label}` shorthand——jq 1.7 能通过，而 CI 用的正是 1.7，只有这个测试能拦住 |
| `test-pq-routes.sh` | 任意传输上的 PQ 线路：`_pq_add_route_for_profile` 创建独立入站并把 `decryption` 切到 `.vless_decryption`、PQ 链接携带 `encryption=mlkem…`、同一配置档的普通线路仍为 `none`、`profile-pq` 的 JSON 契约（缺密钥与重复时拒绝）、base64/v2ray 体丢弃任意传输（不只 xhttp）的 PQ 线路 |
| `test-sni-reachability.sh` | 默认 SNI 的选择：不可达的默认值（或 `sni_list.txt` 首行）被第一个可达候选替换、全部不可达时回退到原默认值（不让探测破坏隔离主机上的部署）、结果按 SNI 缓存；同时覆盖探针判据（完整 TLS 1.3 + 已验证证书 + HTTP 应答）与候选顺序的上限 |

> 静态测试不能替代一次性 VPS 上的实测：创建与删除配置档、校验配置、重启服务、回滚以及真实客户端连接。

## 生命周期与 HAPP endpoint 检查

新部署时请走完整的 `quickstart --email <address>` 路径，确认它在 `8443` 上配置了产品 IP-TLS
endpoint、创建了配置档，并使服务保持健康。这条非交互路径里的迁移调用是 best-effort 的，因此还要
检查迁移标记与最终的配置档/配置。对已有安装，则单独走精简的 `happ-setup` 路径：在一次性环境里删掉
一个或两个订阅标记，确认除非 `8443` 上的产品 IP-TLS endpoint/证书通过验证，否则它会拒绝凭空补写
标记。两个标记都存在时，确认它复用了标记，而不是把「标记存在」当成 endpoint 仍然健康的证据 —— 仍需要
运营者自行核验，或重跑相应的安装路径。

## 线上服务器的手工检查

```bash
sudo xrayebator probe-test                                    # 从 VPS 检查 SNI 可达性
sudo /usr/local/bin/xray run -test -config /usr/local/etc/xray/config.json
sudo systemctl status xray --no-pager -l
sudo systemctl status xrayebator-sub --no-pager -l
curl -sS -i http://127.0.0.1:8080/sub/                        # 预期返回 404
jq -r '.routes[] | [.label,.transport,.port,(.pq_enabled // false)] | @tsv' \
  /usr/local/etc/xray/profiles/<profile>.json
sudo xrayebator channel-test --name <profile>                 # 每条线路跑真实流量
```

`channel-test` 是唯一能证明线路真的承载流量的检查：它按订阅中的每条链接启动本地 Xray 客户端并发出
HTTP 请求，按线路返回 `ok`、`http` 与延迟，PQ 线路也包含在内。请运行两次：Xray 重启后的首次运行要付
连接预热的代价（实机配置档为 ~5.1 秒，第二次 ~150 毫秒），因此单次偏慢不足以判断通道已坏。

本地订阅自检必须在无令牌时返回 `404`，在令牌有效且包含 VLESS 线路时返回 `200`。确认新建的标准
HAPP 配置档是 `schema_version: 3` 且拥有七条存活线路，并且 HAPP 订阅体下发了全部七条：PQ 线路不再
被它过滤掉（面向 v2rayNG/v2rayN 的 base64 体则会丢弃 PQ 线路，因此那里是六条）。被 HAPP 设置复用的
已有配置档可能只满足「七条存活线路」这一下限，所以要检查实际的 label 与 schema —— 迁移不会补齐缺失的
线路。如果 UFW 已经启用，请对比操作前后的 numbered rules：安装会加入固定的产品服务 TCP 列表，且不得
更改默认策略；卸载则只应删除记录为「自己的」规则。

对于可选后端，一次性 VPS 上还应覆盖：`hysteria2-install --grant-all`（服务已启动、UDP 端口在监听、
`server.yaml` 中有对应授权）、`awg-install --grant-all`（模块出现在 `lsmod`、`awg show awg0` 能看到该
peer）、一次 `profile-revoke` 轮换（两个后端的授权同时轮换）、一次过期/恢复循环，以及两个订阅体各含
恰好一行 `hysteria2://`（每个已授权配置档一行）。CI 用 mock 二进制覆盖渲染器、注册表集成与 dispatch
接线；软件包安装本身（网络、DKMS 构建、真实 systemctl）与真实客户端连接按设计属于实机检查。

## 桌面图形界面

GUI（`src/`）在 `tests/` 中有独立的 Vitest 单元测试：

```bash
npm run typecheck     # 检查 TypeScript：main、preload、renderer、shared
npm test              # Vitest 单元测试
```

测试文件：

| 测试 | 检查内容 |
|---|---|
| `tests/unit/subscription.test.ts` | 订阅链接与配置档密钥提取 |
| `tests/unit/probe-ports.test.ts` | Dashboard 状态点使用的可达性探测 |
| `tests/unit/extractJson.test.ts` | 从 `xrayebator` 输出解析 JSON |
| `tests/unit/countryFlag.test.ts` | 服务器卡片的国家旗帜 |
| `tests/unit/vless.test.ts` | `vless://` URL 解析 |
| `tests/unit/shell-command.test.ts` | POSIX 安全的 shell 参数 quoting |
| `tests/unit/ssh-access.test.ts` | SSH 访问参数验证与 keychain 密钥解析顺序 |
| `tests/unit/ssh-client.test.ts` | SSH 连接与 host-key verification |
| `tests/unit/ssh-keychain.test.ts` | 系统钥匙串的私钥保存/读取/删除及大小防护（mock keytar） |
| `tests/unit/server-manager.test.ts` | 更新分支安全性验证 |
| `tests/unit/server-store.test.ts` | 按 host+port 的幂等导入 upsert 与 credential 引用计数；按配置档名缓存的有效期（`profileExpiry`，全量写入——删除的配置档随之从缓存消失） |
| `tests/unit/server-inspector.test.ts` | 诊断规范化：公网与仅本地/不可达订阅、partial 及拒绝导入状态 |
| `tests/unit/deployer.test.ts` | quickstart 参数构建：provided/without email 模式，不使用虚假地址 |
| `tests/unit/ui-contracts.test.ts` | email 模式选择下的部署就绪判断与 payload 构造 |
| `tests/unit/awg-shared.test.ts` | AWG `.conf` 解析、注释剔除、`vpn://` 构建与 qCompress |
| `tests/unit/backend-manager.test.ts` | 后端状态与 AWG 配置解析（hysteria2/awg、3.1 标志） |
| `tests/unit/calendar.test.ts` | 日历：本地 ISO 日期（无 UTC 偏移）、月网格、导航边界 |
| `tests/unit/expire.test.ts` | 有效期徽标状态、服务器时区日期与禁用标志优先级 |
| `tests/unit/traffic.test.ts` | 流量限额辅助函数：输入解析与校验（`500MB`/`1.5GB`/`2TB`/`none`）、用量与限额格式化、标签描述（80% 提醒色与耗尽状态）、限额到输入框的转换 |
| `tests/unit/clipboard.test.ts` | 复制封装：剪贴板接受文本时返回 `true`，写入被拒绝、剪贴板 API 缺失或没有 `navigator` 时返回 `false` 而不是抛错 |
| `tests/unit/dns01.test.ts` | DNS-01 的纯函数（与服务器端一致）：域名校验（拒绝 IP、单标签与带路径的域名）、按提供商的凭据形态校验、就绪判断、certbot 参数组装，以及密钥脱敏 `maskSecret` |
| `tests/unit/i18n-parity.test.ts` | 三种语言（ru/en/zh）的键集合一致、每种语言需要的复数形式齐全、插值占位符与俄语源保持同步 |
| `tests/unit/gui-cache-wiring.test.ts` | 服务器卡片缓存的接线：进入服务器页面时先从本地 store 重读卡片（而不是用启动时读到的旧对象），且有效期由 `profiles:list` 写入 |
| `tests/unit/server-keys-render.test.ts` | 「密钥」页的首帧渲染：配置档有效期在 SSR 下（effect 不执行，数据不可能来自网络）就已在标记里，来自卡片缓存；缓存里没有的配置档不画有效期 |
| `tests/unit/server-settings-render.test.ts` | 「服务器设置」的首帧渲染、分区契约，以及独立「现有配置档」页面的冒烟渲染 |

`npm run typecheck` 还会检查 `tsconfig.contracts.json`，其中编译 `tests/type-contracts/` 中严格的 onboarding 契约（必需的 `emailMode`、keychain 引用密钥选择器、已暴露的 import API）；仅靠 Vitest 转译无法捕获这类类型回归。

说明：`tests/unit/shell-command.test.ts` 有意调用 `/bin/sh`，在没有 POSIX `/bin/sh` 的 Windows
上会失败（`status=null`）。完整 suite 应在 Linux（包括 `release.yml` 的 Ubuntu job）运行；Linux
上全部测试通过。

## CI workflow

三个独立 workflow：

- **ci-linux.yml** — Bash validation：在 ubuntu-24.04 上对所有脚本执行 `bash -n`，并运行全部 42 个
  `validation/test-*.sh`；在 push 到 `main`、`dev`、`experimental` 以及 pull request 时运行。
- **release.yml** — Electron 构建（Windows/macOS/Linux）。只在 `v*` tag 和手动触发时运行；先由
  `preflight` 检查发布说明 `docs/releases/<tag>.en.md` 是否存在，以及仓库密钥 `AP3X0`（若已设置）
  是否真的能创建 release——用随即删除的草稿探测，让意外在几秒内暴露，而不是三次构建之后。
  两项检查都只作警告：release 无论如何都会发布。然后在 Ubuntu 上执行 `npm run typecheck`、
  `npm test`、`npm run build`，再在三种平台执行 `electron-builder --publish never`。若 `preflight`
  确认 `AP3X0` 可用，release 以该 token 所有者名义发布，否则以 `github-actions[bot]` 通过内置
  `GITHUB_TOKEN` 发布：GitHub release 的作者在创建时即固定，事后无法改换。
- **gui-release.yml** — legacy PySide6 GUI：ruff、pytest 和 wheel 构建；在 PR 与 `gui-v*` tag 上运行。