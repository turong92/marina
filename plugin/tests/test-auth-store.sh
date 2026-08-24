#!/usr/bin/env bash
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"   # 실 ~/.marina 격리

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SCR="$HERE/../scripts"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PYTHONPATH="$SCR" python3 - "$TMP" <<'PY'
import sqlite3
import sys
from pathlib import Path

from marina_auth import AuthStore

db = Path(sys.argv[1]) / "auth.db"
store = AuthStore(db, pbkdf2_iterations=1_000)
store.initialize()

with sqlite3.connect(db) as conn:
    names = {row[0] for row in conn.execute("select name from sqlite_master where type='table'")}
    expected = {
        "meta", "users", "project_access", "resource_owners",
        "auth_sessions", "auth_attempts", "audit_events",
    }
    assert expected <= names, names
    assert conn.execute("pragma journal_mode").fetchone()[0].lower() == "wal"
    assert conn.execute("select value from meta where key='schema_version'").fetchone()[0] == "2"

algorithm, iterations, salt, key = store.password_record("correct horse battery staple")
assert algorithm == "pbkdf2_sha256"
assert iterations == 1_000
assert len(salt) == 16
assert len(key) == 32
assert store.verify_password("correct horse battery staple", algorithm, iterations, salt, key)
assert not store.verify_password("wrong", algorithm, iterations, salt, key)
assert not store.verify_password("correct horse battery staple", "unknown", iterations, salt, key)
assert not store.auth_enabled()
assert db.stat().st_mode & 0o777 == 0o600
print("ok auth schema and password")

from marina_auth import AuthError

now = [1_700_000_000.0]
accounts_db = Path(sys.argv[1]) / "accounts.db"
accounts = AuthStore(accounts_db, pbkdf2_iterations=1_000, clock=lambda: now[0])
accounts.initialize()

admin = accounts.bootstrap_admin("Owner", "Owner", "owner-password")
assert (admin.username, admin.role, admin.status) == ("owner", "admin", "active")
assert accounts.auth_enabled()
try:
    accounts.bootstrap_admin("other", "Other", "another-password")
    raise AssertionError("duplicate bootstrap succeeded")
except AuthError as exc:
    assert (exc.code, exc.status) == ("already_initialized", 409)

member = accounts.add_user("sumin-dev", "Sumin Dev")
assert (member.role, member.status) == ("member", "unclaimed")
# **초대 계정은 비밀번호를 정하면 곧바로 활성이다**(2026-08-24 형 결정: "초대가 맞다").
# 마리나엔 회원가입 경로가 없어서 claim 에 닿는 사람은 언제나 관리자가 만들어준 사람뿐이고,
# 만든 순간 이미 승인한 것이라 승인 단계는 같은 결정을 두 번 시키는 군더더기였다.
assert accounts.claim_user("sumin-dev", "member-password").status == "active"
assert accounts.authenticate("sumin-dev", "member-password").username == "sumin-dev"

for attempt in range(5):
    try:
        accounts.authenticate("sumin-dev", "wrong-password")
    except AuthError as exc:
        if attempt < 4:
            assert exc.code == "invalid_credentials"
        else:
            assert exc.code == "rate_limited" and exc.status == 429 and exc.retry_after > 0
try:
    accounts.authenticate("sumin-dev", "member-password")
    raise AssertionError("locked account authenticated")
except AuthError as exc:
    assert exc.code == "rate_limited" and exc.status == 429 and exc.retry_after > 0
with sqlite3.connect(accounts_db) as conn:
    assert conn.execute(
        "select result from audit_events where action='auth.login' order by id desc limit 1"
    ).fetchone()[0] == "locked"
now[0] += 901
assert accounts.authenticate("sumin-dev", "member-password").username == "sumin-dev"

claim_db = Path(sys.argv[1]) / "claim-rate-limit.db"
claim_guard = AuthStore(claim_db, pbkdf2_iterations=1_000, clock=lambda: now[0])
claim_guard.initialize()
derived_passwords = [0]
original_password_record = claim_guard.password_record

def counted_password_record(password):
    derived_passwords[0] += 1
    return original_password_record(password)

