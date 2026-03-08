# Architecture Research: Optimal Xray config.json for TSPU Bypass

**Domain:** Xray Reality VPN server configuration for bypassing Russian DPI (TSPU)
**Researched:** 2026-03-08
**Confidence:** HIGH (official XTLS docs + community examples + Xray-examples repo)

## System Overview

```
                        TSPU / DPI
                           |
Client =====[TLS 1.3 + Reality]===> VPS Server
                                      |
                               +--------------+
                               | Xray-core    |
                               |              |
                               | Inbound(s)   |  <-- VLESS + Reality
                               |   |          |
                               | Sniffing     |  <-- domain extraction
                               |   |          |
                               | Routing      |  <-- rule matching
                               |   |          |
                               | DNS          |  <-- domain resolution (when needed)
                               |   |          |
                               | Outbound(s)  |  <-- freedom / blackhole
                               +--------------+
                                      |
                                  Internet
```

### Component Responsibilities

| Component | Responsibility | Current State | Optimal State |
|-----------|---------------|---------------|---------------|
| Log | Error/debug logging | `warning` | `warning` (correct) |
| DNS | Domain resolution for routing | AdGuard DoH (remote, latency) | `https+local://` DoH (local mode, low latency) |
| Routing | Traffic classification and direction | `IPIfNonMatch`, basic rules | `IPIfNonMatch`, optimized rule order |
| Inbounds | Accept client connections | Dynamic per-profile, no `routeOnly` | Add `routeOnly: true` to all |
| Outbounds | Send traffic to destination | Bare `freedom` + `blackhole` | `freedom` with `domainStrategy` + `blackhole` |
| Policy | Connection limits, buffers | Not present | Add for tuning |

## Optimal config.json (Complete Reference)

```json
{
  "log": {
    "loglevel": "warning",
    "access": "none"
  },

  "dns": {
    "servers": [
      "https+local://1.1.1.1/dns-query",
      "localhost"
    ],
    "queryStrategy": "UseIPv4",
    "disableCache": false,
    "tag": "dns-internal"
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
        "protocol": ["bittorrent"],
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
      "settings": {
        "domainStrategy": "UseIPv4"
      },
      "tag": "direct"
    },
    {
      "protocol": "blackhole",
      "tag": "block"
    }
  ],

  "policy": {
    "levels": {
      "0": {
        "handshake": 4,
        "connIdle": 300,
        "uplinkOnly": 2,
        "downlinkOnly": 5,
        "bufferSize": 4
      }
    }
  }
}
```

### Inbound Template (applied per-profile)

```json
{
  "listen": "0.0.0.0",
  "port": 443,
  "protocol": "vless",
  "settings": {
    "clients": [
      {
        "id": "<UUID>",
        "flow": "xtls-rprx-vision"
      }
    ],
    "decryption": "none"
  },
  "streamSettings": {
    "network": "tcp",
    "security": "reality",
    "realitySettings": {
      "show": false,
      "dest": "<SNI>:443",
      "xver": 0,
      "serverNames": ["<SNI>"],
      "privateKey": "<PRIVATE_KEY>",
      "shortIds": ["", "0123456789abcdef"]
    }
  },
  "sniffing": {
    "enabled": true,
    "destOverride": ["http", "tls", "quic"],
    "routeOnly": true
  },
  "tag": "inbound-443"
}
```

## Section-by-Section Analysis

### 1. Log Section

**Confidence: HIGH** (official docs + community consensus)

```json
{
  "log": {
    "loglevel": "warning",
    "access": "none"
  }
}
```

| Setting | Value | Rationale |
|---------|-------|-----------|
| `loglevel` | `"warning"` | Production standard. `error` misses useful warnings about config issues. `info` is too verbose for production (generates per-connection logs). `debug` is only for troubleshooting. |
| `access` | `"none"` | Disables access log entirely. On a VPN server, access logs create privacy risk (who connected when) and cause disk I/O overhead. Official docs: set to `"none"` to disable. |

**Current state:** `"warning"` without `access` field -- access log goes to stdout by default.

