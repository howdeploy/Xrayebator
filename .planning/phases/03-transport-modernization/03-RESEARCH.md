# Phase 3: Transport Modernization - Research

**Researched:** 2026-03-10
**Domain:** Xray transport defaults, Reality profile generation, single-file Bash TUI UX
**Confidence:** HIGH

## Summary

Phase 3 is not a pure text/menu refresh. The current transport behavior is encoded across five coupled areas in `xrayebator`: `create_profile_menu()`, `create_profile()`, `add_inbound()`, connection-link rendering, and `change_port_menu()`. Today the script hardcodes legacy defaults that directly conflict with the phase goal: menu order still recommends `tcp-mux` first, common ports are fixed to `443/8443/2053/9443`, gRPC always uses `serviceName=grpc`, XHTTP always uses `path=/xhttp`, and the warning language understates that Vision on `443` is now a risky/manual option rather than a safe default.

The most important planning insight is that TRN-02/TRN-03/TRN-04 require a small profile metadata expansion, not just different literals. Profile JSON currently stores only `transport`, `port`, `fingerprint`, and `sni`; it does not store XHTTP `path` or gRPC `serviceName`. As a result, the QR/link output hardcodes `/xhttp` and `grpc`, and any randomized values would be lost immediately after profile creation. Without fixing the metadata model first, the phase will look implemented in `config.json` but will generate broken client links.

The implementation is still small enough for one Phase 3 plan, but the plan should sequence work carefully: first introduce transport-default helpers and metadata fields, then rewire profile creation + inbound generation to use them, then update link/manual output and change-port UX, then refresh transport descriptions and explicit Vision-on-443 confirmation. No broad refactor is needed; the phase fits the existing single-file Bash architecture if helpers stay compact and profile schema changes are additive.

**Primary recommendation:** Plan Phase 3 around a single source of truth for transport defaults per profile, with additive metadata for `grpc_service_name` and `xhttp_path`, plus one small migration to preserve backward compatibility for old profiles.

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|-----------------|
| TRN-01 | XHTTP+Reality is the first and recommended transport | `create_profile_menu()` currently puts `tcp-mux` first and XHTTP fifth; menu order and recommendation text are the primary implementation seam |
| TRN-02 | All transports default to random high ports | `create_profile_menu()` and `change_port_menu()` hardcode popular low ports; port choice logic must move to a helper and preserve compatibility checks in `add_inbound()` |
| TRN-03 | gRPC `serviceName` is randomized | `add_inbound()` hardcodes `grpcSettings.serviceName = "grpc"` and connection output hardcodes `serviceName=grpc`; profile metadata currently cannot store the randomized value |
| TRN-04 | XHTTP path is randomized | `add_inbound()` hardcodes `xhttpSettings.path = "/xhttp"` and connection output hardcodes `path=%2Fxhttp`; profile metadata currently cannot store the randomized value |
| TRN-05 | Vision-on-443 is no longer default; show honest blocking warning | current menu still treats multiple `443`/`8443` Vision variants as normal first-class options; create flow needs an explicit warning/confirm gate |
| TRN-06 | Transport descriptions updated for current TSPU realities | all menu copy is concentrated in `create_profile_menu()` and partly in connection output; this is a copy update after behavior is fixed |
</phase_requirements>

## Standard Stack

### Core
| Tool | Version | Purpose | Why Standard |
|------|---------|---------|--------------|
| bash | 5.x | Runtime and TUI flow | Project constraint: single-file Bash only |
| jq | 1.6+ | Read/write profile metadata and config.json | Already the project’s standard for safe JSON mutation |
| openssl | 1.1+ | Random high ports, randomized path/service tokens | Already used for shortIds; avoids adding new dependencies |
| xray | 25.x+ | Transport config semantics (`xhttpSettings`, `grpcSettings`, Reality) | Official transport behavior comes from Xray docs |

### Supporting
| Function/Concept | Location | Purpose | When to Use |
|------------------|----------|---------|-------------|
| `safe_jq_write()` | `xrayebator` | Atomic JSON writes | All profile/config updates |
| `safe_restart_xray()` | `xrayebator` | Validate + restart after transport changes | After successful profile/inbound mutations |
| `fix_xray_permissions()` | `xrayebator` | Restore `xray:xray` ownership | After profile/config writes |
| `open_firewall_port()` / `close_firewall_port()` | `xrayebator` | UFW sync with inbound port changes | When creating/moving inbounds |

