"""Strict JSON protocol shared by the desktop process and privileged helper."""

from __future__ import annotations

import json
import uuid
from dataclasses import dataclass
from typing import Any

from .routing import RoutingProfile
from .subscription import VlessLink, parse_link

PROTOCOL_VERSION = 1
MAX_MESSAGE_BYTES = 256 * 1024
COMMANDS = {
    "status",
    "selftest",
    "connect",
    "switch",
    "verify",
    "disconnect",
}


class ProtocolError(ValueError):
    """Malformed or unsupported helper message."""


@dataclass(frozen=True)
class HelperRequest:
    request_id: str
    action: str
    route: VlessLink | None = None
    routing_profile: RoutingProfile | None = None


def encode_request(
    action: str,
    route: VlessLink | None = None,
    routing_profile: RoutingProfile | None = None,
) -> bytes:
    if action not in COMMANDS:
        raise ProtocolError(f"Неизвестная команда helper: {action}")
    if action in {"connect", "switch"} and route is None:
        raise ProtocolError(f"Команда {action} требует маршрут")
    if action in {"connect", "switch"} and routing_profile is None:
        raise ProtocolError(f"Команда {action} требует routing profile")
    payload: dict[str, Any] = {
        "version": PROTOCOL_VERSION,
        "id": uuid.uuid4().hex,
        "action": action,
    }
    if route is not None:
        payload["route"] = route.raw
    if routing_profile is not None:
        payload["routing_profile"] = routing_profile.value
    return _encode(payload)


def decode_request(data: bytes) -> HelperRequest:
    payload = _decode(data)
    _require_exact_keys(
        payload,
        required={"version", "id", "action"},
        optional={"route", "routing_profile"},
    )
    if payload["version"] != PROTOCOL_VERSION:
        raise ProtocolError(
            f"Версия helper protocol {payload['version']} не поддерживается"
        )
    request_id = payload["id"]
    action = payload["action"]
    if not isinstance(request_id, str) or not _valid_request_id(request_id):
        raise ProtocolError("Некорректный request id")
    if not isinstance(action, str) or action not in COMMANDS:
        raise ProtocolError("Некорректная команда helper")
    route = None
    routing_profile = None
    if "route" in payload:
        if not isinstance(payload["route"], str):
            raise ProtocolError("Маршрут должен быть строкой vless://")
        route = parse_link(payload["route"])
        if route is None:
            raise ProtocolError("Некорректный VLESS-маршрут")
    if "routing_profile" in payload:
        try:
            routing_profile = RoutingProfile(payload["routing_profile"])
        except (ValueError, TypeError) as exc:
            raise ProtocolError("Некорректный routing profile") from exc
    if action in {"connect", "switch"} and route is None:
        raise ProtocolError(f"Команда {action} требует маршрут")
    if action in {"connect", "switch"} and routing_profile is None:
        raise ProtocolError(f"Команда {action} требует routing profile")
    if action not in {"connect", "switch"} and (
        route is not None or routing_profile is not None
    ):
        raise ProtocolError(f"Команда {action} не принимает маршрут/профиль")
    return HelperRequest(
        request_id=request_id,
        action=action,
        route=route,
        routing_profile=routing_profile,
    )


def encode_response(
    request_id: str,
    *,
    ok: bool,
    state: str,
    external_ip: str | None = None,
    error: str | None = None,
) -> bytes:
    payload = {
        "version": PROTOCOL_VERSION,
        "id": request_id,
        "ok": ok,
        "state": state,
        "external_ip": external_ip,
        "error": error,
    }
    return _encode(payload)


def decode_response(data: bytes, expected_id: str) -> dict[str, Any]:
    payload = _decode(data)
    _require_exact_keys(
        payload,
        required={
            "version",
            "id",
            "ok",
            "state",
            "external_ip",
            "error",
        },
    )
    if payload["version"] != PROTOCOL_VERSION:
        raise ProtocolError("Несовместимая версия privileged helper")
    if payload["id"] != expected_id:
        raise ProtocolError("Ответ privileged helper имеет другой request id")
    if not isinstance(payload["ok"], bool):
        raise ProtocolError("Поле ok в ответе helper должно быть bool")
    if not isinstance(payload["state"], str):
        raise ProtocolError("Поле state в ответе helper должно быть строкой")
    for key in ("external_ip", "error"):
        if payload[key] is not None and not isinstance(payload[key], str):
            raise ProtocolError(f"Поле {key} в ответе helper некорректно")
    return payload


def request_id_from_wire(data: bytes) -> str:
    """Best-effort id extraction for an error response."""
    try:
        value = json.loads(data.decode("utf-8")).get("id", "")
    except (UnicodeDecodeError, json.JSONDecodeError, AttributeError):
        return ""
    return value if isinstance(value, str) and _valid_request_id(value) else ""


def _encode(payload: dict[str, Any]) -> bytes:
    data = json.dumps(
        payload,
        ensure_ascii=False,
        separators=(",", ":"),
    ).encode("utf-8")
    if len(data) > MAX_MESSAGE_BYTES:
        raise ProtocolError("Сообщение helper слишком велико")
    return data + b"\n"


def _decode(data: bytes) -> dict[str, Any]:
    if len(data) > MAX_MESSAGE_BYTES:
        raise ProtocolError("Сообщение helper слишком велико")
    try:
        payload = json.loads(data.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise ProtocolError("Некорректный JSON helper protocol") from exc
    if not isinstance(payload, dict):
        raise ProtocolError("Сообщение helper должно быть JSON-объектом")
    return payload


def _require_exact_keys(
    payload: dict[str, Any],
    *,
    required: set[str],
    optional: set[str] | None = None,
) -> None:
    optional = optional or set()
    missing = required - payload.keys()
    unknown = payload.keys() - required - optional
    if missing:
        raise ProtocolError(
            "В сообщении helper отсутствуют поля: " + ", ".join(sorted(missing))
        )
    if unknown:
        raise ProtocolError(
            "Неизвестные поля helper protocol: " + ", ".join(sorted(unknown))
        )


def _valid_request_id(value: str) -> bool:
    return bool(value) and len(value) <= 64 and value.isalnum()
