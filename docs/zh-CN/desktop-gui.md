# Electron 桌面图形界面

[← 返回 README](../../README.zh-CN.md) · [English](../desktop-gui.md) · [Русский](../ru/desktop-gui.md)

本页说明当前使用的桌面应用。内容针对 `src/` 中的 Electron + React + TypeScript GUI；`gui-legacy/` 中已归档的 PySide6 应用另有边界说明，它不是当前 Electron 实现。

## 用途与边界

桌面 GUI 是一个 Electron 应用，包含位于 `src/` 的 React renderer 以及 TypeScript main、preload、shared 和 renderer 代码。它是运维面板，而不是第二套服务器实现：

- 服务器端的权威实现仍然是 Bash `xrayebator`；
- GUI 通过 SSH 管理 VPS，并调用服务器安装器、CLI 与维护脚本；
- 服务器状态、Xray 配置、配置档、路由和服务生命周期都保留在 VPS 上；
- GUI 在本地保存服务器卡片与连接元数据，方便运维人员再次打开服务器。

renderer 只能通过精简的 preload `contextBridge` API 访问特权操作。GUI 可以管理下文所列的配置档与部署流程，但它不是终端，也不是完整复制 Bash 交互菜单的界面。

## UI 流程

### Dashboard

Dashboard 显示已保存的服务器卡片、可达性状态点、位置/OS 与线路元数据，以及密钥、设置和删除本地服务器卡片的操作。可达性检查由 Electron main process 执行，是有时间限制的 TCP 检查；它不是服务端的 `probe-test` 命令。语言选择器可以切换 `RU`、`EN` 和 `中文`。

### Add server

Add server 接收 VPS host 和 SSH 端口、SSH 访问参数以及用于 `quickstart` 的邮箱。部署进度按以下步骤显示：

1. 通过 SSH 连接并验证提升后的权限；
2. 读取 `/etc/os-release`；
3. 创建临时目录 `/tmp/xrayebator-<token>`，上传 `install.sh` 和 `xrayebator`；
4. 使用所选权限运行 `bash install.sh`；
5. 将上传的管理器二进制安装到 `/usr/local/bin/xrayebator`；
6. 运行 `xrayebator quickstart --email <email>`；
7. 解析包含 `subscription_url` 的 JSON 结果，获取订阅，并在本地保存服务器元数据与密钥。

GUI 会显示部署日志和步骤状态，但进行中的部署没有 IPC 取消通道。

### Server keys

Server keys 会从保存的 `subscription_url` 刷新订阅，并显示返回的 VLESS 线路。每条 VLESS 链接都可以复制或生成二维码；订阅 URL 也可以复制，页面还提供复制全部内容的操作。此页面不会在服务器上创建独立订阅，也不会轮换订阅令牌。

### Server settings

Server settings 先通过 SSH 认证，然后可以：

- 列出已有配置档；
- 创建一个或多个配置档并删除配置档；
- 选择 `xhttp`、`tcp`、`tcp-utls`、`tcp-xudp`、`tcp-mux` 或 `grpc` 传输；
- 修改配置档 fingerprint，从 `sni-list` 选择 SNI，或手动输入 SNI；
- 修改配置档线路的端口，或选择随机端口；
- 更新服务器安装；
- 确认后卸载服务器安装；
- 在明确确认后重置固定的 SSH host key。

SNI 和端口属于 inbound 级别的设置：修改它们可能影响共享该 inbound 的所有配置档。Fingerprint 则不同：它是按配置档/线路保存的客户端参数，不会修改其他线路。服务端命令会报告结果以及是否需要重新连接。

## SSH 与安全

GUI 支持 SSH 密码认证或私钥认证，并支持直接以 `root` 执行或通过 `sudo` 提升权限。私钥通过 Electron 原生文件对话框选择；main process 会拒绝未经该对话框批准的任意路径。

SSH 密码、sudo 密码、私钥口令和私钥字节都不会持久化。它们只存在于当前表单/操作中，并在需要时传给 main process。`electron-store` 会保存服务器卡片和连接偏好、订阅 URL、已获取的 VLESS 链接（bearer/client credentials）、用户名、认证方式、权限模式、所选密钥路径，以及首次成功连接后保存的 SSH host-key SHA-256 pin（TOFU）。请保护本地应用数据；如果订阅 URL 或 VLESS 链接泄露，请通过终端 workflow 吊销订阅。之后 fingerprint 不匹配时，会在执行命令前失败；有意重装服务器时，必须在 Server settings 中明确重置 host-key pin。

`keytar` 存在于 `package.json` 依赖中，但当前 Electron GUI 尚未使用它把 SSH 密码或私钥口令存入操作系统钥匙串。

Electron 边界包含以下保护措施：

- BrowserWindow 设置 `contextIsolation: true`、`sandbox: true` 和 `nodeIntegration: false`；
- renderer Content Security Policy 将脚本限制为本地来源，仅允许声明的本地/inline 样式来源，并将图片和字体 data URL 限制为声明的数据来源；
- 构造远程命令之前对 shell 参数进行 POSIX 安全 quoting；
- sudo 密码通过 SSH stdin 发送，不插入命令行；
- 外部导航和 `shell.openExternal` 仅允许 HTTPS GitHub 主机，其他 URL 默认拒绝。

