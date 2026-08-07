"""Оркестратор развёртывания Xrayebator на VPS.

Deployer — чистый Python (тестируется без Qt), DeployThread — тонкая
Qt-обёртка с сигналами для UI.
"""

from __future__ import annotations

import json
import re
import shlex
from collections.abc import Callable
from pathlib import Path
from typing import Protocol

# Корень репозитория: gui/xrayebator_gui/core/deploy.py -> ../../../
REPO_ROOT = Path(__file__).resolve().parents[3]

# Поддерживаемые ОС: {id: {версии}}
SUPPORTED_OS = {
    "debian": {"12", "13"},
    "ubuntu": {"22.04", "24.04"},
}

STEPS = [
    "Подключение по SSH",
    "Проверка операционной системы",
    "Загрузка install.sh и xrayebator",
    "Установка Xrayebator (install.sh)",
    "Установка локальной версии xrayebator",
    "Создание профиля и подписки (quickstart)",
    "Сохранение сервера",
]


class DeployError(Exception):
    """Ошибка развёртывания с человекочитаемым сообщением."""


class UnsupportedOSError(DeployError):
    """ОС сервера не поддерживается."""


class SSHLike(Protocol):
    """Минимальный интерфейс SSH-клиента, нужный Deployer'у."""

    def connect(
        self,
        host: str,
        port: int = 22,
        user: str = "root",
        password: str | None = None,
        key_path: str | None = None,
        sudo_password: str | None = None,
    ) -> None: ...

    def run_streaming(
        self,
        command: str,
        on_line: Callable[[str], None] | None = None,
        timeout: float | None = 600.0,
        *,
        privileged: bool = True,
    ) -> int: ...

    def upload(self, local_path: str | Path, remote_path: str) -> None: ...

    def close(self) -> None: ...


def parse_os_release(text: str) -> tuple[str, str]:
    """Извлечь (ID, VERSION_ID) из содержимого /etc/os-release."""
    os_id = version = ""
    for line in text.splitlines():
        m = re.match(r"^([A-Z_]+)=(.*)$", line.strip())
        if not m:
            continue
        key, val = m.group(1), m.group(2).strip().strip('"')
        if key == "ID":
            os_id = val.lower()
        elif key == "VERSION_ID":
            version = val
    return os_id, version


def check_os_supported(text: str) -> tuple[str, str]:
    """Проверить ОС по /etc/os-release; бросить UnsupportedOSError."""
    os_id, version = parse_os_release(text)
    if os_id not in SUPPORTED_OS or version not in SUPPORTED_OS[os_id]:
        supported = ", ".join(
            f"{k} {'/'.join(sorted(v))}" for k, v in SUPPORTED_OS.items()
        )
        raise UnsupportedOSError(
            f"Неподдерживаемая ОС сервера: {os_id or '?'} {version or '?'}.\n"
            f"Поддерживаются: {supported}"
        )
    return os_id, version


