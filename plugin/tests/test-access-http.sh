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
import urllib.parse
from http.server import ThreadingHTTPServer
from pathlib import Path

tmp = Path(sys.argv[1])
home = tmp / "home"
alpha, beta = tmp / "alpha", tmp / "beta"
alpha.mkdir(); beta.mkdir(); home.mkdir()
reused = alpha / "worktrees" / "feature-reused"
reused.mkdir(parents=True)
(home / "projects.json").write_text(json.dumps({"projects": [
    {"id": "alpha", "root": str(alpha), "kind": "compose", "subrepos": [], "worktreeGlobs": ["worktrees/*"]},
    {"id": "beta", "root": str(beta), "kind": "compose", "subrepos": [], "worktreeGlobs": []},
]}))
os.environ.update({
    "MARINA_HOME": str(home), "MARINA_AUTH_DB": str(home / "auth.db"),
    "MARINA_AUTH_PBKDF2_ITERATIONS": "1000", "MARINA_CONTROL_HOST": "127.0.0.1",
    "CODEX_WORKTREES_ROOT": str(tmp / "codex-worktrees"),
})

from marina_auth import AuthStore
store = AuthStore(home / "auth.db", pbkdf2_iterations=1000)
admin = store.bootstrap_admin("owner", "Owner", "owner-password")
member = store.add_user("dev-one", "Dev One", actor_user_id=admin.id)
with store._transaction() as conn:
    conn.execute("update users set status='active' where id=?", (member.id,))
store.set_project_access(member.id, ["alpha"], actor_user_id=admin.id)
store.assign_resource_owner("worktree", str(alpha.resolve()), member.id, actor_user_id=admin.id)
store.assign_resource_owner("terminal", "term-alpha", member.id, actor_user_id=admin.id)
store.assign_resource_owner("worktree", str(reused.resolve()), admin.id, actor_user_id=admin.id)
admin_session = store.create_session(admin.id)
member_session = store.create_session(member.id)

import marina_handler
marina_handler.safe_root = lambda text: Path(text).resolve()
marina_handler.term_list = lambda: {"sessions": [
    {"tid": "term-alpha", "root": str(alpha.resolve())},
    {"tid": "term-reused", "root": str(reused.resolve())},
]}
marina_handler.term_input = lambda tid, data: {"ok": True, "tid": tid}
marina_handler.term_resize = lambda tid, cols, rows: {"ok": True, "tid": tid}
marina_handler.term_kill = lambda tid: {"ok": True, "tid": tid}
marina_handler.term_open = lambda root, cols, rows, agent_source="", agent_sid="": {
    "ok": True, "tid": "opened-term", "root": str(root),
}
marina_handler.mobile_send = lambda body: {"ok": True, "tid": "mobile-term"}
marina_handler.agent_belongs_to_root = lambda root, source, sid: (
    Path(root).resolve() == alpha.resolve() and source == "codex" and sid == "agent-alpha"
)
marina_handler.agents_payload = lambda root, refresh=False: ([{
    "source": "codex", "sid": "agent-reused", "root": str(reused.resolve()),
}] if Path(root).resolve() == reused.resolve() else [])
marina_handler._marina_cli = lambda target, *args, **kwargs: f"✓ 워크트리: {reused}\n"
remove_result = {"value": {"root": {"removed": str(reused)}}}
marina_handler.remove_worktree = lambda root, force=False: remove_result["value"]
Handler = marina_handler.Handler
server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
import marina_sessions
marina_sessions.PORT = server.server_address[1]
threading.Thread(target=server.serve_forever, daemon=True).start()

def request(path, session):
    conn = http.client.HTTPConnection("127.0.0.1", server.server_address[1], timeout=20)
    conn.request("GET", path, headers={
        "Host": f"127.0.0.1:{server.server_address[1]}",
        "Cookie": f"marina_session={session.token}; marina_csrf={session.csrf_token}",
    })
    response = conn.getresponse()
    payload = json.loads(response.read())
    conn.close()
    return response.status, payload

def post(path, session, body):
    conn = http.client.HTTPConnection("127.0.0.1", server.server_address[1], timeout=20)
    raw = json.dumps(body)
    conn.request("POST", path, raw, headers={
        "Host": f"127.0.0.1:{server.server_address[1]}",
        "Origin": f"http://127.0.0.1:{server.server_address[1]}",
        "Content-Type": "application/json", "X-Marina-CSRF": session.csrf_token,
        "Cookie": f"marina_session={session.token}; marina_csrf={session.csrf_token}",
    })
    response = conn.getresponse()
    payload = json.loads(response.read())
    conn.close()
    return response.status, payload

