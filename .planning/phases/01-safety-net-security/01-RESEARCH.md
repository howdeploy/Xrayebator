# Phase 1: Safety Net + Security - Research

**Researched:** 2026-03-08
**Domain:** Bash script hardening, Xray Reality security, systemd capabilities, jq safe operations
**Confidence:** HIGH

## Summary

Phase 1 addresses 13 requirements across three areas: (1) config validation with rollback before every Xray restart, (2) six security fixes (port 53, non-root, shortIds, install.sh key grep, update.sh DNS preservation), and (3) code quality cleanup (safe_jq_write migration, SNI list, formatting).

The codebase is well-understood. Every function referenced in the requirements has been read and analyzed. The existing `safe_jq_write()` function (lines 117-143) is a solid foundation -- it validates jq output is non-empty before `mv`, sets permissions, and returns error codes. The pattern needs extension to migrations (which use raw `jq > temp && mv temp`) and to `update_transport_settings_for_sni` (lines 65-110, partial -- base SNI update is raw jq, only XHTTP host update uses safe_jq_write).

All 10 `systemctl restart xray` calls in the script have been located and verified. The `xray run -test -config` command is documented in official Xray docs and confirmed working. The systemd `AmbientCapabilities=CAP_NET_BIND_SERVICE` approach for non-root is well-established and verified across multiple sources.

**Primary recommendation:** Implement changes in dependency order -- safe_restart_xray first (used by everything), then security fixes (independent of each other), then code quality (also independent). Each change is isolated and testable.

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|-----------------|
| CFG-04 | `xray run -test -config` before every restart, rollback on error | safe_restart_xray() pattern documented, all 10 restart sites mapped |
| CFG-08 | All config changes as migrations with marker-file | Existing migration system at lines 462-501 already uses marker files; pattern is established |
| CFG-09 | Backup config.json before each migration | cp with timestamp to /usr/local/etc/xray/backups/ |
| SEC-01 | Generate non-empty shortIds (hex, 8 chars) | `openssl rand -hex 4` produces 8 hex chars; all 4 inbound templates identified at lines 836, 865, 895, 939 |
| SEC-02 | Port 53 NOT opened publicly when installing AdGuard Home | Remove open_firewall_port 53 calls at lines 2235-2236; AGH bind_hosts stays 0.0.0.0 for Xray, UFW blocks external |
| SEC-03 | Port 53 closed in UFW when uninstalling AdGuard Home | Add ufw delete allow 53/tcp and 53/udp at lines 2356-2361 |
| SEC-04 | install.sh: grep for public key fixed | Support both old ("Public key:") and new ("Password:") xray x25519 output formats |
| SEC-05 | Xray runs as non-root with CAP_NET_BIND_SERVICE | systemd AmbientCapabilities + User=xray; install.sh creates user + sets file permissions |
| SEC-06 | update.sh doesn't overwrite AdGuard Home DNS (127.0.0.1) | Check for 127.0.0.1 in dns.servers before DNS migration at line 329 |
| CQ-01 | All jq operations in migrations use safe_jq_write | 3 migration functions identified with raw jq: migrate_routing_config, migrate_xhttp_mode, migrate_xhttp_extra_restore |
| CQ-02 | update_transport_settings_for_sni converted to safe_jq_write | Lines 80-96: base SNI update uses raw jq; XHTTP host update (line 101) already uses safe_jq_write |
| CQ-03 | SNI list cleaned | Remove www.google.com, www.microsoft.com, www.apple.com, www.bbc.com, www.yahoo.com, www.mozilla.org; keep GitHub/Cloudflare for gRPC |
| CQ-04 | create_profile formatting fixed | Lines 643, 658-660: indentation broken (no leading spaces) |
</phase_requirements>

## Standard Stack

### Core
| Tool | Version | Purpose | Why Standard |
|------|---------|---------|--------------|
| bash | 5.x | Script runtime | Target platform default |
| jq | 1.6+ | JSON manipulation | Already used throughout, safe_jq_write depends on it |
| openssl | 1.1+ | Random hex generation for shortIds | Available on all target systems, `openssl rand -hex 4` |
| systemd | 240+ | Service management with capabilities | All target platforms (Debian 10+/Ubuntu 20.04+) |