class Deployer:
    """Чистый оркестратор развёртывания (без Qt)."""

    def __init__(
        self,
        ssh_client: SSHLike,
        *,
        host: str,
        email: str,
        port: int = 22,
        user: str = "root",
        password: str | None = None,
        key_path: str | None = None,
        sudo_password: str | None = None,
        repo_root: Path = REPO_ROOT,
        on_step: Callable[[int, str], None] | None = None,
        on_log: Callable[[str], None] | None = None,
    ):
        self.ssh = ssh_client
        self.host = host
        self.port = port
        self.user = user
        self.password = password
        self.key_path = key_path
        self.sudo_password = sudo_password
        self.email = email
        self.repo_root = Path(repo_root)
        self._on_step = on_step or (lambda i, name: None)
        self._on_log = on_log or (lambda line: None)

    def _step(self, idx: int) -> None:
        self._on_step(idx, STEPS[idx])

    def _run_checked(
        self,
        cmd: str,
        timeout: float = 1800.0,
        what: str = "",
        *,
        privileged: bool = True,
    ) -> list[str]:
        lines: list[str] = []

        def collect(line: str) -> None:
            lines.append(line)
            self._on_log(redact_log_line(line))

        rc = self.ssh.run_streaming(
            cmd,
            on_line=collect,
            timeout=timeout,
            privileged=privileged,
        )
        if rc != 0:
            raise DeployError(
                f"Команда завершилась с кодом {rc}: {what or cmd}\n"
                f"Последние строки вывода:\n"
                + "\n".join(redact_log_line(line) for line in lines[-5:])
            )
        return lines

    def run(self) -> dict:
        """Выполнить все шаги. Возвращает dict результата quickstart.

        {"ok": True, "subscription_url": ..., "base_url": ..., "profile": ...}
        """
        install_sh = self.repo_root / "install.sh"
        xrayebator_bin = self.repo_root / "xrayebator"
        if not install_sh.is_file() or not xrayebator_bin.is_file():
            raise DeployError(
                f"Не найдены install.sh/xrayebator в корне репозитория: {self.repo_root}"
            )

        remote_dir: str | None = None
        try:
            # 1. Подключение
            self._step(0)
            self.ssh.connect(
                self.host,
                self.port,
                self.user,
                password=self.password,
                key_path=self.key_path,
                sudo_password=self.sudo_password,
            )

            # 2. Проверка ОС
            self._step(1)
            os_lines: list[str] = []
            rc = self.ssh.run_streaming(
                "cat /etc/os-release",
                on_line=os_lines.append,
                timeout=30,
                privileged=False,
            )
            if rc != 0:
                raise DeployError("Не удалось прочитать /etc/os-release на сервере")
            os_id, version = check_os_supported("\n".join(os_lines))
            self._on_log(f"ОС сервера: {os_id} {version} — поддерживается")

            # 3. Загрузка файлов
            self._step(2)
            staging_lines = self._run_checked(
                "mktemp -d /tmp/xrayebator-deploy.XXXXXXXXXX",
                timeout=30,
                what="mktemp",
                privileged=False,
            )
            staging_dir = staging_lines[-1].strip() if staging_lines else ""
            if not re.fullmatch(
                r"/tmp/xrayebator-deploy\.[A-Za-z0-9]{6,32}",
                staging_dir,
            ):
                raise DeployError(
                    f"Сервер вернул небезопасный временный путь: {staging_dir!r}"
                )
            remote_dir = staging_dir
            # upload_text: bash-скрипты требуют LF (Windows-чекаут даёт CRLF —
            # сырой sftp.put ломал бы shebang и синтаксис на сервере).
            self.ssh.upload_text(install_sh, f"{remote_dir}/install.sh")
            self.ssh.upload_text(xrayebator_bin, f"{remote_dir}/xrayebator")
            self._on_log("Файлы загружены в " + remote_dir)

            # 4. install.sh (долго)
            self._step(3)
            self._run_checked(
                f"bash {remote_dir}/install.sh",
                timeout=3600,
                what="bash install.sh",
            )

            # 5. Локальный xrayebator поверх релизного (в нём есть quickstart)
            self._step(4)
            self._run_checked(
                f"install -m 0755 -o root -g root {remote_dir}/xrayebator "
                "/usr/local/bin/xrayebator",
                timeout=60,
                what="install xrayebator",
            )

            # 6. quickstart
            self._step(5)
            lines = self._run_checked(
                f"xrayebator quickstart --email {shlex.quote(self.email)}",
                timeout=3600,
                what="xrayebator quickstart",
            )
            result = self._parse_result(lines)
            if not result.get("ok"):
                raise DeployError(
                    "quickstart завершился с ошибкой: "
                    + result.get("error", "неизвестная ошибка")
                    + "\nПроверьте, что порты 80/443 открыты у провайдера "
                    "(нужны для Let's Encrypt)."
                )

            # 7. Готово (сохранение выполняет вызывающий код через servers.py)
            self._step(6)
            return result
        finally:
            if remote_dir:
                try:
                    self.ssh.run_streaming(
                        f"rm -rf -- {shlex.quote(remote_dir)}",
                        timeout=30,
                        privileged=False,
                    )
                except Exception:
                    pass
            self.ssh.close()

    @staticmethod
    def _parse_result(lines: list[str]) -> dict:
        """Распарсить ПОСЛЕДНЮЮ JSON-строку stdout quickstart."""
        for line in reversed(lines):
            line = line.strip()
            if not line.startswith("{"):
                continue
            try:
                data = json.loads(line)
            except json.JSONDecodeError:
                continue
            if isinstance(data, dict) and "ok" in data:
                return data
        raise DeployError(
            "quickstart не вернул JSON-результат. "
            "Возможно, на сервере старая версия xrayebator."
        )


def redact_log_line(line: str) -> str:
    """Remove subscription/VLESS bearer secrets before a line reaches the UI."""
    if '"subscription_url"' in line:
        try:
            payload = json.loads(line)
        except json.JSONDecodeError:
            pass
        else:
            if isinstance(payload, dict) and "subscription_url" in payload:
                payload["subscription_url"] = "<redacted>"
                return json.dumps(payload, ensure_ascii=False)
    line = re.sub(r"vless://[^\s\"']+", "vless://<redacted>", line)
    return re.sub(
        r"(https?://[^\s\"']+/(?:sub|subscription)/)[^\s\"']+",
        r"\1<redacted>",
        line,
        flags=re.IGNORECASE,
    )


# ---------------------------------------------------------------------------
# Qt-обёртка (импорт Qt ленивый, чтобы core оставался тестируемым без Qt)
# ---------------------------------------------------------------------------


def make_deploy_thread(**kwargs):  # pragma: no cover - тонкая обёртка
    """Создать QThread-обёртку над Deployer. Qt импортируется здесь."""
    from PySide6.QtCore import QThread, Signal

    class DeployThread(QThread):
        step_changed = Signal(int, str)
        log_line = Signal(str)
        finished_ok = Signal(dict)
        failed = Signal(str)

        def __init__(self, **kw):
            super().__init__()
            self._kw = kw

        def run(self):
            try:
                deployer = Deployer(
                    on_step=lambda i, s: self.step_changed.emit(i, s),
                    on_log=lambda line: self.log_line.emit(line),
                    **self._kw,
                )
                result = deployer.run()
            except Exception as e:
                self.failed.emit(str(e))
                return
            self.finished_ok.emit(result)

    return DeployThread(**kwargs)
