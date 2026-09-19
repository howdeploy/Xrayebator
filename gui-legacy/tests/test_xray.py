from __future__ import annotations

import sys

import pytest

from xrayebator_gui.core.routing import RoutingProfile
from xrayebator_gui.core.subscription import VlessLink
from xrayebator_gui.core.xray import (
    XrayError,
    XrayProcess,
    _parse_dgst,
    build_client_config,
    build_tun_client_config,
)


def link(*, encryption: str = "none") -> VlessLink:
    return VlessLink(
        raw="vless://uuid@vpn.example.com:443",
        address="vpn.example.com",
        port=443,
        uuid="uuid",
        network="tcp",
        security="reality",
        sni="www.example.com",
        fingerprint="chrome",
        public_key="public",
        short_id="0123456789abcdef",
        flow="xtls-rprx-vision",
        encryption=encryption,
        remark="Vision",
    )


def test_system_proxy_config_has_local_inbounds():
    config = build_client_config(link())

    assert [inbound["protocol"] for inbound in config["inbounds"]] == [
        "socks",
        "http",
    ]
    assert config["outbounds"][0]["tag"] == "proxy"


def test_linux_tun_config_uses_auto_routes_and_loop_prevention():
    config = build_tun_client_config(
        link(),
        system="Linux",
        outbound_mark=0x5852,
    )
    inbound = config["inbounds"][0]
    settings = inbound["settings"]

    assert inbound["protocol"] == "tun"
    assert settings["name"] == "xrayebator0"
    assert settings["autoSystemRoutingTable"] == ["0.0.0.0/0", "::/0"]
    assert settings["autoOutboundsInterface"] == "auto"
    assert "dns" not in settings
    assert config["outbounds"][0]["streamSettings"]["sockopt"]["mark"] == 0x5852
    assert config["outbounds"][1]["streamSettings"]["sockopt"]["mark"] == 0x5852


def test_windows_tun_config_includes_wintun_description_and_dns():
    settings = build_tun_client_config(link(), system="Windows", ipv6=False)[
        "inbounds"
    ][0]["settings"]

    assert settings["name"] == "xrayebator"
    assert settings["desc"] == "Xrayebator"
    assert settings["dns"] == ["1.1.1.1", "8.8.8.8"]
    assert settings["gateway"] == ["10.254.0.1/30"]
    assert settings["autoSystemRoutingTable"] == ["0.0.0.0/0"]


def test_darwin_leaves_utun_name_selection_to_xray():
    settings = build_tun_client_config(link(), system="Darwin")["inbounds"][0][
        "settings"
    ]

    assert "name" not in settings
    assert "dns" not in settings


def test_tun_can_expose_local_proxies_for_mixed_mode():
    config = build_tun_client_config(link(), system="Linux", include_local_proxies=True)

    assert [inbound["protocol"] for inbound in config["inbounds"]] == [
        "tun",
        "socks",
        "http",
    ]


def test_smart_ru_routing_orders_block_before_direct():
    config = build_tun_client_config(
        link(),
        system="Linux",
        routing_profile=RoutingProfile.SMART_RU,
    )
    rules = config["routing"]["rules"]

    assert rules[0]["outboundTag"] == "block"
    assert "geosite:category-ads-all" in rules[0]["domain"]
    assert rules[1]["outboundTag"] == "direct"
    assert "geoip:private" in rules[1]["ip"]
    assert "geosite:category-ru" in rules[2]["domain"]
    assert "geoip:ru" in rules[3]["ip"]


def test_post_quantum_encryption_omits_incompatible_vision_flow():
    config = build_tun_client_config(
        link(encryption="mlkem768x25519plus.native"),
        system="Linux",
    )
    user = config["outbounds"][0]["settings"]["vnext"][0]["users"][0]

    assert user["encryption"] == "mlkem768x25519plus.native"
    assert "flow" not in user


@pytest.mark.parametrize("mtu", [0, 1279, 9001])
def test_tun_rejects_unsafe_mtu(mtu):
    with pytest.raises(XrayError, match="MTU"):
        build_tun_client_config(link(), system="Linux", mtu=mtu)


def test_tun_rejects_unknown_platform():
    with pytest.raises(XrayError, match="не поддерживается"):
        build_tun_client_config(link(), system="Plan9")


@pytest.mark.parametrize("mark", [0, -1, 0x1_0000_0000])
def test_tun_rejects_invalid_outbound_mark(mark):
    with pytest.raises(XrayError, match="метка"):
        build_tun_client_config(link(), system="Linux", outbound_mark=mark)


def test_parse_dgst_accepts_release_asset_line():
    digest = "a" * 64
    text = f"{digest}  Xray-linux-64.zip\n"

    assert _parse_dgst(text, "Xray-linux-64.zip") == digest


def test_parse_dgst_accepts_actual_xray_release_format():
    digest = "b" * 64
    text = f"MD5= {'a' * 32}\nSHA2-256= {digest}\n"

    assert _parse_dgst(text, "Xray-linux-64.zip") == digest


POSIX_MODE_TEST = pytest.mark.skipif(
    sys.platform == "win32",
    reason="POSIX-only file permission check (os.fchmod absent on Windows)",
)


@POSIX_MODE_TEST
def test_xray_runtime_files_are_owner_only(monkeypatch, tmp_path):
    binary = tmp_path / "xray"
    binary.write_bytes(b"binary")
    binary.chmod(0o755)

    class FakePopen:
        def __init__(self, *args, **kwargs):
            self.returncode = None

        def poll(self):
            return self.returncode

        def terminate(self):
            self.returncode = 0

        def wait(self, timeout):
            return self.returncode

    monkeypatch.setattr("xrayebator_gui.core.xray.subprocess.Popen", FakePopen)
    monkeypatch.setattr("xrayebator_gui.core.xray.time.sleep", lambda _: None)
    config_path = tmp_path / "runtime" / "config.json"
    log_path = tmp_path / "runtime" / "xray.log"
    process = XrayProcess(
        binary,
        config_path=config_path,
        stderr_path=log_path,
    )

    process.start(build_client_config(link()))
    process.stop()

    assert config_path.stat().st_mode & 0o777 == 0o600
    assert log_path.stat().st_mode & 0o777 == 0o600
