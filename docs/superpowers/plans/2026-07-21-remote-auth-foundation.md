# Remote Auth Foundation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Marina의 기존 localhost 사용성을 유지하면서, 최초 관리자 초기화 이후 모든 desktop/mobile API에 로컬 계정 로그인, 세션, CSRF, 사용자 사전 등록과 승인 절차를 적용한다.

**Architecture:** `marina_auth.py`가 SQLite schema, 비밀번호, 계정 상태, 세션, rate limit과 감사 이벤트를 소유한다. `marina_auth_http.py`는 이 도메인 API를 HTTP cookie/CSRF/보안 헤더와 연결하고, 기존 `marina_handler.Handler`는 GET/POST 입구에서 인증 controller를 한 번 호출한 뒤 기존 route를 그대로 실행한다. 독립 로그인 화면은 desktop/mobile이 공유하고, 설정 메뉴의 사용자 관리 화면은 같은 auth API만 사용한다.

**Tech Stack:** Python 3.9+ stdlib (`sqlite3`, `hashlib`, `hmac`, `secrets`, `http.cookies`), `ThreadingHTTPServer`, vanilla HTML/CSS/JavaScript, bash contract tests.

## Global Constraints

- 인증 DB는 `~/.marina/auth.db` 한 파일이며 외부 DB, pip 패키지, Docker 서비스를 추가하지 않는다.
- 비밀번호는 PBKDF2-HMAC-SHA256, 기본 600,000회, salt 16바이트, key 32바이트를 사용한다.
- 계정 상태는 `unclaimed`, `pending_approval`, `active`, `disabled`; 역할은 `admin`, `member`만 허용한다.
- 최초 관리자 초기화는 loopback 요청 또는 로컬 CLI에서만 허용한다.
- 세션은 30일 비활성, 90일 절대 만료이며 비밀번호 변경·초기화·비활성화 때 즉시 폐기한다.
- 로그인과 claim은 사용자명별 15분 동안 5회 실패하면 15분 잠근다.
- 인증 초기화 전에는 현재 localhost 및 mobile token 동작을 유지한다.
- 인증 초기화 후 localhost와 mobile을 포함한 모든 데이터 API가 인증을 요구한다.
- `marina_session`은 HttpOnly host-only cookie, `marina_csrf`는 JavaScript가 header로 반사하는 host-only cookie다.
- 인증 DB/migration 오류는 무인증 fallback으로 우회하지 않는다.
- 이 계획은 애플리케이션 인증까지만 구현한다. 리소스 소유권, Tailscale Serve, Funnel은 별도 계획이다.

---

## File Structure

- Create `plugin/scripts/marina_auth.py`: schema migration, password derivation, users, sessions, attempts, audit log.
- Create `plugin/scripts/marina_auth_http.py`: auth routes, cookies, CSRF, redirects, security headers, request principal.
- Create `plugin/scripts/marina_auth_cli.py`: local recovery and user administration commands.
- Create `plugin/scripts/marina-web/login.html`: shared desktop/mobile login, claim, bootstrap, pending states.
- Create `plugin/scripts/marina-web/auth-login.js`: login page state machine and auth API calls.
- Create `plugin/scripts/marina-web/auth.css`: compact responsive auth and user-management layout.
- Create `plugin/scripts/marina-web/app-0-auth.js`: authenticated app bootstrap, CSRF injection, 401 redirect.
- Create `plugin/scripts/marina-web/app-6c-users.js`: settings entry and admin user-management dialog.
- Modify `plugin/scripts/marina_handler.py`: central auth dispatch/guard and secure response headers.
- Modify `plugin/scripts/marina-control.py`: re-export auth modules for the existing test harness.
- Modify `plugin/scripts/marina_mobile.py`: use cookie auth after activation and preserve legacy token before activation.
- Modify `plugin/scripts/marina-entrypoint.sh`: route `marina auth` and `marina user` commands.
- Modify `plugin/scripts/marina-web/index.html`: load auth bootstrap and expose user-management settings entry/dialog.
- Modify `plugin/scripts/marina-web/styles.css`: authenticated header/user dialog states.
- Create `plugin/tests/test-auth-store.sh`: database, password, account, session, rate-limit tests.
- Create `plugin/tests/test-auth-http.sh`: real HTTP server auth, cookie, CSRF, redirect, security tests.
- Create `plugin/tests/test-auth-ui.sh`: static frontend contracts and JavaScript syntax tests.
- Create `plugin/tests/test-auth-cli.sh`: isolated `MARINA_HOME` CLI recovery tests.
- Modify `plugin/tests/test-mobile-control.sh`: legacy token before activation and cookie auth after activation.

---

### Task 1: SQLite Schema And Password Policy

**Files:**
- Create: `plugin/scripts/marina_auth.py`
- Create: `plugin/tests/test-auth-store.sh`

**Interfaces:**
- Produces: `AuthError(code: str, message: str, status: int = 400, retry_after: int = 0)`
- Produces: `AuthStore(db_path: Path | None = None, pbkdf2_iterations: int = 600_000, clock: Callable[[], float] = time.time)`
- Produces: `AuthStore.initialize() -> None`
- Produces: `AuthStore.auth_enabled() -> bool`
- Produces: `AuthStore.password_record(password: str) -> tuple[str, int, bytes, bytes]`
- Produces: `AuthStore.verify_password(password: str, algorithm: str, iterations: int, salt: bytes, expected: bytes) -> bool`

