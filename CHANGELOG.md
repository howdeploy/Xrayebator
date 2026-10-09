# Changelog

User-facing Xrayebator changes. The server manager and Electron application are published from the canonical `howdeploy/Xrayebator` repository.

## [0.6.5-beta.1] - 2026-10-08

Multi-protocol stage: Xray Reality is joined by Hysteria 2 (UDP/QUIC) and AmneziaWG 3.1
(system VPN), a neutral backend registry with per-profile grants and lifecycle, a
HAPP client-routing generator with split routing, softer SNI defaults, a graceful
`http_tls` degradation path for hosters that filter port 80, and a wave of GUI feedback
polish. **0.6.5 is in testing — if you need a proven build, stay on 0.6.0.**

### Added

- **Hysteria 2 backend** (multi-protocol slices 2–3): install/uninstall/status via the
  registry, a dedicated `hysteria` system user with its own `hysteria-server.service`
  (CAP_NET_BIND_SERVICE), QUIC buffer sysctls, per-profile grants (`hysteria2-grant`)
  with passwords stored in the profile JSON, server config regenerated from profiles
  with rollback, adaptive TLS (Let's Encrypt cert copied with a renewal deploy-hook,
  or self-signed with `insecure=1` client links), and `hysteria2://` lines appended to
  both subscription bodies behind a kill switch.
- **AmneziaWG 3.1 backend** (slices 4–5 + 3.1): kernel module via DKMS (amnezia PPA
  with a manual source-build fallback), `awg0` interface with junk params matching the
  official Amnezia dialect, per-profile peers with keypair + preshared key, `awg0.conf`
  regenerated from profiles, client `.conf` and `awg-conf` JSON for the GUI, AWG 3.1
  format on by default (`HeaderProtectionKey`, `RandomTrailers`, `S1`–`S4`) with an
  `awg-31` toggle and explicit re-download warnings, and the GUI delivering keys in the
  app-native `vpn://` shape for AmneziaVPN.
- **Multi-protocol GUI**: a "multi-protocol backends" panel in Server settings with
  official Hysteria/Amnezia logos, backend profile cards alongside VLESS cards
  (create flow with an explicit protocol choice — a new profile receives keys only
  from the chosen backend), per-backend QR (including "QR · AmneziaVPN"), expiry,
  revoke and delete with immediate backend-key revocation on profile deletion.
- **HAPP client routing** (`bypass` CLI + generator): managed HAPP profile can carry
  split routing from bypass groups, with placeholders (`{{GEOIP_URL}}`, `{{GEOSITE_URL}}`,
  `{{LAST_UPDATED}}`) resolved per subscriber — geo databases are downloaded through the
  subscription itself.
- **quickstart `http_tls` graceful degradation**: when Let's Encrypt cannot validate
  http-01 for the IP (`Connection reset by peer` — the hoster filters port 80), the
  deploy no longer dead-ends: markers switch to `http_tls`, the subscription stays
  loopback-only (there is no public subscription URL at all — the GUI loads keys over
  SSH from `127.0.0.1:8080`), a self-signed certificate is generated for future backends,
  and the result JSON carries `degraded:true` / `tls_mode:"http_tls"` / `certbot_reason`.
  Re-running quickstart after the hoster unblocks port 80 restores HTTPS.
- SNI candidates updated from the 03.09.2026 reachability measurements; the default SNI
  for new profiles is `www.cloudflare.com`.
- Server country in key names: the HAPP profile fragments are labelled with a country
  flag and name (`🇫🇮 Finland · happ-...`) resolved from the server IP geo databases.
- `validation/` grew from 28 to 34 scripts: backend registry, Hysteria 2 lifecycle,
  AmneziaWG junk/renderers/lifecycle, HAPP client routing, legacy profile port sync,
  quickstart `http_tls` fallback, apt-lock race, profile revoke/expire CLI.
- Branch choice for server updates: the "Update Xrayebator" button became a menu —
  "Auto — as pinned on the server" (previous behavior), "main — latest stable release",
  "dev — every feature first" (may be unstable): a server can be moved to the dev
  manager before the merge without polluting main; switching back is an update from main.

### Fixed

- `revoke --full` crashed on single-route profiles (invalid jq path).
- `xrayebator profile-delete` printed colored status lines into stdout JSON; the CLI
  path is JSON-clean now and backend grants are revoked in the same command (no
  orphaned AWG peers or Hysteria passwords).
- Backend keys are granted only for the explicitly chosen protocol — creation no longer
  issues keys from every installed backend.
- AWG ports moved out of the ephemeral range and ufw reloads are avoided during batch
  firewall updates.
- Dead duplicate function definitions in the single-file manager removed (a shadowed
  validator whose body would have clobbered subscription markers if ever called).
- The GUI no longer shows a dead `https://IP:8443` subscription URL on degraded
  (`http_tls`) servers: no public link is displayed or saved at all, keys are fetched
  over SSH, and the server is stored as "partially configured" with a degraded badge.
- Backend key creation/revoke/expiry dialogs match the VLESS card semantics
  (danger-soft confirmations, device notes, expiry presets).

## [0.6.0] - 2026-10-01

Access control in the panel: subscription revocation (link-only or full), profile expiry
enforced server-side by a systemd timer, `410 Gone` for expired profiles, and a themed
calendar picker; self-update now remembers its branch.

