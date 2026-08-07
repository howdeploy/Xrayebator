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
Xrayebator 安装 Xray-core，在随机端口上建立 Reality 入站，创建包含七条线路的配置档，
并通过一条 HTTPS 订阅链接交付给客户端。当前版本线为 3.0。
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
- 任何配置改动都经过备份、`xray run -test` 校验和自动回滚，失败的改动不会让服务器失去 VPN；
- 更换 SNI、端口或指纹都不需要重建配置档。

本项目由一个人开发和测试。由此带来的限制都直接写在
[已知限制](#已知限制) 一节，请在正式 VPS 上安装前先阅读。

## 能力一览

| 能力 | 作用 | 实现位置 |
|---|---|---|
| 安装 Xray-core | 从 GitHub 下载发行版，强制用 `.dgst` 校验 SHA-256，通过 `install -m 755` 安装二进制并自检 | `install.sh` |
| Reality 入站 | 在 `30000-60000` 的空闲端口上建立入站，同时核对 `config.json` 与实际监听的套接字 | `xrayebator` |
| 多线路配置档 | 一个配置档 = 共享 `sub_token` 的一组线路；多个配置档可共用同一端口 | `profiles/<name>.json` |
| HAPP 订阅 | 本地 HTTP 服务提供 `vless://` 列表和 HAPP 元数据，由 nginx 通过 HTTPS 对外发布 | `subhttp.sh`、`xrayebator-sub.service` |
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

- 具备 `root` 或 `sudo` 权限的 VPS，系统为 Debian 12/13 或 Ubuntu 22.04/24.04 LTS
- 内存至少 512 MB，建议 1 GB 以上
- 1 核 CPU，建议 2 核以上
- 至少 1 GB 可用磁盘空间

安装脚本会安装 `ca-certificates curl wget jq qrencode uuid-runtime ufw unzip openssl socat`。

> 安装脚本并不检查系统版本，上述矩阵只是声明的支持范围，并非强制校验。项目主要在 Debian 上做实测。
> 在重要的 VPS 上安装前请先做快照。

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

还要检查 HAPP 中当前启用的 **Routing** 配置。其他付费 VPN 遗留的路由配置可能覆盖
Xrayebator，把 Telegram 直接发送而不经过 VPS，即使线路延迟仍显示绿色。请禁用第三方
Routing 并使用 Global Proxy；如果存在 `xrayebator-default`，也可以选择该配置。
尤其不要使用 `globalProxy: false` 且没有 Telegram 专用代理规则的配置。

如需手工控制 SNI、传输方式或单条线路，请使用 `1) Создать новый профиль`。

> 终端界面为俄语。本文档逐项说明了所有菜单条目，因此界面语言不构成障碍。

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

- 安装脚本会通过 `ufw --force enable` 启用 UFW，并开放固定的十一个端口。非标准端口上的 SSH
  不在该列表中。
- `xrayebator-update` 会把检测到的 `/opt/AdGuardHome` 作为废弃组件自动删除：先把 Xray DNS
  切回 DoH，然后停止服务并删除文件。如果该 VPS 仍在使用 AdGuard Home，请不要在没有快照的情况下更新。
- `/usr/local/etc/xray/` 整个目录属于 `xray:xray`，且 `config.json` 权限为 `0644`：
  服务账户可以写入自己的配置与配置档。
- 安装脚本不检查系统版本。支持矩阵只是声明，并非强制。
- Xray 内核强制校验 SHA-256，而 Loyalsoldier 的 geo 数据库在下载时没有校验和。
- `xrayebator-uninstall` 并不会清理干净。它停止并禁用 `xray`，删除 `/usr/local/etc/xray`、
  `/usr/local/bin/xrayebator` 以及 `xray.service` 和 `xray@.service` 单元。它不会删除
  `/usr/local/bin/xray` 二进制、`subhttp`、`xrayebator-update`、`xrayebator-uninstall`、
  `xrayebator-sub.service` 单元、nginx 配置、geo 数据库、UFW 规则以及系统用户 `xray`。
  残留需要手工清理。
- `tcp-mux` 线路仅为兼容保留，它并不是 mux 预设。
- 不支持 H2、WebSocket、SplitHTTP 以及 Clash/mihomo 订阅。
- 界面没有硬性的用户数上限，但实际容量受 CPU、内存、VPS 带宽、线路数量和服务商限制约束。

---

## 更新与卸载

```bash
sudo xrayebator update            # 仅更新 Xray-core
sudo xrayebator-update            # 更新 Xrayebator 本身，分支取自 .current_branch
sudo xrayebator-update main       # 更新 Xrayebator 本身，强制使用 main 分支
sudo xrayebator-uninstall         # 移除服务与配置
```

两条命令名字相近，含义完全不同：

| | `sudo xrayebator update` | `sudo xrayebator-update main` |
|---|---|---|
| 更新对象 | Xray-core 二进制 | Xrayebator 脚本本身 |
| 来源 | XTLS 项目的 GitHub Releases | 本仓库的 `main` 分支 |
| 参数 | 不接受参数 | 接受分支名：`main`、`dev`、`experimental` 或其他 |
| 影响 | 内核版本、传输方式、协议 | 菜单、迁移、订阅生成 |
| 副作用 | 配置校验后重启 Xray | 下次打开菜单时执行迁移 |

所选分支记录在 `/usr/local/etc/xray/.current_branch`，并显示在菜单标题处。
更新 Xrayebator 本身之后，第一次运行 `sudo xrayebator` 会执行迁移：等它结束后再刷新客户端订阅。

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
