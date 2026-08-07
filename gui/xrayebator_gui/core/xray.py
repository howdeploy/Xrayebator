"""Менеджер локального xray-core: бинарник, конфиг, процесс, health-check."""

from __future__ import annotations

import hashlib
import json
import os
import platform
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import time
import zipfile
from pathlib import Path
from urllib.error import URLError
from urllib.request import ProxyHandler, build_opener

from .routing import RoutingProfile, build_routing_config
from .subscription import VlessLink

APP_NAME = "xrayebator-gui"
XRAY_REPO = "XTLS/Xray-core"
# Stable v26.3.27 predates desktop auto-routing. This pinned prerelease contains
# gateway/dns/autoSystemRoutingTable/autoOutboundsInterface plus Wintun naming.
XRAY_TUN_VERSION = "v26.7.28"
SOCKS_PORT = 10808
HTTP_PORT = 10809

# Ассет релиза Xray-core для каждой платформы
_PLATFORM_ASSETS = {
    ("Windows", "AMD64"): "Xray-windows-64.zip",
    ("Windows", "x86_64"): "Xray-windows-64.zip",
    ("Linux", "x86_64"): "Xray-linux-64.zip",
    ("Linux", "aarch64"): "Xray-linux-arm64-v8a.zip",
    ("Darwin", "x86_64"): "Xray-macos-64.zip",
    ("Darwin", "arm64"): "Xray-macos-arm64-v8a.zip",
}


class XrayError(Exception):
    """Ошибка менеджера xray-core."""


def data_dir() -> Path:
    from platformdirs import user_data_dir

    d = Path(user_data_dir(APP_NAME))
    d.mkdir(parents=True, exist_ok=True)
    return d


def bin_dir() -> Path:
    d = data_dir() / "bin"
    d.mkdir(parents=True, exist_ok=True)
    return d


def xray_binary_name() -> str:
    return "xray.exe" if platform.system() == "Windows" else "xray"


def xray_binary_path() -> Path:
    return bin_dir() / xray_binary_name()


def _vendor_dir() -> Path:
    # gui/xrayebator_gui/core/xray.py -> repo/gui/vendor
    return Path(__file__).resolve().parents[2] / "vendor"


def _platform_asset() -> str:
    key = (platform.system(), platform.machine())
    asset = _PLATFORM_ASSETS.get(key)
    if asset is None:
        raise XrayError(f"Неподдерживаемая платформа для xray-core: {key}")
    return asset


