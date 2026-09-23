# Electron Desktop GUI

[← Back to README](../README.md) · [Русский](ru/desktop-gui.md) · [简体中文](zh-CN/desktop-gui.md)

This page describes the active desktop application. It is a reference for the Electron + React + TypeScript GUI in `src/`; it does not describe the archived PySide6 application in `gui-legacy/`.

## Purpose and boundary

The desktop GUI is an Electron application with a React renderer and TypeScript main, preload, shared, and renderer code under `src/`. It is an operator panel, not a second server implementation:

- the server-side authority remains the Bash `xrayebator` application;
- the GUI manages a VPS over SSH and invokes the server's installer, CLI, and maintenance scripts;
- server state, Xray configuration, profiles, routing, and service lifecycle remain on the VPS;
- the GUI stores local server cards and connection metadata so that the operator can return to a server later.

The renderer reaches privileged operations only through the narrow preload `contextBridge` API. The UI can manage the profile and deployment flows listed below, but it is not a terminal and is not a complete mirror of the interactive Bash menu.

## UI flows

### Dashboard

Dashboard displays the saved server cards, a reachability status dot, an installation status chip (`Configured`, `Partially configured`, or `Imported`), location/OS and route metadata, and actions for keys, settings, and removing a local server card. On an empty Dashboard the operator chooses between two scenarios: **Deploy a new server** (install Xrayebator on a clean VPS) and **Connect an existing server** (find an installed Xrayebator over SSH and open its panel without touching the installation). With servers already present, `+ Add` opens the same choice. Its reachability check is a bounded TCP check performed by the Electron main process; it is not the server-side `probe-test` command. The language selector switches between `RU`, `EN`, and `中文`.

### Add server

