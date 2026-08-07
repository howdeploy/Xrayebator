"""Connection lifecycle independent from Qt and concrete tunnel backends."""

from __future__ import annotations

from collections.abc import Callable
from dataclasses import dataclass, replace
from enum import Enum
from typing import Protocol

from .routing import RoutingProfile
from .subscription import VlessLink


class ConnectionState(str, Enum):
    DISCONNECTED = "disconnected"
    PREPARING = "preparing"
    CONNECTING = "connecting"
    VERIFYING = "verifying"
    CONNECTED = "connected"
    SWITCHING = "switching"
    DISCONNECTING = "disconnecting"
    RECOVERING = "recovering"
    ERROR = "error"


class ConnectionMode(str, Enum):
    SYSTEM_PROXY = "system_proxy"
    TUN = "tun"


@dataclass(frozen=True)
class ConnectionSnapshot:
    state: ConnectionState = ConnectionState.DISCONNECTED
    mode: ConnectionMode | None = None
    route: VlessLink | None = None
    routing_profile: RoutingProfile | None = None
    external_ip: str | None = None
    error: str | None = None


class ConnectionError(RuntimeError):
    """Connection lifecycle operation failed."""


class InvalidTransition(ConnectionError):
    """Operation is not allowed from the current state."""


class RouteSwitchError(ConnectionError):
    """Candidate route failed; the previous route may have been restored."""


class TunnelBackend(Protocol):
    """Operations implemented by system-proxy and privileged TUN backends."""

    def prepare(
        self,
        route: VlessLink,
        mode: ConnectionMode,
        routing_profile: RoutingProfile,
    ) -> None: ...

    def start(
        self,
        route: VlessLink,
        mode: ConnectionMode,
        routing_profile: RoutingProfile,
    ) -> None: ...

    def verify(self) -> str | None: ...

    def replace(
        self,
        route: VlessLink,
        mode: ConnectionMode,
        routing_profile: RoutingProfile,
    ) -> None: ...

    def stop(self) -> None: ...


Observer = Callable[[ConnectionSnapshot], None]