### Added

- Subscription revocation in Server settings: a per-profile button opens a menu with two modes. "New link only" reissues the `sub_token`; "full revocation" also rotates the uuid in every inbound of the profile, so devices that already downloaded the configuration are cut off immediately — the only way to actually close access through a leaked link.
- Profile expiry dates: `profile-create --expire`, `profile-expire`, the `expire` field in the profile JSON, a date chip (warning tone within three days before expiry, danger tone after) and an in-theme calendar editor in the GUI (past days disabled, +7/+30/+90/+365 presets; outdated servers without expiry support are reported instead of silently shown as unlimited), plus server-side enforcement — a `xrayebator-expire.timer` systemd unit runs `xrayebator expire-check` every 10 minutes and switches an expired profile off (the client is removed from the inbounds and restored on renewal).
- The subscription-userinfo `expire` header now has a UI path: HAPP and other clients display the date handed out by the subscription.

### Fixed

- Expired or disabled profiles now receive `410 Gone` instead of subscription routes.
- `xrayebator update <branch>` now pins the branch in `.current_branch`: previously the GUI’s "Update Xrayebator" silently rolled an updated server back to the release branch and the new commands disappeared.
- GUI failures now surface the real reason (parsed from stderr, falling back to stdout); an unknown command on an outdated server is answered with an update hint instead of a bare exit code.
- A date-only profile expiry now includes the selected day through `23:59:59` in the server's local timezone; explicit times use that timezone as entered. The server returns its own `expire_date` for GUI display, so a desktop in a different timezone still shows the selected server-local calendar day (covered by a UTC−7 server / UTC+14 client regression test). Date/time fields with leading zeroes such as September (`09`) are accepted correctly.

## [0.5.5] - 2026-09-25

Connecting to servers that already run Xrayebator, plus fixes found while testing on a live VPS.

### Added

- Optional email during deployment: `quickstart --without-email` registers Certbot with `--register-unsafely-without-email` instead of substituting a fake address; the GUI offers both modes and explains that renewal notices and ACME account recovery are unavailable without an email.
- Separate "deploy a new server" and "connect an existing server" flows. Import is strictly read-only (`xrayebator inspect --json`), recognizes Xrayebator installations only, and imports a partially configured server with honest component statuses.
- SSH login password is stored in the operating-system keychain after the first successful authentication and reused across restarts; the server card keeps only its non-secret credential id.
- Server card shows a summary of the saved access (`user@host:port`, where the secret lives) with a three-dot menu to change it, plus the reported OS, active route count and SSH user as icon tiles.
- The import wizard shows a live console of the work performed, alongside the step index.

### Changed

- Server Settings auto-connects with saved credentials and shows the profile panel directly; the access form appears only when there is no saved secret or a connection failed. The installation-status table was removed as a duplicate of the deployment and import consoles.
- The subscription token is masked in the deployment log and import console, because it is a bearer credential.

### Fixed

- `quickstart` no longer fails with `apt-get install nginx failed` when `unattended-upgrades` holds the apt/dpkg lock: every install waits for an active `unattended-upgrade` worker within a 12-minute budget and passes `-o DPkg::Lock::Timeout=180`.
- Bash validation scripts no longer die with `tr: write error: Broken pipe` on Ubuntu (`pipefail` plus an early-exiting reader).

## [0.5.0] - 2026-09-22

The first combined release of the updated server manager and **Xrayebator Desktop GUI**.

### Added

- Electron + React + TypeScript GUI for managing VPS instances over SSH.
- Dashboard, server add wizard, keys page, and QR codes.
- Profile creation/deletion and fingerprint, SNI, and port changes.
- RU / EN / 中文 interface switching.
- Standard HAPP schema-v3 profile with seven routes and one subscription URL.
- Improved installer IPv6 scenarios, DNS fallback, and IPv6 URL formatting; automated public IP-TLS for IPv6-only VPS is still not claimed and requires domain TLS.
- Installer step control with `--check` / `--resume` / `--fresh`.
- A 24-script Bash validation suite and Electron unit tests.

### Changed

- Runtime configuration changes go through backup, Xray validation, and rollback on failure.
- Installer, update, firewall ownership, and lifecycle paths have additional checks.
- The archival PySide6 GUI is separated into `gui-legacy/`; the active application is the Electron GUI in `src/`.
- Release packages use clear platform suffixes: `-win`, `-mac-arm64`, and `-linux`.
- Documentation is synchronized in Russian, English, and Chinese.

### Fixed

- Migration, HAPP subscription, IPv6 DNS/URL fallback, certificate, and profile synchronization scenarios.
- GUI deployment, SSH validation, JSON CLI responses, SNI/port-change, and CI issues.

### Limitations

- The full interactive menu, bypass, probe-test, revoke, happ-setup, cascade, self-steal, and service logs remain CLI-only.
- Hardening tasks found in a later audit around `safe_jq_write`, lifecycle rollback, JSON escaping, and existing-inbound validation are not included in this release.

Detailed English release notes: [docs/releases/v0.5.0.en.md](docs/releases/v0.5.0.en.md).
Russian release notes: [docs/releases/v0.5.0.md](docs/releases/v0.5.0.md).
