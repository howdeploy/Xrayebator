"""Unix-socket service exposing the narrow privileged TUN API.

grp/pwd импортируются лениво внутри функций — это Unix-only модули,
которых нет на Windows. Helper реально работает только на Linux/macOS,
но пакет должен импортироваться и на Windows (тесты, packaging).
"""

from __future__ import annotations

import argparse
import os
import signal
import socket
import struct
from pathlib import Path

from ..core.helper_protocol import (
    MAX_MESSAGE_BYTES,
    HelperRequest,
    ProtocolError,
    decode_request,
    encode_response,
    request_id_from_wire,
)
from .runtime import CORE_BINARY, RUNTIME_DIR, TunRuntime

DEFAULT_GROUP = "xrayebator"
DEFAULT_SOCKET = RUNTIME_DIR / "helper.sock"


class ServiceError(RuntimeError):
    """Privileged helper service setup or authorization failed."""


class HelperApplication:
    def __init__(self, runtime: TunRuntime):
        self.runtime = runtime

    def handle(self, request: HelperRequest) -> dict:
        if request.action == "status":
            return self.runtime.status()
        if request.action == "selftest":
            return self.runtime.selftest()
        if (
            request.action == "connect"
            and request.route is not None
            and request.routing_profile is not None
        ):
            return self.runtime.connect(
                request.route,
                request.routing_profile,
            )
        if (
            request.action == "switch"
            and request.route is not None
            and request.routing_profile is not None
        ):
            return self.runtime.switch(
                request.route,
                request.routing_profile,
            )
        if request.action == "verify":
            return self.runtime.verify()
        if request.action == "disconnect":
            return self.runtime.disconnect()
        raise ProtocolError(f"Команда {request.action} не поддерживается")


class HelperServer:
    def __init__(
        self,
        application: HelperApplication,
        *,
        socket_path: Path = DEFAULT_SOCKET,
        allowed_gid: int,
        allowed_uid: int | None = None,
    ):
        self.application = application
        self.socket_path = Path(socket_path)
        self.allowed_gid = allowed_gid
        self.allowed_uid = allowed_uid
        self._server: socket.socket | None = None
        self._stopping = False

    def serve_forever(self) -> None:
        self._prepare_socket()
        assert self._server is not None
        try:
            while not self._stopping:
                try:
                    connection, _ = self._server.accept()
                except TimeoutError:
                    continue
                with connection:
                    self._handle_connection(connection)
        finally:
            self.close()

    def stop(self, *_args) -> None:
        self._stopping = True

    def close(self) -> None:
        if self._server is not None:
            self._server.close()
            self._server = None
        self.socket_path.unlink(missing_ok=True)

    def _prepare_socket(self) -> None:
        self.socket_path.parent.mkdir(parents=True, exist_ok=True)
        os.chown(self.socket_path.parent, 0, self.allowed_gid)
        os.chmod(self.socket_path.parent, 0o750)
        self.socket_path.unlink(missing_ok=True)
        server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        server.bind(str(self.socket_path))
        os.chown(self.socket_path, 0, self.allowed_gid)
        os.chmod(self.socket_path, 0o660)
        server.listen(8)
        server.settimeout(1.0)
        self._server = server

    def _handle_connection(self, connection: socket.socket) -> None:
        request_id = ""
        try:
            uid, gid = peer_credentials(connection)
            if not authorized_peer(
                uid,
                gid,
                self.allowed_gid,
                allowed_uid=self.allowed_uid,
            ):
                raise ServiceError(f"UID {uid} не авторизован для TUN helper")
            wire = read_request(connection)
            request_id = request_id_from_wire(wire)
            request = decode_request(wire)
            request_id = request.request_id
            result = self.application.handle(request)
            response = encode_response(
                request_id,
                ok=True,
                state=result["state"],
                external_ip=result.get("external_ip"),
                error=result.get("error"),
            )
        except Exception as exc:
            response = encode_response(
                request_id,
                ok=False,
                state=self.application.runtime.status()["state"],
                error=str(exc),
            )
        connection.sendall(response)


def peer_credentials(connection: socket.socket) -> tuple[int, int]:
    if not hasattr(socket, "SO_PEERCRED"):
        raise ServiceError("SO_PEERCRED недоступен на этой платформе")
    raw = connection.getsockopt(
        socket.SOL_SOCKET,
        socket.SO_PEERCRED,
        struct.calcsize("3i"),
    )
    _pid, uid, gid = struct.unpack("3i", raw)
    return uid, gid


def authorized_peer(
    uid: int,
    primary_gid: int,
    allowed_gid: int,
    *,
    allowed_uid: int | None = None,
) -> bool:
    if uid == 0:
        return True
    if allowed_uid is not None:
        return uid == allowed_uid
    import pwd  # Unix-only (см. docstring модуля)

    try:
        username = pwd.getpwuid(uid).pw_name
        groups = os.getgrouplist(username, primary_gid)
    except (KeyError, OSError):
        return False
    return allowed_gid in groups


def read_request(connection: socket.socket) -> bytes:
    data = bytearray()
    while True:
        chunk = connection.recv(min(65536, MAX_MESSAGE_BYTES + 1 - len(data)))
        if not chunk:
            raise ProtocolError("Клиент закрыл соединение до конца запроса")
        data.extend(chunk)
        if len(data) > MAX_MESSAGE_BYTES:
            raise ProtocolError("Запрос helper слишком велик")
        newline = data.find(b"\n")
        if newline >= 0:
            if data[newline + 1 :]:
                raise ProtocolError("За одно соединение разрешён один запрос")
            return bytes(data[:newline])


def main() -> int:
    parser = argparse.ArgumentParser(description="Privileged Xrayebator TUN helper")
    parser.add_argument("--socket", type=Path, default=DEFAULT_SOCKET)
    parser.add_argument("--group", default=DEFAULT_GROUP)
    parser.add_argument("--socket-gid", type=int)
    parser.add_argument("--allow-uid", type=int)
    parser.add_argument("--core", type=Path, default=CORE_BINARY)
    args = parser.parse_args()

    if os.geteuid() != 0:
        parser.error("helper должен запускаться от root")
    if args.socket_gid is not None:
        if args.socket_gid < 0:
            parser.error("--socket-gid должен быть неотрицательным")
        allowed_gid = args.socket_gid
    else:
        import grp  # Unix-only (см. docstring модуля)

        try:
            allowed_gid = grp.getgrnam(args.group).gr_gid
        except KeyError as exc:
            parser.error(f"группа {args.group!r} не существует")
            raise AssertionError from exc

    runtime = TunRuntime(
        core_binary=args.core,
        runtime_dir=args.socket.parent,
    )
    runtime.recover()
    server = HelperServer(
        HelperApplication(runtime),
        socket_path=args.socket,
        allowed_gid=allowed_gid,
        allowed_uid=args.allow_uid,
    )
    signal.signal(signal.SIGTERM, server.stop)
    signal.signal(signal.SIGINT, server.stop)
    try:
        server.serve_forever()
    finally:
        try:
            runtime.disconnect()
        except Exception:
            pass
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
