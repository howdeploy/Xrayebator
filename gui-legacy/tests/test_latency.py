from __future__ import annotations

from xrayebator_gui.core import latency
from xrayebator_gui.core.subscription import VlessLink


def route(raw: str, host: str, port: int) -> VlessLink:
    return VlessLink(
        raw=raw,
        address=host,
        port=port,
        uuid="uuid",
    )


def test_probe_routes_deduplicates_shared_endpoints(monkeypatch):
    calls = []

    def fake_probe(host, port, *, timeout):
        calls.append((host, port, timeout))
        return 42

    monkeypatch.setattr(latency, "probe_endpoint", fake_probe)
    routes = [
        route("one", "vpn.example.com", 443),
        route("two", "vpn.example.com", 443),
        route("three", "vpn.example.com", 8443),
    ]

    result = latency.probe_routes(routes, timeout=1.5)

    assert result == {"one": 42, "two": 42, "three": 42}
    assert sorted(calls) == [
        ("vpn.example.com", 443, 1.5),
        ("vpn.example.com", 8443, 1.5),
    ]
