# 安全

[← 返回 README](../../README.zh-CN.md) · [English](../security.md) · [Русский](../ru/security.md)

章节：[服务账户与权限](#服务账户与权限) · [订阅安全](#订阅安全) · [VPS 的 SSH 访问](#vps-的-ssh-访问) ·
[Linux 内核与网络栈](#linux-内核与网络栈-cve-2026-98432) · [桌面 GUI 凭据](#桌面-gui-凭据)

---

## 服务账户与权限

Xray 以系统用户 `xray` 运行。Drop-in
`/etc/systemd/system/xray.service.d/security.conf` 设置 `User=xray`，并把能力集收窄为
`CAP_NET_BIND_SERVICE`，这足以绑定低端口。管理器状态被有意放在服务账户的写入边界之外。

权限模型如下：

| 路径或类别 | 属主与访问权限 |
|---|---|
| `/usr/local/etc/xray/` 及其状态目录 | 大部分由 root 拥有且服务不可写；`.server_country` 等生成元数据可能由 `xray` 拥有 |
| `config.json`、配置档与迁移标记 | 通常为 `root:root`，按 Xray 需要可读；rollback 可能使 live config 变为 `root:xray`、`0640` |
| Reality 与 VLESS 私钥 | `root:root`，权限 `0600` |
| 公钥文件与生成的元数据 | 在服务或订阅处理器需要时可读；生成元数据的属主可能不同 |
| `/usr/local/etc/xray/scripts/` 与 `/usr/local/bin/xrayebator*` | `root:root`，由 root 管理的可执行脚本 |
| `/var/log/xray/` | 由 Xray 运行时账户写入服务日志 |

服务账户可以读取所需配置，但不能替换配置档、标记、root 脚本或私钥。备份由 root 拥有，
并与 live 文件分开保存。某些生成的元数据（例如 `.server_country`）可能由 helper 以 xray
属主创建；rollback 路径也可能使 live config 变为 `root:xray`。审计时请检查具体文件，
不要在 Xray 状态目录放置无关机密。

由 `xrayebator` 执行的运行时改动使用备份、经过验证的原子写入和 `safe_restart_xray` 事务。
安装程序和项目更新程序是独立的生命周期程序，有自己的校验与重启/回滚步骤，因此不能声称
每条生命周期路径都会调用 `safe_restart_xray`。

## 订阅安全

订阅 URL 是 bearer credential。它不是公开信息，但持有完整 URL 的任何人都可以下载线路列表和
受令牌保护的订阅资源。因此桌面 GUI 会在 URL 进入任何控制台（部署日志和导入向导控制台）之前
遮蔽令牌（`…`）；密码和私钥字节完全不会写入其中。

服务端已经处理：

- 32 位十六进制令牌，由 `openssl rand -hex 16` 生成；
- 没有有效令牌访问 `/sub/` 一律返回相同的 `404`；
- 没有活跃线路的配置档返回 `410`，不提供线路；部分过期的多线路配置档仍可能以 `200` 返回剩余线路；
- 已过期或被停用的配置档同样返回 `410 Gone`（`Profile expired or disabled`），完全不提供线路——即使用户端尚未刷新订阅；
- nginx 添加 `Cache-Control: no-store`，并为订阅 location 限流；
- 根路径与 `/sub/` 之外的路径返回 `404`；
- `Revoke` 轮换 `sub_token`，旧 URL 失效；完全吊销（`profile-revoke --full`）还会更换该配置档所有 inbound 中的 uuid，因此已下载的配置无法再连接。

运维人员需要注意：

- 不要把 `subscription_url` 发布到公开聊天或 issue tracker；
- 泄露后立即点击 `Revoke`；
- 把每条保存的 `vless://` 链接也视为 credential；
- 不要把 local-only URL 交给外部客户端；
- 没有理解 nginx 配置前，不要在同一域名上托管第三方面板或代理。

## 多协议后端安全

可选后端（Hysteria 2、AmneziaWG）遵循与 Xray 服务相同的信任模型，并按后端细化：

| 路径或类别 | 属主与权限 |
|---|---|
| `/usr/local/etc/xrayebator/backends.json` | `root:root 644` —— 刻意不含机密（只有端口、版本、开关）；`xray` 服务账户在订阅处理器中读取它 |
| `/usr/local/etc/xrayebator/backends/hysteria/` | `root:hysteria 750`；`server.yaml` 与证书 `0640 root:hysteria` —— 服务必须能读，其他任何人不触碰 |
| `/usr/local/etc/xrayebator/backends/awg/` | `root:root 700`；`awg0.conf` 与 `server-params.json` 为 `0600` —— 服务器私钥与 peer 机密 |
| Hysteria 占位凭据 | `_xrayebator_placeholder`，随机密码存于 `0600` 文件；仅用于避免空 auth 映射，不签发给任何客户端 |
| certbot 续期 deploy-hook | `/etc/letsencrypt/renewal-hooks/deploy/xrayebator-hysteria.sh`，root `0755`；把续期后的证书复制进后端目录并重启后端 |
| `/etc/amnezia/amneziawg/awg0.conf` | 指向受管文件的 symlink —— 发行版 `awg-quick@awg0` 单元经它读取；不存在第二份配置副本 |

Hysteria 以专用用户 `hysteria` 运行，带 `AmbientCapabilities=CAP_NET_BIND_SERVICE` 与
`NoNewPrivileges=true`；QUIC 缓冲 sysctl 位于 `/etc/sysctl.d/99-xrayebator-hysteria.conf`。
AmneziaWG 需要 `net.ipv4.ip_forward=1`（独立 sysctl 文件），并通过接口配置的
`PostUp`/`PostDown` 添加作用于后端子网的 MASQUERADE/FORWARD 规则。后端仅在操作者显式操作时
安装，通过对应 `*-uninstall` 命令移除；`uninstall.sh` 不参与此流程。

## VPS 的 SSH 访问

Xrayebator 可以直接以 `root` 安装，但更好的做法是使用权限范围受限的独立用户。

在服务器上：

```bash
adduser <username>
usermod -aG sudo <username>
su - <username>
```

在自己的电脑上：

```bash
ssh-keygen -t ed25519 -C <your_email@example.com>
ssh-copy-id <username>@<服务器IP>
```

然后以 `<username>@<服务器IP>` 登录。确认密钥登录可用后，关闭密码登录并视需要禁止 root 登录：

```bash
sudo nano /etc/ssh/sshd_config
```

```text
PermitRootLogin no
PasswordAuthentication no
PubkeyAuthentication yes
```

> 丢失 SSH 密钥就等于失去服务器访问权限。先确认密钥登录正常，再关闭密码登录。

为了让 SSH 会话在配置 VPN 期间不断开，keep-alive 很有用：

```text
ClientAliveInterval 60
ClientAliveCountMax 120
TCPKeepAlive yes
```

### 防爆破保护（fail2ban）

公开 VPS 的 SSH 端口会被持续扫描。实测数据（2026-10-23）：**24 小时 9 953 次失败登录，来自 115 个
地址**——其中 6 个 `109.160.32.0/24` 地址各尝试 1 197 次，而 `root` 当时允许用密码登录。

`sudo xrayebator ssh-protect --enable` 在不把运营者锁在门外的前提下堵住这个洞：

- 安装 `fail2ban` 并启用 `sshd` 规则——journald 后端，`findtime = 10m` 内 `maxretry = 4`，
  `bantime = 30m`，另加 `bantime.increment`（屡犯最长一天）；所有参数都位于 `[sshd]` 段内，
  因此运营者已有的其他 fail2ban 规则保持原有默认值；
- 写入 `/etc/ssh/sshd_config.d/99-xrayebator-hardening.conf`（`MaxAuthTries 3` /
  `LoginGraceTime 30`）——单个连接内尝试次数更少，可用时间也更短；
- 应用前用 `sshd -t` 校验 drop-in，并且只 `reload` 而不 `restart`，因此已打开的会话（包括 GUI
  正在使用的那个）不会被断开。

执行安装或部署的地址**在 24 小时内免于封禁**：它连同 `# xrayebator-ignore-until: <epoch>` 一起写入
`ignoreip`，而 `xrayebator-ssh-ignoreip.timer`（每 30 分钟、开机后 10 分钟）调用
`ssh-protect --prune-ignore`，到期后移除该记录。因此连续输错不会把运营者——以及从同一地址访问的
GUI——锁在外面 30 分钟，而其他人仍会被过滤。该例外可在 `ssh-protect --status` 的
`ignore_ip` / `ignore_until` 中查看；回环基线 `ignoreip = 127.0.0.1/8 ::1` 永久保留。这是命令行与
JSON 的细节，桌面 GUI 不展示。

**密码登录被有意保留。** 桌面应用以 `root` 身份通过 SSH 密码管理服务器（`authMethod: password`）；
改用密钥属于运营者的独立决定，该路径已在上文描述。即便改用密钥，也建议保留 `fail2ban`：它没有
代价，还能清掉日志噪音。

同一功能也可通过菜单第 `15` 项、GUI 的**安全与 TLS**选项卡使用，并且会自动启用：`install.sh` 与
`quickstart` 在每次部署时都会开启。没有 `apt` 或 `systemd` 的主机上，命令返回 `supported: false`
且不做任何修改。

多次输错后解封自己的地址：

```bash
sudo xrayebator ssh-protect --unban <IP>
```

没有 SSH 访问时封禁会自行过期（30 分钟，屡犯更久），而且托管商控制台始终可用。

## Linux 内核与网络栈 (CVE-2026-98432)

2026 年 10 月 15 日，Linux 内核修复了 IPv4 选项处理中的 use-after-free（上游 `e3f33b0a1d89`，
「ipv4: free inet_opt and ireq_opt after an RCU grace period」）：重传的 SYN 与 SYNACK 并发时，
已释放的 `inet_opt`/`ireq_opt` 仍可被访问，`ip_options_build()` 会再读一次。NVD 评分
**9.8，critical**（`AV:N/AC:L/PR:N/UI:N`），受影响的**所有** IPv4 TCP 监听套接字——Xray、
nginx、sshd 都一样。因此它无法在代理管理器内部修复；我们能控制的是以下两个面。

**1. MPTCP 监听。** Go 1.24+ 默认开启 MPTCP，而目前公开描述的利用方式（Anthropic 的，
尚未发布）正是通过 multipath TCP 套接字拿到 root。Xray-core 在 **26.10.31** 中不再于
`DefaultListener` 启用 MPTCP（上游 PR #7291）；服务器侧 `xrayebator` 在内核里关闭它：
`/etc/sysctl.d/99-xrayebator-netguard.conf` 中的 `net.mptcp.enabled = 0`，由迁移
`netguard_mptcp_2026` 应用。整个协议栈都不使用 MPTCP——VLESS/Reality 是 TCP，Hysteria 2 与
AmneziaWG 是 UDP——所以线路行为不变。

**2. 带 IPv4 选项的入站报文**（`IHL > 5`）。这正是漏洞代码解析的报文，而 VPN、nginx 与 sshd
都不使用 IPv4 选项。该规则取自 Ubuntu 安全团队公布的缓解措施，落在独立的 nftables 表中，并有
自己的开机单元。反过来启用 `nftables.service` 会是陷阱：默认的 `/etc/nftables.conf` 以
`flush ruleset` 开头，开机时会清掉 UFW 的规则集。

与 MPTCP 开关不同，这一层需要显式开启——它改变服务器到底接受哪些报文，所以不会在背后替您打开：

```bash
sudo xrayebator kernel-guard --status    # JSON 事实（内核、MPTCP、nft 规则、Xray 版本）
sudo xrayebator kernel-guard --enable    # 关闭 MPTCP + 丢弃带 IP 选项的入站 IPv4 报文
sudo xrayebator kernel-guard --disable   # 撤销两项改动
```

如果系统里没有 `nft`（精简镜像会出现：UFW 装了，但没有 `nftables` 包），`--enable` 会关闭 MPTCP，并
如实返回 `partial: true` 与「未启用 IPv4 选项丢弃」的警告。安装该包（`apt install nftables`）后重新
执行即可——命令是幂等的。

它**不是**什么：内核更新。丢弃 IPv4 选项只是缩小攻击面，真正的修复是打好补丁的内核包。截至
2026 年 11 月 2 日，Ubuntu 的修复只在 `-proposed` 口袋（jammy `5.15.0-203.213`、noble
`6.8.0-149.149`），`-updates` 里还没有，所以请把 `uname -r` 与当前公告对照，而不是假定
unattended-upgrades 已经装上。`kernel-guard --status` 会报告运行中的内核、「已安装更新的内核但
未启动」（`newer_kernel_installed`）以及是否需要重启——有意不硬编码版本表，因为版本表过时的
速度比它帮忙的速度更快。

为公平起见还有一点：MPTCP 维护者反对在代理里关闭 MPTCP，因为这会牺牲能从 MPTCP 获益的客户端。
我们跟随 Xray 的决定，把它作为纵深防御的一层，而不是内核更新的替代品。

## 桌面 GUI 凭据

活跃的 Electron GUI 支持 SSH 密码和私钥，并可选择直接 root 或 sudo。通过 Electron 原生文件对话框选择的私钥由 main process 读取，并通过 `keytar` 保存到操作系统钥匙串（Windows Credential Manager、macOS Keychain 或 Linux Secret Service），因此后续 SSH 操作和应用重启后都可以复用。Renderer 只收到非敏感 credential id 和显示文件名；私钥字节不会跨越 preload boundary。

如果系统钥匙串不可用，应用不会在磁盘上保存明文回退副本：密钥只保留在 main process 内存中直到应用退出，界面会提示重启后需要重新选择。SSH 登录密码仅在首次成功登录后保存到系统钥匙串并可继续复用；单独的 sudo 密码和加密私钥口令不持久化，需要时重新输入。

GUI 会保存返回服务器所需的元数据：主机、SSH 端口、用户名、认证方式、权限模式、credential id（密码与私钥）、密钥显示名、安装诊断、偏好、`subscription_url`、获取到的 `vless://` 链接、Hysteria 2 链接、AWG 客户端配置、Clash/sing-box 链接、各配置档的有效期以及 SHA-256 SSH host-key pin（后四组的存在是为了让「密钥」页面瞬时渲染，而不必等待 SSH 往返）。订阅 URL、VLESS 链接、Hysteria 2 链接与 AWG 配置是 bearer credentials，因此请保护本地 Electron 应用数据，泄露后在服务器设置中吊销订阅（完全吊销会同时更换客户端密钥，已下载的配置随即失效）。删除最后一张引用某 credential 的服务器卡片时会删除钥匙串记录；若其他卡片仍引用则保留。

SSH 导入只识别 Xrayebator，并默认只执行只读诊断；部分配置的服务器会按实际状态导入，不会自动修复。部署时 email 可选；不填写时 Certbot 使用 `--register-unsafely-without-email`，因此没有续期通知和 ACME 账户邮箱恢复，GUI 会在部署前说明。

SSH host key 在首次成功认证后按 TOFU 固定。之后指纹不匹配时，会在执行命令前失败。有意重装 VPS 后，在 Server Settings 中显式重置 pin，并在下一次成功连接时确认新密钥。

参见 [Electron 桌面 GUI](desktop-gui.md) 了解完整的 Electron 边界、命令适配器和打包详情。