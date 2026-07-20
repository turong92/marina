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
import sqlite3
import sys
import threading
from http.cookies import SimpleCookie
from http.server import ThreadingHTTPServer
from pathlib import Path

tmp = Path(sys.argv[1])
home = tmp / "home"
os.environ["MARINA_HOME"] = str(home)
os.environ["MARINA_AUTH_DB"] = str(home / "auth.db")
os.environ["MARINA_AUTH_PBKDF2_ITERATIONS"] = "1000"
os.environ["MARINA_CONTROL_HOST"] = "127.0.0.1"

from marina_handler import Handler

server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
threading.Thread(target=server.serve_forever, daemon=True).start()
port = server.server_address[1]


def cookie_jar(headers):
    jar = {}
    for raw in headers.get_all("set-cookie", []):
        parsed = SimpleCookie()
        parsed.load(raw)
        for name, morsel in parsed.items():
            jar[name] = morsel.value
    return jar


def request(method, path, payload=None, cookies=None, csrf=None, forwarded_https=False, origin=None):
    conn = http.client.HTTPConnection("127.0.0.1", port, timeout=10)
    headers = {"Host": f"127.0.0.1:{port}"}
    if payload is not None:
        headers["Content-Type"] = "application/json"
        body = json.dumps(payload)
    else:
        body = None
    if cookies:
        headers["Cookie"] = "; ".join(f"{key}={value}" for key, value in cookies.items())
    if csrf:
        headers["X-Marina-CSRF"] = csrf
    if forwarded_https:
        headers["X-Forwarded-Proto"] = "https"
    if origin:
        headers["Origin"] = origin
    conn.request(method, path, body=body, headers=headers)
    response = conn.getresponse()
    raw = response.read()
    result = json.loads(raw) if raw and response.getheader("content-type", "").startswith("application/json") else raw.decode("utf-8", errors="replace")
    status, response_headers = response.status, response.headers
    conn.close()
    return status, response_headers, result


