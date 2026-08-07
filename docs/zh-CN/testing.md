# 测试

[← 返回 README](../../README.zh-CN.md) · [English](../testing.md) · [Русский](../ru/testing.md)

---

## 本地检出校验

```bash
bash -n xrayebator install.sh update.sh uninstall.sh
for test_file in validation/*.sh; do bash "$test_file" || exit; done
shellcheck -S error xrayebator install.sh update.sh uninstall.sh
```

提交之前这三条命令都必须通过。

## 测试覆盖范围

`validation/` 中是静态与本地回归测试：

| 测试 | 检查内容 |
|---|---|
| `test-transaction-safety.sh` | 配置操作的事务安全性 |
| `test-project-update-rollback.sh` | 项目更新失败后的回滚 |
| `test-xhttp-route-path-repair.sh` | 迁移过程中 XHTTP 线路路径的修复 |
| `test-multiroute-argument-preservation.sh` | 多线路配置档传输参数的保留 |
| `test-happ-subscription-static.sh` | HAPP 订阅处理器 |
| `test-subscription-server-name.sh` | 客户端中显示的订阅服务器名 |
| `test-fingerprint-subscription-sync.sh` | 更换指纹时线路与订阅的同步 |
| `test-dead-stealth-route-pruning.sh` | 失效 stealth 线路的清理 |
| `test-cascade-routing.sh` | 级联路由 |
| `test-cascade-upstream-import.sh` | 从链接导入级联上游 |
| `test-update-xray-core-sync.sh` | Xray-core 更新的同步 |
| `test-vless-url-generation.sh` | `vless://` 链接生成 |
| `test-installer-network-fallbacks.sh` | 安装脚本的网络回退 |
| `test-bbr-removal-migration.sh` | 已被移除的 BBR/TCP 调优在所有路径上的安全清理 |
| `test-legacy-udp443-migration.sh` | 一次性清理旧版 UDP/443 阻断规则 |
| `test-main-menu-numbering.sh` | 主菜单条目编号连续且与处理函数一致 |

> 静态测试不能替代一次性 VPS 上的实测：创建与删除配置档、校验配置、重启服务、回滚，
> 以及真实客户端连接。

## 线上服务器的手工检查

```bash
sudo xrayebator probe-test                                        # 从 VPS 检查 SNI 可达性
sudo /usr/local/bin/xray test -config /usr/local/etc/xray/config.json
sudo systemctl status xray --no-pager -l
sudo systemctl status xrayebator-sub --no-pager -l
curl -sS -i http://127.0.0.1:8080/sub/                            # 预期返回 404
jq -r '.routes[] | [.label,.transport,.port,(.pq_enabled // false)] | @tsv' \
  /usr/local/etc/xray/profiles/<profile>.json
```

如果 UFW 已经启用，请对比操作前后的 numbered rules：安装不应重新启用防火墙，
也不应更改其默认策略。
