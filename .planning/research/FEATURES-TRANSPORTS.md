# Feature Landscape: Xray Reality Transport Configurations vs TSPU (March 2026)

**Domain:** VPN/proxy bypass of Russian TSPU deep packet inspection
**Researched:** 2026-03-08
**Overall confidence:** MEDIUM (rapidly evolving censorship landscape; findings based on community reports, not controlled testing)

---

## Context: How TSPU Detects Xray in March 2026

Before assessing individual transports, understanding the current TSPU detection arsenal is critical. Research reveals **multiple independent blocking mechanisms** operating simultaneously, varying by ISP, region, and network type (mobile vs wired).

### Detection Methods Observed (Nov 2025 -- Mar 2026)

| Method | Confirmed By | Affects | Severity |
|--------|-------------|---------|----------|
| **TLS connection count heuristic** | net4people #546, Habr analysis | Vision on port 443 creates many TLS connections; TSPU drops after ~12 simultaneous connections | CRITICAL |
| **15-20KB TCP threshold** | net4people #490, hyperion-cs testing | Any TCP connection transferring >15-20KB to foreign IP gets dropped. Mostly mobile ISPs (MTS, Megafon, Beeline, Tele2, Yota) but expanding to wired | HIGH |
| **Port 443 targeting** | Habr Nov 2025, pvsm.ru analysis | VLESS+Reality on 443 -- instant drop or throttle to zero. Same config on high random port (47000+) works | HIGH |
| **SNI scrutiny** | EmptyLibra discussions, ntc.party | Popular SNI domains (google.com, microsoft.com, etc.) being specifically tracked; some ISPs ban tried SNIs per-server-IP | MEDIUM |
| **IP range blocking** | Multiple reports, OVH/Hetzner targeted | Entire DC IP ranges (OVH, Hetzner) blocked on mobile operators | HIGH |
| **TLS 1.3 heuristic** | Habr "Clumsy Hands" article | TSPU sees TLS 1.3 + sustained packet flow -> DROP; so aggressive it also blocks legitimate Russian HTTPS | HIGH |
| **UDP complete block** | net4people #490 | On mobile: any UDP to foreign IP triggers ~10 min full block to that server | HIGH (mobile) |
| **SSH throttling** | Saiv46 report, Irkutsk Oblast | SSH throttled to <=2KB/s after ~10-20KB on mobile networks | MEDIUM |

**Key insight:** The blocking is NOT protocol-specific detection of VLESS. It is heuristic-based: "TLS 1.3 to foreign IP with sustained traffic on port 443 = proxy." This is why the blocks also hit legitimate HTTPS traffic (confirmed by Habr analysis testing real NGINX servers on Selectel).

**Confidence:** MEDIUM-HIGH. Multiple independent sources agree on mechanisms. Regional variation makes universal statements impossible.

---

## Table Stakes

Features that MUST work for Xrayebator to remain viable in the current Russian censorship environment. Missing any of these means the tool is broken for significant user segments.

| Feature | Why Expected | Complexity | Detection Status | Notes |
|---------|-------------|------------|-----------------|-------|
| **VLESS + TCP + Reality + Mux (no Vision)** | Primary bypass method. Mux multiplexes streams into one TLS connection, avoiding both connection-count heuristic and 15-20KB threshold | Low (already implemented in Xrayebator) | **WORKS** -- confirmed by net4people #546: "flow should be removed, mux should be applied" | Currently transport option #1 in Xrayebator. Correct default. Keep as recommended. |
| **Non-standard port support** | Port 443 is specifically targeted by TSPU heuristics. Moving to random high ports (8443, 2053, or truly random 30000-60000) immediately fixes many blocks | Low | **Port change alone fixes most blocks** -- confirmed by Habr "moving to random high port (47000+) works" | Xrayebator already uses 8443/2053/9443 for some transports, but should offer random port generation |
| **VLESS + XHTTP + Reality** | XHTTP (SplitHTTP) is the recommended transport for 2025-2026. Uses HTTP POST for upload, GET/SSE for download. Built-in xmux. Mode `auto` selects best approach. | Med | **WORKS** -- confirmed working on mobile (Megafon) per Reddit r/VPN report, recommended by ntc.party, 4pda, digirpt.com | Currently transport option #5 in Xrayebator. Should be promoted to recommended. XHTTP+Reality on non-443 port is the strongest current config. |
| **Multiple transport fallback** | When one transport gets blocked, users need alternatives without re-deploying | Med | N/A (meta-feature) | Habr article explicitly states: "in 2024-2025, connection 'survivability' is more important than server cost. User with protocol selection simply clicked a button, switched transport, continued" |
| **SNI domain validation** | Popular foreign SNIs (google.com, microsoft.com, cloudflare.com) are increasingly tracked. SNI must match server IP's geographic/hosting context | Med | Some ISPs ban specific SNI+IP combinations. "google.com googletagmanager etc. are already gone" per EmptyLibra discussion | Need SNI health-check or rotation. Current 104-domain list needs audit. |

