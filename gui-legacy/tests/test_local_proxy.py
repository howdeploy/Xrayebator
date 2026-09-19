from __future__ import annotations

import pytest

from xrayebator_gui.core import local_proxy
from xrayebator_gui.core.connection import ConnectionMode
from xrayebator_gui.core.routing import RoutingProfile
from xrayebator_gui.core.subscription import VlessLink
from xrayebator_gui.core.xray import XrayError


def route() -> VlessLink:
    return VlessLink(
        raw="vless://uuid@vpn.example.com:443",
        address="vpn.example.com",
        port=443,
        uuid="uuid",
        network="tcp",
        security="reality",
        sni="www.example.com",
        public_key="public",
        short_id="0123456789abcdef",
        remark="Vision",
    )


class FakeProcess:
    def __init__(self, binary):
        self.binary = binary
        self.started = []
        self.stop_calls = 0

    def start(self, config):
        self.started.append(config)

    def stop(self):
        self.stop_calls += 1

    def health_check(self):
        return "203.0.113.10"


def test_backend_restores_previous_proxy_on_stop(monkeypatch, tmp_path):
    snapshot = object()
    restored = []
    monkeypatch.setattr(local_proxy.proxy, "capture", lambda: snapshot)
    monkeypatch.setattr(local_proxy.proxy, "enable", lambda **kwargs: True)
    monkeypatch.setattr(
        local_proxy.proxy,
        "restore",
        lambda saved: restored.append(saved) or True,
    )
    process = FakeProcess(tmp_path / "xray")
    backend = local_proxy.LocalProxyBackend(
        ensure_binary_fn=lambda: tmp_path / "xray",
        process_factory=lambda binary: process,
    )

    backend.prepare(
        route(),
        ConnectionMode.SYSTEM_PROXY,
        RoutingProfile.FULL,
    )
    backend.start(
        route(),
        ConnectionMode.SYSTEM_PROXY,
        RoutingProfile.FULL,
    )
    backend.stop()

    assert restored == [snapshot]
    assert process.stop_calls == 1


def test_backend_restores_snapshot_when_proxy_enable_fails(monkeypatch, tmp_path):
    snapshot = object()
    restored = []
    monkeypatch.setattr(local_proxy.proxy, "capture", lambda: snapshot)
    monkeypatch.setattr(local_proxy.proxy, "enable", lambda **kwargs: False)
    monkeypatch.setattr(
        local_proxy.proxy,
        "restore",
        lambda saved: restored.append(saved) or True,
    )
    process = FakeProcess(tmp_path / "xray")
    backend = local_proxy.LocalProxyBackend(
        ensure_binary_fn=lambda: tmp_path / "xray",
        process_factory=lambda binary: process,
    )
    backend.prepare(
        route(),
        ConnectionMode.SYSTEM_PROXY,
        RoutingProfile.FULL,
    )

    with pytest.raises(XrayError, match="proxy"):
        backend.start(
            route(),
            ConnectionMode.SYSTEM_PROXY,
            RoutingProfile.FULL,
        )

    assert restored == [snapshot]
    assert process.stop_calls == 1
