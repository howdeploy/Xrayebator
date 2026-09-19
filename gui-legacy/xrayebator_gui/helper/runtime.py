"""Stateful owner of Xray TUN, DNS and the Linux kill-switch guard."""

from __future__ import annotations

import os
import socket
import stat
from collections.abc import Callable
from dataclasses import replace
from pathlib import Path

from ..core.routing import RoutingProfile
from ..core.subscription import VlessLink
from ..core.xray import (
    XRAY_TUN_VERSION,
    XrayProcess,
    _installed_version,
    build_tun_client_config,
)
from .linux_network import LinuxNetwork
from .state import RouteStateStore

# Должен совпадать с INSTALL_ROOT в install-helper.sh — ядро ставится в /opt,
# а systemd-unit передаёт --core explicitly, т.ч. это значение — только дефолт
# для ручного запуска helper без --core.
CORE_BINARY = Path("/opt/xrayebator-gui/xray")
RUNTIME_DIR = Path("/run/xrayebator-gui")
TUN_INTERFACE = "xrayebator0"
OUTBOUND_MARK = 0x5852


class TunRuntimeError(RuntimeError):
    """Privileged TUN runtime operation failed."""


ProcessFactory = Callable[[Path, Path, Path], XrayProcess]
Resolver = Callable[[str, int], str]
BinaryValidator = Callable[[Path], None]


class TunRuntime:
    def __init__(
        self,
        *,
        core_binary: Path = CORE_BINARY,
        runtime_dir: Path = RUNTIME_DIR,
        network: LinuxNetwork | None = None,
        process_factory: ProcessFactory | None = None,
        resolver: Resolver | None = None,
        binary_validator: BinaryValidator | None = None,
        state_store: RouteStateStore | None = None,
    ):
        self.core_binary = Path(core_binary)
        self.runtime_dir = Path(runtime_dir)
        self.network = network or LinuxNetwork()
        self._process_factory = process_factory or _make_process
        self._resolver = resolver or resolve_server
        self._binary_validator = binary_validator or validate_core_binary
        self._state_store = state_store or RouteStateStore()
        self._process: XrayProcess | None = None
        self._state = "guarded_error" if self.network.guard_exists() else "disconnected"
        self._error: str | None = (
            "Обнаружен kill switch от предыдущего аварийного завершения"
            if self._state == "guarded_error"
            else None
        )
        self._external_ip: str | None = None
        self._resolved_routes: dict[str, VlessLink] = {}
        self._active_route_raw: str | None = None
        self._active_profile: RoutingProfile | None = None

    def recover(self) -> dict:
        """Restore the last verified route while preserving a stale guard."""
        if self._state != "guarded_error":
            return self._result()
        try:
            stored = self._state_store.load()
            if stored is None:
                return self._result()
            self.network.check_dependencies()
            self._binary_validator(self.core_binary)
            resolved = replace(
                stored.route,
                address=stored.resolved_address,
            )
            self._resolved_routes[stored.route.raw] = resolved
            self.network.enable_guard(TUN_INTERFACE, OUTBOUND_MARK)
            self._start_process(resolved, stored.routing_profile)
            self.network.configure_dns(TUN_INTERFACE)
        except Exception as exc:
            self._stop_process()
            self._state = "guarded_error"
            self._error = f"Автовосстановление TUN не удалось: {exc}"
            return self._result()
        self._state = "connected"
        self._error = None
        self._active_route_raw = stored.route.raw
        self._active_profile = stored.routing_profile
        return self._result()

    def status(self) -> dict:
        if self._state == "connected" and (
            self._process is None or not self._process.is_running()
        ):
            self._state = "guarded_error"
            self._error = "Xray остановился; kill switch оставлен закрытым"
            self._external_ip = None
        return self._result()

    def selftest(self) -> dict:
        self.network.check_dependencies()
        self._binary_validator(self.core_binary)
        self.network.validate_guard(TUN_INTERFACE, OUTBOUND_MARK)
        return self._result()

    def connect(
        self,
        route: VlessLink,
        routing_profile: RoutingProfile,
    ) -> dict:
        if self._state == "connected":
            if (
                route.raw == self._active_route_raw
                and routing_profile == self._active_profile
            ):
                return self._result()
            return self.switch(route, routing_profile)
        if self._state not in {"disconnected", "guarded_error"}:
            raise TunRuntimeError(f"Нельзя подключиться из состояния {self._state}")
        self._state = "connecting"
        self._error = None
        self._external_ip = None
        try:
            self.network.check_dependencies()
            self._binary_validator(self.core_binary)
            resolved = self._resolve(route)
            self.network.enable_guard(TUN_INTERFACE, OUTBOUND_MARK)
            self._start_process(resolved, routing_profile)
            self.network.configure_dns(TUN_INTERFACE)
            self._state_store.save(route, resolved.address, routing_profile)
        except Exception as exc:
            self._cleanup(remove_guard=True)
            self._state = "disconnected"
            self._error = str(exc)
            raise TunRuntimeError(str(exc)) from exc
        self._state = "connected"
        self._active_route_raw = route.raw
        self._active_profile = routing_profile
        return self._result()

    def switch(
        self,
        route: VlessLink,
        routing_profile: RoutingProfile,
    ) -> dict:
        if self._state not in {"connected", "guarded_error"}:
            raise TunRuntimeError("Маршрут можно менять только при активном TUN")
        self._state = "switching"
        self._error = None
        self._external_ip = None
        try:
            resolved = self._resolve(route)
            self.network.restore_dns(TUN_INTERFACE)
            self._stop_process()
            self._start_process(resolved, routing_profile)
            self.network.configure_dns(TUN_INTERFACE)
            self._state_store.save(route, resolved.address, routing_profile)
        except Exception as exc:
            self._stop_process()
            self._state = "guarded_error"
            self._error = str(exc)
            raise TunRuntimeError(
                f"Новый маршрут не запущен; kill switch закрыт: {exc}"
            ) from exc
        self._state = "connected"
        self._active_route_raw = route.raw
        self._active_profile = routing_profile
        return self._result()

    def verify(self) -> dict:
        status = self.status()
        if status["state"] != "connected" or self._process is None:
            raise TunRuntimeError(self._error or "Нельзя проверить неактивный TUN")
        external_ip = self._process.health_check_tun()
        if not external_ip:
            raise TunRuntimeError("TUN не прошёл проверку внешнего IP")
        self._external_ip = external_ip
        return self._result()

    def disconnect(self) -> dict:
        self._state = "disconnecting"
        errors = self._cleanup(remove_guard=True)
        self._state = "disconnected"
        self._external_ip = None
        self._active_route_raw = None
        self._active_profile = None
        self._error = "; ".join(errors) if errors else None
        try:
            self._state_store.remove()
        except Exception as exc:
            errors.append(f"persisted state: {exc}")
            self._error = "; ".join(errors)
        if errors:
            raise TunRuntimeError(self._error)
        return self._result()

    def _resolve(self, route: VlessLink) -> VlessLink:
        cached = self._resolved_routes.get(route.raw)
        if cached is not None:
            return cached
        address = self._resolver(route.address, route.port)
        resolved = replace(route, address=address)
        self._resolved_routes[route.raw] = resolved
        if len(self._resolved_routes) > 16:
            oldest = next(iter(self._resolved_routes))
            del self._resolved_routes[oldest]
        return resolved

    def _start_process(
        self,
        route: VlessLink,
        routing_profile: RoutingProfile,
    ) -> None:
        self.runtime_dir.mkdir(parents=True, exist_ok=True)
        os.chmod(self.runtime_dir, 0o750)
        process = self._process_factory(
            self.core_binary,
            self.runtime_dir / "config.json",
            self.runtime_dir / "xray.log",
        )
        config = build_tun_client_config(
            route,
            system="Linux",
            interface_name=TUN_INTERFACE,
            outbound_mark=OUTBOUND_MARK,
            routing_profile=routing_profile,
        )
        process.start(config)
        self._process = process

    def _stop_process(self) -> None:
        if self._process is None:
            return
        try:
            self._process.stop()
        finally:
            self._process = None

    def _cleanup(self, *, remove_guard: bool) -> list[str]:
        errors: list[str] = []
        try:
            self.network.restore_dns(TUN_INTERFACE)
        except Exception as exc:
            errors.append(f"DNS: {exc}")
        try:
            self._stop_process()
        except Exception as exc:
            errors.append(f"Xray: {exc}")
        if remove_guard:
            try:
                self.network.disable_guard()
            except Exception as exc:
                errors.append(f"kill switch: {exc}")
        return errors

    def _result(self) -> dict:
        return {
            "state": self._state,
            "external_ip": self._external_ip,
            "error": self._error,
        }


