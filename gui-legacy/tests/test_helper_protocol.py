from __future__ import annotations

import json

import pytest

from xrayebator_gui.core.helper_protocol import (
    ProtocolError,
    decode_request,
    decode_response,
    encode_request,
    encode_response,
)
from xrayebator_gui.core.routing import RoutingProfile
from xrayebator_gui.core.subscription import parse_link

ROUTE = (
    "vless://11111111-1111-1111-1111-111111111111@vpn.example.com:443"
    "?type=tcp&security=reality&sni=www.example.com&fp=chrome"
    "&pbk=public&sid=0123456789abcdef&flow=xtls-rprx-vision#Vision"
)


def test_protocol_round_trip_keeps_only_canonical_vless_url():
    route = parse_link(ROUTE)
    assert route is not None

    request = decode_request(encode_request("connect", route, RoutingProfile.SMART_RU))

    assert request.action == "connect"
    assert request.route is not None
    assert request.route.raw == ROUTE
    assert request.routing_profile == RoutingProfile.SMART_RU


def test_protocol_rejects_unknown_fields():
    payload = {
        "version": 1,
        "id": "abc123",
        "action": "status",
        "command": "rm -rf /",
    }

    with pytest.raises(ProtocolError, match="Неизвестные поля"):
        decode_request(json.dumps(payload).encode())


def test_protocol_rejects_route_for_status():
    payload = {
        "version": 1,
        "id": "abc123",
        "action": "status",
        "route": ROUTE,
        "routing_profile": "full",
    }

    with pytest.raises(ProtocolError, match="не принимает"):
        decode_request(json.dumps(payload).encode())


def test_response_id_must_match():
    response = encode_response(
        "one",
        ok=True,
        state="connected",
        external_ip="203.0.113.1",
    )

    with pytest.raises(ProtocolError, match="другой request id"):
        decode_response(response, "two")
