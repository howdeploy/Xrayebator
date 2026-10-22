# Changelog

User-facing Xrayebator changes. The server manager and Electron application are published from the canonical `howdeploy/Xrayebator` repository.

## [Unreleased]

### Fixed

- **`channel-test` labelled every route as post-quantum.** The shell variable holds the string
  `false` rather than an empty flag, so `${pq:+, PQ}` appended ", PQ" to every successful route. The
  JSON was correct all along — only the human output lied, and on a live 8/8 run every line claimed
  PQ. The suffix is now added only when `pq == true`. Verified on two live servers: with the fix only
  `happ-xhttp-pq` carries the mark (166–272 ms per route), without it all seven routes did.
- **The AmneziaWG install banner said "2.0" while 3.1 was on.** The banner was hard-coded, but 3.1
  (`HeaderProtectionKey`, `RandomTrailers`, `S3`/`S4`) has been the default since the 3.1 stage — a
  live install printed "AMNEZIAWG 2.0 УСТАНОВЛЕН" right next to a junk block that already carried the
  3.1 fields. The banner no longer names a version; a separate `Формат:` line reports the format from
  the backend registry (`three_enabled`).

## [0.7.0] - 2026-10-22

The `0.7` line: the whole multi-protocol stage in one release — Hysteria 2 and AmneziaWG 3.1
backends, PQ on every transport, DNS-01, four subscription bodies from one token, per-profile
traffic limits and Telegram alerts — plus the GUI wave that came after `0.6.5-beta.2` and a long
tail of stability and security fixes. Validation: 42 Bash scripts, 172 unit tests, three live
deployments (two fresh control runs on Ubuntu 22.04 and a production server) with every route
verified by a real Xray client, plus control deploys on four distributions.

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
- **An ACME staging contour, and `dns01-test` to prove a domain and a token before spending
  production quota.** Let's Encrypt limits a single exact set of identifiers to 5 certificates per
  168 hours (refilling one every 34 hours) and one account to 5 *failed* validations per identifier per
  hour; a session of debug issuances can therefore exhaust the budget and block the next meaningful
  run — which is exactly what happened on a live server (`retry after 2026-10-19 02:02:28 UTC`).
  `--staging` (or `XRAYEBATOR_ACME_STAGING=1`) now switches the ACME paths of `dns01-setup`,
  `repair-dns01` and `quickstart` to the staging environment (`--test-cert`), where the same limit is
  30000 orders per week; the run reports `staging:true`, warns that the certificate is signed by an
  untrusted test root, and records the contour in `/usr/local/etc/xray/.acme_staging`.
  `dns01-status` reports the contour from the **certificate itself** (an issuer containing
  `(STAGING)`), using the mark only as a fallback when the certificate is unreadable: renewals go
  through `certbot renew` outside xrayebator and would otherwise leave the mark stale — verified live,
  where a staging run against an engineered precondition left a mark while `live/<ip>` already held
  the production certificate, and the status command (and therefore the GUI badge) claimed the
  subscription was untrusted. The production path
  now always names the ACME endpoint explicitly (`--server https://acme-v02…`): without it a repeat
  issuance under the same `--cert-name` inherits the server from its renewal configuration and a
  "production" run would silently stay in staging. The new `xrayebator dns01-test --domain D
  --provider P [--token T | --aws-*]` performs a *verification-only* issuance — staging, its own
  certificate lineage, no deploy hook — and touches neither the subscription, nor nginx, nor the
  markers, nor the firewall; it returns `issuer`, `not_after`, the TXT name to check, and, on failure,
  the parsed certbot reason. Packaged as `_dns01_test_run` / `_dns01_test_certbot_args_pure` and
  guarded by `validation/test-dns01-certbot.sh`.
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
- **`xrayebator channel-test` — проверка каналов настоящим клиентом Xray.** Новых тестов с пингом и
  проверкой каналов в наборе не было: `validation/` — это pure/static-проверки, а живой спайк делался
  руками. Команда поднимает для каждого маршрута профиля локальный клиент Xray (SOCKS5) с параметрами
  из ссылки подписки и прогоняет через него реальный запрос в интернет, печатая JSON с латентностью:
  `working`/`checked`, по маршруту — `ok`, `http`, `ms`, хвост лога клиента. Let's Encrypt тут не
  участвует (Reality и VLESS Encryption шифруют сами), поэтому проверка работает и на `http_tls`-
  подписке, и до выпуска сертификата; проверяются и PQ-маршруты. На живом VPS матрица дала 8/8
  (xhttp-legacy, xhttp-pq, tcp-mux, grpc, tcp-vision, tcp-utls, tcp-xudp, tcp-pq) с латентностью
  152-252 мс. Guarded by `validation/test-channel-test-cli.sh` (чистая сборка клиентского конфига,
  диспатч, JSON-гигиена, независимость от LE; сетевой прогон в CI не запускается).
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
  `repair-dns01`, otherwise *Set up DNS-01* -> `dns01-setup`).
