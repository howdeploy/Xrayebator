# 安全

[← 返回 README](../../README.zh-CN.md) · [English](../security.md) · [Русский](../ru/security.md)

章节：[服务账户与权限](#服务账户与权限) · [订阅安全](#订阅安全) · [VPS 的 SSH 访问](#vps-的-ssh-访问) ·
[桌面 GUI 凭据](#桌面-gui-凭据)

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
受令牌保护的订阅资源。

服务端已经处理：

- 32 位十六进制令牌，由 `openssl rand -hex 16` 生成；
- 没有有效令牌访问 `/sub/` 一律返回相同的 `404`；
- 没有活跃线路的配置档返回 `410`，不提供线路；
- nginx 添加 `Cache-Control: no-store`，并为订阅 location 限流；
- 根路径与 `/sub/` 之外的路径返回 `404`；
- `Revoke` 轮换 `sub_token`，旧 URL 失效。

运维人员需要注意：

- 不要把 `subscription_url` 发布到公开聊天或 issue tracker；
- 泄露后立即点击 `Revoke`；
- 把每条保存的 `vless://` 链接也视为 credential；
- 不要把 local-only URL 交给外部客户端；
- 没有理解 nginx 配置前，不要在同一域名上托管第三方面板或代理。

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

## 桌面 GUI 凭据

活跃的 Electron GUI 支持 SSH 密码和私钥，并可选择直接 root 或 sudo。通过 Electron 原生文件对话框选择的私钥由 main process 读取，并通过 `keytar` 保存到操作系统钥匙串（Windows Credential Manager、macOS Keychain 或 Linux Secret Service），因此后续 SSH 操作和应用重启后都可以复用。Renderer 只收到非敏感 credential id 和显示文件名；私钥字节不会跨越 preload boundary。

如果系统钥匙串不可用，应用不会在磁盘上保存明文回退副本：密钥只保留在 main process 内存中直到应用退出，界面会提示重启后需要重新选择。SSH 登录密码仅在首次成功登录后保存到系统钥匙串并可继续复用；单独的 sudo 密码和加密私钥口令不持久化，需要时重新输入。

GUI 会保存返回服务器所需的元数据：主机、SSH 端口、用户名、认证方式、权限模式、credential id（密码与私钥）、密钥显示名、安装诊断、偏好、`subscription_url`、获取到的 `vless://` 链接以及 SHA-256 SSH host-key pin。订阅 URL 和 VLESS 链接是 bearer credentials，因此请保护本地 Electron 应用数据，泄露后吊销订阅。删除最后一张引用某 credential 的服务器卡片时会删除钥匙串记录；若其他卡片仍引用则保留。

SSH 导入只识别 Xrayebator，并默认只执行只读诊断；部分配置的服务器会按实际状态导入，不会自动修复。部署时 email 可选；不填写时 Certbot 使用 `--register-unsafely-without-email`，因此没有续期通知和 ACME 账户邮箱恢复，GUI 会在部署前说明。

SSH host key 在首次成功认证后按 TOFU 固定。之后指纹不匹配时，会在执行命令前失败。有意重装 VPS 后，在 Server Settings 中显式重置 pin，并在下一次成功连接时确认新密钥。

参见 [Electron 桌面 GUI](desktop-gui.md) 了解完整的 Electron 边界、命令适配器和打包详情。