from __future__ import annotations

from xrayebator_gui.core import proxy


def test_linux_capture_and_restore_puts_mode_last(monkeypatch):
    values = {
        ("org.gnome.system.proxy", "mode"): "'auto'",
        ("org.gnome.system.proxy.http", "host"): "'old-http'",
        ("org.gnome.system.proxy.http", "port"): "3128",
        ("org.gnome.system.proxy.https", "host"): "'old-https'",
        ("org.gnome.system.proxy.https", "port"): "4443",
    }
    calls = []
    monkeypatch.setattr(proxy.platform, "system", lambda: "Linux")
    monkeypatch.setattr(
        proxy,
        "_gsettings_get",
        lambda schema, key: values[(schema, key)],
    )
    monkeypatch.setattr(
        proxy,
        "_gsettings",
        lambda *args: calls.append(args) or True,
    )

    snapshot = proxy.capture()
    assert proxy.restore(snapshot)

    assert calls[-1] == (
        "set",
        "org.gnome.system.proxy",
        "mode",
        "'auto'",
    )
    assert len(calls) == 5


def test_restore_rejects_snapshot_from_another_system(monkeypatch):
    monkeypatch.setattr(proxy.platform, "system", lambda: "Linux")
    snapshot = proxy.ProxySnapshot("Windows", {})

    try:
        proxy.restore(snapshot)
    except proxy.UnsupportedPlatform as exc:
        assert "Windows" in str(exc)
    else:
        raise AssertionError("restore accepted a snapshot from another OS")