def _sha256(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def _parse_dgst(dgst_text: str, asset_name: str) -> str | None:
    """Извлечь sha256 ассета из файла .dgst релиза Xray-core."""
    for line in dgst_text.splitlines():
        key, separator, value = line.partition("=")
        if separator and key.strip().upper() == "SHA2-256":
            digest = value.strip()
            if re.fullmatch(r"[0-9a-fA-F]{64}", digest):
                return digest
        parts = line.split()
        if (
            len(parts) >= 2
            and parts[-1].endswith(asset_name)
            and re.fullmatch(r"[0-9a-fA-F]{64}", parts[0])
        ):
            return parts[0]
    return None


def _extract_member(
    zf: zipfile.ZipFile, member: str, dest: Path, *, executable: bool = False
) -> None:
    fd, tmp_name = tempfile.mkstemp(prefix=f".{dest.name}.", dir=dest.parent)
    os.close(fd)
    tmp = Path(tmp_name)
    try:
        with zf.open(member) as src, open(tmp, "wb") as dst:
            shutil.copyfileobj(src, dst)
        if executable:
            tmp.chmod(tmp.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)
        os.replace(tmp, dest)
    finally:
        tmp.unlink(missing_ok=True)


def _install_from_zip(zip_path: Path, dest: Path) -> None:
    """Atomically install Xray, routing data and the Windows TUN runtime."""
    wanted = xray_binary_name()
    with zipfile.ZipFile(zip_path) as zf:
        member = next(
            (n for n in zf.namelist() if n.endswith((wanted, "xray"))),
            None,
        )
        if member is None:
            raise XrayError(f"В архиве {zip_path.name} не найден бинарник xray")
        _extract_member(
            zf,
            member,
            dest,
            executable=platform.system() != "Windows",
        )
        for resource in ("geoip.dat", "geosite.dat"):
            resource_member = next(
                (n for n in zf.namelist() if n.lower().endswith(resource)),
                None,
            )
            if resource_member is None:
                raise XrayError(f"В архиве {zip_path.name} не найден {resource}")
            _extract_member(zf, resource_member, dest.parent / resource)

        if platform.system() == "Windows":
            wintun_member = next(
                (n for n in zf.namelist() if n.lower().endswith("wintun.dll")),
                None,
            )
            if wintun_member is not None:
                _extract_member(zf, wintun_member, dest.parent / "wintun.dll")


def _installed_version(binary: Path) -> str | None:
    try:
        result = subprocess.run(
            [str(binary), "version"],
            capture_output=True,
            text=True,
            timeout=10,
            check=False,
        )
    except (OSError, subprocess.SubprocessError):
        return None
    match = re.search(r"\bXray\s+(\d+\.\d+\.\d+)\b", result.stdout)
    return f"v{match.group(1)}" if match else None


def _routing_data_installed(binary: Path) -> bool:
    return all(
        (binary.parent / resource).is_file()
        for resource in ("geoip.dat", "geosite.dat")
    )


def ensure_binary(version: str | None = None) -> Path:
    """Убедиться, что бинарник xray есть; вернуть путь к нему.

    Порядок: уже скачан -> vendor/ -> скачать релиз с GitHub (с проверкой
    sha256 по .dgst).
    """
    tag = version or XRAY_TUN_VERSION
    dest = xray_binary_path()
    if (
        dest.exists()
        and _installed_version(dest) == tag
        and _routing_data_installed(dest)
    ):
        return dest

    asset = _platform_asset()
    vendor_zip = _vendor_dir() / asset
    if vendor_zip.exists():
        _install_from_zip(vendor_zip, dest)
        installed = _installed_version(dest)
        if installed == tag:
            return dest
        raise XrayError(f"Vendor Xray имеет версию {installed or '?'}, требуется {tag}")

    base = f"https://github.com/{XRAY_REPO}/releases/download/{tag}"
    tmp = Path(tempfile.mkdtemp(prefix="xray-dl-"))
    try:
        zip_path = tmp / asset
        _download(f"{base}/{asset}", zip_path)
        dgst_path = tmp / f"{asset}.dgst"
        _download(f"{base}/{asset}.dgst", dgst_path)
        expected = _parse_dgst(dgst_path.read_text(encoding="utf-8"), asset)
        if expected is None:
            raise XrayError(f"Не найден sha256 для {asset} в .dgst")
        actual = _sha256(zip_path)
        if actual.lower() != expected.lower():
            raise XrayError(f"sha256 не совпал для {asset}: {actual} != {expected}")
        _install_from_zip(zip_path, dest)
        installed = _installed_version(dest)
        if installed != tag:
            raise XrayError(f"Установлен Xray {installed or '?'}, ожидался {tag}")
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    return dest


def _download(url: str, dest: Path) -> None:
    import requests

    with requests.get(url, stream=True, timeout=120) as resp:
        resp.raise_for_status()
        with open(dest, "wb") as f:
            f.writelines(resp.iter_content(1 << 20))


def _build_outbounds(
    link: VlessLink, *, outbound_mark: int | None = None
) -> list[dict]:
    user: dict = {"id": link.uuid, "encryption": link.encryption or "none"}
    # flow несовместим с post-quantum encryption — добавляем только для "none"
    if link.flow and (not link.encryption or link.encryption == "none"):
        user["flow"] = link.flow

    stream: dict = {
        "network": link.network,
        "security": "reality",
        "realitySettings": {
            "serverName": link.sni,
            "fingerprint": link.fingerprint or "chrome",
            "publicKey": link.public_key,
            "shortId": link.short_id,
        },
    }
    if link.network == "tcp":
        stream["tcpSettings"] = {}
    elif link.network == "grpc":
        stream["grpcSettings"] = {"serviceName": link.service_name}
    elif link.network == "xhttp":
        xhttp: dict = {"mode": "auto"}
        if link.path:
            xhttp["path"] = link.path
        if link.host:
            xhttp["host"] = link.host
        stream["xhttpSettings"] = xhttp
    if outbound_mark is not None:
        if not 1 <= outbound_mark <= 0xFFFFFFFF:
            raise XrayError(f"Некорректная метка outbound: {outbound_mark}")
        stream["sockopt"] = {"mark": outbound_mark}

    proxy_outbound = {
        "tag": "proxy",
        "protocol": "vless",
        "settings": {
            "vnext": [
                {
                    "address": link.address,
                    "port": link.port,
                    "users": [user],
                }
            ]
        },
        "streamSettings": stream,
    }
    direct_outbound: dict = {
        "tag": "direct",
        "protocol": "freedom",
    }
    if outbound_mark is not None:
        direct_outbound["streamSettings"] = {"sockopt": {"mark": outbound_mark}}
    return [
        proxy_outbound,
        direct_outbound,
        {"tag": "block", "protocol": "blackhole"},
    ]


def _local_proxy_inbounds(
    socks_port: int = SOCKS_PORT, http_port: int = HTTP_PORT
) -> list[dict]:
    return [
        {
            "tag": "socks-in",
            "listen": "127.0.0.1",
            "port": socks_port,
            "protocol": "socks",
            "settings": {"udp": True},
            "sniffing": {
                "enabled": True,
                "destOverride": ["http", "tls"],
            },
        },
        {
            "tag": "http-in",
            "listen": "127.0.0.1",
            "port": http_port,
            "protocol": "http",
            "sniffing": {
                "enabled": True,
                "destOverride": ["http", "tls"],
            },
        },
    ]


def build_client_config(
    link: VlessLink,
    socks_port: int = SOCKS_PORT,
    http_port: int = HTTP_PORT,
    routing_profile: RoutingProfile = RoutingProfile.FULL,
) -> dict:
    """Build the current system-proxy client configuration."""
    config = {
        "log": {"loglevel": "warning"},
        "inbounds": _local_proxy_inbounds(socks_port, http_port),
        "outbounds": _build_outbounds(link),
    }
    routing = build_routing_config(routing_profile)
    if routing is not None:
        config["routing"] = routing
    return config


def _default_tun_name(system: str) -> str | None:
    if system == "Windows":
        return "xrayebator"
    if system == "Linux":
        return "xrayebator0"
    # Darwin requires utunN and Xray can select a free random number.
    if system == "Darwin":
        return None
    raise XrayError(f"TUN не поддерживается на платформе {system}")


def build_tun_client_config(
    link: VlessLink,
    *,
    system: str | None = None,
    interface_name: str | None = None,
    mtu: int = 1500,
    ipv6: bool = True,
    include_local_proxies: bool = False,
    outbound_mark: int | None = None,
    routing_profile: RoutingProfile = RoutingProfile.FULL,
) -> dict:
    """Build a full-device Xray-native TUN configuration.

    Linux/macOS DNS still requires the privileged platform adapter: Xray's
    ``dns`` TUN setting only changes the Windows adapter.
    """
    if not 1280 <= mtu <= 9000:
        raise XrayError(f"Некорректный TUN MTU: {mtu}")

    detected_system = system or platform.system()
    name = (
        interface_name
        if interface_name is not None
        else _default_tun_name(detected_system)
    )
    routes = ["0.0.0.0/0"]
    gateways = ["10.254.0.1/30"]
    if ipv6:
        routes.append("::/0")
        gateways.append("fdfe:dcba:9876::1/126")

    settings: dict = {
        "mtu": mtu,
        "gateway": gateways,
        "userLevel": 0,
        "autoSystemRoutingTable": routes,
        "autoOutboundsInterface": "auto",
    }
    if name:
        settings["name"] = name
    if detected_system == "Windows":
        settings["desc"] = "Xrayebator"
        settings["dns"] = ["1.1.1.1", "8.8.8.8"]

    inbounds = [
        {
            "tag": "tun-in",
            "port": 0,
            "protocol": "tun",
            "settings": settings,
            "sniffing": {
                "enabled": True,
                "destOverride": ["http", "tls", "quic"],
                "routeOnly": True,
            },
        }
    ]
    if include_local_proxies:
        inbounds.extend(_local_proxy_inbounds())

    config = {
        "log": {"loglevel": "warning"},
        "inbounds": inbounds,
        "outbounds": _build_outbounds(link, outbound_mark=outbound_mark),
    }
    routing = build_routing_config(routing_profile)
    if routing is not None:
        config["routing"] = routing
    return config


class XrayProcess:
    """Запуск/остановка локального xray-core."""

    def __init__(
        self,
        binary: Path | None = None,
        *,
        config_path: Path | None = None,
        stderr_path: Path | None = None,
    ):
        self._binary = binary or xray_binary_path()
        self._proc: subprocess.Popen | None = None
        self._config_path = config_path or data_dir() / "config.json"
        self._stderr_path = stderr_path or data_dir() / "xray.log"
        self._stderr_file = None

    def start(self, config: dict) -> None:
        """Записать конфиг и запустить xray; детект раннего падения."""
        if self.is_running():
            self.stop()
        if not self._binary.exists():
            raise XrayError(
                f"Бинарник xray не найден: {self._binary}. "
                "Сначала вызовите ensure_binary()."
            )
        self._config_path.parent.mkdir(parents=True, exist_ok=True)
        fd, tmp_name = tempfile.mkstemp(
            prefix=f".{self._config_path.name}.",
            dir=self._config_path.parent,
        )
        try:
            # CI-2: os.fchmod() POSIX-only; Windows fallback на os.chmod().
            if sys.platform == "win32":
                os.chmod(tmp_name, stat.S_IRUSR | stat.S_IWUSR)
            else:
                os.fchmod(fd, stat.S_IRUSR | stat.S_IWUSR)
            with os.fdopen(fd, "w", encoding="utf-8") as config_file:
                fd = -1
                json.dump(config, config_file, indent=2)
                config_file.flush()
                os.fsync(config_file.fileno())
            os.replace(tmp_name, self._config_path)
        finally:
            if fd >= 0:
                os.close(fd)
            Path(tmp_name).unlink(missing_ok=True)

        self._stderr_path.parent.mkdir(parents=True, exist_ok=True)
        stderr_fd = os.open(
            self._stderr_path,
            os.O_RDWR | os.O_CREAT | os.O_TRUNC,
            stat.S_IRUSR | stat.S_IWUSR,
        )
        # CI-2: os.fchmod POSIX-only; на Windows права задаются через os.chmod.
        if sys.platform == "win32":
            os.chmod(self._stderr_path, stat.S_IRUSR | stat.S_IWUSR)
        else:
            os.fchmod(stderr_fd, stat.S_IRUSR | stat.S_IWUSR)
        self._stderr_file = os.fdopen(stderr_fd, "w+b")
        self._proc = subprocess.Popen(
            [str(self._binary), "run", "-c", str(self._config_path)],
            stdout=subprocess.DEVNULL,
            stderr=self._stderr_file,
        )
        # Даём процессу шанс упасть сразу (битый конфиг и т.п.)
        time.sleep(1.0)
        if self._proc.poll() is not None:
            self._stderr_file.flush()
            self._stderr_file.seek(0)
            stderr = self._stderr_file.read(2000).decode("utf-8", errors="replace")
            self._stderr_file.close()
            self._stderr_file = None
            self._proc = None
            raise XrayError(f"xray завершился сразу после старта:\n{stderr}")

    def stop(self) -> None:
        if self._proc is None:
            return
        self._proc.terminate()
        try:
            self._proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self._proc.kill()
            self._proc.wait(timeout=5)
        self._proc = None
        if self._stderr_file is not None:
            self._stderr_file.close()
            self._stderr_file = None

    def is_running(self) -> bool:
        return self._proc is not None and self._proc.poll() is None

    def health_check(
        self, socks_port: int = SOCKS_PORT, timeout: float = 10.0
    ) -> str | None:
        """Проверить туннель: запрос api.ipify.org через SOCKS5.

        Возвращает внешний IP или None.
        """
        import requests

        proxy = f"socks5h://127.0.0.1:{socks_port}"
        session = requests.Session()
        session.trust_env = False
        try:
            resp = session.get(
                "https://api.ipify.org",
                proxies={"http": proxy, "https": proxy},
                timeout=timeout,
            )
            resp.raise_for_status()
            return resp.text.strip()
        except requests.RequestException:
            return None

    def health_check_tun(self, timeout: float = 10.0) -> str | None:
        """Проверить полный системный маршрут без локального proxy."""
        try:
            opener = build_opener(ProxyHandler({}))
            with opener.open("https://api.ipify.org", timeout=timeout) as response:
                return response.read(128).decode("ascii").strip()
        except (OSError, UnicodeError, URLError):
            return None
