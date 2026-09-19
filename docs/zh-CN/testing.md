# 测试

[← 返回 README](../../README.zh-CN.md) · [English](../testing.md) · [Русский](../ru/testing.md)

---

## 本地检出校验

```bash
bash -n xrayebator install.sh update.sh uninstall.sh
for test_file in validation/*.sh; do bash "$test_file" || exit; done
```

这是本地检查的最小门槛。`shellcheck` 可以额外运行，但不是 CI 的必要 gate（见下文）。

## 测试覆盖范围

`validation/` 中有 24 个静态与本地回归测试：

| 测试 | 检查内容 |
|---|---|
| `test-transaction-safety.sh` | 配置操作的事务安全性 |
| `test-project-update-rollback.sh` | 项目更新失败后的回滚 |
| `test-xhttp-route-path-repair.sh` | 迁移过程中 XHTTP 路径的修复 |
| `test-multiroute-argument-preservation.sh` | 多线路配置档传输参数的保留 |
| `test-happ-subscription-static.sh` | HAPP 订阅处理器 |
| `test-subscription-server-name.sh` | 客户端中显示的订阅服务器名 |
| `test-fingerprint-subscription-sync.sh` | 更换指纹时线路与订阅的同步 |
| `test-dead-stealth-route-pruning.sh` | 失效 stealth 线路的清理 |
| `test-cascade-routing.sh` | 级联路由 |
| `test-cascade-upstream-import.sh` | 从链接导入级联上游 |
| `test-update-xray-core-sync.sh` | Xray-core 更新同步 |
| `test-vless-url-generation.sh` | `vless://` 链接生成 |
| `test-installer-network-fallbacks.sh` | 安装脚本网络回退 |
| `test-bbr-removal-migration.sh` | 已删除 BBR/TCP 调优在所有路径上的安全清理 |
| `test-legacy-udp443-migration.sh` | 一次性清理旧版 UDP/443 阻断规则 |
| `test-main-menu-numbering.sh` | 主菜单条目编号连续并与处理函数一致 |
| `test-main-readiness-regressions.sh` | 审计后的 readiness 回归：certbot manifest、UFW manifest、nginx 回滚、权限与 SSH 端口 |
| `test-sni-change-cli.sh` | `sni-change` CLI：JSON 输出、Reality、XHTTP host、配置档同步与回滚 |
| `test-port-change-cli.sh` | `port-change` CLI：unit/shared/move 入站场景、无效端口、缺少配置档、多线路 `--route` |
| `test-bypass-cli.sh` | `bypass` CLI：JSON 输出、路由规则更新、带 SNI 探测的 add |
| `test-quickstart-migration-parity.sh` | `quickstart` 执行与 `main_menu` 相同的关键迁移 |
| `test-quickstart-subscription-port.sh` | 确认 `quickstart` 使用规范的订阅基础地址 helper，不回退到无关的硬编码 URL |
| `test-audit-functional.sh` | HowDeploy 审计（P0/P1）的功能回归检查 |
| `test-audit-privilege-regressions.sh` | 权限边界回归 |

> 静态测试不能替代一次性 VPS 上的实测：创建与删除配置档、校验配置、重启服务、回滚以及真实客户端连接。

## 线上服务器的手工检查

```bash
sudo xrayebator probe-test                                    # 从 VPS 检查 SNI 可达性
sudo /usr/local/bin/xray run -test -config /usr/local/etc/xray/config.json
sudo systemctl status xray --no-pager -l
sudo systemctl status xrayebator-sub --no-pager -l
curl -sS -i http://127.0.0.1:8080/sub/                        # 预期返回 404
jq -r '.routes[] | [.label,.transport,.port,(.pq_enabled // false)] | @tsv' \
  /usr/local/etc/xray/profiles/<profile>.json
```

如果 UFW 已经启用，请对比操作前后的 numbered rules：安装不应重新启用防火墙，也不应更改其默认策略。

## 桌面图形界面

GUI（`src/`）在 `tests/` 中有独立的 Vitest 单元测试：

```bash
npm run typecheck     # 检查 TypeScript：main、preload、renderer、shared
npm test              # Vitest 单元测试
```

测试文件：

| 测试 | 检查内容 |
|---|---|
| `tests/unit/subscription.test.ts` | 订阅链接与配置档密钥提取 |
| `tests/unit/probe-ports.test.ts` | Dashboard 状态点使用的可达性探测 |
| `tests/unit/extractJson.test.ts` | 从 `xrayebator` 输出解析 JSON |
| `tests/unit/countryFlag.test.ts` | 服务器卡片的国家旗帜 |
| `tests/unit/vless.test.ts` | `vless://` URL 解析 |
| `tests/unit/shell-command.test.ts` | POSIX 安全的 shell 参数 quoting |
| `tests/unit/ssh-access.test.ts` | SSH 访问参数验证 |
| `tests/unit/ssh-client.test.ts` | SSH 连接与 host-key verification |
| `tests/unit/server-manager.test.ts` | 更新分支安全性验证 |

说明：`tests/unit/shell-command.test.ts` 有意调用 `/bin/sh`，在没有 POSIX `/bin/sh` 的 Windows
上会失败（`status=null`）。完整 suite 应在 Linux（包括 `release.yml` 的 Ubuntu job）运行；Linux
上 39 个测试全部通过。

## CI workflow

三个独立 workflow：

- **ci-linux.yml** — Bash validation：在 ubuntu-24.04 上对所有脚本执行 `bash -n`，并运行全部 24 个
  `validation/test-*.sh`；在 push 到 `main`、`dev`、`experimental` 以及 pull request 时运行。
- **release.yml** — Electron 构建（Windows/macOS/Linux）。只在 `v*` tag 和手动触发时运行；先在
  Ubuntu 上执行 `npm run typecheck`、`npm test`、`npm run build`，再在三种平台执行
  `electron-builder --publish never`。
- **gui-release.yml** — legacy PySide6 GUI：ruff、pytest 和 wheel 构建；在 PR 与 `gui-v*` tag 上运行。