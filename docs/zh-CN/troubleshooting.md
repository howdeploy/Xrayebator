# 故障排查

[← 返回 README](../../README.zh-CN.md) · [English](../troubleshooting.md) · [Русский](../ru/troubleshooting.md)

---

## HAPP 不刷新订阅

`quickstart` 输出的 JSON 包含 `subscription_url`。它根据已保存的订阅基础地址构建，因此链接中的主机和端口是有意的：

```text
https://your-domain/sub/<token>        # 443 上的公共 TLS
https://your-domain:8443/sub/<token>   # 8443 上的公共 TLS
http://127.0.0.1:8080/sub/<token>      # 仅本地调试模式
```

在 VPS 上检查实际 URL，并保留其中的端口：

```bash
curl -vkI https://your-domain[:port]/sub/
curl -vk https://your-domain[:port]/sub/<token>
```

不带令牌访问 `/sub/` 必须返回 `404`。完整令牌 URL 必须返回 `200`，响应体包含 `vless://` 链接。然后检查服务：

```bash
systemctl status xrayebator-sub --no-pager -l
systemctl status nginx --no-pager -l
```

如果主机或端口不正确，请检查订阅模式并重新执行对应的 IP-TLS 或域名设置；仅添加 DNS 记录不会改写保存的 endpoint 标记。

## 链接显示为 127.0.0.1

当前是仅本地模式，只用于调试或 SSH 隧道。手机使用请在 HAPP 订阅菜单中切换到按 IPv4 或按域名的公共 TLS。仅本地链接不能交给外部客户端。

## IPv6-only VPS 上的 IP-TLS 不工作

当前自动 IP 证书流程需要公共 IPv4。由于 IPv6 IP-TLS 路径尚未自动化，程序会拒绝生成该 endpoint。请配置具有可达 A/AAAA 记录的域名，然后使用域名 TLS 模式。

## 已经添加域名，链接仍显示 IP

DNS 记录不等于保存的订阅配置。重新启用域名模式：`HAPP 订阅 → 按域名的 public TLS`。确认生成的 `subscription_url` 使用域名，并且当公共监听器不在 443 时包含 `:8443`。

## `happ-setup` 拒绝返回公共 URL

这是安全检查，不是 URL 格式选项缺失。缺少订阅标记时，`happ-setup` 不会从 IP 或标记文件伪造公共 endpoint；它要求订阅 vhost、证书和活动 HTTPS listener 得到验证。如果保存的标记已经存在，程序可能复用旧标记，因此过期标记仍需要运维人员重新验证并重新执行设置。

新服务器请先运行 `quickstart --email <address>`，或从终端菜单完成 HAPP 的 IP/域名设置。对于已有安装，请检查：

```bash
sudo systemctl status nginx --no-pager -l
sudo systemctl status xrayebator-sub --no-pager -l
sudo journalctl -u xrayebator-sub -n 80 --no-pager
```

修复证书或 listener 后再次运行 `sudo xrayebator happ-setup`。不要手写一个看似合理的公共 URL 来绕过错误。

## HAPP 显示六条线路，但配置档有七条

对于 managed HAPP 配置档，这是预期行为。配置档 JSON 应包含七条存活的 `routes[]`，包括 `xhttp-legacy` 和 `xhttp-pq`；发布的 VLESS 列表包含六条，因为 PQ-XHTTP 线路保留给原始/配置档路径，而不是普通 HAPP 列表。

检查配置档和存活端口：

```bash
jq -r '.routes[] | [.label,.transport,.port,(.pq_enabled // false)] | @tsv' \
  /usr/local/etc/xray/profiles/<profile>.json
```

最后一列是 `pq_enabled`，不是健康状态。所有非 PQ 线路为 `false` 是正常的；只有 `xhttp-pq` 应为 `true`。注意：`_migrate_happ_legacy_xhttp_route_2026` 不会向已有配置档添加线路。如果已有配置档缺少 `xhttp-legacy`，请重新创建/恢复 managed multi-route 配置档（通过菜单/quickstart 重新部署，或重新创建），而不是只重复运行迁移。

## HAPP 中 XHTTP 不可用

HAPP 兼容的 XHTTP 候选必须是 `xhttp-legacy`，而不是 PQ 线路。更新后运行 `sudo xrayebator`，等待迁移完成，并在 HAPP 中强制刷新订阅。确认该线路存在于配置档中，且其端口存在于运行中的配置里。