- **Telegram alerts left the desktop app** (GUI). Server settings carried a **Notifications** card
  (`alerts-status`, enable/disable, test message) although the bot token could only be set in the
  terminal. That split had no upside: the card mixed a one-time server secret into a screen used for
  per-profile work, and it existed only to show state the terminal reports better. Alerts are now
  terminal-only from end to end — `alerts-setup`, `alerts-status`, `alerts-test`,
  `alerts-enable|alerts-disable` — and the GUI no longer ships the IPC channels, the renderer card or
  the localised strings for them, so the root-owned token has exactly one entry point.
- **Server settings became three sections instead of one long scroll** (GUI). A UX audit of the desktop
  app found the settings screen to be a wall of five sections — connection, profile creation, profile
  list, extra protocols and subscription/TLS — where reaching the profile list (the
  reason for most visits) meant scrolling past two forms. The screen is now split into **Create profile |
  Existing profiles | Extra protocols | Subscription and TLS** (`role=tablist`/`tabpanel`), the sections are
  hidden rather than unmounted so a half-typed profile name survives a tab switch, and the connection
  block stays a common gate. The same pass fixed a batch of smaller findings: the update-branch menu is
  now a HeroUI `Dropdown` (keyboard, Escape, click-outside, chevron) instead of a hand-rolled popover
  whose styles referenced a CSS variable that did not exist (`--text`), deployment and import logs are
  selectable and gained a **Copy log** button (the operator's main diagnostic artifact used to be
  unselectable), status indicators and the calendar carry localised `aria-label`s, confirmation dialogs
  for backend actions name the action on the title and the red button instead of a generic
  "Confirm"/"Done" pair, dialog errors are shown inside the dialog instead of behind its overlay,
  clipboard writes report failure instead of silently pretending to succeed, `--text-2` was raised to
  the WCAG-AA compliant `#8b949e`, small hints went from 11px to 12px, the *Create profile* button moved
  to the end of the form with an explanation of why it is disabled, the empty state of the keys page
  links to the profiles, and the i18n files are now guarded by a key-parity test
  (`tests/unit/i18n-parity.test.ts`) plus the first render smoke test of the settings screen. The
  profile row itself lost its eleven-button wall: it now shows **Copy** and **Settings**, and the
  settings window (an `AlertDialog` — it no longer pushes the profile list around by expanding in place)
  carries four labelled groups (route, limits, access, deletion), each with one line explaining what the
  action does and what it affects — SNI/port are inbound-level and touch every profile on the port,
  fingerprint is client-side, expiry and traffic limit are profile-level; the Clash/sing-box links moved
  to the Keys page, where they belong. Destructive "soft" buttons (`danger-soft`: delete profile, uninstall a
  backend, revoke keys) no longer inherit HeroUI's light-pink fill: the palette defines them as a
  muted red tint (24% of `--danger` over the card, 32% on hover) with HeroUI's standard danger text, which is
  AA-compliant and reads as an action rather than a highlight — only the background is overridden, so the
  label stays exactly as legible as it was before.