### Alternatives Considered
| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| Storing transport extras in profile JSON | Re-read them from `config.json` by port | Fails when multiple clients share an inbound and makes link generation more fragile |
| One generic “custom transport params” blob | Explicit `grpc_service_name` and `xhttp_path` fields | Blob is flexible but adds parsing complexity to Bash and weakens readability |
| Reusing port presets with random manual option | Full random-high-port default helper | Keeping presets as defaults conflicts with TRN-02 and weakens menu guidance |

## Architecture Patterns

### Recommended Project Structure

Keep everything in `xrayebator`, but treat these as logical sections:

- Random/default helpers near other utilities
- Profile creation flow in `create_profile_menu()` and `create_profile()`
- Inbound builders in `add_inbound()`
- Client output in `show_connection_info()`
- Compatibility/backfill migration in `main_menu()` marker section

### Pattern 1: Single Source of Truth for Transport Defaults

**What:** Introduce small helper functions that return the default port and transport-specific random values, instead of embedding literals in menu cases and inbound templates.

**When to use:** Any time the script creates a new profile, new inbound, or prints connection instructions.

**Why:** The current code repeats defaults in three places. If only one of them changes, the generated link or displayed manual settings drift from the real inbound.

**Example:**

```bash
generate_random_high_port() {
  local min=30000
  local max=60000
  echo $((min + (RANDOM << 15 | RANDOM) % (max - min + 1)))
}

generate_transport_token() {
  local prefix=$1
  local bytes=${2:-6}
  echo "${prefix}-$(openssl rand -hex "$bytes")"
}

build_transport_defaults() {
  local transport=$1
  local port
  port=$(generate_random_high_port)

  case "$transport" in
    grpc)
      printf '%s|%s|\n' "$port" "$(generate_transport_token grpc 4)"
      ;;
    xhttp)
      printf '%s||/%s\n' "$port" "$(generate_transport_token xhttp 4)"
      ;;
    *)
      printf '%s||\n' "$port"
      ;;
  esac
}
```

**Planning note:** In Bash, do not over-engineer this into associative-object plumbing. A compact pipe-delimited return or globals is sufficient.

### Pattern 2: Additive Profile Metadata Schema

**What:** Extend profile JSON with optional fields for transport-specific client parameters:

- `grpc_service_name`
- `xhttp_path`
- optionally `transport_warning_ack` if explicit confirmations need persistence

**When to use:** At profile creation time and when rendering QR/manual output.

**Why:** Current profile files do not contain enough information to reconstruct client config once randomized values are introduced.

**Recommended profile shape:**

```json
{
  "name": "user1",
  "uuid": "uuid",
  "transport": "xhttp",
  "port": "35142",
  "fingerprint": "chrome",
  "sni": "www.ozon.ru",
  "xhttp_path": "/xhttp-a1b2c3d4",
  "created": "2026-03-10 12:00:00"
}
```

**Migration rule:** Old profiles should continue to work. Missing fields should fall back to legacy values:

- gRPC: `grpc_service_name -> "grpc"`
- XHTTP: `xhttp_path -> "/xhttp"`

This lets the phase ship without rewriting every old profile immediately.

### Pattern 3: Transport Builder Inputs Passed Explicitly

**What:** Change `create_profile()` and `add_inbound()` signatures to accept transport extras directly instead of having templates guess them internally.

**When to use:** New inbound creation and link generation.

**Why:** Right now `add_inbound()` knows the transport but not the profile-specific randomized metadata. Passing explicit values removes hidden coupling.

**Recommended shape:**

```bash
create_profile "$name" "$transport" "$port" "$fingerprint" "$custom_sni" "$grpc_service_name" "$xhttp_path"
add_inbound "$uuid" "$transport" "$port" "$sni" "$fingerprint" "$grpc_service_name" "$xhttp_path"
```

**Planning note:** This is a targeted signature expansion, not a refactor. Keep positional args and comment them clearly.

### Pattern 4: Warning Gate for Risky Legacy Transport Choices

**What:** Wrap Vision-on-443 selections in an explicit confirmation step with honest risk text before any file write.

**When to use:** Any transport preset that still chooses `tcp`, `tcp-utls`, or `tcp-xudp` on `443`, or any manual port change that sets a Vision transport to `443`.

**Why:** TRN-05 is behavioral, not cosmetic. The script must force the user to acknowledge risk instead of merely showing a static menu line.

**Example behavior:**

