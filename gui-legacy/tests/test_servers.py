"""Server store operations.

POSIX-only checks for file permissions (st_mode) are skipped on Windows:
there's no st_mode sensitivity here, and os.fchmod is unavailable.
"""
from __future__ import annotations

import sys

import pytest

from xrayebator_gui.core import servers
from xrayebator_gui.core.servers import ServerStore

server_marks = pytest.mark.skipif(
    sys.platform == "win32",
    reason="POSIX-only file permission check (os.fchmod absent on Windows)",
)


@server_marks
def test_server_metadata_with_subscription_is_owner_only(monkeypatch, tmp_path):
    monkeypatch.setattr(servers.keyring, "set_password", lambda *args: None)
    store = ServerStore(tmp_path)

    saved = store.add(
        name="VPN",
        host="vpn.example.com",
        port=22,
        user="root",
        auth_type="password",
        password="ssh-secret",
        subscription_url="https://vpn.example.com/sub/bearer-secret",
    )

    data_file = tmp_path / "servers.json"
    assert data_file.stat().st_mode & 0o777 == 0o600
    text = data_file.read_text(encoding="utf-8")
    assert "bearer-secret" in text
    assert "ssh-secret" not in text
    assert store.get(saved["id"]) is not None
