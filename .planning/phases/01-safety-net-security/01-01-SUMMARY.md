---
phase: 01-safety-net-security
plan: 01
subsystem: infra
tags: [bash, xray, config-validation, backup, rollback, systemctl]

# Dependency graph
requires: []
provides:
  - "safe_restart_xray() -- config validation before restart with auto-rollback"
  - "backup_config() -- timestamped config backups in /usr/local/etc/xray/backups/"
  - "All 10 bare systemctl restart xray calls replaced with safe_restart_xray"
  - "All 4 migration functions + 2 AdGuard Home functions have pre-mutation backups"
affects: [01-02, 01-03, 02-config-migrations, 03-transport-menu]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "safe_restart_xray pattern: validate with xray run -test -config before systemctl restart"
    - "backup_config pattern: timestamped cp to /usr/local/etc/xray/backups/ before any config mutation"
    - "auto-rollback pattern: restore latest backup on validation failure"

key-files:
  created: []
  modified:
    - "xrayebator"

key-decisions:
  - "No chown in safe_restart_xray rollback -- Plan 01-02 will change ownership to xray user"
  - "backup_config placed after echo header but before any jq mutation in each migration"
  - "safe_restart_xray placed between safe_jq_write and open_firewall_port in function order"

patterns-established:
  - "safe_restart_xray: always use instead of bare systemctl restart xray"
  - "backup_config before mutation: call backup_config with descriptive name before modifying config.json"

requirements-completed: [CFG-04, CFG-08, CFG-09]

# Metrics
duration: 4min
completed: 2026-03-08
---

# Phase 1 Plan 1: Safe Restart + Config Backup Summary

**safe_restart_xray() with xray run -test validation, auto-rollback from timestamped backups, all 10 restart calls wrapped**

## Performance

- **Duration:** 4 min
- **Started:** 2026-03-08T07:00:09Z
- **Completed:** 2026-03-08T07:04:30Z
- **Tasks:** 2
- **Files modified:** 1

## Accomplishments
- Created `backup_config()` function for timestamped config backups before any config mutation
- Created `safe_restart_xray()` with xray config validation and automatic rollback from latest backup on failure
- Replaced all 10 bare `systemctl restart xray` calls with `safe_restart_xray`
- Added `backup_config` calls to all 4 migration functions and both AdGuard Home install/uninstall DNS mutations

## Task Commits

Each task was committed atomically:

1. **Task 1: Create safe_restart_xray() and backup_config() functions** - `c340a03` (feat)
2. **Task 2: Replace all 10 systemctl restart xray calls and add backup_config to migrations** - `ca5641d` (feat)

## Files Created/Modified
- `xrayebator` - Added backup_config() and safe_restart_xray() functions, replaced all bare restart calls, added backup calls to migrations

## Decisions Made
- No `chown root:root` in safe_restart_xray rollback path -- Plan 01-02 (SEC-05) will change file ownership to xray user, hardcoding root:root would conflict
- backup_config placed after the echo header line but before any jq/config mutations in each migration function
- Functions placed between safe_jq_write (line 143) and open_firewall_port in the helper functions section

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] Restored accidentally deleted chown line in safe_jq_write**
- **Found during:** Task 2 (during editing)
- **Issue:** `chown root:root "$dst_file" 2>/dev/null` was accidentally removed from safe_jq_write function
- **Fix:** Restored the line immediately, amended into Task 2 commit
- **Files modified:** xrayebator (safe_jq_write function)
- **Verification:** Diff confirmed line restored, bash -n passes
- **Committed in:** ca5641d (Task 2 commit, amended)

---

**Total deviations:** 1 auto-fixed (1 bug)
**Impact on plan:** Auto-fix restored accidentally deleted code. No scope creep.

## Issues Encountered
- Task 1 and Task 2 Part A (replacements) were applied to the file before Task 2's separate commit, resulting in all 10 replacements being captured in the Task 1 commit. The end result is identical -- all changes are correctly committed.

## User Setup Required
None - no external service configuration required.

## Next Phase Readiness
- safe_restart_xray() and backup_config() are ready for use by all subsequent plans
- Plan 01-02 (SEC-05 non-root Xray) can safely modify file ownership without conflicting with these functions
- Plan 01-03 can use backup_config in any new migrations it introduces

## Self-Check: PASSED

- FOUND: 01-01-SUMMARY.md
- FOUND: c340a03 (Task 1 commit)
- FOUND: ca5641d (Task 2 commit)
- FOUND: safe_restart_xray in xrayebator
- FOUND: backup_config in xrayebator

---
*Phase: 01-safety-net-security*
*Completed: 2026-03-08*
