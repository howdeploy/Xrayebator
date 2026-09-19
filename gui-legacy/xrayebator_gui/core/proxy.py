"""Системный прокси per-OS: Windows (winreg), macOS (networksetup), Linux (gsettings)."""

from __future__ import annotations

import ctypes
import platform
import re
import shutil
import subprocess
from dataclasses import dataclass
from typing import Any


class UnsupportedPlatform(Exception):
    """ОС/DE не поддерживается для автонастройки прокси."""


@dataclass(frozen=True)
class ProxySnapshot:
    """Настройки, которые приложение обязано вернуть при отключении."""

    system: str
    values: Any


def capture() -> ProxySnapshot:
    """Снять только те системные настройки, которые меняет этот модуль."""
    system = platform.system()
    if system == "Windows":
        return ProxySnapshot(system, _win_capture())
    if system == "Darwin":
        return ProxySnapshot(system, _mac_capture())
    if system == "Linux":
        return ProxySnapshot(system, _linux_capture())
    raise UnsupportedPlatform(f"Неподдерживаемая ОС: {system}")


def restore(snapshot: ProxySnapshot) -> bool:
    """Восстановить ранее снятые настройки без подмены текущей ОС."""
    system = platform.system()
    if snapshot.system != system:
        raise UnsupportedPlatform(
            f"Снимок proxy создан для {snapshot.system}, текущая ОС — {system}"
        )
    if system == "Windows":
        return _win_restore(snapshot.values)
    if system == "Darwin":
        return _mac_restore(snapshot.values)
    if system == "Linux":
        return _linux_restore(snapshot.values)
    raise UnsupportedPlatform(f"Неподдерживаемая ОС: {system}")


def enable(host: str = "127.0.0.1", port: int = 10809) -> bool:
    """Включить системный HTTP/HTTPS proxy. False — сделайте вручную."""
    system = platform.system()
    if system == "Windows":
        return _win_enable(host, port)
    if system == "Darwin":
        return _mac_enable(host, port)
    if system == "Linux":
        return _linux_enable(host, port)
    raise UnsupportedPlatform(f"Неподдерживаемая ОС: {system}")


def disable() -> bool:
    """Выключить системный прокси."""
    system = platform.system()
    if system == "Windows":
        return _win_disable()
    if system == "Darwin":
        return _mac_disable()
    if system == "Linux":
        return _linux_disable()
    raise UnsupportedPlatform(f"Неподдерживаемая ОС: {system}")


def is_enabled() -> bool:
    system = platform.system()
    try:
        if system == "Windows":
            import winreg

            with winreg.OpenKey(
                winreg.HKEY_CURRENT_USER,
                r"Software\Microsoft\Windows\CurrentVersion\Internet Settings",
            ) as k:
                return bool(winreg.QueryValueEx(k, "ProxyEnable")[0])
        if system == "Darwin":
            services = _mac_services()
            if not services:
                return False
            out = subprocess.run(
                ["networksetup", "-getwebproxy", services[0]],
                capture_output=True,
                text=True,
                timeout=10,
            ).stdout
            return "Enabled: Yes" in out
        if system == "Linux":
            if not shutil.which("gsettings"):
                return False
            out = subprocess.run(
                ["gsettings", "get", "org.gnome.system.proxy", "mode"],
                capture_output=True,
                text=True,
                timeout=10,
            ).stdout.strip()
            return out == "'manual'"
    except (OSError, subprocess.SubprocessError):
        return False
    return False


# --- Windows ---------------------------------------------------------------

_WIN_PROXY_KEY = r"Software\Microsoft\Windows\CurrentVersion\Internet Settings"
_WIN_PROXY_VALUES = ("ProxyEnable", "ProxyServer", "ProxyOverride")


