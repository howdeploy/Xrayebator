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

Dashboard displays the saved server cards. Each card shows the title with its location beneath, a status line (`Configured` in green, `Partially configured` in yellow, or `Imported`), and a row of three tiles — operating system, active routes, and SSH access (`user@host:port` plus where the secret lives: password or key in the system keychain, or this session only). The tile values come from the server card and the read-only inspection, so the OS, route count and SSH user are whatever the server actually reports. A three-dot menu in the access tile opens the access form for that card. Actions for keys, settings, and removing the card sit at the bottom. On an empty Dashboard the operator chooses between two scenarios: **Deploy a new server** (install Xrayebator on a clean VPS) and **Connect an existing server** (find an installed Xrayebator over SSH and open its panel without touching the installation). With servers already present, `Add` opens the same choice. Its reachability check is a bounded TCP check performed by the Electron main process; it is not the server-side `probe-test` command. The language selector switches between `RU`, `EN`, and `中文`.

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

The wizard shows a step index and a live console of the work actually performed: the SSH connect, the `xrayebator inspect --json` call, the reported component statuses, the subscription probe and the result. The subscription URL is a bearer credential, so its token is masked (`…`) before it reaches the console; passwords and key bytes never appear there at all.

### Server keys

Server keys refreshes the subscription from the saved `subscription_url` and displays the returned VLESS routes. Each VLESS link can be copied or rendered as a QR code; the subscription URL can also be copied, and the page offers a copy-all action. This page does not create a separate server-side subscription or rotate a subscription token (rotation lives on the profile cards in Server settings). When the server has multi-protocol backends, the page also shows their keys from the persistent local store: one Hysteria 2 card per granted profile with the `hysteria2://` link (copy + QR) — the card chip names the owning profile (`HYSTERIA2 · <profile> · UDP :<port>`), and one AmneziaWG card per granted profile with the client `.conf` — the `Endpoint`/`Address` values are surfaced as key fields, and the full `.conf` (service comment header stripped) is available as text and QR for import into AmneziaVPN/AmneziaWG. Backend cards paint immediately from the persisted store and refresh in parallel with the VLESS routes; a per-card spinner shows only while that card's data is being fetched. The AWG card carries two QR codes: the plain one for the standalone AmneziaWG client and «QR · AmneziaVPN» — the app-native compressed `vpn://` shape (`amnezia-awg2` container, server-side junk fields, `protocol_version` 3.1), which is the recommended import path for the full AmneziaVPN app.

### Server settings

Server settings first authenticates over SSH. When the card already has a keychain-backed SSH password or a persisted private key, the page attempts to connect automatically and then shows only the profile panel — the access form appears only when there is no saved secret or after a failed connection. The access summary and the "Change access" action live on the server card in the dashboard, not inside the profile page. Once connected, the page can:

- list existing profiles;
- create one or more profiles and delete profiles (profile names are unique: the GUI pre-checks a name collision before creating — deletion is per-profile, so unique names keep it precise);
- choose `xhttp`, `tcp`, `tcp-utls`, `tcp-xudp`, `tcp-mux`, or `grpc` transports — or select one of the two multi-protocol backends (Hysteria 2 / AmneziaWG 3.1 cards below the transport grid). Clicking a backend card only selects the protocol (selected VLESS transports deselect it and vice versa); the profile is created by the «Create profile» button, and only the selected backend issues its key — the underlying VLESS profile uses the recommended `xhttp` transport;
- change a profile fingerprint, choose an SNI from `sni-list`, or enter an SNI;
- change a profile route's port or choose a random port;
- update the server installation (a branch menu: "As pinned on the server" — `.current_branch`, otherwise main; **main is the latest stable release**; **dev is the latest build with every feature but may be unstable**; switch back from dev by updating to main);
- uninstall the server installation after confirmation;
- reset the pinned SSH host key after explicit confirmation;
- manage the multi-protocol backends (menu parity with items 11–13): the combined panel "additional protocols" (they are in development — the interface and behavior may change) shows the Hysteria 2 and AmneziaWG state (version, port, TLS mode / interface, junk summary) with install/uninstall, the subscription kill switch for `hysteria2://` lines and the AWG 3.1 toggle — the last two with explicit confirmation;
- per-profile backend boxes in the profiles list, titled by the profile name with the protocol in the subtitle and a green status line (`Active · SNI …` or `Active · UDP <port>`): QR (plus «QR · AmneziaVPN» for AmneziaWG), Expiry, Revoke and Delete. Deleting a profile revokes its backend keys immediately — the AWG peer is removed from `awg0.conf` and the Hysteria password from `server.yaml` (no orphaned credentials) — and the name becomes free for reuse. Full key copying lives on the Server keys page.

