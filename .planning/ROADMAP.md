# Roadmap: Xrayebator Optimization

## Overview

Xrayebator needs three things: a safety net that prevents broken configs from killing VPN connections, optimized server-side config.json matching 2026 best practices, and a transport menu that reflects current TSPU realities instead of 2024 defaults. The work flows linearly -- safe restart and backups first, then config migrations that use them, then transport restructuring that depends on both.

## Phases

**Phase Numbering:**
- Integer phases (1, 2, 3): Planned milestone work
- Decimal phases (2.1, 2.2): Urgent insertions (marked with INSERTED)

Decimal phases appear between their surrounding integers in numeric order.

- [ ] **Phase 1: Safety Net + Security** - Config validation, backup mechanism, security fixes, code quality cleanup
- [ ] **Phase 2: Config Optimization** - DNS, routing, policy, and sniffing migrations for performance and stealth
- [ ] **Phase 3: Transport Modernization** - Restructure transport menu, randomize ports/paths, update TSPU guidance

## Phase Details

### Phase 1: Safety Net + Security
**Goal**: Every config change is validated before restart with automatic rollback, security vulnerabilities are closed, and all jq operations use safe_jq_write
**Depends on**: Nothing (first phase)
**Requirements**: CFG-04, CFG-08, CFG-09, SEC-01, SEC-02, SEC-03, SEC-04, SEC-05, SEC-06, CQ-01, CQ-02, CQ-03, CQ-04
**Success Criteria** (what must be TRUE):
  1. Breaking a config.json intentionally and triggering restart does NOT kill VPN -- Xray continues running on old config, user sees error message
  2. Before any migration runs, a timestamped backup of config.json exists and can be found on disk
  3. AdGuard Home installation does not expose port 53 to the public internet (verified via `ufw status`)
  4. Xray process runs as non-root user (verified via `ps aux | grep xray`) with no loss of functionality
  5. New inbounds have non-empty shortIds (verified in generated config.json)
**Plans**: 3 plans

Plans:
- [ ] 01-01-PLAN.md -- safe_restart_xray, backup_config, replace all 10 restart calls
- [ ] 01-02-PLAN.md -- Security fixes (shortIds, port 53, non-root, key grep, DNS preserve)
- [ ] 01-03-PLAN.md -- Code quality (safe_jq_write migration, SNI cleanup, formatting)

### Phase 2: Config Optimization
**Goal**: Server-side config.json delivers optimal DNS latency, correct routing, memory efficiency, and privacy -- all applied as backward-compatible migrations
**Depends on**: Phase 1
**Requirements**: CFG-01, CFG-02, CFG-03, CFG-05, CFG-06, CFG-07
**Success Criteria** (what must be TRUE):
  1. DNS queries resolve via DoH Local (https+local://) with no routing overhead -- verified by checking config.json dns section
  2. Freedom outbound uses UseIPv4 -- no IPv6 leak when connecting to dual-stack destinations
  3. All inbound sniffing has routeOnly:true -- destination addresses are never overridden
  4. BitTorrent traffic is blocked (VPS TOS compliance) -- verified in routing rules
  5. Existing installations receive all optimizations via migration functions on first menu launch after update (no manual intervention)
**Plans**: TBD

Plans:
- [ ] 02-01: DNS, Freedom, sniffing, log, policy, BitTorrent migrations
- [ ] 02-02: install.sh and update.sh alignment (new installs get optimal config, updates preserve AdGuard DNS)

### Phase 3: Transport Modernization
**Goal**: Users create profiles with transport defaults that match 2026 TSPU blocking patterns -- XHTTP first, random ports, randomized paths, honest risk warnings
**Depends on**: Phase 2
**Requirements**: TRN-01, TRN-02, TRN-03, TRN-04, TRN-05, TRN-06
**Success Criteria** (what must be TRUE):
  1. Creating a new profile shows XHTTP+Reality as the first (recommended) option in the transport menu
  2. All transports default to a random high port (30000-60000), not 443/8443/2053
  3. gRPC serviceName and XHTTP path are randomly generated strings, not hardcoded "grpc"/"xhttp"
  4. Choosing Vision on port 443 shows a warning about TSPU blocking risk and requires explicit confirmation
  5. Transport descriptions in the menu explain current TSPU status (which transports work on mobile vs wired)
**Plans**: TBD

Plans:
- [ ] 03-01: Transport menu restructuring, random port/path generation, Vision warnings

## Progress

**Execution Order:**
Phases execute in numeric order: 1 -> 2 -> 3

| Phase | Plans Complete | Status | Completed |
|-------|----------------|--------|-----------|
| 1. Safety Net + Security | 0/3 | Not started | - |
| 2. Config Optimization | 0/2 | Not started | - |
| 3. Transport Modernization | 0/1 | Not started | - |
