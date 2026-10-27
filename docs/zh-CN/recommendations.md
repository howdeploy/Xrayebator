# 建议：VPS、域名与 DNS

[← 返回 README](../../README.zh-CN.md) · [English](../recommendations.md) · [Русский](../ru/recommendations.md)

章节：[选择 VPS](#选择-vps) · [域名与 DNS](#域名与-dns) · [Cloudflare 步骤](#cloudflare-步骤) ·
[Route 53 步骤](#route-53-步骤) · [检查域名](#检查域名) · [客户端](#客户端) · [本文不包含什么](#本文不包含什么)

---

本文讲的是 Xrayebator 周围的基础设施，而不是它的命令：什么样的服务器合适、如何获得域名，以及如何
配置 DNS 让证书顺利签发。命令与参数见[配置](configuration.md)。

## 选择 VPS

我们刻意不推荐主机商：价格、网段和条款的变化比我们的发布周期更快，而带推广链接的"推荐"已经不是推荐。
下面是判断一台服务器是否合适的客观标准。

### 硬性要求

| 要求 | 原因 |
|---|---|
| Debian 12/13 或 Ubuntu 22.04/24.04 | 唯一验证过的矩阵；其他系统上 `install.sh` 会拒绝运行 |
| `systemd` | `xray` 单元、`xrayebator-sub.service`、`expire`/`traffic`/`monitor` 定时器 |
| root 或 `sudo` | 安装软件包、单元、`ufw` 规则 |
| `x86_64`/`amd64` 或 `aarch64`/`arm64` | 其他架构在安装第一步就会被拒绝 |
| 公网 IPv4 | 按 IP 的订阅模式；只有 IPv6 的服务器只能使用域名 |
| KVM 而不是 OpenVZ/LXC | AmneziaWG 是通过 DKMS 构建的内核模块；无法访问内核的容器装不上该后端 |

没有 `systemd` 的容器会被直接拒绝：半配置的服务器比未配置的更糟。

### 内核与 AmneziaWG

`amneziawg` 模块通过 DKMS 构建，因此需要当前内核的头文件（`linux-headers-$(uname -r)`）。Debian 12
默认不装它们——后端安装流程会补上，但并不总有精确匹配：如果运行中的内核比仓库里的更旧，模块会针对更新的
内核构建，安装返回 `reboot_required: true`。这不是错误，而是需要重启：重启后重新执行 `awg-install`。

实用结论：选择内核可以升级的服务器。把内核冻结在旧 LTS 版本、又不提供对应头文件的主机商，会让
AmneziaWG 变成抽奖。

### 资源

| 参数 | 最低配置 | 中等配置 |
|---|---|---|
| CPU | 1 vCPU | 2 vCPU |
| RAM | 1 GB | 2–4 GB |
| 磁盘 | 10 GB | 15–20 GB |
| 设备数 | 6–8 | 8–20 |
| 带宽 | 100 Mbit/s | 300 Mbit/s |

最低配置经过实测：在 1 vCPU 与 1 GB 上同时运行 Xray、nginx、Hysteria 2 与 AmneziaWG（生产环境有 4 个
配置档与 13 个入站，占用 ~224 MB 内存与 5 GB 磁盘）。中等配置是推荐值，我们没有在它上面测试过。

设备数是来自运维经验的参考值，不是实测值；带宽一行是推荐值，链路更窄时带宽会比 CPU 更早成为瓶颈。
Xray 本身只占 ~54 MB。

### 付款前要确认的事

- IPv4 与 SSH 从**你自己的网络**可达，而不只是主机商面板里显示的；
- 端口 `80` 与 `443` 没有被过滤：`nc -vz <ip> 80`、`nc -vz <ip> 443`；
- UDP 不是"尽力而为"——需要 Hysteria 2 就向客服确认；
- 有快照或备份：安装过程会改动 `ufw`、`sysctl`、`nginx` 并安装软件包；
- 重装系统会抹掉密钥、订阅标记和配置档——之后服务器需要重新配置（`xrayebator inspect --json` 可以
  看出还有什么留了下来）；
- 公网 VPS 的 SSH 一直被人爆破。`xrayebator ssh-protect` 会在安装和部署时自动启用 `fail2ban` 与
  `sshd` 限制；细节见[安全](security.md)。

## 域名与 DNS

域名有三个用途：带有效证书的 HTTPS 订阅（客户端不会报警）、self-steal 伪装成自己的网站，以及在主机商
过滤 `80/tcp` 时用 DNS-01 签发证书。

| 路径 | 需要什么 | 费用 | 端口 `80` | `dns01-setup` |
|---|---|---|---|---|
| A. 按 IP 使用服务器 | 什么都不需要 | 0 | 签发 IP 证书时需要 | 不需要 |
| B. 免费子域名 | 子域名服务商账号、一条 A 记录 | 0 | 需要 | **不支持** |
| C. 自己的域名放在 Cloudflare | 域名、免费的 Cloudflare 区域、API 令牌 | 域名付费，DNS 免费 | 不需要 | `--provider cloudflare` |
| D. 自己的域名放在 Route 53 | 绑卡的 AWS 账号、hosted zone、IAM 密钥 | 付费：区域与查询 | 不需要 | `--provider route53` |

`dns01-setup` 只支持两个服务商。这是有意的限制：我们不会在用户服务器上安装任意 certbot 插件。如果你的
DNS 服务商既不是 Cloudflare 也不是 Route 53，那么可用的是路径 A 和 B——通过 `80/tcp`。

### 路径 A：完全不用域名

订阅按 IP 发布：`https://<ip>/sub/<token>`，证书签发给 IP 地址。这是最快的起步方式，且完全受支持——
只有当你想有人可读的地址，或 `80/tcp` 被关闭且又不打算配置 DNS-01 时才需要域名。

### 路径 B：免费子域名

提供免费子域名的例如 [DuckDNS](https://www.duckdns.org) 和 [FreeDNS](https://freedns.afraid.org)。
步骤相同：

1. 注册并创建子域名，例如 `myvpn` → `myvpn.duckdns.org`；
2. 用 A 记录把它指向服务器 IPv4（DuckDNS 在首页或其 API 中设置）；
3. 验证：`dig +short myvpn.duckdns.org` 应返回服务器地址；
4. 配置订阅时填入这个域名——证书通过 http-01 签发，因此 `80/tcp` 必须对外可达。

需要提前知道的限制：`dns01-setup` 对这类子域名**不会**成功——区域属于服务商而不是你，也就无法为其签发
API 令牌。

### 路径 C 与 D：自己的域名

不需要昂贵的域名：任何通过认证的注册商、你喜欢区域里最便宜的域名都够用。域名也可以直接在
[Cloudflare Registrar](https://dash.cloudflare.com) 注册——按成本价、无加价；此时区域会立即落在
Cloudflare，名称服务器那一步可以跳过。

两条路径共同的要求：

- `sub` 记录（或根域）指向服务器 IPv4。只有当服务器上的 IPv6 确实可用时才加 `AAAA`——否则客户端会拿到
  一条死路；
- DNS 不是瞬间生效的：从几分钟到一小时，有时更久。在 `dig +short` 返回预期地址之前，不要开始签发证书；
- 在 Cloudflare 中，指向服务器的记录请设为 **Proxy status: DNS only**。代理会破坏 http-01，并在客户端
  与 Reality 之间多加一层，而这层我们并不需要。

## Cloudflare 步骤

路径 C。所有需要的东西都在 Cloudflare 免费方案内：只有域名本身要付钱。

1. 创建账号：<https://dash.cloudflare.com/sign-up>。
2. **Add a site** → 你的域名 → **Free** 方案 → Cloudflare 会给出两个名称服务器。
3. 在注册商处把 NS 换成这两个。如果此前启用了 DNSSEC，请先在注册商处关闭，否则 NS 变更不会生效。
4. 等待面板中出现 **Active** 状态。验证：`dig +short NS example.com` 应显示 Cloudflare 的名称服务器。
5. **DNS → Records → Add record**：类型 `A`，name `sub`（根域用 `@`），服务器 IPv4，
   **Proxy status — DNS only**。
6. API 令牌：<https://dash.cloudflare.com/profile/api-tokens> → **Create Token** → 模板
   **Edit zone DNS** → **Zone Resources**：`Include` → `Specific zone` → 你的域名 →
   **Continue to summary** → **Create Token**。密钥只显示一次，请存进密码管理器。
7. 验证令牌，同时避免它进入命令历史：

   ```bash
   read -rs CF_API_TOKEN && export CF_API_TOKEN
   curl -sS -H "Authorization: Bearer $CF_API_TOKEN" \
     https://api.cloudflare.com/client/v4/user/tokens/verify
   ```

8. 在服务器上配置订阅：

   ```bash
   sudo xrayebator dns01-setup --domain sub.example.com --provider cloudflare \
     --token "$CF_API_TOKEN" --email admin@example.com
   ```

9. 检查结果：`sudo xrayebator dns01-status`——服务商、域名、端口、证书有效期以及 deploy hook 是否存在。
10. 续期由标准的 `certbot.timer` 与 deploy hook 完成，不需要额外的定时器。

顺带有用的命令：

- `dns01-test` 在 staging 环境、独立的证书线路上验证"域名 + 令牌"这一组合，不发布任何东西：
  `sudo xrayebator dns01-test --domain sub.example.com --provider cloudflare --token "$CF_API_TOKEN"`
- Let's Encrypt 有配额：同一组名称每 168 小时五个证书，每个名称每小时五次失败的校验。调试时请给
  `dns01-setup`/`repair-dns01` 加 `--staging`，否则可能把自己的签发堵上几个小时。

## Route 53 步骤

路径 D。与 Cloudflare 不同，这里没有免费额度：AWS 对每个 hosted zone 和查询都收费。当前价格见
<https://aws.amazon.com/route53/pricing/>；至少要把每月的区域费用算进去。

1. AWS 账号：<https://aws.amazon.com>。需要绑定银行卡。
2. **Route 53 → Hosted zones → Create hosted zone** → 你的域名 → 类型 **Public** → 创建。AWS 会给出四个
   名称服务器。
3. 在注册商处填写这些 NS 并等待生效：`dig +short NS example.com`。
4. **DNS → Records → Create record**：`A`，name `sub`（根域留空），服务器 IPv4。
5. **IAM → Users → Create user**，不授予控制台访问 → **Access key** → 保存密钥对。
6. 只给所需的最小权限——仅限需要的区域：

   ```json
   {
     "Version": "2012-10-17",
     "Statement": [
       {
         "Effect": "Allow",
         "Action": ["route53:ChangeResourceRecordSets", "route53:ListHostedZones"],
         "Resource": "*"
       },
       {
         "Effect": "Allow",
         "Action": ["route53:GetChange"],
         "Resource": "*"
       }
     ]
   }
   ```

7. 配置订阅：

   ```bash
   sudo xrayebator dns01-setup --domain sub.example.com --provider route53 \
     --aws-access-key-id AKIA... --aws-secret-access-key ... --email admin@example.com
   ```

8. 检查：`sudo xrayebator dns01-status`。

经验之谈：不要使用 AWS root 密钥，上面的策略够用时不要授予 `Route53FullAccess`。我们的密钥保存在
`0600 root` 的 `/etc/letsencrypt/xrayebator-dns01-aws.ini` 中，`uninstall.sh` 会删除它——但密钥轮换仍然
由你负责。

## 检查域名

签发证书前后，值得跑一遍这组简短检查。

| 检查 | 命令 | 期望 |
|---|---|---|
| A 记录 | `dig +short sub.example.com` | 你的服务器 IPv4 |
| NS 已委派 | `dig +short NS example.com` | Cloudflare 或 AWS 的名称服务器 |
| 端口 `80` 开放 | `curl -sS -o /dev/null -w '%{http_code}\n' http://sub.example.com/` | 任意状态码，但不能是 `000` |
| 订阅有响应 | `curl -sS -o /dev/null -w '%{http_code}\n' https://sub.example.com/sub/<token>` | `200` |
| DNS-01 状态 | `sudo xrayebator dns01-status` | 服务商、域名、证书有效期 |
| 服务器状态 | `sudo xrayebator inspect --json` | 订阅模式、配置档、后端 |

`curl` 返回 `000` 意味着根本没有建立连接：端口没开、DNS 不匹配，或请求被某一层代理吞掉了。这是"证书
签不下来"时要先查的地方。

## 客户端

服务器以四种格式提供同一组路由：格式由订阅链接中的 `?target=` 参数或客户端的 User-Agent 决定。

| 订阅格式 | 谁来请求 | 包含什么、不包含什么 |
|---|---|---|
| HAPP（默认） | HAPP | 全部路由，含 PQ；按令牌提供 routing 配置与地理数据 |
| v2ray 的 base64 | v2rayNG、v2rayN（`?target=v2ray`） | PQ 路由被隐藏：没有 ML-KEM 的客户端用不了 |
| Clash/mihomo YAML | mihomo、Stash、FlClash（`?target=clash`） | xhttp 仅在 `?xhttp=1` 且 mihomo 新于 1.19 时可用；PQ 被跳过 |
| sing-box JSON | sing-box、Karing、Hiddify（`?target=singbox`） | 不支持 xhttp；PQ 被跳过 |

规则很简单：客户端不在表里时，先用 HAPP 链接——它兼容性最好。我们不发布也不分发自己打包的客户端；
官方页面：[HAPP](https://www.happ.su)、[v2rayN](https://github.com/2dust/v2rayN)、
[sing-box](https://sing-box.sagernet.org)、[mihomo](https://github.com/MetaCubeX/mihomo)。

## 本文不包含什么

- **主机商推荐与推广链接。** 不推荐 VPS、不推荐域名、不推荐任何东西。"已验证"的主机商名单几周就会过期，
  而收费的推荐也就不再是推荐。
- **被封网段的"白名单"。** 请从你要使用服务器的那个网络自行确认可达性。
- **"任何网络都能用"的承诺。** 有些封锁发生在主机商网段这一层——这不能靠配置 Xray 解决，只能换一家
  主机商，或用两台服务器做桥接（见[级联](configuration.md)）。
- **法律建议。** 买哪里的主机、在哪个司法辖区，是你的决定，也是你的责任。

如果本文与实际情况不符，那比文字的工整更重要：请开一个 issue。
