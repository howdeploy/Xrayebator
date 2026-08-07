"""Обёртка над paramiko: подключение, стриминг команд, SFTP, sudo.

Host key policy — TOFU: свой known_hosts в каталоге данных приложения.
При смене ключа хоста бросается HostKeyChanged.
"""

from __future__ import annotations

import shlex
import time
from collections.abc import Callable
from pathlib import Path

import paramiko
from platformdirs import user_data_dir

APP_NAME = "xrayebator-gui"


class SSHError(Exception):
    """Базовая ошибка SSH-слоя."""


class SSHAuthError(SSHError):
    """Ошибка аутентификации (пароль/ключ)."""


class HostKeyChanged(SSHError):
    """Ключ хоста изменился по сравнению с сохранённым (возможный MITM)."""


def default_known_hosts() -> Path:
    """Путь к known_hosts приложения (TOFU)."""
    d = Path(user_data_dir(APP_NAME))
    d.mkdir(parents=True, exist_ok=True)
    return d / "known_hosts"


class _TOFUHostKeyPolicy(paramiko.client.MissingHostKeyPolicy):
    """Trust On First Use: новый ключ сохраняется, изменённый — ошибка."""

    def __init__(self, known_hosts: Path):
        self._path = known_hosts

    def missing_host_key(self, client, hostname, key):
        # Сюда попадаем только если ключа нет в known_hosts вообще —
        # paramiko сам бросит RejectKey/SSHException при несовпадении.
        client._host_keys.add(hostname, key.get_name(), key)
        client.save_host_keys(str(self._path))


class SSHClient:
    """Тонкая обёртка над paramiko.SSHClient."""

    def __init__(self, known_hosts: Path | None = None):
        self._client: paramiko.SSHClient | None = None
        self._known_hosts = known_hosts or default_known_hosts()
        self._sudo_password: str | None = None
        self._need_sudo = False

    def connect(
        self,
        host: str,
        port: int = 22,
        user: str = "root",
        password: str | None = None,
        key_path: str | None = None,
        sudo_password: str | None = None,
        timeout: float = 15.0,
    ) -> None:
        """Подключиться к серверу. TOFU для host key."""
        client = paramiko.SSHClient()
        try:
            client.load_host_keys(str(self._known_hosts))
        except (OSError, paramiko.SSHException):
            # Повреждённый known_hosts — начинаем с чистого листа.
            pass
        client.set_missing_host_key_policy(_TOFUHostKeyPolicy(self._known_hosts))
        try:
            client.connect(
                hostname=host,
                port=port,
                username=user,
                password=password if not key_path else None,
                key_filename=(str(Path(key_path).expanduser()) if key_path else None),
                timeout=timeout,
                banner_timeout=timeout,
                auth_timeout=timeout,
                look_for_keys=False,
                allow_agent=False,
            )
        except paramiko.AuthenticationException as e:
            client.close()
            raise SSHAuthError(
                f"Аутентификация не удалась для {user}@{host}: {e}"
            ) from e
        except paramiko.SSHException as e:
            client.close()
            msg = str(e)
            # Изменившийся ключ хоста paramiko сообщает как SSHException.
            if "not found in known_hosts" not in msg and (
                "host key" in msg.lower() or "mismatch" in msg.lower()
            ):
                raise HostKeyChanged(
                    f"Ключ хоста {host} изменился! Возможна атака MITM.\n"
                    f"Если сервер переустанавливался — удалите запись в {self._known_hosts}"
                ) from e
            raise SSHError(f"SSH-ошибка при подключении к {host}:{port}: {e}") from e
        except (TimeoutError, OSError) as e:
            client.close()
            raise SSHError(f"Не удалось подключиться к {host}:{port}: {e}") from e

        self._client = client
        self._need_sudo = user != "root"
        self._sudo_password = sudo_password or password

    @property
    def connected(self) -> bool:
        return self._client is not None

    def _wrap_sudo(self, command: str) -> tuple[str, str | None]:
        """Обернуть команду в sudo, если пользователь не root.

        Возвращает (команда, пароль_для_stdin или None).
        """
        if not self._need_sudo:
            return command, None
        if self._sudo_password is None:
            return f"sudo -n bash -c {shlex.quote(command)}", None
        wrapped = f"sudo -S -p '' bash -c {shlex.quote(command)}"
        return wrapped, self._sudo_password

    def run_streaming(
        self,
        command: str,
        on_line: Callable[[str], None] | None = None,
        timeout: float | None = 600.0,
        *,
        privileged: bool = True,
    ) -> int:
        """Выполнить команду, построчно стримя stdout+stderr в on_line.

        Возвращает exit code.
        """
        if self._client is None:
            raise SSHError("SSHClient не подключён")
        if privileged:
            cmd, sudo_pw = self._wrap_sudo(command)
        else:
            cmd, sudo_pw = command, None
        chan = self._client.get_transport().open_session(timeout=timeout)  # type: ignore[union-attr]
        chan.set_combine_stderr(True)
        chan.settimeout(timeout)
        chan.exec_command(cmd)
        if sudo_pw is not None:
            chan.sendall(sudo_pw + "\n")
        buf = b""
        while True:
            if chan.exit_status_ready() and not chan.recv_ready():
                break
            if chan.recv_ready():
                data = chan.recv(4096)
                if not data:
                    break
                buf += data
                while b"\n" in buf:
                    line, buf = buf.split(b"\n", 1)
                    if on_line:
                        on_line(line.decode("utf-8", errors="replace"))
            elif chan.exit_status_ready():
                break
            else:
                time.sleep(0.05)
        # Дочитываем остаток после завершения канала.
        while chan.recv_ready():
            data = chan.recv(4096)
            if not data:
                break
            buf += data
        if buf and on_line:
            for line in buf.split(b"\n"):
                on_line(line.decode("utf-8", errors="replace"))
        return chan.recv_exit_status()

    def run(
        self,
        command: str,
        timeout: float | None = 60.0,
        *,
        privileged: bool = True,
    ) -> tuple[int, str]:
        """Выполнить команду и вернуть (exit code, весь вывод)."""
        out: list[str] = []
        rc = self.run_streaming(
            command,
            on_line=out.append,
            timeout=timeout,
            privileged=privileged,
        )
        return rc, "\n".join(out)

    def upload(self, local_path: str | Path, remote_path: str) -> None:
        """Загрузить файл на сервер через SFTP."""
        if self._client is None:
            raise SSHError("SSHClient не подключён")
        sftp = self._client.open_sftp()
        try:
            sftp.put(str(local_path), remote_path)
        finally:
            sftp.close()

    def upload_text(self, local_path: str | Path, remote_path: str) -> None:
        """Загрузить текстовый файл через SFTP с нормализацией переводов строк в LF.

        Bash на сервере не переваривает CRLF: `$'\\r': command not found`, сломанный
        shebang (`#!/bin/bash\\r`), неработающие heredoc. Рабочая копия git на Windows
        (core.autocrlf=true) содержит CRLF, поэтому здесь явно стрипаём `\\r`.
        """
        if self._client is None:
            raise SSHError("SSHClient не подключён")
        data = Path(local_path).read_bytes()
        data = data.replace(b"\r\n", b"\n").replace(b"\r", b"\n")
        sftp = self._client.open_sftp()
        try:
            with sftp.open(remote_path, "wb") as remote_file:
                remote_file.write(data)
        finally:
            sftp.close()

    def close(self) -> None:
        if self._client is not None:
            self._client.close()
            self._client = None
