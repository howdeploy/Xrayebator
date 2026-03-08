---
phase: 01-safety-net-security
verified: 2026-03-08T08:00:00Z
status: passed
score: 11/11 must-haves verified
re_verification: false
---

# Phase 1: Safety Net + Security Verification Report

**Phase Goal:** Every config change is validated before restart with automatic rollback, security vulnerabilities are closed, and all jq operations use safe_jq_write
**Verified:** 2026-03-08T08:00:00Z
**Status:** passed
**Re-verification:** No -- initial verification

## Goal Achievement

### Observable Truths

| # | Truth | Status | Evidence |
|---|-------|--------|----------|
| 1 | Breaking config.json and triggering restart does NOT kill Xray -- old config stays running, user sees error message | VERIFIED | `safe_restart_xray()` at line 154 calls `xray run -test -config` before `systemctl restart xray`. On validation failure, restores from latest backup via `cp "$latest_backup" "$CONFIG_FILE"` and returns 1 without restarting. |
| 2 | Before any migration function mutates config.json, a timestamped backup file exists in /usr/local/etc/xray/backups/ | VERIFIED | `backup_config()` at line 137 creates timestamped backup in `/usr/local/etc/xray/backups/`. Called at: migrate_xhttp_profiles (line 298), migrate_routing_config (line 337), migrate_xhttp_mode (line 369), migrate_xhttp_extra_restore (line 407), install_adguard_home (line 2241), uninstall_adguard_home (line 2339). |
| 3 | All 10 bare systemctl restart xray calls are replaced with safe_restart_xray | VERIFIED | `grep 'systemctl restart xray' xrayebator` returns only line 173, which is INSIDE safe_restart_xray itself. 10 call sites of safe_restart_xray found at lines 327, 520, 711, 1050, 1308, 1471, 1633, 1871, 2257, 2384. |
| 4 | Migration marker-file system is consistent -- each migration creates its marker only on success | VERIFIED | Lines 487-516: each migration is wrapped in `if [[ ! -f marker ]]; then if migrate_function; then touch marker; fi; fi` pattern. Marker is created only when the function returns 0 (success). |
| 5 | New inbounds have non-empty 8-char hex shortIds in config.json | VERIFIED | `openssl rand -hex 4` at line 743 in add_inbound(). All 4 inbound templates use `"shortIds": ["$short_id"]` (lines 860, 889, 919, 963). Zero instances of `"shortIds": [""]` remain. |
| 6 | AdGuard Home installation does NOT open port 53 in UFW | VERIFIED | Zero results for `open_firewall_port 53` in xrayebator. Comment at line 2259 explicitly states why. |
| 7 | AdGuard Home uninstall closes port 53/tcp and 53/udp in UFW | VERIFIED | Lines 2375-2376: `ufw delete allow 53/tcp` and `ufw delete allow 53/udp`. |
| 8 | install.sh extracts public key from both old and new xray x25519 output formats | VERIFIED | Lines 145-146: `grep -E "^Private"` matches both `Private key:` and `PrivateKey:`. `grep -E "^Public\|^Password"` matches both `Public key:` and `Password:`. `awk '{print $NF}'` extracts last field. |
| 9 | Xray process runs as non-root user xray with CAP_NET_BIND_SERVICE | VERIFIED | install.sh: `useradd -r -s /usr/sbin/nologin -M xray` (line 76), systemd drop-in at lines 82-89 with `User=xray`, `AmbientCapabilities=CAP_NET_BIND_SERVICE`, `NoNewPrivileges=true`. File ownership: `chown -R xray:xray /usr/local/etc/xray/` at lines 138, 164. `fix_xray_permissions()` in xrayebator at line 147 maintains ownership at runtime. |
| 10 | update.sh preserves AdGuard Home DNS (127.0.0.1) and does not overwrite it | VERIFIED | Lines 328-331: checks `CURRENT_DNS == "127.0.0.1"` first and skips DNS migration with success message. |
| 11 | Connection links include shortId from config.json (sid=<hex> instead of sid=) | VERIFIED | Line 1120: reads `shortIds[0]` from config.json. Lines 1132-1144: all 4 VLESS link templates use `sid=${short_id}`. |