### Supporting
| Tool | Version | Purpose | When to Use |
|------|---------|---------|-------------|
| ufw | any | Firewall management | Port 53 open/close operations |
| xray | 26.x | VPN core binary | Config validation via `xray run -test -config` |

## Architecture Patterns

### Pattern 1: safe_restart_xray() -- Validate Before Restart

**What:** A wrapper function that validates config with `xray run -test -config` before calling `systemctl restart xray`, with automatic rollback on failure.

**When to use:** Replace ALL 10 bare `systemctl restart xray` calls in the script.

**Implementation:**

```bash
# Безопасный перезапуск Xray с валидацией конфига
# Returns: 0=success, 1=validation failed (Xray NOT restarted, old config preserved)
safe_restart_xray() {
  # Валидация конфига перед перезапуском
  local test_output
  test_output=$(/usr/local/bin/xray run -test -config "$CONFIG_FILE" 2>&1)

  if [[ $? -ne 0 ]]; then
    echo -e "${RED}  ✗ Конфиг не прошёл валидацию — Xray НЕ перезапущен${NC}"
    echo -e "${YELLOW}  Ошибка: ${test_output}${NC}"

    # Rollback: restore from backup if exists
    local latest_backup=$(ls -t /usr/local/etc/xray/backups/config_*.json 2>/dev/null | head -1)
    if [[ -n "$latest_backup" ]]; then
      echo -e "${YELLOW}  → Восстанавливаю конфиг из бэкапа...${NC}"
      cp "$latest_backup" "$CONFIG_FILE"
      chown root:root "$CONFIG_FILE"
      chmod 644 "$CONFIG_FILE"
      echo -e "${GREEN}  ✓ Конфиг восстановлен из: $(basename "$latest_backup")${NC}"
    fi
    return 1
  fi

  systemctl restart xray
  sleep 1

  if systemctl is-active --quiet xray; then
    echo -e "${GREEN}  ✓ Xray перезапущен${NC}"
    return 0
  else
    echo -e "${RED}  ✗ Xray не запустился после перезапуска${NC}"
    return 1
  fi
}
```

**Source:** Official Xray docs confirm `xray run -test -config` validates without starting. Confirmed by XTLS/Xray-core Discussion #2570 showing this in systemd service context.

**All 10 restart locations (line numbers in current codebase):**

| Line | Function | Context |
|------|----------|---------|
| 286 | migrate_xhttp_profiles | After XHTTP profile migration |
| 499 | main_menu | After all migrations complete |
| 689 | create_profile | After successful profile creation |
| 1026 | delete_profile_menu | After profile deletion |
| 1277 | change_sni_menu | After SNI change (gRPC path) |
| 1441 | change_sni_menu | After SNI change (main path) |
| 1603 | change_fingerprint_menu | After fingerprint change |
| 1840 | change_port_menu | After port change |
| 2232 | install_adguard_home | After AdGuard Home install |
| 2365 | uninstall_adguard_home | After AdGuard Home uninstall |

**Note:** Line 286 (migrate_xhttp_profiles) has its own restart separate from the main_menu migration restart at line 499. The migration at line 286 runs independently with its own marker check. Both should use safe_restart_xray.

### Pattern 2: Config Backup Before Mutation

**What:** Before any migration modifies config.json, create a timestamped backup.

**Implementation:**

```bash
# Создание бэкапа config.json перед миграцией
# Args: $1=migration_name (optional, for logging)
# Returns: path to backup file
backup_config() {
  local migration_name=${1:-"manual"}
  local backup_dir="/usr/local/etc/xray/backups"
  mkdir -p "$backup_dir"
  local backup_file="$backup_dir/config_$(date +%Y%m%d_%H%M%S)_${migration_name}.json"
  cp "$CONFIG_FILE" "$backup_file"
  echo -e "${CYAN}  → Бэкап конфига: $(basename "$backup_file")${NC}"
  echo "$backup_file"
}
```

**Where to call:** At the start of every `migrate_*` function, before any jq operations.

### Pattern 3: Migration Function Template

**What:** Standard template for migrations that uses safe_jq_write and backup.

