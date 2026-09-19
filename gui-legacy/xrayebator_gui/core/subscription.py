"""Загрузка и разбор подписки Xrayebator (список vless:// ссылок).

Сервер отдаёт либо plain-text список ссылок (HAPP), либо base64 от него
(v2rayNG) — определяем по содержимому.
"""

from __future__ import annotations

import base64
import binascii
import re
from dataclasses import dataclass
from urllib.parse import parse_qs, unquote, urlparse


class SubscriptionError(Exception):
    """Ошибка загрузки или разбора подписки."""


@dataclass
class VlessLink:
    """Разобранная vless:// ссылка."""

    raw: str
    address: str
    port: int
    uuid: str
    network: str = "tcp"  # tcp / grpc / xhttp
    security: str = ""
    sni: str = ""
    fingerprint: str = ""  # fp
    public_key: str = ""  # pbk
    short_id: str = ""  # sid
    flow: str = ""
    path: str = ""
    host: str = ""
    service_name: str = ""  # grpc serviceName
    encryption: str = "none"
    remark: str = ""

    @property
    def label(self) -> str:
        """Короткая метка маршрута для UI: transport:port."""
        flow = f"+{self.flow}" if self.flow else ""
        return f"{self.network}{flow}:{self.port}"


def fetch(url: str, timeout: float = 20.0) -> str:
    """Скачать тело подписки. TLS-сертификат Let's Encrypt — verify=True."""
    import requests

    try:
        resp = requests.get(url, timeout=timeout, verify=True)
        resp.raise_for_status()
    except requests.exceptions.SSLError as e:
        raise SubscriptionError("Ошибка TLS при загрузке подписки") from e
    except requests.exceptions.Timeout as e:
        raise SubscriptionError(f"Таймаут загрузки подписки ({timeout} с)") from e
    except requests.exceptions.HTTPError as e:
        status = e.response.status_code if e.response is not None else "?"
        raise SubscriptionError(f"Сервер подписки ответил HTTP {status}") from e
    except requests.exceptions.RequestException as e:
        raise SubscriptionError(
            f"Не удалось загрузить подписку ({type(e).__name__})"
        ) from e
    return resp.text


def _try_base64(body: str) -> str | None:
    """Попытаться декодировать тело как base64; вернуть текст или None."""
    compact = re.sub(r"\s+", "", body)
    if not compact:
        return None
    try:
        decoded = base64.b64decode(compact, validate=True)
        text = decoded.decode("utf-8")
    except (binascii.Error, UnicodeDecodeError, ValueError):
        return None
    return text if "vless://" in text else None


def parse(body: str) -> list[VlessLink]:
    """Разобрать тело подписки в список VlessLink.

    Строки без vless:// (служебные строки HAPP, комментарии) игнорируются.
    """
    decoded = _try_base64(body)
    if decoded is not None:
        body = decoded

    links: list[VlessLink] = []
    for line in body.splitlines():
        line = line.strip()
        if not line.startswith("vless://"):
            continue
        link = parse_link(line)
        if link is not None:
            links.append(link)
    return links


def parse_link(url: str) -> VlessLink | None:
    """Разобрать одну vless:// ссылку."""
    try:
        u = urlparse(url)
    except ValueError:
        return None
    if not u.username or not u.hostname:
        return None
    q = {k: v[0] for k, v in parse_qs(u.query).items()}
    try:
        port = u.port or 443
    except ValueError:
        return None
    return VlessLink(
        raw=url,
        address=u.hostname,
        port=port,
        uuid=unquote(u.username),
        network=q.get("type", "tcp"),
        security=q.get("security", ""),
        sni=q.get("sni", ""),
        fingerprint=q.get("fp", ""),
        public_key=q.get("pbk", ""),
        short_id=q.get("sid", ""),
        flow=q.get("flow", ""),
        path=unquote(q.get("path", "")),
        host=q.get("host", ""),
        service_name=q.get("serviceName", ""),
        encryption=q.get("encryption", "none"),
        remark=unquote(u.fragment or ""),
    )


def pick_default(links: list[VlessLink]) -> VlessLink | None:
    """Маршрут по умолчанию: первый tcp+vision, иначе просто первый."""
    if not links:
        return None
    for link in links:
        if link.network == "tcp" and link.flow == "xtls-rprx-vision":
            return link
    return links[0]