def _win_capture() -> dict[str, tuple[bool, Any, int | None]]:
    import winreg

    values: dict[str, tuple[bool, Any, int | None]] = {}
    with winreg.CreateKey(winreg.HKEY_CURRENT_USER, _WIN_PROXY_KEY) as key:
        for name in _WIN_PROXY_VALUES:
            try:
                value, value_type = winreg.QueryValueEx(key, name)
                values[name] = (True, value, value_type)
            except FileNotFoundError:
                values[name] = (False, None, None)
    return values


def _win_restore(values: dict[str, tuple[bool, Any, int | None]]) -> bool:
    import winreg

    with winreg.CreateKey(winreg.HKEY_CURRENT_USER, _WIN_PROXY_KEY) as key:
        for name in _WIN_PROXY_VALUES:
            existed, value, value_type = values[name]
            if existed:
                winreg.SetValueEx(key, name, 0, value_type, value)
            else:
                try:
                    winreg.DeleteValue(key, name)
                except FileNotFoundError:
                    pass
    _win_apply_settings()
    return True


def _win_apply_settings() -> None:
    """Уведомить систему об изменении настроек прокси без перелогина."""
    wininet = ctypes.windll.wininet  # type: ignore[attr-defined]
    INTERNET_OPTION_SETTINGS_CHANGED = 39
    INTERNET_OPTION_REFRESH = 41
    wininet.InternetSetOptionW(0, INTERNET_OPTION_SETTINGS_CHANGED, 0, 0)
    wininet.InternetSetOptionW(0, INTERNET_OPTION_REFRESH, 0, 0)


def _win_enable(host: str, port: int) -> bool:
    import winreg

    with winreg.CreateKey(
        winreg.HKEY_CURRENT_USER,
        _WIN_PROXY_KEY,
    ) as k:
        winreg.SetValueEx(k, "ProxyEnable", 0, winreg.REG_DWORD, 1)
        winreg.SetValueEx(k, "ProxyServer", 0, winreg.REG_SZ, f"{host}:{port}")
        winreg.SetValueEx(k, "ProxyOverride", 0, winreg.REG_SZ, "<local>")
    _win_apply_settings()
    return True


def _win_disable() -> bool:
    import winreg

    with winreg.CreateKey(
        winreg.HKEY_CURRENT_USER,
        _WIN_PROXY_KEY,
    ) as k:
        winreg.SetValueEx(k, "ProxyEnable", 0, winreg.REG_DWORD, 0)
    _win_apply_settings()
    return True


# --- macOS -----------------------------------------------------------------


def _mac_services() -> list[str]:
    """Активные network services (строки со '*' — отключённые, пропускаем)."""
    out = subprocess.run(
        ["networksetup", "-listallnetworkservices"],
        capture_output=True,
        text=True,
        timeout=15,
    ).stdout
    services = []
    for line in out.splitlines()[1:]:  # первая строка — заголовок
        line = line.strip()
        if line and not line.startswith("*"):
            services.append(line)
    return services


def _mac_run(args: list[str]) -> None:
    result = subprocess.run(
        ["networksetup", *args],
        capture_output=True,
        text=True,
        timeout=15,
    )
    if result.returncode != 0:
        raise UnsupportedPlatform(
            result.stderr.strip() or f"networksetup завершился с {result.returncode}"
        )


def _mac_proxy(service: str, secure: bool) -> dict[str, Any]:
    command = "-getsecurewebproxy" if secure else "-getwebproxy"
    result = subprocess.run(
        ["networksetup", command, service],
        capture_output=True,
        text=True,
        timeout=15,
    )
    if result.returncode != 0:
        raise UnsupportedPlatform(
            result.stderr.strip() or f"Не удалось прочитать proxy для {service}"
        )
    fields = {}
    for line in result.stdout.splitlines():
        match = re.match(r"^([^:]+):\s*(.*)$", line)
        if match:
            fields[match.group(1).strip()] = match.group(2).strip()
    try:
        return {
            "enabled": fields.get("Enabled") == "Yes",
            "server": fields.get("Server", ""),
            "port": int(fields.get("Port", "0")),
        }
    except ValueError as exc:
        raise UnsupportedPlatform(
            f"Некорректный ответ networksetup для {service}"
        ) from exc


