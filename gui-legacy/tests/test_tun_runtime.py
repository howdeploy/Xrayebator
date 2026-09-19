from __future__ import annotations

import pytest

from xrayebator_gui.core.routing import RoutingProfile
from xrayebator_gui.core.subscription import parse_link
from xrayebator_gui.helper.runtime import TunRuntime, TunRuntimeError
from xrayebator_gui.helper.state import StoredRoute

ROUTE_ONE = (
    "vless://11111111-1111-1111-1111-111111111111@one.example.com:443"
    "?type=tcp&security=reality&sni=www.example.com"
    "&pbk=public&sid=0123456789abcdef#One"
)
ROUTE_TWO = ROUTE_ONE.replace("one.example.com", "two.example.com").replace(
    "#One", "#Two"
)


class FakeNetwork:
    def __init__(self):
        self.calls = []
        self.guarded = False

    def guard_exists(self):
        return self.guarded

    def check_dependencies(self):
        self.calls.append(("check",))

    def enable_guard(self, interface, mark):
        self.guarded = True
        self.calls.append(("guard-on", interface, mark))

    def validate_guard(self, interface, mark):
        self.calls.append(("guard-check", interface, mark))

    def disable_guard(self):
        self.guarded = False
        self.calls.append(("guard-off",))

    def configure_dns(self, interface):
        self.calls.append(("dns-on", interface))

    def restore_dns(self, interface):
        self.calls.append(("dns-off", interface))


class FakeProcess:
    def __init__(self, address, *, fail=False):
        self.address = address
        self.fail = fail
        self.running = False
        self.stop_calls = 0

    def start(self, config):
        if self.fail:
            raise TunRuntimeError("candidate failed")
        self.running = True

    def stop(self):
        self.running = False
        self.stop_calls += 1

    def is_running(self):
        return self.running

    def health_check_tun(self):
        return "203.0.113.20" if self.running else None


class FakeStateStore:
    def __init__(self, stored=None):
        self.stored = stored
        self.saved = []
        self.remove_calls = 0

    def save(self, route, address, routing_profile):
        self.saved.append((route, address, routing_profile))
        self.stored = StoredRoute(route, address, routing_profile)

    def load(self):
        return self.stored

    def remove(self):
        self.remove_calls += 1
        self.stored = None


def make_runtime(
    network,
    runtime_dir,
    *,
    fail_addresses=None,
    state_store=None,
):
    processes = []
    fail_addresses = fail_addresses or set()

    def factory(binary, config_path, stderr_path):
        # The resolver result is consumed later in config.start; use call order.
        address = str(len(processes))
        process = FakeProcess(address, fail=address in fail_addresses)
        processes.append(process)
        return process

    runtime = TunRuntime(
        network=network,
        runtime_dir=runtime_dir,
        process_factory=factory,
        resolver=lambda host, port: {
            "one.example.com": "198.51.100.1",
            "two.example.com": "198.51.100.2",
        }[host],
        binary_validator=lambda path: None,
        state_store=state_store or FakeStateStore(),
    )
    return runtime, processes


def test_connect_verify_disconnect_orders_guard_and_cleanup(tmp_path):
    network = FakeNetwork()
    runtime, processes = make_runtime(network, tmp_path)
    route = parse_link(ROUTE_ONE)
    assert route is not None

    runtime.connect(route, RoutingProfile.FULL)
    verified = runtime.verify()
    disconnected = runtime.disconnect()

    assert verified["external_ip"] == "203.0.113.20"
    assert disconnected["state"] == "disconnected"
    assert network.calls[:3] == [
        ("check",),
        ("guard-on", "xrayebator0", 22610),
        ("dns-on", "xrayebator0"),
    ]
    assert network.calls[-1] == ("guard-off",)
    assert processes[0].stop_calls == 1


def test_failed_switch_keeps_guard_for_controller_rollback(tmp_path):
    network = FakeNetwork()
    runtime, _ = make_runtime(
        network,
        tmp_path,
        fail_addresses={"1"},
    )
    first = parse_link(ROUTE_ONE)
    second = parse_link(ROUTE_TWO)
    assert first is not None and second is not None
    runtime.connect(first, RoutingProfile.FULL)

    with pytest.raises(TunRuntimeError, match="kill switch закрыт"):
        runtime.switch(second, RoutingProfile.SMART_RU)

    assert runtime.status()["state"] == "guarded_error"
    assert network.guarded is True

    recovered = runtime.switch(first, RoutingProfile.FULL)
    assert recovered["state"] == "connected"
    assert network.guarded is True


def test_dead_xray_transitions_to_closed_guard_state(tmp_path):
    network = FakeNetwork()
    runtime, processes = make_runtime(network, tmp_path)
    route = parse_link(ROUTE_ONE)
    assert route is not None
    runtime.connect(route, RoutingProfile.FULL)
    processes[0].running = False

    status = runtime.status()

    assert status["state"] == "guarded_error"
    assert "kill switch" in status["error"]
    assert network.guarded is True


def test_recovery_uses_persisted_ip_without_dns_resolution(tmp_path):
    route = parse_link(ROUTE_ONE)
    assert route is not None
    network = FakeNetwork()
    network.guarded = True
    state_store = FakeStateStore(
        StoredRoute(
            route,
            "198.51.100.1",
            RoutingProfile.SMART_RU,
        )
    )
    processes = []

    def factory(binary, config_path, stderr_path):
        process = FakeProcess("recovered")
        processes.append(process)
        return process

    runtime = TunRuntime(
        network=network,
        runtime_dir=tmp_path,
        process_factory=factory,
        resolver=lambda host, port: (_ for _ in ()).throw(
            AssertionError("recovery must not use DNS")
        ),
        binary_validator=lambda path: None,
        state_store=state_store,
    )

    result = runtime.recover()

    assert result["state"] == "connected"
    assert processes[0].running is True


def test_reconnect_same_target_adopts_existing_tun_without_restart(tmp_path):
    network = FakeNetwork()
    runtime, processes = make_runtime(network, tmp_path)
    route = parse_link(ROUTE_ONE)
    assert route is not None
    runtime.connect(route, RoutingProfile.SMART_RU)

    result = runtime.connect(route, RoutingProfile.SMART_RU)

    assert result["state"] == "connected"
    assert len(processes) == 1


def test_selftest_validates_dependencies_binary_and_nft_rules(tmp_path):
    network = FakeNetwork()
    validated = []
    runtime = TunRuntime(
        network=network,
        runtime_dir=tmp_path,
        binary_validator=lambda path: validated.append(path),
        state_store=FakeStateStore(),
    )

    result = runtime.selftest()

    assert result["state"] == "disconnected"
    assert validated
    assert ("guard-check", "xrayebator0", 22610) in network.calls
