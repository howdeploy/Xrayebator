---
phase: 02-config-optimization
plan: 02
subsystem: infra
tags: [bash, xray, dns, doh-local, install, update]
requires:
  - phase: 01-safety-net-security
    provides: safe config mutation patterns and update-time migration safeguards
provides:
  - Fresh installs start with the full Phase 2 optimized config template
  - update.sh preserves DoH Local DNS and migrates legacy DNS formats to https+local://
  - Fresh installs skip redundant first-launch config optimization via marker file
affects: [phase-02-config-migrations, install-lifecycle, update-lifecycle]
tech-stack:
  added: []
  patterns: [install-time optimized config template, backward-compatible DNS migration detection]
key-files:
  created: [.planning/phases/02-config-optimization/02-02-SUMMARY.md]
  modified: [install.sh, update.sh]
key-decisions:
  - "Fresh install config now writes the full optimized Phase 2 baseline instead of relying on first-launch migration."
  - "update.sh keeps legacy AdGuard DoH detection for backward compatibility but migrates non-compliant DNS states to DoH Local."
patterns-established:
  - "Fresh-install templates must match the latest migration target to avoid post-install drift."
  - "Lifecycle scripts accept current and legacy DNS states before deciding to migrate."
requirements-completed: [CFG-01, CFG-02, CFG-03, CFG-05, CFG-06, CFG-07]
duration: 9min
completed: 2026-03-10
---

# Phase 2 Plan 02: install.sh and update.sh alignment Summary

**Fresh installs now ship the full Phase 2 optimized Xray config, and update.sh preserves or migrates DNS into the shared DoH Local format.**

## Performance

- **Duration:** 9 min
- **Started:** 2026-03-10T14:35:00Z
- **Completed:** 2026-03-10T14:43:42Z
- **Tasks:** 2
- **Files modified:** 2

## Accomplishments

- Replaced the `install.sh` base config template with the full optimized Phase 2 baseline: DoH Local DNS, access log disabled, BitTorrent blocking, `UseIPv4` on freedom, and `policy.levels.0.bufferSize = 4`.
- Added `.config_optimized` marker creation during install so fresh deployments do not re-run the same optimization migration on first launch.
- Updated `update.sh` DNS migration to recognize `https+local://` as already valid, preserve `127.0.0.1` for AdGuard Home, and migrate remaining legacy DNS formats to DoH Local.

## Task Commits

Each task was committed atomically:

1. **Task 1: Update install.sh base config template with optimal defaults** - `75275b9` (feat)
2. **Task 2: Update update.sh DNS migration to recognize https+local:// and migrate to new format** - `cc2a32d` (fix)

## Files Created/Modified

- `.planning/phases/02-config-optimization/02-02-SUMMARY.md` - Execution summary for this plan
- `install.sh` - New-install config template aligned with all Phase 2 config optimizations
- `update.sh` - DNS migration logic aligned with the DoH Local target and backward-compatible detection

## Decisions Made

- Fresh installs are treated as already optimized by writing `/usr/local/etc/xray/.config_optimized` during installation, avoiding unnecessary first-launch migration work.
- `update.sh` still treats legacy `dns.adguard-dns.com` configs as already migrated for backward compatibility, but new migration writes only the DoH Local format.

## Deviations from Plan

None - plan executed exactly as written.

## Issues Encountered

None

## User Setup Required

None - no external service configuration required.

## Next Phase Readiness

- `install.sh` and `update.sh` now agree with the Phase 2 DNS target and fresh-install baseline.
- Phase 2 still depends on completing `02-01-PLAN.md` to apply the same optimizations to existing installations and runtime migrations.

## Self-Check: PASSED

- Found `.planning/phases/02-config-optimization/02-02-SUMMARY.md`
- Found commit `75275b9`
- Found commit `cc2a32d`

---
*Phase: 02-config-optimization*
*Completed: 2026-03-10*