def _mac_capture() -> dict[str, dict[str, dict[str, Any]]]:
    return {
        service: {
            "web": _mac_proxy(service, secure=False),
            "secure": _mac_proxy(service, secure=True),
        }
        for service in _mac_services()
    }


def _mac_restore(values: dict[str, dict[str, dict[str, Any]]]) -> bool:
    for service, proxies in values.items():
        for kind, command in (
            ("web", "-setwebproxy"),
            ("secure", "-setsecurewebproxy"),
        ):
            saved = proxies[kind]
            if saved["server"] and saved["port"]:
                _mac_run([command, service, saved["server"], str(saved["port"])])
            state_command = (
                "-setwebproxystate" if kind == "web" else "-setsecurewebproxystate"
            )
            _mac_run([state_command, service, "on" if saved["enabled"] else "off"])
    return True


def _mac_enable(host: str, port: int) -> bool:
    services = _mac_services()
    if not services:
        return False
    for svc in services:
        _mac_run(["-setwebproxy", svc, host, str(port)])
        _mac_run(["-setsecurewebproxy", svc, host, str(port)])
    return True


def _mac_disable() -> bool:
    services = _mac_services()
    for svc in services:
        _mac_run(["-setwebproxystate", svc, "off"])
        _mac_run(["-setsecurewebproxystate", svc, "off"])
    return True


# --- Linux (GNOME) ----------------------------------------------------------


def _gsettings(*args: str) -> bool:
    if not shutil.which("gsettings"):
        return False
    rc = subprocess.run(
        ["gsettings", *args], capture_output=True, timeout=10
    ).returncode
    return rc == 0


def _gsettings_get(schema: str, key: str) -> str:
    if not shutil.which("gsettings"):
        raise UnsupportedPlatform(
            "gsettings не найден; автоматический proxy поддержан только в GNOME"
        )
    result = subprocess.run(
        ["gsettings", "get", schema, key],
        capture_output=True,
        text=True,
        timeout=10,
    )
    if result.returncode != 0:
        raise UnsupportedPlatform(
            result.stderr.strip() or f"Не удалось прочитать {schema} {key}"
        )
    return result.stdout.strip()


_LINUX_PROXY_KEYS = (
    ("org.gnome.system.proxy", "mode"),
    ("org.gnome.system.proxy.http", "host"),
    ("org.gnome.system.proxy.http", "port"),
    ("org.gnome.system.proxy.https", "host"),
    ("org.gnome.system.proxy.https", "port"),
)


def _linux_capture() -> dict[tuple[str, str], str]:
    return {
        (schema, key): _gsettings_get(schema, key) for schema, key in _LINUX_PROXY_KEYS
    }


def _linux_restore(values: dict[tuple[str, str], str]) -> bool:
    ok = True
    # Mode is restored last so consumers never see a half-restored manual proxy.
    for schema, key in (*_LINUX_PROXY_KEYS[1:], _LINUX_PROXY_KEYS[0]):
        ok = _gsettings("set", schema, key, values[(schema, key)]) and ok
    return ok


def _linux_enable(host: str, port: int) -> bool:
    """GNOME: manual HTTP/HTTPS proxy. False — настройте вручную."""
    ok = _gsettings("set", "org.gnome.system.proxy", "mode", "'manual'")
    ok = _gsettings("set", "org.gnome.system.proxy.http", "host", f"'{host}'") and ok
    ok = _gsettings("set", "org.gnome.system.proxy.http", "port", str(port)) and ok
    ok = _gsettings("set", "org.gnome.system.proxy.https", "host", f"'{host}'") and ok
    ok = _gsettings("set", "org.gnome.system.proxy.https", "port", str(port)) and ok
    return ok


def _linux_disable() -> bool:
    return _gsettings("set", "org.gnome.system.proxy", "mode", "'none'")
