from __future__ import annotations

import json
import os
import subprocess

import pytest

from xrayebator_gui.core.routing import RoutingProfile
from xrayebator_gui.core.subscription import parse_link
from xrayebator_gui.core.xray import build_tun_client_config


@pytest.mark.parametrize(
    "profile",
    [RoutingProfile.FULL, RoutingProfile.SMART_RU],
)
def test_real_xray_accepts_generated_tun_config(tmp_path, profile):
    binary = os.environ.get("XRAY_TEST_BINARY")
    if not binary:
        pytest.skip("set XRAY_TEST_BINARY to run real Xray config validation")
    route = parse_link(
        "vless://11111111-1111-1111-1111-111111111111@198.51.100.1:443"
        "?type=tcp&security=reality&sni=www.example.com&fp=chrome"
        "&pbk=O0rrwmWNVNHiHzBuTpIA_jbhZy6uZT7Q4u-INKcUuWc"
        "&sid=0123456789abcdef&flow=xtls-rprx-vision#Vision"
    )
    assert route is not None
    config = build_tun_client_config(
        route,
        system="Linux",
        outbound_mark=0x5852,
        routing_profile=profile,
    )
    config_path = tmp_path / "config.json"
    config_path.write_text(json.dumps(config), encoding="utf-8")

    result = subprocess.run(
        [binary, "run", "-test", "-c", str(config_path)],
        capture_output=True,
        text=True,
        timeout=15,
        check=False,
    )

    assert result.returncode == 0, result.stderr