**Migration:** Add `"access": "none"` to suppress stdout access logging. Keeps error/warning output for `journalctl -u xray`.

**Anti-pattern:** Do NOT use `"loglevel": "none"` in production. You lose error and warning output entirely, making it impossible to diagnose config issues or connection failures.

---

### 2. DNS Section

**Confidence: HIGH** (official docs explicitly recommend `https+local://` for server-side)

```json
{
  "dns": {
    "servers": [
      "https+local://1.1.1.1/dns-query",
      "localhost"
    ],
    "queryStrategy": "UseIPv4",
    "disableCache": false,
    "tag": "dns-internal"
  }
}
```

| Setting | Value | Rationale |
|---------|-------|-----------|
| `servers[0]` | `"https+local://1.1.1.1/dns-query"` | **DOHL (DoH Local) mode.** Official docs: "the DOH request will not pass through the routing component but will request directly via the Freedom outbound to reduce latency. Generally suitable for server-side use." This avoids routing DNS queries through Xray's own pipeline, eliminating loops and reducing latency. |
| `servers[1]` | `"localhost"` | Fallback to system DNS resolver. If DoH fails (network issue, 1.1.1.1 unreachable), Xray falls back to the OS-configured DNS. |
| `queryStrategy` | `"UseIPv4"` | Only resolve A records (IPv4). Most VPS have IPv4 only. Prevents AAAA queries that return nothing, cutting DNS latency in half. |
| `disableCache` | `false` | Enables Xray's internal DNS cache. Avoids repeated DoH queries for the same domain. Default is `false` but explicit is better. |
| `tag` | `"dns-internal"` | Names the DNS component for potential routing rules targeting DNS traffic. Optional but good practice. |

**Current state problems:**

1. `"https://dns.adguard-dns.com/dns-query"` (without `+local`) -- this DNS request goes through Xray's routing system, which can cause routing loops or unnecessary overhead on a server. The `+local` suffix is specifically designed for server-side use.
2. AdGuard DNS as primary adds latency (EU/US servers for a VPS that might be geographically closer to Cloudflare 1.1.1.1).
3. The current `"address": "1.1.1.1"` secondary is plain UDP DNS (port 53), unencrypted. Not critical on server side, but unnecessary when using DoH primary.

**When AdGuard Home is installed:** DNS section correctly switches to `"servers": ["127.0.0.1"]` pointing to the local AdGuard Home instance. This is already optimal -- local DNS, zero latency, with ad filtering. No changes needed for the AdGuard Home integration path.

**Migration:**
- Without AdGuard Home: Replace DNS block with `https+local://1.1.1.1/dns-query` + `localhost`.
- With AdGuard Home: Keep `127.0.0.1` as-is (already optimal).
- The uninstall_adguard_home restoration should also switch to `https+local://` instead of the old format.

**Alternative DNS providers for `https+local://`:**

| Provider | URL | Notes |
|----------|-----|-------|
| Cloudflare | `https+local://1.1.1.1/dns-query` | Fastest globally, anycast |
| Google | `https+local://8.8.8.8/dns-query` | Reliable, well-cached |
| Quad9 | `https+local://9.9.9.9:5053/dns-query` | Security-focused, blocks malware |

**Recommendation:** Cloudflare 1.1.1.1 because it has the lowest latency to most VPS datacenters globally (anycast network) and does not log queries.

---

### 3. Routing Section

**Confidence: HIGH** (official docs + examples + community patterns)

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
        "protocol": ["bittorrent"],
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

#### domainStrategy: "IPIfNonMatch"

| Option | Behavior | When to Use |
|--------|----------|-------------|
| `"AsIs"` | Only match domains as strings. Never resolves to IP. | Client-side, minimal DNS usage |
| `"IPIfNonMatch"` | First try domain rules. If no match, resolve domain to IP and try IP rules. | **Server-side recommended.** Catches traffic by both domain and IP. |
| `"IPOnDemand"` | Resolve domain to IP immediately when any IP rule exists. | Aggressive, higher DNS load. Overkill for server. |

