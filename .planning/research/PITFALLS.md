# Pitfalls Research: Xray Reality VPN Bypass in Russia

**Domain:** Automated Xray Reality VPN manager for DPI censorship bypass
**Researched:** 2026-03-08
**Confidence:** MEDIUM-HIGH (core findings from net4people issues, XTLS GitHub, Russia whitelist repos, Habr analysis; some detection specifics are LOW confidence due to rapidly evolving TSPU behavior)

---

## Critical Pitfalls

### Pitfall 1: Using Google/Yahoo/Apple SNI Domains (Instant Detection)

**What goes wrong:**
TSPU cross-references the SNI in the TLS ClientHello with the IP address of the destination server. When a client connects to a Hetzner/DigitalOcean/OVH IP using SNI `www.google.com`, the censor immediately flags this as suspicious because Google owns its own datacenters and never serves from third-party hosting IPs. The connection is blocked or throttled.

**Why it happens:**
Early Reality guides (including Xray-examples) recommended `www.google.com` or `www.yahoo.com` as default SNI values. Xrayebator currently defaults to `www.google.com` for gRPC profiles (line 650) and recommends it in the SNI change menu (line 1220: "www.google.com (recommended)"). These domains are the first ones TSPU learned to fingerprint because the IP-to-SNI mismatch is trivial to detect.

**How to avoid:**
- Never use SNI domains from companies that own their own datacenter infrastructure (Google, Yahoo, Apple, Facebook, Amazon, Microsoft Azure services)
- Use domains hosted on shared CDN infrastructure where many different IPs legitimately serve the same domain. Examples: medium-traffic sites behind Cloudflare, regional CDN-hosted sites
- For whitelist bypass scenarios, use domains from `whitelist.txt` (community-maintained list at `hxehex/russia-mobile-internet-whitelist`)
- The best SNI choices are sites that: (a) actually have a server in the same datacenter/ASN as your VPS, (b) support TLS 1.3 and H2, (c) are not on any blocklist
- Use the Hiddify Reality Scanner or manual `curl` testing to verify a potential SNI works from the same IP range

**Warning signs:**
- Profile suddenly stops working on mobile networks while wired ISP still works
- Connection drops within seconds of establishing tunnel
- `xray -test` passes but connections timeout from client
- Users report "connected but no traffic"

**Phase to address:** Phase 1 (Security Hardening) -- change default SNI selection logic, remove google.com/yahoo.com from recommendations, add SNI validation

**Confidence:** HIGH -- confirmed by net4people #490 comments, Reddit r/VPN threads (Nov 2025), Habr article "Clumsy Hands or New DPI", Xray-core issue #5332

**Sources:**
- https://github.com/net4people/bbs/issues/490 (upd3: SNI whitelist)
- https://www.reddit.com/r/VPN/comments/1p66fel/ ("All blocked VPS instances use google/yahoo SNI, which you should never do under any circumstances")
- https://github.com/XTLS/Xray-core/issues/5332 (user with www.google.com SNI blocked)
- https://github.com/hxehex/russia-mobile-internet-whitelist

---

### Pitfall 2: Vision Flow on Port 443 Creates Detectable TLS Connection Patterns

**What goes wrong:**
`xtls-rprx-vision` creates multiple parallel TLS connections to the same endpoint. TSPU on some home ISPs (MTS/MGTS Moscow, JustLan, LanInterCom, RTK Izhevsk -- as of November 2025) monitors the number of simultaneous TLS connections to a single endpoint on port 443. When this count exceeds a threshold, the connection is shaped or dropped entirely. The blocking lifts after ~60 seconds of no connections.

**Why it happens:**
Vision's design opens many TLS connections for multiplexing, which is atypical for normal HTTPS browsing where a browser uses HTTP/2 multiplexing over a single connection. The TSPU detects this many-connections-to-one-IP pattern specifically on port 443 because that's the standard HTTPS port where they can differentiate proxy traffic from regular browsing.

