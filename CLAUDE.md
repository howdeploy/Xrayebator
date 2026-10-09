# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

Xrayebator — automated Xray Reality VPN manager for bypassing DPI censorship in Russia. The single Bash application (`xrayebator`, ~12700 lines) turns a VPS into a managed VPN server with an interactive terminal UI. The installer requires Bash, root/sudo, an apt-based Debian/Ubuntu-like system and systemd; the tested matrix is Debian 12/13 and Ubuntu 22.04/24.04. The **active desktop GUI** lives in `src/` (Electron + React + TypeScript) and drives the same Bash CLI over SSH. A legacy PySide6 GUI sits in `gui-legacy/` and is archival, not the active desktop app.

## Validation

There IS automated test coverage (despite what older notes said):
- **`validation/`** — 34 Bash test scripts, including `test-main-readiness-regressions.sh`, covering migrations, VLESS URL generation, transaction safety, dedup, firewall, menu numbering, the backend registry, the Hysteria 2 backend renderers/lifecycle, the AmneziaWG backend junk/renderers, the bypass/sni-change/port-change/profile-revoke/profile-expire CLIs, the HAPP client-routing generator, update branch pinning, quickstart, email/inspect regressions, apt-lock race regressions, the quickstart http_tls fallback and audit regressions. They run on the host (`bash validation/test-*.sh`); CI installs `jq`, `uuidgen` and `ripgrep` on Ubuntu. A bare Windows Git Bash checkout is not equivalent to the Linux environment.
- **`gui-legacy/tests/`** — 16 pytest modules covering SSH, deploy, connection, subscription and TUN runtime (legacy PySide6 GUI). Run with the GUI venv: `gui-legacy/.venv/Scripts/python -m pytest gui-legacy/tests`.
- **GUI (Electron)** — Vitest unit tests in `tests/`: `npm test`, plus `npm run typecheck`.
- **CI** — `.github/workflows/ci-linux.yml` runs the full `validation/` suite; `.github/workflows/gui-release.yml` runs `ruff` + `pytest gui-legacy/tests` and builds Windows/macOS bundles; `.github/workflows/release.yml` ships the Electron app.

Syntax checks used before a commit:
```bash
bash -n xrayebator
bash -n install.sh
bash -n update.sh
bash -n uninstall.sh
```

## Architecture

### Single-file application

All logic lives in `xrayebator`. Supporting scripts (`install.sh`, `update.sh`, `uninstall.sh`) handle lifecycle but are not part of the runtime.

### Production paths

- `/usr/local/etc/xray/config.json` — Xray configuration (inbounds, routing, DNS)
- `/usr/local/etc/xray/profiles/*.json` — per-user profile metadata
- `/usr/local/etc/xray/.private_key`, `.public_key` — Reality keys (generated once at install, never regenerated)
- `/usr/local/etc/xray/backups/` — timestamped config backups (created by `backup_config()`)
- `/usr/local/bin/xrayebator` — symlink to the script
- `/etc/systemd/system/xray.service.d/security.conf` — drop-in: `User=xray`, `CAP_NET_BIND_SERVICE`

### Critical concept: Inbound vs Profile

An **inbound** is a port-level config block in `config.json` (tag: `inbound-443`). A **profile** is a user-facing JSON file with UUID/transport/SNI metadata. Multiple profiles can share one inbound (same port). SNI and port are **inbound-level** — changing either can affect ALL profiles on that port. Fingerprint is **client-side per profile/route** and changing it does not edit the inbound or other routes. The function `update_all_profiles_on_port()` keeps profile JSONs in sync after inbound-level changes.

### Transport compatibility and flow

All TCP sub-types (`tcp`, `tcp-utls`, `tcp-xudp`, `tcp-mux`) map to network `"tcp"` and can coexist on one inbound (same port). But they require different `flow` values per client:

| Transport | network | flow |
|-----------|---------|------|
| tcp, tcp-utls, tcp-xudp | tcp | `xtls-rprx-vision` |
| tcp-mux | tcp | `""` (empty) |
| grpc | grpc | `""` (empty) |
| xhttp | xhttp | `""` (empty) |