SNI and port are inbound-level settings: changing them can affect every profile sharing that inbound. Fingerprint is different: it is a client-side value stored per profile/route and does not change the other routes. The server command reports the result and whether reconnecting is required.

## SSH and security

The GUI supports SSH password authentication or a private key, with either direct `root` execution or elevated commands through `sudo`. A private key is selected through the native Electron file dialog; the main process reads the bytes, stores them in the operating-system keychain via `keytar` (Windows Credential Manager, macOS Keychain, or Linux Secret Service), and returns to the renderer only a non-secret credential id plus the display file name. The key is reused across later operations and app restarts without re-picking the file. If the OS keychain is unavailable, the key is kept only in main-process memory for the current app session and the UI warns that reuse after restart is unavailable; there is no plaintext fallback on disk.

The SSH login password is persisted to the operating-system keychain after the first successful authentication and reused across later operations and app restarts; the server card stores only its non-secret credential id. A distinct sudo password and an encrypted-key passphrase are never persisted — they are asked again when needed. Private-key bytes and password values never cross the preload boundary: the renderer receives only credential ids and display names. `electron-store` persists the server card and connection preferences, the subscription URL, and the fetched VLESS links (bearer/client credentials), as well as the username, authentication method, privilege mode, credential ids, display key name, installation diagnostics, and the SHA-256 SSH host-key pin. Protect the local application data; if the subscription URL or VLESS links leak, revoke the subscription from Server settings (full revocation rotates the key as well). A later fingerprint mismatch fails closed before commands are executed; an intentional server reinstall requires an explicit host-key reset in Server settings. Removing the last card that references a credential deletes the matching keychain entry; shared references are preserved.

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
xrayebator profile-create --name NAME [--transport T] [--port P] [--count N] [--expire DATE]
xrayebator profile-delete --name NAME
xrayebator profile-revoke --name NAME [--full]
xrayebator profile-expire --name NAME --expire DATE|epoch|none
xrayebator fp-change --name NAME [--route R] --fp FINGERPRINT
xrayebator sni-change --name NAME [--route R] --sni SNI
xrayebator sni-list
xrayebator port-change --name NAME [--route R] --port PORT|random
xrayebator bypass list|add --domain D|remove --domain D|reset|bundle [--group a,b,c]
```

Backend management additionally invokes:

```text
xrayebator backend-status
xrayebator hysteria2-install [--port P] [--grant-all] / hysteria2-uninstall / hysteria2-grant --name N / hysteria2-subbody --on|--off / hysteria2-link --name N
xrayebator awg-install [--grant-all] / awg-uninstall / awg-grant --name N / awg-conf --name N / awg-31 --on|--off
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
probe-test
happ-setup
cascade
self-steal
interactive terminal menu
service logs/status
```

In particular, the Dashboard reachability dot must not be read as access to `probe-test`.

Server settings additionally provides:

- **Subscription revocation** — a per-profile button opens a menu with two modes. "New link only" reissues the `sub_token` (the previous URL stops working; routes and keys stay the same). "Full revocation" also rotates the uuid in every inbound of the profile, so devices that already downloaded the config are cut off immediately — the only way to actually close access through a leaked link.
- **Profile expiry** — the date travels to the client in the subscription header and is enforced server-side: the `xrayebator-expire.timer` systemd timer runs `xrayebator expire-check` every 10 minutes and removes the client from the inbounds once the expiry timestamp passes. A date selected without a time is inclusive through `23:59:59` in the server's local timezone. The GUI displays the server's calendar date from `expire_date`, so it stays correct even when the desktop and VPS use different timezones. Extending the date restores the same client. The profile chip shows the expiry date, turns warning-toned within three days before the cutoff and danger-toned after it passes. An expiry can also be set at profile-creation time; dates are chosen with an in-theme calendar widget (past days disabled) with +7/+30/+90/+365 presets. If the connected server is older and does not report expiry support, the GUI warns about the outdated server instead of pretending profiles are unlimited.
- **Error surfacing** — CLI failures are shown with a human-readable reason taken from stderr, falling back to stdout; an unknown command on an outdated server comes with an update hint instead of a bare exit code.

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
- The GUI intentionally exposes only the command surface documented above. Use the Bash `xrayebator` interface or server-side commands for probing, HAPP setup, cascade, self-steal, terminal menu, and service logs/status.