**Current pattern (problematic):**
```bash
# Lines 305-316 (migrate_routing_config) -- RAW JQ
local temp_config=$(mktemp)
jq '...' "$CONFIG_FILE" > "$temp_config"
if [[ $? -eq 0 ]] && [[ -s "$temp_config" ]]; then
  mv "$temp_config" "$CONFIG_FILE"
  chown root:root "$CONFIG_FILE"
  chmod 644 "$CONFIG_FILE"
```

**Target pattern:**
```bash
# Using safe_jq_write -- no temp file management needed
backup_config "routing_v132"
if safe_jq_write '...' "$CONFIG_FILE"; then
  echo -e "${GREEN}  ✓ Маршрутизация исправлена${NC}"
  return 0
else
  echo -e "${RED}  ✗ Ошибка миграции маршрутизации${NC}"
  return 1
fi
```

### Anti-Patterns to Avoid

- **Raw jq pipe to temp file:** `jq '...' "$file" > "$temp" && mv "$temp" "$file"` -- always use `safe_jq_write` instead. It handles temp file, validation, permissions, and error reporting.
- **Bare systemctl restart xray:** Never call directly -- always through `safe_restart_xray()`.
- **Modifying config without backup:** Never run migrations without `backup_config()` first.

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Random hex string | bash arithmetic | `openssl rand -hex 4` | Cryptographically secure, exactly 8 hex chars |
| Config validation | JSON syntax check | `xray run -test -config` | Validates Xray-specific semantics, not just JSON |
| Service capabilities | Manual setcap | systemd `AmbientCapabilities` | Persistent across restarts, managed by init system |
| Atomic file write | manual temp+mv | `safe_jq_write()` | Already exists, handles permissions, validates non-empty |

## Common Pitfalls

### Pitfall 1: xray x25519 Output Format Change (SEC-04)

**What goes wrong:** The `xray x25519` command changed output format between versions:
- **Old format (pre-v25.3.6):** `Private key: ...` / `Public key: ...`
- **New format (v25.3.6+):** `PrivateKey: ...` / `Password: ...` / `Hash32: ...`

The "Password" field in new format IS the public key. The install.sh currently greps for `"PrivateKey:"` (line 124) and `"Password:"` (line 125), which works ONLY with the new format. If a user somehow has an older Xray binary during install, it will fail silently (empty PUBLIC_KEY).

**How to avoid:** Support both formats:
```bash
KEYS_OUTPUT=$(/usr/local/bin/xray x25519 2>&1)
PRIVATE_KEY=$(echo "$KEYS_OUTPUT" | grep -E "Private[ _]?[Kk]ey:|PrivateKey:" | awk '{print $NF}')
PUBLIC_KEY=$(echo "$KEYS_OUTPUT" | grep -E "Public[ _]?[Kk]ey:|Password:" | awk '{print $NF}')
```

**Confidence:** HIGH -- Confirmed by Marzban PR #1972 (feat: Support new xray X25519 output format) and XTLS/Xray-core Discussion #5219. The format change happened in v25.3.6.

### Pitfall 2: Non-Root Xray Needs File Permission Changes (SEC-05)

**What goes wrong:** Switching from `User=root` to `User=xray` breaks Xray because it cannot read private keys and config files owned by root with 600 permissions.

**How to avoid:**
1. Create a dedicated `xray` system user (no login, no home)
2. Change ownership of config files to `xray:xray`
3. Keep private key at 600 but owned by `xray`
4. Add `AmbientCapabilities=CAP_NET_BIND_SERVICE` to systemd service
5. The xrayebator script itself still runs as root (it has the root check at line 29), so it can manage files -- but the Xray daemon runs as `xray` user

**systemd service modification:**
```ini
[Service]
User=xray
Group=xray
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
```

**File permissions needed:**
```
/usr/local/etc/xray/                 -- xray:xray 755
/usr/local/etc/xray/config.json      -- xray:xray 644
/usr/local/etc/xray/.private_key     -- xray:xray 600
/usr/local/etc/xray/.public_key      -- xray:xray 644
/usr/local/etc/xray/profiles/        -- xray:xray 755
/usr/local/etc/xray/profiles/*.json  -- xray:xray 644
/usr/local/etc/xray/data/            -- xray:xray 755
/usr/local/etc/xray/backups/         -- xray:xray 755
/var/log/xray/                       -- xray:xray 755
```