Flow is determined by transport type in `add_inbound()`, NOT copied from existing clients. Mixing Vision and non-Vision transports on one port is valid — each client gets its own flow.

### XHTTP special case

XHTTP transport stores SNI in TWO places: `realitySettings.serverNames` AND `xhttpSettings.host`. Both MUST match. The function `update_transport_settings_for_sni()` handles this.

### Firewall port management

- `open_firewall_port(port, proto)` — idempotent, validates port, checks UFW
- `close_firewall_port(port, proto)` — only closes if port unused by any Xray inbound AND not in default ports list (22, 80, 443, 8443, 2053, etc.)

### Safe restart and backup

- `safe_restart_xray("/exact/backup/path")` — validates config with `xray run -test -format json` before `systemctl restart`; on failure it attempts rollback from the exact operation backup. Always use it for runtime mutations owned by `xrayebator`, and pass the operation's exact backup path.
- `backup_config("migration_name")` — creates timestamped config backups in `/usr/local/etc/xray/backups/`. **Call before any config mutation** in migration functions.
- `fix_xray_permissions()` — restores the root-owned manager-state boundary after writes. The service account reads required files; it does not own manager scripts or migration markers. Generated metadata and lifecycle rollback paths may have narrower exceptions.
- `install.sh` and `update.sh` have separate validation/restart/rollback paths; do not assume every lifecycle restart calls `safe_restart_xray()`.

### Migration system

Marker files in `/usr/local/etc/xray/` (e.g. `.xhttp_migrated`, `.config_optimized`). Migrations run once on first `main_menu()` launch after upgrade — and `quickstart` runs the same critical set (`test-quickstart-migration-parity.sh` keeps them in sync). Pattern for new migrations:
```bash
if [[ ! -f "/usr/local/etc/xray/.my_migration_marker" ]]; then
  backup_path=""
  backup_config "my_migration" backup_path
  # ... safe_jq_write calls ...
  fix_xray_permissions
  touch "/usr/local/etc/xray/.my_migration_marker"
  safe_restart_xray "$backup_path"
fi
```

### Security model

Xray runs as non-root user `xray` with `CAP_NET_BIND_SERVICE` via systemd drop-in file. The `install.sh` creates the user and sets file ownership. The `safe_jq_write()` function preserves `644` permissions; `fix_xray_permissions()` restores ownership after writes.

### Add-on services (legacy deprecated behavior)

- **AdGuard Home** — Removed from the interactive menu before the 3.0 line. If `/opt/AdGuardHome/AdGuardHome` is detected during `xrayebator update`, update.sh force-uninstalls it through `_adguard_force_uninstall_if_present` after rolling Xray DNS back to DoH Local (`https+local://1.1.1.1/dns-query`). `uninstall_adguard_home()` remains in `xrayebator` for manual emergency use.

## Coding Patterns

**Language**: Bash. Core runtime dependencies include `jq`, `curl`, `ufw`, `systemctl`, `openssl`, `uuidgen`, `qrencode`, `ip`, `ss`, `getent`, `flock`, `timeout`, `base64`, `awk`, `sed`, `stat`, `find`, `cmp`, `readlink`, `sha256sum`, `unzip`, `install`, `sysctl` and `hostname`; nginx, certbot, socat and snap are required by particular subscription/self-steal modes. Validation CI additionally installs `ripgrep`.

**Variables**: Always quote (`"$var"`), always `local` in functions.

**Safe JSON writes** — use `safe_jq_write()` for ALL jq modifications to config.json and profile files. It validates output is non-empty before `mv`, preventing data loss on jq errors:
```bash
safe_jq_write --arg uuid "$uuid" --argjson port "$port" \
  '(.inbounds[] | select(.port == $port) | .settings.clients) += [{"id": $uuid}]' \
  "$CONFIG_FILE"
```
Do NOT use raw `jq ... > temp && mv temp file` — always go through `safe_jq_write`. Note: `safe_jq_write` is only available inside `xrayebator`; `install.sh` and `update.sh` use inline jq followed by a `[[ -s ... ]]` non-empty check before `mv`.

