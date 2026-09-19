from __future__ import annotations

from xrayebator_gui.core import helper_install


def test_installer_is_packaged_with_application():
    path = helper_install.linux_installer_path()

    assert path.is_file()
    assert path.name == "install-helper.sh"


def test_installer_uses_pkexec_without_shell(monkeypatch):
    calls = []
    monkeypatch.setattr(helper_install.platform, "system", lambda: "Linux")
    monkeypatch.setattr(helper_install.shutil, "which", lambda name: "/usr/bin/pkexec")
    monkeypatch.setattr(helper_install.getpass, "getuser", lambda: "alice")

    def fake_run(args, **kwargs):
        calls.append((args, kwargs))
        return type(
            "Result",
            (),
            {"returncode": 0, "stdout": "installed", "stderr": ""},
        )()

    monkeypatch.setattr(helper_install.subprocess, "run", fake_run)

    assert helper_install.install_linux_helper() == "installed"
    args, kwargs = calls[0]
    assert args[:2] == ["/usr/bin/pkexec", "bash"]
    assert args[-2:] == ["--user", "alice"]
    assert "shell" not in kwargs
