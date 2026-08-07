# 配置

[← 返回 README](../../README.zh-CN.md) · [English](../configuration.md) · [Русский](../ru/configuration.md)

章节：[环境变量](#安装脚本的环境变量) · [防火墙与主机网络设置](#防火墙与主机网络设置) ·
[主菜单](#主菜单) · [命令](#命令) · [分流路由](#分流路由) · [级联](#级联与上游节点) ·
[Self-steal](#自有域名与-self-steal-挡板) · [域名与 DNS](#域名与-dns)

---

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

UFW 由安装脚本自行管理：安装 `ufw` 包，若 UFW 未启用则执行 `ufw --force enable`，
随后开放端口 `22, 80, 443, 8443, 2053, 2083, 2087, 8080, 2096, 8880, 9443/tcp` 并重新加载规则。

> 端口列表是固定的，其中可能没有你的 SSH 端口。如果 SSH 不在 `22`，或者你有自己的防火墙策略，
> 请对比安装前后的 numbered rules。卸载 Xrayebator 时，安装脚本开放的规则不会被移除。

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

修改 SNI 或端口会重启对应的服务端入站。指纹是客户端参数：只影响所选线路，且不需要重启 Xray。
任何修改之后，请在客户端强制刷新订阅，或通过 `3) Подключиться по профилю` 重新获取原始线路。

## 命令

| 命令 | 作用 |
|---|---|
| `sudo xrayebator` | 打开交互菜单 |
| `sudo xrayebator update` | 仅更新 **Xray-core 内核**，不动 Xrayebator 本身 |
| `sudo xrayebator probe-test` | 更换 SNI 前，从 VPS 检查其可达性 |
| `sudo xrayebator quickstart --email <邮箱>` | 非交互式一键部署（供桌面 GUI 使用）：设置订阅服务器、签发 IP-TLS 证书并创建 multi-route HAPP 配置档。打印 JSON 结果 |
| `sudo xrayebator happ-setup` | 幂等地重建 HAPP multi-route 配置档：安装/重启订阅服务并打印与 `quickstart` 相同的 JSON |
| `sudo xrayebator-update` | 按 `.current_branch` 记录的分支更新 **Xrayebator 本身** |
| `sudo xrayebator-update main` | 强制从 `main` 分支更新 Xrayebator 本身 |
| `sudo xrayebator-uninstall` | 移除服务与配置 |

`xrayebator update` 与 `xrayebator-update main` 只是名字相像：

| | `sudo xrayebator update` | `sudo xrayebator-update main` |
|---|---|---|
| 更新对象 | Xray-core 二进制 | Xrayebator 脚本本身 |
| 来源 | XTLS 项目的 GitHub Releases | 本仓库的 `main` 分支 |
| 参数 | 不接受 | 接受分支名：`main`、`dev`、`experimental` 或其他 |
| 影响 | 内核版本、传输方式、协议 | 菜单、迁移、订阅生成 |
| 副作用 | 配置校验后重启 Xray | 下次打开菜单时执行迁移 |

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
所有改动都经过 `backup_config`、`safe_jq_write` 与 `safe_restart_xray`。

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
