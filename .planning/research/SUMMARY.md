# Project Research Summary

**Project:** Xrayebator
**Domain:** Automated Xray Reality VPN manager for DPI censorship bypass in Russia
**Researched:** 2026-03-08
**Confidence:** MEDIUM-HIGH

## Executive Summary

Xrayebator is a single-file Bash VPN manager (~2500 lines) deploying Xray-core with REALITY protocol on Debian/Ubuntu VPS servers. Research across five dimensions -- stack, features, transports, architecture, and pitfalls -- reveals that the codebase works but has accumulated significant technical debt and is misaligned with the current Russian censorship landscape as of March 2026. The TSPU (state DPI system) has shifted from protocol-specific detection to heuristic-based blocking: TLS connection count policing on port 443, a 15-20KB TCP threshold on mobile networks, SNI+CIDR cross-referencing, and broad TLS 1.3 traffic analysis. This means Xrayebator's current defaults -- Vision on port 443 with google.com SNI -- represent the single worst configuration for Russian users in 2026.

The recommended approach is a two-track strategy. **Track 1 (config hardening):** Fix the server-side config.json with changes that are low-complexity, high-confidence, and non-breaking -- DNS migration to `https+local://`, Freedom outbound `domainStrategy`, sniffing `routeOnly: true`, config validation before restart, shortId generation, port 53 security fix. These are all documented in official Xray sources and can be delivered as migration functions following the existing marker-file pattern. **Track 2 (transport modernization):** Restructure the transport menu to match current TSPU realities -- promote XHTTP+Reality as the recommended default, move all transports off port 443 by default (random high ports), remove Vision-on-443 as a default option, randomize gRPC/XHTTP paths, and audit the 104-domain SNI list to remove overused domains.

Key risks are: (1) the censorship landscape changes weekly, so any "recommended" configuration has a shelf life measured in months at best -- the mitigation is multiple transport options with easy switching; (2) migration functions can corrupt config.json if jq expressions are not carefully written (the XHTTP extra settings wipe in commit f943024 is evidence) -- the mitigation is mandatory config backup before migrations and `xray run -test` validation before restart; (3) regional variation across Russian ISPs means no single configuration works everywhere -- the mitigation is offering diverse transport options and clear documentation about which transports suit wired vs mobile networks.

## Key Findings

### Recommended Stack

Xray-core v26.2.6 (2026-02-06) is the current stable release and should be the target. Critical changes include the XHTTP `auto` mode fix with REALITY, dynamic Chrome User-Agent for anti-fingerprinting, and reduced memory usage. The install script already pulls the latest release, which is correct.

**Core technologies:**
- **Xray-core v26.2.6:** VPN proxy engine -- latest stable with XHTTP+Reality bug fixes and anti-detection improvements
- **Loyalsoldier/v2ray-rules-dat:** Enhanced geo databases -- better ad domain and CN domain coverage than stock
- **DoH Local mode (`https+local://`):** DNS resolution -- bypasses Xray routing, eliminates 100-300ms latency vs current remote DoH
- **TCP BBR + fq qdisc:** Network tuning -- current sysctl configuration is solid, matches Cloudflare/ESnet best practices

**Key config changes from current state:**
1. DNS: `https://dns.adguard-dns.com/dns-query` -> `https+local://1.1.1.1/dns-query` (bypass routing, reduce latency)
2. Freedom outbound: add `domainStrategy: "UseIPv4"` (prevent IPv6 leaks, use Xray DNS)
3. Sniffing: add `routeOnly: true` to all inbounds (prevent destination override, reduce DNS load)
4. Log: add `access: "none"` (privacy, reduce I/O)
5. Routing: add BitTorrent protocol block (VPS TOS compliance)
6. Policy: add `bufferSize: 4` (reduce memory from 512KB to 4KB per connection)
7. Reality: generate non-empty shortIds (authentication hardening)

### Expected Features

**Must have (table stakes):**
- Config validation before `systemctl restart xray` -- prevent silent VPN outage
- DoH Local mode DNS -- encrypted DNS without routing overhead
- Freedom outbound `domainStrategy: UseIPv4` -- prevent IPv6 leaks
- Sniffing `routeOnly: true` -- prevent destination override issues
- Non-empty shortIds -- additional REALITY authentication layer
- Access log disabled -- privacy and performance
- XHTTP+Reality as transport option -- strongest current transport for mobile+wired

