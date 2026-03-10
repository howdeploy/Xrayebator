# Milestones

## v1.0 Xrayebator Optimization (Shipped: 2026-03-10)

**Phases completed:** 3 phases, 6 plans, 13 tasks

**Key accomplishments:**
- Safe restart with config validation, timestamped backups, and rollback before Xray restarts.
- Security hardening: shortIds, non-root Xray, AdGuard loopback-safe DNS handling, and safer key extraction.
- Phase 2 config optimization: DoH Local DNS, `UseIPv4`, `routeOnly`, access log disablement, policy tuning, and BitTorrent blocking.
- Fresh install/update flows aligned with the optimized config baseline and canonical DNS migration target.
- Transport modernization: XHTTP first, random high ports, persisted gRPC/XHTTP metadata, and explicit Vision-on-443 risk confirmation.

---