## 已暴露与未暴露的命令

GUI 暴露的配置档 API 对应以下 Bash CLI 命令：

```text
xrayebator profiles
xrayebator profile-create --name NAME [--transport T] [--port P] [--count N]
xrayebator profile-delete --name NAME
xrayebator fp-change --name NAME [--route R] --fp FINGERPRINT
xrayebator sni-change --name NAME [--route R] --sni SNI
xrayebator sni-list
xrayebator port-change --name NAME [--route R] --port PORT|random
```

部署流程还会调用：

```text
xrayebator quickstart --email EMAIL
```

GUI 使用结果中的 `subscription_url`，随后通过该 URL 获取 VLESS 密钥。Server settings 还会调用更新操作（`xrayebator update <branch>`），卸载时可以上传并运行 `uninstall.sh`。这些都是受控操作，不是交互式 shell 会话。

当前 Electron GUI **不暴露**以下服务器功能：

```text
bypass
probe-test
revoke
happ-setup
cascade
self-steal
交互式 terminal menu
服务日志/状态
```

尤其要注意，Dashboard 的可达性状态点不等于可以使用 `probe-test`，密钥页面也不等于可以使用 `revoke`。

## 部署协议

部署时的权威是远程 Bash 安装，而不是 React。Electron main process 创建 SSH 客户端，验证目标与权限模式，然后执行以下协议：

```text
SSH connect + host-key verification
        │
        ├─ 以提升权限执行 `id -u`
        ├─ 以普通权限读取 `/etc/os-release`
        ├─ SFTP upload: install.sh, xrayebator
        ├─ elevated `bash install.sh`
        ├─ elevated install → /usr/local/bin/xrayebator
        ├─ elevated `xrayebator quickstart --email EMAIL`
        └─ parse `subscription_url` → fetch subscription → 保存服务器卡片、连接偏好、订阅 URL 和已获取的 VLESS 链接
```

远程命令使用安全的 shell 参数 quoting 构造。使用 sudo 时，机密通过 stdin 与命令分开传递。每次操作结束后 GUI 都会关闭 SSH 客户端，并在关闭时清理内存中的私钥缓冲区。

配置档操作使用同一 SSH 路径，并且只调用上面列出的命令适配器。Bash 应用负责备份、校验、防火墙变更、Xray 重启、配置档同步和回滚。

## 打包与 CI

本地开发与检查使用 `package.json` 中的 scripts：

```bash
npm run dev
npm run build
npm run typecheck
npm test
```

打包 script 是仅限 Windows 的便捷命令，因为它明确以 Windows 为目标：

```bash
npm run package
# equivalent: electron-vite build && electron-builder --win
```

Electron 发布工作流是 `.github/workflows/release.yml`。它运行 Electron 的 `npm run typecheck` 和 `npm test`，然后为 Windows、macOS 和 Linux 构建平台包。这是 `v*` 发布路径（或手动 workflow dispatch）；这**不表示**每次涉及 GUI 的 push 都会运行 Electron 测试。

独立的 `.github/workflows/gui-release.yml` 是 legacy GUI 工作流。它运行 Python `ruff` 和 `pytest gui-legacy/tests`，构建 PySide6 原生 bundle，并服务于 `gui-v*` legacy 发布路径。它不是 Electron 发布工作流。

`.github/workflows/ci-linux.yml` 校验 Bash core：语法检查和完整的 `validation/test-*.sh` 测试集。它不是 Electron 测试工作流。

Electron packaging 使用为 `howdeploy/Xrayebator` 配置的 GitHub provider。Auto-updater 只有在 packaged build 中初始化；启用时会自动下载更新，并在应用退出时安装。开发模式不会运行这条更新路径。

## Legacy GUI：`gui-legacy`

`gui-legacy/` 是归档的 PySide6 桌面 GUI。它是独立实现，有独立的 Python 测试、打包代码和原生 bundle。它历史上的行为包括 system proxy、TUN runtime 和 keyring 集成；这些特性只属于 legacy，不能归因于当前 Electron GUI。

当前桌面实现位于 `src/`。因此，`gui-v*` 工件或成功的 `gui-legacy/tests` job 并不表示 Electron 应用已由该工作流打包或测试。

## 限制

- 部署没有 IPC 取消通道。启动后，UI 可以报告事件和错误，但不能向远程部署协议发送取消请求。
- 没有 React/Electron runtime integration tests。Electron 具有 unit tests、TypeScript 检查、build 检查和真实服务器手工验证，但没有同时启动完整 packaged renderer 与 main process 流程的测试。
- 有一个 Vitest 测试使用 POSIX `/bin/sh`（`tests/unit/shell-command.test.ts`）。这是 Windows 上的已知限制；该 shell 专用测试以 Linux 为事实来源。
- Auto-updater 仅在 packaged build 中运行，使用为 `howdeploy` 配置的 GitHub provider，并采用 auto-download/install-on-quit 行为；`npm run dev` 不会模拟发布更新。
- GUI 有意只暴露上面记录的命令范围。需要 bypass、probe-test、订阅撤销、HAPP setup、cascade、self-steal、terminal menu 或服务日志/状态时，请使用 Bash `xrayebator` 界面或服务器端命令。