**Confidence:** HIGH for mux+non-443 and XHTTP recommendations. Multiple independent sources confirm.

---

## Differentiators

Features that set Xrayebator apart from basic setup scripts. Not every user needs them, but they solve specific pain points.

| Feature | Value Proposition | Complexity | Detection Status | Notes |
|---------|-------------------|------------|-----------------|-------|
| **XHTTP extra settings (xmux, padding, scMaxEachPostBytes)** | Fine-tuned XHTTP with custom padding ranges (not default 100-1000), xmux concurrency, and post-size limits reduces statistical fingerprinting | Med | **Improves resistance** -- default padding is detectable as anomalous per research report | `extra` block with `xmux.maxConcurrency: "16-32"`, `scMaxEachPostBytes: "1000000-2000000"`, `noSSEHeader: true` |
| **XHTTP downloadSettings (split upload/download)** | Separates upload and download streams onto different ports, defeating traffic correlation analysis | High | **Theoretical improvement**, not widely tested in RU context | Server needs two XHTTP inbounds. Complex but powerful against ML-based analysis. |
| **VLESS + TCP + Reality + Vision on non-443 ports** | Vision provides better performance than mux (direct splice). Works when NOT on port 443 and NOT on heavily restricted mobile networks | Low | **WORKS on wired ISPs, non-443 ports** -- confirmed. FAILS on mobile with 15-20KB threshold | Keep as option but NOT as default. Explicitly warn about mobile network issues. |
| **VLESS + TCP + Reality + Vision + uTLS (Firefox fp)** | Firefox fingerprint may differ from Chrome in DPI matching. Provides diversity. | Low | **No evidence fingerprint choice matters for TSPU** -- TSPU detection is connection-pattern-based, not JA3-based per all observed evidence | Keep for completeness, but fingerprint is not the differentiator people think it is |
| **CDN fallback (VLESS + WS + TLS + Cloudflare)** | When server IP is blocked, CDN route still works. IP hidden behind Cloudflare. | High (needs domain) | **WORKS** -- confirmed by multiple sources. TSPU sometimes throttles CF ranges but cannot fully block | Emergency fallback only. Not for heavy traffic. Cloudflare ToS tolerate light personal use. |
| **XTLS Vision testpre (pre-connect) and testseed** | New in Xray v25.12.8: experimental pre-connection to eliminate latency, user-customizable padding parameters | Med | **Experimental** -- marked as test features by RPRX. May improve stealth by customizing padding distribution | Monitor, do not make default yet |
| **Random port generation** | Instead of fixed alternative ports, generate random port in 30000-60000 range. Each Xrayebator install gets unique port. | Low | **Reduces pattern matching** -- if every Xrayebator user uses port 8443, that becomes a signal | Simple but effective differentiation |
| **VLESS + gRPC + Reality** | gRPC uses HTTP/2 framing, different traffic pattern from TCP. Provides diversity. | Low (already implemented) | **Still works as of Feb 2026** -- digirpt.com confirms gRPC viable. But requires H2-capable SNI (foreign domains only) | Keep but lower priority. SNI requirement (must support H2, e.g. google.com) conflicts with SNI tracking. |
| **XHTTP H3 (HTTP/3 over QUIC)** | XHTTP over QUIC for CDN scenarios. Added in Xray-core in late 2024. | High | **UDP-based = broken on most mobile ISPs**. May work on wired ISPs where UDP is not throttled | Niche use case. Do not prioritize. |

