"""Linux nftables guard and DNS redirection for the privileged helper."""

from __future__ import annotations

import re
import shutil
import socket
import subprocess
import time

NFT_TABLE = "xrayebator_gui"
INTERFACE_RE = re.compile(r"^[A-Za-z0-9_.-]{1,15}$")


class NetworkError(RuntimeError):
    """A privileged network operation failed."""


class LinuxNetwork:
    def __init__(self, *, command_timeout: float = 15.0):
        self.command_timeout = command_timeout

    def check_dependencies(self) -> None:
        missing = [command for command in ("nft",) if shutil.which(command) is None]
        if missing:
            raise NetworkError(
                "Не установлены зависимости TUN helper: " + ", ".join(missing)
            )

    def guard_exists(self) -> bool:
        if shutil.which("nft") is None:
            return False
        result = self._run(
            ["nft", "list", "table", "inet", NFT_TABLE],
            check=False,
        )
        return result.returncode == 0

    def enable_guard(self, interface: str, mark: int) -> None:
        if not INTERFACE_RE.fullmatch(interface):
            raise NetworkError(f"Некорректное имя TUN-интерфейса: {interface!r}")
        if not 1 <= mark <= 0xFFFFFFFF:
            raise NetworkError(f"Некорректная firewall mark: {mark}")
        if self.guard_exists():
            # The table name is private to this helper and its rules are fixed.
            # Keeping it in place avoids a leak window during recovery/switching.
            return
        script = build_nft_rules(interface, mark)
        self._run(["nft", "-f", "-"], input_text=script)

    def validate_guard(self, interface: str, mark: int) -> None:
        """Ask nftables to parse/check the transaction without applying it."""
        script = build_nft_rules(interface, mark)
        self._run(["nft", "--check", "-f", "-"], input_text=script)

    def disable_guard(self) -> None:
        if not self.guard_exists():
            return
        self._run(["nft", "delete", "table", "inet", NFT_TABLE])

    def wait_for_interface(
        self,
        interface: str,
        *,
        timeout: float = 8.0,
    ) -> None:
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            try:
                socket.if_nametoindex(interface)
                return
            except OSError:
                time.sleep(0.1)
        raise NetworkError(f"TUN-интерфейс {interface} не появился")

    def configure_dns(
        self,
        interface: str,
        servers: tuple[str, ...] = ("1.1.1.1", "8.8.8.8"),
    ) -> None:
        """Wait for TUN; DNS redirection itself is in the nft transaction."""
        del servers
        self.wait_for_interface(interface)

    def restore_dns(self, interface: str) -> None:
        # Removing the nft table restores the original resolver unchanged.
        del interface

    def _run(
        self,
        args: list[str],
        *,
        input_text: str | None = None,
        check: bool = True,
    ) -> subprocess.CompletedProcess:
        try:
            result = subprocess.run(
                args,
                input=input_text,
                capture_output=True,
                text=True,
                timeout=self.command_timeout,
                check=False,
            )
        except (OSError, subprocess.SubprocessError) as exc:
            raise NetworkError(f"Не удалось выполнить {args[0]}: {exc}") from exc
        if check and result.returncode != 0:
            detail = result.stderr.strip() or result.stdout.strip()
            raise NetworkError(
                f"{' '.join(args)} завершился с {result.returncode}: {detail}"
            )
        return result


def build_nft_rules(interface: str, mark: int) -> str:
    if not INTERFACE_RE.fullmatch(interface):
        raise NetworkError(f"Некорректное имя TUN-интерфейса: {interface!r}")
    if not 1 <= mark <= 0xFFFFFFFF:
        raise NetworkError(f"Некорректная firewall mark: {mark}")
    return (
        f"table inet {NFT_TABLE} {{\n"
        "  chain dns_output {\n"
        "    type nat hook output priority -100; policy accept;\n"
        "    meta nfproto ipv4 udp dport 53 dnat ip to 1.1.1.1\n"
        "    meta nfproto ipv4 tcp dport 53 dnat ip to 1.1.1.1\n"
        "    meta nfproto ipv6 udp dport 53 dnat ip6 to "
        "2606:4700:4700::1111\n"
        "    meta nfproto ipv6 tcp dport 53 dnat ip6 to "
        "2606:4700:4700::1111\n"
        "  }\n"
        "  chain output {\n"
        "    type filter hook output priority -50; policy accept;\n"
        '    oifname "lo" accept\n'
        f'    oifname "{interface}" accept\n'
        f"    meta mark {mark} accept\n"
        "    udp sport 68 udp dport 67 accept\n"
        "    udp sport 546 udp dport 547 accept\n"
        "    reject\n"
        "  }\n"
        "}\n"
    )