**"IPIfNonMatch" is correct for server-side** because:
1. Domain rules (geosite:category-ads-all) match first without DNS resolution -- fast path.
2. If domain doesn't match any rule, Xray resolves it to IP and checks IP rules (geoip:private).
3. Final catch-all `"network": "tcp,udp"` routes everything else to `direct`.

#### Rule Ordering (Critical)

Rules are evaluated **top to bottom, first match wins**. Order matters.

| Priority | Rule | Purpose | Why This Order |
|----------|------|---------|----------------|
| 1 | Block private IPs | Security: prevent SSRF, internal network access | Must be first -- security boundary |
| 2 | Block ads (domain) | Ad filtering via geosite | Before catch-all, domain match is fast |
| 3 | Block BitTorrent | Prevent VPS abuse, TOS violations | Protocol-based, before catch-all |
| 4 | Block QUIC (UDP 443) | Performance: force TCP for proxied QUIC traffic | Before catch-all, prevents slow QUIC-over-proxy |
| 5 | Direct everything else | Default outbound | Catch-all, must be last |

**Why block QUIC (UDP 443)?**
When a client proxies QUIC traffic through Xray, the QUIC packets get encapsulated inside the proxy tunnel (TCP). This creates double overhead: QUIC's own congestion control fights with the outer TCP connection's congestion control. The result is significantly degraded performance compared to forcing the browser to fall back to HTTP/2 over TCP. Blocking UDP 443 forces browsers to use TCP-based HTTP/2, which performs much better through a proxy.

**Note:** Vision flow (`xtls-rprx-vision`) already blocks UDP 443 implicitly. The explicit rule is needed for non-Vision transports (gRPC, XHTTP, tcp-mux) where flow is empty.

**Why block BitTorrent?** Most VPS providers prohibit P2P traffic. BitTorrent detection via the `protocol` field in routing uses Xray's built-in protocol sniffing. This requires sniffing to be enabled on inbounds (which it is).

**Current state:** Missing the BitTorrent block rule. Otherwise correct.

**Migration:** Add `{"type": "field", "protocol": ["bittorrent"], "outboundTag": "block"}` before the catch-all rule.

---

### 4. Inbound Section: Sniffing Configuration

**Confidence: HIGH** (official XTLS/Xray-examples repo uses `routeOnly: true`)

```json
{
  "sniffing": {
    "enabled": true,
    "destOverride": ["http", "tls", "quic"],
    "routeOnly": true
  }
}
```

| Setting | Value | Rationale |
|---------|-------|-----------|
| `enabled` | `true` | Enables traffic sniffing. Required for domain-based routing to work. Without sniffing, Xray only sees destination IPs, not domain names. |
| `destOverride` | `["http", "tls", "quic"]` | Protocols to sniff. `http` extracts Host header, `tls` extracts SNI from ClientHello, `quic` extracts SNI from QUIC initial packets. All three are needed for comprehensive domain detection. |
| `routeOnly` | `true` | **KEY CHANGE.** Sniffed domains are used ONLY for routing decisions. The actual connection destination remains as the original IP address. Without `routeOnly`, Xray replaces the destination with the sniffed domain, which can break certain sites (Tor Browser, CDN-hosted services where SNI differs from actual backend). |

#### routeOnly: true vs false (Detailed)

| Behavior | `routeOnly: false` (current) | `routeOnly: true` (recommended) |
|----------|------------------------------|----------------------------------|
| Domain extraction | Yes | Yes |
| Routing by domain | Yes | Yes |
| Destination override | **Yes** -- replaces IP with sniffed domain | **No** -- keeps original IP |
| DNS resolution | Resolves sniffed domain to IP for connection | Uses original destination IP |
| Compatibility | Can break sites with CDN/SNI mismatch | Compatible with everything |
| Performance | Extra DNS resolution per connection | No extra DNS resolution |

**The official XTLS/Xray-examples repository uses `routeOnly: true`** in the VLESS-TCP-XTLS-Vision-REALITY server config. This is the recommended setting.

