<div align="center">

# Xrayebator

<h3>在自己的 VPS 上运行 Xray VLESS Reality</h3>

<p>
<strong>入站</strong> · <strong>配置档</strong> · <strong>订阅</strong> ·
<strong>分流</strong> · <strong>级联</strong>
</p>

<p>
<strong>其他语言版本</strong><br>
<a href="README.md">🇺🇸 English</a> ·
<a href="README.ru.md">🇷🇺 Русский</a> ·
<a href="README.zh-CN.md">🇨🇳 简体中文</a>
</p>

<p>
<img alt="Bash 5.0+" src="https://img.shields.io/badge/bash-5.0%2B-4EAA25?style=flat-square&logo=gnubash&logoColor=white">
<img alt="Xray-core Reality" src="https://img.shields.io/badge/Xray--core-Reality-22D3EE?style=flat-square">
<img alt="HAPP subscription" src="https://img.shields.io/badge/subscription-HAPP-A78BFA?style=flat-square">
<a href="LICENSE"><img alt="MIT" src="https://img.shields.io/badge/license-MIT-3FB950?style=flat-square"></a>
</p>

<p>
<strong>一个 bash 脚本，把干净的 VPS 变成私人 VLESS Reality 服务器。</strong><br>
Xrayebator 安装 Xray-core，在随机端口上建立 Reality 入站，并为新安装创建包含七条线路的标准
schema-v3 HAPP 配置档。已有七线路配置档在满足存活线路数量时可能被复用，因此排查 label 或 schema
时请检查配置档 JSON。客户端通过一条 HTTPS 订阅链接获取线路。当前服务器版本线为 3.0；可选
Electron 桌面应用单独版本化。
</p>

</div>

```bash
curl -fsSLo ./xrayebator-install.sh \
  https://raw.githubusercontent.com/howdeploy/Xrayebator/main/install.sh
less ./xrayebator-install.sh          # 运行前请先审阅脚本
sudo bash ./xrayebator-install.sh

# 步进控制（中断安全安装）：
#   --check   查看 10 个安装步骤中哪些已完成
#   --resume  从未完成的第一个步骤继续
#   --fresh   清除标记并从头开始
```

<div align="center">

<p>
Debian 12/13 · Ubuntu 22.04/24.04 · 内存 512 MB 起 · 需要 <code>root</code> 或 <code>sudo</code><br>
随后执行 <code>sudo xrayebator</code>，选择第 <code>6</code> 项，订阅即可就绪。
详情：<a href="#快速开始">快速开始</a>
</p>

<p>
<a href="#项目目的">项目目的</a> ·
<a href="#能力一览">能力一览</a> ·
<a href="#工作原理">工作原理</a> ·
<a href="#快速开始">快速开始</a> ·
<a href="#文档">文档</a> ·
<a href="#已知限制">已知限制</a> ·
<a href="#更新与卸载">更新</a>
</p>

</div>

---

## 项目目的

手工搭建私人 VLESS Reality 需要十几个步骤：组装入站、生成密钥、挑选 SNI、避免写坏配置、
把链接送到手机上。`config.json` 中一个拼写错误就会让 Xray 无法启动。

而且单条线路远远不够。DPI 对各种传输方式的封锁并不一致：某个网络里 TCP Vision 可用，
另一个网络里只有 gRPC 能跑，第三个网络里只剩 XHTTP。为每种情况手工维护独立配置并不现实。

Xrayebator 同时解决这两个问题：

- 一个配置档不是一条线路，而是共享同一个 `sub_token` 的一组 `routes`；
- 客户端拿到的是一条短订阅链接，而不是七条 `vless://` 链接；
- 运行时配置改动都经过备份、显式的 `xray run -test` 校验和自动回滚，失败的改动不会有意让服务器失去 VPN；
- 更换 SNI、端口或指纹都不需要重建配置档。SNI 和端口属于共享入站设置，指纹则是按配置档/线路保存的客户端参数。