**Warning:** The `safe_jq_write` function sets `chown root:root` and `chmod 644` on every write (lines 135-136). After SEC-05, this needs to change to `chown xray:xray` or better yet, not change ownership at all (files already have correct owner, jq writes as root from the script, then it should chown to xray).

**Confidence:** HIGH -- systemd AmbientCapabilities confirmed working on Server Fault, Stack Overflow, and Arch Linux forums. The Xray-install script defaults to `User=nobody` which proves non-root is the intended configuration.

### Pitfall 3: Port 53 Direction of Fix (SEC-02 + SEC-03)

**What goes wrong:** Two independent issues:

**SEC-02 (install):** Lines 2235-2236 call `open_firewall_port 53` and `open_firewall_port 53 udp` after AdGuard Home install. This opens port 53 to the ENTIRE internet. AdGuard Home binds DNS to `0.0.0.0:53` (line 2028 in yaml), which is correct -- Xray connects to it on `127.0.0.1`. But UFW should NOT open port 53 externally.

**Fix:** Simply remove the two `open_firewall_port` calls. AdGuard Home listens on `0.0.0.0:53`, Xray connects to `127.0.0.1:53`. Loopback traffic never hits UFW, so no firewall rule is needed.

**SEC-03 (uninstall):** Lines 2356-2361 only close port 3000/tcp but NOT port 53 (tcp or udp). If port 53 was opened during install (by the buggy current code), it stays open forever after uninstall.

**Fix:** Add `ufw delete allow 53/tcp` and `ufw delete allow 53/udp` to the uninstall function. These are idempotent -- safe to run even if port was never opened.

**Confidence:** HIGH -- verified by reading the code. Loopback traffic does not go through UFW on Linux (confirmed by UFW documentation).

### Pitfall 4: update.sh DNS Overwrite When AdGuard Home Is Active (SEC-06)

**What goes wrong:** update.sh line 329 checks `if ! grep -q "dns.adguard-dns.com" "$CONFIG_FILE"` to decide whether to migrate DNS. When AdGuard Home is installed, Xray DNS is `127.0.0.1` (no mention of `dns.adguard-dns.com`), so the check passes and the migration overwrites `127.0.0.1` with `dns.adguard-dns.com`. All DNS goes to remote DoH instead of local AdGuard Home.

**Fix:** Before the DNS migration, check if DNS is already pointing to `127.0.0.1`:
```bash
if jq -e '.dns.servers[] | select(. == "127.0.0.1")' "$CONFIG_FILE" >/dev/null 2>&1; then
  echo -e "${GREEN}  ✓ DNS → 127.0.0.1 (AdGuard Home) — сохранено${NC}"
else
  # ... proceed with DNS migration
fi
```

**Confidence:** HIGH -- verified by reading update.sh lines 324-356.

### Pitfall 5: shortIds Empty String vs Non-Empty (SEC-01)

**What goes wrong:** All 4 inbound templates (tcp-mux line 836, tcp line 865, grpc line 895, xhttp line 939) use `"shortIds": [""]` -- an array with a single empty string. This means the client can connect with an empty shortId. While technically valid per Xray docs, it provides no additional client identification and is considered weak security by all serious deployment guides.

**Fix:** Generate 8-char hex shortId when creating inbound:
```bash
local short_id=$(openssl rand -hex 4)
```
Then use `"shortIds": ["$short_id"]` in the inbound template.

**Impact on existing profiles:** This is a BREAKING change for existing connections. The shortId must be included in the VLESS connection link (`sid=` parameter). Currently all links use `sid=` (empty). New inbounds will use `sid=<hex>`.

**Important:** This only affects NEW inbounds created after the fix. Existing inbounds keep their empty shortIds. A migration to add shortIds to existing inbounds would break all current client connections and is out of scope for this phase.

**Connection link update required:** Lines 1101, 1105, 1109, 1113 -- the `sid=` parameter must be populated from the inbound's shortIds. Need to read shortId from config.json when generating the connection link:
```bash
local short_id=$(jq -r --argjson port "$port" \
  '.inbounds[] | select(.port == $port) | .streamSettings.realitySettings.shortIds[0]' \
  "$CONFIG_FILE" 2>/dev/null)
```

**Profile JSON update:** Store shortId in the profile JSON for easy access, or read from config.json each time.

**Confidence:** HIGH -- Xray docs confirm shortIds behavior. `openssl rand -hex 4` is standard approach used in official Xray examples.