- **The profile list is its own page** (GUI). It shared a screen with the create form, so a routine
  trip to one profile scrolled past a form first. The list now lives on a **Server profiles** screen:
  the tab strip keeps the entry («Существующие профили», right after Create profile) but it opens
  that screen instead of swapping a panel, and its back button returns to the dashboard. The two
  screens are one component with a `mode` prop, so switching between them no longer re-runs the SSH
  work — connection, profiles, backends and subscription status are fetched once per opened server.
  Cards gained a transport icon and an `Active`/`Disabled` status (expired or over the traffic limit),
  and the header gained a search over name/SNI/subscription URL plus an all/active/disabled filter. A
  "Shown: N" line counts the cards actually rendered (the profile plus one per granted backend).
  Expiry and traffic now carry calendar/database icons — "valid until 2026-11-16" and "182 KB" were
  readable only by format. From the reference layout
  the progress bar, pagination and the duplicated footer were deliberately dropped: none of them
  measures or shows anything a handful of profiles does not already show.
- **`xrayebator backend-start --type hysteria2|awg`** brings an *installed* backend whose unit is not
  active back up; the desktop GUI shows it as the **Start** button next to the honest "Not running"
  state. The only mutation is `systemctl start` (plus the kernel module for AWG) and it answers JSON —
  `already:true` when the unit was already running. Re-running `awg-install` on an existing installation
  now performs the same repair instead of answering "already installed" without checking anything.

### Changed

- **The server deployment form is a quarter shorter.** It was one column of single-row fields ending in
  four stacked card groups. Three things changed: the VPS address now shares a row with the SSH port
  (which keeps a 104 px column of its own), the two opt-in cards (PQ route, DNS-01) sit in one
  "Additional options" row instead of two groups with their own headings — both still off by default —
  and the host-key note moved out of the form into the footer of the progress card, pinned to its bottom
  under the console (that card stretches to the form's height, so the bottom was dead space; the note
  used to hang as a lone line in the page header).
  Measured on the built bundle at 1024×720: the form went from 1182 px to 853 px and the page from
  1302 px to 973 px. The step rows and the console are untouched, no box was shrunk and no field was
  removed; the import page got the same host/port row.

- **The "Subscription and TLS" card became compact and collapsible.** It used to be one long card
  whose status was a run-on line (`mode · domain · provider · cert days`) with the whole DNS-01 form
  always open underneath. The collapsed card now shows a certificate icon, the mode as a badge next to
  the title (green for HTTPS modes, amber for `http_tls`), and three labelled values — domain, provider
  and certificate days left (amber under two weeks) — each in a monospaced box spanning its column.
  Clicking the header, or the primary action, expands the form, and the explanatory hint moved into
  that expanded state.
- **The profile settings window puts the current SNI in the corner of the "Route" box.** It used to hang under the profile name
  in the header: a bare mono line with no caption, which competed with the title in a narrow window (271 px) and read as an
  orphan in a wide one. The header is now exactly two lines — badge, kicker, profile name — and the SNI sits in the top-right
  corner of the "Route" group, on the same row as the group title, as a bare value with no label, the way it used to appear under
  the name. A long hostname is truncated with the full value in `title`, so the row height never depends on the SNI length.
  Buttons were not touched.

- **The "Done" button is green, not glowing.** The success state of the five action dialogs (expiry, limit, fingerprint, SNI,
  port) used a 14 px green `box-shadow`, which read as a blur — as if the action were still running or the button were disabled.
  It now uses the same green as the deploy screen's finished step: green text, a 14% green fill and that step's
  `rgba(63,185,80,.35)` outline — drawn with `outline-offset: -1px` so the line appears even on a HeroUI button that has no
  border of its own and never changes the button's size — with no shadow at all, and the check mark pops in with the same
  easing as that step.

### Fixed

- **The Keys page printed every key three times.** The Clash/mihomo and sing-box links of a
  subscription were rendered next to the main keys unconditionally, so each profile showed the same
  token in three shapes and the key list read as duplicated — while the product targets HAPP, Hiddify
  and v2rayNG, which all use the plain subscription. The formats are now an opt-in view: the page
  serves the main set (HAPP/v2ray subscription plus the VLESS links) by default, and the
  «Clash / sing-box formats» toggle in the header adds the second view. The choice is kept in
  `localStorage`, because it describes the operator's client rather than a particular server, and the
  toggle only appears when the server actually returns format links. Verified by rendering the page
  in an offscreen Electron build with a stubbed store: five key cards plus the copy-all button by
  default, six cards with the toggle on.