- [x] **Step 1: Write the failing schema and password tests**

Add a Python heredoc to `plugin/tests/test-auth-store.sh` that creates an isolated DB and asserts exact schema and derivation behavior:

```bash
#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SCR="$HERE/../scripts"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

PYTHONPATH="$SCR" python3 - "$TMP" <<'PY'
import sqlite3, sys
from pathlib import Path
from marina_auth import AuthStore

db = Path(sys.argv[1]) / "auth.db"
store = AuthStore(db, pbkdf2_iterations=1_000)
store.initialize()
with sqlite3.connect(db) as conn:
    names = {row[0] for row in conn.execute("select name from sqlite_master where type='table'")}
    assert {"meta", "users", "project_access", "resource_owners", "auth_sessions", "auth_attempts", "audit_events"} <= names
    assert conn.execute("pragma journal_mode").fetchone()[0].lower() == "wal"
algorithm, iterations, salt, key = store.password_record("correct horse battery staple")
assert algorithm == "pbkdf2_sha256" and iterations == 1_000
assert len(salt) == 16 and len(key) == 32
assert store.verify_password("correct horse battery staple", algorithm, iterations, salt, key)
assert not store.verify_password("wrong", algorithm, iterations, salt, key)
assert not store.auth_enabled()
assert db.stat().st_mode & 0o777 == 0o600
print("ok auth schema and password")
PY
echo "PASS test-auth-store schema"
```

- [x] **Step 2: Run the test and verify RED**

Run: `bash plugin/tests/test-auth-store.sh`

Expected: `ModuleNotFoundError: No module named 'marina_auth'`.

- [x] **Step 3: Implement schema v1 and password helpers**

Create `marina_auth.py` with a per-operation SQLite connection, `busy_timeout=5000`, `foreign_keys=ON`, WAL initialization, and a transactional `MIGRATIONS` map keyed by target schema version. Create the parent directory with mode `0700` when absent and force the DB file to `0600` after opening. Use these exact constants and public types:

```python
AUTH_DB = Path(os.environ.get("MARINA_AUTH_DB", str(MARINA_HOME / "auth.db")))
SCHEMA_VERSION = 1
PBKDF2_ALGORITHM = "pbkdf2_sha256"
PBKDF2_ITERATIONS = 600_000
PASSWORD_SALT_BYTES = 16
PASSWORD_KEY_BYTES = 32

class AuthError(Exception):
    def __init__(self, code: str, message: str, status: int = 400, retry_after: int = 0):
        super().__init__(message)
        self.code, self.message, self.status, self.retry_after = code, message, status, retry_after

class AuthStore:
    def __init__(self, db_path=None, pbkdf2_iterations=PBKDF2_ITERATIONS, clock=time.time):
        self.db_path = Path(db_path or AUTH_DB)
        self.pbkdf2_iterations = pbkdf2_iterations
        self.clock = clock

    def password_record(self, password):
        salt = secrets.token_bytes(PASSWORD_SALT_BYTES)
        key = hashlib.pbkdf2_hmac("sha256", password.encode("utf-8"), salt,
                                  self.pbkdf2_iterations, dklen=PASSWORD_KEY_BYTES)
        return PBKDF2_ALGORITHM, self.pbkdf2_iterations, salt, key

    def verify_password(self, password, algorithm, iterations, salt, expected):
        if algorithm != PBKDF2_ALGORITHM:
            return False
        actual = hashlib.pbkdf2_hmac("sha256", password.encode("utf-8"), salt,
                                     iterations, dklen=len(expected))
        return hmac.compare_digest(actual, expected)
```

The `users` table must keep password fields nullable for `unclaimed` users; `auth_sessions.token_hash` and `auth_sessions.csrf_hash` are unique BLOBs. Store schema version and `auth_enabled_at` in `meta` rows.

Use this schema inside the v1 migration so later tasks use the same names:

```sql
CREATE TABLE meta (
  key TEXT PRIMARY KEY,
  value TEXT NOT NULL
);
CREATE TABLE users (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  username TEXT NOT NULL UNIQUE COLLATE NOCASE,
  display_name TEXT NOT NULL,
  role TEXT NOT NULL CHECK (role IN ('admin', 'member')),
  status TEXT NOT NULL CHECK (status IN ('unclaimed', 'pending_approval', 'active', 'disabled')),
  password_algorithm TEXT,
  password_iterations INTEGER,
  password_salt BLOB,
  password_hash BLOB,
  approved_at REAL,
  created_at REAL NOT NULL,
  updated_at REAL NOT NULL
);
CREATE TABLE project_access (
  user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  project_id TEXT NOT NULL,
  PRIMARY KEY (user_id, project_id)
);
CREATE TABLE resource_owners (
  resource_type TEXT NOT NULL,
  resource_key TEXT NOT NULL,
  owner_user_id INTEGER NOT NULL REFERENCES users(id),
  created_at REAL NOT NULL,
  updated_at REAL NOT NULL,
  PRIMARY KEY (resource_type, resource_key)
);
CREATE TABLE auth_sessions (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  token_hash BLOB NOT NULL UNIQUE,
  csrf_hash BLOB NOT NULL UNIQUE,
  created_at REAL NOT NULL,
  last_used_at REAL NOT NULL,
  idle_expires_at REAL NOT NULL,
  absolute_expires_at REAL NOT NULL
);
CREATE TABLE auth_attempts (
  username TEXT NOT NULL COLLATE NOCASE,
  kind TEXT NOT NULL CHECK (kind IN ('login', 'claim')),
  window_started_at REAL NOT NULL,
  failure_count INTEGER NOT NULL,
  locked_until REAL,
  PRIMARY KEY (username, kind)
);
CREATE TABLE audit_events (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  actor_user_id INTEGER REFERENCES users(id),
  action TEXT NOT NULL,
  resource_type TEXT,
  resource_key TEXT,
  result TEXT NOT NULL,
  created_at REAL NOT NULL,
  request_meta TEXT
);
CREATE INDEX auth_sessions_user_idx ON auth_sessions(user_id);
CREATE INDEX audit_events_created_idx ON audit_events(created_at);
```

