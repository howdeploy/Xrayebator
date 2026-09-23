# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

Xrayebator — automated Xray Reality VPN manager for bypassing DPI censorship in Russia. The single Bash application (`xrayebator`, ~11841 lines) turns a VPS into a managed VPN server with an interactive terminal UI. The installer requires Bash, root/sudo, an apt-based Debian/Ubuntu-like system and systemd; the tested matrix is Debian 12/13 and Ubuntu 22.04/24.04. The **active desktop GUI** lives in `src/` (Electron + React + TypeScript) and drives the same Bash CLI over SSH. A legacy PySide6 GUI sits in `gui-legacy/` and is archival, not the active desktop app.

## Validation

There IS automated test coverage (despite what older notes said):
- **`validation/`** — 25 Bash test scripts, including `test-main-readiness-regressions.sh`, covering migrations, VLESS URL generation, transaction safety, dedup, firewall, menu numbering, the bypass/sni-change/port-change CLIs, quickstart, email/inspect regressions and audit regressions. They run on the host (`bash validation/test-*.sh`); CI installs `jq`, `uuidgen` and `ripgrep` on Ubuntu. A bare Windows Git Bash checkout is not equivalent to the Linux environment.
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

- `xrayebator update` — update only the Xray-core binary; `xrayebator update <branch>` self-updates the manager from the canonical raw branch and then updates Xray-core.
- `xrayebator-update [branch]` — separate full `update.sh` lifecycle workflow; without a branch it displays `.current_branch` and opens interactive branch selection.
- `xrayebator quickstart --email <email>` — UI CLI used by the desktop app: runs the broad setup/migration path, provisions the subscription endpoint, creates a standard **schema-v3 multi-route** HAPP profile (7 routes including `xhttp-legacy`), and prints JSON with `subscription_url`. The implementation currently tolerates migration failures in this non-interactive path; verify the resulting profile and services after deployment. Email mode is explicit: `quickstart --without-email` runs the same path but registers Certbot/ACME with `--register-unsafely-without-email` (no renewal notices, no email-based account recovery; never substitute a fake address). The GUI passes exactly one of the two forms.
- `xrayebator inspect --json` — read-only install probe for the GUI "connect existing server" import: reports manager/Xray/profiles/subscription markers as one JSON object on stdout (diagnostics to stderr only). It must not migrate, install, restart, open firewall or write anything; `validation/test-quickstart-email-and-inspect.sh` guards these invariants statically.
- `xrayebator happ-setup` — reduced existing-install HAPP path; ensures the subscription service and a usable multi-route profile, verifies a real public TLS endpoint when subscription markers are missing, and prints JSON with `subscription_url`. It does not have the same migration breadth as quickstart.
- `xrayebator probe-test` — probe-test candidate SNIs from `sni_list.txt` and print reachability scores.
- `xrayebator profiles` — print all profiles as a flat JSON array (used by the GUI "Server settings" page).
- `xrayebator profile-create --name NAME [--transport T] [--port P] [--count N]` — create 1..N profiles non-interactively (names `name`, `name-2`, ...). Emits `{"ok":true,"names":[...],"errors":[...]}`; `ok` stays `true` even when some profiles already exist (they land in `errors`).
- `xrayebator profile-delete --name NAME` — delete a profile, emits `{"ok":true,"name":"..."}`. Inbound/firewall cleanup happens automatically.
- `xrayebator fp-change --name NAME [--route R] --fp FINGERPRINT` — change the fingerprint for a profile (client-side, no Xray restart), emits JSON.
- `xrayebator sni-change --name NAME [--route R] --sni SNI` — change the SNI for a profile; updates all profiles on the same port (`update_all_profiles_on_port()`), emits JSON.
- `xrayebator sni-list` — print the SNI candidates from `sni_list.txt` grouped by category, emits JSON (used by the GUI SNI dialog).
- `xrayebator port-change --name NAME [--route R] --port PORT|random` — change the port for a profile; updates the inbound, firewall, subscription and all profiles on the port, emits JSON (reconnect is required).
- `xrayebator bypass list|add --domain D|remove --domain D|reset|bundle [--group a,b,c]` — manage bypass routing groups (JSON).

CLI JSON hygiene: `profile-create`/`profile-delete` **must** print only JSON on stdout. The shared helpers (`backup_config`, `add_inbound`, `open_firewall_port`, `safe_restart_xray`, `close_firewall_port`) print colored status lines that would corrupt the parse, so the CLI paths redirect stdout→stderr around those calls (`exec 3>&1; exec 1>&2 ... exec 1>&3`). Keep it that way when editing.

### HAPP profile vs GUI quickstart — a subtle case

`quickstart` **must** emit a multi-route profile with `xhttp-legacy` (schema_version 3, routes[] with 7 entries) — HAPP expects the multi-route shape. Do NOT create a single-route one-off profile; `_happ_ensure_default_multiroute_profile()` is the single source of truth for the HAPP profile and is shared by both `quickstart` and `happ-setup`. When debugging "HAPP shows no data", check that the profile in `/usr/local/etc/xray/profiles/*.json` has a `routes` array with 7 entries and that `xhttp-legacy` is one of them (PQ route is excluded from the subscription).

## Language

Bash/server-facing strings, comments, and commit messages are in **Russian**. The active Electron renderer is intentionally multilingual (`ru`, `en`, `zh`); code identifiers and function names are in English.