- **`xrayebator-uninstall` left the optional backends running.** It deleted the neutral
  `/usr/local/etc/xrayebator` root but never stopped `hysteria-server.service` or `awg-quick@awg0`,
  so both units stayed enabled with their configs gone and the first reboot produced two failed
  units; the Hysteria binary, sysctl file and certbot deploy-hook, the `awg0` interface, the AWG
  sysctl and `modules-load.d` entries also survived. The script now tears the backends down before
  deleting state — the AmneziaWG package and kernel module still stay in the system, exactly as
  `awg-uninstall` documents — and the confirmation banner names the backends. Guarded by the two
  backend lifecycle validation tests.
- **The "valid until" line on the Keys page appeared late and pushed the card down.** Expiry came only from
  the `profiles` list, which is fetched over SSH, while every other piece of that page (VLESS links,
  hysteria2 links, AWG configs, Clash/sing-box URLs) is drawn instantly from the server card cached in the
  local store. So a backend card first rendered without the date and then grew a paragraph when the SSH answer
  arrived — the boxes visibly jumped. Expiry is now cached next to the keys (`profileExpiry` on the server
  card, written by `profiles:list` as a full set so a deleted profile disappears), rendered on the first
  paint, and replaced by the fresh list as soon as it arrives — a renewed or cleared date can never stay
  stale on screen. A profile present only in the AWG config cache and absent from both sources shows no line
  at all instead of a fabricated "unlimited". Caching alone did not finish the job: the renderer kept receiving
  the card from a server list read once at startup, so `profiles:list` wrote the cache while the page still
  opened with a stale copy and filled the dates in only when the SSH answer arrived (reported again after the
  first fix). Every navigation to a server page now re-reads the card from the local store before rendering,
  so the page mounts with the full cache and nothing grows in a second stage. Guarded by
  `tests/unit/server-keys-render.test.ts` (asserts the date is in the markup of the very first render, where no
  effect can have run), `tests/unit/server-store.test.ts` and `tests/unit/gui-cache-wiring.test.ts` (a server
  page opens with a card re-read from the store).

- **The SNI probe accepted hosts it could not reach, so brand-new profiles got dead routes.**
  `openssl s_client` prints `Verify return code: 0 (ok)` **even when the handshake never happened** —
  with no peer certificate there is nothing to verify, and `0` means "nothing failed to verify", not
  "the chain is valid". The reachability probe grepped exactly that string, so `online.vtb.ru` (a
  TLS 1.2-only site, while Reality requires TLS 1.3 — it answers `sslv3 alert handshake failure`,
  `no peer certificate available`) and `splitter.wb.ru` (no TLS at all) were classified as *reachable*.
  Measured live on 2026-10-20: of six freshly created PQ routes only two worked, and the four dead ones
  (`tcp`, `tcp-utls`, `tcp-mux`, `xhttp`) all carried such an SNI — switching the SNI of the very same
  port and route to `www.cloudflare.com` returned HTTP 200, both for a PQ route (5174 ms) and for a
  plain one (5180 ms). So the PQ layer itself was fine; the selection criterion was not. The new pure
  seam `_sni_tls_output_ok_pure` now requires a *completed* TLS 1.3 handshake **with a verified
  certificate** (no `no peer certificate`, no alert, no `Cipher is (NONE)`, `TLSv1\.3` present,
  `Verify return code: 0`), and a success is confirmed by a second attempt because some hosts answer only
  intermittently (`splitter.wb.ru` failed with alert 40 in one measurement and passed in another), and a
  host that completes the handshake but never answers HTTP is rejected too — `www.wildberries.ru` passed the
  TLS probe in 1.7 s and returned `000` to `curl`, and a route with that SNI hung for 10 s (`reality` sends a
  real ClientHello to the dest and waits for the session to continue, not just for a certificate); the HTTP
  status itself is irrelevant, only that a response arrived,
  and both `_monitor_sni_reachable` and `probe-test` use it — `probe-test` had been printing `TLS OK`
  for the same dead hosts, and its budget now matches the selection one (3 s) — with the old 8 s a host that
  completed a handshake in 6 s was displayed as `TLS OK` while selection rejected it, so the diagnostic
  contradicted the behaviour. Candidate order is also bounded now: the per-transport default, then at most
  `SNI_REACH_HEAD_MAX` (4) entries of `sni_list.txt`, then the global fallbacks
  (`www.cloudflare.com`, `api-maps.yandex.ru`, `www.google.com`), then the rest of the list. The list
  is *not* cloudflare-first as an old comment claimed — it starts with `ru_whitelist` (`www.ozon.ru`,
  …), which is entirely dead from a foreign VPS, and every dead candidate costs a full timeout, so
  profile creation crawled for minutes. `((idx++))` in that loop was replaced by `idx=$((idx + 1))`:
  the former returns 1 when the index was 0 and silently killed any caller running under `set -e`.