**Confidence:** MEDIUM. XHTTP and CDN recommendations are well-supported. Vision+non-443 needs more regional testing data.

---

## Anti-Features

Features to explicitly NOT build, or configurations to actively discourage.

| Anti-Feature | Why Avoid | What to Do Instead |
|--------------|-----------|-------------------|
| **Vision on port 443 as default** | CRITICAL: TSPU specifically targets TLS 1.3 + sustained connections on 443. Vision creates multiple TLS connections. Instant drop in many regions. Confirmed by net4people #546, Habr analysis, pvsm.ru. | Use mux on 443 (no Vision flow), or Vision on non-standard ports only |
| **Popular foreign SNI domains (google.com, microsoft.com, cloudflare.com)** | These SNIs are being actively tracked. "google.com googletagmanager etc. are already gone" per community reports. TSPU correlates SNI with server IP -- if your VPS IP has nothing to do with Google, it is suspicious. | Use less-popular but valid TLS 1.3 + H2 sites. Preferably CDN-hosted domains where many IPs serve the same domain. Rotate periodically. |
| **Fixed well-known ports across all installations** | If every Xrayebator user runs on 8443, 2053, 9443 -- TSPU can create heuristic rules for these ports specifically | Offer random port generation, use well-known ports only as suggestions |
| **gRPC with Russian SNI domains** | gRPC requires H2-capable SNI. Russian domains (.ru) rarely serve on H2 properly for Reality dest probing. Also, using RU SNI on a foreign server IP is geographically inconsistent. | gRPC must use foreign H2-capable SNI (e.g. dl.google.com, www.apple.com) |
| **Vision + Mux simultaneously** | Technically impossible: mux is incompatible with `flow: "xtls-rprx-vision"`. Enabling both breaks the connection. | Choose one: mux (no flow) OR Vision (flow: "xtls-rprx-vision"). Never combine. |
| **XUDP as anti-Tele2 standalone solution** | The Tele2 problem is the 15-20KB TCP threshold, which XUDP does not solve. XUDP is for UDP proxy support (gaming, VoIP). It does not help with DPI bypass. | Use mux or XHTTP for Tele2/mobile bypass. Keep XUDP only for UDP functionality if needed. |
| **Hysteria 2 / QUIC-based transports on mobile networks** | UDP is either completely blocked or triggers 10-minute IP bans on all major Russian mobile operators | If offered at all, mark clearly as "wired ISP only" and test UDP connectivity first |
| **SSH tunnel as primary bypass** | While SSH currently passes the 15-20KB threshold on some ISPs, it has a clear fingerprint, low throughput, and promoting it publicly will lead to blocking | Not relevant for Xrayebator (different protocol stack), but do not recommend it |

**Confidence:** HIGH for Vision-on-443 and popular-SNI avoidance. These are the most consistently confirmed findings across all sources.

---

## New Developments to Track (Xray-core v25.12 -- v26.2)

Features that appeared in recent Xray-core releases that may be relevant.

### Finalmask (v26.2.2+)
A new "final masking layer" added to Xray-core. Provides packet-level disguise for UDP protocols.

| Sub-feature | What It Does | Relevance to Xrayebator |
|-------------|-------------|------------------------|
| **XICMP** | Tunnels data inside ICMP packets (relies on mKCP/QUIC) | LOW -- experimental, niche. ICMP is easily blockable. |
| **XDNS** | Tunnels data via DNS queries (like DNSTT, relies on mKCP) | LOW -- slow, emergency-only. Interesting for whitelist scenarios. |
| **header-\***, **mkcp-\*** | Fake protocol headers (game protocols, video calls, etc.) | MEDIUM -- could help on mobile ISPs that block "all encrypted protocols" but allow gaming traffic |
| **Salamander** | WireGuard obfuscation layer | LOW -- UDP-based, blocked on mobile |