**Score:** 11/11 truths verified

### Required Artifacts

| Artifact | Expected | Status | Details |
|----------|----------|--------|---------|
| `xrayebator` | safe_restart_xray, backup_config, safe_jq_write everywhere, shortId generation, port 53 fix, fix_xray_permissions, updated SNIs | VERIFIED | All functions exist and are substantive (not stubs). 31 occurrences of safe_jq_write. Zero raw jq temp patterns. Zero `chown root:root` for xray config (only 1 for AdGuard yaml). |
| `install.sh` | Key extraction fix, xray user creation, systemd drop-in | VERIFIED | Dual-format grep at lines 145-146, useradd at 76, drop-in at 82-89, ownership at 138/164/227. bash -n passes. |
| `update.sh` | DNS preservation check for 127.0.0.1 | VERIFIED | 3-way conditional at lines 328-358: 127.0.0.1 skip / no adguard-dns.com migrate / already has it skip. bash -n passes. |
| `sni_list.txt` | Cleaned SNI list without TSPU-detectable domains | VERIFIED | Zero matches for google.com, microsoft.com, apple.com, bbc.com, yahoo.com. 77 lines with categorized domains (ru_whitelist, yandex_cdn, foreign, fallback). |

### Key Link Verification

| From | To | Via | Status | Details |
|------|----|-----|--------|---------|
| safe_restart_xray() | xray run -test -config | validation before systemctl restart | WIRED | Line 156: `/usr/local/bin/xray run -test -config "$CONFIG_FILE"`. Return code checked, rollback on failure, restart only on success. |
| backup_config() | /usr/local/etc/xray/backups/ | cp with timestamp | WIRED | Line 141: `cp "$CONFIG_FILE" "$backup_file"` where backup_file includes timestamp and migration name. |
| migrate_routing_config, migrate_xhttp_mode, migrate_xhttp_extra_restore, migrate_xhttp_profiles | backup_config() | call at function start | WIRED | Lines 298, 337, 369, 407: all 4 migration functions call backup_config before any jq mutation. |
| add_inbound() | openssl rand -hex 4 | shortId generation | WIRED | Line 743: `local short_id=$(openssl rand -hex 4)`. Used in all 4 inbound templates. |
| generate_connection() | config.json shortIds | jq read of shortIds[0] | WIRED | Line 1120: reads shortIds[0] from config.json for the port's inbound. Used in all 4 VLESS link templates at lines 1132-1144. |
| install.sh | systemd drop-in | xray.service.d/security.conf | WIRED | Lines 81-89: creates drop-in with User=xray + capabilities. systemctl daemon-reload at line 91. |
| update.sh DNS migration | 127.0.0.1 check | skip when AdGuard Home active | WIRED | Lines 329-331: reads dns.servers[0], compares to 127.0.0.1, skips migration if match. |
| migrate_routing_config() | safe_jq_write | replaced raw jq temp pattern | WIRED | Line 347: `safe_jq_write '.routing.rules += ...'` |
| migrate_xhttp_mode() | safe_jq_write | replaced raw jq temp pattern | WIRED | Line 386: `safe_jq_write --argjson port "$port" '...'` |
| update_transport_settings_for_sni() | safe_jq_write | replaced raw jq for base SNI update | WIRED | Line 81: `safe_jq_write --argjson port "$port_num" --arg sni "$new_sni" '...'` |

### Requirements Coverage

