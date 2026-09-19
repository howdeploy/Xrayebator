# Xrayebator GUI Development Plan

## Product target

Xrayebator GUI is a cross-platform desktop client for a self-hosted Xrayebator
server. It combines:

- one-click VPS deployment over SSH;
- subscription and route management similar to HAPP/INCY;
- a primary Xray-native TUN connection mode;
- an optional system-proxy mode;
- safe connect, disconnect, route switching, tray operation, DNS protection,
  and kill-switch behavior.

The GUI must run as an ordinary desktop user. Operations that require network
administration rights belong to a narrow local service with an authenticated,
typed IPC API. The service must not expose arbitrary command execution.

## Current implementation status

- Linux desktop MVP: implemented and unit/integration tested.
- One-click VPS deployment for root and sudo users: implemented.
- Native Xray TUN, DNS redirection, nftables kill switch, helper recovery:
  implemented; live helper install and check-only firewall self-test passed.
- Full/Smart RU routing profiles, verified route/profile rollback, RTT probes,
  and tray controls: implemented.
- Windows/macOS system-proxy preview bundles: implemented in native CI runners.
- Windows/macOS TUN config fixtures: implemented; native privileged services,
  signing/notarization, and live platform tests remain.

## Invariants

1. The GUI never stores SSH passwords in JSON or logs.
2. A route switch either reaches a verified connection or restores the last
   known-good route.
3. TUN routes never capture the Xray server's own outbound traffic.
4. DNS follows the selected routing profile and does not silently fall back to
   the physical interface while the kill switch is active.
5. Closing the window keeps the connection alive in the tray; explicit Quit
   performs the configured shutdown behavior.
6. Server-side deployment remains compatible with the repository's
   `install.sh` and `xrayebator quickstart --email ...` contract.

## Delivery phases

### Phase 1 — Runnable desktop skeleton

- Package installs and starts on a clean Python environment.
- Main window, tray, server list, route selector, log panel, and connection
  status are present.
- Existing SSH deployment, subscription parser, server store, Xray process,
  and system-proxy modules are connected through explicit application
  controllers.
- Connection lifecycle uses a tested state machine instead of button-local
  booleans.

**Done when:** the application launches, can deploy or load a server, fetch its
subscription, connect in system-proxy mode, switch a route with rollback, and
disconnect cleanly.

### Phase 2 — Xray-native TUN vertical slice

- Pin a known-good Xray version that contains the native TUN implementation.
- Generate TUN inbound configuration with `autoSystemRoutingTable` and
  `autoOutboundsInterface`.
- Implement platform capability checks and actionable errors.
- Keep system-proxy mode as an independent fallback.

**Done when:** Linux, Windows, and macOS configuration fixtures validate, and a
Linux integration run sends TCP, UDP, and DNS traffic through TUN without a
route loop.

### Phase 3 — Privileged network service and safe switching

- Add a minimal privileged local service and authenticated IPC.
- Move TUN/core lifecycle, OS routes, DNS, and firewall operations into it.
- Implement the connection state machine:
  `disconnected → preparing → connecting → verifying → connected`, plus
  `switching`, `disconnecting`, `recovering`, and `error`.
- During route switching, keep the traffic guard active, verify the candidate,
  and roll back to the last known-good route on failure.

**Done when:** killing the GUI does not leak or corrupt routes, killing Xray
  triggers recovery or a closed kill-switch state, and failed switches restore
  the previous route.

### Phase 4 — One-click product flow and routing profiles

- Make “Deploy and connect” the first-run path.
- Add full-tunnel and smart `proxy/direct/block` profiles.
- Split remote and direct DNS resolution.
- Add subscription refresh, latency probes, manual route selection, and
  last-known-good persistence.
- Expose connect, disconnect, server, route, and mode in the tray.

**Done when:** a user can go from clean VPS credentials to a verified TUN
  connection without opening a terminal.

### Phase 5 — Hardening, packaging, and release

- Signed/pinned core downloads and reproducible package inputs.
- Windows service + Wintun packaging, macOS launch daemon/signing hooks, and
  Linux systemd/polkit packages.
- Suspend/resume, network-change recovery, update safety, diagnostics export,
  and uninstall cleanup.
- Unit, integration, privilege-boundary, route-leak, DNS-leak, and disposable
  VPS smoke tests.

**Done when:** installers for all three desktop platforms pass the release
  checklist and uninstall restores network state.

## Deferred until after the first stable release

- Per-application split tunneling on every platform.
- Automatic load balancing across multiple routes.
- Mobile applications.
- Supporting non-Xray protocols unrelated to Xrayebator subscriptions.