**How to avoid:**
- On port 443: remove `flow: "xtls-rprx-vision"` and enable mux instead. Mux multiplexes within one connection, which looks more natural
- Move Vision profiles to non-443 ports (8443, 2053, 9443) where this specific detection is not applied (confirmed working per net4people #546)
- For port 443, use transport types that don't use Vision flow: `tcp-mux` (flow="", mux enabled), `grpc` (inherently multiplexed), or `xhttp` (uses HTTP-based multiplexing)
- Xrayebator should default new profiles to `tcp-mux` on port 443, reserving Vision for alternative ports

**Warning signs:**
- Connection works briefly then drops after heavy traffic starts flowing
- Reconnection works after ~60 seconds of silence
- Problem affects port 443 but not alternative ports
- `curl` to the server's SNI target still works even when proxy is blocked

**Phase to address:** Phase 1 (Security Hardening) -- implement tcp-mux transport type, change default port 443 behavior

**Confidence:** HIGH -- confirmed by net4people #546, with specific ISP names and dates. Update on 15.11.2025 confirmed the fix: "flow should be removed, as well as mux should be applied"

**Sources:**
- https://github.com/net4people/bbs/issues/546 (primary source with ISP list, workarounds)
- https://habr.com/en/articles/990236/ ("The Magic of Port 443")

---

### Pitfall 3: 15-20KB TCP Connection Threshold Blocking (Mobile Networks)

**What goes wrong:**
On mobile networks (MTS, Megafon, Beeline, Yota, Tele2) and increasingly on wired ISPs (Rostelecom, regional providers), TSPU freezes any TCP connection to foreign IPs that transfers more than ~15-20KB of data within a single TCP connection. The connection is not RST'd -- it simply "freezes" (no more packets arrive). This affects ALL traffic to foreign datacenter IPs, not just proxy traffic.

**Why it happens:**
This is a broad-spectrum censorship mechanism targeting any substantial data transfer to foreign servers. It does not inspect payload -- it purely counts bytes per TCP connection. SSH/SFTP and RDP are sometimes exempted. The threshold varies by provider (15-20KB range). This method was deployed on mobile networks starting mid-2025, with rollout to wired ISPs in late 2025.

**How to avoid:**
- Use XHTTP transport with `downloadSettings` that splits upload/download across separate connections
- Enable mux to multiplex many streams into fewer connections (each connection still hits the limit, but smaller requests complete before the threshold)
- Use whitelisted SNI domains -- TSPU maintains a SNI-based whitelist that exempts matching connections from the threshold (net4people #490 upd3)
- CIDR whitelist: some IP ranges are exempted. Check with `hyperion-cs/dpi-checkers` tools
- For heavy traffic: consider intermediate server in Russia (Russian datacenter IPs have more lenient rules)
- Use zapret on client-side routers as a last resort (TCP desync techniques)

**Warning signs:**
- Large downloads (>20KB) fail or stall, while small requests succeed
- Same configuration works on wired ISP but fails on mobile
- Can be tested with `hyperion-cs/dpi-checkers` RU::TCP 16-20 browser checker
- SSH to the same server also throttled to ~2KB/s after ~10-20KB

**Phase to address:** Phase 2 (Transport Resilience) -- implement XHTTP downloadSettings, improve mux configuration, add SNI whitelist support

**Confidence:** HIGH -- extensively documented in net4people #490 with reproducible test methodology and browser-based checker tool

**Sources:**
- https://github.com/net4people/bbs/issues/490 (primary, includes checker tool link)
- https://github.com/hyperion-cs/dpi-checkers (test tools)
- https://github.com/XTLS/Xray-core/issues/4846 (feature request for XHTTP packet retransmission)

---

### Pitfall 4: uTLS Chrome Fingerprint Leakage (CVE-grade, Passive Detection)

**What goes wrong:**
A bug in the uTLS library (used by Xray for TLS fingerprint simulation) caused the ECH GREASE cipher suite to not match the actual CipherSuite in ClientHello when using the `chrome` fingerprint. This mismatch allows purely passive detection of uTLS-based connections with ~50% per-connection accuracy, but since proxy software creates many TCP connections, the effective detection rate reaches ~100%. This bug affected all versions from December 2023 through October 2025.

A second, lower-severity bug (CVE-2026-26995) affects `HelloChrome_120` fingerprint specifically -- padding extension incorrectly removed in non-PQ variant.

**Why it happens:**
Real Chrome browsers send ECH GREASE with cipher suites matching their actual TLS cipher preferences. uTLS was generating mismatched ECH GREASE, creating a reliable fingerprint distinguisher. The bug was fixed in utls commit `24bd1e05a788c1add7f3037f4532ea552b2cee07` and Xray released a patch.

**How to avoid:**
- Update Xray-core to the latest version (post October 2025 fix)
- If running old Xray versions, switch fingerprint from `chrome` to `firefox` (which was not affected by the ECH GREASE bug)
- Reality cannot disable uTLS (it's fundamental to the protocol), so updating is the only real fix for Reality users
- Do NOT use `random` or `randomized` fingerprints -- they can produce inconsistent behavior

**Warning signs:**
- Running Xray-core versions from 2023.12 through 2025.10
- Using `fingerprint: "chrome"` on old versions
- No warning in logs -- this is a passive detection vulnerability

**Phase to address:** Phase 1 (Security Hardening) -- add Xray version check, warn about outdated versions, update installer to latest Xray

**Confidence:** HIGH -- confirmed by Xray-core issue #5230, uTLS security advisory GHSA-7m29-f4hw-g2vx, CVE-2026-26995

**Sources:**
- https://github.com/XTLS/Xray-core/issues/5230
- https://github.com/refraction-networking/utls/security/advisories/GHSA-7m29-f4hw-g2vx
- https://github.com/refraction-networking/utls/security/advisories/GHSA-rrxv-pmq9-x67r (CVE-2026-26995)

---

### Pitfall 5: Empty shortIds Weakens Authentication (Active Probing Vulnerability)

**What goes wrong:**
Xrayebator currently generates all inbounds with `"shortIds": [""]` (empty string). ShortId is a pre-shared key component of Reality authentication. When empty, any client that knows the server's public key (which is embedded in every shared profile link) can connect without the additional shortId verification. This weakens the authentication layer and makes the server more susceptible to probing -- if a public key leaks, anyone can authenticate.

**Why it happens:**
Empty shortId is technically valid in Xray (the docs say "If set to an empty string, the client shortId can be empty"). However, it reduces the entropy of the authentication. With a proper hex shortId (e.g., `"0123456789abcdef"`), an active prober who somehow obtains the public key still needs to guess the shortId.

**How to avoid:**
- Generate random hex shortIds for each inbound (8-16 hex chars): `openssl rand -hex 8`
- Store shortId in profile JSON alongside other credentials
- Include shortId in generated VLESS links (`&sid=<shortId>` parameter)
- Generate different shortIds per user/profile for better isolation

**Warning signs:**
- `"shortIds": [""]` in config.json (current state of all Xrayebator inbounds)
- VLESS links contain `&sid=` with empty value
- No shortId field in profile JSON files

**Phase to address:** Phase 1 (Security Hardening) -- generate proper shortIds, migration for existing configs

**Confidence:** MEDIUM -- the theoretical risk is clear from Xray documentation. Practical exploitation in Russia is LOW confidence (TSPU doesn't appear to use public key enumeration currently), but it's a defense-in-depth issue that all serious guides recommend.

**Sources:**
- https://github.com/XTLS/Xray-examples/blob/main/VLESS-TCP-XTLS-Vision-REALITY/REALITY.ENG.md (official examples use non-empty shortIds)
- https://github.com/XTLS/Xray-core/discussions/1702 (testing methodology)

---

### Pitfall 6: No Config Validation Before Xray Restart

**What goes wrong:**
Xrayebator calls `systemctl restart xray` in 10+ places without ever running `xray -test -config /usr/local/etc/xray/config.json` first. If a jq operation produces malformed JSON (even with safe_jq_write, which only checks for non-empty output, not valid Xray config), the restart fails silently. Xray goes down, all users lose connectivity, and the operator must SSH in to debug.

**Why it happens:**
The original code assumed jq operations always produce valid configs. But valid JSON != valid Xray config. Missing required fields, wrong types (string port where number expected), conflicting transport settings -- all these pass jq but fail Xray validation.

**How to avoid:**
- Create a `safe_restart_xray()` function that:
  1. Runs `xray -test -config "$CONFIG_FILE"` first
  2. Only restarts if exit code is 0
  3. On failure: shows the error message, keeps the old config, does NOT restart
  4. Optionally backs up the working config before applying changes
- Replace all bare `systemctl restart xray` calls with `safe_restart_xray`
- Implement a rollback mechanism: save last known working config, restore on failure

**Warning signs:**
- `systemctl status xray` shows failed state after profile operations
- Users suddenly disconnect with no menu-visible error
- `journalctl -u xray` shows config parse errors

**Phase to address:** Phase 1 (Security Hardening) -- implement safe_restart_xray, replace all 10+ restart calls

**Confidence:** HIGH -- verified by grepping the codebase: zero instances of `xray -test` or `xray.*test.*config`

---

### Pitfall 7: Port 53 Publicly Exposed (Open DNS Resolver + Attack Vector)

**What goes wrong:**
When AdGuard Home is installed, Xrayebator opens port 53 on all interfaces (`0.0.0.0:53`) via UFW (`open_firewall_port 53` and `open_firewall_port 53 udp`). This creates an open DNS resolver accessible to the entire internet, which is: (a) a DDoS amplification attack vector -- attackers send DNS queries with spoofed source IPs, your server amplifies them; (b) a resource drain on the VPS; (c) makes the server look like a public service rather than a personal VPN server, drawing attention.

**Why it happens:**
AdGuard Home needs to listen on port 53 for DNS queries from Xray (which runs locally). But the firewall rule opens port 53 to ALL sources, not just localhost. Xray only needs DNS on `127.0.0.1:53`.

**How to avoid:**
- AdGuard Home should bind DNS listener to `127.0.0.1:53` (or `0.0.0.0:53` if needed for local network) but UFW should NOT open port 53 to the world
- Remove `open_firewall_port 53` and `open_firewall_port 53 udp` from AdGuard Home setup
- Xray config already points DNS to `127.0.0.1` -- external access is unnecessary
- If DNS needs to be served to VPN clients, use Xray's built-in DNS routing instead of exposing raw port 53

**Warning signs:**
- `nmap` from external host shows port 53 open
- `ufw status` shows 53/tcp ALLOW Anywhere and 53/udp ALLOW Anywhere
- Server appears in Shodan/Censys scans as open resolver
- Unexpected high bandwidth usage from DNS amplification

**Phase to address:** Phase 1 (Security Hardening) -- remove public port 53 exposure, bind AdGuard to localhost only

**Confidence:** HIGH -- verified in codebase (lines 2235-2236: `open_firewall_port 53` and `open_firewall_port 53 udp`)

**Sources:**
- https://www.reddit.com/r/pihole/comments/1707nxd/ (open resolver risks)
- https://vercara.digicert.com/resources/port-53-ddos-attack (port 53 DDoS amplification)

---

## Moderate Pitfalls

### Pitfall 8: Predictable gRPC serviceName and XHTTP Path

**What goes wrong:**
Xrayebator uses hardcoded `"serviceName": "grpc"` for gRPC transport and `"path": "/xhttp"` for XHTTP transport. These are the most commonly used defaults in tutorials and auto-install scripts. If TSPU ever compiles a signature of common proxy paths (as GFW did for Shadowsocks), these predictable values become instant identifiers.

**Why it happens:**
Default values were chosen for simplicity. The gRPC service path becomes `/${serviceName}/Tun` (i.e., `/grpc/Tun`), which is not a path any legitimate gRPC service would use. Similarly, `/xhttp` is a dead giveaway.

**How to avoid:**
- Generate random serviceName/path during profile creation: e.g., `serviceName` = random 8-12 alphanumeric string, path = `/` + random string
- Make them look like legitimate API paths: `/api/v2/stream`, `/rpc/DataService`, `/cdn/chunk`
- Store the generated values in profile JSON for client configuration
- Different paths per inbound (currently all gRPC inbounds share "grpc")

**Warning signs:**
- Multiple public tools/scripts using identical paths
- TSPU starts blocking connections with specific gRPC service names (hasn't happened yet, but GFW precedent exists)

**Phase to address:** Phase 2 (Transport Resilience) -- randomize paths, migration for existing configs

**Confidence:** MEDIUM -- the predictability is factual, but no evidence that TSPU currently fingerprints specific paths. However, GFW has done this for other protocols, so it's a reasonable precaution.

---

### Pitfall 9: SNI-to-IP Mismatch Detection (Beyond Just Google)

**What goes wrong:**
TSPU increasingly cross-references not just "big tech" SNIs but any SNI where the IP address doesn't match legitimate hosting for that domain. Even using a medium-traffic site as SNI can be detected if the site's real IP range is publicly known and your VPS is clearly outside it.

**Why it happens:**
Operators are moving from SNI-only checks to combined `SNI + CIDR` whitelisting (confirmed in net4people #490 upd4 and russia-mobile-internet-whitelist repo). Under this model, even a "good" SNI fails if the server IP isn't in the whitelist.

**How to avoid:**
- Use Reality Scanner to find domains that are actually hosted in your VPS provider's datacenter/ASN
- Monitor community whitelists (`hxehex/russia-mobile-internet-whitelist` `whitelist.txt` and `cidrwhitelist.txt`)
- Best practice: find a website that genuinely serves from an IP in your VPS's subnet (or nearby subnet in the same ASN)
- For CIDR whitelist bypass: intermediate server in Russia with a whitelisted IP, or CDN fronting via Cloudflare
- Implement SNI rotation capability in Xrayebator

**Warning signs:**
- Profile works on wired ISP but fails on mobile networks
- Same SNI works from one region but not another (whitelists vary by operator and region)
- Connection works briefly after SNI change but stops again within days

**Phase to address:** Phase 2 (Transport Resilience) -- SNI management improvements, whitelist integration

**Confidence:** HIGH for the mechanism, MEDIUM for specific SNI recommendations (vary by region, operator, time)

**Sources:**
- https://github.com/net4people/bbs/issues/490 (upd3, upd4: SNI + CIDR whitelisting)
- https://github.com/hxehex/russia-mobile-internet-whitelist (community whitelist)
- https://www.arctictoday.com/the-new-russian-internet-closed-censored-and-secure/ (whitelist composition)

---

### Pitfall 10: Running Xray as Root

**What goes wrong:**
Xray-core defaults to running as `nobody` user (documented in official guide chapter 7). However, Xrayebator requires root to run (line 29: `if [[ $EUID -ne 0 ]]`) and likely installs Xray with a systemd unit that runs as root. If Xray-core has a vulnerability, an attacker gains root access to the entire server.

**Why it happens:**
Running as root simplifies file permissions (reading keys, writing configs, managing UFW). The script itself needs root for system administration tasks, but the Xray daemon does not.

**How to avoid:**
- Configure systemd service to run Xray as dedicated user (e.g., `xray` or `nobody`)
- Set proper file permissions on config.json, keys, profiles (readable by xray user)
- Keep the management script (xrayebator) requiring root, but separate from the daemon's runtime privileges
- Use `User=nobody` and `CapabilityBoundingSet=CAP_NET_BIND_SERVICE` in systemd unit for binding to ports <1024

**Warning signs:**
- `ps aux | grep xray` shows xray running as root
- systemd unit file has no `User=` directive
- Key files owned by root with 644 permissions (should be 640 or 600)

**Phase to address:** Phase 1 (Security Hardening) -- create xray user, update systemd unit, fix permissions

**Confidence:** HIGH -- Xray official docs explicitly recommend running as nobody user

**Sources:**
- https://xtls.github.io/en/document/level-0/ch07-xray-server.html ("Xray defaults to running as the nobody user")

---

### Pitfall 11: DNS Configuration Exposing VPN Usage

**What goes wrong:**
If the client's DNS resolution happens outside the VPN tunnel (DNS leak), the ISP sees the user resolving youtube.com, discord.com, etc. -- instantly revealing VPN usage for accessing blocked content. On the server side, if Xray's DNS is misconfigured, it may use the system's default resolver (often the ISP's), which can be monitored.

**Why it happens:**
Client-side DNS leaks are common with v2rayNG and other clients that don't properly configure sniffing/DNS interception. Server-side, Xrayebator configures DoH but with no fallback strategy -- if the DoH endpoint (e.g., Cloudflare) is temporarily blocked, DNS resolution fails entirely.

**How to avoid:**
- Server-side: configure multiple DNS servers with fallback chain (e.g., DoH primary, plain DNS to localhost secondary)
- Enable `sniffing.enabled: true` with `destOverride: ["http", "tls"]` on all inbounds (Xrayebator already does this)
- Client-side: ensure the client app has DNS configured to resolve through the proxy, not locally
- Consider running local DNS resolver (Unbound or AdGuard Home on localhost) as fallback when DoH is blocked
- Block direct DNS queries (port 53 outbound) at the firewall level for VPN clients

**Warning signs:**
- DNS leak test sites (dnsleaktest.com, ipleak.net) show ISP's DNS servers
- Server logs show DNS timeouts when DoH endpoint is unreachable
- Users report "connected but nothing loads" (DNS resolution failure)

**Phase to address:** Phase 2 (Transport Resilience) -- implement DNS fallback chain, document client-side DNS configuration

**Confidence:** MEDIUM -- DNS leaks are well-documented generic VPN issue, specific to Xray configuration patterns

**Sources:**
- https://github.com/XTLS/Xray-core/issues/2715 (DNS config discussion)
- https://ntc.party/t/xray-настройка-перехвата-dns/12820 (DNS interception in Xray)
- https://www.reddit.com/r/dumbclub/comments/1dmbxj7/ (DNS leak with Reality)

---

### Pitfall 12: XHTTP Extra Settings Wiped by Migrations

**What goes wrong:**
A previous Xrayebator migration (`migrate_xhttp_mode()`) had a bug that wiped the `extra` field in `xhttpSettings` when setting `mode: "auto"`. This removed anti-DPI settings like `xmux`, `noSSEHeader`, `scMaxEachPostBytes`, and `scMinPostsIntervalMs`. Although fixed in the latest commit (f943024), the pattern of destructive migrations is a systemic risk.

**Why it happens:**
jq replacements that set one field can accidentally discard sibling fields if the jq expression reconstructs the parent object instead of modifying in-place. The `safe_jq_write` function catches empty output but not semantic data loss.

**How to avoid:**
- Use jq's `|=` (update) operator instead of `=` (set) when modifying nested objects
- Always test migration functions against configs with and without optional fields
- Add a config backup step before ANY migration (`cp config.json config.json.bak.<timestamp>`)
- Add integration tests: known input config -> migration -> verify all fields preserved
- Migration `migrate_xhttp_extra_restore()` already fixes this, but future migrations need the same discipline

**Warning signs:**
- After update, XHTTP transport loses anti-DPI tuning
- `jq '.inbounds[].streamSettings.xhttpSettings.extra' config.json` returns empty or null
- Users report XHTTP connections become less reliable after update

**Phase to address:** Phase 1 (Security Hardening) -- add config backup before migrations, improve migration testing

**Confidence:** HIGH -- verified in git history (commit f943024 explicitly fixes this)

---

## Minor Pitfalls

### Pitfall 13: QUIC Globally Blocked Kills HTTP/3 Performance

**What goes wrong:**
Xrayebator's routing blocks all QUIC/UDP-443 traffic via routing rules. While this prevents QUIC-based fingerprinting, it also means that clients behind the VPN cannot use HTTP/3 for any website, resulting in unnecessary fallback to HTTP/2 and degraded performance for modern websites that prefer QUIC.

**How to avoid:**
- Make QUIC blocking configurable rather than mandatory
- For most Russian users, QUIC is already blocked or throttled by ISPs, so the routing rule is redundant
- Document the trade-off: QUIC leaks can reveal browsing patterns, but blocking it reduces performance

**Phase to address:** Phase 3 (UX/Features) -- make QUIC blocking optional per-profile

---

### Pitfall 14: Inconsistent Whitelist Evolution Across Regions

**What goes wrong:**
The Russian censorship landscape is not uniform. Different mobile operators (MTS, Megafon, Beeline, Tele2, Yota), different regions (Moscow, Irkutsk, Tver, Urals, Far East), and even different cell towers can have different whitelist policies. What works in Moscow may not work in Irkutsk. What works on MTS may not work on Tele2.

**How to avoid:**
- Xrayebator should support multiple profiles with different configurations for the same user
- Implement "connection test" functionality that verifies a profile works
- Allow rapid SNI switching without re-creating profiles
- Document that users may need region-specific configurations
- Link to community resources (discord, hxehex/russia-mobile-internet-whitelist)

**Phase to address:** Phase 3 (UX/Features) -- multi-profile support, connection testing

**Confidence:** HIGH -- extensively documented in whitelist repo README and net4people discussions

---

### Pitfall 15: Profile Links Containing Sensitive Data Shared Insecurely

**What goes wrong:**
VLESS profile links contain UUID, public key, server IP, port, and all connection parameters in plaintext URL format. Users share these via unencrypted channels (Telegram chats, email), exposing the server to anyone who intercepts the link. Combined with empty shortIds, anyone with the link can use the server.

**How to avoid:**
- Generate proper shortIds (see Pitfall 5) so links alone aren't sufficient
- Add expirable invite links or time-limited tokens
- Document secure sharing practices (encrypted messaging, QR codes in person)
- Consider subscription URL model (profile URL that can be revoked server-side)

**Phase to address:** Phase 3 (UX/Features) -- subscription URLs, revocable access

---

## Technical Debt Patterns

| Shortcut | Immediate Benefit | Long-term Cost | When Acceptable |
|----------|-------------------|----------------|-----------------|
| Empty shortIds `[""]` | Simpler profile generation, no need to sync shortId with client | Weakened authentication, easier server enumeration if public key leaks | Never -- shortId generation is trivial |
| Hardcoded gRPC/XHTTP paths | No randomization logic needed | Predictable paths become fingerprint signatures if widely deployed | MVP only, must randomize before v2.0 |
| No config validation before restart | Faster operations, fewer shell dependencies | Silent Xray downtime on bad config, all users disconnected | Never -- `xray -test` is a single command |
| All transports on all ports | Simplified menu flow | Vision on 443 detected, lack of transport-port optimization | MVP only, needs transport-aware defaults |
| Root-level Xray daemon | No permission issues with keys/configs | Full system compromise if Xray is exploited | Never for production servers |
| Single-file 2300-line bash script | Easy to deploy, no dependencies | Difficult to test, maintain, or add features; migration bugs | Acceptable for current scope, but approaching limit |

## Integration Gotchas

| Integration | Common Mistake | Correct Approach |
|-------------|----------------|------------------|
| AdGuard Home DNS | Opening port 53 to world via UFW | Bind to 127.0.0.1 only, no UFW rule for 53 |
| v2rayNG client | Not enabling sniffing/DNS override, causing DNS leaks | Configure DNS through proxy, enable sniffing in client |
| Cloudflare CDN (future) | Running heavy traffic through free plan CDN | Use CDN only as emergency fallback, main traffic direct |
| Reality dest server | Using unreachable or slow dest server | Verify dest server is reachable and fast from VPS IP with `curl -I https://dest:443` |
| UFW firewall | Forgetting to open new ports when changing from 443 | `open_firewall_port` before creating inbound, verify with `ufw status` |
| XHTTP host field | SNI in `realitySettings.serverNames` but not in `xhttpSettings.host` | Both MUST match -- `update_transport_settings_for_sni()` handles this |

## Security Mistakes

| Mistake | Risk | Prevention |
|---------|------|------------|
| Empty shortIds | Server accessible to anyone with the public key | Generate random hex shortIds per inbound |
| Port 53 open to world | DDoS amplification attacks, bandwidth drain, unwanted attention | Bind AdGuard DNS to localhost, no public UFW rule |
| Xray running as root | Full server compromise on Xray vulnerability | Run Xray as `nobody`/`xray` user with minimal capabilities |
| No rate limiting on failed connections | Active probing goes undetected | Monitor `"processed invalid connection"` log entries |
| Key files with 644 permissions | Anyone on the server can read Reality private key | 600 permissions, owned by xray user |
| google.com as SNI | Instant detection by TSPU IP-SNI mismatch | Use CDN-hosted domains from the same datacenter |

## Performance Traps

| Trap | Symptoms | Prevention | When It Breaks |
|------|----------|------------|----------------|
| DoH-only DNS with no fallback | All DNS fails when DoH endpoint blocked | Add plain DNS to localhost as fallback | When Cloudflare/Google DoH is throttled by TSPU |
| Vision on 443 without mux | Many TLS connections trigger TSPU shaping | Use mux on 443, Vision on alt ports | Immediately on ISPs with TLS connection policing |
| Single VPS IP, no CDN | One IP block = total outage | Prepare CDN fallback profile | When VPS ASN gets CIDR-blocked |
| Heavy XHTTP without `xmux` settings | Excessive connection overhead | Configure `maxConcurrency: "16-32"`, `cMaxLifetimeMs` | At sustained >10Mbps throughput |

## "Looks Done But Isn't" Checklist

- [ ] **Profile creation:** Often missing shortId -- verify `"shortIds"` in inbound is not `[""]`
- [ ] **SNI change:** Often misses XHTTP host update -- verify `xhttpSettings.host` matches `realitySettings.serverNames`
- [ ] **Transport change:** Often keeps wrong flow value -- verify Vision profiles have `"xtls-rprx-vision"`, mux/grpc/xhttp have `""`
- [ ] **Firewall:** Often opens ports but never closes them -- verify deleted inbound's ports are closed in UFW
- [ ] **Config edit:** Often restarts xray without validation -- verify `xray -test -config config.json` passes
- [ ] **AdGuard install:** Often exposes port 53 publicly -- verify `ufw status | grep 53` shows no public rules
- [ ] **Xray update:** Often doesn't check for uTLS vulnerability -- verify xray version is post-October 2025
- [ ] **Migration:** Often wipes optional config fields -- verify `extra` settings in XHTTP are preserved

## Recovery Strategies

| Pitfall | Recovery Cost | Recovery Steps |
|---------|---------------|----------------|
| Bad SNI choice (detected) | LOW | Change SNI in config and all profiles, restart xray, update client configs |
| Vision on 443 blocked | LOW | Remove flow, add mux settings, restart. Or change port to 8443/9443 |
| uTLS fingerprint leak | LOW | Update xray-core, or switch fingerprint to `firefox` |
| Config corruption (no validation) | MEDIUM | Restore from backup (if exists), or manually fix JSON, or re-run install |
| Port 53 DDoS amplification | MEDIUM | Close UFW port 53, bind AdGuard to localhost, check for abuse complaints |
| Empty shortId exploited | MEDIUM | Generate new shortIds, update all client profiles, redistribute links |
| Root Xray compromised | HIGH | Full server reinstall, rotate all keys, new server IP recommended |
| CIDR whitelist blocks VPS IP | HIGH | No server-side fix. Need CDN fallback or Russian intermediate server |

## Pitfall-to-Phase Mapping

| Pitfall | Prevention Phase | Verification |
|---------|------------------|--------------|
| Google/Yahoo SNI | Phase 1: Security Hardening | `grep -c "google\|yahoo" config.json` returns 0 |
| Vision on 443 | Phase 1: Security Hardening | Port 443 inbounds have `flow: ""` + mux OR use non-Vision transport |
| 15-20KB threshold | Phase 2: Transport Resilience | XHTTP downloadSettings configured, mux enabled on TCP profiles |
| uTLS fingerprint | Phase 1: Security Hardening | `xray version` shows post-2025.10 release |
| Empty shortIds | Phase 1: Security Hardening | `jq '.inbounds[].streamSettings.realitySettings.shortIds' config.json` shows non-empty hex values |
| No config validation | Phase 1: Security Hardening | All `systemctl restart xray` replaced with `safe_restart_xray` |
| Port 53 exposed | Phase 1: Security Hardening | `ufw status` shows no public 53 rules |
| Predictable paths | Phase 2: Transport Resilience | gRPC serviceName and XHTTP path are randomized |
| SNI+CIDR mismatch | Phase 2: Transport Resilience | SNI validation checks domain is reachable from VPS IP |
| Root Xray daemon | Phase 1: Security Hardening | `ps aux | grep xray` shows non-root user |
| DNS leaks | Phase 2: Transport Resilience | DNS fallback chain configured, no DoH-only dependency |
| Migration data loss | Phase 1: Security Hardening | Config backup before migrations, test preservation of optional fields |
| Regional whitelist inconsistency | Phase 3: UX/Features | Multi-profile support, connection test function |
| Insecure profile sharing | Phase 3: UX/Features | Subscription URLs, shortId required |

## Sources

### Primary (HIGH confidence)
- [net4people/bbs#490](https://github.com/net4people/bbs/issues/490) -- TCP 15-20KB blocking, SNI+CIDR whitelisting mechanism
- [net4people/bbs#546](https://github.com/net4people/bbs/issues/546) -- TLS connection-based policing, Vision detection on port 443
- [XTLS/Xray-core#5230](https://github.com/XTLS/Xray-core/issues/5230) -- uTLS Chrome fingerprint leakage (CVE-grade)
- [XTLS/Xray-core#5332](https://github.com/XTLS/Xray-core/issues/5332) -- TCP Reality blocking with Google SNI
- [refraction-networking/utls GHSA-7m29-f4hw-g2vx](https://github.com/refraction-networking/utls/security/advisories/GHSA-7m29-f4hw-g2vx) -- ECH GREASE mismatch
- [refraction-networking/utls GHSA-rrxv-pmq9-x67r](https://github.com/refraction-networking/utls/security/advisories/GHSA-rrxv-pmq9-x67r) -- Chrome 120 padding (CVE-2026-26995)
- [hyperion-cs/dpi-checkers](https://github.com/hyperion-cs/dpi-checkers) -- DPI detection tools and methodology
- [hxehex/russia-mobile-internet-whitelist](https://github.com/hxehex/russia-mobile-internet-whitelist) -- Community-maintained SNI+CIDR whitelists
- [Xray official docs ch07](https://xtls.github.io/en/document/level-0/ch07-xray-server.html) -- Running Xray as nobody user

### Secondary (MEDIUM confidence)
- [Habr: "Clumsy Hands or New DPI"](https://habr.com/en/articles/990236/) -- Port 443 specific blocking analysis (Feb 2026)
- [Reddit r/VPN: Information about Russia blocking VLESS](https://www.reddit.com/r/VPN/comments/1p66fel/) -- Google/Yahoo SNI confirmed blocked (Nov 2025)
- [Reddit r/VPN: VLESS/Reality mobile issues](https://www.reddit.com/r/VPN/comments/1ogn5cs/) -- MTS/Megafon mobile blocking with ozon.ru SNI
- [ArcticToday: New Russian Internet](https://www.arctictoday.com/the-new-russian-internet-closed-censored-and-secure/) -- Whitelist composition details (Dec 2025)
- [Carnegie: Kremlin Internet Crackdown](https://carnegieendowment.org/russia-eurasia/politika/2025/12/russia-internet-restrictions) -- Whitelist policy analysis
- [Meduza: VLESS blocking tests](https://meduza.io/news/2025/11/24/v-rossii-nachali-testirovat-blokirovku-odnogo-iz-samyh-populyarnyh-vpn-protokolov) -- Nov 2025 blocking confirmation
- [ntc.party: XRay DNS interception](https://ntc.party/t/xray-настройка-перехвата-dns/12820) -- DNS configuration pitfalls

### Codebase Analysis (HIGH confidence -- verified in source)
- Xrayebator source: `shortIds: [""]` on all 4 inbound templates (lines 836, 865, 895, 939)
- Xrayebator source: `serviceName: "grpc"` hardcoded (line 888)
- Xrayebator source: `path: "/xhttp"` hardcoded (line 920)
- Xrayebator source: `www.google.com` as default/recommended SNI (lines 650, 1220, 1229)
- Xrayebator source: zero instances of `xray -test` before restart
- Xrayebator source: `open_firewall_port 53` for AdGuard Home (lines 2235-2236)
- Git history: commit f943024 fixes XHTTP extra settings wiped by migration

---
*Pitfalls research for: Xray Reality VPN bypass in Russia*
*Researched: 2026-03-08*
