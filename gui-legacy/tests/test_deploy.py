from __future__ import annotations

import json

import pytest

from xrayebator_gui.core.deploy import (
    Deployer,
    DeployError,
    check_os_supported,
    redact_log_line,
)


class FakeSSH:
    def __init__(self, *, quickstart_ok=True, staging=None):
        self.quickstart_ok = quickstart_ok
        self.staging = staging or "/tmp/xrayebator-deploy.A1b2C3d4"
        self.connect_kwargs = None
        self.commands = []
        self.uploads = []
        self.closed = False

    def connect(self, host, port, user, **kwargs):
        self.connect_kwargs = (host, port, user, kwargs)

    def run_streaming(
        self,
        command,
        on_line=None,
        timeout=600,
        *,
        privileged=True,
    ):
        self.commands.append((command, privileged))
        lines = []
        if command == "cat /etc/os-release":
            lines = ['ID="debian"', 'VERSION_ID="12"']
        elif command.startswith("mktemp "):
            lines = [self.staging]
        elif "quickstart" in command:
            lines = [
                "quickstart output",
                json.dumps(
                    {
                        "ok": self.quickstart_ok,
                        "subscription_url": "https://vpn.example/sub/token",
                        "profile": "happ",
                    }
                ),
            ]
        if on_line:
            for line in lines:
                on_line(line)
        return 0

    def upload(self, local_path, remote_path):
        self.uploads.append((local_path, remote_path))

    def upload_text(self, local_path, remote_path):
        # deploy.py загружает bash-артефакты с LF-нормализацией; фиксируем
        # использование текстового пути (а не сырого бинарного upload).
        self.uploads.append((local_path, remote_path))

    def close(self):
        self.closed = True


def repo(tmp_path):
    (tmp_path / "install.sh").write_text("#!/bin/sh\n", encoding="utf-8")
    (tmp_path / "xrayebator").write_text("#!/bin/sh\n", encoding="utf-8")
    return tmp_path


def test_deploy_uses_user_owned_staging_and_privileged_install(tmp_path):
    ssh = FakeSSH()
    deployer = Deployer(
        ssh,
        host="vpn.example.com",
        user="alice",
        password=None,
        key_path="~/.ssh/id_ed25519",
        sudo_password="sudo-secret",
        email="alice@example.com",
        repo_root=repo(tmp_path),
    )

    result = deployer.run()

    assert result["ok"] is True
    assert ssh.connect_kwargs[3]["sudo_password"] == "sudo-secret"
    assert ssh.commands[0] == ("cat /etc/os-release", False)
    assert ssh.commands[1][0].startswith("mktemp -d ")
    assert ssh.commands[1][1] is False
    assert [str(remote) for _, remote in ssh.uploads] == [
        f"{ssh.staging}/install.sh",
        f"{ssh.staging}/xrayebator",
    ]
    install_commands = [
        command for command, privileged in ssh.commands if privileged and command != ""
    ]
    assert any(command.startswith("bash ") for command in install_commands)
    assert any(
        "quickstart --email alice@example.com" in command
        for command in install_commands
    )
    assert ssh.commands[-1] == (f"rm -rf -- {ssh.staging}", False)
    assert ssh.closed


def test_deploy_rejects_untrusted_staging_path_and_still_closes(tmp_path):
    ssh = FakeSSH(staging="/tmp/safe; touch /tmp/pwned")
    deployer = Deployer(
        ssh,
        host="vpn.example.com",
        email="alice@example.com",
        repo_root=repo(tmp_path),
    )

    with pytest.raises(DeployError, match="небезопасный"):
        deployer.run()

    assert not ssh.uploads
    assert ssh.closed


@pytest.mark.parametrize(
    ("text", "expected"),
    [
        ('ID=debian\nVERSION_ID="12"\n', ("debian", "12")),
        ('ID="ubuntu"\nVERSION_ID="24.04"\n', ("ubuntu", "24.04")),
    ],
)
def test_supported_os(text, expected):
    assert check_os_supported(text) == expected


def test_unsupported_os_has_actionable_message():
    with pytest.raises(DeployError, match="Поддерживаются"):
        check_os_supported('ID="centos"\nVERSION_ID="9"\n')


def test_deploy_log_redacts_subscription_and_vless_secrets():
    json_line = json.dumps(
        {
            "ok": True,
            "subscription_url": "https://vpn.example/sub/bearer-token",
        }
    )

    assert "bearer-token" not in redact_log_line(json_line)
    assert "uuid-secret" not in redact_log_line(
        "route: vless://uuid-secret@vpn.example:443?security=reality"
    )