**jq argument passing**: Use `--argjson` for numeric ports, `--arg` for strings. Never interpolate variables into jq expressions.

**Error handling in create_profile**: `add_inbound()` can fail (transport conflict, SNI conflict rejection). `create_profile()` checks the return code and deletes the profile file on failure. Always check `add_inbound` return.

**Client counting**: When checking if an inbound has remaining clients (e.g. before deleting the entire inbound), count via `config.json` clients array, NOT by counting profile files on disk. Profile files can be out of sync.

**Menu pattern**: `while true; do show_ascii; ... read choice; case $choice in ... 0) return ;; esac; done`

**Colors**: `RED` (errors), `GREEN` (success), `YELLOW` (warnings/prompts), `BLUE` (menu borders), `CYAN` (info/options), `MAGENTA` (section headers), `NC` (reset).

**Port validation**: `[[ ! "$port" =~ ^[0-9]+$ ]] || [[ $port -lt 1 ]] || [[ $port -gt 65535 ]]`

**Restart discipline**: Never use bare `systemctl restart xray`. Always use `safe_restart_xray()` which validates config first and auto-rolls back on failure.

**Freedom outbound**: When modifying freedom outbound settings, use jq path assignment (not object merge) to avoid clobbering existing `fragment` anti-DPI settings.

## Branches

- `main` — stable, releases every 1-2 months
- `dev` — quick fixes, weekly or biweekly
- `experimental` — latest features, several times per week
- This checkout is currently on `dev`; do not assume `experimental` is the working branch.

## CLI commands

Apart from the interactive menu (`sudo xrayebator`), the script exposes subcommands used by the GUI and by automation. They are dispatched at the very bottom of `xrayebator` (the `case "${1:-}" in ... esac` block guarded by `XRAYEBATOR_SOURCED`):

