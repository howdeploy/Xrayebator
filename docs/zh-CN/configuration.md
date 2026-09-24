# 配置

[← 返回 README](../../README.zh-CN.md) · [English](../configuration.md) · [Русский](../ru/configuration.md)

章节：[前置条件](#前置条件与已测试系统) · [环境变量](#安装脚本的环境变量) · [防火墙与主机网络设置](#防火墙与主机网络设置) ·
[主菜单](#主菜单) · [命令](#命令) · [桌面图形界面](#桌面图形界面) · [分流路由](#分流路由) ·
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
| `7` | 分流路由：域名直连，绕过 VPN |
| `8` | 级联与上游节点 |
| `9` | 自有域名与 self-steal 挡板 |
| `10` | 部署出站服务器，使本 VPS 成为级联的境外节点 |
| `0` | 退出 |

操作项从 `1` 到 `10` 连续编号；`0` 用于退出程序。

端口和 SNI 是共享入站的设置，修改它们可能影响同一端口上的其他配置档。指纹是配置档/线路级别的客户端参数，修改它不会重启 Xray，也不会影响其他线路。任何修改之后，请在客户端强制刷新订阅，或通过 `3) Подключиться по профилю` 重新获取原始线路。

## 命令

| 命令 | 作用 |
|---|---|
| `sudo xrayebator` | 打开交互菜单 |
| `sudo xrayebator update` | 仅更新 **Xray-core 内核** |
| `sudo xrayebator update <branch>` | 从规范 raw 仓库分支 self-update 管理器，继续使用新脚本，然后更新 Xray-core |
| `sudo xrayebator probe-test` | 更换 SNI 前，从 VPS 检查其可达性 |
| `sudo xrayebator quickstart --email <邮箱>` | 桌面 GUI 使用的一次性部署路径：执行广泛设置/迁移，在 `8443` 配置 IP-TLS endpoint，创建带 `schema_version: 3` 和 7 条线路的标准 HAPP 配置档；输出带 `subscription_url` 的 JSON。非交互迁移是 best-effort，请检查最终配置档与服务 |
| `sudo xrayebator happ-setup` | 已有安装的精简 HAPP 路径：确保订阅服务和可用的多线路配置档；缺少订阅域或端口标记时，会先验证 `8443` 的产品 IP-TLS endpoint，否则失败 |
| `sudo xrayebator profiles` | 以 JSON 数组输出服务器全部配置档（供桌面 GUI「服务器设置」页使用） |
| `sudo xrayebator profile-create --name 名称 [--transport tcp\|tcp-utls\|tcp-xudp\|tcp-mux\|grpc\|xhttp] [--port P] [--count N]` | 非交互式创建单个或多个配置档，打印 `{"ok":true,"names":[...],"errors":[...]}` |
| `sudo xrayebator profile-delete --name 名称` | 非交互式删除配置档，打印 `{"ok":true,"name":"..."}` |
| `sudo xrayebator fp-change --name 名称 [--route R] --fp 指纹` | 修改配置档的指纹，打印 JSON 结果 |
| `sudo xrayebator sni-change --name 名称 [--route R] --sni SNI` | 修改配置档的 SNI，并同步更新同一端口上的所有配置档，打印 JSON 结果 |
| `sudo xrayebator sni-list` | 按类别列出 `sni_list.txt` 中的候选 SNI，打印 JSON 结果（供桌面 GUI 的 SNI 对话框使用） |
| `sudo xrayebator port-change --name 名称 [--route R] --port 端口\|random` | 修改配置档的端口；更新入站、防火墙与订阅。客户端需要重新连接，打印 JSON 结果 |
| `sudo xrayebator bypass list` | 按分组列出当前分流规则（JSON） |
| `sudo xrayebator bypass add --domain D` | 向分流规则添加一个域名（JSON） |
| `sudo xrayebator bypass remove --domain D` | 从分流规则移除一个域名（JSON） |
| `sudo xrayebator bypass reset` | 清空所有自定义分流规则（JSON） |
| `sudo xrayebator bypass bundle [--group a,b,c]` | 应用默认分流分组；不带 `--group` 时重新应用全部分组（JSON） |
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

## 桌面图形界面

活跃的 Electron 桌面应用（`src/`）是通过 SSH 调用 CLI 的前端，不是终端菜单的完整替代品。它从不直接修改
`config.json`；运行时的 Bash 变更使用 `backup_config`、`safe_jq_write` 与 `safe_restart_xray`，而安装与项目更新
有各自的校验和回滚路径。

| 页面 | 用途 |
|---|---|
| Dashboard | 服务器卡片、连通性检查、打开/设置/删除、语言切换 |
| 添加服务器 | 通过 SSH 完整部署，带步骤进度：`os check → upload → install → binary → quickstart` |
| 服务器密钥 | 刷新订阅、复制链接、显示 `vless://` 链接与二维码 |
| 服务器设置 | 使用 SSH 密码或私钥，并选择直接 root 或 sudo：列出/创建/删除配置、`fp-change`、`sni-change`、`port-change`，以及更新/卸载服务器 |

界面语言（Русский / English / 简体中文）在 Dashboard 页眉切换，并保存在 `localStorage` 的
`xrayebator-language` 键中。构建与运行：

```bash
npm install
npm run dev          # Electron + Vite 开发模式
npm run build        # 编译 renderer 与 main process
npm test             # Vitest 单元测试
npm run typecheck    # TypeScript 检查
```

## 分流路由

分流会在 Xray routing 中加入规则，让选定域名经 `freedom` 直连而不走 VPN。
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

## HAPP 客户端路由配置

订阅端点通过响应头 `routing:` 向 HAPP 下发客户端路由配置。托管的默认配置 `xrayebator-default`
设置了 `GlobalProxy: "true"`，因此除私有 IPv4 段之外的所有目标都会走隧道。

这与[分流路由](#分流路由)不是同一个开关。分流路由改变的是**服务端**把请求发往何处；客户端仍然会把它
送进隧道，目标站点看到的依旧是 VPS 的地址。在没有级联的节点上，兜底 outbound 本来就是 `direct`，
所以分流路由无法改变俄罗斯站点看到的结果。只有客户端配置才能让本国流量不进入隧道。

### 覆盖文件

| 变量 | 默认值 | 含义 |
|---|---|---|
| `HAPP_ROUTING_ENABLED` | `true` | 设为 `false` 则不再下发 `routing:` 响应头 |
| `HAPP_ROUTING_JSON_FILE` | `/usr/local/etc/xray/.happ_routing.json` | 运维方的覆盖文件 |

如果覆盖文件存在并通过 HAPP 结构校验，它会对所有订阅者取代托管的默认配置。格式错误的 JSON 会被忽略
并回退到默认配置，而不会下发给客户端。无需重启 `xrayebator-sub.service`：该文件在每次请求时读取。

判定是按目标逐个进行的。`GlobalProxy: "false"` 时默认行为是 `direct`，只有 `ProxySites` 和
`ProxyIp` 走隧道；`GlobalProxy: "true"` 则相反，`DirectSites` 和 `DirectIp` 成为例外。

### 分流示例

本国流量留在运营商网络，被封锁的服务经由 VPS：

```json
{
  "Name": "xrayebator-split",
  "GlobalProxy": "false",
  "RemoteDNSType": "DoH",
  "RemoteDNSDomain": "https://cloudflare-dns.com/dns-query",
  "RemoteDNSIP": "1.1.1.1",
  "DomesticDNSType": "DoU",
  "DomesticDNSDomain": "",
  "DomesticDNSIP": "77.88.8.8",
  "Geoipurl": "https://example.com/geo/geoip.dat",
  "Geositeurl": "https://example.com/geo/geosite.dat",
  "LastUpdated": "1788700000",
  "DnsHosts": { "cloudflare-dns.com": "1.1.1.1" },
  "DirectSites": ["domain:ru", "domain:xn--p1ai"],
  "DirectIp": ["geoip:private", "geoip:ru"],
  "ProxySites": ["domain:google.com", "domain:youtube.com", "domain:instagram.com"],
  "ProxyIp": ["149.154.160.0/20", "91.108.4.0/22", "91.105.192.0/23"],
  "BlockSites": [],
  "BlockIp": [],
  "DomainStrategy": "IPIfNonMatch",
  "FakeDNS": "false"
}
```

三个容易出错的地方：

- **Telegram 按 IP 地址通信，而不是域名。** 域名规则匹配不到它。请从
  <https://core.telegram.org/resources/cidr.txt> 获取网段，不要凭记忆填写：该列表会变化，遗漏一个
  网段会悄悄拖慢媒体下载，而聊天看起来仍然正常。
- **`LastUpdated` 必须递增。** 只有当该值大于已保存的值时，HAPP 才会重新导入配置。
- **geo 数据库必须能被客户端访问。** 托管的默认配置指向 `/sub/<token>/geoip.dat`，该路径与具体订阅者
  绑定。面向全体的覆盖文件无法内嵌某一个订阅者的 token，因此请把数据库放在任何客户端都能下载的位置。

客户端下载新的 geo 数据库期间，先前的配置继续生效，因此下载失败只会保持路由不变，而不会使其损坏。

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