def _make_process(
    binary: Path,
    config_path: Path,
    stderr_path: Path,
) -> XrayProcess:
    return XrayProcess(
        binary,
        config_path=config_path,
        stderr_path=stderr_path,
    )


def validate_core_binary(path: Path) -> None:
    try:
        info = path.stat()
    except OSError as exc:
        raise TunRuntimeError(f"Xray core не установлен: {path}") from exc
    if not stat.S_ISREG(info.st_mode):
        raise TunRuntimeError(f"Xray core не является обычным файлом: {path}")
    if info.st_uid != 0 or info.st_mode & 0o022:
        raise TunRuntimeError(
            "Xray core должен принадлежать root и не быть доступен для записи "
            f"group/other: {path}"
        )
    if not info.st_mode & stat.S_IXUSR:
        raise TunRuntimeError(f"Xray core не исполняемый: {path}")
    version = _installed_version(path)
    if version != XRAY_TUN_VERSION:
        raise TunRuntimeError(
            f"Установлен Xray {version or '?'}, требуется {XRAY_TUN_VERSION}"
        )
    for resource in ("geoip.dat", "geosite.dat"):
        resource_path = path.parent / resource
        try:
            resource_info = resource_path.stat()
        except OSError as exc:
            raise TunRuntimeError(
                f"Не установлен routing resource: {resource_path}"
            ) from exc
        if (
            not stat.S_ISREG(resource_info.st_mode)
            or resource_info.st_uid != 0
            or resource_info.st_mode & 0o022
        ):
            raise TunRuntimeError(
                "Routing resource должен принадлежать root и не быть "
                f"доступен для записи group/other: {resource_path}"
            )


def resolve_server(host: str, port: int) -> str:
    try:
        records = socket.getaddrinfo(
            host,
            port,
            type=socket.SOCK_STREAM,
        )
    except socket.gaierror as exc:
        raise TunRuntimeError(f"Не удалось разрешить адрес VPS {host}: {exc}") from exc
    if not records:
        raise TunRuntimeError(f"DNS не вернул адрес VPS {host}")
    # Prefer IPv4 for the first desktop slice; IPv6 remains a valid fallback.
    records.sort(key=lambda item: item[0] != socket.AF_INET)
    return records[0][4][0]
