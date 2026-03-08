---
phase: 01-safety-net-security
plan: 02
subsystem: security
tags: [shortIds, non-root, capabilities, firewall, dns, xray, systemd]

# Dependency graph
requires:
  - phase: 01-01
    provides: safe_jq_write, safe_restart_xray, backup_config functions
provides:
  - Non-empty shortIds for new inbounds (8-char hex via openssl rand)
  - Connection links with sid=<hex> from config.json
  - Port 53 no longer opened during AdGuard Home install
  - Port 53 closed on AdGuard Home uninstall
  - Xray runs as non-root user xray with CAP_NET_BIND_SERVICE
  - install.sh supports both old and new xray x25519 output formats
  - update.sh preserves 127.0.0.1 DNS when AdGuard Home is active
  - fix_xray_permissions() helper for file ownership correction
affects: [01-03, phase-02 migrations, config management]

# Tech tracking
tech-stack:
  added: [systemd drop-in, CAP_NET_BIND_SERVICE]
  patterns: [non-root service execution, fix_xray_permissions after config changes]

key-files:
  created: []
  modified:
    - xrayebator
    - install.sh
    - update.sh

key-decisions:
  - "Use systemd drop-in (/etc/systemd/system/xray.service.d/security.conf) instead of modifying xray.service directly"
  - "fix_xray_permissions() called at 4 strategic points: create_profile, delete_profile, main_menu migrations, change_port"
  - "Removed all chown root:root for xray config files, keeping only for AdGuard Home yaml"
  - "Port 53 never opened in UFW since Xray connects to AdGuard Home on loopback (127.0.0.1)"

patterns-established:
  - "Non-root service: systemd drop-in with User=xray + AmbientCapabilities=CAP_NET_BIND_SERVICE"
  - "Permission fix pattern: call fix_xray_permissions() after any operation that creates/modifies xray config files"
  - "Key extraction: grep -E with awk '{print $NF}' for format-agnostic field extraction"

requirements-completed: [SEC-01, SEC-02, SEC-03, SEC-04, SEC-05, SEC-06]

# Metrics
duration: 6min
completed: 2026-03-08
---

# Phase 1 Plan 2: Security Fixes Summary

**Six security fixes: non-empty shortIds for Reality inbounds, port 53 firewall hardening, non-root Xray via systemd drop-in, dual-format key extraction, and AdGuard Home DNS preservation in update.sh**

## Performance

- **Duration:** 6 min
- **Started:** 2026-03-08T07:00:10Z
- **Completed:** 2026-03-08T07:06:54Z
- **Tasks:** 2
- **Files modified:** 3

## Accomplishments
- New inbounds generate 8-char hex shortIds via `openssl rand -hex 4`; connection links include `sid=<hex>` read from config.json
- Port 53 no longer opened in UFW during AdGuard Home install (loopback traffic); port 53 tcp+udp cleaned up on uninstall
- Xray process runs as dedicated `xray` user with `CAP_NET_BIND_SERVICE` via systemd drop-in
- install.sh key extraction supports both old (`Private key:/Public key:`) and new (`PrivateKey:/Password:`) xray x25519 formats
- update.sh skips DNS migration when AdGuard Home is active (DNS server = 127.0.0.1)
- All `chown root:root` removed from xray config file operations; replaced with `fix_xray_permissions()` at strategic points

## Task Commits

Each task was committed atomically:

1. **Task 1: ShortIds generation + port 53 fixes + update.sh DNS preservation** - `6bb12ed` (feat)
2. **Task 2: install.sh key extraction fix + non-root Xray** - `66cc4c5` (feat)

## Files Created/Modified
- `xrayebator` - shortId generation in add_inbound(), sid in connection links, port 53 firewall fixes, fix_xray_permissions(), removed chown root:root from safe_jq_write and migration functions
- `install.sh` - dual-format key extraction, xray user creation, systemd drop-in, file ownership to xray:xray
- `update.sh` - AdGuard Home DNS preservation check (skip migration when DNS = 127.0.0.1)

## Decisions Made
- Used systemd drop-in instead of modifying xray.service directly (survives Xray-core updates that regenerate the service file)
- Placed fix_xray_permissions() at 4 points (create, delete, migration, port change) to cover all config modification paths
- Removed chown root:root from all xray config paths; the only remaining chown root:root is for AdGuard Home's own yaml file
- Port 53 never needs UFW rule because Xray connects to AdGuard Home on 127.0.0.1 (loopback bypasses UFW)

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] Fixed `local` keyword usage in update.sh**
- **Found during:** Task 1 (SEC-06 DNS preservation)
- **Issue:** Plan used `local current_dns` but update.sh DNS migration runs at top-level scope (not inside a function), where `local` is invalid
- **Fix:** Changed to `CURRENT_DNS` (uppercase, no `local` keyword)
- **Files modified:** update.sh
- **Verification:** `bash -n update.sh` passes
- **Committed in:** 6bb12ed (Task 1 commit)

**2. [Rule 2 - Missing Critical] Removed chown root:root from AdGuard Home CONFIG_FILE writes**
- **Found during:** Task 2 (SEC-05 non-root cleanup)
- **Issue:** Two additional `chown root:root "$CONFIG_FILE"` calls existed in install_adguard_home() and uninstall_adguard_home() functions, which would reset xray config ownership to root
- **Fix:** Removed both chown calls, kept chmod 644
- **Files modified:** xrayebator
- **Verification:** `grep -c 'chown root:root' xrayebator` returns 1 (only AdGuard yaml)
- **Committed in:** 66cc4c5 (Task 2 commit)

---

**Total deviations:** 2 auto-fixed (1 bug, 1 missing critical)
**Impact on plan:** Both fixes necessary for correctness. No scope creep.

## Issues Encountered
None

## User Setup Required
None - no external service configuration required.

## Next Phase Readiness
- All 6 security vulnerabilities (SEC-01 through SEC-06) are fixed
- Plan 01-03 (safe_jq_write migration for raw jq calls) can proceed -- the non-root ownership pattern is established
- fix_xray_permissions() is available for any future code that modifies xray config files

## Self-Check: PASSED

All files exist. All commit hashes verified.

---
*Phase: 01-safety-net-security*
*Completed: 2026-03-08*