- [x] **Step 4: Run the test and verify GREEN**

Run: `bash plugin/tests/test-auth-store.sh`

Expected: `PASS test-auth-store schema`.

- [x] **Step 5: Commit the storage foundation**

```bash
git add plugin/scripts/marina_auth.py plugin/tests/test-auth-store.sh
git commit -m "feat(auth): add sqlite auth store"
```

### Task 2: Account Lifecycle, Approval, And Rate Limits

**Files:**
- Modify: `plugin/scripts/marina_auth.py`
- Modify: `plugin/tests/test-auth-store.sh`

**Interfaces:**
- Consumes: `AuthStore`, `AuthError`
- Produces: `User(id: int, username: str, display_name: str, role: str, status: str)`
- Produces: `bootstrap_admin(username: str, display_name: str, password: str) -> User`
- Produces: `add_user(username: str, display_name: str, role: str = "member") -> User`
- Produces: `claim_user(username: str, password: str) -> User`
- Produces: `approve_user(username: str) -> User`, `reject_user(username: str) -> User`
- Produces: `disable_user(username: str) -> User`, `reset_password(username: str) -> User`
- Produces: `authenticate(username: str, password: str) -> User`
- Produces: `list_users() -> list[User]`

- [x] **Step 1: Add failing account-state and lockout tests**

Append tests using a mutable clock and assert the complete state machine:

```python
now = [1_700_000_000.0]
accounts = AuthStore(Path(sys.argv[1]) / "accounts.db", pbkdf2_iterations=1_000, clock=lambda: now[0])
accounts.initialize()
admin = accounts.bootstrap_admin("owner", "Owner", "owner-password")
assert (admin.role, admin.status, accounts.auth_enabled()) == ("admin", "active", True)
member = accounts.add_user("sumin-dev", "Sumin Dev")
assert member.status == "unclaimed"
assert accounts.claim_user("sumin-dev", "member-password").status == "pending_approval"
try:
    accounts.authenticate("sumin-dev", "member-password")
    raise AssertionError("pending user authenticated")
except AuthError as exc:
    assert (exc.code, exc.status) == ("pending_approval", 403)
assert accounts.approve_user("sumin-dev").status == "active"
assert accounts.authenticate("sumin-dev", "member-password").username == "sumin-dev"
for _ in range(5):
    try: accounts.authenticate("sumin-dev", "wrong")
    except AuthError: pass
try:
    accounts.authenticate("sumin-dev", "member-password")
    raise AssertionError("locked account authenticated")
except AuthError as exc:
    assert exc.code == "rate_limited" and exc.status == 429 and exc.retry_after > 0
now[0] += 901
assert accounts.authenticate("sumin-dev", "member-password").username == "sumin-dev"
```

Also assert duplicate bootstrap, invalid usernames, short passwords, last-admin disable, reject-to-unclaimed, reset-to-unclaimed, and password columns cleared on reset. When auth is disabled, `bootstrap_admin` may reactivate an existing `unclaimed` username as the initial active admin; it still rejects bootstrap while `auth_enabled_at` exists. Create one user with a 1,000-iteration store, reopen that DB with a 2,000-iteration store, authenticate, and assert its `password_iterations` changed to 2,000 while the password still verifies.

- [x] **Step 2: Run the account tests and verify RED**

Run: `bash plugin/tests/test-auth-store.sh`

Expected: FAIL with `AttributeError: 'AuthStore' object has no attribute 'bootstrap_admin'`.

- [x] **Step 3: Implement the account state machine**

Use `^[a-z0-9][a-z0-9._-]{2,31}$` for normalized lowercase usernames and require passwords of at least 12 characters. Every state-changing method must use `BEGIN IMMEDIATE`, re-read state inside the transaction, and append an `audit_events` row without storing passwords.

Implement attempts with these constants and behavior:

