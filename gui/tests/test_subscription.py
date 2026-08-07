from __future__ import annotations

import base64

from xrayebator_gui.core.subscription import parse, pick_default

VISION = (
    "vless://11111111-1111-1111-1111-111111111111@vpn.example.com:443"
    "?type=tcp&security=reality&sni=www.example.com&fp=chrome"
    "&pbk=public&sid=0123456789abcdef&flow=xtls-rprx-vision#Vision"
)
XHTTP = (
    "vless://22222222-2222-2222-2222-222222222222@vpn.example.com:8443"
    "?type=xhttp&security=reality&sni=www.example.com&fp=firefox"
    "&pbk=public&sid=abcdef0123456789&path=%2Fxhttp#XHTTP"
)


def test_parse_plain_subscription_and_pick_vision():
    routes = parse(f"# ignored\n{XHTTP}\n{VISION}\n")

    assert [route.remark for route in routes] == ["XHTTP", "Vision"]
    assert routes[0].path == "/xhttp"
    assert pick_default(routes) == routes[1]


def test_parse_base64_subscription():
    encoded = base64.b64encode(f"{VISION}\n{XHTTP}\n".encode()).decode()

    routes = parse(encoded)

    assert len(routes) == 2
    assert routes[0].flow == "xtls-rprx-vision"