## v2rayNG 时好时坏

`v2rayNG` 不是 HAPP 流程的主力客户端。它收到的是 v2ray 兼容的订阅体，但线路能否使用仍取决于客户端对该传输方式的支持以及其内置的 Xray-core 版本。请逐条测试线路：不存在通用的「从好到坏」顺序。

## 修改 SNI、端口或指纹后连接失效

请在客户端刷新订阅，或重新获取原始线路。SNI 和端口是共享入站的设置，因此修改它们可能影响该端口上的所有配置档，通常需要客户端重新连接。指纹是所选配置档/线路的客户端参数，不会重启 Xray，也不会修改其他线路。服务端订阅会在同一链接上立即更新，但 HAPP 仍需要强制刷新或等待下一次自动更新。

## 订阅返回 410，但配置档看起来是正常的

该配置档因有效期被停用：profile JSON 中带有 `.expire_disabled: true`，或者 `.expire`
（epoch 秒）已经过期。强制执行由 systemd 定时器 `xrayebator-expire.timer` 完成（每 10 分钟运行
`xrayebator expire-check`）：它会把客户端从 inbound 中移除，因此即使已经下载的链接也无法连接，
订阅会返回 `410 Gone`，正文为 `Profile expired or disabled`。只选日期（例如 9 月 30 日）时，
配置档在当天仍有效，并于服务器本地时区的 `23:59:59` 到期；CLI 显式指定的时间也按服务器时区解释。
延长或取消有效期：

```bash
sudo xrayebator profile-expire --name 名称 --expire 2026-12-31   # 延长
sudo xrayebator profile-expire --name 名称 --expire none         # 设为永久
```

延长后会恢复同一个客户端（同一 uuid），因此设备无需重新导入订阅。在 GUI 中同样的操作位于配置档卡片上的「有效期」按钮。

## 服务器上有旧配置档但无法使用

如果配置档 JSON 指向的端口已经不在 `config.json` 中，说明配置档已过期。新订阅不会提供这些线路。只有当配置档已经没有任何存活线路时，旧令牌才会返回 `410 Gone`；部分过期的多线路配置档仍可能以 `200` 返回剩余的存活线路。请重新创建配置档，或通过终端菜单修复存活入站；不要发布指向失效端口的链接。

## 客户端连不上

按顺序排查：

1. HAPP 版本过旧 —— 更新到 `3.3.6` 或更高版本，彻底退出所有旧 HAPP 进程，只启动一个最新实例，然后刷新订阅。
2. 绿色延迟并不能证明主 TUN 正常：HAPP 使用独立的临时 Xray-core 检测线路。在 Linux 上运行 `ss -lntp | grep ':10808'`；没有输出说明主 core 没有监听，请彻底重启 HAPP。
3. 客户端不支持该传输方式 —— 先用订阅链接或 TCP 线路。
4. SNI 不合适 —— 用 `sudo xrayebator probe-test` 检查并更换。
5. 服务商封锁了端口 —— 更换配置档端口。
6. 指纹被识别 —— 尝试用 `firefox` 代替 `chrome`。
7. 订阅已过期 —— 确认线路存在于运行中的 `config.json`。

Xrayebator 3.0 还会一次性删除旧版本安装的 UDP/443 阻断规则。该规则可能在 TCP 线路检测仍为绿色时破坏 Telegram。带有额外匹配条件的运维人员自定义路由规则会被保留。

建议常备 2–4 个配置档，便于紧急切换。

## GUI 更新没有执行完整的项目更新

Electron GUI 的 Server Settings 调用 `xrayebator update <branch>`：从该分支 self-update 管理器并更新 Xray-core。它不同于完整的 `xrayebator-update [branch]` lifecycle updater。需要刷新数据、订阅集成和全部 lifecycle 步骤时，请从 SSH 终端运行后者。

GUI 有意只暴露 Bash 菜单的一个子集。`probe-test`、HAPP setup、级联、self-steal 以及服务日志/状态仍需从终端执行；配置档有效期、订阅吊销和分流分组可在服务器设置中完成。

## Electron 单元测试在 Windows 上失败

