# 架构

[← 返回 README](../../README.zh-CN.md) · [English](../architecture.md) · [Русский](../ru/architecture.md)

章节：[仓库结构](#仓库结构) · [服务器上的状态](#服务器上的状态) ·
[入站与配置档的区别](#入站与配置档的区别) · [订阅如何工作](#订阅如何工作) ·
[更新路径](#更新路径) · [桌面图形界面](#桌面图形界面)

---

## 仓库结构

```text
Xrayebator/
├── xrayebator                  # Bash 应用程序：菜单、配置档、入站、路由、迁移
├── install.sh                  # 首次安装、服务、依赖与权限
├── update.sh                   # 完整的项目生命周期更新
├── uninstall.sh                # 移除服务与安装状态
├── src/                        # 活跃的 Electron + React + TypeScript 桌面 GUI
│   ├── main/                   # SSH、部署、配置档、订阅和服务器管理器
│   ├── preload/                # 暴露给渲染进程的 contextBridge
│   ├── renderer/               # Dashboard、AddServer、ServerKeys、ServerSettings
│   └── shared/                 # 共享的 TypeScript 类型和 VLESS 辅助函数
├── tests/                      # Electron/Vitest 单元测试
├── resources/                  # Electron 构建资源
│   └── icons/                  # 应用程序图标
├── electron-builder.yml        # 打包和 extraResources 配置
├── electron.vite.config.ts     # main、preload 和 renderer 构建配置
├── package.json                # Electron 脚本和依赖
├── gui-legacy/                 # 已归档的 PySide6 GUI 及其测试
├── validation/                 # Bash 静态和本地回归测试
├── docs/                       # 中文、英文、俄文技术参考文档
├── sni_list.txt                # Bash 应用程序使用的 SNI 候选列表
├── ascii_art.txt               # 终端界面标题图
└── LICENSE
```

所有服务器端管理逻辑都在 `xrayebator` 文件中。`install.sh`、`update.sh` 和 `uninstall.sh`
负责安装和生命周期操作。生成的 `subhttp.sh`、nginx 配置和 systemd 单元构成 HAPP 订阅链路。
`src/` 中的活跃桌面应用是 Bash 管理层的 SSH 前端，而不是第二个服务器实现。

## 服务器上的状态

```text
/usr/local/bin/
├── xray                          # Xray-core 二进制
├── xrayebator                    # 管理器入口
├── subhttp.sh                    # 生成的订阅 HTTP 处理器
├── xrayebator-update             # 完整的项目更新程序
└── xrayebator-uninstall          # 移除入口

/usr/local/etc/xray/
├── config.json                   # 入站、出站、路由和 DNS
├── profiles/<name>.json          # 配置档元数据和订阅令牌
├── upstreams/cascade.json        # 级联上游参数
├── backups/                      # 运行时改动前的配置备份
├── .private_key / .public_key    # Reality 密钥
├── .vless_decryption / .vless_encryption
├── .subscription_*               # 订阅模式、地址、域和端口标记
├── .happ_defaults.env            # HAPP 显示和路由默认值
├── .current_branch               # 管理器用于生命周期更新的分支
└── 迁移标记                       # 已完成一次性迁移的记录

/usr/local/share/xray/             # geoip.dat 和 geosite.dat
/var/log/xray/                     # Xray 服务写入的运行时日志目录
/etc/systemd/system/xray.service.d/security.conf
/etc/systemd/system/xrayebator-sub.service
/etc/nginx/sites-available/xrayebator-sub
```

`/usr/local/etc/xray/` 是 root 拥有的管理器状态和配置。Xray 以非 root 的 `xray` 服务账户运行，
读取所需文件；它不拥有也不写入管理器状态。`/var/log/xray/` 是单独的运行时日志目录。root 拥有的
脚本和标记不会被服务账户替换。

## 入站与配置档的区别

入站是 `config.json` 中与端口绑定的配置块。配置档是包含一个或多个路由的面向用户的 JSON 文件。
多个配置档可以共享同一个入站和端口。

端口和 SNI 是共享入站的属性。更改 SNI 或端口可能会改变使用该入站的所有配置档；当需要独立 SNI
值时，请使用单独的端口。生成的配置档 JSON 会在入站级别的 SNI 或端口变更后同步。

Reality 指纹是按配置档或路由保存的客户端值。更改它只会修改所选路由的客户端链接，不编辑入站，
也不需要重启 Xray。对于 XHTTP，路由 SNI 也会反映在传输 host 字段中，使两个值保持同步。

## 订阅如何工作

`xrayebator-sub.service` 监听 `127.0.0.1:8080`；nginx 通过 HTTPS 发布生成的
`/usr/local/bin/subhttp.sh` 处理器。处理器读取 root 拥有的状态和配置档元数据，
返回客户端特定的订阅主体。

基础 URL 从 `.subscription_domain` 和 `.subscription_port` 动态构建：

```text
https://<domain>/sub/<32-hex-token>       # 443 上的公共 TLS
https://<domain>:8443/sub/<32-hex-token>  # 其他端口上的公共 TLS
http://127.0.0.1:8080/sub/<token>         # 仅本地回退
```

交互式 HAPP 设置可以选择公共端口，`_subscription_base_url` 会保留这一选择。非交互式的
`quickstart --email <address>` 和 `quickstart --without-email` IP-TLS 流程会在 `8443` 配置 nginx、证书和标记，然后返回该 endpoint 的 `subscription_url`。不提供邮箱时，Certbot 会在没有 ACME 联系地址的情况下注册，因此无法接收续期通知或通过邮箱恢复。令牌以 `sub_token` 形式存储在配置档中；执行 revoke 会轮换令牌并使之前的 URL 失效。

新创建的标准托管 HAPP 配置档是 schema-v3 七路由配置档，包括 `xhttp-legacy` 和后量子 XHTTP 路由。
发布的 HAPP 连接列表包含六个 VLESS 路由，因为 PQ 路由仍可通过原始/配置档路径访问。助手也可能
复用至少有七条存活线路的旧配置档，因此排查时请检查实际 label 和 schema；迁移不会向已有配置档
补齐缺失线路。没有存活线路的配置档返回 `410 Gone`，部分过期的多线路配置档则可能以 `200` 返回剩余线路。

处理器还提供由令牌保护的 `geoip.dat` 和 `geosite.dat` 资源，这些资源是托管的 HAPP 路由配置
所必需的。HAPP 接收其路由元数据，而 v2rayNG 和 v2rayN 接收兼容的 VLESS 主体，不包含 HAPP 专属
元数据。

## 更新路径

名称相似的命令有不同的职责：

| 命令 | 职责 |
|---|---|
| `sudo xrayebator update` | 仅从 XTLS 发布渠道更新 Xray-core 二进制，然后通过 core-update 路径验证和重启核心 |
| `sudo xrayebator update <branch>` | 从规范仓库分支获取管理器脚本，继续使用新脚本，然后更新 Xray-core |
| `sudo xrayebator-update [branch]` | 运行 `update.sh` 项目生命周期工作流：管理器脚本、数据、订阅集成和服务刷新，具体以该脚本实现为准 |

无参数时，`xrayebator-update` 显示交互式分支选择；`.current_branch` 中的当前分支会显示但不会
自动选择。Electron GUI 在服务器设置中使用中间路径（`xrayebator update <branch>`）；它不暴露
完整的终端更新工作流。

## 配置改动流程

对于 `xrayebator` 拥有的运行时变更，正常事务如下：

```text
backup_config ────► /usr/local/etc/xray/backups/config_<timestamp>_<op>.json
safe_jq_write ────► 临时文件 → 验证 → 原子重命名
safe_restart_xray ► xray run -test -config → systemctl restart
                    失败时从备份回滚，Xray 继续使用旧配置
```

迁移只执行一次，由 `/usr/local/etc/xray/` 下的标记文件记录。通常的序列是：标记缺失 → 备份 →
修改 → 配置变更时已验证的重启 → 创建标记。安装程序和生命周期更新程序有各自的验证和重启序列；
并非每次安装或更新重启都是对 `safe_restart_xray` 的调用。

## 桌面图形界面

活跃的桌面应用（`src/`）是一个受控的 SSH CLI 前端。它可以通过 `quickstart` 部署、刷新和显示
已保存的订阅、管理配置档，以及调用选定的 SNI、指纹、端口、更新和卸载操作。它有意只暴露交互式
Bash 菜单的一个子集，并且从不直接编辑 `config.json`。

参见 [Electron 桌面 GUI](desktop-gui.md) 了解完整的功能边界、SSH 安全模型、命令映射、打包和
测试详情。