Add server accepts the VPS host and SSH port, SSH access details, and an explicit email choice for `quickstart`: either **Provide an email** (default, shown as a field) or **Continue without email** (a warning explains that Let's Encrypt renewal notices and ACME account recovery are unavailable). The deployment progress is shown as these steps:

1. connect over SSH and verify elevated access;
2. inspect `/etc/os-release`;
3. create a temporary `/tmp/xrayebator-<token>` directory and upload `install.sh` and `xrayebator`;
4. run `bash install.sh` with the selected privileges;
5. install the uploaded manager binary at `/usr/local/bin/xrayebator`;
6. run `xrayebator quickstart --email <email>` or `xrayebator quickstart --without-email` — the second form passes `--register-unsafely-without-email` to Certbot and never substitutes a fake address;
7. read the JSON result, including `subscription_url`, fetch the subscription, and save the server metadata and keys locally.

The GUI shows deployment logs and step status, but it does not provide a cancellation channel for an in-flight deployment.

### Connect existing server (import)

Import accepts host, SSH port, SSH user and SSH access details (password or private key, the same choice as in Add server), then runs a strictly read-only `xrayebator inspect --json` over the same SSH stack: it recognizes Xrayebator installations only, and never runs `quickstart`, `happ-setup`, installers, updates, migrations, restarts, or firewall changes. A partially configured installation is still imported with honest component statuses (manager / Xray / profiles / subscription); a local-only or unreachable subscription is stored as such and no dead URL is presented as working. Importing the same `host + port` again updates the existing card instead of creating a duplicate; the server id and host-key pin survive the update. After a successful import the app opens Server Settings directly.

### Server keys

Server keys refreshes the subscription from the saved `subscription_url` and displays the returned VLESS routes. Each VLESS link can be copied or rendered as a QR code; the subscription URL can also be copied, and the page offers a copy-all action. This page does not create a separate server-side subscription or rotate a subscription token.

### Server settings

Server settings first authenticates over SSH and can then:

- list existing profiles;
- create one or more profiles and delete profiles;
- choose `xhttp`, `tcp`, `tcp-utls`, `tcp-xudp`, `tcp-mux`, or `grpc` transports;
- change a profile fingerprint, choose an SNI from `sni-list`, or enter an SNI;
- change a profile route's port or choose a random port;
- update the server installation;
- uninstall the server installation after confirmation;
- reset the pinned SSH host key after explicit confirmation.

SNI and port are inbound-level settings: changing them can affect every profile sharing that inbound. Fingerprint is different: it is a client-side value stored per profile/route and does not change the other routes. The server command reports the result and whether reconnecting is required.

## SSH and security

The GUI supports SSH password authentication or a private key, with either direct `root` execution or elevated commands through `sudo`. A private key is selected through the native Electron file dialog; the main process reads the bytes, stores them in the operating-system keychain via `keytar` (Windows Credential Manager, macOS Keychain, or Linux Secret Service), and returns to the renderer only a non-secret credential id plus the display file name. The key is reused across later operations and app restarts without re-picking the file. If the OS keychain is unavailable, the key is kept only in main-process memory for the current app session and the UI warns that reuse after restart is unavailable; there is no plaintext fallback on disk.

SSH passwords, sudo passwords, and key passphrases are never persisted — the passphrase is asked again for each session when the key is encrypted. `electron-store` persists the server card and connection preferences, the subscription URL, and the fetched VLESS links (bearer/client credentials), as well as the username, authentication method, privilege mode, credential id, display key name, installation diagnostics, and the SHA-256 SSH host-key pin. Protect the local application data; if the subscription URL or VLESS links leak, revoke the subscription through the terminal workflow. A later fingerprint mismatch fails closed before commands are executed; an intentional server reinstall requires an explicit host-key reset in Server settings. Removing the last card that references a credential deletes the keychain entry; shared references are preserved.

The Electron boundary includes the following protections:

- `contextIsolation: true`, `sandbox: true`, and `nodeIntegration: false` for the BrowserWindow;
- a renderer Content Security Policy that keeps scripts local, permits only the declared local/inline style sources, and limits image and font data URLs to the declared data sources;
- POSIX shell argument quoting before remote commands are built;
- sudo passwords sent through SSH command stdin, not interpolated into the command line;
- external navigation and `shell.openExternal` restricted to HTTPS GitHub hosts, with other URLs denied.

## Exposed and not exposed commands

The profile API exposed by the GUI maps to these Bash CLI commands:

```text
xrayebator profiles
xrayebator profile-create --name NAME [--transport T] [--port P] [--count N]
xrayebator profile-delete --name NAME
xrayebator fp-change --name NAME [--route R] --fp FINGERPRINT
xrayebator sni-change --name NAME [--route R] --sni SNI
xrayebator sni-list
xrayebator port-change --name NAME [--route R] --port PORT|random
```

Deployment additionally invokes:

```text
xrayebator quickstart --email EMAIL
xrayebator quickstart --without-email
```

Import invokes exactly one read-only command:

```text
xrayebator inspect --json
```

The result consumed by the GUI uses `subscription_url`; the GUI then fetches that URL to obtain the VLESS keys. Server Settings also invokes the update operation (`xrayebator update <branch>`) and can upload and run `uninstall.sh` for removal. These are controlled operations, not an interactive shell.

The active Electron GUI does **not** expose the following server features:

```text
bypass
probe-test
revoke
happ-setup
cascade
self-steal
interactive terminal menu
service logs/status
```

In particular, the Dashboard reachability dot must not be read as access to `probe-test`, and the keys page must not be read as access to `revoke`.

## Deployment protocol

The deployment authority is the remote Bash installation, not React. The Electron main process creates an SSH client, validates the target and privilege mode, and executes the following protocol:

```text
SSH connect + host-key verification
        │
        ├─ elevated `id -u`
        ├─ ordinary `/etc/os-release` read
        ├─ SFTP upload: install.sh, xrayebator
        ├─ elevated `bash install.sh`
        ├─ elevated install → /usr/local/bin/xrayebator
        ├─ elevated `xrayebator quickstart --email EMAIL` or `--without-email`
        └─ parse `subscription_url` → fetch subscription → persist the server card, connection preferences, subscription URL, and fetched VLESS links

For an existing installation, the import flow instead runs the read-only `xrayebator inspect --json`, fetches the subscription only when a public HTTPS endpoint is reported, and saves the detected state without repairing or updating the VPS.
```

Remote commands are assembled with shell-safe argument quoting. For sudo access, the secret is supplied via stdin while the command itself is kept separate. The GUI closes the SSH client after each operation and clears the in-memory private-key buffer when the client closes.

Profile operations use the same SSH path and call only the command adapters listed above. The Bash application remains responsible for backups, validation, firewall changes, Xray restarts, profile synchronization, and rollback.

## Packaging and CI

Local development and checks use the scripts in `package.json`:

```bash
npm run dev
npm run build
npm run typecheck
npm test
```

The package script is a Windows-only convenience command because it targets Windows explicitly:

```bash
npm run package
# equivalent: electron-vite build && electron-builder --win
```

The Electron release workflow is `.github/workflows/release.yml`. It runs Electron `npm run typecheck` and `npm test`, then builds platform packages for Windows, macOS, and Linux. It is the `v*` release path (or a manual workflow dispatch); it is not a claim that Electron tests run on every GUI-related push.

The separate `.github/workflows/gui-release.yml` is the legacy GUI workflow. It runs Python `ruff` and `pytest gui-legacy/tests`, builds the PySide6 native bundles, and publishes the `gui-v*` legacy release path. It is not the Electron release workflow.

`.github/workflows/ci-linux.yml` validates the Bash core: syntax checks and the full `validation/test-*.sh` suite. It is not an Electron test workflow.

Electron packaging uses the GitHub provider configured for `howdeploy/Xrayebator`. The auto-updater is initialized only in packaged builds; when active, it auto-downloads updates and installs them on application quit. Development runs do not exercise that updater path.

## Legacy GUI: `gui-legacy`

`gui-legacy/` is the archival PySide6 desktop GUI. It is a separate implementation with separate Python tests, packaging code, and native bundles. Its historical behavior includes a system proxy, TUN runtime, and keyring integration; those claims are legacy-specific and must not be attributed to the active Electron GUI.

The active desktop implementation is `src/`. A `gui-v*` artifact or a passing `gui-legacy/tests` job therefore does not mean that the Electron application was packaged or tested by that workflow.

## Limitations

- Deployment has no IPC cancellation channel. Once started, the UI can report events and errors but cannot send a cancellation request to the remote deployment protocol.
- There are no React/Electron runtime integration tests. The Electron side has unit tests, TypeScript checks, build checks, and manual/live-server validation, but no test that boots the full packaged renderer and main-process flow together.
- One Vitest test uses POSIX `/bin/sh` (`tests/unit/shell-command.test.ts`). On Windows this is a known caveat; Linux is the source of truth for that shell-specific test.
- The auto-updater is packaged-only, uses the GitHub provider configured for `howdeploy`, and follows auto-download/install-on-quit behavior; `npm run dev` does not simulate a release update.
- The GUI intentionally exposes only the command surface documented above. Use the Bash `xrayebator` interface or server-side commands for bypass, probing, subscription revocation, HAPP setup, cascade, self-steal, terminal menu, and service logs/status.
