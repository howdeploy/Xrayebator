# Feature Landscape: Xrayebator Configuration Optimization

**Domain:** Xray Reality VPN manager configuration for bypassing Russian TSPU
**Researched:** 2026-03-08

## Table Stakes

Features that any well-configured Xray Reality server must have. Missing = server is detectable or unreliable.

| Feature | Why Expected | Complexity | Notes |
|---------|--------------|------------|-------|
| Config validation before restart | Prevent silent service failures | Low | `xray run -test -config` check before `systemctl restart` |
| DoH DNS (local mode) | Encrypted DNS without routing overhead | Low | Change `https://` to `https+local://` in DNS config |
| Freedom domainStrategy | Prevent IPv6 leaks, use Xray DNS | Low | Add `"domainStrategy": "UseIPv4"` to freedom outbound |
| Sniffing routeOnly | Prevent destination override and extra DNS | Low | Add `"routeOnly": true` to all inbound sniffing |
| Non-empty shortIds | Additional authentication layer for REALITY | Low | Generate hex shortId, add alongside empty string |
| QUIC (UDP/443) blocking | Prevent failed HTTP/3 connections via Russian TSPU | Already done | Current config already blocks this correctly |
| Access log disabled | Privacy and performance | Low | Add `"access": "none"` to log section |

## Differentiators

Features that improve Xrayebator beyond basic functionality.

| Feature | Value Proposition | Complexity | Notes |
|---------|-------------------|------------|-------|
| Auto shortId generation per install | Unique auth per server, not shared default | Low | `openssl rand -hex 8` at install time |
| Migration functions (DNS, Freedom, routeOnly) | Auto-upgrade existing installs | Low | Same pattern as existing `migrate_routing_config()` |
| BitTorrent blocking rule | VPS TOS compliance, prevent abuse | Low | Add protocol bittorrent rule to routing |
| Policy section with bufferSize | Memory optimization for small VPS | Low | `bufferSize: 4` saves significant RAM |
| Config backup before migration | Safety net for migration functions | Low | Copy config.json before any jq modification |
| SNI validation via `xray tls ping` | Verify dest servers still support TLS 1.3 + H2 | Med | Run at SNI selection or change |
| Xray version check and upgrade prompt | Keep users on latest security patches | Med | Compare installed vs latest GitHub release |
| Russia-specific geo databases | Better routing for Russian blocked content | Med | Download runetfreedom databases alongside Loyalsoldier |
| DNS tag for routing control | Explicit DNS traffic routing | Low | Add `"tag": "dns-out"` to DNS section |

## Anti-Features

Features to explicitly NOT build in this milestone.

| Anti-Feature | Why Avoid | What to Do Instead |
|--------------|-----------|-------------------|
| Finalmask (XICMP/XDNS) support | Too new (v26.2.6), API not stable, third-party implementations warned against | Monitor, add in future milestone when API stabilizes |
| XHTTP CDN bypass options (#5414) | Explicitly marked "not yet finalized" by Xray devs | Wait for stable release |
| XDRIVE transport | Announced but not released yet | Monitor for next month release |
| allowInsecure migration | Client-side change, Xrayebator server does not use allowInsecure | Document in release notes for users |
| Hysteria 2 integration | Different protocol, different transport, significant scope | Separate milestone |
| Custom XHTTP padding ranges | Current values (100-1000) are adequate, anti-detection is active arms race | Monitor community, adjust only with evidence |
| Russia geo databases (full integration) | Requires download infrastructure, update mechanism, testing | Investigate in separate milestone |
| stats/api sections | Adds overhead, only needed for traffic monitoring | Consider in separate feature milestone |
| ForceIPv4 on freedom | Too strict -- fails connections when no A record exists | Use UseIPv4 which is a preference, not a hard requirement |

## Feature Dependencies

```
Config validation -> independent, no dependencies (should be FIRST)
DNS fix (https+local) -> independent
Freedom domainStrategy -> soft-depends on DNS fix (UseIPv4 resolves through Xray DNS)
Sniffing routeOnly -> independent
shortIds generation -> independent
BitTorrent rule -> independent
Policy section -> independent
All migration functions -> depend on config validation being available
Install.sh update -> depends on all above being decided
```

## MVP Recommendation

Prioritize (all Low complexity, HIGH confidence):
1. **Config validation before restart** -- safety net for all future changes
2. **DNS fix: https+local://1.1.1.1/dns-query** -- immediate latency improvement
3. **Freedom outbound domainStrategy: UseIPv4** -- close IPv6 leak
4. **Sniffing routeOnly: true** -- prevent destination override issues
5. **shortIds generation** -- security improvement
6. **Access log: "none"** -- privacy improvement
7. **BitTorrent block rule** -- VPS TOS compliance

Defer:
- **Russia geo databases:** Needs separate investigation of download, storage, update mechanisms
- **SNI TLS ping validation:** Useful but not urgent, adds complexity to SNI selection flow
- **Xray version check:** Nice-to-have, not a config fix
- **Policy section:** Optimization, not a bug fix -- can be added later

## Sources

- Official Xray DNS docs: https://xtls.github.io/en/config/dns.html
- Official Freedom outbound docs: https://xtls.github.io/en/config/outbounds/freedom.html
- REALITY transport docs: https://xtls.github.io/en/config/transport.html
- Xray-core v26.2.6 release: https://github.com/XTLS/Xray-core/releases/tag/v26.2.6
- XTLS/Xray-examples repo (routeOnly usage): https://github.com/XTLS/Xray-examples
- net4people/bbs#490 (TSPU methods): https://github.com/net4people/bbs/issues/490
- Xray server guide: https://xtls.github.io/en/document/level-0/ch07-xray-server.html
