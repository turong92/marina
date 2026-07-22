#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SCR="$HERE/../scripts"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PYTHONPATH="$SCR" python3 - "$TMP" <<'PY'
import sys
from pathlib import Path

from marina_auth import AuthError, AuthStore, SessionPrincipal
from marina_remote_service import RemoteService

root = Path(sys.argv[1])
home = root / "home"
store = AuthStore(home / "auth.db", pbkdf2_iterations=1000)
admin = store.bootstrap_admin("owner", "Owner", "owner-password")
principal = SessionPrincipal(admin, 1, b"")

class FakeRemote:
    def __init__(self): self.calls = []; self.mode = "off"
    def status(self, refresh=False):
        return {"installed": True, "online": True, "mode": self.mode, "state": self.mode,
                "dnsName": "marina.tail.ts.net", "url": None if self.mode == "off" else "https://marina.tail.ts.net"}
    def activate(self, mode, port):
        self.calls.append(("activate", mode, port)); self.mode = mode; return self.status(True)
    def off(self): self.calls.append(("off",)); self.mode = "off"; return self.status(True)

remote = FakeRemote()
service = RemoteService(store, remote, home=home, control_port=3900, guard_check=lambda: True)
ready = service.readiness()
assert ready["ready"] is True and all(item["ok"] for item in ready["checks"])

result = service.activate("serve", principal)
assert result["mode"] == "serve" and result["restartRequired"] is True
assert (home / "dashboard-bind.env").read_text() == "MARINA_CONTROL_HOST=localhost\nMARINA_CONTROL_PORT=3900\n"

try:
    service.activate("funnel", principal, password="wrong-password")
    raise AssertionError("wrong password accepted")
except AuthError as exc:
    assert exc.code == "reauth_failed"
assert remote.calls == [("activate", "serve", 3900)]

result = service.activate("funnel", principal, password="owner-password")
assert result["mode"] == "funnel"
assert remote.calls[-1] == ("activate", "funnel", 3900)

blocked = RemoteService(store, remote, home=home, control_host="0.0.0.0", guard_check=lambda: False)
checks = {item["id"]: item["ok"] for item in blocked.readiness()["checks"]}
assert checks["localhost_bind"] is False and checks["auth_guard"] is False
try:
    blocked.activate("funnel", principal, password="owner-password")
    raise AssertionError("unsafe funnel accepted")
except AuthError as exc:
    assert exc.code == "remote_not_ready"

assert service.off(principal)["mode"] == "off"
assert remote.calls[-1] == ("off",)

class MissingRemote(FakeRemote):
    def status(self, refresh=False):
        return {"installed": False, "online": False, "mode": "off", "state": "unavailable", "conflict": False}

unavailable = RemoteService(store, MissingRemote(), home=home, control_port=3900, guard_check=lambda: True)
missing_checks = {item["id"]: item["ok"] for item in unavailable.readiness()["checks"]}
assert missing_checks["tailscale_installed"] is False
assert missing_checks["tailscale_online"] is False
assert unavailable.readiness()["ready"] is False
print("ok remote readiness service")
PY

echo "PASS test-remote-service"