**Why `routeOnly: true` is better for a VPN server:**
1. The server receives connections that already have a resolved destination IP from the client. Re-resolving the domain is wasteful.
2. `routeOnly: false` can cause DNS poisoning issues -- if the server's DNS returns a different IP than the client intended.
3. `routeOnly: true` still enables domain-based routing rules (ads blocking, etc.) while keeping the original connection target intact.

**Fields NOT to use:**
- `metadataOnly: true` -- limits sniffing to connection metadata only, loses protocol detection. Not useful for VPN server.
- `domainsExcluded` -- only needed when `routeOnly: false` and you want to exclude specific domains from destination override. Unnecessary with `routeOnly: true`.
- `fakedns` in destOverride -- only useful for client-side transparent proxy setups, not for server.

**Migration:** Add `"routeOnly": true` to all inbound sniffing blocks. This is backward-compatible and non-breaking.

---

### 5. Outbound Section

**Confidence: HIGH** (official docs)

```json
{
  "outbounds": [
    {
      "protocol": "freedom",
      "settings": {
        "domainStrategy": "UseIPv4"
      },
      "tag": "direct"
    },
    {
      "protocol": "blackhole",
      "tag": "block"
    }
  ]
}
```

#### Freedom outbound domainStrategy

| Option | Behavior | Server-Side Use |
|--------|----------|-----------------|
| `"AsIs"` (default) | Sends domain as-is to system resolver | Default, works fine |
| `"UseIPv4"` | Resolves domain to IPv4 via Xray's built-in DNS before connecting | **Recommended** for IPv4-only VPS |
| `"UseIP"` | Resolves to any IP type | Dual-stack VPS only |
| `"ForceIPv4"` | Like UseIPv4 but fails if no IPv4 result | Too strict, can break sites |

**Why `UseIPv4` on freedom outbound?**
1. When `routeOnly: true` is set on sniffing, the connection destination is the original IP -- no domain resolution needed in most cases.
2. However, when `routing.domainStrategy` is `IPIfNonMatch` and routing passes a domain to the outbound (edge case), `UseIPv4` ensures it resolves via Xray's DNS (the `https+local://` DoH) rather than the system resolver.
3. Prevents accidental IPv6 connections on VPS that have broken IPv6 connectivity.