本项目由一个人开发和测试。由此带来的限制都直接写在
[已知限制](#已知限制) 一节，请在正式 VPS 上安装前先阅读。

## 能力一览

| 能力 | 作用 | 实现位置 |
|---|---|---|
| 安装 Xray-core | 从 GitHub 下载发行版，强制用 `.dgst` 校验 SHA-256，通过 `install -m 755` 安装二进制并自检 | `install.sh` |
| Reality 入站 | 在 `30000-60000` 的空闲端口上建立入站，同时核对 `config.json` 与实际监听的套接字 | `xrayebator` |
| 多线路配置档 | 一个配置档 = 共享 `sub_token` 的一组线路；多个配置档可共用同一端口 | `profiles/<name>.json` |
| HAPP 订阅 | 提供 `vless://` 列表、托管的 Global Proxy 路由及令牌保护的 geo 数据库，由 nginx 通过 HTTPS 对外发布 | `subhttp.sh`、`xrayebator-sub.service` |
| 后量子 XHTTP | `xhttp-pq` 线路使用 VLESS 加密 `mlkem768x25519plus` | `.vless_encryption`、`.vless_decryption` |
| v2ray 兼容 | `v2rayNG` 与 `v2rayN` 获得不含 HAPP 元数据的经典 base64 订阅体 | `subhttp.sh` |
| 吊销订阅 | 生成新的 32 位十六进制令牌，旧链接立即失效 | `openssl rand -hex 16` |
| 分流路由 | 七组域名可经 `freedom` 直连，绕过 VPN | 菜单 `7` |
| 级联 | 把 `tcp,udp` 兜底规则切换到 `tcp` 或 `xhttp` 类型的境外 VLESS Reality 上游 | `upstreams/cascade.json` |
| Self-steal 挡板 | 在 `127.0.0.1:9444` 部署带有效证书的 nginx，并让 Reality 回落指向它 | 菜单 `9` |
| 安全写入 JSON | 在目标目录内写临时文件，校验后原子重命名 | `safe_jq_write` |
| 安全重启 | 重启前执行 `xray run -test -config`，失败则从备份回滚配置 | `safe_restart_xray` |
| 迁移 | 由标记文件驱动的一次性迁移：备份 → 修改 → 重启 → 写标记 | `run_migration` |
| geo 数据库 | 把 Loyalsoldier 发行版的 `geoip.dat` 与 `geosite.dat` 放入 `/usr/local/share/xray` | `install.sh` |

不支持也不声称支持：H2、WebSocket、SplitHTTP、Clash/mihomo 订阅。

## 工作原理

控制流。任何配置改动都走同一条路径：

```text
sudo xrayebator
      │
      ▼
xrayebator  (bash)
创建配置档 · 修改 SNI/端口/指纹 · 迁移 · 路由
      │
      ├─ backup_config ───────► /usr/local/etc/xray/backups/<timestamp>
      │
      ├─ safe_jq_write ───────► config.json  +  profiles/<name>.json
      │
      └─ safe_restart_xray
               │
               ├─ xray run -test -config  → 通过 ──► systemctl restart xray
               │
               └─ 配置无效 ───────────────────────► 从备份回滚，
                                                    Xray 继续以旧配置运行
```

客户端流。从订阅链接到访问互联网：

```text
客户端 (HAPP)
    │  https://<域名或IP>/sub/<32位十六进制令牌>
    ▼
nginx  :443  （443 被占用时为 :8443）
    │  proxy_pass
    ▼
xrayebator-sub.service   127.0.0.1:8080
    │  读取 profiles/*.json 并与运行中的 config.json 核对线路
    ▼
vless:// 列表 —— 配置档的 7 条线路中，HAPP 收到 6 条
    │
    ▼
30000-60000 端口上的 Reality 入站   (User=xray, CAP_NET_BIND_SERVICE)
    │
    ├─ 已启用分流组中的域名 ──► freedom（直连，不走 VPN）
    │
    └─ 其余全部 tcp/udp ─────► direct
                                或 cascade-upstream ──► 境外 VPS
```

### 配置档线路

HAPP 流程会创建或复用包含七条线路的配置档：

| 线路 | 传输 | 用途 |
|---|---|---|
| `xhttp-legacy` | xhttp | HAPP 兼容的 XHTTP 回落，`decryption=none`，无 PQ |
| `xhttp-pq` | xhttp | 带后量子加密 `mlkem768x25519plus` 的 XHTTP |
| `tcp-mux` | tcp | 不带 Vision flow 的 TCP Reality，独立的兼容回落 |

托管的 HAPP 配置档使用 schema version 3，包含七条线路。普通 HAPP 列表发布其中六条；PQ 线路仍可通过原始/配置档路径使用。
| `grpc` | grpc | gRPC Reality，对 HTTP/2 和 SNI 敏感 |
| `tcp-vision` | tcp | 带 `xtls-rprx-vision` 的 TCP Reality |
| `tcp-utls-firefox` | tcp | 使用 Firefox 指纹的 TCP Vision |
| `tcp-xudp` | tcp | TCP Vision + XUDP，面向恶劣移动网络的窄回落 |

七条线路中有六条进入 HAPP 订阅：当配置档中存在 `xhttp-legacy` 时，PQ-XHTTP 不会作为
XHTTP 候选下发。配置档 JSON 中仍然保留全部七条。

新建和更新配置档的默认客户端指纹为 `firefox`。若已显式选择了 `chrome` 以外的指纹，更新时会保留。

订阅中的线路顺序是稳定的，但它不是「从好到坏」的排名。传输是否可用取决于客户端、
其内置的 Xray-core 版本以及具体网络。

### 订阅发布模式

| 模式 | 结果 | 适用场景 |
|---|---|---|
| 按 VPS IP 的 public TLS | `https://<ip>/sub/<token>` | 无域名的快速启动。Let's Encrypt 的 IP 证书有效期很短，必须能自动续期 |
| 按域名的 public TLS | `https://sub.example.com/sub/<token>` | 推荐用于长期使用 |
| 仅本地调试 | `http://127.0.0.1:8080/sub/<token>` | 仅用于在 VPS 上或通过 SSH 隧道检查，手机无法直接使用 |

---

## 快速开始

### 环境要求

硬性要求是 Bash、root（或 sudo）、基于 apt 的 Debian/Ubuntu 类系统以及正常运行的 systemd。当前验证矩阵为 Debian 12/13 和 Ubuntu 22.04/24.04。

- 内存至少 512 MB，建议 1 GB 以上
- 1 核 CPU，建议 2 核以上
- 至少 1 GB 可用磁盘空间

安装脚本会安装 `ca-certificates curl wget jq qrencode uuid-runtime ufw unzip openssl socat`。

> 安装脚本检查 apt/systemd 前置条件，但不会强制版本矩阵。启用 UFW 前会检测活动 SSH 端口；如果无法确定或安全放行该端口，非活动 UFW 会保持关闭。在重要的 VPS 上安装前请先做快照。

### 安装

先下载脚本，审阅之后再以 root 运行本地文件：

```bash
curl -fsSLo ./xrayebator-install.sh \
  https://raw.githubusercontent.com/howdeploy/Xrayebator/main/install.sh
less ./xrayebator-install.sh
sudo bash ./xrayebator-install.sh
```

> 安装脚本不会更改主机 TCP 或 sysctl 设置，但会自行管理 UFW。运行前请先阅读
> [环境变量](docs/zh-CN/configuration.md#安装脚本的环境变量) 和
> [防火墙与主机网络设置](docs/zh-CN/configuration.md#防火墙与主机网络设置)，
> 尤其是当 SSH 监听在非标准端口时。

### 社区项目

- **[Xrayebator OpenWrt/Cudy companion](https://github.com/slavytich23/xrayebator-openwrt-cudy)** —
  独立的社区工具包，用于在 OpenWrt/Cudy 路由器上运行 Xray 客户端，提供分阶段启用与自动回滚、
  故障时阻断直连、隧道健康与内存监控，以及可选的 Windows 双链路故障转移。它不是 Xrayebator
  的官方组件。

### 五步完成 HAPP 订阅

1. 打开菜单：

   ```bash
   sudo xrayebator
   ```

2. 选择 `6) Подписка HAPP`，即 HAPP 订阅项。
3. 选择发布模式：按 VPS IP 无需域名、启动快；按域名适合长期使用。
4. Xrayebator 会创建 `happ` 配置档、建立入站、签发证书，并显示链接与二维码。
5. 在 HAPP 中导入订阅链接或二维码，而不是单条 `vless://` 链接。

### FAQ：线路显示绿色，但 Telegram 或其他应用无法使用

> **需要 HAPP 3.3.6 或更高版本。** 如果 Xrayebator 线路显示绿色延迟，但连接仍不可用，
> 请彻底退出所有旧的 HAPP 进程，只启动一个最新实例，然后刷新订阅。绿色延迟检测使用独立的
> 临时 Xray-core，并不能证明主 TUN 正常。在 Linux 上，`ss -lntp | grep ':10808'`
> 应当显示 HAPP 主 core 正在监听。

当前版本会发布并启用托管的 `xrayebator-default` 配置，其中使用 Global Proxy 和
Cloudflare DoH。geo 数据库通过同一个受令牌保护的订阅 URL 下载，不再要求客户端直连
GitHub。服务器更新后，请强制刷新订阅并重新连接一次；HAPP 会覆盖同名旧配置，并在两个
geo 文件下载成功后清除红色警告。测试时仍应禁用可能覆盖订阅的第三方 Routing 配置。

如需手工控制 SNI、传输方式或单条线路，请使用 `1) Создать новый профиль`。

> 终端界面为俄语。本文档逐项说明了所有菜单条目，因此界面语言不构成障碍。

---

## 桌面图形界面

除了终端菜单，还有一个可选桌面应用（Electron + React，位于 `src/`），通过 SSH 管理 VPS。
它并不替代 bash 引擎——服务器上的所有操作仍由 `xrayebator` 完成，图形界面只是通过 SSH
调用同一组命令。

```text
桌面应用 (Electron · React)
    │  SSH + 已文档化的 CLI
    ▼
xrayebator (bash)   ──►  /usr/local/etc/xray/
```

界面语言（Русский / English / 简体中文）在主屏幕页眉切换，并保存在 `localStorage` 中。
终端菜单仍为俄语。

GUI 的功能：

| 页面 | 操作 |
|---|---|
| Dashboard | 服务器卡片与连通/安装状态；空页面提供“部署新服务器”或“连接现有服务器”；语言切换 |
| 添加服务器 | 显式选择是否提供 email：`quickstart --email` 或 `quickstart --without-email`；保存服务器与公网订阅 |
| 连接现有服务器 | 通过 SSH（密码或密钥）和只读 `xrayebator inspect --json` 导入已识别的 Xrayebator；部分安装会连同诊断状态保存，不自动修复 |
| 服务器密钥 | 刷新公网订阅、复制链接、显示 `vless://` 链接与二维码 |
| 服务器设置 | 使用 SSH 密码或私钥、直接 root 或 sudo：列出/创建/删除配置档，修改指纹、SNI 和端口，以及更新或卸载服务器上的 Xrayebator |

选中的私钥与成功登录时使用过的 SSH 密码都会通过 `keytar` 保存在操作系统钥匙串中，之后的 SSH 操作和应用重启均可复用；服务器卡片只保存非敏感的 credential id 和显示文件名。单独的 sudo 密码与加密私钥口令不会持久化，需要时重新输入。系统钥匙串不可用时不会写入明文回退文件：密钥仅保留在 main process 内存中直到当前会话结束，界面会提示重启后需重新输入。应用还会保存 `subscription_url`、获取到的 `vless://` 链接和固定的 SSH host-key fingerprint。这些是 bearer/client credentials：请保护本地应用数据，泄露后通过终端 workflow 吊销订阅。

GUI 只暴露终端菜单的一个子集。bypass、`probe-test`、订阅吊销、`happ-setup`、级联、self-steal
以及服务日志/状态仍需从终端执行。完整的 Electron GUI 边界、安全模型与打包说明见
[Electron 桌面 GUI](docs/zh-CN/desktop-gui.md)。

开发模式下的构建与运行：

```bash
npm install
npm run dev          # Electron + Vite dev server
npm run build        # 编译 renderer 与 main process
```

Electron 检查：`npm test` 运行 `tests/` 中的 14 个单元测试文件；`npm run typecheck` 检查 TypeScript，
包含 `tests/type-contracts/` 中严格的 onboarding 契约；`npm run build` 构建应用。在原生 Windows 上，POSIX 专用测试
`tests/unit/shell-command.test.ts`
可能因缺少 `/bin/sh` 而失败；Linux CI 是事实来源。参见[测试](docs/zh-CN/testing.md#桌面图形界面)
和 [Electron 桌面 GUI](docs/zh-CN/desktop-gui.md)。

---

## 文档

| 文档 | 内容 |
|---|---|
| [配置](docs/zh-CN/configuration.md) | 环境变量、防火墙与主机网络设置、主菜单、命令、分流、级联、self-steal、域名与 DNS |
| [架构](docs/zh-CN/architecture.md) | 仓库结构与服务器状态目录树、入站与配置档的区别、订阅内部机制 |
| [安全](docs/zh-CN/security.md) | 服务账户与权限、订阅保护、VPS 的 SSH 访问 |
| [故障排查](docs/zh-CN/troubleshooting.md) | 订阅不刷新、XHTTP 不可用、客户端连不上等常见问题 |
| [测试](docs/zh-CN/testing.md) | 本地校验、`validation/` 覆盖范围、线上服务器的手工检查 |

英文与俄文版本分别位于 [`docs/`](docs/) 与 [`docs/ru/`](docs/ru/)。

---

## 已知限制

- 安装脚本要求 Bash、root/sudo、基于 apt 的 Debian/Ubuntu 类系统和 systemd。当前验证矩阵为
  Debian 12/13 与 Ubuntu 22.04/24.04；发行版版本不会被硬性限制。
- 启用 UFW 前，安装脚本会检测活动 SSH 端口。如果无法确定或安全放行该端口，非活动 UFW 会保持关闭。
  通过检查后才会加入固定的项目服务 TCP 端口，并把自己创建的规则记录到 `.ufw_owned`。
- `xrayebator-update` 会把检测到的 `/opt/AdGuardHome` 作为废弃组件自动删除：先把 Xray DNS
  切回 DoH，然后停止服务并删除文件。如果该 VPS 仍在使用 AdGuard Home，请不要在没有快照的情况下更新。
- 大部分 Xray 状态、配置档、标记、密钥和管理器脚本由 root 拥有；`xray` 账户读取所需文件并在
  `/var/log/xray` 写入运行时日志。`.server_country` 等生成元数据和 rollback 路径可能有不同属主/权限，
  审计时请检查具体文件。
- Xray 内核强制校验 SHA-256，而 Loyalsoldier 的 geo 数据库在下载时没有校验和。
- `xrayebator-uninstall` 会停止并禁用 `xray`，删除 `/usr/local/bin/xray` 二进制和
  `/usr/local/share/xray` 中的 geo 数据库，清除 `/usr/local/etc/xray` 与 `/var/log/xray`、
  `xrayebator`、`xrayebator-update`、`xrayebator-uninstall`、`subhttp.sh` 二进制，以及
  `xray.service`、`xray@.service`、`xray.service.d`、`xrayebator-sub.service` 单元、由它创建的
  使用其名称的 nginx vhost、它自己的 certbot 证书和 UFW 规则，还有系统用户 `xray`。nginx 清理按路径/名称执行，
  不是通过独立的 ownership manifest。全局 Certbot 状态、nginx 软件包、他人的 certbot 证书和 UFW 规则不会被动到。
  域名模式的 ACME webroot
  `/var/www/xrayebator-domain-acme` 可能保留，需要手工清理。
- `tcp-mux` 线路仅为兼容保留，它并不是 mux 预设。
- 不支持 H2、WebSocket、SplitHTTP 以及 Clash/mihomo 订阅。
- 界面没有硬性的用户数上限，但实际容量受 CPU、内存、VPS 带宽、线路数量和服务商限制约束。
- 安装程序和项目更新使用独立的校验、重启与回滚路径，不等同于运行时 `safe_restart_xray` 事务；
  lifecycle 更新后请检查 Xray、DNS 和订阅。

---

## 更新与卸载

```bash
sudo xrayebator update                  # 仅更新 Xray-core
sudo xrayebator update dev              # 从分支 self-update 管理器，然后更新内核
sudo xrayebator-update [branch]         # 完整生命周期更新；无参数时打开分支选择
sudo xrayebator-uninstall               # 移除服务与配置
```

这些名称相似的命令职责不同：

| | `sudo xrayebator update <branch>` | `sudo xrayebator-update [branch]` |
|---|---|---|
| 起点 | 已安装管理器的 self-update | 完整项目生命周期更新程序 |
| 来源 | 请求分支的 canonical raw 管理器文件 | 所选分支的 `update.sh` workflow |
| 主要结果 | 管理器 self-update，然后更新 Xray-core | 管理器脚本、数据、订阅集成和服务刷新 |
| 分支选择 | 必须显式提供分支 | 无参数时显示 `.current_branch` 后交互选择；有参数时使用该分支 |

当前分支会显示在 updater 中，并保存在 `/usr/local/etc/xray/.current_branch`，但无参数运行
`xrayebator-update` 仍会提示选择。Electron GUI 调用的是 `xrayebator update <branch>`，不是完整
项目更新程序。完成生命周期更新后，请等待迁移结束并检查 Xray、DNS 与订阅，再刷新客户端。

`xrayebator-uninstall` 之后系统里还会留下什么，见 [已知限制](#已知限制)。

---

## 客户端

请在客户端导入订阅链接，而不是单条 `vless://` 链接。
`3) Подключиться по профилю` 给出的原始线路用于诊断。

| 客户端 | 状态 | 说明 |
|---|---|---|
| HAPP | 推荐 | 目标客户端。支持按链接和二维码添加订阅，也支持 VLESS 链接 |
| v2rayNG | 部分支持 | 接收 base64 订阅，不使用 HAPP 元数据 |
| v2rayN | 部分支持 | 支持 VLESS 订阅，不使用 HAPP 专有字段 |
| Shadowrocket | 手工 | 适合原始 VLESS，不是订阅流程的主力客户端 |
| sing-box · Hiddify · NekoBox · mihomo | 非目标 | 不要指望 PQ-XHTTP 与 HAPP 路由 |

- Android：[HAPP](https://www.happ.su/) · [v2rayNG](https://github.com/2dust/v2rayNG) · [NekoBox](https://github.com/MatsuriDayo/NekoBoxForAndroid)
- iOS：[HAPP](https://www.happ.su/) · [Shadowrocket](https://apps.apple.com/app/shadowrocket/id932747118) · [V2Box](https://apps.apple.com/app/v2box-v2ray-client/id6446814690)
- Windows：[Throne](https://github.com/throneproj/Throne) · [v2rayN](https://github.com/2dust/v2rayN) · [NekoRay](https://github.com/MatsuriDayo/nekoray)
- macOS：[Throne](https://github.com/throneproj/Throne) · [V2RayXS](https://github.com/tzmax/V2RayXS) · [Qv2ray](https://github.com/Qv2ray/Qv2ray)
- Linux：[Throne](https://github.com/throneproj/Throne) · [v2rayA](https://github.com/v2rayA/v2rayA) · [Qv2ray](https://github.com/Qv2ray/Qv2ray)

客户端文档：[HAPP 订阅](https://www.happ.su/main/faq/adding-configuration-subscription) ·
[v2rayN 订阅格式](https://github.com/2dust/v2rayN/wiki/Description-of-subscription)

---

## 许可证

MIT，详见 [LICENSE](LICENSE) 文件。

## 致谢

- [XTLS/Xray-core](https://github.com/XTLS/Xray-core) —— 提供协议。
- [HAPP](https://www.happ.su/) —— 提供目标客户端与订阅格式。
- [2dust/v2rayNG](https://github.com/2dust/v2rayNG) 与 [2dust/v2rayN](https://github.com/2dust/v2rayN) —— 提供客户端与订阅格式。
- [Loyalsoldier/v2ray-rules-dat](https://github.com/Loyalsoldier/v2ray-rules-dat) —— 提供扩展 geo 数据库。
- [Umalanif/xray-server-setup](https://github.com/Umalanif/xray-server-setup) —— 提供 uTLS 参考与自动化思路。
- [ServerTechnologies/simple-xray-core](https://github.com/ServerTechnologies/simple-xray-core) —— 提供快速部署方案。
- 社区 —— 提供支持与测试。

## 支持项目

在 GitHub 上点一个 star 是最简单的支持方式。

捐赠：

```text
EVM     0x7acE4442b92f2769c24484c78A13024B139E1A5b
Solana  FS9RBrG5yXJty3WNWgkBkfai6BfNoYxGMFeH1LQEpRZr
TON     UQA56zsOv3zvU5x-p7iNNDL8jHh9dt7Q7WlY_gfbaj4ZhcyT
BTC     34EznmkBGpBu4dUnzoHL5GBnpg2Rq86v4H
```

---

<div align="center">
<strong>为自由的互联网而作</strong>
</div>