### XDRIVE (announced, not yet released)
RPRX announced (Telegram @projectXtls/1464, Feb 2026): transport layer using cloud storage (S3, network drives) as relay. Does not require public IP. Could use whitelisted IPs (cloud storage services). Expected "next month" from Feb 2026 announcement.

**Relevance:** HIGH if it materializes. Could solve whitelist CIDR blocking by routing through whitelisted cloud storage IPs. Monitor but do not build until released.

### XHTTP `auto` mode fix with Reality (v26.2.2)
Bug fix in v26.2.2: XHTTP `auto` mode now works correctly with Reality security. Previous versions required explicit mode selection.

**Relevance:** HIGH. Xrayebator should use `auto` mode for XHTTP, which now properly selects between packet-up, stream-up, and stream-one based on conditions.

### Vision testpre and testseed (v25.12.8)
Experimental pre-connection feature and user-customizable padding seed for Vision. Aims to reduce latency and improve stealth.

**Relevance:** MEDIUM. Experimental. Monitor for stabilization.

### TLS allowInsecure removal (v26.2.6)
`allowInsecure` TLS setting scheduled for auto-disable on UTC 2026-06-01. Replaced by `pinnedPeerCertSha256` and `verifyPeerCertByName`.

**Relevance:** LOW for Xrayebator (uses Reality, not TLS with certificates). But important for CDN fallback configurations.

---

## Feature Dependencies

```
Mux transport -> requires flow: "" (no Vision)
Vision transport -> requires flow: "xtls-rprx-vision" (no Mux)
gRPC transport -> requires H2-capable SNI domain
XHTTP transport -> requires Xray-core >= 24.9.x (already satisfied)
XHTTP auto mode + Reality -> requires Xray-core >= 26.2.2
XHTTP downloadSettings -> requires second inbound on different port
CDN fallback -> requires purchased domain + Cloudflare account
Finalmask features -> requires Xray-core >= 26.2.2
XDRIVE -> NOT YET RELEASED (announced for Mar/Apr 2026)
Random port generation -> no dependencies
SNI rotation -> requires SNI health-check mechanism
```

---

## Transport Assessment Matrix

| # | Transport | Port | Detection (Wired) | Detection (Mobile) | Speed | Recommendation |
|---|-----------|------|-------------------|-------------------|-------|---------------|
| 1 | **TCP+Reality+Mux** | non-443 | LOW risk | MEDIUM risk (15-20KB threshold still applies per-connection but mux aggregates) | Good | **PRIMARY -- recommended default** |
| 2 | **TCP+Reality+Mux** | 443 | MEDIUM risk (443 is targeted) | HIGH risk | Good | Viable but non-443 preferred |
| 3 | **XHTTP+Reality (auto)** | non-443 | LOW risk | LOW-MEDIUM risk (HTTP POST/GET pattern, built-in xmux) | Good | **CO-PRIMARY -- best for mobile** |
| 4 | **XHTTP+Reality (auto) + extra** | non-443 | VERY LOW risk | LOW risk | Good (higher CPU) | **Best stealth option** |
| 5 | **TCP+Reality+Vision** | non-443 | LOW risk | HIGH risk (15-20KB threshold) | Excellent (splice) | **Wired-only, advanced users** |
| 6 | **TCP+Reality+Vision** | 443 | **BLOCKED** | **BLOCKED** | N/A | **REMOVE as default** |
| 7 | **TCP+Reality+Vision+uTLS** | non-443 | LOW risk | HIGH risk (same as Vision) | Excellent | Same as #5, fingerprint irrelevant |
| 8 | **gRPC+Reality** | non-443 | LOW risk | MEDIUM risk | Good | **Keep as fallback** |
| 9 | **TCP+Reality+Vision+XUDP** | 443 | **BLOCKED** | **BLOCKED** | N/A | **REMOVE or move off 443** |

---

## Xrayebator Current vs Recommended Transport Menu

### Current Menu (v1.3.2 EXP)