- `xrayebator update` — update only the Xray-core binary; `xrayebator update <branch>` self-updates the manager from the canonical raw branch, pins that branch in `/usr/local/etc/xray/.current_branch` (the GUI updater reads this file), then updates Xray-core.
- `xrayebator-update [branch]` — separate full `update.sh` lifecycle workflow; without a branch it displays `.current_branch` and opens interactive branch selection.
- `xrayebator quickstart --email <email>` — UI CLI used by the desktop app: runs the broad setup/migration path, provisions the subscription endpoint, creates a standard **schema-v3 multi-route** HAPP profile (7 routes including `xhttp-legacy`), and prints JSON with `subscription_url`. The implementation currently tolerates migration failures in this non-interactive path; verify the resulting profile and services after deployment. Email mode is explicit: `quickstart --without-email` runs the same path but registers Certbot/ACME with `--register-unsafely-without-email` (no renewal notices, no email-based account recovery; never substitute a fake address). The GUI passes exactly one of the two forms. If Let's Encrypt cannot validate the IP over http-01 (hoster filters port 80 — "Connection reset by peer" from validation hosts), quickstart degrades to `http_tls`: markers switch to that mode, the subscription is published over HTTP from the loopback handler, a self-signed cert is generated for future backends, and the result JSON carries `degraded:true`, `tls_mode:"http_tls"` and `certbot_reason`; the renew timer is NOT installed in this mode, and rerunning quickstart after port 80 is unblocked issues the LE certificate and restores ip_tls (guarded by `validation/test-quickstart-tls-fallback.sh`).
- `xrayebator inspect --json` — read-only install probe for the GUI "connect existing server" import: reports manager/Xray/profiles/subscription markers as one JSON object on stdout (diagnostics to stderr only). It must not migrate, install, restart, open firewall or write anything; `validation/test-quickstart-email-and-inspect.sh` guards these invariants statically. Since the multi-protocol stage it also carries a secrets-free `backends` summary (`{<type>: {installed, version, port}}`) read from the backend registry only when the file already exists — inspect never creates it.
- `xrayebator happ-setup` — reduced existing-install HAPP path; ensures the subscription service and a usable multi-route profile, verifies a real public TLS endpoint when subscription markers are missing, and prints JSON with `subscription_url`. It does not have the same migration breadth as quickstart.
- `xrayebator probe-test` — probe-test candidate SNIs from `sni_list.txt` and print reachability scores.
- `xrayebator profiles` — print all profiles as a flat JSON array (used by the GUI "Server settings" page); each entry carries `expire` (epoch seconds, `0` = unlimited), server-local `expire_date` (`YYYY-MM-DD`) for display, `expire_disabled`, and since the multi-protocol stage the additive `backends` object (per-profile hysteria2/awg grants — operator-level credentials, same trust level as the already-exposed `sub_token`). `expire_supported` is present (`true`) only on servers with expiry enforcement; its absence means the server predates the feature and the GUI must not offer expiry.
- `xrayebator profile-create --name NAME [--transport T] [--port P] [--count N] [--expire DATE]` — create 1..N profiles non-interactively (names `name`, `name-2`, ...). `--expire` accepts `YYYY-MM-DD[ HH:MM]`, epoch seconds or 13-digit milliseconds; date-only expiry is inclusive through `23:59:59` in server-local time, while an explicit time uses server-local time as given. Dates/times with leading-zero fields such as `09` are parsed as decimal, not octal. A past expiry is rejected. Emits `{"ok":true,"names":[...],"errors":[...]}`; `ok` stays `true` even when some profiles already exist (they land in `errors`). The GUI additionally pre-checks a name collision before issuing the create call (deletion is per-profile: unique names keep it precise, and the deleted profile's backend keys are revoked immediately — see the lifecycle bullets above).
- `xrayebator profile-delete --name NAME` — delete a profile, emits `{"ok":true,"name":"..."}` (stdout carries only the JSON — the `backup_config` status line is silenced to stderr like the other helpers). Inbound/firewall cleanup happens automatically, and the deleted profile's backend grants are revoked in the same command: the AWG peer is regenerated out of `awg0.conf`, the Hysteria password out of `server.yaml` — no orphaned credentials; the name is immediately free for reuse.
- `xrayebator profile-revoke --name NAME [--full]` — reissue the subscription `sub_token`; `--full` also rotates the uuid in every inbound of the profile, so already-downloaded configs stop connecting. Transaction order matters: config + `safe_restart_xray` first, then the profile JSON, and a failed profile write rolls the config back from the transaction backup.
- `xrayebator profile-expire --name NAME --expire DATE|epoch|none` — set/extend/clear a profile expiry (`.expire` epoch seconds); date-only expiry is inclusive through `23:59:59` in server-local time; an explicit time is also interpreted in server-local time. Applied immediately (an expired profile loses its client, an extension restores it).
- `xrayebator expire-check` — batch enforcement of every due expiry; idempotent (no changes ⇒ no Xray restart), driven by `xrayebator-expire.timer` every 10 minutes. Disabling keeps the inbounds alive (a fresh inbound would change the shortId and kill issued URLs) and snapshots clients into `.expire_clients` for restoration.
- `xrayebator fp-change --name NAME [--route R] --fp FINGERPRINT` — change the fingerprint for a profile (client-side, no Xray restart), emits JSON.
- `xrayebator sni-change --name NAME [--route R] --sni SNI` — change the SNI for a profile; updates all profiles on the same port (`update_all_profiles_on_port()`), emits JSON.
- `xrayebator sni-list` — print the SNI candidates from `sni_list.txt` grouped by category, emits JSON (used by the GUI SNI dialog).
- `xrayebator port-change --name NAME [--route R] --port PORT|random` — change the port for a profile; updates the inbound, firewall, subscription and all profiles on the port, emits JSON (reconnect is required).
- `xrayebator bypass list|add --domain D|remove --domain D|reset|bundle [--group a,b,c]` — manage bypass routing groups (JSON). Server-side only: it exists for cascade deployments, where the catch-all points at the upstream; without a cascade the built-in catch-all already sends everything direct.
- `xrayebator backend-status` — print the multi-protocol backend registry status as JSON (`{"ok":true,"backends":{...}}`). Backend state lives in the neutral root `/usr/local/etc/xrayebator/` (`backends.json` registry 644 root — no secrets, readable by the `xray` service account; `backends/<type>/` runtime state with secrets in 750/640); `/usr/local/etc/xray/*` stays Xray-only. Slice 1 of the multi-protocol stage (2026-10) ships the registry with no backends; `hysteria2` and `awg` entries appear as those backends land. `_backend_apply_profile_lifecycle <name> <created|deleted|revoked|expired|restored>` is the single lifecycle choke point for backend grants; per-profile backend credentials live in the profile's additive `.backends` object, so the profile JSON remains the single source of truth for revoke/expire. Guarded by `validation/test-backend-registry.sh` (sources the script in source-mode with an overridden `BACKENDS_ROOT`).
- `xrayebator hysteria2-install [--port P] [--grant-all]` / `hysteria2-uninstall` / `hysteria2-status` / `hysteria2-grant --name N` / `hysteria2-subbody --on|--off` / `hysteria2-link --name N` — Hysteria 2 UDP backend (multi-protocol slices 2–3, menu item 11). Install downloads the binary from `HyNetworks/hysteria` releases (tag format `app/vX.Y.Z`, sha256 from the API `digest` field), creates the dedicated `hysteria` system user, writes its own `hysteria-server.service` (CAP_NET_BIND_SERVICE, `Restart=on-failure`), QUIC sysctl buffers, and `/usr/local/etc/xrayebator/backends/hysteria/server.yaml`. TLS is adaptive: a subscription Let's Encrypt cert is copied into the backend dir with a certbot renewal deploy-hook, otherwise a self-signed cert is generated (clients then use `insecure=1`). CLI commands print only JSON on stdout; exit code `2` from the workhorse means "already installed / not installed" and the wrapper reports `already: true`.
- Hysteria 2 grants (slice 3): per-profile credentials live in the profile's `.backends.hysteria2` object (`username` = profile name, `password` = 32 hex chars) — the profile JSON is the single source of truth; `server.yaml` is always **regenerated** from profiles by `_hysteria2_regen_config` (compact users map, filter `.expire_disabled == false`, so `expired`/`restored` events are just a regen) and applied via `_hysteria2_apply_config` (restart with rollback). `_backend_apply_profile_lifecycle` is wired after the Xray part of `create_profile` / `_profile_cli_create_one` (created — **no-op**: backend keys are NOT auto-issued on creation, the operator picks the protocol explicitly via the GUI create flow or explicit grant CLI — otherwise every new profile would receive keys from ALL installed backends), `profile_delete_command` (deleted), `profile_revoke_command` (revoked → password rotation), and `_expire_disable_profile`/`_expire_enable_profile` (expired/restored). Install asks to grant all existing profiles interactively; the CLI is non-interactive by default and opt-in via `--grant-all`. The pure builder `_hysteria2_profile_link_pure` produces `hysteria2://user:pass@host:port/?sni=…&insecure=0|1#name`; the subhttp handler appends it to BOTH the generic (v2rayNG) and the HAPP subscription bodies, gated by the registry `sub_body` flag (kill-switch without service restart). Migration `subhttp_hysteria2_2026` regenerates the handler on existing servers and is registered in BOTH `main_menu` and `quickstart` (parity test). The registry file is 644 root (no secrets) so the `xray` service account can read it from subhttp; secrets live in the 750 backend dirs. HAPP-body acceptance with a hysteria2 line is verified in the live spike, not CI.
- `xrayebator awg-install [--grant-all]` / `awg-uninstall` / `awg-status` / `awg-grant --name N` / `awg-conf --name N` / `awg-31 --on|--off` — AmneziaWG 2.0/3.1 system-VPN backend (multi-protocol slices 4–5 + 3.1 stage, menu items 12/13). Kernel module via DKMS per the AmneziaWG README: primary path is the `amnezia/ppa` PPA (`apt install amneziawg`), fallback is a manual source build (kernels ≥5.6 need the FULL `linux-source` tree linked as the module's `kernel` symlink — headers alone are not enough). The backend is registered in the registry only after `modprobe amneziawg` + `lsmod` confirm the module and `awg show awg0` confirms the interface. Server state: `backends/awg/server-params.json` (0600, keys/port/iface/junk) and `awg0.conf` (0600). AWG 3.1 is implemented and ON by default: the generator emits `S1`–`S4` (≥ 12), `HeaderProtectionKey` (random, shared with every client conf) and `RandomTrailers = on` — the `awg` parser (kernel UAPI) accepts booleans as `on`/`off`, NOT `true`/`false`; `DisableCookies` is available via `awg-31 --disable-cookies` (local flag, off by default). `awg-31` toggles the format with an explicit operator warning that every issued client `.conf` must be re-downloaded (clients need AmneziaVPN ≥ 5.0.1.5) and regenerates the interface with rollback; `_awg_ensure_31_params` upgrades legacy (pre-3.1) server params in place. Junk params mirror the Amnezia defaults — the dialect the official AmneziaVPN apps (phone and desktop) apply reliably; their go-tunnel applies custom junk incompletely: Jc=5, Jmin=10, Jmax=50, H1–H4=1..4 (WG magic), S1/S2 random 12..150, S3/S4 random 12..64, all unique with S1+56≠S2. The desktop GUI additionally delivers keys in the app-native `vpn://` shape (`amnezia-awg2` container, server-side junk fields, `protocol_version`; see shared/awg.ts `buildAwgVpnConfig`) — a raw `.conf` pasted into AmneziaVPN does not reach its tunnel intact. `ip_forward` is set via `/etc/sysctl.d/99-xrayebator-awg.conf`. Uninstall tears down the interface and files but leaves the packages/module in the system (documented in output).
- AWG peers (slice 5): per-profile peer credentials live in the profile's `.backends.awg` object (`client_private_key`, `client_public_key`, `preshared_key`, `address` `10.8.1.x`, `created`) — profile JSON is the single source of truth; `awg0.conf` `[Peer]` sections are **regenerated** from profiles (`_awg_regen_config`, filter `.expire_disabled == false`, so expired/restored events are just a regen) and applied via `_awg_apply_config` (interface restart with rollback; the restart briefly drops the tunnel for all peers — accepted for stage 1, grants/revokes are rare). Address allocation picks the first free `.2..254` honoring addresses already issued to profiles. The lifecycle choke point dispatches to `_awg_on_profile_event` automatically for installed backends — deleted/revoked/expired/restored need no extra wiring in profile flows (created is a no-op: no auto-grant, keys are issued only by explicit `awg-grant`; the `deleted` case regenerates unconditionally because the caller removes the profile file BEFORE the lifecycle call). Client config (`_awg_client_conf_pure`) carries the client keypair, the server pubkey/endpoint, junk params copied from the server, `AllowedIPs = 0.0.0.0/0, ::/0` (full tunnel) and `PersistentKeepalive = 25`; `awg-conf --name N` returns it as JSON `{ok, name, conf}` for the GUI, the menu prints it with an optional QR. Peer events: revoked = keypair+PSK rotation with the address kept (old client configs stop connecting). Package installation itself (network + DKMS build) and a real client connection are verified in the live spike, not CI.

CLI JSON hygiene: `profile-create`/`profile-delete` **must** print only JSON on stdout. The shared helpers (`backup_config`, `add_inbound`, `open_firewall_port`, `safe_restart_xray`, `close_firewall_port`) print colored status lines that would corrupt the parse, so the CLI paths redirect stdout→stderr around those calls (`exec 3>&1; exec 1>&2 ... exec 1>&3`). Keep it that way when editing.

### HAPP profile vs GUI quickstart — a subtle case

`quickstart` **must** emit a multi-route profile with `xhttp-legacy` (schema_version 3, routes[] with 7 entries) — HAPP expects the multi-route shape. Do NOT create a single-route one-off profile; `_happ_ensure_default_multiroute_profile()` is the single source of truth for the HAPP profile and is shared by both `quickstart` and `happ-setup`. When debugging "HAPP shows no data", check that the profile in `/usr/local/etc/xray/profiles/*.json` has a `routes` array with 7 entries and that `xhttp-legacy` is one of them (PQ route is excluded from the subscription).

## Language

Bash/server-facing strings, comments, and commit messages are in **Russian**. The active Electron renderer is intentionally multilingual (`ru`, `en`, `zh`); code identifiers and function names are in English.