### Pitfall 6: safe_jq_write chown After Non-Root Migration

**What goes wrong:** `safe_jq_write` (line 135) always runs `chown root:root "$dst_file"`. After SEC-05 makes Xray run as non-root user, config files owned by root:root cannot be read by the xray user.

**How to avoid:** Two options:
1. Change `safe_jq_write` to not set ownership (the script runs as root, files already have correct ownership)
2. Change to `chown xray:xray` -- but this hardcodes the username

**Recommended:** Remove the `chown` from `safe_jq_write` entirely. The script already runs as root (line 29 check). Files created by root-running script will be owned by root. Then in install.sh, after initial setup, chown the entire `/usr/local/etc/xray/` tree to xray user. And add a helper function to fix permissions after writes:

```bash
fix_xray_permissions() {
  chown -R xray:xray /usr/local/etc/xray/ 2>/dev/null || true
  chmod 600 "$PRIVATE_KEY_FILE" 2>/dev/null || true
}
```

Call this after migration batches and profile operations, not after every single jq write.

**Confidence:** MEDIUM -- this is a design decision. Both approaches work, but removing chown from safe_jq_write is cleaner.

## Code Examples

### Example 1: Generating shortIds for Inbound Templates

```bash
# Generate 8-character hex shortId
local short_id=$(openssl rand -hex 4)

# In inbound template (all 4 transport types):
# Replace:  "shortIds": [""]
# With:     "shortIds": ["$short_id"]
```

The shortId must also be stored in the profile JSON and used in connection link generation:
```bash
# In generate_connection(), read shortId from config:
local short_id=$(jq -r --argjson port "$port" \
  '.inbounds[] | select(.port == $port) | .streamSettings.realitySettings.shortIds[0]' \
  "$CONFIG_FILE" 2>/dev/null)
[[ -z "$short_id" || "$short_id" == "null" ]] && short_id=""

# In VLESS link:  sid=${short_id}
```

### Example 2: Converting migrate_routing_config to safe_jq_write

**Current (lines 305-316):**
```bash
local temp_config=$(mktemp)
jq '.routing.rules += [{
  "type": "field",
  "network": "tcp,udp",
  "outboundTag": "direct"
}]' "$CONFIG_FILE" > "$temp_config"

if [[ $? -eq 0 ]] && [[ -s "$temp_config" ]]; then
  mv "$temp_config" "$CONFIG_FILE"
  chown root:root "$CONFIG_FILE"
  chmod 644 "$CONFIG_FILE"
```

**Target:**
```bash
backup_config "routing_v132"
if safe_jq_write '.routing.rules += [{
  "type": "field",
  "network": "tcp,udp",
  "outboundTag": "direct"
}]' "$CONFIG_FILE"; then
  echo -e "${GREEN}  ✓ Маршрутизация исправлена${NC}"
  return 0
else
  echo -e "${RED}  ✗ Ошибка миграции маршрутизации${NC}"
  return 1
fi
```

### Example 3: Converting update_transport_settings_for_sni Base Update

**Current (lines 80-96):**
```bash
local temp_config=$(mktemp)
jq --argjson port "$port_num" --arg sni "$new_sni" '
  (.inbounds[] | select(.port == $port) | .streamSettings.realitySettings.dest) |= ($sni + ":443") |
  (.inbounds[] | select(.port == $port) | .streamSettings.realitySettings.serverNames) |= [$sni]
' "$config_file" > "$temp_config"

if [[ $? -ne 0 ]] || [[ ! -s "$temp_config" ]]; then
  echo -e "${RED}  ✗ Ошибка обновления SNI${NC}"
  rm -f "$temp_config"
  return 1
fi

mv "$temp_config" "$config_file"
chown root:root "$config_file" 2>/dev/null
chmod 644 "$config_file" 2>/dev/null
```

**Target:**
```bash
if ! safe_jq_write --argjson port "$port_num" --arg sni "$new_sni" '
  (.inbounds[] | select(.port == $port) | .streamSettings.realitySettings.dest) |= ($sni + ":443") |
  (.inbounds[] | select(.port == $port) | .streamSettings.realitySettings.serverNames) |= [$sni]
' "$config_file"; then
  echo -e "${RED}  ✗ Ошибка обновления SNI${NC}"
  return 1
fi
```

