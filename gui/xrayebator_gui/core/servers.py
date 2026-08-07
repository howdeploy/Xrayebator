"""Хранилище серверов: JSON-файл + пароли в keyring.

Пароль никогда не попадает в JSON — только в системное хранилище ключей
(service "xrayebator-gui", key = id сервера).
"""

from __future__ import annotations

import json
import os
import stat
import sys
import tempfile
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

import keyring
from platformdirs import user_data_dir

APP_NAME = "xrayebator-gui"
KEYRING_SERVICE = "xrayebator-gui"


class ServerStore:
    """Список серверов в user_data_dir("xrayebator-gui")/servers.json."""

    def __init__(self, data_dir: Path | None = None):
        self._dir = data_dir or Path(user_data_dir(APP_NAME))
        self._dir.mkdir(parents=True, exist_ok=True)
        self._path = self._dir / "servers.json"

    def _load(self) -> list[dict[str, Any]]:
        if not self._path.exists():
            return []
        try:
            data = json.loads(self._path.read_text(encoding="utf-8"))
        except (json.JSONDecodeError, OSError):
            return []
        return data if isinstance(data, list) else []

    def _save(self, servers: list[dict[str, Any]]) -> None:
        fd, tmp_name = tempfile.mkstemp(
            prefix=f".{self._path.name}.",
            dir=self._dir,
        )
        try:
            # CI-2: os.fchmod() есть в POSIX, но отсутствует на Windows <3.13.
            # На Windows используем os.chmod() — права на не-POSIX всё равно не идут.
            if sys.platform == "win32":
                os.chmod(tmp_name, stat.S_IRUSR | stat.S_IWUSR)
            else:
                os.fchmod(fd, stat.S_IRUSR | stat.S_IWUSR)
            with os.fdopen(fd, "w", encoding="utf-8") as stream:
                fd = -1
                json.dump(servers, stream, ensure_ascii=False, indent=2)
                stream.flush()
                os.fsync(stream.fileno())
            os.replace(tmp_name, self._path)
        finally:
            if fd >= 0:
                os.close(fd)
            Path(tmp_name).unlink(missing_ok=True)

    def list(self) -> list[dict[str, Any]]:
        """Все серверы."""
        return self._load()

    def get(self, server_id: str) -> dict[str, Any] | None:
        for s in self._load():
            if s.get("id") == server_id:
                return s
        return None

    def add(
        self,
        *,
        name: str,
        host: str,
        port: int,
        user: str,
        auth_type: str,
        subscription_url: str,
        profile: str = "happ",
        password: str | None = None,
        key_path: str | None = None,
    ) -> dict[str, Any]:
        """Добавить сервер. Пароль уходит в keyring, не в JSON.

        Внимание: subscription_url — фактически секрет (токен подписки),
        поэтому храним JSON только локально в каталоге данных пользователя.
        """
        server = {
            "id": uuid.uuid4().hex,
            "name": name,
            "host": host,
            "port": port,
            "user": user,
            "auth_type": auth_type,  # "password" | "key"
            "subscription_url": subscription_url,
            "profile": profile,
            "key_path": key_path or "",
            "created_at": datetime.now(timezone.utc).isoformat(),
        }
        servers = self._load()
        servers.append(server)
        self._save(servers)
        if password:
            # keyring может быть недоступен (headless Linux, нет D-Bus secret
            # service). Сервер уже дописан в JSON — не роняем весь add(), лучше
            # просто не запомнить пароль (клиент попросит его снова при подключении).
            try:
                keyring.set_password(KEYRING_SERVICE, server["id"], password)
            except keyring.errors.KeyringError:
                pass
        return server

    def remove(self, server_id: str) -> None:
        """Удалить сервер и его пароль из keyring."""
        servers = [s for s in self._load() if s.get("id") != server_id]
        self._save(servers)
        try:
            keyring.delete_password(KEYRING_SERVICE, server_id)
        except keyring.errors.PasswordDeleteError:
            pass

    def get_password(self, server_id: str) -> str | None:
        """Пароль сервера из keyring (None, если не сохранён)."""
        try:
            return keyring.get_password(KEYRING_SERVICE, server_id)
        except keyring.errors.KeyringError:
            return None
