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
from http.server import ThreadingHTTPServer
from pathlib import Path

home = Path(sys.argv[1]) / "home"
os.environ.update({
    "MARINA_HOME": str(home),
    "MARINA_AUTH_DB": str(home / "auth.db"),
    "MARINA_AUTH_PBKDF2_ITERATIONS": "1000",
    "MARINA_CONTROL_HOST": "0.0.0.0",
    "MARINA_CONTROL_PORT": "3900",
})

import marina_handler
from marina_auth import AuthStore


class FakeRemote:
    def status(self, refresh=False):
        return {
            "installed": True,
            "online": True,
            "mode": "off",
            "state": "off",
            "url": None,
            "ips": ["100.64.0.8"],
        }


marina_handler._REMOTE_CONTROLLER = FakeRemote()
server = ThreadingHTTPServer(("127.0.0.1", 0), marina_handler.Handler)
threading.Thread(target=server.serve_forever, daemon=True).start()


def request(method, path, session=None):
    conn = http.client.HTTPConnection("127.0.0.1", server.server_address[1], timeout=10)
    headers = {"Host": f"127.0.0.1:{server.server_address[1]}"}
    if session is not None:
        headers["Cookie"] = (
            f"marina_session={session.token}; marina_csrf={session.csrf_token}"
        )
        headers["X-Marina-CSRF"] = session.csrf_token
    if method == "POST":
        headers["Content-Type"] = "application/json"
    conn.request(method, path, "{}" if method == "POST" else None, headers)
    response = conn.getresponse()
    payload = json.loads(response.read())
    conn.close()
    return response.status, payload


try:
    status, payload = request("GET", "/api/mobile/access")
    assert status == 200 and payload["enabled"] is False, (status, payload)
    assert payload["address"] == "http://100.64.0.8:3900/mobile", payload

    status, enabled = request("POST", "/api/mobile/enable")
    assert status == 200 and enabled["enabled"] is True, (status, enabled)
    assert enabled["loginUrl"].startswith(enabled["address"] + "?token="), enabled
    first_url = enabled["loginUrl"]

    status, rotated = request("POST", "/api/mobile/rotate")
    assert status == 200 and rotated["loginUrl"] != first_url, (status, rotated)

    status, disabled = request("POST", "/api/mobile/disable")
    assert status == 200 and disabled["enabled"] is False, (status, disabled)

    real_loopback_check = marina_handler.is_loopback_client
    marina_handler.is_loopback_client = lambda _handler: False
    status, payload = request("POST", "/api/mobile/enable")
    assert status == 403 and payload["error"] == "access_denied", (status, payload)
    marina_handler.is_loopback_client = real_loopback_check

    store = AuthStore(home / "auth.db", pbkdf2_iterations=1000)
    admin = store.bootstrap_admin("owner", "Owner", "owner-password")
    member = store.add_user("dev-one", "Dev One")
    with store._transaction() as conn:
        conn.execute("update users set status='active' where id=?", (member.id,))
    admin_session = store.create_session(admin.id)
    member_session = store.create_session(member.id)

    status, payload = request("GET", "/api/mobile/access", member_session)
    assert status == 403 and payload["error"] == "access_denied", (status, payload)
    status, payload = request("POST", "/api/mobile/enable", admin_session)
    assert status == 200 and payload["enabled"] is True and payload["authEnabled"] is True
    assert payload["loginUrl"] == payload["address"], payload
    print("ok mobile admin http boundary")
finally:
    server.shutdown()
    server.server_close()
PY

node --check "$SCR/marina-web/app-6e-mobile.js"
grep -q 'id="mobileAccessBtn"' "$SCR/marina-web/index.html"
grep -q 'id="mobileAccessDialog"' "$SCR/marina-web/index.html"
grep -q 'src="/web/app-6e-mobile.js"' "$SCR/marina-web/index.html"

echo "PASS test-mobile-admin-http"
