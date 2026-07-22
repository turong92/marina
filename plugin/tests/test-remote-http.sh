#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SCR="$HERE/../scripts"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PYTHONPATH="$SCR" python3 - "$TMP" <<'PY'
import http.client
import json
import os
import sys
import threading
import time
from http.server import ThreadingHTTPServer
from pathlib import Path

home = Path(sys.argv[1]) / "home"
os.environ.update({
    "MARINA_HOME": str(home), "MARINA_AUTH_DB": str(home / "auth.db"),
    "MARINA_AUTH_PBKDF2_ITERATIONS": "1000", "MARINA_CONTROL_HOST": "127.0.0.1",
    "MARINA_RESTART_DRY_RUN": "1",
})
from marina_auth import AuthStore
store = AuthStore(home / "auth.db", pbkdf2_iterations=1000)
admin = store.bootstrap_admin("owner", "Owner", "owner-password")
member = store.add_user("dev-one", "Dev One")
with store._transaction() as conn:
    conn.execute("update users set status='active' where id=?", (member.id,))
admin_session, member_session = store.create_session(admin.id), store.create_session(member.id)

class FakeRemote:
    def __init__(self): self.mode = "off"; self.calls = []
    def status(self, refresh=False):
        return {"installed": True, "online": True, "mode": self.mode, "state": self.mode,
                "dnsName": "marina.tail.ts.net", "url": None if self.mode == "off" else "https://marina.tail.ts.net",
                "ips": ["100.64.0.8"], "configuration": {"serve": {"private": True}}}
    def activate(self, mode, port): self.calls.append((mode, port)); self.mode = mode; return self.status(True)
    def off(self): self.calls.append(("off",)); self.mode = "off"; return self.status(True)

import marina_handler
fake = FakeRemote()
marina_handler._REMOTE_CONTROLLER = fake
server = ThreadingHTTPServer(("127.0.0.1", 0), marina_handler.Handler)
threading.Thread(target=server.serve_forever, daemon=True).start()

def request(method, path, session, body=None):
    conn = http.client.HTTPConnection("127.0.0.1", server.server_address[1], timeout=10)
    headers = {"Host": f"127.0.0.1:{server.server_address[1]}",
               "Cookie": f"marina_session={session.token}; marina_csrf={session.csrf_token}"}
    raw = None
    if body is not None:
        raw = json.dumps(body); headers.update({"Content-Type": "application/json", "X-Marina-CSRF": session.csrf_token})
    conn.request(method, path, raw, headers)
    response = conn.getresponse(); payload = json.loads(response.read()); conn.close()
    return response.status, payload

try:
    status, payload = request("GET", "/api/remote/status", member_session)
    assert status == 200 and payload["mode"] == "off"
    assert "ips" not in payload and "configuration" not in payload
    status, payload = request("POST", "/api/remote/serve", member_session, {})
    assert status == 403 and payload["error"] == "access_denied" and fake.calls == []
    status, payload = request("POST", "/api/remote/funnel", admin_session, {"password": "wrong-password"})
    assert status == 403 and payload["error"] == "reauth_failed" and fake.calls == []
    status, payload = request("POST", "/api/remote/funnel", admin_session, {"password": "owner-password"})
    assert status == 200 and payload["mode"] == "funnel" and payload["restartRequired"]
    assert fake.calls == [("funnel", 3900)], fake.calls
    assert (home / "dashboard-bind.env").read_text().startswith("MARINA_CONTROL_HOST=localhost\n")
    for _ in range(50):
        if (home / "restart-dry-run.log").exists() and "restart" in (home / "restart-dry-run.log").read_text():
            break
        time.sleep(0.02)
    assert "restart" in (home / "restart-dry-run.log").read_text(), (home / "restart-dry-run.log").read_text()
    status, payload = request("POST", "/api/remote/off", admin_session, {})
    assert status == 200 and payload["mode"] == "off" and fake.calls[-1] == ("off",)
    print("ok remote http boundary")
finally:
    server.shutdown(); server.server_close()
PY

echo "PASS test-remote-http"