- **The subscription body lied about the format and dropped a working PQ route.** Two defects that only a
  real response could show. First, the branch that base64-encodes the v2ray body was guarded by the
  `universal_sub` flag, which is derived from the `User-Agent` — so an explicit `?target=v2ray` (or
  `?target=base64`) set the format but never that flag, fell into the HAPP branch and returned a plaintext
  HAPP body: byte-identical to the HAPP one (4885 B, 7 `vless://` + the hysteria2 line + the
  `happ://routing` line), PQ routes included. The branch now keys off the resolved `sub_format`.
  Second, the HAPP body discarded every xhttp route that was not `encryption=none` whenever the profile had
  a legacy xhttp route; that rule predated HAPP's ML-KEM support and silently removed `xhttp-pq`, so the
  body carried 7 links for a profile whose 8 routes all answered `channel-test` — the subscription simply
  did not offer that route. Both live fixes are verified end-to-end on the server: the HAPP body now has all
  8 links (2 with `encryption=mlkem…`), `?target=v2ray|base64` decodes to 6 `vless://` + 1 `hysteria2://`
  with no PQ, and Xray clients built from the URLs *taken out of the body* connect with HTTP 200
  (`xhttp-pq`, `xhttp-legacy`, `tcp-pq`). Because the handler is generated from a heredoc, existing servers
  get the fix through migration `subhttp_v2ray_pq_2026` (registered in `main_menu`, `quickstart` and
  `happ-setup`, verified live by running it exactly as the menu does). The interactive menu labels that still
  advertised «профиль 7 / HAPP 6 routes» were corrected as well: the HAPP list carries all seven, PQ included.
- **`profile-pq` threw away the base route of a profile it was asked to extend.** A profile created by
  `profile-create` lives in the single-route shape (transport/port/SNI only at top level, no `routes`
  array); `profile-pq` appended `routes` containing just the PQ entry, so the original route silently
  vanished from the subscription, from `channel-test` (it checked 1 route instead of 2) and from
  `profile-delete`. `_pq_add_route_for_profile` now expands the single-route shape into `routes` first
  (keeping port/transport/SNI/fingerprint and the `grpc`/`xhttp` metadata) and only then appends the
  `<transport>-pq` route. `profile-pq` also refuses a duplicate on a transport that is already
  post-quantum in the single-route shape, which is the normal case for `--transport xhttp`.
- **`profile-delete` left orphaned inbounds that kept serving the deleted profile.** The ports of a
  profile were computed as "`routes[].port` if `routes` is non-empty, otherwise `.port`", so a mixed
  profile — exactly what `profile-pq` used to produce — hid its base port from the cleanup: the inbound
  stayed in `config.json` **with the deleted profile's uuid still in `settings.clients`**, and the port
  kept listening (live: six leftovers after six create/`profile-pq`/delete cycles). `_profile_ports_json`
  now returns the union of the top-level `.port` and every `.routes[].port`, and all three call sites
  (interactive delete, `profile-delete`, `expire`) share it instead of re-implementing the choice.
- **`inspect --json` reported every backend as not installed.** The registry summary was built with
  `with_entries(... .value |= …)`, but to the right of `|=` the input is already the entry *value*, so
  `.value.installed` read a non-existent inner `value` field and `// false` turned it into `false`
  unconditionally. The live registry held `installed:true`, `version:"v2.13.0"`, `port:443` for
  hysteria2 and `kernel-dkms`/`51997` for awg, and `backend-status` reported both as `installed:true`
  in the same second, while the GUI import saw two absent backends. Now `map_values`, covered by a
  functional assertion in `validation/test-quickstart-email-and-inspect.sh` (which also pins the
  installed/version/port whitelist, so registry secrets cannot leak into the summary).