try:
    status, payload = request("/api/worktrees", member_session)
    assert status == 200
    assert [item["id"] for item in payload["projects"]] == ["alpha"]
    assert all("root" not in item for item in payload["projects"])
    assert {Path(item["root"]).resolve() for item in payload["worktrees"]} == {alpha.resolve()}

    store.set_project_access(member.id, [], actor_user_id=admin.id)
    status, payload = request("/api/worktrees", member_session)
    assert status == 200 and payload["projects"] == [] and payload["worktrees"] == []
    target = urllib.parse.quote(str(alpha.resolve()))
    status, payload = request(f"/api/build-summary?root={target}", member_session)
    assert status == 403 and payload["error"] == "access_denied"
    for path, body in (
        ("/api/term-input", {"tid": "term-alpha", "data": "pwd\n"}),
        ("/api/term-resize", {"tid": "term-alpha", "cols": 100, "rows": 30}),
        ("/api/term-kill", {"tid": "term-alpha"}),
    ):
        status, payload = post(path, member_session, body)
        assert status == 403 and payload["error"] == "access_denied", (path, status, payload)
    store.set_project_access(member.id, ["alpha"], actor_user_id=admin.id)

    status, payload = request("/api/worktrees", admin_session)
    assert status == 200 and {item["id"] for item in payload["projects"]} == {"alpha", "beta"}

    target = urllib.parse.quote(str(beta.resolve()))
    status, payload = request(f"/api/build-summary?root={target}", member_session)
    assert status == 403 and payload["error"] == "access_denied"

    status, payload = request("/api/auth/access/resources", member_session)
    assert status == 403 and payload["error"] == "admin_required"

    store.set_project_access(member.id, ["beta"], actor_user_id=admin.id)
    store.assign_resource_owner("worktree", str(beta.resolve()), member.id, actor_user_id=admin.id)
    for path, body in (
        ("/api/term-open", {
            "root": str(beta.resolve()), "agent": {"source": "codex", "sid": "agent-alpha"},
        }),
        ("/mobile/api/send", {
            "root": str(beta.resolve()), "target": {"type": "agent", "source": "codex", "sid": "agent-alpha"},
            "text": "continue",
        }),
    ):
        status, payload = post(path, member_session, body)
        assert status == 403 and payload["error"] == "access_denied", (path, status, payload)
    store.set_project_access(member.id, ["alpha"], actor_user_id=admin.id)

    status, payload = post("/api/worktree-create", member_session, {
        "projectId": "alpha", "branch": "feature/reused",
    })
    assert status == 200 and payload["ok"] is True, (status, payload)
    assert store.resource_owner("worktree", str(reused.resolve())) == member.id

    store.assign_resource_owner(
        "terminal", "term-reused", member.id, actor_user_id=admin.id,
        parent_type="worktree", parent_key=str(reused.resolve()),
    )
    agent_key = "codex:agent-reused"
    store.assign_resource_owner(
        "agent", agent_key, member.id, actor_user_id=admin.id,
        parent_type="worktree", parent_key=str(reused.resolve()),
    )
    old_agent_key = "codex:agent-older-than-card-limit"
    store.assign_resource_owner(
        "agent", old_agent_key, member.id, actor_user_id=admin.id,
        parent_type="worktree", parent_key=str(reused.resolve()),
    )
    remove_result["value"] = {"root": {"error": "git worktree remove failed", "path": str(reused)}}
    status, payload = post("/api/remove-worktree", member_session, {
        "root": str(reused.resolve()), "force": True,
    })
    assert status == 200 and payload["root"]["error"]
    assert store.resource_owner("worktree", str(reused.resolve())) == member.id
    assert store.resource_owner("terminal", "term-reused") == member.id
    assert store.resource_owner("agent", old_agent_key) == member.id

    remove_result["value"] = {"root": {"removed": str(reused)}}
    status, payload = post("/api/remove-worktree", member_session, {
        "root": str(reused.resolve()), "force": True,
    })
    assert status == 200 and payload["root"]["removed"]
    assert store.resource_owner("worktree", str(reused.resolve())) is None
    assert store.resource_owner("terminal", "term-reused") is None
    assert store.resource_owner("agent", agent_key) is None
    assert store.resource_owner("agent", old_agent_key) is None
    print("ok access http matrix")
finally:
    server.shutdown(); server.server_close()
PY

echo "PASS test-access-http"