```python
ATTEMPT_WINDOW_SECONDS = 15 * 60
ATTEMPT_LIMIT = 5
LOCK_SECONDS = 15 * 60

def _check_attempt_lock(self, conn, username, kind):
    now = self.clock()
    row = conn.execute(
        "SELECT window_started_at, failure_count, locked_until "
        "FROM auth_attempts WHERE username=? AND kind=?",
        (username, kind),
    ).fetchone()
    if row is None:
        return
    locked_until = float(row[2] or 0)
    if locked_until > now:
        raise AuthError("rate_limited", "잠시 후 다시 시도하세요.", 429,
                        max(1, math.ceil(locked_until - now)))
    if now - float(row[0]) >= ATTEMPT_WINDOW_SECONDS:
        conn.execute("DELETE FROM auth_attempts WHERE username=? AND kind=?", (username, kind))

def _record_failure(self, conn, username, kind):
    now = self.clock()
    row = conn.execute(
        "SELECT window_started_at, failure_count FROM auth_attempts "
        "WHERE username=? AND kind=?",
        (username, kind),
    ).fetchone()
    if row is None or now - float(row[0]) >= ATTEMPT_WINDOW_SECONDS:
        window_started_at, failure_count = now, 1
    else:
        window_started_at, failure_count = float(row[0]), int(row[1]) + 1
    locked_until = now + LOCK_SECONDS if failure_count >= ATTEMPT_LIMIT else None
    conn.execute(
        "INSERT INTO auth_attempts(username, kind, window_started_at, failure_count, locked_until) "
        "VALUES(?, ?, ?, ?, ?) ON CONFLICT(username, kind) DO UPDATE SET "
        "window_started_at=excluded.window_started_at, failure_count=excluded.failure_count, "
        "locked_until=excluded.locked_until",
        (username, kind, window_started_at, failure_count, locked_until),
    )
```

Unknown-user login must still execute one PBKDF2 derivation against a process-local dummy record before returning `invalid_credentials`, preventing an obvious timing oracle. Successful login or claim deletes the matching `(username, kind)` attempt row. On successful login, if the stored algorithm or iteration count is weaker than the active policy, 자동 재해시를 수행해 새 record를 같은 transaction에서 저장한 뒤 반환한다.

- [x] **Step 4: Run account tests and verify GREEN**

Run: `bash plugin/tests/test-auth-store.sh`

Expected: all schema, state, audit and lockout assertions pass.

- [x] **Step 5: Commit account lifecycle**

```bash
git add plugin/scripts/marina_auth.py plugin/tests/test-auth-store.sh
git commit -m "feat(auth): add account approval lifecycle"
```

### Task 3: Session Issuance, Expiry, And Revocation

**Files:**
- Modify: `plugin/scripts/marina_auth.py`
- Modify: `plugin/tests/test-auth-store.sh`

**Interfaces:**
- Produces: `IssuedSession(user: User, token: str, csrf_token: str, idle_expires_at: float, absolute_expires_at: float)`
- Produces: `SessionPrincipal(user: User, session_id: int, csrf_hash: bytes)`
- Produces: `create_session(user_id: int) -> IssuedSession`
- Produces: `resolve_session(token: str, touch: bool = True) -> SessionPrincipal | None`
- Produces: `verify_csrf(principal: SessionPrincipal, supplied: str) -> bool`
- Produces: `logout(token: str) -> bool`, `revoke_user_sessions(user_id: int) -> int`, `revoke_all_sessions() -> int`

- [x] **Step 1: Add failing session tests**

Append assertions for raw-token secrecy, inactivity expiry, absolute expiry, touch throttling, CSRF mismatch and revocation:

```python
session = accounts.create_session(admin.id)
assert len(session.token) >= 43 and len(session.csrf_token) >= 43
raw_db = (Path(sys.argv[1]) / "accounts.db").read_bytes()
assert session.token.encode() not in raw_db and session.csrf_token.encode() not in raw_db
principal = accounts.resolve_session(session.token)
assert principal and principal.user.username == "owner"
assert accounts.verify_csrf(principal, session.csrf_token)
assert not accounts.verify_csrf(principal, "wrong")
assert accounts.logout(session.token)
assert accounts.resolve_session(session.token) is None

idle = accounts.create_session(admin.id)
now[0] += 30 * 24 * 60 * 60 + 1
assert accounts.resolve_session(idle.token) is None
```

Create a fresh store/clock for the 90-day absolute-expiry assertion so idle expiry does not mask it. Verify `disable_user` and `reset_password` revoke all of that user's sessions.

- [x] **Step 2: Run session tests and verify RED**

Run: `bash plugin/tests/test-auth-store.sh`

Expected: FAIL because `create_session` does not exist.

- [x] **Step 3: Implement hashed sessions**

Use exact expiry constants and SHA-256 token hashes:

```python
SESSION_IDLE_SECONDS = 30 * 24 * 60 * 60
SESSION_ABSOLUTE_SECONDS = 90 * 24 * 60 * 60
SESSION_TOUCH_SECONDS = 5 * 60

@staticmethod
def _token_hash(value: str) -> bytes:
    return hashlib.sha256(value.encode("ascii")).digest()
```

Generate both raw values with `secrets.token_urlsafe(32)`. `resolve_session` joins `users`, rejects non-active users, deletes expired rows, and only writes `last_used_at`/`idle_expires_at` when five minutes have elapsed since the previous touch.

- [x] **Step 4: Run store tests and verify GREEN**

Run: `bash plugin/tests/test-auth-store.sh`

Expected: `PASS test-auth-store` with no raw token found in either DB file.

- [x] **Step 5: Commit sessions**

```bash
git add plugin/scripts/marina_auth.py plugin/tests/test-auth-store.sh
git commit -m "feat(auth): add revocable login sessions"
```

### Task 4: HTTP Auth Controller And Central Handler Guard

**Files:**
- Create: `plugin/scripts/marina_auth_http.py`
- Modify: `plugin/scripts/marina_handler.py`
- Modify: `plugin/scripts/marina-control.py`
- Create: `plugin/tests/test-auth-http.sh`