- **Default SNI could be unreachable from the VPS, killing most channels.** Reality serves the client a
  certificate fetched from the SNI's real site (`dest`), so an unreachable `dest` hangs the handshake
  even though the config is perfectly valid. On a live deployment the first line of `sni_list.txt`
  (`www.ozon.ru`) was unreachable, and **5 of 7 routes of a fresh deployment were dead**: `channel-test`
  showed 12-second timeouts for exactly those routes, while `grpc` and `tcp-xudp` (reachable SNIs)
  worked instantly; after switching the SNI to a reachable host all 7 worked. `_default_sni_for_transport`
  now verifies reachability from the server with the same criterion as `probe-test`/monitoring
  (openssl `Verify return code: 0` — a criterion later proven too weak, see the SNI-probe bullet above),
  walks the `sni_list.txt` candidates plus global fallbacks, caches
  one probe per SNI, and keeps the old behaviour when nothing is reachable (no internet/DNS must not
  break a deployment). Guarded by `validation/test-sni-reachability.sh`.
- **`quickstart --pq` never added a post-quantum route.** The flag was parsed and a static test
  asserted on it, but the block calling `_pq_add_route_for_profile` sat *inside* the failure branch of
  `_happ_ensure_default_multiroute_profile`: the route was appended to a profile that did not exist
  yet, after which the deployment returned `1` anyway. The block now runs after the managed HAPP
  profile is created, and the result is reported in the JSON as `pq_route` (a server without ML-KEM
  keys keeps deploying, just without PQ). Found and fixed on a live Ubuntu 22.04 deployment; two more
  defects of the same feature surfaced there and are fixed as well:
  - **The PQ route pointed at an inbound that was never created.** `build_transport_defaults` only
    picks a free port — it does not create anything, despite what its name (and the test seam)
    suggested, so `profile-pq` returned `ok:true` with an empty `link`, the port never listened and
    UFW never opened it. `_pq_add_route_for_profile` now creates the inbound through `add_inbound`
    (with a config backup), sets its `decryption`, opens the firewall port and calls
    `safe_restart_xray`, rolling the route and the port back if Xray refuses the config.
  - **`label: $label` is a jq 1.6 syntax error.** Ubuntu 22.04 and Debian 12 ship jq 1.6, where
    `label` is a keyword: the object pair `label: $label` fails to compile
    (`syntax error, unexpected label, expecting IDENT`) while jq 1.7 accepts it — so the whole PQ
    feature silently did nothing on two supported systems and CI (jq 1.7) stayed green. The variable
    is renamed to `$lbl`, the jq error is no longer swallowed by `2>/dev/null` (that is what turned
    the real cause into a cheerful "check config.json and free ports"), and
    `validation/test-jq-keyword-compat.sh` now guards the whole `keyword: $keyword` class.
  - **`quickstart --pq` duplicated PQ routes.** Re-running the deploy (or the GUI wizard) with the
    toggle on appended another `tcp-pq` route and port every time — the CLI refuses duplicates, the
    deploy path did not. It now reports an existing PQ route instead of adding a second one, and names
    the real reason when it cannot add one (the ML-KEM wording was printed even when keys were
    present).
- **A suffixed certificate lineage produced a dead subscription and a vague error.** If
  `/etc/letsencrypt/live/<ip>` is missing while the lineage is still registered, certbot issues into
  `/live/<ip>-0001` (observed up to `-0004` during live testing). The nginx vhost expects exactly
  `/live/<ip>`, so `nginx -t` failed and the deployment ended with
  `{"ok":false,"error":"nginx config failed"}` *after* a successful issuance, with a dead subscription
  and no hint. `quickstart` now checks the certificate directory right after issuance, prints the
  existing lineage names to stderr and tells the operator to remove the extra lineages
  (`certbot delete --cert-name <ip>-000N`) and re-run.