claim_guard.password_record = counted_password_record

def assert_claim_locks(username, password, expected_error):
    for attempt in range(5):
        try:
            claim_guard.claim_user(username, password)
            raise AssertionError(f"claim unexpectedly succeeded for {expected_error}")
        except AuthError as exc:
            assert exc.code == ("rate_limited" if attempt == 4 else expected_error)

assert_claim_locks("unknown-user", "unknown-password", "unknown_user")
assert derived_passwords[0] == 0
try:
    claim_guard.claim_user("unknown-user", "unknown-password")
    raise AssertionError("locked claim succeeded")
except AuthError as exc:
    assert exc.code == "rate_limited"
assert derived_passwords[0] == 0
with sqlite3.connect(claim_db) as conn:
    assert conn.execute(
        "select result from audit_events where action='auth.claim' order by id desc limit 1"
    ).fetchone()[0] == "locked"
claimable = claim_guard.add_user("claimable-user", "Claimable User")
assert_claim_locks(claimable.username, "short", "weak_password")
now[0] += 901
# 초대 계정은 비밀번호를 정하는 순간 활성이다(승인 단계 없음 — 위 주석 참조).
assert claim_guard.claim_user(claimable.username, "claimable-password").status == "active"
assert derived_passwords[0] == 1
# 이미 비밀번호를 정한 계정에 또 claim 하면 거부된다 — 남이 남의 계정 비번을 덮어쓸 길을
# 열어두면 안 된다(초대 링크는 공개 경로다).
assert_claim_locks(claimable.username, "claimable-password", "already_claimed")
now[0] += 901
assert claim_guard.disable_user(claimable.username).status == "disabled"
assert_claim_locks(claimable.username, "claimable-password", "account_disabled")
assert derived_passwords[0] == 1

try:
    accounts.add_user("BAD USER", "Bad")
    raise AssertionError("invalid username accepted")
except AuthError as exc:
    assert exc.code == "invalid_username"

short = accounts.add_user("short-user", "Short User")
try:
    accounts.claim_user(short.username, "too-short")
    raise AssertionError("short password accepted")
except AuthError as exc:
    assert exc.code == "weak_password"

# reject 는 이제 **초대 취소**다 — 아직 비밀번호를 안 정한 초대를 거둬들인다.
# (이미 쓰고 있는 계정을 막는 건 disable 이다.)
rejected = accounts.add_user("rejected-user", "Rejected")
assert accounts.reject_user(rejected.username).status == "unclaimed"
with sqlite3.connect(accounts_db) as conn:
    password = conn.execute(
        "select password_hash from users where username=?", (rejected.username,)
    ).fetchone()[0]
    assert password is None

assert accounts.reset_password("sumin-dev").status == "unclaimed"
try:
    accounts.disable_user("owner")
    raise AssertionError("last admin disabled")
except AuthError as exc:
    assert exc.code == "last_admin"

users = accounts.list_users()
assert [user.username for user in users][:2] == ["owner", "rejected-user"]
with sqlite3.connect(accounts_db) as conn:
    assert conn.execute("select count(*) from audit_events").fetchone()[0] >= 8

audit_db = Path(sys.argv[1]) / "actor-audit.db"
audited = AuthStore(audit_db, pbkdf2_iterations=1_000)
audited.initialize()
audit_admin = audited.bootstrap_admin("audit-owner", "Audit Owner", "audit-password")
audit_member = audited.add_user(
    "audit-member", "Audit Member", actor_user_id=audit_admin.id
)
audit_member = audited.claim_user(audit_member.username, "audit-member-password")
audit_session = audited.create_session(audit_member.id)
assert audited.logout(audit_session.token, actor_user_id=audit_member.id)
with sqlite3.connect(audit_db) as conn:
    conn.row_factory = sqlite3.Row
    add_event = conn.execute(
        "select * from audit_events where action='user.add' and resource_key='audit-member'"
    ).fetchone()
    # 승인 이벤트는 이제 안 남는다(승인 단계 자체가 없다). 대신 **claim 이 활성 기록**이다.
    claim_event = conn.execute(
        "select * from audit_events where action='auth.claim' and resource_key='audit-member'"
    ).fetchone()
    logout_event = conn.execute(
        "select * from audit_events where action='auth.logout' and actor_user_id=?",
        (audit_member.id,),
    ).fetchone()
    assert add_event["actor_user_id"] == audit_admin.id and add_event["result"] == "ok"
    assert claim_event is not None and claim_event["result"] in ("ok", "active"), dict(claim_event or {})
    assert logout_event["result"] == "ok"

