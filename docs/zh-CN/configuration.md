# 配置

[← 返回 README](../../README.zh-CN.md) · [English](../configuration.md) · [Русский](../ru/configuration.md)

章节：[前置条件](#前置条件与已测试系统) · [环境变量](#安装脚本的环境变量) · [防火墙与主机网络设置](#防火墙与主机网络设置) ·
[级联](#级联与上游节点) ·
[Self-steal](#自有域名与-self-steal-挡板) · [域名与 DNS](#域名与-dns)

---

## 前置条件与已测试系统

安装脚本有以下硬性前置条件：

- root 权限，或能够通过 `sudo` 获取 root 的用户；
- Bash（使用 Bash 运行 `install.sh` 和管理器，不要使用 `sh`）；
- 基于 apt 的 Debian/Ubuntu 类系统，具有 `apt`/`apt-get`；
- 正常运行的 systemd 环境（`systemctl` 和 `/run/systemd/system`）。

支持的系统家族比下面的版本更宽，但当前验证矩阵覆盖：

| 发行版 | 已测试版本 |
|---|---|
| Debian | 12、13 |
| Ubuntu | 22.04、24.04 |

实际部署的基础条件是 KVM 类 VPS、正常 DNS、出站 HTTPS 和可连接的 SSH。没有 systemd 的容器会被安装脚本拒绝，不会被部分配置。

## 安装脚本的环境变量

| 变量 | 取值 | 作用 |
|---|---|---|
| `XRAY_FORCE_IPV4` | `1` | 强制通过 IPv4 下载 Xray 发行版 |
| `XRAY_DOWNLOAD_PROXY` | 代理 URL | 通过 HTTP 或 SOCKS 代理下载内核 |
| `XRAY_LOCAL_ZIP` | 文件路径 | 使用本地内核 ZIP，不再下载 |
| `XRAY_LOCAL_DGST` | 文件路径 | 使用本地 `.dgst` SHA-256 清单 |

当 GitHub Releases 无法访问时：

```bash
XRAY_FORCE_IPV4=1 XRAY_DOWNLOAD_PROXY=socks5h://127.0.0.1:1080 \
  sudo -E bash ./xrayebator-install.sh
```

也可以通过其他渠道先下载官方 ZIP 和 `.dgst`，然后传入本地路径。SHA-256 校验是强制的，无法关闭：

```bash
XRAY_LOCAL_ZIP=/tmp/Xray-linux-64.zip \
XRAY_LOCAL_DGST=/tmp/Xray-linux-64.zip.dgst \
  sudo -E bash ./xrayebator-install.sh
```

## 防火墙与主机网络设置

Xrayebator 不会更改主机的 TCP 拥塞控制算法，也不会写入或应用系统级 `sysctl` 参数。
主机网络设置始终由 VPS 管理员控制。

从旧版本升级到 v3.0 时会执行一次性迁移。它只删除由 Xrayebator 创建且内容完全匹配的旧调优
文件或配置块，并立即把正在使用的 BBR 切换到 `cubic`（若不可用则使用 `reno`）。
迁移不会修改其他 sysctl 文件；如果发现外部配置仍启用 BBR，它会报告该文件并在下次启动时重试。
被删除的项目自有文件会备份到 `/usr/local/etc/xray/backups/`。即使实时切换失败，也不会恢复这些
持久化设置，从而避免服务器重启后再次启用该算法。

安装程序会自行管理 UFW，并在启用前处理 SSH 锁定风险：

1. 从监听 socket 检测活动 SSH 端口，并在可用时检查 `sshd -T` 与 SSH 配置；
2. 确认该端口已经放行，或在启用 UFW 前先放行；
3. 只把 Xrayebator 创建的规则记录在 root-owned 的 `/usr/local/etc/xray/.ufw_owned` 清单中；
4. 如果无法确定或安全放行 SSH 端口，保持非活动 UFW 关闭，而不应用可能锁死 VPS 的 deny 策略。

如果 UFW 已经启用或通过 SSH 安全检查后被启用，安装程序会加入以下项目服务 TCP 端口：
`22, 80, 443, 8443, 2053, 2083, 2087, 8080, 2096, 8880, 9443/tcp`。这不表示 SSH 必须使用 22 端口；请对比安装前后的 numbered rules。Xrayebator 自己创建的规则会在卸载时移除，安装前已存在的规则不受影响。

## 主菜单

| 项 | 作用 |
|---|---|
| `1` | 手工创建配置档：单条线路或一组线路 |
| `2` | 删除配置档及其入站 |
| `3` | 显示配置档的连接信息 |
| `4` | 管理配置档：SNI、指纹、端口、advanced |
| `5` | 将单个配置档升级到 PQ XHTTP |
| `6` | HAPP 订阅：7 条线路的配置档、public TLS、链接、二维码、吊销 |
| `7` | 分流路由（Bypass）：选中域名（银行、电商、Steam 等）直连，不走隧道 |
| `8` | 级联与上游节点 |
| `9` | 自有域名与 self-steal 挡板 |
| `10` | 部署出站服务器，使本 VPS 成为级联的境外节点 |
| `11` | Hysteria 2 后端：安装/状态/客户端链接/卸载（高速 UDP 传输） |
| `12` | AmneziaWG 2.0 后端：安装/状态/客户端配置/卸载（系统级 VPN） |
| `13` | 所有后端的统一状态 |
| `14` | Telegram 通知：配置、测试、启用/停用、监控状态 |
| `0` | 退出 |

操作项从 `1` 到 `14` 连续编号；`0` 用于退出程序。

端口和 SNI 是共享入站的设置，修改它们可能影响同一端口上的其他配置档。指纹是配置档/线路级别的客户端参数，修改它不会重启 Xray，也不会影响其他线路。任何修改之后，请在客户端强制刷新订阅，或通过 `3) Подключиться по профилю` 重新获取原始线路。

## 命令

| 命令 | 作用 |
|---|---|
| `sudo xrayebator` | 打开交互菜单 |
| `sudo xrayebator update` | 仅更新 **Xray-core 内核** |
| `sudo xrayebator update <branch>` | 从规范 raw 仓库分支 self-update 管理器，继续使用新脚本，然后更新 Xray-core；分支写入 `.current_branch` 固定，供后续 GUI 更新使用 |
| `sudo xrayebator probe-test` | 更换 SNI 前，从 VPS 检查其可达性 |
| `sudo xrayebator quickstart --email <邮箱>` | 桌面 GUI 使用的一次性部署路径：执行广泛设置/迁移，在 `8443` 配置 IP-TLS endpoint，创建带 `schema_version: 3` 和 7 条线路的标准 HAPP 配置档；输出带 `subscription_url` 的 JSON。非交互迁移是 best-effort，请检查最终配置档与服务 |
| `sudo xrayebator quickstart --without-email` | 相同的一次性部署路径，但不提供 ACME 联系邮箱；Certbot 使用 `--register-unsafely-without-email`，因此没有续期通知或邮箱恢复。若 Let's Encrypt 无法通过 http-01 验证 IP（validation 主机被服务商在 80 端口上游拦截），部署不会失败而是降级为 `http_tls`：订阅以 HTTP 发布，JSON 携带 `degraded:true`，解除 80 端口封锁后重新部署即恢复 HTTPS |
| `sudo xrayebator inspect --json` | GUI 导入时使用的只读安装检查：返回 Xray、配置档和订阅标记状态；不会安装、迁移或修改配置 |
| `sudo xrayebator happ-setup` | 已有安装的精简 HAPP 路径：确保订阅服务和可用的多线路配置档；缺少订阅域或端口标记时，会先验证 `8443` 的产品 IP-TLS endpoint，否则失败 |
| `quickstart` http_tls 模式 | 若 Let's Encrypt 无法对 IP 执行 http-01 验证（validation 主机报 `Connection reset by peer`——通常是服务商对境外来源过滤 80 端口），部署不失败：订阅保持仅回环访问（完全不存在公共 URL——GUI 通过 SSH 从服务器本机的 `http://127.0.0.1:8080/sub/<token>` 加载密钥），并为后续后端生成自签证书；结果 JSON 携带 `degraded:true`、`tls_mode:"http_tls"` 与 Certbot 原因。服务器以「配置不完整」并带降级标记保存；80 端口上的 ACME challenge location 保持原位——解除封锁后重新运行 quickstart 即签发 LE 证书并把订阅切回 HTTPS |
| `sudo xrayebator profiles` | 以 JSON 数组输出服务器全部配置档（供桌面 GUI「服务器设置」页使用）；有效期同时包含用于服务端执行的 epoch 秒（`expire`）和用于界面显示的服务器本地日历日期（`expire_date`），因此不同时区的客户端也会显示用户选择的日期 |
| `sudo xrayebator profile-create --name 名称 [--transport tcp\|tcp-utls\|tcp-xudp\|tcp-mux\|grpc\|xhttp] [--port P] [--count N] [--expire 日期]` | 非交互式创建单个或多个配置档；`--expire` 接受 `YYYY-MM-DD[ HH:MM]`、epoch 秒或 13 位毫秒。只选日期时，配置档在服务器本地时区的当天 `23:59:59` 之前（含该秒）有效；指定时间时按同一服务器时区执行。过去的有效期会被拒绝；已有名称不会被覆盖——它们会进入 `errors`（GUI 在创建前也会预检名称冲突，因为删除以配置档为单位，名称唯一才能保证删除精确），打印 `{"ok":true,"names":[...],"errors":[...]}` |
| `sudo xrayebator profile-delete --name 名称` | 非交互式删除配置档；被删配置档的后端授权会立即吊销——AWG peer 从 `awg0.conf` 移除，Hysteria 密码从 `server.yaml` 移除（不会残留孤立凭据），名称可立即复用；打印 `{"ok":true,"name":"..."}` |
| `sudo xrayebator profile-revoke --name 名称 [--full]` | 重新签发订阅链接：新的 `sub_token`；带 `--full` 时还会更换该配置档所有 inbound 中的 uuid（已下载的配置立即失效），打印 JSON |
| `sudo xrayebator profile-expire --name 名称 --expire 日期\|epoch\|none` | 设置、延长或取消配置档有效期；只输入日期时，在服务器本地时区的当天 `23:59:59`（含）到期，显式输入的时间按同一时区原样使用；立即生效（已过期会移除客户端，延长则恢复），打印 JSON |
| `sudo xrayebator expire-check` | 批量应用所有已到期的有效期；幂等，无变化时不重启 Xray。由 `xrayebator-expire.timer` 每 10 分钟触发 |
| `sudo xrayebator profile-limit --name 名称 --limit 100GB\|none [--reset]` | 设置配置档的流量限额（`500MB`、`1.5GB`、`2TB`、直接写字节数、`none` 为不限量；大小写不敏感）和/或重置计数器（`--reset`）；打印 JSON |
| `sudo xrayebator traffic-check` | 读取 Stats API 计数器、按配置档累计用量并应用限额（限额耗尽的配置档会被从入站移除）。由 `xrayebator-traffic.timer` 每 5 分钟触发；幂等——无变化时不改动配置 |
| `sudo xrayebator fp-change --name 名称 [--route R] --fp 指纹` | 修改配置档的指纹，打印 JSON 结果 |
| `sudo xrayebator sni-change --name 名称 [--route R] --sni SNI` | 修改配置档的 SNI，并同步更新同一端口上的所有配置档，打印 JSON 结果 |
| `sudo xrayebator sni-list` | 按类别列出 `sni_list.txt` 中的候选 SNI，打印 JSON 结果（供桌面 GUI 的 SNI 对话框使用）。`sni_list.txt` 中第一条非注释行是新配置档的默认 SNI（`www.cloudflare.com`） |
| `sudo xrayebator port-change --name 名称 [--route R] --port 端口\|random` | 修改配置档的端口；更新入站、防火墙与订阅。客户端需要重新连接，打印 JSON 结果 |
| `sudo xrayebator bypass list` | 按分组列出当前分流规则（JSON） |
| `sudo xrayebator bypass add --domain D` | 向分流规则添加一个域名（JSON） |
| `sudo xrayebator bypass remove --domain D` | 从分流规则移除一个域名（JSON） |
| `sudo xrayebator bypass reset` | 清空所有自定义分流规则（JSON） |
| `sudo xrayebator bypass bundle [--group a,b,c]` | 应用默认分流分组；不带 `--group` 时重新应用全部分组（JSON） |
| `sudo xrayebator backend-status` | 以 JSON 输出多协议后端注册表状态（`{"ok":true,"backends":{…}}`） |
| `sudo xrayebator hysteria2-install [--port P] [--grant-all]` | 安装 Hysteria 2 UDP 后端：从 `HyNetworks/hysteria` 官方 release 下载二进制（SHA-256 校验）、专用 `hysteria` 服务账户、独立 systemd 单元（`CAP_NET_BIND_SERVICE`）、QUIC sysctl 缓冲、自适应 TLS（优先复用订阅的 Let's Encrypt 证书并附续期 deploy-hook，否则自签）；UDP 端口默认 443；输出 JSON（已安装时 `already: true`） |
| `sudo xrayebator hysteria2-uninstall` | 移除 Hysteria 2 后端（服务、配置、证书、防火墙规则）；JSON |
| `sudo xrayebator hysteria2-status` | Hysteria 2 后端状态（JSON） |
| `sudo xrayebator hysteria2-grant --name N` | 为配置档签发 Hysteria 2 凭据（存入配置档的 `.backends.hysteria2`）；服务端配置按全部配置档重新生成；JSON |
| `sudo xrayebator hysteria2-subbody --on\|--off` | 两个订阅主体中 `hysteria2://` 行的总开关：标志存于后端注册表，处理器每次请求都会重读，无需重启服务；JSON |
| `sudo xrayebator hysteria2-link --name N` | 以 JSON `{ok, name, link}` 输出持有授权配置档的 `hysteria2://` 链接（命名与 VLESS 路由一致，带国家旗帜） |
| `sudo xrayebator awg-install [--grant-all]` | 安装 AmneziaWG 2.0 系统级 VPN 后端：DKMS 内核模块（首选 `amnezia/ppa` PPA，回退源码编译）、`awg0` 接口与随机高位 UDP 端口、junk 参数与 Amnezia 默认值一致、`ip_forward` + MASQUERADE；JSON |
| `sudo xrayebator awg-uninstall` | 移除 AmneziaWG 后端（接口、配置、symlink、防火墙规则；软件包与模块保留在系统中）；JSON |
| `sudo xrayebator awg-status` | AmneziaWG 后端状态（JSON） |
| `sudo xrayebator awg-grant --name N` | 为配置档签发 peer（密钥对 + 预共享密钥 + `10.8.1.x` 地址，存入 `.backends.awg`）；重新生成 `awg0.conf`；JSON |
| `sudo xrayebator awg-conf --name N` | 输出配置档 peer 的客户端 `.conf`（JSON `{ok, name, conf}`）——全隧道 AllowedIPs、服务端 junk 参数、endpoint；导入 AmneziaWG/AmneziaVPN 客户端 |
| `sudo xrayebator awg-31 --on\|--off` | 切换 AWG 3.1 配置格式（`HeaderProtectionKey`、`RandomTrailers`、`S3`/`S4`）；新安装默认开启 3.1，切换会在原地补齐缺失的服务端参数，警告所有已签发的客户端 `.conf` 必须重新下载（AmneziaVPN ≥ 5.0.1.5），并带回滚地重新生成接口 |
| `sudo xrayebator dns01-setup --domain sub.example.com --provider cloudflare\|route53` | 通过 DNS-01 实现按域名的 HTTPS 订阅：不需要 80 端口，证书由 TXT 记录验证。写入 `0600` 凭据、用带 deploy-hook 的 certbot 签发证书、生成不含 `listen 80` 的 nginx vhost，并把标记切换为 `domain_tls`；打印 JSON |
| `sudo xrayebator dns01-status` | DNS-01 状态：提供商、模式、域名、端口、凭据是否存在、证书剩余天数以及 deploy-hook 是否存在；打印 JSON |
| `sudo xrayebator alerts-setup --token T --chat-id C` | 接入 Telegram 通知：用 `getMe` 校验令牌、发送一条测试消息，并且**只有在投递成功之后**才保存 `alerts.json`（0600）并启用 `xrayebator-monitor.timer`；打印 JSON |
| `sudo xrayebator alerts-status` | 监控状态：配置、定时器、上次检查时间、事件以及最近一次 SNI 探测结果（不显示机器人令牌）；打印 JSON |
| `sudo xrayebator alerts-test` | 向已配置的会话发送测试消息（验证投递）；打印 JSON |
| `sudo xrayebator alerts-enable\|alerts-disable` | 启用或停用投递而不删除配置（不丢失令牌的急停开关）；打印 JSON |
| `sudo xrayebator monitor-check [--force-sni]` | 一次监控迭代——`xrayebator-monitor.timer` 每 15 分钟正是调用它：服务与后端、配置档有效期与限额、订阅存活及其 TLS 模式、服务器重启、每天一次的 SNI 探测（`--force-sni` 为计划外立即执行）；打印 JSON |
| `sudo xrayebator-update [branch]` | 运行完整的 `update.sh` 生命周期更新；无参数时显示 `.current_branch` 并打开交互式分支选择，有参数时使用该分支 |
| `sudo xrayebator-uninstall` | 移除服务与配置 |

这些 update 命令的职责有意不同：

| | `sudo xrayebator update <branch>` | `sudo xrayebator-update [branch]` |
|---|---|---|
| 起点 | 已安装的管理器脚本 | 完整生命周期更新程序 |
| 来源 | 请求分支的 canonical raw 文件 | 所选分支的 `update.sh` workflow |
| 主要结果 | 管理器 self-update，然后更新 Xray-core | 管理器脚本、数据、订阅集成和服务刷新，具体以 workflow 实现为准 |
| 分支选择 | 必须显式提供分支 | 无参数时显示 `.current_branch` 后交互选择；有参数时使用该分支 |

桌面 GUI 的 Server Settings 调用 `xrayebator update <branch>`，不会调用完整的 `xrayebator-update` workflow。

## HAPP 预配路径

`quickstart --email <邮箱>` 是宽泛的迁移路径：执行新部署所需的设置，在 `8443` 配置 IP-TLS 订阅
endpoint 及其证书，然后创建或复用受管理的 HAPP 配置档。新建的标准配置档使用 `schema_version: 3`
和 7 条线路，包括 `xhttp-legacy` 与 `xhttp-pq`。该非交互路径中的迁移调用是 best-effort，部署后
请检查标记、配置档 JSON 与服务状态。

`quickstart --without-email` 执行与带邮箱形式相同的宽泛设置和 endpoint 配置，但以
`--register-unsafely-without-email` 注册 ACME 账户；无法收到 Certbot 续期通知，也没有邮箱恢复。

若 Let's Encrypt 无法对 IP 执行 http-01 验证——部署日志中 challenge 抓取报
`Connection reset by peer`，通常是服务商对境外来源过滤 80 端口——quickstart 不会失败，而是降级为
`http_tls` 模式。订阅处理器保持仅回环访问：**完全不存在公共订阅 URL**——GUI 通过 SSH 从服务器
本机的 `http://127.0.0.1:8080/sub/<token>` 加载密钥；并为后续后端生成自签证书，结果 JSON 携带
`degraded:true`、`tls_mode:"http_tls"` 与 Certbot 原因。服务器以「配置不完整」并带降级标记保存；
80 端口上的 ACME challenge location 保持原位——解除封锁后重新运行 quickstart 即签发 LE 证书并把
订阅切回 HTTPS（该路径幂等）。

`inspect --json` 是 GUI 的只读导入探测：报告本机是否为 Xrayebator 安装、Xray/配置档/服务标记和
已保存的订阅元数据；不运行迁移、不创建配置档、不修改配置、不重启服务、不编辑防火墙规则。

`happ-setup` 是已有安装的精简路径：只运行关键迁移、恢复订阅服务并确保存在多线路配置档；它不能
替代初次 endpoint 配置。若缺少 `.subscription_domain` 或 `.subscription_port`，它会先验证公共
TLS endpoint 再写入标记，拒绝凭空生成。已有标记会被复用而不一定重新验证，因此陈旧的已保存标记
仍需要运维人员核验或重新运行相应的设置路径。

该辅助程序可能复用满足七条活线路最低要求的现有配置档，未必包含全部标准标签或当前 schema。请检查
实际 JSON；迁移不会向现有配置档补建缺失线路。当缺少 `xhttp-legacy`、`xhttp-pq` 或预期的七线路
形态时，请使用菜单或 `quickstart` 重新配置受管理的 HAPP 配置档。

## 订阅格式

一个令牌可以返回四种不同的订阅体：不需要为每个客户端单独建订阅，格式在请求时决定。

| 格式 | 适用客户端 | 如何选择 |
|---|---|---|
| HAPP | HAPP（以及任何未知客户端） | 不带参数，或 `?target=happ` |
| v2ray/base64 | v2rayNG、v2rayN、Shadowrocket | `?target=v2ray`（同义 `base64`），或 User-Agent `v2rayNG`/`v2rayN` |
| Clash/mihomo YAML | mihomo、Clash Verge、Stash、FlClash | `?target=clash`（同义 `mihomo`），或 User-Agent `mihomo`/`clash`/`stash`/`flclash` |
| sing-box JSON | sing-box、Hiddify、NekoBox、Karing | `?target=singbox`（同义 `sing-box`），或这些客户端的 User-Agent |

各订阅体都由配置档的同一批链接生成，因此线路组成与 Reality 参数在所有格式中一致：

- `tcp`、`tcp-utls`、`tcp-xudp` → TCP + `flow: xtls-rprx-vision`（XUDP 还带
  `packet-encoding: xudp`）、`client-fingerprint`、`reality-opts`（public-key/short-id）；
- `tcp-mux` → 不带 flow 的普通 TCP：mux 由客户端发起，服务端不依赖它；
- gRPC → `grpc-opts.grpc-service-name`（Clash）与 `transport.type=grpc`（sing-box）；
- Hysteria 2 —— 后端已安装、配置档持有授权且注册表中 `sub_body` 打开时（auth 字符串完整下发；
  自签证书时带 `skip-cert-verify: true`）；
- `subscription-userinfo`（用量、限额、有效期）在所有格式中都会返回：v2rayNG、HAPP、
  Clash UI（Clash Verge、Mihomo Party）以及 sing-box 客户端（Hiddify、Karing）都能识别它。

这两种格式里没有什么，以及为什么：

- **PQ 线路（VLESS Encryption，`mlkem768x25519plus`）** —— mihomo 与 sing-box 都不支持；线路会被
  跳过，原因作为注释写入 YAML（`# skipped: …`）；
- **xhttp** —— sing-box 根本没有这种传输方式；在 Clash 中需要显式开启 `?xhttp=1`
  （要求 mihomo ≥ 1.19：旧版本遇到未知 `network` 会导致整个配置加载失败，因此默认跳过该线路）。

```bash
# 配置档订阅 URL 的全部格式——令牌是同一个
sudo xrayebator profiles | jq -r '.[] | [.name, .subscription_url, .subscription_url_clash, .subscription_url_singbox] | @tsv'
curl -s "$(sudo xrayebator profiles | jq -r '.[0].subscription_url_clash')" | head -20
```

如果没有显式指定格式且 User-Agent 未知，响应仍然是 HAPP 订阅体：已经发给客户端的链接行为不变。
现有安装通过迁移 `subhttp_formats_2026` 获得新格式，它在首次进入菜单时重新生成订阅处理器。

## 桌面图形界面

活跃的 Electron 桌面应用（`src/`）是通过 SSH 调用 CLI 的前端，不是终端菜单的完整替代品。它从不直接修改
`config.json`；运行时的 Bash 变更使用 `backup_config`、`safe_jq_write` 与 `safe_restart_xray`，而安装与项目更新
有各自的校验和回滚路径。

| 页面 | 用途 |
|---|---|
| Dashboard | 服务器卡片、连通性检查、打开/设置/删除、语言切换 |
| 添加服务器 | 通过 SSH 完整部署，带步骤进度：`os check → upload → install → binary → quickstart` |
| 服务器密钥 | 刷新订阅、复制链接、显示 `vless://` 链接与二维码；多协议后端密钥（Hysteria 2 链接、AmneziaWG 客户端配置，文本+二维码） |
| 服务器设置 | 使用 SSH 密码或私钥，并选择直接 root 或 sudo：列出/创建/删除配置、`fp-change`、`sni-change`、`port-change`，多协议后端面板（安装/卸载、按配置档密钥、订阅开关、AWG 3.1 切换），以及更新/卸载服务器 |

界面语言（Русский / English / 简体中文）在 Dashboard 页眉切换，并保存在 `localStorage` 的
`xrayebator-language` 键中。构建与运行：

```bash
npm install
npm run dev          # Electron + Vite 开发模式
npm run build        # 编译 renderer 与 main process
npm test             # Vitest 单元测试
npm run typecheck    # TypeScript 检查
```

## 分流路由（Bypass）

分流路由让选中的域名绕过隧道：匹配的流量直连（direct），其余流量继续走 VPN。
`domain -> direct` 规则位于兜底规则之上，因此在启用级联时仍然生效。

默认组合包中的分组：

| 分组 | 内容 |
|---|---|
| `steam` | Steam：CDN、聊天、社区 |
| `banks` | 俄罗斯银行与支付 |
| `marketplaces` | 俄罗斯电商与零售 |
| `streaming` | 俄罗斯流媒体与媒体 |
| `yandex` | Yandex 生态 |
| `vk` | VKontakte |
| `mailru` | VK Group 与 Mail.ru |

菜单是交互式的：方向键移动光标，空格切换分组，回车应用。

## 多协议后端

除 Xray Reality 外，同一台 VPS 还可以运行由同一 CLI/菜单管理的其他传输。所有后端状态位于
中性根目录（不触碰 `/usr/local/etc/xray/`）：

```text
/usr/local/etc/xrayebator/
├── backends.json                 # 注册表：各后端的 installed/version/port/开关（644，无机密）
└── backends/
    ├── hysteria2/                # server.yaml、证书、占位凭据
    └── awg/                      # awg0.conf、server-params.json（0600）
```

每个配置档的后端凭据保存在配置档 JSON 自身（`.backends.hysteria2`、`.backends.awg`）——配置档
是唯一事实来源，后端服务端配置始终由配置档重新生成。配置档生命周期事件（创建/删除/吊销/过期/
恢复）会自动传播到每个已安装的后端：吊销会轮换 Hysteria 密码与 AWG peer 密钥；过期会从两个
服务端配置中移除授权；续期则恢复两者。

### Hysteria 2（高速 UDP）

`hysteria2-install` 从官方 `HyNetworks/hysteria` release 下载二进制（SHA-256 校验），创建
`hysteria` 服务账户与独立 systemd 单元，默认监听 UDP 443（与 TCP 443 的 Reality 入站并存）。
TLS 自适应：订阅 endpoint 已有 Let's Encrypt 证书时直接复用（客户端 `insecure=0`），否则生成
自签证书（`insecure=1`）。尚无配置档授权时，auth 映射携带 `_xrayebator_placeholder` 用户——
Hysteria 拒绝空的 userpass 映射。客户端链接形如
`hysteria2://user:pass@host:port/?sni=…&insecure=0|1#name`，会追加到两个订阅主体（HAPP 与通用）；
注册表标志 `sub_body` 是客户端解析器出问题时的总开关。

### AmneziaWG 2.0（系统级 VPN）

`awg-install` 通过 DKMS 编译内核模块（首选 `amnezia/ppa` PPA；回退为源码编译，内核 ≥ 5.6 需要
完整 `linux-source`），并通过 `awg-quick@awg0` 拉起 `awg0` 接口：随机高位 UDP 端口、网段
`10.8.1.0/24`、`ip_forward` 与默认路由接口上的 MASQUERADE。junk 参数与 Amnezia 默认值一致——
这是所有官方 AmneziaVPN 客户端（手机与桌面）都能可靠应用的方言：`Jc` 5、`Jmin` 10、`Jmax` 50、
`H1`–`H4` = 1..4（WireGuard 魔数）、`S1`/`S2` 随机 12..150、`S3`/`S4` 随机 12..64
（均互不相同，`S1+56 ≠ S2`）。每个配置档 peer 获得密钥对、预共享密钥与首个空闲地址；客户端 `.conf`（菜单项 12 或
`awg-conf --name N`）携带全隧道 `AllowedIPs` 与服务端 junk 参数，开头带有自述性头部：该配置档
通过 AmneziaVPN/AmneziaWG 运行，而非 V2Ray 客户端（HAPP）。桌面 GUI 中，相同的密钥通过
Server Settings 的「密钥」按钮按配置档交付：Hysteria 2 链接与 AWG `.conf` 以文本+二维码呈现，
并支持一键签发授权。「QR · AmneziaVPN」二维码以应用原生 `vpn://` 形态携带配置（`amnezia-awg2`
容器、容器级服务器 junk 字段、`protocol_version`、压缩 payload）——直接把裸 `.conf` 粘进
AmneziaVPN 无法完整到达其隧道，因此该应用推荐使用此码；普通二维码保留给独立版 AmneziaWG
客户端。peer 变更会带回滚地重启接口
——所有 peer 的隧道会短暂中断；授权与吊销是低频操作，第一阶段可接受。

### AWG 2.0 与 3.x 的差异——以及 3.1 为何对 DPI/ТСПУ 更重要

按上游协议的划分，AmneziaWG 参数分为两组：

| 服务端与客户端必须逐字节一致 | 各端本地设置 |
|---|---|
| `S1`–`S4`、`H1`–`H4` | `PersistentKeepalive`（建议 22–30） |
| 3.0：`HeaderProtectionKey` | 3.0：`ContentPaddingAddition`、`Rekey*`、`Reject*`、`Keepalive*`、`MaxHandshakeAttempts`（整数或 `"a-b"` 区间） |
| 3.1：`RandomTrailers` | 3.1：`DisableCookies` |

Xrayebator 实现了 AWG 3.1 特性集：junk 参数加 `S1`–`S4`（≥ 12）、随机生成的 `HeaderProtectionKey`
（服务器与每个客户端 `.conf` 共享），以及 `RandomTrailers = on`。`DisableCookies` 可用但默认关闭
（代价是失去内建的防放大防御）。新安装直接获得 3.1；3.1 阶段之前的安装可通过菜单项 12 →
「Режим AWG 3.1」或 `awg-31 --on|--off` 补齐缺失密钥、切换配置格式并重新生成接口。迁移警示依然
成立：3.1 键位于「必须一致」组，切换后**所有先前发出的客户端 `.conf` 必须重新下载**，且客户端
需要 AmneziaVPN ≥ 5.0.1.5——旧版本会直接拒绝导入。用 `awg show` 验证：没有 `latest handshake`
说明「必须一致」组不一致；有握手无流量则去查 `awg-quick`/路由/防火墙。

### HAPP 客户端路由配置

订阅端点通过响应头 `routing:` 向 HAPP 下发客户端路由配置。托管的默认配置 `xrayebator-default`
设置了 `GlobalProxy: "true"`，因此除私有 IPv4 段之外的所有目标都会走隧道。

这与[分流路由](#分流路由)不是同一个开关。分流路由改变的是**服务端**把请求发往何处；客户端仍然会把它
送进隧道，目标站点看到的依旧是 VPS 的地址。在没有级联的节点上，兜底 outbound 本来就是 `direct`，
所以分流路由无法改变俄罗斯站点看到的结果。只有客户端配置才能让本国流量不进入隧道。

配置通过响应头下发给客户端，因此较大的 `DirectSites` 列表可能超出 nginx 默认的 4k 代理缓冲区。生成的订阅
nginx 配置已调高该值（`proxy_buffer_size 32k`），域名模式的 `location /sub/` 与 IP 模式（quickstart，
`location /`）均已覆盖；如果订阅前面还有你自己的反向代理，也需要在那里
调高 `proxy_buffer_size`，否则 nginx 会返回 502 并在日志中记录 `upstream sent too big header`。

### 从菜单生成

`HAPP 订阅 → 7) 客户端路由` 会写入一份现成的分流配置，其内容取自服务端分流路由使用的同一批域名集合。
`GlobalProxy` 保持为 `"true"`，未知目标仍走隧道，而俄罗斯相关集合与 `geoip:ru` 会移入 `DirectSites`
和 `DirectIp`。原有的覆盖文件会备份在同一目录，删除覆盖文件即可恢复托管的默认配置。配置使用占位符
（`{{GEOIP_URL}}`、`{{GEOSITE_URL}}`、`{{LAST_UPDATED}}`），在请求时按订阅者解析——共享文件中
不包含任何 token。

### 覆盖文件

| 变量 | 默认值 | 含义 |
|---|---|---|
| `HAPP_ROUTING_ENABLED` | `true` | 设为 `false` 则不再下发 `routing:` 响应头 |
| `HAPP_ROUTING_JSON_FILE` | `/usr/local/etc/xray/.happ_routing.json` | 运维方的覆盖文件 |

如果覆盖文件存在并通过 HAPP 结构校验，它会对所有订阅者取代托管的默认配置。格式错误的 JSON 会被忽略
并回退到默认配置，而不会下发给客户端。无需重启 `xrayebator-sub.service`：该文件在每次请求时读取。

判定是按目标逐个进行的。`GlobalProxy: "false"` 时默认行为是 `direct`，只有 `ProxySites` 和
`ProxyIp` 走隧道；`GlobalProxy: "true"` 则相反，`DirectSites` 和 `DirectIp` 成为例外。

### 占位符

覆盖文件在每次请求时读取，因此可以把三个值交给服务端填充：

| 占位符 | 替换为 |
|---|---|
| `{{GEOIP_URL}}` | 当前订阅者的 `<基础地址>/sub/<token>/geoip.dat` |
| `{{GEOSITE_URL}}` | 当前订阅者的 `<基础地址>/sub/<token>/geosite.dat` |
| `{{LAST_UPDATED}}` | `xrayebator` 与两个 geo 数据库中最新的修改时间 |

替换在结构校验之前进行，因此未被解析的占位符会无法通过 `https://` 校验，客户端将收到托管的默认配置，
而不是一份损坏的配置。`{{LAST_UPDATED}}` 还省去了修改 geo 数据库后手动递增该值的麻烦。

三个容易出错的地方：

- **Telegram 按 IP 地址通信，而不是域名。** 域名规则匹配不到它。请从
  <https://core.telegram.org/resources/cidr.txt> 获取网段，不要凭记忆填写：该列表会变化，遗漏一个
  网段会悄悄拖慢媒体下载，而聊天看起来仍然正常。
- **`LastUpdated` 必须递增。** 只有当该值大于已保存的值时，HAPP 才会重新导入配置。
- **geo 数据库必须能被客户端访问。** 托管的默认配置指向 `/sub/<token>/geoip.dat`，该路径与具体订阅者
  绑定。上面的占位符解决了这个问题；否则请把数据库放在任何客户端都能下载的位置。
- **数据库 URL 里的国家可能标错。** 各家的 ASN 地理标注并不一致：ipinfo.io 与 ipwho.is/ip-api 会把
  同一网段划到不同国家（例如 NODE HOST LIMITED：芬兰 vs 德国/法兰克福）。托管的 HAPP 配置让客户端
  通过同一订阅的 `{{GEOIP_URL}}`/`{{GEOSITE_URL}}` 下载 geo 数据库，因此在 http_tls 回退（公共订阅
  不可用）时，没有预载数据库的客户端无法下载，HAPP 会显示「无数据」。解决方法：手工修正
  `/usr/local/etc/xray/.server_country`（`代码|国家|城市`）并通过 SSH 导入密钥，或恢复公共订阅。

客户端下载新的 geo 数据库期间，先前的配置继续生效，因此下载失败只会保持路由不变，而不会使其损坏。

### 一个密钥——多少台设备？

VLESS、Hysteria 2 与 AmneziaWG 的多设备语义不同：

- **VLESS（订阅）**——订阅发放配置档的 UUID，而 UUID 并非独占：任意数量的设备都可以在 HAPP 中
  拉取同一订阅并同时连接，各自按线路建立自己的 Reality 隧道。线路是传输方式，不是设备槽位。
- **Hysteria 2**——按连接认证（`userpass`），服务器不会把凭据锁定到单一会话：**一条
  `hysteria2://` 链接可供不限数量的设备同时使用**，每台设备拥有独立的 QUIC 会话。它们只共享
  服务器带宽。
- **AmneziaWG**——cryptokey 路由将 peer 绑定到其密钥对，接口上每个 peer 只保留一个 endpoint
  （最后认证者胜出）。**一个密钥 = 一台设备才可靠。** 两台设备用同一 `.conf` 会争抢 endpoint
  并轮流重连；同一 NAT 后勉强能用，跨网络会散架。第二台设备需要自己的配置档/密钥——它会得到
  自己的 peer 与 `10.8.1.x` 地址。
- **nginx** 只在 8443 上服务订阅端点（密钥交付）。Hysteria（UDP 443）与 AmneziaWG（各自 UDP
  端口）完全绕过 nginx，后端之间也没有任何负载均衡——它们是独立端口上的独立服务；每台设备只是
  向所用协议添加自己的会话。

## 配置档流量统计与限额

Xray 按客户端统计流量（客户端的 `email` = 配置档名称），而管理器把计数器转换为按配置档的用量：

- 全新安装时，`install.sh` 会向 `config.json` 加入 `127.0.0.1:10085` 上的 `dokodemo-door` api 入站、
  `policy.system.statsInboundUplink/Downlink`、级别 `0` 的 `statsUserUplink/Downlink` 以及第一条
  `api → api` 路由规则，因此安装完成后统计立即生效。级别标志是必需的：Xray 只依据它们注册
  `user>>>名称>>>traffic>>>uplink` 计数器（`policy.system.statsInbound*` 给出的是入站统计，而不是
  按用户的统计），在旧配置上由迁移 `traffic_stats_2026` 在首次进入菜单时补齐。已经执行过该迁移早期
  版本的服务器（其标记已存在，而标志并未写入）由单独的幂等迁移 `traffic_user_stats_2026` 修复——
  它在下次进入菜单时运行；
- `xrayebator-traffic.timer` 每 5 分钟执行 `xrayebator traffic-check`：读取 Stats API 计数器
  （`xray api statsquery`），扣除上一次快照（`.traffic.last`）后把用量累加进配置档（`.traffic.used`）
  ——重启 Xray 不会「吞掉」已经计入的流量；
- 限额存放在配置档中（`.traffic.limit`，字节），`none` 表示不限量。限额耗尽时客户端会被从入站移除
  （快照保存在 `.traffic_clients`），配置档获得 `.traffic_disabled: true`，订阅返回 `410 Gone`。
  提高或取消限额会恢复同一个客户端，因此设备无需重新导入订阅；
- 订阅中的 `subscription-userinfo` 返回真实的 `download`（累计用量）与 `total`（限额），
  因此支持 userinfo 的客户端会自行显示剩余量；
- 统计的是配置档 Xray 线路的流量：Hysteria 2 与 AmneziaWG 各自单独统计（或不统计）自己的流量，
  不计入配置档限额——带 Hysteria 2 授权的配置档在客户端走 UDP 后端时可能超出限额；
- 有效期（`expire`）与流量限额相互独立：只要另一项限制仍然生效，取消其中一项就不会恢复客户端。

```bash
sudo xrayebator profile-limit --name 名称 --limit 1.5GB   # 设置限额
sudo xrayebator profile-limit --name 名称 --reset         # 重置计数器
sudo xrayebator profile-limit --name 名称 --limit none    # 取消限额
sudo xrayebator profiles | jq '.[] | {name, traffic_used, traffic_limit, traffic_disabled}'
```

GUI 的配置档卡片上会显示「已用 / 限额」标签（达到 80% 变黄，耗尽变红），「限额」对话框可设置预设值、
自定义数值、重置计数器以及取消限额。限额管理只在统计真正启用的地方显示：`profiles` 仅当 api 入站与
级别 `0` 的 user-level 标志都存在时才返回 `traffic_supported: true`，否则（旧服务器，或在更新后
迁移尚未执行的服务器上）GUI 会如实隐藏该能力。

## 监控与 Telegram 告警

监控是可选的附加层：`xrayebator-monitor.timer` 每 15 分钟执行 `xrayebator monitor-check`，
只在状态发生变化时写入 Telegram（同一事件的重复提醒每天最多一次，恢复则单独发一条消息）。

| 监控对象 | 事件 |
|---|---|
| `xray.service`、`xrayebator-sub.service` 与 `nginx.service`（若已启用） | 服务未运行 / 已恢复运行 |
| Hysteria 2（`hysteria-server.service`）与 AWG 接口（`awg show awg0`） | 只针对已安装的后端（依据注册表） |
| 配置档有效期 | 未来 3 天内到期；已因到期被停用 |
| 流量限额 | 因限额耗尽而被停用的配置档 |
| 订阅 | 回环处理器无响应（`:8080/sub/<token>`）；模式降级为 `http_tls`/`local_only` —— Let's Encrypt 未能验证 http-01，订阅没有 HTTPS |
| SNI | 每天一次对配置档实际使用的 SNI 执行 `probe-test`：完全或部分不可达 |
| 服务器重启 | 基于 `boot_id` 的边沿触发：重启后发送消息（若上一条未投递则重发） |

配置可通过菜单（`14`）或 CLI 完成。机器人令牌由 `@BotFather` 发放，`chat_id` 来自 `@userinfobot`
（群组的 chat_id 为负数）：

```bash
sudo xrayebator alerts-setup --token 123456:AA... --chat-id -1001234567890
sudo xrayebator alerts-status                # 定时器、上次检查、事件、SNI
sudo xrayebator alerts-test                  # 测试消息
sudo xrayebator alerts-disable               # 暂停而不丢失配置
sudo xrayebator monitor-check --force-sni    # 立即执行一次检查与 SNI 探测
```

相关文件：`/usr/local/etc/xrayebator/alerts.json`（0600 —— 机器人令牌与 chat_id）和
`monitor-state.json`（去重状态：事件、`boot_id`、最近一次 SNI 探测结果）。令牌从不会打印到 CLI
stdout。如果 Telegram 不可达，事件状态不会被记录——发送会在下一个周期重试，而 SNI 探测不会随之
重跑（其结果已保存在状态中）。阈值由单元的环境变量配置：`ALERTS_REMIND_SEC`（提醒间隔，86400）、
`ALERTS_EXPIRE_WARN_SEC`（「即将到期」时间范围，259200）、`ALERTS_SNI_INTERVAL_SEC`（86400）、
`ALERTS_SNI_TIMEOUT`（单个 SNI 8 秒）。

## DNS-01：无需 80 端口的证书与订阅域名

常规订阅模式（`ip_tls`、`domain_tls`）通过 http-01 获取 Let's Encrypt 证书，也就是需要一个对外
可达的 80 端口。部分服务商会过滤该端口——此时订阅会降级为 `http_tls`（没有证书的 HTTP）。DNS-01
通过 TXT 记录验证域名归属，因此完全不需要 80 端口，订阅运行在自己的域名上：
`https://sub.example.com/sub/<token>`。

```bash
# Cloudflare：具有该区域 DNS:Edit 权限的 API token
sudo xrayebator dns01-setup --domain sub.example.com --provider cloudflare \
  --token CF_API_TOKEN --email admin@example.com

# Route53：具有 Route53:ChangeResourceRecordSets 权限的密钥
sudo xrayebator dns01-setup --domain sub.example.com --provider route53 \
  --aws-access-key-id AKIA... --aws-secret-access-key ... --without-email

sudo xrayebator dns01-status   # 提供商、域名、端口、证书有效期、deploy-hook
```

该命令做了什么：

1. 安装 `certbot` 与该提供商的插件（`python3-certbot-dns-cloudflare` 或
   `python3-certbot-dns-route53`）；
2. 写入 `0600` root 的凭据文件——`/etc/letsencrypt/xrayebator-dns01-cloudflare.ini`
   （`dns_cloudflare_api_token = …`）或 `xrayebator-dns01-aws.ini`（`[default]` 配置节，
   通过 `AWS_SHARED_CREDENTIALS_FILE` 传给 certbot）；
3. 以 `certbot certonly --dns-cloudflare|--dns-route53 -d <域名>` 签发证书，并带
   `--deploy-hook "systemctl reload nginx"`（续期由标准的 `certbot.timer` 完成，证书重新签发不会
   中断订阅）；
4. 写入**只含 TLS server 的 nginx vhost**（既没有 `listen 80`，也没有 ACME location——该模式下
   它们并不需要），在 UFW 中只开放订阅的公共端口（默认 `443`）；
5. 把订阅标记切换为 `domain_tls`，因此 `_subscription_base_url` 与 GUI 都会返回 `https://<域名>`。

要求与注意事项：

- 域名必须已委派，且其 A/AAAA 记录指向本 VPS（不执行 DNS 检查：split-DNS 与被代理的区域会产生
  误判）；
- 不提供邮箱时，证书以 `--register-unsafely-without-email` 签发——无法收到续期通知，也无法通过
  邮箱恢复账户（与 `quickstart` 相同）；
- 凭据文件由 `xrayebator-uninstall` 删除；证书则依据 root 拥有的 `.certbot_owned` 清单处理，不会
  触碰他人的域名；
- 切换到 DNS-01 不会使已签发的链接失效：改变的只是订阅的基础 URL。

## 级联与上游节点

级联是服务端的出站与路由模式，而不是新的客户端配置档。客户端仍然连接当前 VPS：

```text
客户端 → 当前 VPS → 境外 VLESS Reality 上游 → 互联网
```

菜单第 `8` 项把参数保存到 `/usr/local/etc/xray/upstreams/cascade.json`，
添加 `cascade-upstream` 出站，并且只切换 `network=tcp,udp` 这条兜底规则。

支持两种上游类型：VLESS Reality over TCP（含 Vision 与 XUDP）以及 XHTTP。
菜单可以直接接受现成的 `vless://` 链接并自动迁移与传输相关的参数；手工输入时需要
`address`、`port`、`uuid`、`publicKey`、`shortId`、SNI 和指纹。
如果级联已经启用，更换上游会重建出站与路由并重启 Xray，无需先关闭再开启。

关闭级联会移除 `cascade-upstream` 出站，并把兜底规则改回 `direct`。
运行时的配置改动经过 `backup_config`、`safe_jq_write` 与 `safe_restart_xray`；安装程序与项目更新有各自的校验、重启和回滚路径。

第 `10` 项配置的是另一侧：把当前 VPS 变成境外节点，供另一台服务器的级联连入。

## 自有域名与 self-steal 挡板

Self-steal 会在 `127.0.0.1:9444` 部署带有效证书的 nginx，Reality 入站则获得
`serverNames=[domain]` 与 `dest=127.0.0.1:9444`。对 XHTTP 还会同步更新 `xhttpSettings.host`。

需要一个 A 或 AAAA 记录指向该 VPS 的域名，以及用于 Let's Encrypt 的邮箱。菜单会安装
`nginx` 和 `certbot`，把站点配置写入 `/etc/nginx/sites-available/xrayebator-selfsteal`，
启用并重载 nginx，在 UFW 处于启用状态时开放并限流 `80/tcp`，再通过 webroot challenge 签发证书。

可用模板：`Simple web template`、`SNI template`、`Nothing SNI template`。

如果 `443` 上没有入站，Xrayebator 会创建一个只用于回落、没有客户端的 Reality 入站
`inbound-443` —— 否则外部对 `https://domain/` 的 TLS 探测无法经 Xray 回落到挡板。

## 域名与 DNS

域名模式需要为 VPS 的 IPv4 创建 `A` 记录。只有在 IPv6 确实配置好且可达时才添加 `AAAA`。

如果域名托管在 Cloudflare，测试阶段用 `DNS only` 比 `Proxied` 更可靠：
certbot 需要通过 80 端口的 HTTP challenge 访问 VPS。

如果 `443` 已被 Xray 或其他服务占用，订阅会转到 `8443`，链接中会带上端口：
`https://domain:8443/sub/<token>`。