- **Clash subscriptions blamed sing-box for skipped routes.** `_vless_url_to_record` shares one
  `reason` string with the header of the Clash body, and the xhttp branch appended "xhttp не
  поддержан sing-box" to it — a reason that belongs to the other client. A user of mihomo/Clash read
  "VLESS Encryption (post-quantum)…; xhttp не поддержан sing-box" for the PQ route, although xhttp
  *is* supported by Clash (it only needs `?xhttp=1`). Clash adds its own note, sing-box simply does
  not render such routes, and the shared reason now stays client-agnostic.
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
- **`dns01-status` reported `deploy_hook:false` on a correctly configured domain.** Certbot writes the
  `--deploy-hook` into the renewal configuration as `renew_hook`, but the check grepped for the literal
  `deploy-hook`, so the field lied on every real installation (visible on a live renewal file:
  `renew_hook = systemctl reload nginx`). Both spellings are recognised now, and — since renewal of a
  domain certificate depends on that hook — `validation/test-dns01-certbot.sh` pins the behaviour.
- **Switching a subscription to DNS-01 silently moved it to another port.** `repair-dns01` reused the
  current subscription port, while `dns01-setup` (and the GUI "Set up DNS-01" button) defaulted to
  `443`: on a server whose subscription lived on `:8443` the published URL changed host *and* port
  without the operator asking. Both paths now share one rule — explicit `--port`, else the current
  subscription port, else `443` — so the URL keeps its port and only the host changes.
- **The distribution `certbot.timer` fought the shortlived IP certificate.** On servers where the
  IP certificate is renewed by snap certbot (apt certbot 1.x cannot do `--ip-address`), the apt timer
  still tried to renew that lineage twice a day and failed every time — log noise and a failed unit.
  It is now disabled **only** when the renewal is snap-driven, recorded in
  `/usr/local/etc/xray/.apt_certbot_timer_disabled`, re-enabled by `_dns01_install` (a domain
  certificate is renewed by that same timer) and by `uninstall.sh`. A timer the operator disabled
  himself is never touched or claimed.
- **`certbot` was resolved by `command -v`, whatever it found.** Two builds coexist on a real server —
  apt certbot 1.x with the `python3-certbot-dns-*` plugins, and snap certbot 5.x which has
  `--ip-address` but no DNS plugins — so a `PATH` with `/snap/bin` first would fail the DNS-01 issuance
  with `unrecognized arguments: --dns-cloudflare`. The DNS-01 path now picks the binary that actually
  reports the provider plugin (`certbot plugins`), and falls back with a warning.
- **The reported certbot failure reason could be pure boilerplate.** `_certbot_failure_reason` looked
  for a rate limit or a bracketed ACME `urn:` error and otherwise returned the last non-empty log line —
  which, for an ACME refusal that carries no `urn` link (a domain the CA will not issue for, or a DNS
  plugin error), is certbot's "Ask for help or search for solutions … See the logfile" footer. Verified
  live: `dns01-test` reported that footer instead of the actual
  `Error creating new order :: Cannot issue for "<domain>": … forbidden by policy`. The parser now also
  reads the line after `An unexpected error occurred:` and filters the boilerplate out of the fallback.
- **The profile row squeezed its own text into a one-letter-wide column.** In the profile list
  `.profileActions` had `flex-shrink: 0` without wrapping while `.profileMain` was `flex: 1` with
  `min-width: 0`, so the eleven action buttons demanded their full width and crushed the profile block:
  the subscription URL broke per character and the badges stacked vertically. The card now wraps the
  action row as a whole (`flex-wrap`), the buttons themselves wrap, and the profile block keeps a 320px
  base width. A long-standing layout weakness, not a regression of the section split — the row's CSS is
  untouched by the audit commits.
- **The update-branch menu lost its former look after moving to HeroUI `Dropdown`.** HeroUI centres the
  text of a button-based menu item, gives every item its own background, padding and press-scale, so the
  menu no longer matched the popover it replaced. The items are styled back: left-aligned text,
  transparent background, highlight only under the cursor or keyboard focus, 8px radius, 12px grey hints
  and the previous popover radii/padding.
- **"This server runs an older manager version" gave no way to diagnose itself.** The notice now prints
  the server's actual error next to the hint, and the hint names the cause and the fix (update the
  manager to the `dev` branch with the button above). Found on a live server: it had been switched to
  `main`, where the `backend-status` command does not exist at all, so the GUI was honestly hiding
  backend management — the install/enable UI is intact and returns as soon as the manager is on `dev`.
