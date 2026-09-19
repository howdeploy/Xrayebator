from __future__ import annotations

import pytest

from xrayebator_gui.helper.linux_network import (
    NetworkError,
    build_nft_rules,
)


def test_nft_guard_allows_only_loopback_tun_mark_and_dhcp():
    rules = build_nft_rules("xrayebator0", 0x5852)

    assert 'oifname "lo" accept' in rules
    assert 'oifname "xrayebator0" accept' in rules
    assert f"meta mark {0x5852} accept" in rules
    assert "udp dport 53 dnat ip to 1.1.1.1" in rules
    assert "tcp dport 53 dnat ip6 to 2606:4700:4700::1111" in rules
    assert "udp sport 68 udp dport 67 accept" in rules
    assert rules.rstrip().endswith("}")
    assert "reject" in rules


@pytest.mark.parametrize(
    "interface",
    ["", "tun interface", "../../eth0", "a" * 16, 'tun"evil'],
)
def test_nft_guard_rejects_unsafe_interface_name(interface):
    with pytest.raises(NetworkError, match="имя"):
        build_nft_rules(interface, 1)


@pytest.mark.parametrize("mark", [0, -1, 0x1_0000_0000])
def test_nft_guard_rejects_invalid_mark(mark):
    with pytest.raises(NetworkError, match="mark"):
        build_nft_rules("xrayebator0", mark)
