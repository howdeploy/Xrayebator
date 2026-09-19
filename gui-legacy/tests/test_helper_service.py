from __future__ import annotations

from xrayebator_gui.core.helper_protocol import HelperRequest
from xrayebator_gui.helper.service import HelperApplication, authorized_peer


class FakeRuntime:
    def __init__(self):
        self.calls = []

    def status(self):
        self.calls.append(("status",))
        return {"state": "disconnected", "external_ip": None, "error": None}

    def connect(self, route, routing_profile):
        self.calls.append(("connect", route, routing_profile))
        return {"state": "connected", "external_ip": None, "error": None}

    def selftest(self):
        self.calls.append(("selftest",))
        return {"state": "disconnected", "external_ip": None, "error": None}

    def switch(self, route, routing_profile):
        self.calls.append(("switch", route, routing_profile))
        return {"state": "connected", "external_ip": None, "error": None}

    def verify(self):
        self.calls.append(("verify",))
        return {
            "state": "connected",
            "external_ip": "203.0.113.1",
            "error": None,
        }

    def disconnect(self):
        self.calls.append(("disconnect",))
        return {"state": "disconnected", "external_ip": None, "error": None}


def test_application_dispatches_only_typed_actions():
    runtime = FakeRuntime()
    app = HelperApplication(runtime)

    result = app.handle(HelperRequest("abc", "status"))

    assert result["state"] == "disconnected"
    assert runtime.calls == [("status",)]


def test_explicit_uid_authorization_does_not_trust_shared_group():
    assert authorized_peer(1000, 100, 100, allowed_uid=1000)
    assert not authorized_peer(1001, 100, 100, allowed_uid=1000)
    assert authorized_peer(0, 0, 100, allowed_uid=1000)


def test_application_dispatches_selftest():
    runtime = FakeRuntime()
    app = HelperApplication(runtime)

    result = app.handle(HelperRequest("abc", "selftest"))

    assert result["state"] == "disconnected"
    assert runtime.calls == [("selftest",)]
