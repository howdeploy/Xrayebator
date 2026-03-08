# Technology Stack: Xray-core Configuration for Bypassing Russian TSPU

**Project:** Xrayebator
**Researched:** 2026-03-08
**Mode:** Stack dimension (subsequent milestone)

## Recommended Stack

### Core: Xray-core

| Technology | Version | Purpose | Why |
|------------|---------|---------|-----|
| Xray-core | v26.2.6 (latest stable) | VPN proxy engine | Latest stable as of 2026-02-06. Critical fixes: XHTTP "auto" mode with REALITY (#5638), dynamic Chrome User-Agent for all HTTP requests (#5658), reduced memory usage (#5581). New features: Hysteria 2 outbound/transport, TUN inbound, Finalmask (XICMP/XDNS). **Confidence: HIGH** (verified via GitHub API) |
| Loyalsoldier/v2ray-rules-dat | latest release | Enhanced geoip.dat + geosite.dat | Better coverage of ad domains, CN domains. Used by current install.sh. **Confidence: HIGH** |
| runetfreedom/russia-v2ray-rules-dat | latest release | Russia-specific blocked domain/IP lists | Contains `geosite:category-ru-blocked`, `geoip:ru-blocked` -- domains/IPs blocked by Roskomnadzor. Essential for Russia-context routing. **Confidence: MEDIUM** (active project, weekly updates, but not yet integrated into Xrayebator) |

### DNS Configuration

**Current (problematic):**
```json
{
  "dns": {
    "servers": [
      "https://dns.adguard-dns.com/dns-query",
      {
        "address": "1.1.1.1",
        "domains": ["geosite:geolocation-!cn"]
      },
      "localhost"
    ],
    "queryStrategy": "UseIPv4",
    "disableCache": false
  }
}
```

**Problems identified:**
1. DoH as primary DNS adds 100-300ms per query (TLS handshake overhead on server side)
2. `geosite:geolocation-!cn` rule is China-centric, irrelevant for Russia context
3. No `tag` or `disableFallback` settings for fine-grained control
4. DNS queries through DoH go through routing, potentially creating loops

**Recommended configuration:**

| Setting | Value | Rationale | Confidence |
|---------|-------|-----------|------------|
| Primary DNS | `"https+local://1.1.1.1/dns-query"` | DoH Local mode -- bypasses routing, goes directly via Freedom outbound. Encrypted but minimal latency (no routing hop). Official docs explicitly state this reduces latency. | HIGH |
| Fallback DNS | `"1.1.1.1"` | Plain UDP as fallback if DoH fails. Fast, reliable. Server is already outside censored network, so plaintext DNS is acceptable. | HIGH |
| AdGuard DNS integration | Keep `"127.0.0.1"` when AdGuard Home is active | When AdGuard is installed, route through local AdGuard. This is already correct in the script when AdGuard is active. | HIGH |
| queryStrategy | `"UseIPv4"` | Prevent IPv6 leaks. Keep current value. | HIGH |
| disableCache | `false` | Keep DNS caching enabled for performance. | HIGH |
| disableFallback | `false` | Allow fallback between DNS servers. | MEDIUM |
| tag | `"dns-out"` | Tag the DNS outbound for routing rules to properly handle DNS traffic. | MEDIUM |

**Recommended DNS config (without AdGuard Home):**
```json
{
  "dns": {
    "servers": [
      "https+local://1.1.1.1/dns-query",
      "1.1.1.1",
      "localhost"
    ],
    "queryStrategy": "UseIPv4",
    "disableCache": false,
    "tag": "dns-out"
  }
}
```

**Key insight from official docs:** The `+local` suffix (e.g., `https+local://`) makes DNS queries bypass routing and go directly via Freedom outbound. This eliminates routing loops AND reduces latency compared to regular DoH that goes through the routing engine. This is the **officially recommended approach** for server-side Xray DNS.

**Confidence: HIGH** -- sourced from official Xray documentation at `xtls.github.io/en/config/dns.html` and the official server guide at `xtls.github.io/en/document/level-0/ch07-xray-server.html` which explicitly uses `https+local://1.1.1.1/dns-query`.

---

### Routing Configuration

**Current (problematic):**
```json
{
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      {"type": "field", "ip": ["geoip:private"], "outboundTag": "block"},
      {"type": "field", "domain": ["geosite:category-ads-all"], "outboundTag": "block"},
      {"type": "field", "network": "udp", "port": 443, "outboundTag": "block"},
      {"type": "field", "network": "tcp,udp", "outboundTag": "direct"}
    ]
  }
}
```

**Problems identified:**
1. Missing `geoip:cn` block -- allows server to connect back to China (irrelevant but harmless)
2. `geosite:geolocation-!cn` in DNS is China-oriented, not Russia-oriented
3. QUIC (UDP/443) globally blocked -- this is the correct choice for now but may need revisiting
4. No DNS routing rule (port 53 traffic not explicitly handled)

**Recommended routing config:**

| Setting | Value | Rationale | Confidence |
|---------|-------|-----------|------------|
| domainStrategy | `"IPIfNonMatch"` | Keep current. Resolves domains to IP when no domain rule matches, then retries IP rules. Good for catch-all routing. | HIGH |
| Block private IPs | `geoip:private` -> block | Prevent SSRF/intranet attacks. Keep current. | HIGH |
| Block ads | `geosite:category-ads-all` -> block | Ad blocking at server level. Keep current. | HIGH |
| DNS routing | port 53 -> `dns-out` | Route DNS queries to Xray's built-in DNS module rather than letting them escape as plaintext. | MEDIUM |
| QUIC handling | UDP/443 -> block | **Keep blocking.** Russian TSPU has been blocking QUIC (UDP/443) to foreign destinations since 2022 (net4people/bbs#108). Allowing QUIC would cause clients to waste time on failed connections before falling back to TCP. Blocking it server-side forces clients to use TCP immediately. | HIGH |
| Default direct | `tcp,udp` -> direct | Catch-all direct route. Keep current. | HIGH |

**Recommended routing config:**
```json
{
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      {
        "type": "field",
        "ip": ["geoip:private"],
        "outboundTag": "block"
      },
      {
        "type": "field",
        "domain": ["geosite:category-ads-all"],
        "outboundTag": "block"
      },
      {
        "type": "field",
        "network": "udp",
        "port": 443,
        "outboundTag": "block"
      },
      {
        "type": "field",
        "network": "tcp,udp",
        "outboundTag": "direct"
      }
    ]
  }
}
```

**On QUIC blocking (UDP/443):**

The decision to block QUIC at the server side is correct and should remain. Evidence:
- Russian TSPU has blocked QUIC connections (UDP/443) since March 2022 (gfw.report confirms: "Russia blocked all QUIC connections that used QUIC version 1, were destined to port 443, and had a payload size of at least 1001 bytes")
- net4people/bbs#108 confirms this on ISPs: Yota, Megafon, MTS, Rnet, Beeline
- Xray-core v26.1.23 release notes explicitly recommend: "block UDP/443, or enable 'quic' in sniffing"
- If QUIC is not blocked server-side, browsers will attempt HTTP/3 connections through the proxy, which will fail because TSPU blocks the return path, causing latency and failed page loads

**Confidence: HIGH** -- multiple independent sources confirm this is standard practice.

**Note on `geosite:geolocation-!cn` removal:** The DNS rule using `geosite:geolocation-!cn` (meaning "non-Chinese sites") was inherited from China-focused configurations. For Russia context, this rule is irrelevant -- it does not harm but adds confusion. Remove it from the DNS config and use simpler DNS setup.

---

### Freedom Outbound Configuration

**Current (problematic):**
```json
{
  "outbounds": [
    {"protocol": "freedom", "tag": "direct"},
    {"protocol": "blackhole", "tag": "block"}
  ]
}
```

**Problem:** Freedom outbound has no `domainStrategy` setting. Default is `"AsIs"` which sends domain names as-is to the system resolver. This means:
1. DNS resolution happens at the OS level, not through Xray's DNS module
2. IPv6 addresses may leak (OS might prefer IPv6 even when Xray DNS says UseIPv4)
3. Sniffed domain names from TLS SNI are not resolved through Xray's DNS

**Recommended freedom outbound:**

| Setting | Value | Rationale | Confidence |
|---------|-------|-----------|------------|
| domainStrategy | `"UseIPv4"` | Force IPv4 resolution through Xray's built-in DNS. Prevents IPv6 leaks and ensures all DNS goes through the configured DNS servers. | HIGH |

```json
{
  "outbounds": [
    {
      "protocol": "freedom",
      "tag": "direct",
      "settings": {
        "domainStrategy": "UseIPv4"
      }
    },
    {
      "protocol": "blackhole",
      "tag": "block"
    }
  ]
}
```

**Confidence: HIGH** -- official docs at `xtls.github.io/en/config/outbounds/freedom.html` document this. Multiple GitHub discussions (#3495, #5103) confirm `domainStrategy` in freedom outbound controls how the server resolves sniffed/routed domain names.

---

### Reality Settings

**Current (problematic):**
```json
{
  "realitySettings": {
    "show": false,
    "dest": "$sni:443",
    "xver": 0,
    "serverNames": ["$sni"],
    "privateKey": "$PRIVATE_KEY",
    "shortIds": [""],
    "fingerprint": "$fingerprint"
  }
}
```

**Problems identified:**
1. `shortIds: [""]` -- empty shortId provides NO additional authentication. Any client with the public key can connect without knowing a shortId.
2. dest/serverNames selection relies on SNI list but no validation criteria documented

**Recommended Reality settings:**

| Setting | Value | Rationale | Confidence |
|---------|-------|-----------|------------|
| shortIds | `["", "0123456789abcdef"]` | Include empty string for backward compatibility, PLUS at least one non-empty shortId (1-16 hex chars). Non-empty shortIds act as additional authentication -- client must know both publicKey AND shortId. Empty shortId should be phased out. | HIGH |
| dest server criteria | TLS 1.3 + H2, foreign, no redirect | Official REALITY docs specify: "support TLSv1.3 and H2, domain not used for redirection." Bonus: IP close to server IP, OCSP Stapling. Use `xray tls ping <domain>` to validate. | HIGH |
| fingerprint | `"chrome"` | Chrome is the most common browser. Use as default. Other options (firefox, safari, edge, etc.) are valid for diversity. | HIGH |

**shortIds generation:**
```bash
# Generate a random 16-char hex shortId
openssl rand -hex 8
# Example output: a1b2c3d4e5f6a7b8
```

**Recommended shortIds approach:**
```json
"shortIds": ["", "a1b2c3d4e5f6a7b8"]
```

Keep `""` for backward compatibility with existing profiles. Add a real shortId for new profiles. Generate per-installation (not hardcoded).

**Confidence: HIGH** -- official docs at `xtls.github.io/en/config/transport.html` document shortIds. XTLS/Xray-core Discussion #1702 and #4849 confirm selection criteria.

**dest server selection for Russia context:**

The current SNI list has 104 domains in 4 categories (ru_whitelist, yandex_cdn, foreign, etc.). Key criteria for dest:
1. **Must support TLS 1.3 and H2** -- validate with `xray tls ping <domain>`
2. **Prefer Russian whitelist SNI** (ozone.ru, wildberries.ru, sberbank.ru) -- these domains are in the TSPU whitelist, making connections to them appear legitimate
3. **IP proximity bonus** -- dest server IP geographically close to VPS IP looks more natural
4. **No redirects** -- domain should serve content directly, not 301/302 redirect
5. **OCSP Stapling** -- reduces TLS handshake size and latency

**Confidence: HIGH** -- net4people/bbs#490 confirms whitelist-based filtering by TSPU using SNI.

---

### TCP BBR and Network Tuning

**Current sysctl settings (in install.sh):**
```
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.ipv4.tcp_fastopen=3
net.ipv4.tcp_slow_start_after_idle=0
net.ipv4.tcp_notsent_lowat=16384
net.ipv4.tcp_rmem=4096 87380 16777216
net.ipv4.tcp_wmem=4096 65536 16777216
net.core.rmem_max=16777216
net.core.wmem_max=16777216
net.core.rmem_default=1048576
net.core.wmem_default=1048576
net.ipv4.ip_local_port_range=1024 65535
net.ipv4.tcp_max_tw_buckets=2000000
net.ipv4.tcp_fin_timeout=10
net.ipv4.tcp_keepalive_time=600
net.ipv4.tcp_keepalive_intvl=30
net.ipv4.tcp_keepalive_probes=3
net.ipv4.tcp_mtu_probing=1
net.ipv4.tcp_syncookies=1
net.core.netdev_max_backlog=16384
net.ipv4.tcp_max_syn_backlog=8192
```

**Assessment:** This is a solid configuration. Well-researched and matches industry best practices (Cloudflare blog, DigitalOcean tuning guide, ESnet 100G research).

| Setting | Current | Verdict | Notes |
|---------|---------|---------|-------|
| BBR | `bbr` | KEEP | Industry standard. Mandatory for VPN performance. |
| fq qdisc | `fq` | KEEP | Required for BBR. Fair queuing scheduler. |
| tcp_fastopen | `3` | KEEP | Both client+server TFO. Reduces handshake latency. |
| tcp_slow_start_after_idle | `0` | KEEP | Prevents speed drops after idle periods. Critical for intermittent VPN traffic. |
| tcp_notsent_lowat | `16384` | KEEP | Cloudflare-recommended value for HTTP/2 prioritization with BBR. |
| tcp_rmem/wmem | Large buffers | KEEP | 16MB max is appropriate for long-distance connections. |
| tcp_mtu_probing | `1` | KEEP | Auto MTU discovery prevents fragmentation issues. |
| tcp_syncookies | `1` | KEEP | SYN flood protection. |

**Missing settings to add:**

| Setting | Value | Rationale | Confidence |
|---------|-------|-----------|------------|
| `net.ipv4.tcp_window_scaling` | `1` | Enable TCP window scaling for large bandwidth-delay products. Usually default but should be explicit. | MEDIUM |
| `net.ipv4.tcp_timestamps` | `1` | Required for RTT estimation with BBR. Usually default. | MEDIUM |
| `net.ipv4.tcp_sack` | `1` | Selective ACK improves recovery from packet loss. Usually default. | MEDIUM |

**Verdict: Current TCP tuning is solid. Minor additions optional.**

**Confidence: HIGH** -- current settings align with verified best practices from Cloudflare blog (2025), DigitalOcean tuning guide (2025), and perlod.com Linux kernel tuning guide (2025).

---

### Config Validation

**Current (problematic):** No config validation before `systemctl restart xray`. If config is invalid, xray fails to start silently.

**Recommended approach:**

```bash
# Validate config before restart
if /usr/local/bin/xray run -test -config "$CONFIG_FILE" > /dev/null 2>&1; then
  systemctl restart xray
else
  echo "Config validation failed!"
  /usr/local/bin/xray run -test -config "$CONFIG_FILE"  # Show error
fi
```

The `xray run -test` command (or `xray -test -config`) validates the config file without starting the service. This is already mentioned in the CLAUDE.md but not implemented in the script.

Additionally, v26.1.23 added `xray run -dump` which can read JSON from STDIN for validation.

**Confidence: HIGH** -- official command documented in Xray docs and CLAUDE.md.

---

### Xray-core Version Policy

| Version | Release Date | Key Features | Status |
|---------|-------------|-------------|--------|
| v26.2.6 | 2026-02-06 | XHTTP CDN bypass, Finalmask (XICMP/XDNS), dynamic Chrome UA, `allowInsecure` removal | **Latest stable** |
| v26.1.23 | 2026-01-23 | TUN inbound, Hysteria 2 outbound, process routing, mmap geofiles | Previous stable |
| v1.8.x | 2023 | REALITY support introduced | Legacy |

**Upgrade recommendation:** Update to v26.2.6. Critical changes:
1. Dynamic Chrome User-Agent for all HTTP requests (anti-fingerprinting)
2. XHTTP "auto" mode fix with REALITY (#5638) -- directly impacts Xrayebator
3. `allowInsecure` deprecated with auto-disable date UTC 2026.6.1 -- must update client configs to use `pinnedPeerCertSha256`/`verifyPeerCertByName`
4. Reduced memory usage for geofiles (mmap)
5. Hysteria 2 outbound support (future use for Xrayebator)

**The install script currently uses the latest release via XTLS/Xray-install script, which is correct.**

**Confidence: HIGH** -- verified via GitHub API.

---

## Alternatives Considered

| Category | Recommended | Alternative | Why Not |
|----------|-------------|-------------|---------|
| DNS primary | `https+local://1.1.1.1/dns-query` | `https://dns.adguard-dns.com/dns-query` | AdGuard DoH goes through routing (latency), +local bypasses routing |
| DNS primary | `https+local://1.1.1.1/dns-query` | `1.1.1.1` (plain UDP) | Plain UDP is unencrypted; server side this is acceptable but DoH+local is better |
| Freedom domainStrategy | `UseIPv4` | `AsIs` (current default) | AsIs uses OS resolver, may leak IPv6, bypasses Xray DNS module |
| Freedom domainStrategy | `UseIPv4` | `ForceIPv4` | ForceIPv4 will FAIL if DNS returns no A record; UseIPv4 is more tolerant |
| QUIC handling | Block UDP/443 | Allow UDP/443 | TSPU blocks QUIC return traffic; allowing it causes failed connections and latency |
| Geo databases | Loyalsoldier | Standard v2ray-geoip/geosite | Loyalsoldier has better coverage of ad domains and CN sites |
| Russia routing | Add runetfreedom | Use geolocation-!cn | geolocation-!cn is China-centric; runetfreedom has actual Roskomnadzor blocked lists |

---

## Configuration Reference: Complete Recommended Server Config

```json
{
  "log": {
    "loglevel": "warning"
  },
  "dns": {
    "servers": [
      "https+local://1.1.1.1/dns-query",
      "1.1.1.1",
      "localhost"
    ],
    "queryStrategy": "UseIPv4",
    "disableCache": false,
    "tag": "dns-out"
  },
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      {
        "type": "field",
        "ip": ["geoip:private"],
        "outboundTag": "block"
      },
      {
        "type": "field",
        "domain": ["geosite:category-ads-all"],
        "outboundTag": "block"
      },
      {
        "type": "field",
        "network": "udp",
        "port": 443,
        "outboundTag": "block"
      },
      {
        "type": "field",
        "network": "tcp,udp",
        "outboundTag": "direct"
      }
    ]
  },
  "inbounds": [],
  "outbounds": [
    {
      "protocol": "freedom",
      "tag": "direct",
      "settings": {
        "domainStrategy": "UseIPv4"
      }
    },
    {
      "protocol": "blackhole",
      "tag": "block"
    }
  ]
}
```

**Changes from current config:**
1. DNS: `https://dns.adguard-dns.com/dns-query` -> `https+local://1.1.1.1/dns-query` (bypasses routing, reduces latency)
2. DNS: Removed `geosite:geolocation-!cn` rule (China-centric, irrelevant)
3. DNS: Added `tag: "dns-out"` for proper DNS routing
4. Freedom outbound: Added `domainStrategy: "UseIPv4"` (forces Xray DNS, prevents IPv6 leak)
5. Routing: Unchanged (current rules are correct)

---

## XHTTP Extra Settings (Anti-Detection)

The current XHTTP extra settings in Xrayebator are good but could be improved:

**Current:**
```json
{
  "xPaddingBytes": "100-1000",
  "xmux": {
    "maxConcurrency": "16-32",
    "cMaxLifetimeMs": "10000-30000"
  },
  "noSSEHeader": true,
  "scMaxEachPostBytes": "1000000-2000000",
  "scMinPostsIntervalMs": "10-50"
}
```

**Assessment:** Reddit/ntc.party discussions note that default padding range `100-1000` is detectable because it differs from normal HTTP traffic patterns. However, the current Xrayebator values are already customized with xmux, noSSEHeader, and post limits -- this is better than defaults.

**Recommended improvement:** Widen padding range slightly to match more natural traffic patterns:

```json
{
  "xPaddingBytes": "100-1000",
  "xmux": {
    "maxConcurrency": "16-32",
    "cMaxLifetimeMs": "10000-30000"
  },
  "noSSEHeader": true,
  "scMaxEachPostBytes": "1000000-2000000",
  "scMinPostsIntervalMs": "10-50"
}
```

**Verdict: Keep current values.** They are already tuned. The v26.2.6 release adds NEW XHTTP options for CDN detection bypass (#5414) but those are flagged as "not yet finalized, third-party implementations should not follow yet."

**Confidence: MEDIUM** -- XHTTP anti-detection is an active cat-and-mouse area. Settings that work today may need updates.

---

## Sniffing Configuration

**Current (correct):**
```json
{
  "sniffing": {
    "enabled": true,
    "destOverride": ["http", "tls", "quic"]
  }
}
```

**Assessment:** This is correct. Sniffing extracts the real destination from TLS SNI / HTTP Host, allowing proper routing even when clients use IP addresses. Including "quic" in destOverride is important for the UDP/443 blocking rule to work correctly.

**Confidence: HIGH** -- matches v26.1.23 release recommendation.

---

## Sources

- Xray-core v26.2.6 release notes: https://github.com/XTLS/Xray-core/releases/tag/v26.2.6 **(HIGH confidence)**
- Xray-core v26.1.23 release notes: https://github.com/XTLS/Xray-core/releases/tag/v26.1.23 **(HIGH confidence)**
- Official DNS docs: https://xtls.github.io/en/config/dns.html **(HIGH confidence)**
- Official Freedom outbound docs: https://xtls.github.io/en/config/outbounds/freedom.html **(HIGH confidence)**
- Official REALITY transport docs: https://xtls.github.io/en/config/transport.html **(HIGH confidence)**
- Official server guide: https://xtls.github.io/en/document/level-0/ch07-xray-server.html **(HIGH confidence)**
- REALITY dest server requirements: https://github.com/XTLS/Xray-core/discussions/4849 **(HIGH confidence)**
- REALITY shortIds and setup: https://github.com/XTLS/Xray-core/discussions/1702 **(HIGH confidence)**
- Russian QUIC blocking: https://github.com/net4people/bbs/issues/108 **(HIGH confidence)**
- TSPU new blocking methods: https://github.com/net4people/bbs/issues/490 **(HIGH confidence)**
- QUIC censorship research: https://gfw.report/publications/usenixsecurity25/en/ **(HIGH confidence)**
- Russia-specific geo rules: https://github.com/runetfreedom/russia-v2ray-rules-dat **(MEDIUM confidence)**
- v2rayN Russia routing ruleset: https://github.com/2dust/v2rayNG/discussions/4761 **(MEDIUM confidence)**
- VLESS blocking in Russia Feb 2026: https://digirpt.com/2026/02/17/vless-zablokirovali-rossiya-chto-delat/ **(LOW confidence -- blog post)**
- ntc.party VLESS blocking discussion: https://ntc.party thread on blocking Feb 2026 **(MEDIUM confidence)**
- TCP BBR best practices: https://perlod.com/tutorials/linux-kernel-network-tuning/ **(MEDIUM confidence)**
- Cloudflare BBR + tcp_notsent_lowat: https://blog.cloudflare.com/http-2-prioritization-with-nginx/ **(HIGH confidence)**