**Official docs caveat:** "Only using `AsIs` here allows passing the domain name to the subsequent sockopt module." -- This matters only if you use `fragment` (anti-DPI on the server's outgoing connections). For a standard VPN server, `UseIPv4` is preferred.

**Current state:** Freedom outbound has no `settings` block at all -- uses `AsIs` by default.

**Migration:** Add `"settings": {"domainStrategy": "UseIPv4"}` to the freedom outbound.

---

### 6. Policy Section

**Confidence: MEDIUM** (official docs for field definitions, community patterns for values)

```json
{
  "policy": {
    "levels": {
      "0": {
        "handshake": 4,
        "connIdle": 300,
        "uplinkOnly": 2,
        "downlinkOnly": 5,
        "bufferSize": 4
      }
    }
  }
}
```

| Setting | Value | Default | Rationale |
|---------|-------|---------|-----------|
| `handshake` | `4` | `4` | Seconds to complete handshake. Default is fine. |
| `connIdle` | `300` | `300` | Seconds before idle connection is closed. 5 minutes is standard for VPN. |
| `uplinkOnly` | `2` | `2` | Seconds to wait after downlink closes before closing uplink. |
| `downlinkOnly` | `5` | `5` | Seconds to wait after uplink closes before closing downlink. |
| `bufferSize` | `4` | `512` | **Internal buffer per connection in KB.** Default is 512 KB. Setting to 4 KB reduces memory usage significantly on multi-user servers. Official docs: "Smaller value reduces memory usage on the server side, but may increase CPU." For a small VPN (1-10 users), 4 KB is a good tradeoff. For heavy usage, increase to 64. |

**bufferSize analysis:**

| Users | bufferSize | Memory per conn | Rationale |
|-------|-----------|-----------------|-----------|
| 1-5 | `64` | 64 KB | More responsive, plenty of RAM |
| 5-20 | `4` | 4 KB | Memory conservation, still adequate |
| 20+ | `4` | 4 KB | Must conserve memory |

**Note:** `bufferSize` can also be set via environment variable `XRAY_RAY_BUFFER_SIZE` (in MB, applies globally). Config-level setting overrides the env var.

**What NOT to add (yet):**
- `stats`, `api` sections -- Only needed if you want traffic statistics via gRPC API. Adds overhead. Not needed for basic VPN management.
- `statsUserUplink/Downlink` -- Enables per-user traffic counting but requires the `stats` and `api` sections.

**Current state:** No policy section at all -- uses defaults (512 KB buffer, standard timeouts).

**Migration:** Add the policy section. Non-breaking, only affects resource usage.

---

### 7. Inbound Architecture: Shared vs Separate Ports

**Confidence: HIGH** (current codebase analysis + official docs)

The current Xrayebator architecture correctly handles this:

| Approach | How It Works | When to Use |
|----------|-------------|-------------|
| **Shared port** (current) | Multiple clients (UUIDs) in one inbound's `clients` array | Same transport + SNI on one port |
| **Separate ports** (current) | Different inbound objects with different ports | Different transports or SNIs |
| **Same port, different transports** | NOT directly supported by Xray | Use fallbacks or separate ports |

**Key architectural constraint:** One inbound = one port + one transport + one SNI set. You cannot mix gRPC and TCP on the same port in separate inbounds (port conflict). You CAN have multiple clients with different UUIDs on one inbound.

**The current Xrayebator model is correct:** Each port gets one inbound with one transport type. Multiple users share the inbound via the clients array. Different transport types require different ports.

**Exception -- Vision and non-Vision on same port:** TCP with `flow: "xtls-rprx-vision"` and TCP without flow (for mux) can coexist on the same inbound because flow is per-client, not per-inbound. The inbound network is `"tcp"` in both cases.

```json
{
  "clients": [
    {"id": "uuid-1", "flow": "xtls-rprx-vision"},
    {"id": "uuid-2", "flow": ""}
  ]
}
```

This is already how Xrayebator handles it (tcp-mux profiles share inbound with tcp/tcp-utls profiles).

---

### 8. Reality Settings Best Practices

**Confidence: HIGH** (official XTLS docs + examples)

```json
{
  "realitySettings": {
    "show": false,
    "dest": "<SNI>:443",
    "xver": 0,
    "serverNames": ["<SNI>"],
    "privateKey": "<KEY>",
    "shortIds": ["", "0123456789abcdef"]
  }
}
```

| Setting | Current | Optimal | Rationale |
|---------|---------|---------|-----------|
| `show` | `false` | `false` | Debug output. Never enable in production. |
| `dest` | `"<SNI>:443"` | `"<SNI>:443"` | Correct. Fallback destination for unauthenticated probes. |
| `xver` | `0` | `0` | PROXY protocol version. 0 = disabled. Only needed behind HAProxy/nginx. |
| `serverNames` | Single SNI | Single SNI | Correct for Xrayebator's model (one SNI per port). |
| `shortIds` | `[""]` | `["", "<random_hex>"]` | **Improvement**: Add a non-empty shortId. Empty string means clients can connect without shortId. Adding a random hex ID enables per-client differentiation. |

**shortIds recommendation:**
- Keep `""` (empty) in the array for backward compatibility with existing profiles.
- Consider adding a random hex shortId (e.g., `"a1b2c3d4"`) for new profiles. This adds a layer of identification but does not affect security (Reality's security comes from the x25519 key exchange, not shortIds).

---

## Architectural Patterns

### Pattern 1: DNS Mode Selection Based on Environment

**What:** Choose DNS configuration based on whether AdGuard Home is installed.
**When:** During AdGuard Home install/uninstall.
**Trade-offs:** Adds conditional logic but ensures optimal DNS path.

```
AdGuard Home installed:
  DNS → "127.0.0.1" (local resolver, full ad blocking, caching)

AdGuard Home NOT installed:
  DNS → "https+local://1.1.1.1/dns-query" (DoH local mode, low latency)
  Fallback → "localhost" (system resolver)
```

### Pattern 2: routeOnly for All Inbounds

**What:** Always set `routeOnly: true` on server-side inbounds.
**When:** Always, on every inbound.
**Trade-offs:** None for server-side. This is strictly better than `routeOnly: false` for a VPN server.

### Pattern 3: Catch-All Direct Rule as Last Resort

**What:** The final routing rule must always be `{"network": "tcp,udp", "outboundTag": "direct"}`.
**When:** Always.
**Trade-offs:** Without this, unmatched traffic goes to the first outbound by implicit default, which happens to be "direct" but is fragile. Explicit is better.

The v1.3.2 migration `migrate_routing_config()` already ensures this rule exists. Good.

---

## Anti-Patterns to Avoid

### Anti-Pattern 1: Remote DoH Without +local on Server

**What people do:** Use `"https://dns.adguard-dns.com/dns-query"` as DNS server.
**Why it's wrong:** Without `+local`, the DoH request goes through Xray's routing system. On a server, this means the DNS query enters the routing pipeline, gets matched by rules, and exits via the freedom outbound -- adding overhead and potential for routing loops.
**Do this instead:** Use `"https+local://1.1.1.1/dns-query"` which bypasses routing entirely and sends the DoH request directly.

### Anti-Pattern 2: sniffing without routeOnly on Server

**What people do:** Enable sniffing with `routeOnly: false` (or omit routeOnly, which defaults to false).
**Why it's wrong:** Xray replaces the destination address with the sniffed domain, then re-resolves it via DNS. On a server, this means: (1) extra DNS resolution per connection, (2) potential DNS poisoning, (3) broken connections when DNS returns a different IP than the client intended.
**Do this instead:** Set `"routeOnly": true`. The sniffed domain is used for routing decisions only; the actual connection goes to the original IP.

### Anti-Pattern 3: Large bufferSize on Small VPS

**What people do:** Set `bufferSize: 10240` (10 MB) thinking bigger = faster.
**Why it's wrong:** Each active connection allocates this buffer. With 100 concurrent connections and 10 MB buffer, that's 1 GB RAM just for buffers. Small VPS (1-2 GB RAM) will OOM.
**Do this instead:** Use `bufferSize: 4` (4 KB) for small VPS, `bufferSize: 64` for dedicated servers. The performance difference is minimal; memory savings are significant.

### Anti-Pattern 4: Using freedom domainStrategy "ForceIPv4" Instead of "UseIPv4"

**What people do:** Set `"ForceIPv4"` on freedom outbound.
**Why it's wrong:** `Force` variants fail the connection entirely if the DNS result doesn't match the requested IP type. Some domains only have AAAA records (IPv6-only), which would cause connection failures.
**Do this instead:** Use `"UseIPv4"` which falls back to `AsIs` if no IPv4 result is available.

---

## Data Flow

### Request Flow (Server-Side)

```
Client TLS 1.3 + Reality
    |
    v
[Inbound: VLESS decode] --> extract UUID, verify Reality keys
    |
    v
[Sniffing: extract domain from TLS SNI / HTTP Host]
    |  (routeOnly=true: domain used for routing only,
    |   destination IP unchanged)
    v
[Routing: match rules top-to-bottom]
    |
    +-- geoip:private? --> [Blackhole: block]
    +-- geosite:category-ads-all? --> [Blackhole: block]
    +-- protocol:bittorrent? --> [Blackhole: block]
    +-- UDP port 443? --> [Blackhole: block]
    +-- everything else --> [Freedom: direct to internet]
    |
    v
[Freedom outbound: connect to destination]
    |  (domainStrategy: UseIPv4 -- resolve via built-in DNS if needed)
    v
Internet
```

### DNS Resolution Flow

```
[Routing needs IP for domain] (IPIfNonMatch triggered)
    |
    v
[Built-in DNS: https+local://1.1.1.1/dns-query]
    |  (DOHL mode: bypasses routing, direct outbound)
    |
    +-- Success? --> return IPv4 address
    |
    +-- Failure? --> [Fallback: localhost (system DNS)]
                         |
                         v
                      return IPv4 address
```

---

## Scaling Considerations

| Scale | Architecture Adjustments |
|-------|--------------------------|
| 1-5 users | Current architecture is fine. `bufferSize: 64`. Single inbound per port. |
| 5-20 users | Add `policy` section with `bufferSize: 4`. Consider `stats` section for traffic monitoring. |
| 20-50 users | Multiple VPS recommended. Single Xray instance handles 50+ concurrent with `bufferSize: 4`. Monitor with `systemctl status xray` for memory. |
| 50+ users | Not recommended on single VPS. Split users across multiple servers. Consider `api` + `stats` for usage monitoring. |

### First Bottleneck: Memory

With default 512 KB buffer, 100 active connections = 50 MB just for buffers. On a 1 GB VPS, this limits concurrent connections. Setting `bufferSize: 4` allows thousands of connections with minimal memory.

### Second Bottleneck: CPU (TLS)

VLESS + Reality adds minimal CPU overhead compared to raw proxy (no double encryption). The main CPU cost is TLS handshake. On a 1-core VPS, this limits to ~500 new connections/second.

---

## Migration Path from Current Config to Optimal

### Phase 1: Non-Breaking Changes (Safe, immediate)

These changes improve performance without affecting existing functionality:

1. **Add `routeOnly: true`** to all inbound sniffing blocks
   - Backward compatible, no behavior change for routing rules
   - Reduces DNS load, prevents destination override issues

2. **Add `"access": "none"`** to log section
   - Reduces stdout noise, no functional impact

3. **Add BitTorrent block rule** to routing
   - Prevents VPS TOS violations
   - Insert before catch-all rule

4. **Add policy section** with `bufferSize: 4`
   - Reduces memory usage, minimal CPU impact

### Phase 2: DNS Optimization (Requires testing)

5. **Switch DNS to `https+local://1.1.1.1/dns-query`**
   - Test: Verify DNS resolution works after change
   - Fallback: `localhost` remains as backup
   - Update AdGuard Home uninstall to restore to new format

6. **Add `domainStrategy: "UseIPv4"`** to freedom outbound
   - Ensures IPv4-only resolution on VPS without IPv6
   - Test: Verify normal browsing works after change

### Phase 3: New Installs Only

7. **Update install.sh** with optimal config template
   - New installations get the optimal config from the start
   - Existing installations migrated via phases 1-2

### Migration Function Template

```bash
migrate_config_v140() {
  echo -e "${CYAN}Оптимизация конфигурации (v1.4.0)...${NC}"

  # 1. Add routeOnly to all inbounds
  local inbound_count=$(jq '.inbounds | length' "$CONFIG_FILE")
  for ((i=0; i<inbound_count; i++)); do
    safe_jq_write --argjson idx "$i" \
      '.inbounds[$idx].sniffing.routeOnly = true' \
      "$CONFIG_FILE"
  done

  # 2. Add access: none to log
  safe_jq_write '.log.access = "none"' "$CONFIG_FILE"

  # 3. Add bittorrent block if missing
  local has_bt=$(jq '.routing.rules[] | select(.protocol != null and (.protocol[] == "bittorrent"))' "$CONFIG_FILE")
  if [[ -z "$has_bt" ]]; then
    safe_jq_write '.routing.rules |= (.[:-1] + [{"type":"field","protocol":["bittorrent"],"outboundTag":"block"}] + .[-1:])' "$CONFIG_FILE"
  fi

  # 4. Add policy section if missing
  local has_policy=$(jq '.policy // empty' "$CONFIG_FILE")
  if [[ -z "$has_policy" ]]; then
    safe_jq_write '.policy = {"levels":{"0":{"handshake":4,"connIdle":300,"uplinkOnly":2,"downlinkOnly":5,"bufferSize":4}}}' "$CONFIG_FILE"
  fi

  # 5. Switch DNS (only if not AdGuard Home)
  local current_dns=$(jq -r '.dns.servers[0]' "$CONFIG_FILE" 2>/dev/null)
  if [[ "$current_dns" != "127.0.0.1" ]]; then
    safe_jq_write '.dns = {"servers":["https+local://1.1.1.1/dns-query","localhost"],"queryStrategy":"UseIPv4","disableCache":false}' "$CONFIG_FILE"
  fi

  # 6. Add freedom domainStrategy
  safe_jq_write '(.outbounds[] | select(.protocol == "freedom")) += {"settings":{"domainStrategy":"UseIPv4"}}' "$CONFIG_FILE"

  touch /usr/local/etc/xray/.config_v140_migrated
}
```

---

## Integration Points

### External Services

| Service | Integration Pattern | Notes |
|---------|---------------------|-------|
| AdGuard Home | DNS → 127.0.0.1 | Replaces built-in DNS. Already implemented. |
| Cloudflare DoH | `https+local://1.1.1.1/dns-query` | DOHL mode, bypasses routing |
| Loyalsoldier geo-data | `geoip.dat`, `geosite.dat` | Already downloaded in install.sh |
| UFW Firewall | Port management per inbound | Already implemented |
| systemd | `xray.service` management | Already implemented |

### Internal Boundaries

| Boundary | Communication | Notes |
|----------|---------------|-------|
| Xrayebator script <-> config.json | jq read/write via `safe_jq_write` | Well-structured, safe |
| config.json <-> Xray-core | Xray reads config on start/restart | Validate with `xray -test -config` |
| Profile JSONs <-> config.json | UUIDs must match | `update_all_profiles_on_port()` handles sync |
| DNS section <-> Routing | `IPIfNonMatch` triggers DNS resolution | DOHL mode avoids routing loops |
| Sniffing <-> Routing | `routeOnly` controls domain propagation | Must be `true` on server |

---

## Sources

### Official Documentation (HIGH confidence)
- [Xray Routing Configuration](https://xtls.github.io/en/config/routing.html) -- domainStrategy options, rule format
- [Xray Inbound Configuration](https://xtls.github.io/en/config/inbound.html) -- sniffing, destOverride, routeOnly
- [Xray DNS Configuration](https://xtls.github.io/en/config/dns.html) -- DOHL mode, queryStrategy, servers
- [Xray Freedom Outbound](https://xtls.github.io/en/config/outbounds/freedom.html) -- domainStrategy options
- [Xray Policy Configuration](https://xtls.github.io/en/config/policy.html) -- bufferSize, connection limits
- [Xray Log Configuration](https://xtls.github.io/en/config/log.html) -- loglevel, access log
- [Xray Server Guide (Chapter 7)](https://xtls.github.io/en/document/level-0/ch07-xray-server.html) -- complete server config example

### Official Examples (HIGH confidence)
- [XTLS/Xray-examples: VLESS-TCP-XTLS-Vision-REALITY/config_server.jsonc](https://github.com/XTLS/Xray-examples/blob/main/VLESS-TCP-XTLS-Vision-REALITY/config_server.jsonc) -- uses `routeOnly: true`

### Community Sources (MEDIUM confidence)
- [chika0801/Xray-examples#5](https://github.com/chika0801/Xray-examples/issues/5) -- UDP 443 block rationale
- [XTLS/Xray-core#1714](https://github.com/XTLS/Xray-core/issues/1714) -- performance tuning on heavy loads
- [XTLS/Xray-core Discussion#3518](https://github.com/XTLS/Xray-core/discussions/3518) -- VLESS+Reality setup guide (RU)
- [DeepWiki: Traffic Sniffing and Protocol Detection](https://deepwiki.com/XTLS/Xray-docs-next/8.2-traffic-sniffing-and-protocol-detection) -- routeOnly explained
- [Loyalsoldier/v2ray-rules-dat](https://github.com/Loyalsoldier/v2ray-rules-dat) -- enhanced geo-data

### Go Package Documentation (HIGH confidence)
- [xtls/xray-core/infra/conf](https://pkg.go.dev/github.com/xtls/xray-core/infra/conf) -- SniffingConfig struct definition, Policy struct

---
*Architecture research for: Xray config.json optimization for TSPU bypass*
*Researched: 2026-03-08*