```bash
confirm_vision_443_risk() {
  echo -e "${RED}⚠ Vision на 443 в 2026 году часто блокируется ТСПУ.${NC}"
  echo -e "${YELLOW}Используйте только как ручной рискованный вариант, если XHTTP/gRPC не подходят.${NC}"
  echo -n -e "${YELLOW}Продолжить? (y/N): ${NC}"
  read confirm
  [[ "$confirm" =~ ^[yYдД]$ ]]
}
```

**Planning note:** Reuse this helper from both creation flow and `change_port_menu()` so the warning cannot be bypassed by editing an existing profile.

### Pattern 5: Backward-Compatible Migration for Metadata Only

**What:** Add one marker-gated migration that backfills missing transport metadata in profile files where it can be inferred safely.

**When to use:** First launch after Phase 3 update.

**Why:** Existing gRPC/XHTTP profiles should display correct links even if created before the new schema.

**Safe scope:**

- For gRPC profiles missing `grpc_service_name`, set `"grpc"`
- For XHTTP profiles missing `xhttp_path`, set `"/xhttp"`
- Do not randomize existing profiles automatically; preserve current client compatibility

**Marker pattern:** Follow the existing Phase 1/2 migration style with backup, `safe_jq_write`, `fix_xray_permissions`, marker file, and `safe_restart_xray()` only if `config.json` was changed. Since this migration touches profile JSON only, restart is likely unnecessary.

### Anti-Patterns to Avoid

- **Randomize existing live profiles in-place:** breaks all existing client links and violates backward compatibility.
- **Hardcode randomized values only in `config.json`:** QR/manual output becomes wrong immediately.
- **Scatter port rules across multiple menus:** guarantees drift between creation and change-port behavior.
- **Use low “popular HTTPS” ports as defaults while claiming randomization:** fails TRN-02 in practice.
- **Bury the Vision-on-443 warning in menu prose only:** users can still click through without explicit acknowledgement.

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Random token generation | ad-hoc `$RANDOM` strings | `openssl rand -hex` | Better entropy, predictable ASCII, already a dependency |
| JSON profile rewrites | `cat > file` rewrites for updates | `safe_jq_write` | Preserves atomicity and project conventions |
| Compatibility lookup for old profiles | deep parsing from printed links | additive metadata + legacy fallback | Simpler and reliable in Bash |
| Risk gating | passive menu text | reusable confirmation helper | Enforces TRN-05 in both create and edit flows |

**Key insight:** The hard part of this phase is state consistency, not transport syntax. Solve “where do these values live?” first.

## Common Pitfalls

### Pitfall 1: Randomized XHTTP path exists only in inbound config
**What goes wrong:** Inbound is created with a random `xhttpSettings.path`, but the QR link still prints `/xhttp`.
**Why it happens:** `show_connection_info()` currently hardcodes the client path.
**How to avoid:** Store `xhttp_path` in profile JSON at creation time and read it everywhere client config is rendered.
**Warning signs:** Newly created XHTTP profiles connect only when manually edited on the client.

### Pitfall 2: Randomized gRPC service name breaks old connection output
**What goes wrong:** Server expects a random `serviceName`, but exported VLESS links still show `serviceName=grpc`.
**Why it happens:** `grpcSettings.serviceName` and link generation are currently coupled only by shared hardcoded text.
**How to avoid:** Add `grpc_service_name` to profile metadata and use legacy fallback `"grpc"` only when the field is missing.
**Warning signs:** gRPC profiles are created successfully but all fresh client imports fail.

### Pitfall 3: Random high port collides with existing inbound
**What goes wrong:** Helper picks a port already used by another inbound, leading to transport conflict or unexpected profile merge.
**Why it happens:** Random selection alone does not check `config.json`.
**How to avoid:** Add a `find_available_random_port()` helper that loops until `.inbounds[] | select(.port == $port)` is empty.
**Warning signs:** Some profile creations unexpectedly reuse an existing SNI/fingerprint from another inbound.

### Pitfall 4: `change_port_menu()` keeps steering users back to blocked defaults
**What goes wrong:** New profile creation uses random high ports, but later port edits still push users toward `443/8443/2053/9443`.
**Why it happens:** Phase work updates only creation flow, not port-change flow.
**How to avoid:** Update `change_port_menu()` to make “random high port” the first option and downgrade legacy ports to manual/risky choices.
**Warning signs:** Users immediately move profiles back onto obvious low ports after creation.

