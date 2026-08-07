"""Desktop-side client for the local privileged TUN helper."""

from __future__ import annotations

import json
import platform
import socket
from pathlib import Path

from .connection import ConnectionMode
from .helper_protocol import (
    MAX_MESSAGE_BYTES,
    ProtocolError,
    decode_response,
    encode_request,
)
from .routing import RoutingProfile
from .subscription import VlessLink

DEFAULT_SOCKET = Path("/run/xrayebator-gui/helper.sock")


class HelperError(RuntimeError):
    """Privileged helper is unavailable or rejected an operation."""


class HelperClient:
    def __init__(
        self,
        socket_path: Path = DEFAULT_SOCKET,
        *,
        timeout: float = 15.0,
    ):
        self.socket_path = Path(socket_path)
        self.timeout = timeout

    def available(self) -> bool:
        try:
            self.request("status")
        except HelperError:
            return False
        return True

    def request(
        self,
        action: str,
        route: VlessLink | None = None,
        routing_profile: RoutingProfile | None = None,
    ) -> dict:
        if platform.system() != "Linux":
            raise HelperError("Privileged TUN helper пока реализован только для Linux")
        wire = encode_request(action, route, routing_profile)
        request_id = json.loads(wire)["id"]
        try:
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
                client.settimeout(self.timeout)
                client.connect(str(self.socket_path))
                client.sendall(wire)
                response = _read_line(client)
        except (OSError, TimeoutError) as exc:
            raise HelperError(
                f"Privileged helper недоступен ({self.socket_path}): {exc}"
            ) from exc
        try:
            payload = decode_response(response, request_id)
        except ProtocolError as exc:
            raise HelperError(str(exc)) from exc
        if not payload["ok"]:
            raise HelperError(payload["error"] or "Операция helper не выполнена")
        return payload


def _read_line(sock: socket.socket) -> bytes:
    chunks = bytearray()
    while True:
        chunk = sock.recv(min(65536, MAX_MESSAGE_BYTES + 1 - len(chunks)))
        if not chunk:
            raise HelperError("Privileged helper закрыл соединение без ответа")
        chunks.extend(chunk)
        if len(chunks) > MAX_MESSAGE_BYTES:
            raise HelperError("Ответ privileged helper слишком велик")
        newline = chunks.find(b"\n")
        if newline >= 0:
            if chunks[newline + 1 :]:
                raise HelperError("Privileged helper вернул несколько сообщений")
            return bytes(chunks[:newline])


class HelperTunBackend:
    """Connection backend that delegates all privileged state to the helper."""

    def __init__(self, client: HelperClient | None = None):
        self.client = client or HelperClient()

    def prepare(
        self,
        route: VlessLink,
        mode: ConnectionMode,
        routing_profile: RoutingProfile,
    ) -> None:
        if mode != ConnectionMode.TUN:
            raise HelperError("HelperTunBackend поддерживает только TUN")
        self.client.request("status")

    def start(
        self,
        route: VlessLink,
        mode: ConnectionMode,
        routing_profile: RoutingProfile,
    ) -> None:
        if mode != ConnectionMode.TUN:
            raise HelperError("HelperTunBackend поддерживает только TUN")
        self.client.request("connect", route, routing_profile)

    def verify(self) -> str | None:
        return self.client.request("verify").get("external_ip")

    def replace(
        self,
        route: VlessLink,
        mode: ConnectionMode,
        routing_profile: RoutingProfile,
    ) -> None:
        if mode != ConnectionMode.TUN:
            raise HelperError("HelperTunBackend поддерживает только TUN")
        self.client.request("switch", route, routing_profile)

    def stop(self) -> None:
        self.client.request("disconnect")
