# 通过俄罗斯 VPS 部署私有级联

[← 返回 README](../../README.zh-CN.md) · [English](../private-cascade.md) · [Русский](../ru/private-cascade.md)

## 拓扑

使用两台 VPS。私有客户端连接俄罗斯入口。入口对 TCP 和支持的应用 UDP 使用相同的有序策略。选定的俄罗斯目标从俄罗斯出站，被封锁及未匹配的目标通过 VLESS REALITY 转发到境外出口。

| VPS | 作用 | 地址要求 |
|---|---|---|
| 俄罗斯入口，例如位于莫斯科 | 接收客户端连接，并将明确选定的流量从俄罗斯发出 | 客户端可达的公网地址，以及连接境外 VPS 时稳定且已知的源地址 |
| 境外出口 | 接收俄罗斯 VPS 的级联连接，并将转发流量送往互联网 | 俄罗斯 VPS 可达的公网监听地址，以及访问客户端所需目标的出站能力 |

每台 VPS 一个公网 IPv4 即可实现这些角色。境外监听和互联网出口可以共用地址。文章的完整方案通过另一个地址、网关或 WARP 分离境外监听和最终出口。文章对俄罗斯目标明确允许例外，直连时这些目标会看到入口的公网 IP。文章对地址发现和封锁机制的解释属于作者的假设。[Habr 文章第 4 节](https://habr.com/ru/articles/1103460/)

## 修改 VPS 前

1. 确认两家服务商允许所需的代理用途。记录实际公网地址、出口在服务商 NAT 后看到的源地址、端口和应急控制台访问方式。独立核对 SSH 主机密钥。使用 [VPS 建议](recommendations.md) 中支持的操作系统。
2. 确认客户端网络能通过 IPv4 连接俄罗斯监听。服务器间可使用限制源地址的 IPv4，或已验证路由、监听和防火墙的 IPv6。无论服务器间使用哪个地址族，都要确认境外 VPS 能访问客户端所需的 IPv4 目标。
3. 记录现有 Xray 路由、配置档、后端、监听、服务商防火墙和主机防火墙。保存受保护的备份或快照，并保留独立管理会话。若准备过程需要重启已有服务或修改活动监听，请安排维护窗口。
4. 为境外 VPS 预留独立 TCP 监听。在服务商防火墙上，仅允许俄罗斯 VPS 的实际出站源 IP 访问该端口，IPv4 使用 `/32`，IPv6 使用 `/128`。主机防火墙设置同等限制，并检查包括 Xrayebator 所建规则在内的更宽泛许可。保留 SSH、订阅和现有客户端监听规则。先设置服务商限制，再创建境外入站，因为管理器可能在 UFW 中开放监听端口。
5. 每台主机分别保管 SSH、REALITY 密钥对和证书私钥。服务器间连接使用专用 VLESS 凭据。客户端仅获得入口配置档，上游链接或 UUID 只存于需要它的两台主机。DNS 凭据仅供 root 读取，权限按用途缩小。日志和交接材料中隐藏链接和令牌。

新 VPS 上先在两台主机安装 Xrayebator。此例在入口使用 Xray 和基于 Python 3 标准库的 UDP 辅助程序。若主机已有可选 VPN 后端，创建配置档后检查其授权，因为 Xrayebator 会向已安装后端传递配置档生命周期事件。[安装](../../README.zh-CN.md)

以下目标限制要求两端使用 Xray-core 26.6.27 或更新版本。在两台主机取得相同的已审核源码版本，包含 `profile-create --without-pq`、`private-cascade` 和 `libexec/private_cascade_udp.py`。独立辅助程序和单元按下文手动安装。如果已安装管理器较旧，从此源码目录运行命令，并将 `sudo xrayebator` 替换为 `sudo bash ./xrayebator`。更新时使用相互匹配的辅助程序和生成配置。

在两台主机的空闲目录获取已审核的 tag 或提交。执行前替换引用值。

```bash
CASCADE_REVIEWED_REF='replace-with-reviewed-tag-or-commit'
git clone --no-checkout https://github.com/howdeploy/Xrayebator.git xrayebator-cascade-src
cd xrayebator-cascade-src
git fetch --depth 1 origin "$CASCADE_REVIEWED_REF"
git checkout --detach FETCH_HEAD
```

## 主机名、证书和 REALITY

- 优先使用已受你控制的域名，分别设置 `ingress.example.com` 和 `egress.example.com` 等名称。`A` 记录指向各自公网 IPv4。验证 IPv6 可达性和防火墙范围后再发布 `AAAA`。DNS 提供商支持代理时使用 DNS-only。服务商默认主机名需要具备必要的 DNS 控制权，并能签发和续期匹配证书。
- 使用标准 REALITY 伪装站点时，保留 Xrayebator 已配置且可用的目标与 SNI，通过 IP 连接 VPS。
- 级联拨号地址可以是可达 IP 或主机名。IP 证书可用于订阅 HTTPS。使用 self-steal 时，REALITY SNI 应匹配回环 TLS 目标证书中的主机名，XHTTP 的 `host` 也使用该名称。[域名与 DNS](configuration.md#域名与-dns) · [Self-steal](configuration.md#自有域名与-self-steal-挡板)
- 关闭公网 80 端口的 self-steal 使用 DNS 提供商的 ACME 插件，仅签发证书。配置回环 TLS 站点并添加续期后重载 TLS 服务的 deploy hook，检查监听实际提供的匹配证书。内置 `dns01-setup` 为 Cloudflare 或 Route 53 配置订阅监听。如需发布该订阅再使用它，秘密通过文件或 stdin 传入。[DNS-01](configuration.md)

## 准备境外出口

在境外 VPS 上运行 `sudo xrayebator profile-create --name private-cascade-egress --transport xhttp --without-pq --port 25443`，创建专用旧式 XHTTP 配置档。确认 `names` 包含该配置档且 `errors` 为空。私下从配置档菜单导出 XHTTP URI，保留实际 `path`、`host` 和 `mode`。IPv6 拨号地址用方括号包围。

```text
vless://<uuid>@<egress-address>:<port>?encryption=none&security=reality&type=xhttp&sni=<sni>&fp=<fingerprint>&pbk=<public-key>&sid=<short-id>&host=<host>&path=<url-encoded-path>&mode=<mode>
```

也支持 TCP Vision。在空闲的非 443 端口上使用 `--transport tcp`，省略 `--without-pq`，并保留导出 URI 中的 `flow=xtls-rprx-vision`。此 flow 会拒绝向境外线路的 443 端口开启 UDP 会话。HTTP/3 不可用时，浏览器可以通过 TCP 重试 HTTPS。上述 XHTTP 示例支持应用 UDP/443。

从入口和允许列表外的地址分别验证监听许可与拒绝情况。确认境外节点可以出站到互联网。[标准级联](configuration.md#级联与上游节点)

境外 VPS 独立解析转发的目标名称。出口限制为公网 IPv4，并对每个 UDP 数据报执行限制。先保存受保护的配置备份，再向 `outbounds` 末尾添加以下专用出站。两个 IPv4 策略字段兼容支持的内核版本。若服务商元数据地址不在私有地址集合中，也应加入禁止列表。

```json
{
  "tag": "private-cascade-exit",
  "protocol": "freedom",
  "settings": {
    "domainStrategy": "ForceIPv4",
    "finalRules": [{"action": "block", "ip": ["geoip:private", "::/0"]}]
  },
  "streamSettings": {"sockopt": {"domainStrategy": "ForceIPv4"}}
}
```

这些限制适用于客户端目标。两台 VPS 之间仍可通过 IPv6 连接。

在境外节点的 `routing.rules` 中，将下列规则放在现有禁止规则之后、首个能匹配级联入站的普通转发规则之前，包括 TCP/UDP 兜底规则。若使用其他端口或配置档，以实际入站 tag 替换 `inbound-25443`。

```json
{
  "type": "field",
  "inboundTag": ["inbound-25443"],
  "outboundTag": "private-cascade-exit"
}
```

运行 `sudo /usr/local/bin/xray run -test -config /usr/local/etc/xray/config.json` 验证修改后的境外配置。成功后，在维护窗口重启其 Xray 服务，并确认该入站选择 `private-cascade-exit`。验证或重启失败时，恢复并验证备份，再恢复服务。在一个 XUDP 会话中，先向可控的允许 IPv4 目标发包，再向可控的禁止目标发包。确认第一包到达、第二包被丢弃。分别检查 IP 地址和解析为这些地址的域名。

## 准备路由列表

下例使用已安装的 `geosite.dat` 中的俄罗斯分类，以及 Re-filter 的紧凑域名和 IP 封锁列表。更新现有列表前，保存其哈希和受保护备份。从同一 release 下载两个文件，并校验 GitHub 发布的 SHA-256 后再安装。[Re-filter 来源](https://github.com/1andrevich/Re-filter-lists)

```bash
(
  set -eu
  stage=$(mktemp -d)
  trap 'rm -rf -- "$stage"' EXIT
  curl -fsSL https://api.github.com/repos/1andrevich/Re-filter-lists/releases/latest \
    -o "$stage/release.json"
  for kind in geoip geosite; do
    name="$kind.dat"
    url=$(jq -er --arg name "$name" '.assets[] | select(.name == $name) | .browser_download_url' "$stage/release.json")
    hash=$(jq -er --arg name "$name" '.assets[] | select(.name == $name) | .digest | select(test("^sha256:[a-f0-9]{64}$")) | ltrimstr("sha256:")' "$stage/release.json")
    curl -fsSL "$url" -o "$stage/$name"
    printf '%s  %s\n' "$hash" "$stage/$name" | sha256sum -c -
  done
  sudo install -o root -g xray -m 0644 "$stage/geoip.dat" /usr/local/share/xray/refilter-geoip.dat
  sudo install -o root -g xray -m 0644 "$stage/geosite.dat" /usr/local/share/xray/refilter-geosite.dat
)
```

保留已安装的国家 IP 数据及 `geoip:private`、`geoip:ru` 分类。策略使用已安装域名数据的 `geosite:available-only-in-ru` 和 `geosite:category-ru`。若缺少分类，生成配置前更新或选择已审核数据。每次列表变化后验证新候选配置。列表更新失败时，先恢复原文件，再重启运行中的级联。

## 生成并启动入口

在俄罗斯 VPS 选择可用的 VLESS REALITY TCP 或旧式 XHTTP 入站，要求 `decryption=none` 且 VLESS `fallbacks` 列表为空。新安装上预留空闲模板端口，并在服务商防火墙中保持关闭。运行 `sudo xrayebator profile-create --name private-cascade-template --transport xhttp --without-pq --port 15442`，确认 `names` 包含模板且 `errors` 为空。这会在主配置中创建 `inbound-15442`。独立服务使用自己的端口，此例为 `15443`。

用 `uuidgen` 为独立入口生成新 UUID。在 root 专属目录（例如 `/root/xrayebator-private-cascade/`）中创建两个 root 所有、权限为 `0600` 的文件。将唯一上游 URI 写入 `upstream.txt`，按下例填写 `policy.json`，替换入站 tag、UUID 和示例目标。

```json
{
  "inbound_tag": "inbound-15442",
  "client_id": "<cascade-client-uuid>",
  "listen": "0.0.0.0",
  "port": 15443,
  "udp_relay_port": 15444,
  "udp_dispatch_port": 15445,
  "russia_only_domains": ["geosite:available-only-in-ru"],
  "blocked_domains": ["ext:refilter-geosite.dat:refilter"],
  "blocked_ips": ["ext:refilter-geoip.dat:refilter"],
  "russian_domains": ["domain:ru", "domain:su", "domain:xn--p1ai", "geosite:category-ru"],
  "russian_ips": ["geoip:ru"]
}
```

选择空闲 TCP 端口，并在主机和服务商防火墙上向所需客户端开放。`blocked_domains`、`blocked_ips` 必须是数组，两者至少有一个非空。可选数组 `russia_only_domains`、`russian_domains`、`russian_ips` 定义直连规则，后两者默认覆盖 `.ru`/`.рф` 和 `geoip:ru`。使用已安装数据支持的 Xray selector。`ext:` 需要对应本地数据文件。生成器只读取 VPS 上的数据。

使用空数组禁用某个可选列表。省略字段时使用默认值。

`udp_relay_port` 和 `udp_dispatch_port` 默认分别为 `15444` 和 `15445`。在俄罗斯 VPS 预留两个空闲非特权 TCP 端口，三个端口必须互不相同。本地端口仅绑定 `127.0.0.1`，保持其仅回环可达。生成器在受保护配置中创建独立辅助程序密码和分类器 UUID。仅在服务器本地保管这些内部凭据。

入口按 IP 规则阻止私有和 IPv6 目标。Sniffing 保留客户端传入的禁止地址。其他 TCP 连接使用嗅探到的名称作为 Xray 实际连接目标。识别出的仅限俄罗斯名称优先于封锁列表，无论客户端最初传入的是名称还是对应公网 IP。封锁列表优先于普通俄罗斯规则。直连出站仅解析 IPv4，并在拨号时复查目标 IP。`russian_ips` 路由只能连接该列表中的 IP。后续 DNS 查询结果若与所选直连策略冲突，连接会失败。

对 UDP，公网入站先将每个数据报发给认证回环辅助程序，包括虚拟 DNS 和禁止目标尝试。XUDP 在一个会话内可以改变目标，因此辅助程序为原会话的每个目标分别开启固定目标的 VLESS UDP 流。Xray 再对流执行 DNS 截获、目标禁止和五条有序策略。辅助程序复用 Xray 的域名/IP 策略，互联网连接由 Xray 发起。本地 Trojan 帧格式仅用于内部传输，客户端仍使用 VLESS REALITY。

识别出的俄罗斯 UDP 可以直接从俄罗斯出站。境外节点故障会停止境外 TCP/UDP，保持俄罗斯直连 TCP/UDP 和入口 DNS 可用。辅助程序故障会停止应用 UDP 和虚拟 UDP DNS，TCP 保留其路由。辅助程序拒绝大于 8190 字节的负载。Xray 的 8 KiB 帧缓冲区还可能因地址和头部开销降低可用大小。需要大型数据报的应用应另行验证。连接、流、队列和空闲时间限制用于控制资源消耗，达到限制时丢弃数据或关闭相关流。

分流键是原会话内的目标地址和端口。Sniffing 在固定目标流的起始执行。共享同一目标端点的不同 QUIC 连接沿用该流的分类，需要对这类应用另行确认。

入口使用服务 DoH，并以本机解析器作为备用。在 VLESS 内将客户端 DNS 指向 `192.0.2.53:53`。该虚拟地址专供 53 端口 DNS。关闭客户端自动切换到直连或其他配置档。

```bash
sudo xrayebator private-cascade render \
  --policy-file /root/xrayebator-private-cascade/policy.json \
  --upstream-file /root/xrayebator-private-cascade/upstream.txt \
  --output /root/xrayebator-private-cascade/ingress.json
```

已安装管理器较旧时，从已审核源码目录运行带相同参数的 `sudo bash ./xrayebator private-cascade render`。

生成器为公网客户端创建新 UUID，并采用模板首个客户端的 flow，同时生成内部回环分类器和辅助程序凭据。它保留公网传输及 REALITY 参数，使用 `xray run -test` 验证后写入 root 所有、权限为 `0600` 的新文件。辅助程序服务可用性需要单独检查。首次安装选用空闲服务目录。

```bash
sudo install -d -o root -g xray -m 0750 /etc/xray-private-cascade
sudo install -o root -g xray -m 0640 /root/xrayebator-private-cascade/ingress.json \
  /etc/xray-private-cascade/config.json
sudo install -d -o root -g root -m 0755 /usr/local/libexec
sudo install -o root -g root -m 0755 libexec/private_cascade_udp.py \
  /usr/local/libexec/xrayebator-private-udp.py
command -v python3
```

从已审核源码目录安装辅助程序。启动前确认 `/usr/bin/python3` 存在，支持的 Debian/Ubuntu 上缺失时安装 `python3` 软件包。配置保留 root 所有、仅 `xray` 组可读（`0640`），两个服务都需要读取。

以 root 创建 `/etc/systemd/system/xray-private-cascade-udp.service`。

```ini
[Unit]
Description=Xray private cascade UDP destination splitter
PartOf=xray-private-cascade.service

[Service]
User=xray
Group=xray
NoNewPrivileges=true
ExecStart=/usr/bin/python3 /usr/local/libexec/xrayebator-private-udp.py --config /etc/xray-private-cascade/config.json
Restart=on-failure
```

以 root 创建 `/etc/systemd/system/xray-private-cascade.service`。`Wants` 启动辅助程序，辅助程序故障时 TCP 仍可工作。`PartOf` 让辅助程序随入口停止或重启。绑定能力也支持空闲特权端口（例如 443）。两个本地端口保持大于 1023。以下使用标准 Xrayebator 二进制和数据路径。

```ini
[Unit]
Description=Xray private cascade ingress
Wants=network-online.target xray-private-cascade-udp.service
After=network-online.target xray-private-cascade-udp.service

[Service]
User=xray
Group=xray
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
Environment=XRAY_LOCATION_ASSET=/usr/local/share/xray
ExecStart=/usr/local/bin/xray run -config /etc/xray-private-cascade/config.json
Restart=on-failure

[Install]
WantedBy=multi-user.target
```

```bash
sudo systemctl daemon-reload
sudo systemctl start xray-private-cascade.service
sudo systemctl status --no-pager xray-private-cascade.service xray-private-cascade-udp.service
ss -ltn 'sport = :15443'
ss -ltn 'sport = :15444 or sport = :15445'
```

确认两个本地监听都使用 `127.0.0.1`。通过实际 UDP 请求验证辅助程序。更新时保护配置、辅助程序和两个 unit 的备份，验证候选配置后重启入口，让 `PartOf` 辅助程序加载匹配凭据。验证或验收失败时一起恢复这些文件。

私下以模板首个客户端 URI 为参考，替换 UUID、拨号地址和独立监听端口。保留 REALITY 字段、flow、指纹和传输选项，包括 XHTTP 的 host、path、mode。作为独立测试配置档导入。轮换时更新独立配置中的 UUID 并重新发放链接。

## 更新与卸载

独立级联采用手动生命周期。更新前备份配置、已安装辅助程序和两个 unit 文件。将源码切换到已审核修订版，在新输出路径生成并验证候选配置，再安装匹配配置，并重新将 `libexec/private_cascade_udp.py` 复制到 `/usr/local/libexec/xrayebator-private-udp.py`。对照指南更新两个 unit 文件。单元改变后运行 `sudo systemctl daemon-reload`，再重启 `xray-private-cascade.service`，让辅助程序重读相同凭据。重复验收，失败时整体恢复备份。

运行通用 `uninstall.sh` 前，按下文回滚。先停止入口和辅助程序，再移除 `/etc/systemd/system/xray-private-cascade.service`、`/etc/systemd/system/xray-private-cascade-udp.service`、`/etc/xray-private-cascade/` 及已安装辅助程序。运行 `systemctl daemon-reload`，关闭级联公网端口，移除境外配置档及其限定路由。保留受保护输入和备份，直至不再需要回滚。使用常规安装、更新或卸载程序时，这些独立文件和单元由运营者手动维护。

## 验收或回滚级联

1. 从所需网络上的桌面或命令行客户端验证 REALITY，发送少量 HTTPS 和 DNS 请求。用可控目标日志确认俄罗斯规则显示俄罗斯源 IP，未匹配规则显示境外源 IP。为一个仅限俄罗斯名称配置也命中 `blocked_ips` 的公网 IPv4，分别按名称及带相同 SNI 的 IP 连接，两者应直达实际俄罗斯目标。普通俄罗斯名称若解析到封锁 IP，应走境外。
2. 在同一个真实 XUDP 会话中依次向可控俄罗斯、境外、封锁目标及俄罗斯目标发送小型 UDP 包。确认每次源地址和响应，再反向重复并以虚拟 DNS 查询开头重复。即使封锁目标 IP 属于俄罗斯，也应走境外。私有和 IPv6 目标应收不到包。
3. 维护窗口中只停止专用境外链路，再开启新连接。俄罗斯直连 TCP/UDP 和虚拟 DNS 应继续工作，境外 TCP/UDP 应失败且不会从俄罗斯出口发出。恢复链路并检查恢复。另行仅停止 `xray-private-cascade-udp.service`，应用 UDP 和虚拟 UDP DNS 应停止，TCP 保留其路由。重启辅助程序并复查。
4. 对照操作前状态检查原 Xray 服务、配置档、订阅、Hysteria 2 和 AmneziaWG。验收通过后只启用入口开机启动，运行 `sudo systemctl enable xray-private-cascade.service`，其 `Wants` 会启动辅助程序。
5. 回滚时，断开客户端级联配置档，运行 `sudo systemctl disable --now xray-private-cascade.service`，再运行 `sudo systemctl stop xray-private-cascade-udp.service`。确认入口三个监听均已停止。移除两个专用 unit 和安装配置，仅在辅助程序专用于此级联时删除其安装文件。运行 `sudo systemctl daemon-reload`。仅关闭两端专用公网端口，回环端口保持本地限制。在境外 VPS 运行 `sudo xrayebator profile-delete --name private-cascade-egress`，再移除其路由规则和 `private-cascade-exit` 出站。若创建了 `private-cascade-template`，在俄罗斯 VPS 按名称删除。复查原服务。
