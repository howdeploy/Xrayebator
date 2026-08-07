"""Root-only last-known-good route state for fail-closed recovery."""

from __future__ import annotations

import ipaddress
import json
import os
import stat
import sys
import tempfile
from dataclasses import dataclass
from pathlib import Path

from ..core.routing import RoutingProfile
from ..core.subscription import VlessLink, parse_link

DEFAULT_STATE_PATH = Path("/var/lib/xrayebator-gui/last-route.json")


class StateError(RuntimeError):
    """Persisted helper state is unsafe or malformed."""


@dataclass(frozen=True)
class StoredRoute:
    route: VlessLink
    resolved_address: str
    routing_profile: RoutingProfile = RoutingProfile.FULL


class RouteStateStore:
    def __init__(
        self,
        path: Path = DEFAULT_STATE_PATH,
        *,
        expected_uid: int = 0,
    ):
        self.path = Path(path)
        self.expected_uid = expected_uid

    def save(
        self,
        route: VlessLink,
        resolved_address: str,
        routing_profile: RoutingProfile,
    ) -> None:
        try:
            ipaddress.ip_address(resolved_address)
        except ValueError as exc:
            raise StateError(
                f"Нельзя сохранить не-IP адрес маршрута: {resolved_address}"
            ) from exc
        self.path.parent.mkdir(parents=True, exist_ok=True)
        os.chmod(self.path.parent, 0o700)
        fd, tmp_name = tempfile.mkstemp(
            prefix=f".{self.path.name}.",
            dir=self.path.parent,
        )
        try:
            # CI-2: os.fchmod POSIX-only; на Windows права задаются через os.chmod.
            if sys.platform == "win32":
                os.chmod(tmp_name, 0o600)
            else:
                os.fchmod(fd, 0o600)
            with os.fdopen(fd, "w", encoding="utf-8") as stream:
                fd = -1
                json.dump(
                    {
                        "version": 2,
                        "route": route.raw,
                        "resolved_address": resolved_address,
                        "routing_profile": routing_profile.value,
                    },
                    stream,
                    separators=(",", ":"),
                )
                stream.flush()
                os.fsync(stream.fileno())
            os.replace(tmp_name, self.path)
        finally:
            if fd >= 0:
                os.close(fd)
            Path(tmp_name).unlink(missing_ok=True)

    def load(self) -> StoredRoute | None:
        if not self.path.exists():
            return None
        info = self.path.lstat()
        if (
            not stat.S_ISREG(info.st_mode)
            or info.st_uid != self.expected_uid
            or info.st_mode & 0o077
        ):
            raise StateError(f"Небезопасные owner/mode persisted state: {self.path}")
        try:
            payload = json.loads(self.path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as exc:
            raise StateError("Persisted state повреждён") from exc
        if not isinstance(payload, dict) or set(payload) != {
            "version",
            "route",
            "resolved_address",
            "routing_profile",
        }:
            raise StateError("Persisted state имеет неизвестную схему")
        if payload["version"] != 2:
            raise StateError("Версия persisted state не поддерживается")
        if not isinstance(payload["route"], str):
            raise StateError("Persisted VLESS route должен быть строкой")
        route = parse_link(payload["route"])
        if route is None:
            raise StateError("Persisted VLESS route некорректен")
        try:
            address = str(ipaddress.ip_address(payload["resolved_address"]))
        except (ValueError, TypeError) as exc:
            raise StateError("Persisted resolved address некорректен") from exc
        try:
            routing_profile = RoutingProfile(payload["routing_profile"])
        except (TypeError, ValueError) as exc:
            raise StateError("Persisted routing profile некорректен") from exc
        return StoredRoute(
            route=route,
            resolved_address=address,
            routing_profile=routing_profile,
        )

    def remove(self) -> None:
        self.path.unlink(missing_ok=True)