try:
    status, headers, body = request("GET", "/api/health")
    assert status == 200 and body == {"ok": True}
    assert headers["x-frame-options"] == "DENY"
    assert headers["x-content-type-options"] == "nosniff"
    assert headers["referrer-policy"] == "no-referrer"
    assert "frame-ancestors 'none'" in headers["content-security-policy"]

    status, headers, body = request("GET", "/api/auth/status")
    assert status == 200 and body["enabled"] is False and body["bootstrapAllowed"] is True
    assert headers["cache-control"] == "no-store"

    status, headers, body = request("GET", "/api/auth/status", forwarded_https=True)
    assert status == 200 and headers["strict-transport-security"].startswith("max-age=")

    status, headers, body = request("POST", "/api/auth/bootstrap", {
        "username": "owner", "displayName": "Owner", "password": "owner-password",
    }, forwarded_https=True)
    assert status == 201 and body["user"]["role"] == "admin"
    set_cookies = headers.get_all("set-cookie")
    assert len(set_cookies) == 2
    assert any("marina_session=" in value and "HttpOnly" in value and "SameSite=Lax" in value for value in set_cookies)
    assert any("marina_csrf=" in value and "HttpOnly" not in value for value in set_cookies)
    assert all("Secure" in value and "Max-Age=7776000" in value for value in set_cookies)

    status, headers, body = request("GET", "/")
    assert status == 302 and headers["location"] == "/login?next=%2F"
    status, headers, body = request("GET", "/login?next=%2F")
    assert status == 200 and 'id="authUnavailable"' in body
    status, headers, body = request("GET", "/web/auth-login.js")
    assert status == 200 and "auth_unavailable" in body
    status, headers, body = request("GET", "/mobile")
    assert status == 302 and headers["location"] == "/login?next=%2Fmobile"
    status, headers, body = request("GET", "/api/worktrees")
    assert status == 401 and body["error"] == "authentication_required"

    status, headers, body = request("POST", "/api/auth/login", {
        "username": "owner", "password": "owner-password",
    })
    assert status == 200 and body["user"]["username"] == "owner"
    admin_cookies = cookie_jar(headers)
    assert set(admin_cookies) == {"marina_session", "marina_csrf"}

    status, headers, body = request("GET", "/api/auth/status", cookies=admin_cookies)
    assert status == 200 and body["user"]["role"] == "admin"

    status, headers, body = request("POST", "/api/auth/users/add", {
        "username": "teammate", "displayName": "Team Mate", "role": "member",
    }, cookies=admin_cookies)
    assert status == 403 and body["error"] == "csrf_failed"

    status, headers, body = request("POST", "/api/auth/users/add", {
        "username": "teammate", "displayName": "Team Mate", "role": "member",
    }, cookies=admin_cookies, csrf=admin_cookies["marina_csrf"], origin="https://evil.example")
    assert status == 403 and body["error"] == "forbidden_origin"

    status, headers, body = request("POST", "/api/auth/users/add", {
        "username": "teammate", "displayName": "Team Mate", "role": "member",
    }, cookies=admin_cookies, csrf=admin_cookies["marina_csrf"])
    assert status == 201 and body["user"]["status"] == "unclaimed"

    status, headers, body = request("POST", "/api/auth/claim", {
        "username": "teammate", "password": "teammate-password",
    })
    assert status == 202 and body["status"] == "pending_approval"
    status, headers, body = request("POST", "/api/auth/users/approve", {"username": "teammate"},
                                    cookies=admin_cookies, csrf=admin_cookies["marina_csrf"])
    assert status == 200 and body["user"]["status"] == "active"

    status, headers, body = request("POST", "/api/auth/login", {
        "username": "teammate", "password": "teammate-password",
    })
    assert status == 200
    member_cookies = cookie_jar(headers)
    status, headers, body = request("GET", "/api/auth/users", cookies=member_cookies)
    assert status == 403 and body["error"] == "admin_required"

    status, headers, body = request("GET", "/api/auth/users", cookies=admin_cookies)
    assert status == 200 and {item["username"] for item in body["users"]} == {"owner", "teammate"}

    status, headers, body = request("POST", "/api/auth/logout", {}, cookies=member_cookies,
                                    csrf=member_cookies["marina_csrf"])
    assert status == 200
    assert all("Max-Age=0" in value for value in headers.get_all("set-cookie"))
    with sqlite3.connect(home / "auth.db") as conn:
        admin_id = conn.execute("select id from users where username='owner'").fetchone()[0]
        member_id = conn.execute("select id from users where username='teammate'").fetchone()[0]
        assert conn.execute(
            "select actor_user_id from audit_events where action='user.add' and resource_key='teammate'"
        ).fetchone()[0] == admin_id
        assert conn.execute(
            "select actor_user_id from audit_events where action='user.approve' and resource_key='teammate'"
        ).fetchone()[0] == admin_id
        assert conn.execute(
            "select actor_user_id from audit_events where action='auth.logout' order by id desc limit 1"
        ).fetchone()[0] == member_id

    from marina_auth_http import is_loopback_client
    assert is_loopback_client(type("Local", (), {"client_address": ("127.0.0.1", 1)})())
    assert not is_loopback_client(type("Remote", (), {"client_address": ("203.0.113.10", 1)})())

    bad_db = tmp / "bad.db"
    bad_db.write_bytes(b"not a sqlite database")
    os.environ["MARINA_AUTH_DB"] = str(bad_db)
    status, headers, body = request("GET", "/api/auth/status")
    assert status == 503 and body == {
        "error": "auth_unavailable",
        "message": "Authentication storage is unavailable. Check the local Marina logs.",
    }
    status, headers, body = request("GET", "/")
    assert status == 302 and headers["location"] == "/login?next=%2F"
    status, headers, body = request("GET", "/login?next=%2F")
    assert status == 200 and 'id="authUnavailable"' in body
    status, headers, body = request("GET", "/web/auth-login.js")
    assert status == 200 and "auth_unavailable" in body
    print("ok auth http boundary")
finally:
    server.shutdown()
    server.server_close()
PY

echo "PASS test-auth-http"