### Example 4: Non-Root Xray systemd Configuration

```bash
# In install.sh, replace line 73:
#   sed -i 's/^User=nobody/User=root/' /etc/systemd/system/xray.service
# With:

# Create xray system user if not exists
if ! id "xray" &>/dev/null; then
  useradd -r -s /usr/sbin/nologin -M xray
fi

# Configure systemd service for non-root with capabilities
mkdir -p /etc/systemd/system/xray.service.d
cat > /etc/systemd/system/xray.service.d/security.conf << 'SVCEOF'
[Service]
User=xray
Group=xray
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
SVCEOF

# Set file ownership
chown -R xray:xray /usr/local/etc/xray/
chmod 600 /usr/local/etc/xray/.private_key
chmod 644 /usr/local/etc/xray/.public_key
chmod 644 /usr/local/etc/xray/config.json

# Create log directory for xray user
mkdir -p /var/log/xray
chown xray:xray /var/log/xray

systemctl daemon-reload
```

**Using systemd drop-in file** (instead of modifying xray.service directly) avoids conflicts when the Xray-install script updates the service file. Drop-in overrides are preserved across updates.

### Example 5: install.sh Key Extraction (Both Formats)

```bash
KEYS_OUTPUT=$(/usr/local/bin/xray x25519 2>&1)
# Support both old format (Private key:/Public key:) and new format (PrivateKey:/Password:)
PRIVATE_KEY=$(echo "$KEYS_OUTPUT" | grep -E "^Private" | awk '{print $NF}')
PUBLIC_KEY=$(echo "$KEYS_OUTPUT" | grep -E "^Public|^Password" | awk '{print $NF}')
```

**Reasoning:** `grep -E "^Private"` matches both `Private key:` and `PrivateKey:`. `grep -E "^Public|^Password"` matches both `Public key:` and `Password:`. `awk '{print $NF}'` takes the last field regardless of delimiter format.

### Example 6: SNI List Cleanup

**Remove from sni_list.txt (foreign section):**
- `www.google.com` -- TSPU detects, high priority target
- `www.microsoft.com` -- TSPU detects
- `www.apple.com` -- TSPU detects
- `www.bbc.com` -- already blocked in Russia

**Remove from sni_list.txt (fallback section):**
- `www.yahoo.com` -- TSPU detects, low-trust site

**Keep:**
- `www.github.com`, `raw.githubusercontent.com`, `api.github.com` -- needed for gRPC, less targeted
- `www.cloudflare.com`, `cdn.cloudflare.net` -- needed for gRPC, CDN infrastructure
- `www.mozilla.org`, `www.ubuntu.com`, `www.debian.org` -- keep as fallback, less targeted than Google/MS

**Also update hardcoded references:**
- Line 650: `default_sni="www.google.com"` for gRPC -- change to `www.cloudflare.com`
- Line 655: `default_sni="www.microsoft.com"` as fallback -- change to first entry from sni_list.txt (which is `www.ozon.ru`)
- Lines 1220-1223: gRPC SNI menu still shows google.com, microsoft.com -- update to safer alternatives
- Line 1090: fallback `sni // "www.microsoft.com"` in generate_connection -- change to `www.ozon.ru`
- Line 1203: fallback `sni // "www.microsoft.com"` in change_sni_menu -- change to `www.ozon.ru`
- Line 1319: `sni_desc["www.microsoft.com"]="Часто фильтруется"` -- already acknowledges the problem

### Example 7: update.sh DNS Preservation Fix

**Current (line 329):**
```bash
if ! grep -q "dns.adguard-dns.com" "$CONFIG_FILE" 2>/dev/null; then
  # migrates DNS to AdGuard DoH...
```

**Fix:**
```bash
# Проверяем: если DNS указывает на 127.0.0.1 (AdGuard Home), не трогаем
local current_dns=$(jq -r '.dns.servers[0] // ""' "$CONFIG_FILE" 2>/dev/null)
if [[ "$current_dns" == "127.0.0.1" ]]; then
  echo -e "${GREEN}  ✓ DNS → 127.0.0.1 (AdGuard Home) — сохранено${NC}"
elif ! grep -q "dns.adguard-dns.com" "$CONFIG_FILE" 2>/dev/null; then
  # ... proceed with DNS migration
fi
```

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| `xray x25519` outputs "Public key:" | Outputs "Password:" + "Hash32:" | v25.3.6 (March 2025) | install.sh key extraction must handle both |
| Xray runs as root | Run as dedicated user with CAP_NET_BIND_SERVICE | Best practice since systemd 229+ | Reduces attack surface |
| Empty shortIds | Non-empty hex shortIds | Always recommended, increasingly important | Better client identification |
| Direct service file edit | systemd drop-in files | Always available | Survives Xray-install updates |

