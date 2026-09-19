"""User-triggered installation of the root-owned Linux TUN helper."""

from __future__ import annotations

import getpass
import platform
import shutil
import subprocess
from pathlib import Path


class HelperInstallError(RuntimeError):
    """The local privileged helper could not be installed."""


def linux_installer_path() -> Path:
    return (
        Path(__file__).resolve().parents[1]
        / "resources"
        / "linux"
        / "install-helper.sh"
    )


def install_linux_helper(timeout: float = 600.0) -> str:
    if platform.system() != "Linux":
        raise HelperInstallError(
            "Автоустановка privileged helper поддержана только в Linux"
        )
    pkexec = shutil.which("pkexec")
    if pkexec is None:
        raise HelperInstallError(
            "Не найден pkexec. Установите polkit или запустите "
            "resources/linux/install-helper.sh через sudo."
        )
    script = linux_installer_path()
    if not script.is_file():
        raise HelperInstallError(f"Не найден installer helper: {script}")
    username = getpass.getuser()
    try:
        result = subprocess.run(
            [pkexec, "bash", str(script), "--user", username],
            capture_output=True,
            text=True,
            timeout=timeout,
            check=False,
        )
    except (OSError, subprocess.SubprocessError) as exc:
        raise HelperInstallError(f"Не удалось запустить installer: {exc}") from exc
    output = "\n".join(
        part.strip() for part in (result.stdout, result.stderr) if part.strip()
    )
    if result.returncode != 0:
        raise HelperInstallError(
            output or f"Installer helper завершился с кодом {result.returncode}"
        )
    return output or "Privileged TUN helper установлен"
