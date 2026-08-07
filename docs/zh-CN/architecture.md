# 架构

[← 返回 README](../../README.zh-CN.md) · [English](../architecture.md) · [Русский](../ru/architecture.md)

章节：[仓库结构](#仓库结构) · [服务器上的状态](#服务器上的状态) ·
[入站与配置档的区别](#入站与配置档的区别) · [订阅如何工作](#订阅如何工作)

---

## 仓库结构

```text
Xrayebator/
├── xrayebator            # 主程序：菜单、配置档、入站、路由、迁移
├── install.sh            # 安装内核、服务、权限、geo 数据库、生命周期命令
├── update.sh             # 从指定分支更新 Xrayebator 本身
├── uninstall.sh          # 移除服务与配置
├── validation/           # 静态与本地回归测试
├── docs/                 # 文档：en、ru、zh-CN
├── sni_list.txt          # 候选 SNI 列表
├── ascii_art.txt         # 终端界面标题图
├── CLAUDE.md             # 项目工作规则与策略
└── LICENSE
```

管理逻辑集中在单个 `xrayebator` 文件中。`install.sh`、`update.sh` 与 `uninstall.sh`
负责生命周期。生成的 `subhttp.sh`、nginx 配置与 systemd 单元共同构成 HAPP 订阅链路。

## 服务器上的状态

```text
/usr/local/bin/
├── xray                          # 内核
├── xrayebator                    # 管理器
├── subhttp.sh                       # 订阅后端
├── xrayebator-update
└── xrayebator-uninstall

/usr/local/etc/xray/
├── config.json                   # 入站、出站、路由、DNS
├── profiles/<name>.json          # 配置档元数据：routes、sub_token、SNI、指纹
├── upstreams/cascade.json        # 级联上游参数
├── backups/config_<timestamp>_<op>.json          # 每次改动前的配置备份
├── .private_key / .public_key    # Reality 密钥，安装时生成一次
├── .vless_decryption             # xhttp-pq 使用的 PQ 密钥
├── .vless_encryption
├── .subscription_mode            # 订阅发布模式
├── .subscription_domain          # 订阅域名，仅改 DNS 记录不会改变它
├── .subscription_port            # 443 或 8443
├── .happ_defaults.env            # HAPP 设置，含客户端中显示的服务器名
├── .current_branch               # Xrayebator 的更新分支
└── .xhttp_migrated, ...          # 已完成迁移的标记文件

/usr/local/share/xray/            # geoip.dat 与 geosite.dat
/etc/systemd/system/xray.service.d/security.conf
/etc/systemd/system/xrayebator-sub.service
/etc/nginx/sites-available/xrayebator-sub
/etc/nginx/sites-available/xrayebator-selfsteal
```

## 入站与配置档的区别

入站是 `config.json` 中与端口绑定的配置块；配置档是面向用户的元数据 JSON 文件。
多个配置档可以位于同一个入站上，也就是同一个端口上。

由此得出关键结论：入站的 SNI 与指纹由该端口上的所有配置档共享。
修改某个端口的 SNI 会影响挂在该端口上的全部配置档。

## 订阅如何工作

`xrayebator-sub.service` 监听 `127.0.0.1:8080`，由 nginx 通过 HTTPS 对外发布。端点形如：

```text
https://<域名或IP>/sub/<32位十六进制令牌>
```

令牌以 `sub_token` 保存在配置档 JSON 中。一旦泄露，请在订阅菜单中使用 `Revoke`：
令牌会更换，旧链接立即失效。

客户端中显示的订阅名称与配置档名称是分开设置的：
`Подписка HAPP` → `Настройки HAPP` → `HAPP_SERVER_NAME`。
因此即使每台 VPS 上的内部配置档都叫 `happ`，也可以在客户端列表中显示不同名称。
留空时使用配置档名称。

各客户端的行为：

- HAPP 收到纯文本的 `vless://` 列表、HAPP 头部以及可选的 `happ://routing/onadd/...`；
- `v2rayNG` 与 `v2rayN` 收到不含 HAPP 元数据的经典 base64 订阅体；
- 没有存活入站的配置档不会出现在订阅菜单中，其旧链接返回 `410 Gone`。

## 配置改动流程

任何改动都走同一条路径：

```text
backup_config ────► /usr/local/etc/xray/backups/config_<timestamp>_<op>.json
safe_jq_write ────► 在目标目录内写临时文件 → 校验 → 原子重命名
safe_restart_xray ► xray run -test -config → systemctl restart
                    失败时从备份回滚，Xray 继续使用旧配置
```

迁移只执行一次，并由 `/usr/local/etc/xray/` 下的标记文件记录。流程始终一致：
标记不存在 → 备份 → 修改 → 重启 → 写入标记。
