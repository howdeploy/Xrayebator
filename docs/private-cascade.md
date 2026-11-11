# Private cascade through a Russian VPS

[← Back to README](../README.md) · [Русский](ru/private-cascade.md)

## Topology

Use two VPSs. A private client connects to the Russian ingress. The ingress sends selected Russian TCP destinations directly and forwards other TCP and supported application UDP over VLESS REALITY to the foreign egress.

| VPS | Role | Address required |
|---|---|---|
| Russian ingress, for example in Moscow | Receives client connections and sends explicitly selected traffic out in Russia | A public address reachable by the clients and a stable, known source address for the connection to the foreign VPS |
| Foreign egress | Accepts the cascade connection from the Russian VPS and sends forwarded traffic to the internet | A public listener address reachable from the Russian VPS and working outbound connectivity for the destinations clients need |

One public IPv4 per VPS can cover these roles. The foreign listener and its public internet egress can share an address. The article's full design separates the foreign listener and final exit using another address, a gateway, or WARP. It makes an explicit exception for Russian destinations, which see the ingress public IP when routed direct. The article's explanation of how addresses are discovered and blocked is the author's hypothesis. [Habr article, section 4](https://habr.com/ru/articles/1103460/)

## Before changing either VPS

1. Check both providers' terms for the intended proxy use. Record the actual public addresses, the source address the egress will see after any provider NAT, the ports, and the path for emergency console access. Check SSH host keys independently. Use the supported OS matrix in [VPS recommendations](recommendations.md#choosing-a-vps).
2. Confirm the client network can reach the Russian listener over IPv4. For the hop between servers, use IPv4 with a source-scoped firewall or IPv6 if the route, listener, and firewall work end to end. Also check that the foreign VPS can reach IPv4 destinations if clients need them, regardless of the family used for the hop.
3. Record the current Xray routes and profiles, backends, listeners, provider firewall and host firewall. Take protected backups or snapshots and keep a separate administrative session. Use a maintenance window if preparing either node requires restarting an existing service or changing an active listener.
4. Reserve a dedicated TCP listener on the foreign VPS. At the provider firewall, allow its port only from the Russian VPS's observed source IP (`/32` for IPv4 or `/128` for IPv6). Apply equivalent restrictions on the host and check for broader allows, including those added by Xrayebator. Preserve existing SSH, subscription, and client listener rules. Set the provider restriction before creating the foreign inbound because the manager can open the listener port in UFW.
5. Keep SSH access, REALITY key pairs, and certificate keys separate per host. Issue a dedicated VLESS credential for the ingress-to-egress hop. Give clients only their ingress profile and keep the upstream link or UUID on the two hosts that need it. Store DNS credentials with root-only access and use the narrowest permissions available. Redact links and tokens from logs or handoffs.