## Open Questions

1. **shortIds for existing inbounds**
   - What we know: Adding shortIds to existing inbounds breaks all current client connections (clients need `sid=<hex>` in their config)
   - What's unclear: Should we provide a menu option to migrate existing inbounds?
   - Recommendation: Out of scope for Phase 1. Only new inbounds get shortIds. Add migration option in future phase.

2. **safe_jq_write chown behavior after non-root**
   - What we know: safe_jq_write always chowns to root:root. After non-root fix, files need xray:xray ownership.
   - What's unclear: Should we change safe_jq_write itself or add a permissions-fix function?
   - Recommendation: Remove chown/chmod from safe_jq_write (lines 135-136). Add a separate `fix_xray_permissions()` called at strategic points (after migration batch, after profile creation/deletion). The script runs as root anyway.

3. **gRPC SNI alternatives after removing google.com/microsoft.com**
   - What we know: gRPC requires HTTP/2 support. Russian sites do not support HTTP/2. Google and Microsoft are TSPU targets.
   - What's unclear: Which foreign domains with HTTP/2 are least likely to be TSPU targets?
   - Recommendation: Use `www.cloudflare.com` as primary gRPC SNI (CDN infrastructure, harder to block). Keep `github.com` as secondary. Add `www.amazon.com` or `aws.amazon.com` as alternatives.

## Sources

### Primary (HIGH confidence)
- Xray official docs: `xtls.github.io/en/document/command.html` -- confirmed `xray run -test -config` syntax
- Xray official docs: `xtls.github.io/en/config/transport.html` -- shortIds configuration, empty vs non-empty
- XTLS/Xray-core Discussion #1702 -- Reality testing methodology, shortIds format (hex, max 16 chars)
- XTLS/Xray-core Discussion #2570 -- systemd service example with CAP_NET_BIND_SERVICE
- XTLS/Xray-install README -- default `User=nobody`, does NOT overwrite User in existing service files
- Marzban PR #1972 -- confirmed xray x25519 output format change in v25.3.6+

### Secondary (MEDIUM confidence)
- Server Fault #916807 -- AmbientCapabilities=CAP_NET_BIND_SERVICE confirmed working for port 443
- Stack Overflow #413807 -- AmbientCapabilities with User= works without iptables
- unix.stackexchange.com #580597 -- difference between AmbientCapabilities and CapabilityBoundingSet

### Codebase Analysis (HIGH confidence)
- All 10 `systemctl restart xray` locations mapped and verified
- All 4 inbound templates with `shortIds: [""]` identified (lines 836, 865, 895, 939)
- All 3 migration functions with raw jq identified (migrate_routing_config, migrate_xhttp_mode, migrate_xhttp_extra_restore)
- update_transport_settings_for_sni partial safe_jq_write usage verified (base SNI raw, XHTTP host safe)
- Port 53 open (lines 2235-2236) and missing close (lines 2356-2361) verified
- install.sh line 73 `sed -i 's/^User=nobody/User=root/'` verified
- install.sh lines 124-125 key extraction grep patterns verified
- update.sh line 329 DNS overwrite condition verified
- sni_list.txt content analyzed: google.com, microsoft.com, apple.com, bbc.com, yahoo.com confirmed present
- create_profile indentation issues at lines 643, 658-660 verified

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH -- bash, jq, systemd, openssl are all standard tools on target platforms
- Architecture: HIGH -- all patterns are direct replacements within existing code structure
- Pitfalls: HIGH -- every pitfall verified by reading the actual source code, not hypothetical
- Security fixes: HIGH -- all vulnerabilities confirmed by codebase analysis, fixes verified by official docs

**Research date:** 2026-03-08
**Valid until:** 2026-04-08 (stable domain, Xray core API unlikely to change)