| # | Transport | Port | Status |
|---|-----------|------|--------|
| 1 | TCP + Reality + Mux | 443 | WORKS but 443 is risky. Move to random port. |
| 2 | TCP + Reality + Vision | 8443 | WORKS on wired. Broken on mobile (15-20KB threshold). |
| 3 | TCP + Reality + Vision + uTLS (Firefox fp) | 8443 | Same as #2. Fingerprint does not help. |
| 4 | gRPC + Reality | 2053 | WORKS. Keep as fallback. |
| 5 | XHTTP + Reality | 9443 | WORKS well. Should be promoted. |
| 6 | TCP + Reality + Vision + XUDP | 443 | **BLOCKED** on 443. XUDP does not help with DPI. |

### Recommended Menu (next version)

| # | Transport | Default Port | Notes |
|---|-----------|-------------|-------|
| 1 | **XHTTP + Reality (auto + extra)** | Random (30000-60000) | NEW recommended default. Best for mobile and wired. |
| 2 | **TCP + Reality + Mux** | Random (30000-60000) | Fast alternative. No Vision flow. |
| 3 | **TCP + Reality + Vision** | Random (30000-60000) | Wired ISPs only. Warn about mobile. |
| 4 | **gRPC + Reality** | Random (30000-60000) | Fallback. Requires H2 SNI. |
| 5 | **XHTTP + Reality + downloadSettings** | Two random ports | Advanced. Split upload/download. |

**Removed:**
- ~~TCP + Reality + Vision + uTLS~~ -- merged into Vision option with fingerprint selector
- ~~TCP + Reality + Vision + XUDP on 443~~ -- XUDP is not a bypass feature; 443 is blocked
- ~~Any default assignment to port 443~~ -- all ports should be random or user-chosen

---

## SNI Strategy Recommendations

### Current State (March 2026)
TSPU is actively tracking SNI domains used with Reality. The strategy has shifted from "pick any popular TLS 1.3 site" to something more nuanced.

### What Works
| SNI Category | Examples | Why | Risk |
|-------------|---------|-----|------|
| **CDN-hosted services** | Domains behind Cloudflare, Fastly, Akamai | Many IPs serve same domain, so IP-SNI mismatch is normal | LOW |
| **Large SaaS with distributed infra** | Various cloud service subdomains | Geographically distributed, many edge IPs | LOW |
| **Less popular but valid sites** | Niche but legitimate TLS 1.3 + H2 sites | Not on TSPU radar yet | LOW (but may change) |

### What Does NOT Work
| SNI Category | Examples | Why |
|-------------|---------|-----|
| **Overused popular domains** | google.com, microsoft.com, googletagmanager.com | Specifically tracked by TSPU. "Already goodbye" per community |
| **Russian domains on foreign servers** | .ru domains as SNI for EU/US VPS | Geographic mismatch is a signal |
| **Domains without TLS 1.3** | Older sites | Reality requires TLS 1.3 on dest; connection fails |

### Recommendations
1. **Audit current 104-domain SNI list** -- remove overused domains (google.com, microsoft.com, etc.)
2. **Add SNI validation** -- verify chosen SNI serves TLS 1.3 + H2 from a CDN/distributed IP
3. **Per-installation SNI selection** -- instead of static list, probe available domains at install time
4. **Periodic SNI health-check** -- warn if SNI starts getting blocked for this server IP

---

## Fingerprint Assessment

**Question:** Does the choice of uTLS fingerprint (chrome, firefox, safari) matter for TSPU detection?

**Finding:** No evidence that fingerprint selection affects TSPU detection. All observed blocking is based on:
- Connection count patterns (Vision creates many TLS connections)
- Traffic volume thresholds (15-20KB per TCP connection)
- Port targeting (443 specifically)
- TLS version heuristics (TLS 1.3 + sustained flow = suspect)

TSPU does NOT appear to use JA3/JA4 fingerprint matching. This is consistent with the fact that blocking also affects real browsers accessing real websites.

**Recommendation:** Default to `chrome` (most common, least suspicious if fingerprint IS ever checked). Do not create separate transport options for different fingerprints -- offer it as a sub-option within transport configuration.

**Confidence:** MEDIUM. Absence of evidence is not evidence of absence. TSPU may add JA3 matching in the future.

---

## Regional Variation Warning

Blocking is NOT uniform across Russia. Critical variable factors:

