# Changelog

User-facing Xrayebator changes. The server manager and Electron application are published from the canonical `howdeploy/Xrayebator` repository.

## [Unreleased]

Next `0.6.5` cut: the server manager plus the GUI traffic-limit card.

### Added

- **VLESS Encryption (post-quantum) on every transport.** The PQ layer (`mlkem768x25519plus`)
  used to be reachable only through the dedicated `xhttp-pq` route — the `encryption` field, the
  inbound-matching guard and the subscription filter were hard-wired to xhttp. It is now a property
  of any transport (`tcp`, `tcp-utls`, `tcp-xudp`, `tcp-mux`, `grpc`, `xhttp`), and
  `xrayebator profile-pq --name N [--transport T]` adds a PQ route for the chosen one. VLESS
  `decryption` is inbound-level, so each PQ route gets its own inbound and port whose `decryption`
  is switched to the shared `.vless_decryption` key, and the profile gains a `<transport>-pq` route
  with `pq_enabled: true`. Ordinary routes keep `encryption=none` and remain usable by every client;
  PQ routes are hidden from the v2rayNG/base64 body (a client without ML-KEM could not connect) and
  skipped with an explanatory comment in the Clash/mihomo and sing-box formats. Clients need ML-KEM
  support (HAPP or Xray 25.6+), and `profile-pq` returns a JSON error while the `mlkem_keys`
  migration has not produced keys. `profiles` gained the additive `pq_routes` counter so the desktop
  GUI can show PQ honestly (top-level `pq_enabled` only describes the first route).
- **DNS-01 certificates and a domain-based subscription (Cloudflare / Route53).** `xrayebator
  dns01-setup --domain sub.example.com --provider cloudflare|route53` issues a Let's Encrypt
  certificate by proving domain ownership with a TXT record, so **port 80 is not needed at all** —
  exactly the case where http-01 fails and the subscription degrades to `http_tls` on hosters that
  filter inbound :80. It installs the matching certbot plugin, writes provider credentials as `0600`
  root (`/etc/letsencrypt/xrayebator-dns01-cloudflare.ini`, or an AWS profile handed to certbot via
  `AWS_SHARED_CREDENTIALS_FILE`), renews through the standard `certbot.timer` with a
  `systemctl reload nginx` deploy hook, renders an nginx vhost with a **single TLS server** (no
  `listen 80`, no ACME location), opens only the subscription port in UFW, and flips the
  subscription markers to `domain_tls`, so the published URL becomes `https://<domain>/sub/<token>`.
  `xrayebator dns01-status` reports the provider, mode, domain, port, credential presence, days
  until expiry and whether the deploy hook is in place; without an email the certificate is
  registered with `--register-unsafely-without-email` (no renewal notices), matching the quickstart
  convention. Menu item `6` → `8` runs the same flow interactively, `uninstall.sh` removes the
  credential files, and the certificate stays covered by the root-owned `.certbot_owned` manifest,
  so third-party domains are never touched.
- **Clash/mihomo and sing-box subscription formats.** One subscription token now serves four bodies
  instead of two: the HAPP body, the base64 v2ray body, **Clash/mihomo YAML** and **sing-box JSON**.
  The format is negotiated per request — `?target=clash|mihomo|singbox|sing-box|v2ray|base64|happ`
  wins, then the `User-Agent` (`mihomo`/`clash`/`stash`/`flclash`, `sing-box`/`sfa`/`sfi`/`sfm`/
  `nekobox`/`hiddify`/`karing`, `v2rayNG`/`v2rayN`), and an unknown client still gets the HAPP body,
  so already-issued links keep working. All formats are rendered from the same normalized link set
  (reality `public-key`/`short-id`, Vision `flow`, `packet-encoding: xudp`, gRPC service name,
  hysteria2 with its full auth string and `skip-cert-verify` for self-signed certificates), which
  means routes and Reality parameters cannot drift between clients. Routes a client cannot use are
  **skipped with an explanatory comment instead of being emitted broken**: the PQ route (VLESS
  Encryption is supported by neither mihomo nor sing-box), xhttp in sing-box (no such transport),
  and xhttp in Clash unless `?xhttp=1` is passed (mihomo ≥ 1.19; older builds refuse to load a config
  with an unknown `network`). `subscription-userinfo` is now sent for every format — v2rayNG, HAPP,
  Clash UIs (Clash Verge, Mihomo Party) and sing-box clients all read it — and `profiles` gained the
  additive `subscription_url_clash` / `subscription_url_singbox` fields. Existing installations get
  the new handler through the `subhttp_formats_2026` migration, registered in `main_menu`,
  `quickstart` and `happ-setup`.