**Interfaces:**
- Consumes: all `AuthStore` account/session interfaces.
- Produces: `AUTH_DENIED` sentinel.
- Produces: `auth_controller() -> AuthHTTPController` keyed by current `MARINA_AUTH_DB`.
- Produces: `AuthHTTPController.dispatch(handler, method: str, parsed: ParseResult) -> bool`.
- Produces: `AuthHTTPController.authorize(handler, method: str, parsed: ParseResult) -> SessionPrincipal | None | AUTH_DENIED`.
- Produces: `AuthHTTPController.add_security_headers(handler, https: bool = False) -> None`.
- Handler sets `self.auth_principal` to `SessionPrincipal | None` before existing routes.

- [x] **Step 1: Write a failing real-server HTTP test**

Start `ThreadingHTTPServer(("127.0.0.1", 0), Handler)` with isolated `MARINA_HOME` and cover this sequence with `http.client.HTTPConnection` so cookies and headers are inspected without curl parsing:

```python
status, headers, body = request("GET", "/api/auth/status")
assert status == 200 and body["enabled"] is False and body["bootstrapAllowed"] is True
status, headers, body = request("POST", "/api/auth/bootstrap", {"username":"owner", "displayName":"Owner", "password":"owner-password"})
assert status == 201
assert "HttpOnly" in headers["set-cookie"] and "SameSite=Lax" in headers["set-cookie"]
status, _, body = request("GET", "/api/worktrees")
assert status == 401 and body["error"] == "authentication_required"
status, headers, body = request("POST", "/api/auth/login", {"username":"owner", "password":"owner-password"})
assert status == 200 and body["user"]["role"] == "admin"
status, _, _ = request("POST", "/api/stop-all", {}, cookies=headers.get_all("set-cookie"))
assert status == 403  # session cookie without X-Marina-CSRF
```

Also assert non-loopback bootstrap rejection by unit-testing `is_loopback_client`, unauthenticated `/` and `/mobile` redirect to `/login?next=%2Fmobile`, public `/api/health`, no-store auth responses, CSP/frame/nosniff/referrer/HSTS headers, invalid Origin rejection, cookie deletion on logout, and a simulated migration failure returning 503 rather than bypassing auth.

- [x] **Step 2: Run HTTP tests and verify RED**

Run: `bash plugin/tests/test-auth-http.sh`

Expected: FAIL because `/api/auth/status` returns 404.

- [x] **Step 3: Implement auth routing and guard**

`dispatch` handles exactly:

```text
GET  /api/health
GET  /api/auth/status
GET  /api/auth/users
POST /api/auth/bootstrap
POST /api/auth/claim
POST /api/auth/login
POST /api/auth/logout
POST /api/auth/users/add
POST /api/auth/users/approve
POST /api/auth/users/reject
POST /api/auth/users/disable
POST /api/auth/users/reset-password
POST /api/auth/sessions/revoke-all
```

Return JSON errors as `{error: code, message, retryAfter?}`. Only status/bootstrap/claim/login and health are public; user-list and all user mutations require an active admin. `authorize` behaves as follows:

```python
PUBLIC_PATHS = {"/login", "/api/health", "/api/auth/status", "/api/auth/bootstrap", "/api/auth/claim", "/api/auth/login"}
PUBLIC_PREFIXES = ("/web/",)

if not store.auth_enabled():
    return None
if parsed.path in PUBLIC_PATHS or parsed.path.startswith(PUBLIC_PREFIXES):
    return None
principal = store.resolve_session(session_cookie)
if principal is None:
    redirect HTML GETs to "/login?next=" + quote(current_path)
    otherwise send JSON 401 authentication_required
    return AUTH_DENIED
if method not in ("GET", "HEAD", "OPTIONS"):
    require allowed Origin and matching X-Marina-CSRF
return principal
```

Parse cookies with `http.cookies.SimpleCookie`. Set two separate `Set-Cookie` headers, omit `Domain`, use `Path=/; SameSite=Lax`; add `HttpOnly` only to `marina_session`; add `Secure` only when the direct connection is TLS or a loopback peer supplied `X-Forwarded-Proto: https`.

- [x] **Step 4: Wire one guard at each Handler entry**

At the start of both `do_GET` and `do_POST`, before mobile token checks or other API routes:

```python
controller = auth_controller()
if controller.dispatch(self, "GET", parsed):
    return
principal = controller.authorize(self, "GET", parsed)
if principal is AUTH_DENIED:
    return
self.auth_principal = principal
```

Use `"POST"` in `do_POST`. Serve `login.html` from `/login`, and make `send_json`, index/mobile HTML, static assets, downloads and log streams call the common security-header helper before `end_headers()`.

- [x] **Step 5: Run HTTP and existing Host/Origin tests**

Run:

```bash
bash plugin/tests/test-auth-http.sh
bash plugin/tests/test-host-guard.sh
bash plugin/tests/test-term.sh
```

Expected: all three print `PASS`; auth-disabled fixtures retain old behavior.

- [x] **Step 6: Commit the HTTP boundary**

```bash
git add plugin/scripts/marina_auth_http.py plugin/scripts/marina_handler.py plugin/scripts/marina-control.py plugin/tests/test-auth-http.sh
git commit -m "feat(auth): guard dashboard APIs with sessions"
```