`tests/unit/shell-command.test.ts` 会有意调用 POSIX `/bin/sh`。原生 Windows 没有这个路径，因此即使 TypeScript 代码有效，这一个 shell 专用测试也可能在本地失败。请在 Linux 或 Ubuntu CI job 上运行完整 Electron unit suite；对于该 POSIX 行为，Linux 是事实来源。活跃的 Electron release workflow 也会在打包 Windows、macOS 和 Linux 之前于 Ubuntu 上运行单元测试。

## 配置过程中被踢出服务器

连接自己的 VPN 之后再在服务器上做修改，SSH 可能会断开。最简单的办法是不要通过自己的线路访问服务器。也可以启用 keep-alive：

```bash
sudo nano /etc/ssh/sshd_config
```

```text
ClientAliveInterval 60
ClientAliveCountMax 120
TCPKeepAlive yes
```

```bash
sudo systemctl restart sshd
```

## 整个互联网都无法访问

请检查客户端 DNS。服务商封锁 VPN 时，DNS 往往最先出问题。在客户端保留一份备用订阅链接列表。桌面客户端还要确认是否需要开启 TUN 模式来做系统代理。

## 可以接入多少用户

界面没有硬性的配置档数量限制。实际容量受 CPU、内存、VPS 带宽、线路数量以及服务商限制约束。请逐步增加用户数并观察负载。

多个配置档可以同时使用：不同的订阅、SNI、端口和线路提供了更多绕过封锁的选择，但它们共享同一台 VPS 的资源。

## Hysteria 2 服务无法启动

先读原因——安装会回滚产物，状态需要复现：

```bash
journalctl -u hysteria-server.service --no-pager | tail -20
```

已知失败模式（生成器已修复，手工改配置时仍然相关）：

- `invalid config: auth.userpass: empty auth userpass` —— auth 映射的键是 `userpass` 而**不是**
  `users`，且空映射会被拒绝。生成器始终至少渲染 `_xrayebator_placeholder`（尚无配置档授权时）；
  手工编辑 `server.yaml` 时，请保持 `userpass:` 下有非空映射。
- `Changing to the requested working directory failed: Permission denied` —— 后端目录必须为
  `root:hysteria 0750`；只 `chmod` 而不做配对 `chown` 会留下 `root:root`，单元无法进入目录。
- 证书不可读 —— `le` 模式下证书是 `root:hysteria 0640` 的副本；续期 deploy-hook 负责刷新。

修复后的干净路径：`hysteria2-uninstall` 然后重新 `hysteria2-install`。

## AWG：接口已启动但没有 `latest handshake`

AmneziaWG 对参数不匹配保持沉默：peer 只是永远不出现握手。请检查「必须一致」组——它与每个
客户端 `.conf` 必须完全相同：

- `S1`–`S4`（3.x 引擎要求 ≥ 12）、`H1`–`H4`；
- 对端存在的任何 3.x 键：`HeaderProtectionKey`（3.0）与 `RandomTrailers`（3.1）必须逐字节
  一致。Xrayebator 仅在 3.1 模式（`awg-31 --on`，新安装默认开启）下输出它们；不匹配通常意味着
  客户端 `.conf` 早于 3.1 切换——请重新下载——或混入了第三方/手工配置；
- 客户端应用版本：带 `RandomTrailers` 的配置需要 AmneziaVPN ≥ 5.0.1.5；更旧的客户端可能直接
  拒绝导入。

然后区分调试区域：服务器上的 `awg show awg0` ——若 peer 在列、握手存在但没有流量，问题在
`awg-quick`/路由/防火墙区域（`ip_forward`、MASQUERADE 接口），而不是协议参数。

在怀疑参数之前，先验证网络路径本身。AWG 套接字位于内核空间，UDP 端口在 `ss`/`netstat` 中不可见
——只有在客户端尝试连接时于服务器上抓包才能看到：

```bash
tcpdump -l -ni <iface> 'udp port <port>'
```

抓不到任何包 → 数据包根本没有到达：运营商/DPI 过滤（典型的 RU 模式——UDP 443 上的 Hysteria 2
可以通过，而高位随机 UDP 端口被静默丢弃）。抓到包但 `awg show` 仍无握手 → 客户端发送的是
「垃圾」：重新签发 `.conf`，检查应用版本（3.1 参数需要 AmneziaVPN ≥ 5.0.1.5），或临时
`awg-31 --off` 并重新导入以测试 2.0 兼容性。注意：`tcpdump` 重定向到文件时若不加 `-l` 会按块
缓冲输出——早期数据包在缓冲区刷新前可能不可见。

