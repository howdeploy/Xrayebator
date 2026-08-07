# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

Xrayebator — automated Xray Reality VPN manager for bypassing DPI censorship in Russia. Single Bash script (`xrayebator`, ~9300 lines) that turns a VPS into a managed VPN server with interactive terminal UI. The bash core is compatible with Debian 10+/Ubuntu 20.04+ (the installer does not gate on OS version, and the script itself runs anywhere with systemd + the listed dependencies). The **desktop GUI** (`gui/`, PySide6) intentionally supports a narrower set — Debian 12/13 and Ubuntu 22.04/24.04 only.

## Validation

There IS automated test coverage (despite what older notes said):
- **`validation/`** — 16 bash test scripts that exercise migrations, vless URL generation, transaction safety, dedup, firewall and menu numbering. They run on the host (`bash validation/test-*.sh`); several require `jq`, `uuidgen`, `rg` and a Linux-flavoured environment, so they do NOT pass on a bare Windows Git Bash installation.
- **`gui/tests/`** — 15 pytest modules covering SSH, deploy, connection, subscription and TUN runtime. Run with the GUI venv: `gui/.venv/Scripts/python -m pytest gui/tests`.
- **CI** — `.github/workflows/gui-release.yml` runs `ruff` + `pytest gui/tests` on every push affecting `gui/` and builds Windows/macOS bundles.

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

An **inbound** is a port-level config block in `config.json` (tag: `inbound-443`). A **profile** is a user-facing JSON file with UUID/transport/SNI metadata. Multiple profiles can share one inbound (same port). SNI and fingerprint are **inbound-level** — changing them affects ALL profiles on that port. The function `update_all_profiles_on_port()` keeps profile JSONs in sync.

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

- `safe_restart_xray()` — validates config with `xray run -test -config` before `systemctl restart`. On failure: auto-rollback from latest backup, Xray keeps running on old config. **Always use this instead of bare `systemctl restart xray`**.
- `backup_config("migration_name")` — creates timestamped backup in `/usr/local/etc/xray/backups/`. **Call before any config mutation** in migration functions.
- `fix_xray_permissions()` — restores `xray:xray` ownership on `/usr/local/etc/xray/`. Call after writes that create/modify files.

### Migration system

Marker files in `/usr/local/etc/xray/` (e.g. `.xhttp_migrated`, `.config_optimized`). Migrations run once on first `main_menu()` launch after upgrade. Pattern for new migrations:
```bash
if [[ ! -f "/usr/local/etc/xray/.my_migration_marker" ]]; then
  backup_config "my_migration"
  # ... safe_jq_write calls ...
  fix_xray_permissions
  touch "/usr/local/etc/xray/.my_migration_marker"
  safe_restart_xray
fi
```

### Security model

Xray runs as non-root user `xray` with `CAP_NET_BIND_SERVICE` via systemd drop-in file. The `install.sh` creates the user and sets file ownership. The `safe_jq_write()` function preserves `644` permissions; `fix_xray_permissions()` restores ownership after writes.

### Add-on services (legacy deprecated behavior)

- **AdGuard Home** — Removed from the interactive menu before the 3.0 line. If `/opt/AdGuardHome/AdGuardHome` is detected during `xrayebator update`, update.sh force-uninstalls it through `_adguard_force_uninstall_if_present` after rolling Xray DNS back to DoH Local (`https+local://1.1.1.1/dns-query`). `uninstall_adguard_home()` remains in `xrayebator` for manual emergency use.

## Coding Patterns

**Language**: Bash. Dependencies: `jq`, `curl`, `ufw`, `systemctl`, `openssl`, `uuidgen`, `qrencode`.

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
- `dev` — quick fixes, weekly
- `experimental` — latest features, daily (current working branch)

## CLI commands

Apart from the interactive menu (`sudo xrayebator`), the script exposes subcommands used by the GUI and by automation. They are dispatched at the very bottom of `xrayebator` (the `case "${1:-}" in ... esac` block guarded by `XRAYEBATOR_SOURCED`):

- `xrayebator update [branch]` — re-run the update workflow (main/dev/experimental).
- `xrayebator quickstart --email <email>` — UI CLI used by the desktop app: installs the subscription server, obtains an IP-TLS cert via certbot, creates the **multi-route** HAPP profile (7 routes, includes `xhttp-legacy`), prints JSON `{"ok":true,...,config_url":"https://IP:8443/sub/<token>"}`.
- `xrayebator happ-setup` — ensured the HAPP multi-route profile exists, restarts the subscription service, prints the same JSON payload.
- `xrayebator probe-test` — probe-test candidate SNIs from `sni_list.txt` and print reachability scores.

### HAPP profile vs GUI quickstart — a subtle case

`quickstart` **must** emit a multi-route profile with `xhttp-legacy` (schema_version 3, routes[] with 7 entries) — HAPP expects the multi-route shape. Do NOT create a single-route one-off profile; `_happ_ensure_default_multiroute_profile()` is the single source of truth for the HAPP profile and is shared by both `quickstart` and `happ-setup`. When debugging "HAPP shows no data", check that the profile in `/usr/local/etc/xray/profiles/*.json` has a `routes` array with 7 entries and that `xhttp-legacy` is one of them (PQ route is excluded from the subscription).

## Language

All user-facing strings, comments, and commit messages are in **Russian**. Code identifiers and function names are in English.
