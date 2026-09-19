# Xrayebator GUI (legacy)

> **Архивная версия:** активное десктоп-приложение проекта — Electron + React + TypeScript в `src/`.
> Этот PySide6-клиент сохранён для legacy-совместимости и имеет отдельные тесты, packaging и CI.
> Описанные ниже system-proxy, Linux TUN helper и keyring относятся только к legacy-приложению и
> не являются возможностями активного Electron GUI.

Desktop client for deploying Xrayebator to a VPS and connecting through an
Xray VLESS Reality subscription. It is not the active desktop implementation.

The current preview supports the system-proxy connection path on Windows,
macOS, and Linux, and contains the Linux Xray-native TUN helper. TUN is enabled
in the UI only when the privileged helper socket is installed and reachable.
Native Windows/macOS TUN services and live route/DNS leak verification remain
tracked in [`DEVELOPMENT_PLAN.md`](DEVELOPMENT_PLAN.md).

## Development

```bash
python3 -m venv .venv
. .venv/bin/activate
python -m pip install -e '.[dev]'
pytest
python -m xrayebator_gui
```

The application stores server metadata in the platform user-data directory.
SSH passwords are stored through the operating system keyring rather than in
`servers.json`.

## Linux TUN helper

When the helper is absent, the main window shows **Install TUN helper**.
The action invokes `pkexec`, installs a root-owned copy of the narrow helper
API and the pinned Xray core, then starts
`xrayebator-gui-helper.service`. The service socket authorizes only the UID
that performed the desktop installation.

The installer supports `x86_64` and `aarch64`, verifies the Xray archive
against an embedded SHA-256, and does not execute Xray from the user's
workspace. It requires `python3`, `curl`, `unzip`, `nft`, and `systemd`.

## Current flow

1. Add VPS credentials.
2. Deploy `install.sh` and the local `xrayebator` script over SSH.
3. Run `xrayebator quickstart --email ...` remotely.
4. Save the returned subscription URL.
5. Load routes, select the preferred Vision transport, and connect
   automatically through native TUN (or the system-proxy fallback).

After setup, connect/disconnect, server, transport route, and routing profile
are available from the tray menu. Subscription bearer URLs and VLESS links are
redacted from UI logs; local metadata and runtime configs are written with
owner-only permissions.

Do not use the development build as a leak-proof VPN yet. The helper contains
DNS guarding and a fail-closed nftables kill switch, but packaging and live
integration checks are required before that claim.

## Desktop preview builds

The `GUI desktop release` GitHub Actions workflow builds on each target OS
rather than cross-compiling:

- `Xrayebator-Windows-x64.exe`;
- `Xrayebator-macOS-Intel.dmg`;
- `Xrayebator-macOS-Apple-Silicon.dmg`.

Every bundle contains the pinned Xray archive after checking its upstream
SHA-256 file. A matching `.sha256` sidecar is published with every artifact.
GUI pull requests and manual workflow runs produce CI artifacts; pushing a
`gui-v*` tag additionally creates a GitHub prerelease.

These preview binaries are not yet signed or notarized. Windows SmartScreen
and macOS Gatekeeper can therefore display an unverified-publisher warning.
Use GitHub **Releases** for these end-user downloads; GitHub **Packages** is
reserved for package/container registries and is not used by this workflow.
