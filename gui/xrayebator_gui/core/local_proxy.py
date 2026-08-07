"""Concrete local Xray backend for the current system-proxy connection mode."""

from __future__ import annotations

from collections.abc import Callable
from pathlib import Path

from . import proxy
from .connection import ConnectionMode
from .routing import RoutingProfile
from .subscription import VlessLink
from .xray import HTTP_PORT, XrayError, XrayProcess, build_client_config, ensure_binary


class LocalProxyBackend:
    """Run Xray locally and expose it through the operating-system proxy.

    This backend intentionally rejects TUN. TUN needs a privileged service,
    route/DNS guards, and separate verification before it can share this
    lifecycle contract.
    """

    def __init__(
        self,
        *,
        ensure_binary_fn: Callable[[], Path] = ensure_binary,
        process_factory: Callable[[Path], XrayProcess] = XrayProcess,
    ):
        self._ensure_binary = ensure_binary_fn
        self._process_factory = process_factory
        self._process: XrayProcess | None = None
        self._pending_config: dict | None = None
        self._proxy_snapshot: proxy.ProxySnapshot | None = None

    def prepare(
        self,
        route: VlessLink,
        mode: ConnectionMode,
        routing_profile: RoutingProfile,
    ) -> None:
        if mode != ConnectionMode.SYSTEM_PROXY:
            raise XrayError(
                "TUN ещё не активирован: требуется privileged network service"
            )
        binary = self._ensure_binary()
        if self._process is None:
            self._process = self._process_factory(binary)
        self._pending_config = build_client_config(
            route,
            routing_profile=routing_profile,
        )

    def start(
        self,
        route: VlessLink,
        mode: ConnectionMode,
        routing_profile: RoutingProfile,
    ) -> None:
        if mode != ConnectionMode.SYSTEM_PROXY:
            raise XrayError("LocalProxyBackend поддерживает только system proxy")
        if self._process is None or self._pending_config is None:
            raise XrayError("Backend не подготовлен к запуску")

        snapshot = proxy.capture()
        self._process.start(self._pending_config)
        try:
            enabled = proxy.enable(port=HTTP_PORT)
        except Exception:
            proxy.restore(snapshot)
            self._process.stop()
            raise
        if not enabled:
            proxy.restore(snapshot)
            self._process.stop()
            raise XrayError(
                "Не удалось включить системный proxy автоматически. "
                f"Настройте HTTP proxy 127.0.0.1:{HTTP_PORT} вручную."
            )
        self._proxy_snapshot = snapshot

    def verify(self) -> str | None:
        if self._process is None:
            return None
        return self._process.health_check()

    def replace(
        self,
        route: VlessLink,
        mode: ConnectionMode,
        routing_profile: RoutingProfile,
    ) -> None:
        """Replace Xray config while keeping the system proxy guard enabled."""
        if mode != ConnectionMode.SYSTEM_PROXY:
            raise XrayError("LocalProxyBackend поддерживает только system proxy")
        binary = self._ensure_binary()
        if self._process is None:
            self._process = self._process_factory(binary)
        self._pending_config = build_client_config(
            route,
            routing_profile=routing_profile,
        )
        self._process.start(self._pending_config)

    def stop(self) -> None:
        errors: list[str] = []
        if self._proxy_snapshot is not None:
            try:
                restored = proxy.restore(self._proxy_snapshot)
                if not restored:
                    errors.append("system proxy: прежние настройки не восстановлены")
            except Exception as exc:  # cleanup must still stop Xray
                errors.append(f"system proxy: {exc}")
            self._proxy_snapshot = None
        if self._process is not None:
            try:
                self._process.stop()
            except Exception as exc:
                errors.append(f"xray: {exc}")
        self._pending_config = None
        if errors:
            raise XrayError("; ".join(errors))