- **Per-profile traffic accounting and limits.** `install.sh` adds a loopback `dokodemo-door` API
  inbound (`127.0.0.1:10085`), `policy.system` stats and the `api → api` routing rule, so accounting
  works on a fresh install; the client `email` equals the profile name, which makes the Stats API
  per-profile. `xrayebator-traffic.timer` runs `xrayebator traffic-check` every 5 minutes,
  accumulating deltas from a watermark that survives Xray restarts.
  `xrayebator profile-limit --name N --limit 500MB|1.5GB|2TB|none [--reset]` sets the limit; an
  exhausted limit removes the client from the inbound (snapshot in `.traffic_clients`, transport
  flow preserved) and marks the profile `traffic_disabled`, so the subscription answers `410 Gone`
  and `subscription-userinfo` carries real `download`/`total`. Raising or clearing the limit
  restores the same client, and `expire` and traffic limits stay independent — clearing one does not
  resurrect a client blocked by the other. `profiles` exposes
  `traffic_used`/`traffic_limit`/`traffic_disabled`/`traffic_supported`, and the desktop GUI shows a
  usage chip on the profile card plus a limit dialog (presets, custom value, counter reset, limit
  removal). Migrations `traffic_stats_2026`, `traffic_user_stats_2026`, `traffic_timer_2026` and
  `subhttp_traffic_2026` are registered in `main_menu`, `quickstart` and `happ-setup`;
  `uninstall.sh` removes the new units.
- **Server monitoring with Telegram alerts** (menu item `14`). `xrayebator-monitor.timer` runs
  `monitor-check` every 15 minutes and reports only state changes: a repeat of the same event is not
  sent more often than `ALERTS_REMIND_SEC` (24 h), and a recovery is a separate message. Monitored:
  `xray`/`sub`/`nginx` services, the installed Hysteria 2 unit and the AWG interface, profile
  expiry (approaching within 3 days and already expired), profiles disabled by a traffic limit,
  subscription handler liveness and its TLS mode (`http_tls`/`local_only` means Let's Encrypt could
  not validate http-01 and the subscription went HTTP-only), a daily SNI reachability probe over the
  SNIs profiles actually use, and server reboots via `boot_id`. Configuration is verified before it
  is saved: `alerts-setup` checks the token with `getMe` and delivers a test message first, so a
  broken chat never leaves a half-configured setup. `alerts.json` (0600, bot token) lives in the
  neutral `/usr/local/etc/xrayebator/` root and the token is never printed. An undelivered alert is
  retried on the next tick without re-running the expensive SNI probe, and a failed reboot alert
  keeps the previous `boot_id` instead of losing the message.
- **DNS-01 as a deployment fallback, and the desktop UI for the new stages.** `xrayebator quickstart`
  now accepts `--pq` / `--without-pq` and `--dns01-domain/--dns01-provider/--dns01-token` (Cloudflare)
  or `--dns01-aws-access-key-id/--dns01-aws-secret-access-key` (Route53). With the DNS-01 values the
  deploy no longer degrades to `http_tls` when the hoster filters port 80: the certificate is issued
  through a TXT record, the mode becomes `domain_tls`, and `_dns01_install` renders and reloads its own
  TLS-only vhost (quickstart therefore does not overwrite it with the IP template, which would fail
  `nginx -t` because no certificate exists for the IP, and does not overwrite the subscription markers
  with the IP address, which would hand the GUI a dead `https://<ip>:8443`); renewal stays on the
  standard `certbot.timer` with the deploy hook, while the shortlived-IP timer remains `ip_tls`-only.
  The parameters are validated before any system change, and an incomplete set is a hard error instead
  of a silently ignored request. `xrayebator repair-dns01 --domain D --provider P ...` replaces an
  already-degraded `http_tls` subscription with the same flow (idempotent: an `ip_tls`/`domain_tls`
  subscription returns `{"ok":true,"skipped":true}`). In the desktop app the deploy wizard gained the
  two opt-in blocks (a PQ toggle and the DNS-01 domain/provider/credentials, with the deploy button
  disabled while the DNS-01 set is incomplete), server settings gained a per-profile **PQ** button
  (`profile-pq`, transport picker, ready link with copy), a **Subscription and TLS** card
  (`dns01-status`; in `http_tls` it explains the degradation and offers *Fix with DNS-01* ->
  `repair-dns01`, otherwise *Set up DNS-01* -> `dns01-setup`) and a **Notifications** card
  (`alerts-status`, enable/disable, test message). The bot token is deliberately still configured only
  through `alerts-setup` in the terminal, so the secret is not duplicated in the renderer.