## AmneziaVPN（完整应用）报错 1000，独立版客户端正常

`错误 1000` 是应用笼统的 `AndroidError`；手机端日志此时显示
`VPN config format error: No value for client_ip`。应用的原生管道只接受自己的导出形态——
`amnezia-awg2` 容器、与 `last_config` 并列的服务器级 junk 字段、`protocol_version` 以及压缩
（`qCompress`）payload。裸 `.conf`（或缺少这些字段的朴素 `vpn://`）会被保存，但客户端部分
到不了隧道。桌面 GUI 的「QR · AmneziaVPN」二维码构造的正是这种形态——请用它代替粘贴
`.conf`。Xrayebator 安装的 junk 组与 Amnezia 默认值一致（`Jc` 5、`Jmin` 10、`Jmax` 50、
`H1`–`H4` = 1..4），正是因为应用的 go-туннель对自定义 junk 应用不完整。

## AWG 安装失败

- 首选路径是 `amnezia/ppa` PPA；在没有对应发行版构建的系列上，Xrayebator 回退到源码编译。内核
  ≥ 5.6 时需要**完整的** `linux-source` 包——仅有内核头文件不够（模块构建会链接整个源码树）。
- 安装后验证：`lsmod | grep amneziawg` 显示模块，`awg --version` 有响应。
- 单元 `awg-quick@awg0` 读取 `/etc/amnezia/amneziawg/awg0.conf` —— Xrayebator 将其维护为指向
  `/usr/local/etc/xrayebator/backends/awg/awg0.conf` 的 symlink。删除 symlink 会让单元失效，
  尽管后端配置本身有效。
- 卸载时软件包与内核模块有意保留在系统中；被移除的是接口、配置、symlink 与防火墙规则。

## 订阅中没有 `hysteria2://` 行

只有同时满足以下条件，`hysteria2://` 链接才会追加到两个订阅主体：

1. Hysteria 2 后端已安装（`xrayebator hysteria2-status`）；
2. 配置档持有授权（`profiles` JSON → `.backends.hysteria2.password`）；
3. 注册表标志 `sub_body` 为 `true`（总开关——直接改 `backends.json`，处理器每次请求都会重读
   注册表，无需重启服务）。

过期或停用的配置档不会得到该行；被吊销的配置档在下次刷新订阅时拿到新凭据。吊销后旧 token
URL 返回 `404` 属于预期——令牌本身已轮换。

## quickstart 报错 `apt-get install nginx failed`

新装的 Ubuntu VPS 上，`unattended-upgrades` 可能持有 apt/dpkg 锁约 10 分钟，并且对每个包单独调用 `dpkg`，因此简单的锁检查会从包与包之间的空隙漏过。quickstart 现在会额外等待活跃的 `unattended-upgrade` 进程（12 分钟预算），并给 `apt-get install` 传入 `-o DPkg::Lock::Timeout=180`。当 quickstart 提示 apt 超过预算仍被占用时，请稍后重试部署，或等更新队列结束。该行为由 `validation/test-apt-lock-race.sh` 锁定。

## quickstart 报「certbot failed: ... Connection reset by peer」但仍成功结束

Let's Encrypt 无法获取 http-01 challenge——最常见原因是服务商网络对境外来源过滤 80 端口
（已用 tcpdump 与多节点探测验证：本机防火墙与 nginx 正常，reset 发生在上游）。在此降级
模式下部署以 `http_tls` 回退结束：结果 JSON 携带 `degraded:true` 与 `tls_mode:"http_tls"`，
GUI 将服务器标记为「配置不完整」，密钥通过 SSH 加载。此模式下不存在公共订阅
URL——不会出现可泄露的 HTTP 链接。恢复 HTTPS 的方式：请服务商为 Let's Encrypt validation 网段解除 80 端口
封锁（或将域名解析到服务器并使用域名 TLS 模式），然后重新部署；流程幂等，challenge
可达后即签发 LE 证书。回退结构由 `validation/test-quickstart-tls-fallback.sh` 锁定。

## 安装或使用过程中出现报错

请完整复制终端中的报错文本。如果问题出在 Xrayebator 代码上，请提交 issue。