### Pitfall 5: Shared inbound semantics are broken by per-profile transport extras
**What goes wrong:** Two profiles share one gRPC/XHTTP inbound, but each profile stores different service/path metadata.
**Why it happens:** These values are inbound-level, not client-level.
**How to avoid:** When attaching a new client to an existing inbound, override the new profile metadata to match the inbound’s actual `serviceName` or `path`, just like current SNI/fingerprint sync.
**Warning signs:** Two profiles on the same port export different XHTTP paths or gRPC service names.

### Pitfall 6: Vision-on-443 warning is enforced on create but not on manual port changes
**What goes wrong:** Users bypass TRN-05 by changing a Vision profile’s port to `443` via `change_port_menu()`.
**Why it happens:** Warning logic exists in only one UX path.
**How to avoid:** Centralize the warning into one helper and call it from both creation and port-change code.
**Warning signs:** Audit shows warning copy present, but no confirmation prompt appears during port edits.

## Code Examples

Verified patterns from current codebase and official Xray docs.

### Metadata Backfill for Old Profiles

```bash
migrate_transport_profile_metadata() {
  local changed=false
  local pf transport

  for pf in "$PROFILES_DIR"/*.json; do
    [[ ! -f "$pf" ]] && continue
    transport=$(jq -r '.transport // ""' "$pf" 2>/dev/null)

    case "$transport" in
      grpc)
        if [[ "$(jq -r '.grpc_service_name // empty' "$pf")" == "" ]]; then
          safe_jq_write '.grpc_service_name = "grpc"' "$pf" || return 1
          changed=true
        fi
        ;;
      xhttp)
        if [[ "$(jq -r '.xhttp_path // empty' "$pf")" == "" ]]; then
          safe_jq_write '.xhttp_path = "/xhttp"' "$pf" || return 1
          changed=true
        fi
        ;;
    esac
  done

  $changed && fix_xray_permissions
}
```

### Read Transport Extras with Legacy Fallback

```bash
local grpc_service_name=$(jq -r '.grpc_service_name // "grpc"' "$profile_file")
local xhttp_path=$(jq -r '.xhttp_path // "/xhttp"' "$profile_file")

case $transport in
  grpc)
    vless_link="vless://${uuid}@${SERVER_IP}:${port}?encryption=none&security=reality&sni=${current_sni}&fp=${fingerprint}&pbk=${clean_public_key}&sid=${short_id}&type=grpc&serviceName=${grpc_service_name}#${profile_name}"
    ;;
  xhttp)
    local encoded_xhttp_path=${xhttp_path//\//%2F}
    vless_link="vless://${uuid}@${SERVER_IP}:${port}?encryption=none&security=reality&sni=${current_sni}&fp=${fingerprint}&pbk=${clean_public_key}&sid=${short_id}&type=xhttp&path=${encoded_xhttp_path}&host=${current_sni}#${profile_name}"
    ;;
esac
```

### Sync Profile Metadata When Joining Existing Inbound

```bash
if [[ "$expected_network" == "grpc" ]]; then
  local existing_service_name=$(jq -r --argjson port "$port" \
    '.inbounds[] | select(.port == $port) | .streamSettings.grpcSettings.serviceName // "grpc"' \
    "$CONFIG_FILE")
  safe_jq_write --arg v "$existing_service_name" '.grpc_service_name = $v' "$profile_file"
fi

if [[ "$expected_network" == "xhttp" ]]; then
  local existing_xhttp_path=$(jq -r --argjson port "$port" \
    '.inbounds[] | select(.port == $port) | .streamSettings.xhttpSettings.path // "/xhttp"' \
    "$CONFIG_FILE")
  safe_jq_write --arg v "$existing_xhttp_path" '.xhttp_path = $v' "$profile_file"
fi
```

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| gRPC as a standard modern fallback | Xray docs explicitly recommend switching to XHTTP | Already reflected in docs by March 2026 | Supports TRN-01 and stronger gRPC risk wording |
| Static, recognizable service/path literals | Randomized path/service metadata per deployment | Current best practice for avoiding trivial pattern matching | Requires profile schema expansion |
| “Popular HTTPS” port defaults | Random high ports as safer defaults under active blocking | 2025-2026 TSPU context in project requirements | Menu and port-change UX must stop steering users to 443/8443 |

**Deprecated/outdated:**
- `serviceName=grpc` as a hardcoded default: easy to fingerprint and not aligned with current project requirements.
- `path=/xhttp` as a hardcoded default: same problem, and it breaks TRN-04 directly.
- Treating Vision on `443` as a normal recommendation: phase goal explicitly reframes it as risky/manual.