### Task 5: Shared Login, Claim, And Bootstrap UI

**Files:**
- Create: `plugin/scripts/marina-web/login.html`
- Create: `plugin/scripts/marina-web/auth-login.js`
- Create: `plugin/scripts/marina-web/auth.css`
- Create: `plugin/scripts/marina-web/app-0-auth.js`
- Modify: `plugin/scripts/marina-web/index.html`
- Create: `plugin/tests/test-auth-ui.sh`

**Interfaces:**
- Consumes: `/api/auth/status`, `/bootstrap`, `/claim`, `/login`, `/logout`.
- Produces: `window.marinaAuth = {user, enabled, refresh(), logout()}`.
- Produces: same-origin unsafe `fetch` calls include `X-Marina-CSRF` from `marina_csrf` cookie.

- [x] **Step 1: Write failing static UI contracts**

Create `test-auth-ui.sh` to assert login modes, accessible labels, no feature-explainer copy inside the app, and script order:

```bash
grep -q 'id="authLoginForm"' "$WEB/login.html"
grep -q 'id="authBootstrapForm"' "$WEB/login.html"
grep -q 'id="authClaimForm"' "$WEB/login.html"
grep -q 'id="authPending"' "$WEB/login.html"
grep -q 'src="/web/app-0-auth.js"' "$WEB/index.html"
test "$(grep -n 'app-0-auth.js' "$WEB/index.html" | cut -d: -f1)" -lt "$(grep -n 'app-1-core.js' "$WEB/index.html" | cut -d: -f1)"
node --check "$WEB/auth-login.js"
node --check "$WEB/app-0-auth.js"
```

Extract `app-0-auth.js` into a Node VM with fake `document.cookie` and `fetch`; assert POST receives `X-Marina-CSRF`, GET does not, and a 401 navigates to `/login?next=%2F`.

- [x] **Step 2: Run UI tests and verify RED**

Run: `bash plugin/tests/test-auth-ui.sh`

Expected: FAIL because `login.html` does not exist.

- [x] **Step 3: Implement the shared login state machine**

`auth-login.js` first calls status and selects one mode:

```javascript
if (!state.enabled && state.bootstrapAllowed) show('bootstrap');
else if (state.user) location.replace(safeNext());
else show('login');
```

On login error `unclaimed`, preserve the username and show claim form. On `pending_approval`, show the pending panel without polling project APIs. Only allow `next` values beginning with one `/` and not `//`; default to `/`, preserving `/mobile` for phone users.

The page uses a compact centered form on desktop and full-width form on narrow screens. It contains no invitation-code, email, QR, or temporary-password controls.

- [x] **Step 4: Implement authenticated app fetch bootstrap**

`app-0-auth.js` wraps same-origin `window.fetch` before any existing app module loads:

```javascript
const nativeFetch = window.fetch.bind(window);
window.fetch = async (input, init = {}) => {
  const url = new URL(typeof input === 'string' ? input : input.url, location.href);
  const method = String(init.method || (typeof input !== 'string' && input.method) || 'GET').toUpperCase();
  const options = Object.assign({}, init);
  if (url.origin === location.origin && !['GET','HEAD','OPTIONS'].includes(method)) {
    const headers = new Headers(init.headers || (typeof input !== 'string' ? input.headers : undefined));
    const csrf = cookieValue('marina_csrf');
    if (csrf) headers.set('X-Marina-CSRF', csrf);
    options.headers = headers;
  }
  const response = await nativeFetch(input, options);
  if (response.status === 401) location.assign(`/login?next=${encodeURIComponent(location.pathname + location.search)}`);
  return response;
};
```

Do not send the CSRF token cross-origin. Load this file before `app-1-core.js`.

- [x] **Step 5: Run UI and HTTP tests**

Run:

```bash
bash plugin/tests/test-auth-ui.sh
bash plugin/tests/test-auth-http.sh
```

Expected: both print `PASS`.

- [x] **Step 6: Commit login UI**

```bash
git add plugin/scripts/marina-web/login.html plugin/scripts/marina-web/auth-login.js plugin/scripts/marina-web/auth.css plugin/scripts/marina-web/app-0-auth.js plugin/scripts/marina-web/index.html plugin/tests/test-auth-ui.sh
git commit -m "feat(auth): add shared Marina login"
```

### Task 6: Admin User Management In Settings

**Files:**
- Create: `plugin/scripts/marina-web/app-6c-users.js`
- Modify: `plugin/scripts/marina-web/index.html`
- Modify: `plugin/scripts/marina-web/styles.css`
- Modify: `plugin/tests/test-auth-ui.sh`

**Interfaces:**
- Consumes: `window.marinaAuth`, `/api/auth/users`, `/api/auth/users/*`.
- Produces: settings action `#userManagementBtn`, dialog `#userManagementDialog`, action `#revokeAllSessionsBtn`.

- [x] **Step 1: Add failing management UI contracts**

Assert the settings menu has icon+text actions for account/logout and an admin-only user manager; assert the dialog contains add, approve, reject, disable and reset controls rendered from server data, not hard-coded rows:

```bash
grep -q 'id="userManagementBtn"' "$WEB/index.html"
grep -q 'id="accountLogoutBtn"' "$WEB/index.html"
grep -q 'id="userManagementDialog"' "$WEB/index.html"
grep -q 'id="revokeAllSessionsBtn"' "$WEB/index.html"
grep -q 'renderAuthUsers' "$WEB/app-6c-users.js"
grep -q '/api/auth/users/approve' "$WEB/app-6c-users.js"
node --check "$WEB/app-6c-users.js"
```

