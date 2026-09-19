from __future__ import annotations

import pytest

from xrayebator_gui.core.connection import (
    ConnectionController,
    ConnectionError,
    ConnectionMode,
    ConnectionState,
    InvalidTransition,
    RouteSwitchError,
)
from xrayebator_gui.core.routing import RoutingProfile
from xrayebator_gui.core.subscription import VlessLink


def route(name: str, port: int = 443) -> VlessLink:
    return VlessLink(
        raw=f"vless://uuid@{name}:{port}?security=reality#{name}",
        address=name,
        port=port,
        uuid="uuid",
        network="tcp",
        security="reality",
        sni=name,
        public_key="public-key",
        short_id="0123456789abcdef",
        flow="xtls-rprx-vision",
        remark=name,
    )


class FakeBackend:
    def __init__(self):
        self.calls: list[tuple] = []
        self.verify_results: list[object] = ["203.0.113.1"]
        self.fail_prepare = False
        self.fail_stop = False

    def prepare(self, selected, mode, routing_profile):
        self.calls.append(("prepare", selected.address, mode, routing_profile))
        if self.fail_prepare:
            raise RuntimeError("prepare failed")

    def start(self, selected, mode, routing_profile):
        self.calls.append(("start", selected.address, mode, routing_profile))

    def verify(self):
        self.calls.append(("verify",))
        result = self.verify_results.pop(0)
        if isinstance(result, Exception):
            raise result
        return result

    def replace(self, selected, mode, routing_profile):
        self.calls.append(("replace", selected.address, mode, routing_profile))

    def stop(self):
        self.calls.append(("stop",))
        if self.fail_stop:
            raise RuntimeError("stop failed")


def test_connect_and_disconnect_emit_ordered_states():
    backend = FakeBackend()
    controller = ConnectionController(backend)
    states = []
    controller.subscribe(lambda snapshot: states.append(snapshot.state))

    connected = controller.connect(route("one.example"), ConnectionMode.SYSTEM_PROXY)
    disconnected = controller.disconnect()

    assert connected.state == ConnectionState.CONNECTED
    assert connected.external_ip == "203.0.113.1"
    assert disconnected.state == ConnectionState.DISCONNECTED
    assert states == [
        ConnectionState.DISCONNECTED,
        ConnectionState.PREPARING,
        ConnectionState.CONNECTING,
        ConnectionState.VERIFYING,
        ConnectionState.CONNECTED,
        ConnectionState.DISCONNECTING,
        ConnectionState.DISCONNECTED,
    ]


def test_failed_connect_stops_backend_and_enters_error():
    backend = FakeBackend()
    backend.fail_prepare = True
    controller = ConnectionController(backend)

    with pytest.raises(ConnectionError, match="prepare failed"):
        controller.connect(route("one.example"), ConnectionMode.SYSTEM_PROXY)

    assert controller.snapshot.state == ConnectionState.ERROR
    assert controller.snapshot.error == "prepare failed"
    assert backend.calls[-1] == ("stop",)


def test_route_switch_commits_verified_candidate():
    backend = FakeBackend()
    backend.verify_results = ["203.0.113.1", "203.0.113.2"]
    controller = ConnectionController(backend)
    controller.connect(route("one.example"), ConnectionMode.SYSTEM_PROXY)

    result = controller.switch_route(route("two.example", 8443))

    assert result.state == ConnectionState.CONNECTED
    assert result.route.address == "two.example"
    assert result.external_ip == "203.0.113.2"
    assert ("stop",) not in backend.calls[4:]


def test_route_switch_rolls_back_to_last_known_good_route():
    backend = FakeBackend()
    backend.verify_results = [
        "203.0.113.1",
        None,
        "203.0.113.1",
    ]
    controller = ConnectionController(backend)
    original = route("one.example")
    controller.connect(original, ConnectionMode.SYSTEM_PROXY)

    with pytest.raises(RouteSwitchError, match="восстановлен"):
        controller.switch_route(route("two.example", 8443))

    assert controller.snapshot.state == ConnectionState.CONNECTED
    assert controller.snapshot.route == original
    assert controller.snapshot.external_ip == "203.0.113.1"
    assert controller.snapshot.error is not None


def test_route_switch_enters_error_when_candidate_and_rollback_fail():
    backend = FakeBackend()
    backend.verify_results = [
        "203.0.113.1",
        RuntimeError("candidate failed"),
        RuntimeError("rollback failed"),
    ]
    controller = ConnectionController(backend)
    controller.connect(route("one.example"), ConnectionMode.SYSTEM_PROXY)

    with pytest.raises(RouteSwitchError, match="откат также не удался"):
        controller.switch_route(route("two.example"))

    assert controller.snapshot.state == ConnectionState.ERROR
    assert controller.snapshot.route is None


def test_switch_requires_active_connection():
    controller = ConnectionController(FakeBackend())

    with pytest.raises(InvalidTransition):
        controller.switch_route(route("two.example"))


def test_profile_switch_is_verified_and_keeps_route():
    backend = FakeBackend()
    backend.verify_results = ["203.0.113.1", "203.0.113.2"]
    controller = ConnectionController(backend)
    original = route("one.example")
    controller.connect(original, ConnectionMode.TUN)

    result = controller.switch_profile(RoutingProfile.SMART_RU)

    assert result.state == ConnectionState.CONNECTED
    assert result.route == original
    assert result.routing_profile == RoutingProfile.SMART_RU
    assert (
        "replace",
        "one.example",
        ConnectionMode.TUN,
        RoutingProfile.SMART_RU,
    ) in backend.calls


def test_failed_profile_switch_restores_previous_profile():
    backend = FakeBackend()
    backend.verify_results = ["203.0.113.1", None, "203.0.113.1"]
    controller = ConnectionController(backend)
    controller.connect(route("one.example"), ConnectionMode.TUN)

    with pytest.raises(RouteSwitchError, match="восстановлены"):
        controller.switch_profile(RoutingProfile.SMART_RU)

    assert controller.snapshot.state == ConnectionState.CONNECTED
    assert controller.snapshot.routing_profile == RoutingProfile.FULL
