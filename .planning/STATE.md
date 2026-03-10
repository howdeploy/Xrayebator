# Project State

## Project Reference

See: .planning/PROJECT.md (updated 2026-03-08)

**Core value:** VPN stably and fast works through TSPU -- connection does not drop, blocks are bypassed reliably
**Current focus:** Phase 3: Transport Modernization

## Current Position

Phase: 3 of 3 (Transport Modernization) -- READY TO EXECUTE
Plan: 1 of 1 in current phase -- PLANNED
Status: Phase 3 planned and verified
Last activity: 2026-03-10 -- Created and verified 03-01-PLAN.md

Progress: [███████░░░] 67%

## Performance Metrics

**Velocity:**
- Total plans completed: 5
- Average duration: 7min
- Total execution time: 0.58 hours

**By Phase:**

| Phase | Plans | Total | Avg/Plan |
|-------|-------|-------|----------|
| 01-safety-net-security | 3/3 | 14min | 5min |
| 02-config-optimization | 2/2 | 21min | 11min |

**Recent Trend:**
- Last 5 plans: 02-01 (12min), 02-02 (9min), 01-03 (4min), 01-02 (6min), 01-01 (4min)
- Trend: stable

*Updated after each plan completion*

## Accumulated Context

### Decisions

Decisions are logged in PROJECT.md Key Decisions table.
Recent decisions affecting current work:

- [Roadmap]: 3-phase structure -- safety net first, then config migrations, then transport menu
- [Roadmap]: CFG-08/CFG-09 (migration framework, backups) belong in Phase 1 as infrastructure for Phase 2 migrations
- [01-01]: No chown in safe_restart_xray rollback -- Plan 01-02 will change ownership to xray user
- [01-01]: safe_restart_xray validates config with xray run -test before restart, auto-rollback from latest backup on failure
- [01-02]: Systemd drop-in for non-root xray (User=xray, CAP_NET_BIND_SERVICE) instead of modifying xray.service directly
- [01-02]: fix_xray_permissions() called at 4 strategic points after config modifications
- [01-02]: Port 53 never needs UFW rule -- loopback traffic bypasses firewall
- [01-03]: gRPC default SNI changed from google.com to cloudflare.com (TSPU primary target)
- [01-03]: General fallback SNI changed from microsoft.com to ozon.ru (Russian e-commerce, never blocked)
- [01-03]: All jq operations now use safe_jq_write -- zero raw jq temp file patterns remain
- [02-01]: DNS migration preserves 127.0.0.1 so AdGuard Home is never overwritten by DoH Local migration
- [02-01]: Freedom outbound uses jq path assignment for UseIPv4 to preserve existing settings like fragment
- [02-02]: Fresh installs now write the fully optimized Phase 2 config template and create .config_optimized immediately
- [02-02]: update.sh treats https+local:// as canonical DNS while preserving 127.0.0.1 and legacy AdGuard DoH compatibility
- [03-Plan]: Phase 3 remains a single executable plan because all required transport work stays inside xrayebator
- [03-Plan]: Randomized XHTTP path and gRPC serviceName require additive profile metadata so QR/link export stays correct

### Pending Todos

None yet.

### Blockers/Concerns

- SEC-05 (non-root Xray): RESOLVED -- xray user created, systemd drop-in configured, fix_xray_permissions() in place
- Research gap: SNI domain validity varies by region/ISP. CQ-03 SNI cleanup uses best available community data. RESOLVED in 01-03.

## Session Continuity

Last session: 2026-03-10
Stopped at: Phase 3 planned and verified; next step is execute 03-01 for Transport Modernization
Resume file: None