- [x] **Step 2: Run UI tests and verify RED**

Run: `bash plugin/tests/test-auth-ui.sh`

Expected: FAIL on missing `userManagementBtn`.

- [x] **Step 3: Implement the settings dialog**

Add settings rows below notifications for `사용자 관리` (admin only) and `로그아웃`. The admin dialog includes `모든 세션 로그아웃`; after confirmation it calls `/api/auth/sessions/revoke-all`, clears the current cookies through the response, and redirects the administrator to login. The dialog lists username, display name, role and status in a scan-friendly table; pending rows expose approve/reject; active non-final-admin rows expose disable; unclaimed/pending/active rows expose reset as allowed by API. The create form accepts username, display name and an admin/member select, with member selected by default.

Use stable data attributes for delegated actions and keep rendering text escaped:

```javascript
async function authMutation(path, body) {
  return api(path, {
    method: 'POST',
    headers: {'content-type': 'application/json'},
    body: JSON.stringify(body || {})
  });
}

function renderAuthUsers(users) {
  const tbody = document.querySelector('#userManagementDialog tbody');
  tbody.innerHTML = users.map(user => `<tr>
    <td><b>${escapeHtml(user.username)}</b><small>${escapeHtml(user.displayName)}</small></td>
    <td>${escapeHtml(user.role)}</td>
    <td>${escapeHtml(user.status)}</td>
    <td class="auth-user-actions">
      ${user.status === 'pending_approval' ? `<button data-auth-action="approve" data-username="${escapeHtml(user.username)}">승인</button><button data-auth-action="reject" data-username="${escapeHtml(user.username)}">거절</button>` : ''}
      ${user.canDisable ? `<button data-auth-action="disable" data-username="${escapeHtml(user.username)}">비활성화</button>` : ''}
      ${user.canResetPassword ? `<button data-auth-action="reset-password" data-username="${escapeHtml(user.username)}">비밀번호 초기화</button>` : ''}
    </td>
  </tr>`).join('');
}

document.getElementById('revokeAllSessionsBtn').onclick = async () => {
  if (!confirm('모든 기기에서 로그아웃할까요?')) return;
  await authMutation('/api/auth/sessions/revoke-all');
  location.replace('/login');
};
```

The server supplies `canDisable` and `canResetPassword`, so the client does not reconstruct last-admin policy. The delegated click handler maps each allowed action to `/api/auth/users/${action}` with `{username}` and then reloads `GET /api/auth/users`.

All destructive actions use the existing inline confirmation style and refresh only the auth user list. Do not reload worktrees or add project assignment controls in this phase.

- [x] **Step 4: Run UI and HTTP tests**

Run:

```bash
bash plugin/tests/test-auth-ui.sh
bash plugin/tests/test-auth-http.sh
```

Expected: PASS, including admin-only 403 assertions for a member session.

- [x] **Step 5: Commit user management UI**

```bash
git add plugin/scripts/marina-web/app-6c-users.js plugin/scripts/marina-web/index.html plugin/scripts/marina-web/styles.css plugin/tests/test-auth-ui.sh
git commit -m "feat(auth): add dashboard user administration"
```

### Task 7: Mobile Compatibility And Local Recovery CLI

**Files:**
- Create: `plugin/scripts/marina_auth_cli.py`
- Modify: `plugin/scripts/marina-entrypoint.sh`
- Modify: `plugin/scripts/marina_mobile.py`
- Modify: `plugin/tests/test-mobile-control.sh`
- Create: `plugin/tests/test-auth-cli.sh`

**Interfaces:**
- Consumes: `AuthStore` and Handler `self.auth_principal`.
- Produces: `marina auth status|reset-admin|disable`.
- Produces: `marina user list|add|approve|reject|disable|reset-password`.
- Mobile token is accepted only when `AuthStore.auth_enabled()` is false.
- Produces: `render_mobile_html(auth_enabled: bool = False) -> str` so cookie-authenticated pages skip the legacy token prompt.

- [x] **Step 1: Add failing CLI and mobile-mode tests**

In `test-auth-cli.sh`, use isolated `MARINA_HOME` and the real entrypoint:

```bash
MARINA_HOME="$TMP/home" "$ENTRY" auth status | grep -q 'enabled=false'
MARINA_HOME="$TMP/home" "$ENTRY" user add teammate --name 'Team Mate' | grep -q 'teammate'
MARINA_HOME="$TMP/home" "$ENTRY" user list | grep -q $'teammate\tmember\tunclaimed'
MARINA_HOME="$TMP/home" "$ENTRY" user approve teammate >/dev/null && { echo 'approve unexpectedly succeeded before claim'; exit 1; } || true
```

Bootstrap an admin through Python, claim the teammate, then verify CLI approve, disable, reset-password, reset-admin, and `auth disable --yes`. `auth reset-admin <username> --password-stdin` reads one password line from stdin, replaces the password hash, keeps that administrator active, and revokes every session. Without `--password-stdin`, it prompts twice with `getpass.getpass`; it never accepts a password argument. `auth disable` must revoke sessions, remove `auth_enabled_at`, set users to `unclaimed`, and clear password records while preserving users and audit data; without `--yes` it exits 2.