## Open Questions

1. **Should random port range be strictly `30000-60000` or configurable?**
   What we know: roadmap success criteria use `30000-60000`.
   What's unclear: whether operators need a narrower range for hosting/provider policy.
   Recommendation: hardcode `30000-60000` for Phase 3 and defer configurability.

2. **Should `change_port_menu()` still offer legacy low-port shortcuts?**
   What we know: requirement says defaults must be random high ports, not that low ports are forbidden.
   What's unclear: how aggressively UX should discourage manual low-port use.
   Recommendation: keep low ports as explicit manual/risky options, not as top menu entries.

3. **Should existing gRPC/XHTTP profiles be fully migrated to randomized metadata?**
   What we know: backward compatibility is a hard project constraint.
   What's unclear: whether operators want automatic rotation of old paths/service names.
   Recommendation: no automatic rotation in Phase 3; only backfill legacy literals for metadata completeness.

## Validation Architecture

There is no automated test framework in this project. Validation is manual and should be planned as explicit checklist work.

### Manual Verification Matrix

| Req ID | Behavior | Verification |
|--------|----------|-------------|
| TRN-01 | XHTTP shown first and marked recommended | Open create-profile menu and confirm option order/text |
| TRN-02 | New profiles default to high random ports | Create one profile of each transport and inspect profile JSON + `config.json` |
| TRN-03 | gRPC serviceName randomized and exported correctly | Create gRPC profile, compare profile JSON, inbound `grpcSettings`, and VLESS link |
| TRN-04 | XHTTP path randomized and exported correctly | Create XHTTP profile, compare profile JSON, inbound `xhttpSettings.path`, and VLESS link |
| TRN-05 | Vision-on-443 requires explicit confirmation | Attempt creation and port change to Vision on `443`; verify prompt blocks on default `N` |
| TRN-06 | Menu text reflects current TSPU guidance | Review Russian copy in create menu and connection output |

### Required Commands

- `bash -n xrayebator`
- `bash -n install.sh`
- `bash -n update.sh`

### High-Value Manual Scenarios

1. Create a fresh XHTTP profile and import the generated link into a client that supports XHTTP.
2. Create a fresh gRPC profile and verify link/manual output uses the randomized `serviceName`.
3. Create a second XHTTP or gRPC profile on the same port and verify metadata is synchronized to the existing inbound.
4. Move a Vision profile to port `443` via `change_port_menu()` and verify the new warning/confirmation gate appears.
5. Open an old pre-Phase-3 XHTTP or gRPC profile and verify the link still shows legacy `/xhttp` or `grpc` instead of blank data.

## Recommended Plan Decomposition

### Plan shape

One plan is sufficient, but the tasks inside it should be ordered to protect consistency:

1. Add compact helpers for random high port selection and transport token generation.
2. Extend profile schema and `create_profile()` argument flow for `grpc_service_name` / `xhttp_path`.
3. Update `add_inbound()` to consume explicit transport extras and to synchronize metadata when reusing an existing inbound.
4. Update connection-link/manual output to read stored metadata with legacy fallbacks.
5. Rework `create_profile_menu()` order and Russian copy so XHTTP is first/recommended and low-port Vision choices are clearly risky.
6. Add reusable Vision-on-443 confirmation logic to both creation flow and `change_port_menu()`.
7. Add a metadata-only migration marker for old gRPC/XHTTP profiles.
8. Run syntax validation and manual transport creation checks.

### Why this decomposition works

- Steps 1-4 solve correctness first; until they land, any menu text update is premature.
- Step 6 must cover both create and edit flows or TRN-05 remains partially unimplemented.
- The migration is intentionally narrow so old clients do not break.

## Sources

### Primary (HIGH confidence)
- Current codebase: `xrayebator` functions `create_profile_menu()`, `create_profile()`, `add_inbound()`, connection output, and `change_port_menu()`
- Project planning docs: `.planning/REQUIREMENTS.md`, `.planning/ROADMAP.md`, `.planning/STATE.md`, `.planning/PROJECT.md`
- Project guidance: `CLAUDE.md`
- Official Xray transport docs: https://xtls.github.io/en/config/transports/grpc.html
- Official Xray transport docs: https://xtls.github.io/en/config/transports/xhttp.html
- Official Xray transport overview: https://xtls.github.io/en/config/transport.html

### Secondary (MEDIUM confidence)
- XTLS/Xray-core discussion on XHTTP configuration details: https://github.com/XTLS/Xray-core/discussions/4113