class ConnectionController:
    """Synchronous state machine; UI code runs operations in a worker thread."""

    def __init__(self, backend: TunnelBackend):
        self._backend = backend
        self._snapshot = ConnectionSnapshot()
        self._observers: list[Observer] = []

    @property
    def snapshot(self) -> ConnectionSnapshot:
        return self._snapshot

    def subscribe(self, observer: Observer) -> Callable[[], None]:
        self._observers.append(observer)
        observer(self._snapshot)

        def unsubscribe() -> None:
            if observer in self._observers:
                self._observers.remove(observer)

        return unsubscribe

    def _transition(self, state: ConnectionState, **changes) -> None:
        self._snapshot = replace(self._snapshot, state=state, **changes)
        for observer in tuple(self._observers):
            observer(self._snapshot)

    def connect(
        self,
        route: VlessLink,
        mode: ConnectionMode,
        routing_profile: RoutingProfile = RoutingProfile.FULL,
    ) -> ConnectionSnapshot:
        if self._snapshot.state not in {
            ConnectionState.DISCONNECTED,
            ConnectionState.ERROR,
        }:
            raise InvalidTransition(
                f"Нельзя подключиться из состояния {self._snapshot.state.value}"
            )

        self._transition(
            ConnectionState.PREPARING,
            mode=mode,
            route=route,
            routing_profile=routing_profile,
            external_ip=None,
            error=None,
        )
        try:
            self._backend.prepare(route, mode, routing_profile)
            self._transition(ConnectionState.CONNECTING)
            self._backend.start(route, mode, routing_profile)
            self._transition(ConnectionState.VERIFYING)
            external_ip = self._backend.verify()
            if not external_ip:
                raise ConnectionError(
                    "Туннель запущен, но проверка внешнего IP не прошла"
                )
        except Exception as exc:
            self._stop_after_failure()
            self._transition(ConnectionState.ERROR, error=str(exc), external_ip=None)
            raise ConnectionError(str(exc)) from exc

        self._transition(
            ConnectionState.CONNECTED,
            external_ip=external_ip,
            error=None,
        )
        return self._snapshot

    def disconnect(self) -> ConnectionSnapshot:
        if self._snapshot.state == ConnectionState.DISCONNECTED:
            return self._snapshot
        if self._snapshot.state == ConnectionState.DISCONNECTING:
            raise InvalidTransition("Отключение уже выполняется")

        self._transition(ConnectionState.DISCONNECTING, error=None)
        try:
            self._backend.stop()
        except Exception as exc:
            self._transition(ConnectionState.ERROR, error=str(exc))
            raise ConnectionError(str(exc)) from exc

        self._transition(
            ConnectionState.DISCONNECTED,
            mode=None,
            route=None,
            routing_profile=None,
            external_ip=None,
            error=None,
        )
        return self._snapshot

    def switch_route(self, route: VlessLink) -> ConnectionSnapshot:
        if self._snapshot.state != ConnectionState.CONNECTED:
            raise InvalidTransition(
                "Маршрут можно менять только при активном соединении"
            )
        previous = self._snapshot.route
        mode = self._snapshot.mode
        routing_profile = self._snapshot.routing_profile
        if previous is None or mode is None or routing_profile is None:
            raise ConnectionError(
                "Активное соединение не содержит маршрут, профиль или режим"
            )
        if route.raw == previous.raw:
            return self._snapshot
        return self._switch_target(route, routing_profile)

    def switch_profile(
        self,
        routing_profile: RoutingProfile,
    ) -> ConnectionSnapshot:
        if self._snapshot.state != ConnectionState.CONNECTED:
            raise InvalidTransition(
                "Routing profile можно менять только при активном соединении"
            )
        route = self._snapshot.route
        if route is None:
            raise ConnectionError("Активное соединение не содержит маршрут")
        if routing_profile == self._snapshot.routing_profile:
            return self._snapshot
        return self._switch_target(route, routing_profile)

    def _switch_target(
        self,
        route: VlessLink,
        routing_profile: RoutingProfile,
    ) -> ConnectionSnapshot:
        previous = self._snapshot.route
        previous_profile = self._snapshot.routing_profile
        mode = self._snapshot.mode
        if previous is None or previous_profile is None or mode is None:
            raise ConnectionError(
                "Активное соединение не содержит маршрут, профиль или режим"
            )

        self._transition(
            ConnectionState.SWITCHING,
            route=route,
            routing_profile=routing_profile,
            external_ip=None,
            error=None,
        )
        try:
            self._backend.replace(route, mode, routing_profile)
            external_ip = self._backend.verify()
            if not external_ip:
                raise ConnectionError("Новый маршрут не прошёл проверку")
        except Exception as candidate_exc:
            self._transition(
                ConnectionState.RECOVERING,
                route=previous,
                routing_profile=previous_profile,
                error=str(candidate_exc),
            )
            try:
                self._backend.replace(previous, mode, previous_profile)
                external_ip = self._backend.verify()
                if not external_ip:
                    raise ConnectionError("Предыдущий маршрут не прошёл проверку")
            except Exception as rollback_exc:
                self._stop_after_failure()
                message = (
                    f"Новый маршрут не запустился ({candidate_exc}); "
                    f"откат также не удался ({rollback_exc})"
                )
                self._transition(
                    ConnectionState.ERROR,
                    route=None,
                    routing_profile=None,
                    external_ip=None,
                    error=message,
                )
                raise RouteSwitchError(message) from rollback_exc

            message = "Переключение не прошло проверку; восстановлены "
            message += f"{previous.label}, {previous_profile.label}: {candidate_exc}"
            self._transition(
                ConnectionState.CONNECTED,
                route=previous,
                routing_profile=previous_profile,
                external_ip=external_ip,
                error=message,
            )
            raise RouteSwitchError(message) from candidate_exc

        self._transition(
            ConnectionState.CONNECTED,
            route=route,
            routing_profile=routing_profile,
            external_ip=external_ip,
            error=None,
        )
        return self._snapshot

    def _stop_after_failure(self) -> None:
        try:
            self._backend.stop()
        except Exception:
            pass