Extend `test-mobile-control.sh` with two servers:

```text
auth disabled + valid X-Marina-Mobile-Token => 200
auth enabled + valid old mobile token without session => 401
auth enabled + session cookie => 200 without X-Marina-Mobile-Token
```

- [x] **Step 2: Run tests and verify RED**

Run:

```bash
bash plugin/tests/test-auth-cli.sh
bash plugin/tests/test-mobile-control.sh
```

Expected: CLI reports unknown command and authenticated mobile request still requires the legacy token.

- [x] **Step 3: Implement CLI dispatch and recovery**

Add `AUTH_CLI="$SCRIPT_DIR/marina_auth_cli.py"` and route both command groups:

```bash
auth|user)
  exec "${MARINA_PYTHON:-$(command -v python3 || echo /usr/bin/python3)}" "$AUTH_CLI" "$command" "$@"
  ;;
```

Use `argparse` subparsers in `marina_auth_cli.py`. Print stable tab-separated rows for `user list`, JSON-free key/value lines for `auth status`, messages to stderr, and nonzero exits for invalid state. Never accept a password as a command-line argument. `user reset-password` returns an account to `unclaimed`; `auth reset-admin` is the local lockout recovery path and immediately installs the interactively supplied password on the active administrator.

- [x] **Step 4: Switch mobile authorization by auth state**

At each mobile route, use this exact decision:

```python
if self.auth_principal is None and not mobile_request_ok(self, parsed):
    self.send_json({"error": "mobile disabled or invalid token"}, 403)
    return
```

Because the central guard denies unauthenticated requests when auth is enabled, `auth_principal is None` here means legacy auth-disabled mode. Remove token-login instructional UI when auth is enabled by rendering `/mobile` only after the cookie guard; unauthenticated users are redirected to the shared `/login?next=/mobile` page.

- [x] **Step 5: Run focused and full regression tests**

Run:

```bash
bash plugin/tests/test-auth-store.sh
bash plugin/tests/test-auth-http.sh
bash plugin/tests/test-auth-ui.sh
bash plugin/tests/test-auth-cli.sh
bash plugin/tests/test-mobile-control.sh
bash plugin/tests/test-dashboard-launch.sh
bash plugin/tests/test-entrypoint-routing.sh
bash plugin/tests/test-install-cli.sh
```

Expected: every script prints `PASS`; no test writes to the real `~/.marina`.

- [x] **Step 6: Commit mobile and recovery integration**

```bash
git add plugin/scripts/marina_auth_cli.py plugin/scripts/marina-entrypoint.sh plugin/scripts/marina_mobile.py plugin/tests/test-mobile-control.sh plugin/tests/test-auth-cli.sh
git commit -m "feat(auth): integrate mobile login and recovery CLI"
```

### Task 8: Browser Verification And Phase-A Documentation

**Files:**
- Modify: `README.md`
- Modify: `docs/superpowers/specs/2026-07-20-remote-auth-funnel-design.md`

**Interfaces:**
- Consumes: completed auth foundation.
- Produces: documented activation/recovery flow and verified desktop/mobile UX.

- [x] **Step 1: Document the activation boundary**

Add a concise README section with these commands and facts:

```text
marina auth status
marina user add <username> --name <display-name>
marina user list
marina auth reset-admin <username>
```

State that existing localhost behavior remains unchanged until the first admin is initialized; after initialization all desktop/mobile access requires login; `auth disable --yes` is a local emergency operation; this phase does not provide OS-user/filesystem isolation or public Funnel access.

- [x] **Step 2: Run all auth and smoke tests from a clean temporary home**

Run the eight commands from Task 7 Step 5, then run `git diff --check`.

Expected: all PASS and no whitespace errors.

- [x] **Step 3: Verify the real UI with Aside**

Start a dashboard with temporary `MARINA_HOME`, `MARINA_CONTROL_HOST=127.0.0.1`, and a free port. In Aside, verify at desktop 1440x900 and mobile 390x844:

```text
bootstrap admin -> authenticated dashboard
logout -> login -> dashboard
admin adds user -> user claims -> pending screen
admin approves -> member login
direct /mobile unauthenticated -> shared login -> returns to /mobile
wrong password five times -> visible locked state without layout overlap
```

Inspect the DOM with `snapshot(page, {interactive: true})`, and capture screenshots only for layout review. Confirm focus order, input labels, error placement, dialog scrolling and that the desktop app never flashes worktree data before authentication.

- [x] **Step 4: Update spec status and commit the completed phase**

Change the spec status to record Phase A implementation and its verification date, then commit docs:

```bash
git add README.md docs/superpowers/specs/2026-07-20-remote-auth-funnel-design.md
git commit -m "docs(auth): document local account activation"
```

---

## Follow-On Plans

After this plan ships, write and execute independent plans in this order:

1. `remote-resource-ownership`: migrate existing resources to the initial admin, assign projects, filter every read API, and authorize every mutation.
2. `tailscale-serve-control`: remote settings state, Tailscale diagnostics, non-destructive Serve configuration, localhost bind transition, stable mobile address.
3. `tailscale-funnel-control`: readiness self-check, admin reauthentication, public status, rate-limit verification, non-destructive Funnel activation and shutdown.

Each follow-on plan must leave Marina working and independently releasable before the next begins.