**Should have (differentiators):**
- XHTTP promoted to recommended default transport (currently option #5, should be #1)
- All transports on random high ports by default (not 443/8443/2053)
- Random gRPC serviceName and XHTTP path generation (not hardcoded `/grpc` and `/xhttp`)
- Auto shortId generation per installation
- Migration functions for all config optimizations (existing marker-file pattern)
- Config backup before any migration
- Port 53 security fix (AdGuard Home bound to localhost, no public UFW rule)
- Xray daemon running as non-root user
- SNI list audit (remove google.com, microsoft.com, yahoo.com)

**Defer (v2+):**
- Finalmask (XICMP/XDNS) -- too new, API not stable, devs warn against third-party adoption
- XHTTP CDN bypass options -- explicitly marked "not yet finalized" by Xray developers
- XDRIVE transport -- announced but not released
- Hysteria 2 integration -- different protocol, significant scope
- Russia-specific geo databases (runetfreedom) -- needs download/update infrastructure
- XHTTP downloadSettings (split upload/download) -- complex, not yet proven necessary
- CDN fallback (Cloudflare) -- requires domain purchase, complex setup
- stats/api sections -- overhead, only for traffic monitoring
- Subscription URL model -- significant scope beyond current milestone

### Architecture Approach

The optimal config.json architecture follows a clear data flow: Inbound (VLESS decode + Reality) -> Sniffing (domain extraction, routeOnly) -> Routing (rule matching top-to-bottom) -> DNS (resolution only when needed via `https+local://` DoH) -> Outbound (Freedom with UseIPv4 or Blackhole). All changes are config-level modifications implementable as migration functions. No structural code changes to the single-file Bash architecture are needed.

**Major components and their optimal state:**
1. **DNS** -- `https+local://1.1.1.1/dns-query` with localhost fallback; `127.0.0.1` when AdGuard Home is active
2. **Routing** -- `IPIfNonMatch`, rules ordered: block private IPs > block ads > block BitTorrent > block QUIC > direct catch-all
3. **Inbounds** -- per-port VLESS+Reality with `routeOnly: true` sniffing, non-empty shortIds
4. **Outbounds** -- Freedom with `domainStrategy: "UseIPv4"`, Blackhole for blocked traffic
5. **Policy** -- `bufferSize: 4` for memory optimization on small VPS
6. **Log** -- `warning` level, `access: "none"`

### Transport Assessment (TSPU-Specific)

Research uncovered that TSPU detection is NOT protocol-specific VLESS detection. It is heuristic-based: TLS 1.3 to foreign IP with sustained traffic on port 443 = suspect. This finding fundamentally changes transport recommendations.

**Transport ranking (March 2026):**

| Rank | Transport | Best Port | Wired Risk | Mobile Risk | Recommendation |
|------|-----------|-----------|------------|-------------|----------------|
| 1 | XHTTP+Reality (auto+extra) | Random 30000-60000 | VERY LOW | LOW | **New default** |
| 2 | TCP+Reality+Mux (no Vision) | Random 30000-60000 | LOW | MEDIUM | Fast alternative |
| 3 | TCP+Reality+Vision | Random 30000-60000 | LOW | HIGH (15-20KB threshold) | Wired-only |
| 4 | gRPC+Reality | Random 30000-60000 | LOW | MEDIUM | Fallback, needs H2 SNI |
| 5 | Vision on 443 | 443 | BLOCKED | BLOCKED | **REMOVE as default** |

**Key transport findings:**
- uTLS fingerprint choice (chrome/firefox/safari) has NO observable impact on TSPU detection -- all blocking is connection-pattern-based, not JA3-based
- XHTTP `auto` mode now works correctly with Reality in v26.2.2+
- Vision+Mux is technically impossible (flow is incompatible with mux)
- Random port generation per-installation reduces pattern matching across Xrayebator users

### Critical Pitfalls

1. **Google/Yahoo/Microsoft SNI = instant detection.** TSPU cross-references SNI with server IP. Google never serves from Hetzner/OVH IPs. Xrayebator currently defaults to google.com for gRPC. **Fix:** Remove from recommendations, use CDN-hosted domains matching VPS datacenter. Validate with `xray tls ping`.

2. **Vision on port 443 = connection-count policing.** Vision creates many parallel TLS connections; TSPU drops connections after ~12 simultaneous TLS sessions to one IP on port 443. Confirmed by net4people #546 with specific ISP names. **Fix:** Use mux (no Vision flow) on port 443, or move Vision to non-standard ports.

3. **No config validation before restart = silent VPN outage.** Zero instances of `xray -test` in the codebase. Any jq error + restart = all users disconnected with no diagnostic. **Fix:** Create `safe_restart_xray()` that validates first, replace all 10+ bare `systemctl restart xray` calls.

4. **Port 53 publicly exposed when AdGuard Home installed = DDoS amplification vector.** `open_firewall_port 53` opens DNS to the entire internet. Xray only needs localhost access. **Fix:** Remove public UFW rules for port 53, bind AdGuard to 127.0.0.1.

5. **uTLS Chrome fingerprint had CVE-grade passive detection bug (Dec 2023 -- Oct 2025).** ECH GREASE mismatch allowed ~100% detection of uTLS connections. Fixed in post-October 2025 Xray releases. **Fix:** Ensure installer pulls latest Xray, add version check.

6. **15-20KB TCP threshold on mobile networks.** TSPU freezes any TCP connection to foreign IPs exceeding ~15-20KB on mobile operators (MTS, Megafon, Beeline, Tele2, Yota). Expanding to wired ISPs. **Fix:** XHTTP transport with xmux, mux on TCP, whitelisted SNI domains.

## Implications for Roadmap

Based on combined research, three phases ordered by dependency and impact.

### Phase 1: Security Hardening and Config Validation

**Rationale:** This phase is the foundation. Config validation prevents all subsequent changes from causing silent outages. Security fixes (port 53, root daemon, shortIds) close active vulnerabilities. SNI audit prevents the most common detection vector. Every subsequent phase depends on having safe restart and backup mechanisms.

**Delivers:** Safe restart function, config backup mechanism, security fixes, SNI audit
**Addresses features:** Config validation, shortId generation, access log disabled, port 53 fix, Xray as non-root user
**Avoids pitfalls:** #1 (Google SNI), #5 (empty shortIds), #6 (no validation), #7 (port 53), #10 (root Xray), #12 (migration data loss)

**Scope:**
- `safe_restart_xray()` function with `xray run -test -config` validation
- Config backup before any migration (`config.json.bak.<timestamp>`)
- Replace all ~10 bare `systemctl restart xray` calls
- Generate random hex shortIds for new inbounds, migration for existing
- Add `access: "none"` to log section
- Remove public UFW rules for port 53, bind AdGuard DNS to localhost
- Configure systemd to run Xray as non-root user with `CAP_NET_BIND_SERVICE`
- Audit SNI list: remove google.com, yahoo.com, microsoft.com and similar overused domains
- Add `www.google.com (recommended)` removal from menu suggestions

### Phase 2: Config Optimization and Transport Modernization

**Rationale:** With safe restart in place, apply all config.json optimizations that improve performance, reliability, and stealth. Simultaneously restructure the transport menu to match 2026 TSPU realities. These are logically coupled -- DNS optimization improves all transports, and transport restructuring requires the safety net from Phase 1.

**Delivers:** Optimized config.json, restructured transport menu, random port generation
**Addresses features:** DNS fix, Freedom domainStrategy, routeOnly, BitTorrent block, policy section, XHTTP as default, random ports, randomized paths
**Avoids pitfalls:** #2 (Vision on 443), #3 (15-20KB threshold), #8 (predictable paths), #9 (SNI-CIDR mismatch), #11 (DNS leaks)

**Scope:**
- Migration function for DNS: `https+local://1.1.1.1/dns-query` (with AdGuard Home detection)
- Migration function for Freedom outbound: `domainStrategy: "UseIPv4"`
- Migration function for sniffing: `routeOnly: true` on all inbounds
- Migration function for routing: add BitTorrent block rule
- Migration function for policy: add `bufferSize: 4`
- Restructure transport menu: XHTTP #1, TCP+Mux #2, Vision #3 (wired-only warning), gRPC #4
- Remove Vision-on-443 as default; remove XUDP-on-443
- Random port generation (30000-60000) as default for all transports
- Random gRPC serviceName and XHTTP path generation
- Update `install.sh` with optimal config template for new installs
- Update AdGuard Home uninstall to restore to `https+local://` format

### Phase 3: UX and Resilience

**Rationale:** With the config optimized and transports modernized, focus on user-facing improvements that help users navigate the fragmented Russian censorship landscape. These are nice-to-have features that improve the product but are not critical fixes.

**Delivers:** Better UX for multi-transport scenarios, connection testing, documentation
**Addresses features:** QUIC blocking toggle, multi-profile support, connection testing
**Avoids pitfalls:** #13 (QUIC kills HTTP/3), #14 (regional variation), #15 (insecure profile sharing)

**Scope:**
- Make QUIC blocking configurable per-profile
- SNI validation via `xray tls ping` at SNI selection time
- Xray version check and upgrade prompt
- Connection test functionality (verify profile works)
- Rapid SNI switching without re-creating profiles
- User documentation: which transport for wired vs mobile, regional considerations
- Explore subscription URL model for revocable profile access

### Phase Ordering Rationale

- **Phase 1 before Phase 2:** Config validation and backup are prerequisites for safely applying migration functions. Every migration in Phase 2 depends on safe_restart_xray() and config backup from Phase 1.
- **Phase 2 before Phase 3:** Config optimizations and transport restructuring are the core deliverables of this milestone. Phase 3 is enhancement.
- **DNS + Freedom + routeOnly grouped together (Phase 2):** These three settings interact -- routeOnly affects whether Freedom outbound resolves domains, Freedom's domainStrategy determines which DNS is used for resolution. They should be migrated and tested together.
- **Transport restructuring in Phase 2, not Phase 1:** Changing the menu requires the random port generation infrastructure, path randomization, and SNI audit from Phase 1 to already be available.
- **install.sh update at the end of Phase 2:** New install template should include all Phase 1 + Phase 2 changes.

### Research Flags

Phases likely needing deeper research during planning:
- **Phase 2 (Transport menu):** The transport-to-port-to-SNI interaction is complex. Need to validate that random ports + XHTTP auto mode + Reality work correctly together. Test on real TSPU-affected ISPs.
- **Phase 2 (SNI audit):** The 104-domain SNI list needs empirical validation. Which domains are still safe? Need community whitelist integration research (hxehex/russia-mobile-internet-whitelist).
- **Phase 3 (SNI validation):** The `xray tls ping` approach for SNI health-checking needs prototyping -- unclear how to handle timeouts and partial failures in a user-friendly way.

Phases with standard patterns (skip research-phase):
- **Phase 1 (Config validation):** Well-documented. `xray run -test -config` is a standard one-liner. Straightforward implementation.
- **Phase 1 (Security fixes):** Port 53 fix, shortId generation, non-root daemon -- all have clear documentation and one correct answer.
- **Phase 2 (Config migrations):** DNS, Freedom, routeOnly, policy -- all follow the existing migration pattern with marker files. Official Xray docs provide exact config values.

## Confidence Assessment

| Area | Confidence | Notes |
|------|------------|-------|
| Stack (Xray-core version, DNS, Freedom) | HIGH | Verified via GitHub API, official docs explicitly recommend all changes |
| Config architecture (routing, sniffing, policy) | HIGH | Official examples use routeOnly:true, docs define all policy values |
| Security pitfalls (port 53, root, shortIds, SNI) | HIGH | Verified in codebase, confirmed by official docs and CVE records |
| Transport detection patterns (TSPU) | MEDIUM-HIGH | Multiple independent sources agree (net4people, Habr, Reddit, ntc.party), but regional variation makes universal statements impossible |
| Transport recommendations (XHTTP vs Vision) | MEDIUM | Community consensus backed by logical analysis, but not controlled testing. Censorship evolves weekly. |
| XHTTP extra settings (padding, xmux) | MEDIUM | Anti-detection is an active arms race. Current values are adequate but may need future adjustment |
| SNI domain recommendations | MEDIUM | Depends on region, ISP, time. Community whitelists are best available data but change frequently |
| Future features (Finalmask, XDRIVE) | LOW | Announced but not stable/released. Do not build on these yet. |

**Overall confidence:** MEDIUM-HIGH

### Gaps to Address

- **TSPU detection evolution:** Blocking patterns change weekly. February 2026 saw new AI-based traffic classification experiments. Specific detection methods need continuous monitoring, not one-time research.
- **SNI domain validity by region:** No authoritative source for which SNI domains work in which Russian regions on which ISPs. The hxehex/russia-mobile-internet-whitelist repo is the best approximation but is community-maintained with varying coverage.
- **Random port effectiveness:** Logic says random ports reduce pattern matching, but no empirical data on whether TSPU has adapted to scan non-standard ports for VLESS-like patterns.
- **XHTTP `auto` mode reliability:** Fixed in v26.2.2, but limited field reports on how well `auto` performs across diverse network conditions vs explicit mode selection.
- **bufferSize impact on throughput:** Official docs note "smaller buffer may increase CPU." No empirical data on the throughput impact of `bufferSize: 4` vs `bufferSize: 64` on typical VPN workloads.
- **Xray as non-root user:** May require adjusting file permissions across config.json, keys, and profiles. Needs testing to confirm all Xrayebator operations still work when Xray daemon runs as `nobody`.

## Sources

### Primary (HIGH confidence)
- Xray-core v26.2.6 release notes: https://github.com/XTLS/Xray-core/releases/tag/v26.2.6
- Official DNS docs: https://xtls.github.io/en/config/dns.html
- Official Freedom outbound docs: https://xtls.github.io/en/config/outbounds/freedom.html
- Official Routing docs: https://xtls.github.io/en/config/routing.html
- Official Inbound docs (sniffing/routeOnly): https://xtls.github.io/en/config/inbound.html
- Official Policy docs: https://xtls.github.io/en/config/policy.html
- Official server guide (ch07): https://xtls.github.io/en/document/level-0/ch07-xray-server.html
- XTLS/Xray-examples repo (routeOnly usage): https://github.com/XTLS/Xray-examples
- REALITY setup discussion #1702: https://github.com/XTLS/Xray-core/discussions/1702
- uTLS CVE advisory GHSA-7m29-f4hw-g2vx: https://github.com/refraction-networking/utls/security/advisories/GHSA-7m29-f4hw-g2vx
- net4people/bbs#546 (TLS connection policing): https://github.com/net4people/bbs/issues/546
- net4people/bbs#490 (TCP threshold, SNI+CIDR): https://github.com/net4people/bbs/issues/490

### Secondary (MEDIUM confidence)
- Habr "Clumsy Hands or New DPI" (Nov 2025): https://habr.com/en/articles/990236/
- digirpt.com "VLESS blocked in Russia 2026": https://digirpt.com/2026/02/17/vless-zablokirovali-rossiya-chto-delat/
- ntc.party "Which bypass method for 2026": https://ntc.party/t/22139
- Reddit r/VPN "VLESS/Reality mobile issues": https://www.reddit.com/r/VPN/comments/1ogn5cs/
- Reddit r/dumbclub "Best VLESS+XHTTP+Reality setup": https://www.reddit.com/r/dumbclub/comments/1qvlbhm/
- hxehex/russia-mobile-internet-whitelist: https://github.com/hxehex/russia-mobile-internet-whitelist
- hyperion-cs/dpi-checkers: https://github.com/hyperion-cs/dpi-checkers
- runetfreedom/russia-v2ray-rules-dat: https://github.com/runetfreedom/russia-v2ray-rules-dat

### Tertiary (LOW confidence)
- XDRIVE announcement (Telegram only): https://t.me/projectXtls/1464
- EmptyLibra SNI banning discussion: https://github.com/EmptyLibra/Configure-Xray-with-VLESS-Reality-on-VPS-server/discussions/8
- CNews on statistical analysis: https://www.cnews.ru/news/top/2025-05-05_vlasti_rossii_nauchilis

---
*Research completed: 2026-03-08*
*Ready for roadmap: yes*
