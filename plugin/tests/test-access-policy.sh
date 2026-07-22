#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SCR="$HERE/../scripts"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PYTHONPATH="$SCR" python3 - "$TMP" <<'PY'
import sqlite3
import sys
from pathlib import Path

from marina_auth import AuthStore, SessionPrincipal
from marina_access import AccessPolicy

db = Path(sys.argv[1]) / "auth.db"
store = AuthStore(db, pbkdf2_iterations=1000)
admin = store.bootstrap_admin("owner", "Owner", "owner-password")
member = store.add_user("dev-one", "Dev One", actor_user_id=admin.id)

with sqlite3.connect(db) as conn:
    conn.execute("update users set status='active' where id=?", (member.id,))
member = next(user for user in store.list_users() if user.id == member.id)
admin_p = SessionPrincipal(admin, 1, b"")
member_p = SessionPrincipal(member, 2, b"")

store.set_project_access(member.id, ["alpha", "beta"], actor_user_id=admin.id)
assert store.project_access_for(member.id) == {"alpha", "beta"}
store.set_project_access(member.id, ["beta"], actor_user_id=admin.id)
assert store.project_access_for(member.id) == {"beta"}

root = str((Path(sys.argv[1]) / "project" / "wt-one").resolve())
store.assign_resource_owner("worktree", root, member.id, actor_user_id=admin.id)
assert store.resource_owner("worktree", root) == member.id

policy = AccessPolicy(store, project_resolver=lambda _root: {"id": "beta"})
unowned_root = str((Path(sys.argv[1]) / "project" / "unowned").resolve())
assert policy.inherit_from_root("agent", "claude:unowned-agent", unowned_root) is None
assert store.resource_owner("agent", "claude:unowned-agent") is None
assert policy.can_project(admin_p, "alpha")
assert policy.can_project(member_p, "beta")
assert not policy.can_project(member_p, "alpha")
assert policy.can_resource(admin_p, "worktree", "/unowned")
assert policy.can_resource(member_p, "worktree", root)
assert policy.can_root(member_p, root)
assert not policy.can_resource(member_p, "worktree", "/unowned")

store.set_project_access(member.id, [], actor_user_id=admin.id)
assert not policy.can_root(member_p, root)
store.set_project_access(member.id, ["beta"], actor_user_id=admin.id)

store.assign_resource_owner("terminal", "team-terminal", member.id, actor_user_id=admin.id)
policy.assign(admin_p, "terminal", "team-terminal")
assert store.resource_owner("terminal", "team-terminal") == member.id

assert store.remove_resource_owner("terminal", "team-terminal", actor_user_id=admin.id)
assert store.resource_owner("terminal", "team-terminal") is None
assert not store.remove_resource_owner("terminal", "team-terminal", actor_user_id=admin.id)

store.assign_resource_owner(
    "agent", "codex:old-agent", member.id, actor_user_id=admin.id,
    parent_type="worktree", parent_key=root,
)
assert store.remove_resources_by_parent("worktree", root, actor_user_id=admin.id) == 1
assert store.resource_owner("agent", "codex:old-agent") is None

store.assign_resource_owner("worktree", root, admin.id, actor_user_id=admin.id)
assert not policy.can_resource(member_p, "worktree", root)
assert policy.can_resource(admin_p, "worktree", root)

with sqlite3.connect(db) as conn:
    conn.row_factory = sqlite3.Row
    actions = [row["action"] for row in conn.execute("select action from audit_events")]
    assert actions.count("access.projects.set") == 4
    assert actions.count("access.owner.set") == 4
    assert actions.count("access.owner.remove") == 2
    assert not any("password" in (row["request_meta"] or "") for row in conn.execute("select request_meta from audit_events"))

print("ok access policy")
PY

echo "PASS test-access-policy"