### Fixed

- **`quickstart --pq` never added a post-quantum route.** The flag was parsed and a static test
  asserted on it, but the block calling `_pq_add_route_for_profile` sat *inside* the failure branch of
  `_happ_ensure_default_multiroute_profile`: the route was appended to a profile that did not exist
  yet, after which the deployment returned `1` anyway. The block now runs after the managed HAPP
  profile is created, and the result is reported in the JSON as `pq_route` (a server without ML-KEM
  keys keeps deploying, just without PQ).
- **Per-profile traffic accounting counted nothing on a real server.** The feature enabled only
  `policy.system.statsInboundUplink/Downlink`, but Xray registers the per-user counters
  (`user>>>NAME>>>traffic>>>uplink`) solely from `policy.levels."0".statsUserUplink/Downlink`
  (`app/dispatcher` gates them on `Stats.UserUplink`/`UserDownlink`), and both default to `false`;
  `statsInbound*` is inbound-level statistics. Without the level flags `statsquery` returned no user
  entries, `.traffic.used` stayed zero and limits never fired — on a fresh install and on any server
  that ran the traffic migration. `install.sh` now writes the level flags, `traffic_stats_2026` adds
  them to existing configs, and the new idempotent `traffic_user_stats_2026` migration repairs
  servers whose earlier migration marker already exists (the marker would otherwise block a re-run).
  `profiles` now reports `traffic_supported: false` unless the api inbound and the level flags are
  actually present, so the GUI hides limit management instead of offering a limit nobody enforces.
- **AWG junk parameters could ship `S1 == S2`.** `_awg_gen_junk` guarded only `S2 != S1 + 56`, while
  the spec and `validation/test-awg-lifecycle.sh` require all of `S1..S4` to be unique: on 3000
  seeded runs the old code collided 19 times, so roughly every 160th install got equal `S1`/`S2` and
  CI failed at random. The legacy `_awg_ensure_31_params` upgrade path also generated `S3`/`S4` in
  `12..150` instead of the `12..64` Amnezia validator limit.

## [0.6.5-beta.2] - 2026-10-14

Second beta cut: the manager and GUI code are unchanged from `0.6.5-beta.1` — this
release is the same build with a full live validation stamp and a documentation
cleanup. **Still a beta: if you need a proven build, stay on 0.6.0.**

### Testing

- Live matrix: 8 fresh deploys across Ubuntu 22.04/24.04 and Debian 12/13 on 4
  independent hosters (reachable from Russia): 7 full `install.sh` + `quickstart`
  runs with ACME, a Let's Encrypt certificate on the IP and a publicly answering
  subscription, plus 1 deploy on a hoster filtering inbound port 80 — the
  `http_tls` fallback completes the install, keys over SSH, a self-signed cert
  for future backends, quickstart re-run stays idempotent.
- Both TLS branches (`ip_tls` and `http_tls`) confirmed live, including two
  German VPSes; the CLI self-update main→dev lands on the dev HEAD with
  `backend-status` / `profiles` responding (the 0.6.5 GUI contract).

### Documentation

- HAPP provisioning scenarios (quickstart email/without-email, `http_tls`
  degradation, `inspect`, `happ-setup`) synchronized in ru/en/zh
  `configuration.md`;
- mojibake left in the `0.6.5-beta.1` release notes is fixed.

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