| Factor | Impact |
|--------|--------|
| **ISP type** | Mobile (MTS, Megafon, Beeline, Tele2, Yota) = strictest. Wired (Rostelecom, DOM.ru) = moderate. Datacenter ISPs = most lenient |
| **Region** | Tatarstan, Udmurtia, Primorye, Novosibirsk -- early test regions. Moscow/SPb -- less affected so far |
| **Time** | Blocking rules change week to week. What works today may not work tomorrow. |
| **VPS provider** | OVH, Hetzner IP ranges specifically targeted on mobile. Less-known hosters fare better. |

**Implication for Xrayebator:** Must offer multiple transport options and easy switching. Single "recommended" config is insufficient.

---

## MVP Recommendation

For the next Xrayebator release, prioritize:

1. **Promote XHTTP+Reality to recommended default** (currently option #5, should be #1)
2. **Move all transports off port 443** by default (random port generation)
3. **Remove or deprecate Vision-on-443 options** (add large warning if kept)
4. **Add XHTTP extra settings** (padding, xmux tuning)
5. **Audit SNI list** -- remove google.com/microsoft.com/etc.

Defer:
- **CDN fallback:** requires domain purchase, complex setup -- phase 2
- **XHTTP downloadSettings:** complex, not proven necessary yet -- phase 2
- **Finalmask/XDRIVE:** not stable/released yet -- phase 3

---

## Sources

### HIGH confidence (official/authoritative)
- Xray-core v26.2.6 release notes: https://github.com/XTLS/Xray-core/releases/tag/v26.2.6
- Xray-core v25.12.8 release notes: https://github.com/XTLS/Xray-core/releases/tag/v25.12.8
- XHTTP modes explanation by RPRX: https://github.com/net4people/bbs/issues/440
- Xray transport documentation: https://xtls.github.io/en/config/transport.html
- XHTTP stream-up PR by RPRX: https://github.com/XTLS/Xray-core/pull/3994

### MEDIUM confidence (multiple community sources agree)
- net4people/bbs #546 -- TLS connection-based policing: https://github.com/net4people/bbs/issues/546
- net4people/bbs #490 -- TSPU whitelist and 15-20KB threshold: https://github.com/net4people/bbs/issues/490
- Habr "Clumsy Hands" analysis (Nov 2025): https://habr.com/en/articles/990236/
- Habr "Why VLESS will be blocked" (Jan 2026): https://habr.com/ru/companies/femida_search/articles/986294/
- Habr "XHTTP overview" (Feb 2026): https://habr.com/en/articles/990208/
- digirpt.com "VLESS blocked in Russia 2026": https://digirpt.com/2026/02/17/vless-zablokirovali-rossiya-chto-delat/
- ntc.party "Which bypass method for 2026": https://ntc.party/t/22139
- ntc.party "XHTTP+Reality on port 443 guide": https://ntc.party/t/21459
- ntc.party "Which protocols besides VLESS" (Jan 2026): https://ntc.party/t/21989
- Reddit r/VPN "VLESS/Reality on Wi-Fi vs mobile": https://www.reddit.com/r/VPN/comments/1ogn5cs/
- Reddit r/dumbclub "Best setup VLESS+xhttp+Reality" (Feb 2026): https://www.reddit.com/r/dumbclub/comments/1qvlbhm/
- Reddit r/VPN "Information about Russia blocking VLESS" (Nov 2025): https://www.reddit.com/r/VPN/comments/1p66fel/
- 4pda VPN thread: https://4pda.to/forum/index.php?showtopic=1094247
- autoXRAY script (XHTTP+Reality community standard): https://github.com/xVRVx/autoXRAY

### LOW confidence (single source, needs validation)
- EmptyLibra discussion on SNI banning: https://github.com/EmptyLibra/Configure-Xray-with-VLESS-Reality-on-VPS-server/discussions/8
- SSH throttling report (Irkutsk Oblast, single user): net4people #490 comment by Saiv46
- CNews article on statistical analysis vulnerability: https://www.cnews.ru/news/top/2025-05-05_vlasti_rossii_nauchilis
- XDRIVE announcement (Telegram only, not yet in code): https://t.me/projectXtls/1464
