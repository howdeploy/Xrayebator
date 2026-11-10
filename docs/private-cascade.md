# Private cascade through a Russian VPS

[← Back to README](../README.md) · [Русский](ru/private-cascade.md)

## Topology

Use two VPSs. A private client connects to the Russian ingress. The ingress sends selected Russian destinations directly and forwards other client traffic over VLESS REALITY to the foreign egress.

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

## Hostnames, certificates, and REALITY

- Prefer a domain you already control. Use separate names such as `ingress.example.com` and `egress.example.com`. Point each `A` record to the corresponding public IPv4 and publish `AAAA` only after verifying IPv6 reachability and firewall scope. Use DNS-only records where a provider offers proxying. A VPS provider's default hostname works for this purpose only if you can verify the necessary DNS control and obtain a matching certificate with working renewal.
- With the standard REALITY decoy, keep the working target and SNI already configured by Xrayebator and dial each VPS by IP. This setup needs no new DNS account or certificate for the tunnel.
- The cascade dial address can be a reachable IP or a hostname. An IP certificate can serve the subscription HTTPS endpoint. For self-steal, set REALITY SNI to the hostname covered by the certificate on the loopback TLS target, and match the XHTTP `host` to it when using XHTTP. [Domain and DNS](configuration.md#domain-and-dns) · [Self-steal](configuration.md#custom-domain-and-self-steal-stub)
- For closed-port self-steal, use your DNS provider's ACME plugin in certificate-only mode, configure the loopback TLS site and add a deploy hook that reloads its TLS service after renewal. Verify the matching certificate on the loopback listener. The built-in `dns01-setup` configures a subscription listener for Cloudflare or Route 53. Use it only if you also intend to publish that subscription, and pass its secret through a file or stdin. [DNS-01](configuration.md#dns-01-certificate-and-subscription-domain-without-port-80)

## Prepare the foreign egress

On the foreign VPS, create a named TCP Vision profile on the reserved free port other than 443. For example, run `sudo xrayebator profile-create --name private-cascade-egress --transport tcp --port 25443`. Check that `names` includes the new profile and `errors` is empty. Export its TCP Vision URI privately from the server's profile menu or assemble it using the profile's actual settings. Put an IPv6 dial address in square brackets.

```text
vless://<uuid>@<egress-address>:<port>?encryption=none&security=reality&type=tcp&flow=xtls-rprx-vision&sni=<sni>&fp=<fingerprint>&pbk=<public-key>&sid=<short-id>
```

For XHTTP, export a compatible legacy XHTTP route with `encryption=none` and keep its `path`, `host`, and `mode`. The ordinary XHTTP profile creator uses PQ by default. Verify the restricted listener from both the ingress and a source outside its allowlist. Confirm the foreign node has a working internet egress. [Standard cascade](configuration.md#cascade-and-upstream-nodes)

The foreign VPS can resolve forwarded names independently. Before admitting clients, verify that its egress controls block connections to loopback, private networks and provider metadata from forwarded requests, including when a DNS name resolves there. If clients must use public IPv4 destinations only, enforce that policy on the foreign egress too. This is separate from using IPv6 for the server hop.

## Render and start the ingress

On the Russian VPS, choose a working VLESS REALITY TCP or legacy XHTTP inbound with `decryption=none` and an empty VLESS `fallbacks` list. Generate a fresh UUID with `uuidgen` for the standalone ingress. Create two root-owned `0600` files inside a root-only directory such as `/root/xrayebator-private-cascade/`. Write the single upstream URI to `upstream.txt`, and fill `policy.json` using this example. Replace the inbound tag, UUID and example destinations with your own values.

```json
{
  "inbound_tag": "inbound-443",
  "client_id": "<pilot-profile-uuid>",
  "listen": "0.0.0.0",
  "port": 15443,
  "blocked_domains": ["domain:example.net"],
  "blocked_ips": ["198.51.100.0/24"]
}
```

Choose a free TCP port and open it at both ingress firewalls for the intended client sources. Both `blocked_domains` and `blocked_ips` are required arrays, with at least one entry between them. Optional arrays `russia_only_domains`, `russian_domains`, and `russian_ips` define direct routes. The defaults for the latter two are `.ru`/`.рф` and `geoip:ru`. Use Xray selectors matching your deployed assets. `ext:` rules require their corresponding local data files. The renderer reads those assets from the host and performs no downloads.

The ingress blocks private and IPv6 destinations matched by its IP rules. The explicit Russia-only domain exception takes precedence over the blocked lists. Blocked destinations go through the foreign hop ahead of the general Russian rules. The remaining TCP and UDP traffic uses the foreign hop and fails closed if it is unavailable. The ingress uses service DoH with a local resolver fallback. Configure the client to send its DNS to `192.0.2.53:53` inside VLESS. Keep pilot requests inside the tunnel and disable client-side fallback to direct or another profile.

```bash
sudo xrayebator private-cascade render \
  --policy-file /root/xrayebator-private-cascade/policy.json \
  --upstream-file /root/xrayebator-private-cascade/upstream.txt \
  --output /root/xrayebator-private-cascade/ingress.json
```

The renderer creates a single client with the new UUID and takes the flow from the template inbound's first client. It preserves the inbound's transport and REALITY settings, validates with `xray run -test` and writes a new root-owned `0600` file. Choose an unused service directory for first installation.

```bash
sudo install -d -o root -g xray -m 0750 /etc/xray-private-cascade
sudo install -o root -g xray -m 0640 /root/xrayebator-private-cascade/ingress.json \
  /etc/xray-private-cascade/config.json
```

Create `/etc/systemd/system/xray-private-cascade.service` as root. This example uses an unprivileged TCP port and the standard Xrayebator binary and asset paths.

```ini
[Unit]
Description=Xray private cascade ingress
Wants=network-online.target
After=network-online.target

[Service]
User=xray
Group=xray
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

## Accept or roll back the pilot

1. From a desktop or command-line client on the intended network, verify the REALITY connection and send a few small HTTPS and DNS requests. Use controlled endpoints or destination-side logs to confirm that an explicit Russian route sees the Russian source IP and an unmatched route sees the foreign source IP. Where the policies overlap, verify that a blocked destination takes the foreign path unless explicitly listed as Russia-only.
2. In a maintenance window, briefly withdraw only the dedicated foreign hop and open fresh test connections. A request that requires the foreign path must fail without reaching the destination from the Russian VPS. Restore the hop and check recovery. Verify the policy for private addresses and IPv6 with isolated probes and check client DNS through the virtual resolver. These checks use a few requests and can run without mobile testing or a load test.
3. Compare the original Xray service, profiles and subscriptions, Hysteria 2 and AmneziaWG against the preflight baseline. The separate unit leaves their services and routing in place. Enable the pilot at boot only after acceptance with `sudo systemctl enable xray-private-cascade.service`.
4. To roll back, disconnect the pilot profile and run `sudo systemctl disable --now xray-private-cascade.service`. Verify that its listener is gone. Remove the pilot's dedicated unit and installed config, then run `sudo systemctl daemon-reload`. Close the dedicated ports in both firewalls. Delete the dedicated foreign profile with `sudo xrayebator profile-delete --name private-cascade-egress`, then recheck the baseline services.