On fresh VPSs, install Xrayebator on both hosts. This example requires only Xray. If either host already runs optional backends, check their profile grants after creating a profile because Xrayebator applies profile lifecycle events to installed backends. [Installation](../README.md#installation)

Both nodes require Xray-core 26.6.27 or newer for the destination restrictions below. Use the reviewed Xrayebator version that includes `profile-create --without-pq` and `private-cascade`. When testing a newer checkout, replace `sudo xrayebator` in the commands below with `sudo bash ./xrayebator` from that checkout on each host.

## Hostnames, certificates, and REALITY

- Prefer a domain you already control. Use separate names such as `ingress.example.com` and `egress.example.com`. Point each `A` record to the corresponding public IPv4 and publish `AAAA` only after verifying IPv6 reachability and firewall scope. Use DNS-only records where a provider offers proxying. A VPS provider's default hostname works for this purpose only if you can verify the necessary DNS control and obtain a matching certificate with working renewal.
- With the standard REALITY decoy, keep the working target and SNI already configured by Xrayebator and dial each VPS by IP. This setup needs no new DNS account or certificate for the tunnel.
- The cascade dial address can be a reachable IP or a hostname. An IP certificate can serve the subscription HTTPS endpoint. For self-steal, set REALITY SNI to the hostname covered by the certificate on the loopback TLS target, and match the XHTTP `host` to it when using XHTTP. [Domain and DNS](configuration.md#domain-and-dns) · [Self-steal](configuration.md#custom-domain-and-self-steal-stub)
- For closed-port self-steal, use your DNS provider's ACME plugin in certificate-only mode, configure the loopback TLS site and add a deploy hook that reloads its TLS service after renewal. Verify the matching certificate on the loopback listener. The built-in `dns01-setup` configures a subscription listener for Cloudflare or Route 53. Use it only if you also intend to publish that subscription, and pass its secret through a file or stdin. [DNS-01](configuration.md#dns-01-certificate-and-subscription-domain-without-port-80)

## Prepare the foreign egress

On the foreign VPS, create the dedicated legacy XHTTP profile with `sudo xrayebator profile-create --name private-cascade-egress --transport xhttp --without-pq --port 25443`. Check that `names` includes the new profile and `errors` is empty. Export its XHTTP URI privately from the profile menu. Preserve the actual `path`, `host` and `mode` values. Put an IPv6 dial address in square brackets.

```text
vless://<uuid>@<egress-address>:<port>?encryption=none&security=reality&type=xhttp&sni=<sni>&fp=<fingerprint>&pbk=<public-key>&sid=<short-id>&host=<host>&path=<url-encoded-path>&mode=<mode>
```

TCP Vision is also supported. Use `--transport tcp` without `--without-pq` on a free non-443 port and keep `flow=xtls-rprx-vision` in the exported URI. With this flow Xray rejects UDP sessions opened to port 443 on the foreign route. Browsers can retry HTTPS over TCP when HTTP/3 is unavailable. The XHTTP example supports application UDP/443.

Verify the restricted listener from both the ingress and a source outside its allowlist. Confirm the foreign node has a working internet egress. [Standard cascade](configuration.md#cascade-and-upstream-nodes)

The foreign VPS resolves forwarded names independently. Enforce the public IPv4 policy at its exit, including for each UDP packet. Save a protected backup of its config, then append this dedicated outbound to `outbounds`. Both IPv4 strategy fields keep the configuration compatible with the supported core versions. Add any provider metadata addresses outside the private set to the block list.

```json
{
  "tag": "private-cascade-exit",
  "protocol": "freedom",
  "settings": {
    "domainStrategy": "ForceIPv4",
    "finalRules": [{"action": "block", "ip": ["geoip:private", "::/0"]}]
  },
  "streamSettings": {"sockopt": {"domainStrategy": "ForceIPv4"}}
}
```

These restrictions apply to client destinations. The connection between VPSs can still use IPv6.

In the foreign node's `routing.rules`, insert this rule after the existing block rules and before the first general forwarding rule that matches the cascade inbound, including the TCP/UDP catch-all. Replace `inbound-25443` with the actual inbound tag if you used a different port or profile.

```json
{
  "type": "field",
  "inboundTag": ["inbound-25443"],
  "outboundTag": "private-cascade-exit"
}
```

Validate the edited foreign config with `sudo /usr/local/bin/xray run -test -config /usr/local/etc/xray/config.json`. After a successful check, restart its Xray service in the maintenance window and confirm this inbound selects `private-cascade-exit`. On validation or restart failure, restore and validate the backup before restoring service. In a single XUDP association, send a datagram to a controlled, permitted IPv4 endpoint, then a datagram to a controlled, prohibited endpoint. Confirm that the first arrives and the second does not. Verify the restrictions for both literal addresses and names that resolve to them.


## Prepare the routing lists

The example below uses the installed `geosite.dat` for Russian categories and the compact Re-filter domain and IP lists for blocked destinations. Before updating existing list files, save their hashes and protected backups. Download both assets from one release and verify GitHub's published SHA-256 digests before installing them. [Re-filter sources](https://github.com/1andrevich/Re-filter-lists)

```bash
(
  set -eu
  stage=$(mktemp -d)
  trap 'rm -rf -- "$stage"' EXIT
  curl -fsSL https://api.github.com/repos/1andrevich/Re-filter-lists/releases/latest \
    -o "$stage/release.json"
  for kind in geoip geosite; do
    name="$kind.dat"
    url=$(jq -er --arg name "$name" '.assets[] | select(.name == $name) | .browser_download_url' "$stage/release.json")
    hash=$(jq -er --arg name "$name" '.assets[] | select(.name == $name) | .digest | select(test("^sha256:[a-f0-9]{64}$")) | ltrimstr("sha256:")' "$stage/release.json")
    curl -fsSL "$url" -o "$stage/$name"
    printf '%s  %s\n' "$hash" "$stage/$name" | sha256sum -c -
  done
  sudo install -o root -g xray -m 0644 "$stage/geoip.dat" /usr/local/share/xray/refilter-geoip.dat
  sudo install -o root -g xray -m 0644 "$stage/geosite.dat" /usr/local/share/xray/refilter-geosite.dat
)
```

Keep the installed country data and its `geoip:private` and `geoip:ru` categories. The policy uses `geosite:available-only-in-ru` and `geosite:category-ru` from the installed domain data. If these categories are absent, update or select reviewed data before rendering. Revalidate a new candidate whenever lists change. If a list update fails, restore its previous files before restarting a running cascade.

## Render and start the ingress

On the Russian VPS, choose a working VLESS REALITY TCP or legacy XHTTP inbound with `decryption=none` and an empty VLESS `fallbacks` list. On a fresh installation, reserve a free template port and keep it closed at the provider firewall. Run `sudo xrayebator profile-create --name private-cascade-template --transport xhttp --without-pq --port 15442` and check that `names` includes the template and `errors` is empty. This creates `inbound-15442` in the main Xray configuration. The standalone service will listen on its own port, `15443` in this example.

Generate a fresh UUID with `uuidgen` for the standalone ingress. Create two root-owned `0600` files inside a root-only directory such as `/root/xrayebator-private-cascade/`. Write the single upstream URI to `upstream.txt`, and fill `policy.json` using this example. Replace the inbound tag, UUID and example destinations with your own values.

```json
{
  "inbound_tag": "inbound-15442",
  "client_id": "<cascade-client-uuid>",
  "listen": "0.0.0.0",
  "port": 15443,
  "russia_only_domains": ["geosite:available-only-in-ru"],
  "blocked_domains": ["ext:refilter-geosite.dat:refilter"],
  "blocked_ips": ["ext:refilter-geoip.dat:refilter"],
  "russian_domains": ["domain:ru", "domain:su", "domain:xn--p1ai", "geosite:category-ru"],
  "russian_ips": ["geoip:ru"]
}
```

Choose a free TCP port and open it at both ingress firewalls for the intended client sources. Both `blocked_domains` and `blocked_ips` are required arrays, with at least one entry between them. Optional arrays `russia_only_domains`, `russian_domains`, and `russian_ips` define direct routes. The defaults for the latter two are `.ru`/`.рф` and `geoip:ru`. Use Xray selectors matching your deployed assets. `ext:` rules require their corresponding local data files. The renderer reads those assets from the host and performs no downloads.

Use an empty array to disable an optional route list. Omitting an optional field uses its default.

The ingress blocks private and IPv6 destinations matched by its IP rules. Sniffing preserves a client-supplied address in those denied sets. For other TCP connections, a sniffed name becomes the destination that Xray actually connects to. A recognized Russia-only name takes precedence over the blocked lists, whether the client originally sent that name or its public IP. The blocked lists take precedence over the general Russian rules. The direct outbounds resolve names using IPv4 only and recheck destination IPs at dial time. A route selected by `russian_ips` can only connect to those IPs. If a later DNS lookup conflicts with the selected direct route, the connection fails.

After DNS interception and the destination blocks, all application UDP takes the foreign route. XUDP can change destinations within one association, so direct access is limited to TCP. If the foreign hop fails, the foreign-routed traffic stops. Direct Russian TCP and the ingress DNS remain available.

The ingress uses service DoH with a local resolver fallback. Configure the client to send its DNS to `192.0.2.53:53` inside VLESS. The virtual address is reserved for DNS on port 53. Disable client-side fallback to direct or another profile.

```bash
sudo xrayebator private-cascade render \
  --policy-file /root/xrayebator-private-cascade/policy.json \
  --upstream-file /root/xrayebator-private-cascade/upstream.txt \
  --output /root/xrayebator-private-cascade/ingress.json
```

To try a reviewed checkout whose renderer is newer than the installed manager, use `sudo bash ./xrayebator private-cascade render` with the same arguments from that checkout.

The renderer creates a single client with the new UUID and takes the flow from the template inbound's first client. It preserves the inbound's transport and REALITY settings, validates with `xray run -test` and writes a new root-owned `0600` file. Choose an unused service directory for first installation.

```bash
sudo install -d -o root -g xray -m 0750 /etc/xray-private-cascade
sudo install -o root -g xray -m 0640 /root/xrayebator-private-cascade/ingress.json \
  /etc/xray-private-cascade/config.json
```

Create `/etc/systemd/system/xray-private-cascade.service` as root. The bind capability also supports a free privileged ingress port such as 443. This example uses the standard Xrayebator binary and asset paths.

```ini
[Unit]
Description=Xray private cascade ingress
Wants=network-online.target
After=network-online.target

[Service]
User=xray
Group=xray
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
Environment=XRAY_LOCATION_ASSET=/usr/local/share/xray
ExecStart=/usr/local/bin/xray run -config /etc/xray-private-cascade/config.json
Restart=on-failure

[Install]
WantedBy=multi-user.target
```

```bash
sudo systemctl daemon-reload
sudo systemctl start xray-private-cascade.service
sudo systemctl status --no-pager xray-private-cascade.service
ss -ltn 'sport = :15443'
```

Use the template inbound's first client URI as a private reference. Replace its UUID with the new ingress UUID and set the dial address and port to the standalone listener. Keep the REALITY fields, flow, fingerprint, and transport options, including the XHTTP host, path and mode if present. Import it as a separate test profile. Rotate its UUID in the standalone config and issue a new link when needed.

## Verify or roll back the cascade

1. From a desktop or command-line client on the intended network, verify the REALITY connection and send a few small HTTPS and DNS requests. Use controlled endpoints or destination-side logs to confirm that an explicit Russian route sees the Russian source IP and an unmatched route sees the foreign source IP. Check a Russia-only name whose public IPv4 also matches `blocked_ips` both by name and by IP with the same SNI. Both should reach the actual Russia-only destination directly. A general Russian name resolving to a blocked IP must take the foreign path.
2. In a maintenance window, briefly withdraw only the dedicated foreign hop and open fresh test connections. Confirm that a direct Russian TCP request and a virtual DNS query still work. Confirm that foreign TCP and application UDP fail, including when two datagrams in one XUDP association address different destinations. Use controlled endpoints to confirm they receive no traffic from the Russian VPS. Restore the hop and check recovery. Verify the private address and IPv6 restrictions with isolated probes.
3. Compare the original Xray service, profiles and subscriptions, Hysteria 2 and AmneziaWG against the preflight baseline. The separate unit leaves their services and routing in place. After verification, enable the cascade at boot with `sudo systemctl enable xray-private-cascade.service`.
4. To roll back, disconnect the cascade profile and run `sudo systemctl disable --now xray-private-cascade.service`. Verify that its listener is gone. Remove the dedicated unit and installed config, then run `sudo systemctl daemon-reload`. Close the dedicated ports in both firewalls. Delete `private-cascade-egress` on the foreign VPS with `sudo xrayebator profile-delete --name private-cascade-egress`, then remove the dedicated routing rule and the `private-cascade-exit` outbound. If you created `private-cascade-template` for the cascade, delete that profile by name on the Russian VPS. Recheck the baseline services.
