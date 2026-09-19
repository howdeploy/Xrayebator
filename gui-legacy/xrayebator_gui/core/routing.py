"""Built-in routing profiles shared by UI, desktop backend and helper."""

from __future__ import annotations

from enum import Enum


class RoutingProfile(str, Enum):
    FULL = "full"
    SMART_RU = "smart_ru"

    @property
    def label(self) -> str:
        if self == RoutingProfile.SMART_RU:
            return "Smart RU — РФ/локальная сеть напрямую, реклама блокируется"
        return "Full tunnel — весь трафик через VPN"


def build_routing_config(profile: RoutingProfile) -> dict | None:
    if profile == RoutingProfile.FULL:
        return None
    if profile == RoutingProfile.SMART_RU:
        return {
            "domainStrategy": "IPIfNonMatch",
            "domainMatcher": "hybrid",
            "rules": [
                {
                    "type": "field",
                    "domain": ["geosite:category-ads-all"],
                    "outboundTag": "block",
                },
                {
                    "type": "field",
                    "ip": ["geoip:private"],
                    "outboundTag": "direct",
                },
                {
                    "type": "field",
                    "domain": [
                        "geosite:private",
                        "geosite:category-ru",
                    ],
                    "outboundTag": "direct",
                },
                {
                    "type": "field",
                    "ip": ["geoip:ru"],
                    "outboundTag": "direct",
                },
            ],
        }
    raise ValueError(f"Неизвестный routing profile: {profile}")
