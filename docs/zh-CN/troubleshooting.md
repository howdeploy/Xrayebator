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

GUI 有意只暴露 Bash 菜单的一个子集。bypass、探测、订阅吊销、HAPP setup、级联、self-steal 以及服务日志/状态仍需从终端执行。

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

## quickstart 报错 `apt-get install nginx failed`

新装的 Ubuntu VPS 上，`unattended-upgrades` 可能持有 apt/dpkg 锁约 10 分钟，并且对每个包单独调用 `dpkg`，因此简单的锁检查会从包与包之间的空隙漏过。quickstart 现在会额外等待活跃的 `unattended-upgrade` 进程（12 分钟预算），并给 `apt-get install` 传入 `-o DPkg::Lock::Timeout=180`。当 quickstart 提示 apt 超过预算仍被占用时，请稍后重试部署，或等更新队列结束。该行为由 `validation/test-apt-lock-race.sh` 锁定。

## 安装或使用过程中出现报错

请完整复制终端中的报错文本。如果问题出在 Xrayebator 代码上，请提交 issue。