| Requirement | Source Plan | Description | Status | Evidence |
|-------------|------------|-------------|--------|----------|
| CFG-04 | 01-01 | xray run -test -config before restart with rollback | SATISFIED | safe_restart_xray() validates, rolls back from backup on failure |
| CFG-08 | 01-01 | Config changes as migrations with marker-files | SATISFIED | 4 migrations with marker-file pattern at lines 487-516 |
| CFG-09 | 01-01 | Backup config.json before each migration | SATISFIED | backup_config() called in all 4 migrations + 2 AdGuard functions |
| SEC-01 | 01-02 | Non-empty shortIds (hex, 8 chars) | SATISFIED | openssl rand -hex 4 generates 8-char hex; used in all 4 templates |
| SEC-02 | 01-02 | Port 53 not opened publicly during AdGuard install | SATISFIED | Zero open_firewall_port 53 calls |
| SEC-03 | 01-02 | Port 53 closed in UFW on AdGuard uninstall | SATISFIED | ufw delete allow 53/tcp and 53/udp at lines 2375-2376 |
| SEC-04 | 01-02 | install.sh grep for public key fixed | SATISFIED | grep -E "^Public\|^Password" handles both formats |
| SEC-05 | 01-02 | Xray as non-root with CAP_NET_BIND_SERVICE | SATISFIED | systemd drop-in, xray user, file ownership, fix_xray_permissions() |
| SEC-06 | 01-02 | update.sh preserves AdGuard Home DNS | SATISFIED | 127.0.0.1 check before DNS migration in update.sh |
| CQ-01 | 01-03 | All jq operations in migrations use safe_jq_write | SATISFIED | Zero `local temp_config=$(mktemp)` patterns remain. 31 safe_jq_write occurrences. |
| CQ-02 | 01-03 | update_transport_settings_for_sni uses safe_jq_write | SATISFIED | Line 81: safe_jq_write for base SNI update |
| CQ-03 | 01-03 | SNI list cleaned of detectable domains | SATISFIED | Zero matches for google/microsoft/apple/bbc/yahoo in sni_list.txt. Hardcoded refs in xrayebator updated (cloudflare.com, ozon.ru). |
| CQ-04 | 01-03 | create_profile indentation fixed | SATISFIED | Lines 666, 681-682: consistent 2-space indent, no blank line between comment and code |

### Anti-Patterns Found

| File | Line | Pattern | Severity | Impact |
|------|------|---------|----------|--------|
| (none) | - | - | - | No TODO/FIXME/HACK/PLACEHOLDER found in any modified file |

No anti-patterns detected. All three files pass `bash -n` syntax check. No empty implementations, no console.log-only handlers, no stub functions.

### Human Verification Required

### 1. Safe Restart Rollback on Live Server

**Test:** Intentionally corrupt config.json (e.g., add invalid JSON), then trigger a profile creation or other operation that calls safe_restart_xray.
**Expected:** Xray continues running on old config. Error message displayed. Config restored from backup.
**Why human:** Requires running Xray service and observing real systemd behavior.

### 2. Non-Root Xray Process

**Test:** After fresh install.sh, run `ps aux | grep xray` and verify process owner.
**Expected:** Process runs as user `xray`, not `root`.
**Why human:** Requires actual server with Xray installed and running.

### 3. ShortId in Client Connection Links

**Test:** Create a new profile, scan the QR code or copy the VLESS link, import into v2rayNG/Shadowrocket.
**Expected:** `sid=` parameter contains 8-char hex value. Client connects successfully.
**Why human:** Requires actual VPN client and network connectivity test.

### 4. AdGuard Home Port 53 Isolation

**Test:** Install AdGuard Home via menu, then run `ufw status`.
**Expected:** Port 53 does NOT appear in UFW rules. DNS resolution via Xray still works.
**Why human:** Requires server with UFW and AdGuard Home installed.

### Gaps Summary

No gaps found. All 11 observable truths are verified. All 13 requirement IDs (CFG-04, CFG-08, CFG-09, SEC-01 through SEC-06, CQ-01 through CQ-04) are satisfied with evidence in the codebase. All artifacts exist, are substantive, and are wired. No anti-patterns detected. All three scripts pass syntax validation.

---

_Verified: 2026-03-08T08:00:00Z_
_Verifier: Claude (gsd-verifier)_