rehash_db = Path(sys.argv[1]) / "rehash.db"
weak = AuthStore(rehash_db, pbkdf2_iterations=1_000)
weak.initialize()
weak.bootstrap_admin("rehash-owner", "Rehash Owner", "rehash-password")
strong = AuthStore(rehash_db, pbkdf2_iterations=2_000)
assert strong.authenticate("rehash-owner", "rehash-password").username == "rehash-owner"
with sqlite3.connect(rehash_db) as conn:
    assert conn.execute(
        "select password_iterations from users where username='rehash-owner'"
    ).fetchone()[0] == 2_000
print("ok auth account lifecycle")

session = accounts.create_session(admin.id)
assert len(session.token) >= 43 and len(session.csrf_token) >= 43
for storage_file in accounts_db.parent.glob(accounts_db.name + "*"):
    raw = storage_file.read_bytes()
    assert session.token.encode() not in raw
    assert session.csrf_token.encode() not in raw
principal = accounts.resolve_session(session.token)
assert principal and principal.user.username == "owner"
assert accounts.verify_csrf(principal, session.csrf_token)
assert not accounts.verify_csrf(principal, "wrong")
try:
    accounts.reset_password("owner")
    raise AssertionError("last admin password reset")
except AuthError as exc:
    assert exc.code == "last_admin"

with sqlite3.connect(accounts_db) as conn:
    first_used = conn.execute(
        "select last_used_at from auth_sessions where id=?", (principal.session_id,)
    ).fetchone()[0]
now[0] += 60
assert accounts.resolve_session(session.token)
with sqlite3.connect(accounts_db) as conn:
    assert conn.execute(
        "select last_used_at from auth_sessions where id=?", (principal.session_id,)
    ).fetchone()[0] == first_used
now[0] += 301
assert accounts.resolve_session(session.token)
with sqlite3.connect(accounts_db) as conn:
    assert conn.execute(
        "select last_used_at from auth_sessions where id=?", (principal.session_id,)
    ).fetchone()[0] > first_used

assert accounts.logout(session.token)
assert accounts.resolve_session(session.token) is None

idle = accounts.create_session(admin.id)
now[0] += 30 * 24 * 60 * 60 + 1
assert accounts.resolve_session(idle.token) is None

absolute_start = now[0]
absolute = accounts.create_session(admin.id)
for _ in range(3):
    now[0] += 29 * 24 * 60 * 60
    assert accounts.resolve_session(absolute.token)
now[0] = absolute_start + 90 * 24 * 60 * 60 + 1
assert accounts.resolve_session(absolute.token) is None

session_member = accounts.add_user("session-member", "Session Member")
session_member = accounts.claim_user(session_member.username, "session-password")
member_session = accounts.create_session(session_member.id)
accounts.reset_password(session_member.username)
assert accounts.resolve_session(member_session.token) is None

disabled_member = accounts.add_user("disabled-member", "Disabled Member")
disabled_member = accounts.claim_user(disabled_member.username, "disabled-password")
disabled_session = accounts.create_session(disabled_member.id)
accounts.disable_user(disabled_member.username)
assert accounts.resolve_session(disabled_session.token) is None

one = accounts.create_session(admin.id)
two = accounts.create_session(admin.id)
assert accounts.revoke_user_sessions(admin.id) == 2
assert accounts.resolve_session(one.token) is None and accounts.resolve_session(two.token) is None
three = accounts.create_session(admin.id)
assert accounts.revoke_all_sessions() == 1
assert accounts.resolve_session(three.token) is None
print("ok auth sessions")
PY

echo "PASS test-auth-store"
