---
phase: 01-safety-net-security
plan: 03
subsystem: infra
tags: [bash, jq, sni, dpi-bypass, safe-writes, xray]

# Dependency graph
requires:
  - phase: 01-01
    provides: "safe_jq_write function, backup_config function"
  - phase: 01-02
    provides: "Non-root xray user, fix_xray_permissions, chown root:root removed"
provides:
  - "All jq operations use safe_jq_write -- zero raw jq temp file patterns remain"
  - "Cleaned SNI list without TSPU-detectable foreign domains"
  - "Updated hardcoded SNI defaults (gRPC: cloudflare.com, fallback: ozon.ru)"
  - "Fixed create_profile indentation"
affects: [02-config-migrations, 03-transport-menu]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "safe_jq_write for ALL jq config modifications -- no exceptions"
    - "SNI selection priority: ru_whitelist > yandex_cdn > foreign > fallback"

key-files:
  created: []
  modified:
    - xrayebator
    - sni_list.txt

key-decisions:
  - "gRPC default SNI changed from www.google.com to www.cloudflare.com -- google.com is TSPU primary target"
  - "General fallback SNI changed from www.microsoft.com to www.ozon.ru -- Russian e-commerce domain is more resilient"
  - "Removed 5 TSPU-detectable domains from sni_list.txt: google.com, microsoft.com, apple.com, bbc.com, yahoo.com"

patterns-established:
  - "safe_jq_write: ALL jq config modifications must use safe_jq_write -- never raw jq > temp && mv"
  - "SNI selection: prefer Russian whitelist domains, avoid known TSPU targets"

requirements-completed: [CQ-01, CQ-02, CQ-03, CQ-04]

# Metrics
duration: 4min
completed: 2026-03-08
---

# Phase 01 Plan 03: Safe jq writes + SNI cleanup Summary

**All jq operations migrated to safe_jq_write (zero raw patterns remain), TSPU-detectable SNI domains purged from list and hardcoded references**

## Performance

- **Duration:** 4 min
- **Started:** 2026-03-08T07:10:05Z
- **Completed:** 2026-03-08T07:14:32Z
- **Tasks:** 2
- **Files modified:** 2

## Accomplishments
- Migrated 6 raw jq temp file patterns to safe_jq_write across 5 functions (migrate_routing_config, migrate_xhttp_mode, migrate_xhttp_extra_restore, update_transport_settings_for_sni, install/uninstall_adguard_home)
- Removed 2 orphan `chmod 644` calls from migration loops (safe_jq_write handles permissions)
- Cleaned sni_list.txt of 5 TSPU-detectable domains (google.com, microsoft.com, apple.com, bbc.com, yahoo.com)
- Updated all hardcoded SNI references: gRPC default to cloudflare.com, fallback to ozon.ru, gRPC menu with safe alternatives
- Fixed create_profile indentation inconsistencies (custom_sni line, comment block)

## Task Commits

Each task was committed atomically:

1. **Task 1: Convert migration functions and update_transport_settings_for_sni to safe_jq_write** - `70bbb16` (fix)
2. **Task 2: Clean SNI list, update hardcoded SNI references, fix formatting** - `9a3d2fd` (fix)

## Files Created/Modified
- `xrayebator` - All jq operations via safe_jq_write, SNI defaults updated, indentation fixed
- `sni_list.txt` - Removed 5 TSPU-detectable foreign domains

## Decisions Made
- gRPC default SNI: www.google.com -> www.cloudflare.com (google.com is TSPU primary target, cloudflare.com has HTTP/2 support needed for gRPC)
- General fallback SNI: www.microsoft.com -> www.ozon.ru (Russian e-commerce domain never blocked by RKN)
- gRPC menu options: replaced google/microsoft with aws.amazon.com and cdn.cloudflare.net (less targeted by TSPU)
- Removed sni_desc entries for deleted domains, added aws.amazon.com description

## Deviations from Plan

None - plan executed exactly as written.

## Issues Encountered
None

## User Setup Required
None - no external service configuration required.

## Next Phase Readiness
- Phase 01 (Safety Net + Security) is now complete: all 3 plans executed
- safe_jq_write is the universal pattern for all jq config modifications
- SNI list is clean and ready for Phase 02 config migrations
- Ready to proceed to Phase 02 (Config Migrations)

## Self-Check: PASSED

All files exist, all commits verified.

---
*Phase: 01-safety-net-security*
*Completed: 2026-03-08*