- **An AmneziaWG tunnel stayed down after a reboot, while the card said "Active".** `modprobe amneziawg`
  ran only inside the installation and nothing loaded the module at boot, so after a reboot
  `awg-quick@awg0.service` failed with `Error: Unknown device type`, `awg0` did not exist and the tunnel
  was dead — verified live 1h28m after the machine came back, on a server whose registry still said
  `installed` (the monitoring check that would have alerted needs a Telegram token, which that server
  did not have). `_awg_verify_module` now writes `/etc/modules-load.d/xrayebator-awg.conf` (0644 root,
  written only when the module is actually live — a file promising a module the system does not have
  would be worse than none), `_awg_ensure_runtime` loads the module, starts the unit and verifies the
  interface with `awg show`, and the idempotent `awg_module_2026` migration repairs existing
  installations. `awg-uninstall` drops the file again (module and packages stay, as documented).
  A second defect surfaced while repairing that server: **the install path treated a stale `awg`
  binary as success.** The machine had been rebooted into kernel `5.15.0-198` while the module — built
  manually on Oct 17 — existed only for `5.15.0-177`, so `awg-install` failed at "the module did not
  load" and pointed at "a kernel newer than supported", although `modprobe` was never the problem. The
  PPA branch returned success purely because `awg` was in `PATH` (left over from the manual build), so
  the source-build fallback never ran and nothing rebuilt the module for the new kernel. Success now
  means "a module built for the *running* kernel" (`_awg_module_for_kernel`), falling back to
  `dkms autoinstall` and then to the source build; and when `modprobe` still cannot load it,
  `_awg_verify_module` names the kernels the module exists for (`_awg_module_kernels`) instead of
  leaving the operator to guess. Guarded by `validation/test-awg-lifecycle.sh` (the module root is a
  test seam — CI has no such module).
- **A backend card's label and its colour came from two different fields.** The text was built from
  `installed`, the green tint from `state === 'active'`, so an installed but dead backend read
  "Active · UDP 25187 · 3.1 enabled" in grey — the screenshot behind "make AWG green" turned out to be a
  real outage hiding behind that mismatch. Both now derive from one predicate: green *Active*, red
  **Not running** with the unit name and the reason (the kernel module did not load after a reboot),
  or *Not installed*; the per-profile backend cards and their QR buttons follow the same state, and
  **Start** is offered right where the problem is shown.
- **The client-format links on the Keys page appeared late and vanished without SSH.** Clash/sing-box
  URLs arrive only together with the profile list, so — unlike the vless/hysteria2/AWG keys, which live
  in the server card — the category rendered after a round trip and disappeared when the server was
  unreachable. The main process now stores them on every successful `profiles:list` (as a full set, so a
  deleted profile leaves the cache), and the card is drawn from the cache like every other key. Its two
  opaque "Clash URL"/"sing-box URL" buttons became the layout used by the rest of the page: a row per
  profile with the mono URL, **Copy** and **QR** for each format.
- **The profile settings window read like one plain HTML page.** A caps heading, a paragraph and a row
  of buttons — four times over, with no border anywhere inside the dialog, and a header that glued the
  service line to the profile name ("Profile settings — happ"). Each group is now a well in the style of
  the rest of the app (`bg-1` + border + radius, like the backend block), with an icon, a 13px semibold
  title, its hint and its buttons (the buttons themselves are unchanged, only their arrangement); the
  deletion group is tinted as the only irreversible action, and the header carries a badge, the service
  line, the profile name and a transport/SNI chip — for a backend window, the protocol logo and name.
- **A new UI string could stay a raw key until the application was restarted** — the settings window
  title rendered `settings.profileSettingsTitle — happ` although ru/en/zh all carried the value. Cause:
  i18next copies strings into its store on the first `init`, while Vite accepts JSON modules itself, so
  the importing module never re-ran on an edit. The bundles are re-applied with overwrite after `init`
  and refreshed on HMR.

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
- Both TLS branches (`ip_tls` and `http_tls`) confirmed live, including on a
  hoster that filters inbound :80; the CLI self-update main→dev lands on the dev HEAD with
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