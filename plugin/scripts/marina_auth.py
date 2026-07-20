"""Local Marina accounts, sessions, and audit storage."""
from __future__ import annotations

import hashlib
import hmac
import math
import os
import re
import secrets
import sqlite3
import time
from contextlib import contextmanager
from dataclasses import dataclass
from pathlib import Path
from typing import Callable, Iterator


MARINA_HOME = Path(os.environ.get("MARINA_HOME", str(Path.home() / ".marina")))
AUTH_DB = Path(os.environ.get("MARINA_AUTH_DB", str(MARINA_HOME / "auth.db")))
SCHEMA_VERSION = 1
PBKDF2_ALGORITHM = "pbkdf2_sha256"
PBKDF2_ITERATIONS = 600_000
PASSWORD_SALT_BYTES = 16
PASSWORD_KEY_BYTES = 32
ATTEMPT_WINDOW_SECONDS = 15 * 60
ATTEMPT_LIMIT = 5
LOCK_SECONDS = 15 * 60
USERNAME_RE = re.compile(r"^[a-z0-9][a-z0-9._-]{2,31}$")
MIN_PASSWORD_LENGTH = 12
SESSION_IDLE_SECONDS = 30 * 24 * 60 * 60
SESSION_ABSOLUTE_SECONDS = 90 * 24 * 60 * 60
SESSION_TOUCH_SECONDS = 5 * 60


class AuthError(Exception):
    def __init__(self, code: str, message: str, status: int = 400, retry_after: int = 0):
        super().__init__(message)
        self.code = code
        self.message = message
        self.status = status
        self.retry_after = retry_after


@dataclass(frozen=True)
class User:
    id: int
    username: str
    display_name: str
    role: str
    status: str

    def to_dict(self) -> dict[str, object]:
        return {
            "id": self.id,
            "username": self.username,
            "displayName": self.display_name,
            "role": self.role,
            "status": self.status,
        }


@dataclass(frozen=True)
class IssuedSession:
    user: User
    token: str
    csrf_token: str
    idle_expires_at: float
    absolute_expires_at: float


@dataclass(frozen=True)
class SessionPrincipal:
    user: User
    session_id: int
    csrf_hash: bytes


MIGRATIONS = {
    1: """
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
INSERT INTO meta(key, value) VALUES('schema_version', '1');
PRAGMA user_version=1;
""",
}


class AuthStore:
    def __init__(
        self,
        db_path: Path | None = None,
        pbkdf2_iterations: int = PBKDF2_ITERATIONS,
        clock: Callable[[], float] = time.time,
    ):
        self.db_path = Path(db_path or AUTH_DB)
        self.pbkdf2_iterations = pbkdf2_iterations
        self.clock = clock
        self._dummy_record: tuple[str, int, bytes, bytes] | None = None

    def _connect(self) -> sqlite3.Connection:
        created_parent = not self.db_path.parent.exists()
        self.db_path.parent.mkdir(parents=True, exist_ok=True)
        if created_parent:
            try:
                self.db_path.parent.chmod(0o700)
            except OSError:
                pass
        conn = sqlite3.connect(self.db_path, timeout=5.0, isolation_level=None)
        try:
            self.db_path.chmod(0o600)
        except OSError:
            pass
        conn.row_factory = sqlite3.Row
        conn.execute("PRAGMA busy_timeout=5000")
        conn.execute("PRAGMA foreign_keys=ON")
        return conn

    def initialize(self) -> None:
        with self._connect() as conn:
            conn.execute("PRAGMA journal_mode=WAL")
            version = int(conn.execute("PRAGMA user_version").fetchone()[0])
            if version > SCHEMA_VERSION:
                raise AuthError("schema_too_new", "Auth database is newer than this Marina version.", 503)
            for target in range(version + 1, SCHEMA_VERSION + 1):
                script = MIGRATIONS[target]
                try:
                    conn.executescript("BEGIN IMMEDIATE;\n" + script + "\nCOMMIT;")
                except Exception:
                    try:
                        conn.execute("ROLLBACK")
                    except sqlite3.Error:
                        pass
                    raise

    @contextmanager
    def _transaction(self) -> Iterator[sqlite3.Connection]:
        conn = self._connect()
        conn.execute("BEGIN IMMEDIATE")
        try:
            yield conn
        except AuthError:
            conn.execute("COMMIT")
            raise
        except Exception:
            conn.execute("ROLLBACK")
            raise
        else:
            conn.execute("COMMIT")
        finally:
            conn.close()

    def auth_enabled(self) -> bool:
        self.initialize()
        with self._connect() as conn:
            row = conn.execute("SELECT value FROM meta WHERE key='auth_enabled_at'").fetchone()
            return row is not None and bool(str(row[0]).strip())

    def password_record(self, password: str) -> tuple[str, int, bytes, bytes]:
        salt = secrets.token_bytes(PASSWORD_SALT_BYTES)
        key = hashlib.pbkdf2_hmac(
            "sha256",
            password.encode("utf-8"),
            salt,
            self.pbkdf2_iterations,
            dklen=PASSWORD_KEY_BYTES,
        )
        return PBKDF2_ALGORITHM, self.pbkdf2_iterations, salt, key

    def verify_password(
        self,
        password: str,
        algorithm: str,
        iterations: int,
        salt: bytes,
        expected: bytes,
    ) -> bool:
        if algorithm != PBKDF2_ALGORITHM:
            return False
        actual = hashlib.pbkdf2_hmac(
            "sha256",
            password.encode("utf-8"),
            salt,
            int(iterations),
            dklen=len(expected),
        )
        return hmac.compare_digest(actual, expected)

    @staticmethod
    def _user(row: sqlite3.Row) -> User:
        return User(
            id=int(row["id"]),
            username=str(row["username"]),
            display_name=str(row["display_name"]),
            role=str(row["role"]),
            status=str(row["status"]),
        )

    @staticmethod
    def _username(value: str) -> str:
        username = str(value or "").strip().lower()
        if not USERNAME_RE.fullmatch(username):
            raise AuthError(
                "invalid_username",
                "Username must be 3-32 lowercase letters, numbers, dots, dashes, or underscores.",
            )
        return username

    @staticmethod
    def _display_name(value: str) -> str:
        display_name = str(value or "").strip()
        if not display_name or len(display_name) > 80:
            raise AuthError("invalid_display_name", "Display name must be 1-80 characters.")
        return display_name

    @staticmethod
    def _role(value: str) -> str:
        role = str(value or "member").strip().lower()
        if role not in ("admin", "member"):
            raise AuthError("invalid_role", "Role must be admin or member.")
        return role

    @staticmethod
    def _password(value: str) -> str:
        password = str(value or "")
        if len(password) < MIN_PASSWORD_LENGTH:
            raise AuthError("weak_password", "Password must be at least 12 characters.")
        return password

    def _audit(
        self,
        conn: sqlite3.Connection,
        action: str,
        result: str,
        actor_user_id: int | None = None,
        resource_type: str | None = None,
        resource_key: str | None = None,
        request_meta: str | None = None,
    ) -> None:
        conn.execute(
            "INSERT INTO audit_events(actor_user_id, action, resource_type, resource_key, result, created_at, request_meta) "
            "VALUES(?, ?, ?, ?, ?, ?, ?)",
            (actor_user_id, action, resource_type, resource_key, result, self.clock(), request_meta),
        )

    def _check_attempt_lock(self, conn: sqlite3.Connection, username: str, kind: str) -> None:
        now = self.clock()
        row = conn.execute(
            "SELECT window_started_at, failure_count, locked_until "
            "FROM auth_attempts WHERE username=? AND kind=?",
            (username, kind),
        ).fetchone()
        if row is None:
            return
        locked_until = float(row["locked_until"] or 0)
        if locked_until > now:
            raise AuthError(
                "rate_limited",
                "Please wait before trying again.",
                429,
                max(1, math.ceil(locked_until - now)),
            )
        if now - float(row["window_started_at"]) >= ATTEMPT_WINDOW_SECONDS:
            conn.execute("DELETE FROM auth_attempts WHERE username=? AND kind=?", (username, kind))

    def _record_failure(self, conn: sqlite3.Connection, username: str, kind: str) -> int | None:
        now = self.clock()
        row = conn.execute(
            "SELECT window_started_at, failure_count FROM auth_attempts WHERE username=? AND kind=?",
            (username, kind),
        ).fetchone()
        if row is None or now - float(row["window_started_at"]) >= ATTEMPT_WINDOW_SECONDS:
            window_started_at, failure_count = now, 1
        else:
            window_started_at = float(row["window_started_at"])
            failure_count = int(row["failure_count"]) + 1
        locked_until = now + LOCK_SECONDS if failure_count >= ATTEMPT_LIMIT else None
        conn.execute(
            "INSERT INTO auth_attempts(username, kind, window_started_at, failure_count, locked_until) "
            "VALUES(?, ?, ?, ?, ?) ON CONFLICT(username, kind) DO UPDATE SET "
            "window_started_at=excluded.window_started_at, failure_count=excluded.failure_count, "
            "locked_until=excluded.locked_until",
            (username, kind, window_started_at, failure_count, locked_until),
        )
        if locked_until is None:
            return None
        return max(1, math.ceil(locked_until - now))

    def _raise_claim_failure(
        self,
        conn: sqlite3.Connection,
        username: str,
        code: str,
        message: str,
        status: int,
        result: str,
        actor_user_id: int | None = None,
    ) -> None:
        retry_after = self._record_failure(conn, username, "claim")
        self._audit(
            conn,
            "auth.claim",
            "locked" if retry_after is not None else result,
            actor_user_id,
            "user",
            username,
        )
        if retry_after is not None:
            raise AuthError(
                "rate_limited", "Please wait before trying again.", 429, retry_after
            )
        raise AuthError(code, message, status)

    def _claimable_user(self, conn: sqlite3.Connection, username: str) -> sqlite3.Row:
        row = conn.execute("SELECT * FROM users WHERE username=?", (username,)).fetchone()
        if row is None:
            self._raise_claim_failure(
                conn,
                username,
                "unknown_user",
                "This username was not registered.",
                404,
                "unknown",
            )
        failures = {
            "pending_approval": (
                "pending_approval",
                "This account is waiting for administrator approval.",
                403,
            ),
            "disabled": ("account_disabled", "This account is disabled.", 403),
            "active": ("already_claimed", "This account already has a password.", 409),
        }
        failure = failures.get(str(row["status"]))
        if failure is not None:
            code, message, status = failure
            self._raise_claim_failure(
                conn,
                username,
                code,
                message,
                status,
                code,
                int(row["id"]),
            )
        if row["status"] != "unclaimed":
            self._raise_claim_failure(
                conn,
                username,
                "already_claimed",
                "This account already has a password.",
                409,
                "already_claimed",
                int(row["id"]),
            )
        return row

    @staticmethod
    def _clear_attempts(conn: sqlite3.Connection, username: str, kind: str | None = None) -> None:
        if kind:
            conn.execute("DELETE FROM auth_attempts WHERE username=? AND kind=?", (username, kind))
        else:
            conn.execute("DELETE FROM auth_attempts WHERE username=?", (username,))

    def _dummy_verify(self, password: str) -> None:
        if self._dummy_record is None:
            self._dummy_record = self.password_record("marina-dummy-password")
        self.verify_password(password, *self._dummy_record)

    def bootstrap_admin(self, username: str, display_name: str, password: str) -> User:
        self.initialize()
        username = self._username(username)
        display_name = self._display_name(display_name)
        password = self._password(password)
        algorithm, iterations, salt, password_hash = self.password_record(password)
        now = self.clock()
        with self._transaction() as conn:
            if conn.execute("SELECT 1 FROM meta WHERE key='auth_enabled_at'").fetchone():
                raise AuthError("already_initialized", "Authentication is already initialized.", 409)
            row = conn.execute("SELECT * FROM users WHERE username=?", (username,)).fetchone()
            if row is not None and row["status"] != "unclaimed":
                raise AuthError("username_exists", "Username is already in use.", 409)
            if row is None:
                cursor = conn.execute(
                    "INSERT INTO users(username, display_name, role, status, password_algorithm, "
                    "password_iterations, password_salt, password_hash, approved_at, created_at, updated_at) "
                    "VALUES(?, ?, 'admin', 'active', ?, ?, ?, ?, ?, ?, ?)",
                    (username, display_name, algorithm, iterations, salt, password_hash, now, now, now),
                )
                user_id = int(cursor.lastrowid)
            else:
                user_id = int(row["id"])
                conn.execute(
                    "UPDATE users SET display_name=?, role='admin', status='active', password_algorithm=?, "
                    "password_iterations=?, password_salt=?, password_hash=?, approved_at=?, updated_at=? "
                    "WHERE id=?",
                    (display_name, algorithm, iterations, salt, password_hash, now, now, user_id),
                )
            conn.execute(
                "INSERT INTO meta(key, value) VALUES('auth_enabled_at', ?) "
                "ON CONFLICT(key) DO UPDATE SET value=excluded.value",
                (str(now),),
            )
            self._clear_attempts(conn, username)
            self._audit(conn, "auth.bootstrap", "ok", user_id, "user", username)
            user_row = conn.execute("SELECT * FROM users WHERE id=?", (user_id,)).fetchone()
            return self._user(user_row)

    def add_user(
        self,
        username: str,
        display_name: str,
        role: str = "member",
        actor_user_id: int | None = None,
    ) -> User:
        self.initialize()
        username = self._username(username)
        display_name = self._display_name(display_name)
        role = self._role(role)
        now = self.clock()
        with self._transaction() as conn:
            try:
                cursor = conn.execute(
                    "INSERT INTO users(username, display_name, role, status, created_at, updated_at) "
                    "VALUES(?, ?, ?, 'unclaimed', ?, ?)",
                    (username, display_name, role, now, now),
                )
            except sqlite3.IntegrityError as exc:
                raise AuthError("username_exists", "Username is already in use.", 409) from exc
            self._audit(conn, "user.add", "ok", actor_user_id, "user", username)
            row = conn.execute("SELECT * FROM users WHERE id=?", (cursor.lastrowid,)).fetchone()
            return self._user(row)

    def claim_user(self, username: str, password: str) -> User:
        self.initialize()
        username = self._username(username)
        password = str(password or "")
        with self._transaction() as conn:
            self._check_attempt_lock(conn, username, "claim")
            try:
                password = self._password(password)
            except AuthError as exc:
                self._raise_claim_failure(
                    conn, username, exc.code, exc.message, exc.status, "weak_password"
                )
            self._claimable_user(conn, username)
        algorithm, iterations, salt, password_hash = self.password_record(password)
        now = self.clock()
        with self._transaction() as conn:
            self._check_attempt_lock(conn, username, "claim")
            row = self._claimable_user(conn, username)
            conn.execute(
                "UPDATE users SET status='pending_approval', password_algorithm=?, password_iterations=?, "
                "password_salt=?, password_hash=?, approved_at=NULL, updated_at=? WHERE id=?",
                (algorithm, iterations, salt, password_hash, now, row["id"]),
            )
            self._clear_attempts(conn, username, "claim")
            self._audit(conn, "auth.claim", "pending", int(row["id"]), "user", username)
            return self._user(conn.execute("SELECT * FROM users WHERE id=?", (row["id"],)).fetchone())

    def approve_user(self, username: str, actor_user_id: int | None = None) -> User:
        return self._set_pending_user(username, approve=True, actor_user_id=actor_user_id)

    def reject_user(self, username: str, actor_user_id: int | None = None) -> User:
        return self._set_pending_user(username, approve=False, actor_user_id=actor_user_id)

    def _set_pending_user(
        self,
        username: str,
        approve: bool,
        actor_user_id: int | None = None,
    ) -> User:
        self.initialize()
        username = self._username(username)
        now = self.clock()
        with self._transaction() as conn:
            row = conn.execute("SELECT * FROM users WHERE username=?", (username,)).fetchone()
            if row is None:
                raise AuthError("unknown_user", "Unknown user.", 404)
            if row["status"] != "pending_approval":
                raise AuthError("invalid_state", "User is not waiting for approval.", 409)
            if approve:
                conn.execute(
                    "UPDATE users SET status='active', approved_at=?, updated_at=? WHERE id=?",
                    (now, now, row["id"]),
                )
                action, result = "user.approve", "active"
            else:
                conn.execute(
                    "UPDATE users SET status='unclaimed', password_algorithm=NULL, password_iterations=NULL, "
                    "password_salt=NULL, password_hash=NULL, approved_at=NULL, updated_at=? WHERE id=?",
                    (now, row["id"]),
                )
                self._clear_attempts(conn, username)
                action, result = "user.reject", "unclaimed"
            self._audit(conn, action, result, actor_user_id, "user", username)
            return self._user(conn.execute("SELECT * FROM users WHERE id=?", (row["id"],)).fetchone())

    def disable_user(self, username: str, actor_user_id: int | None = None) -> User:
        self.initialize()
        username = self._username(username)
        now = self.clock()
        with self._transaction() as conn:
            row = conn.execute("SELECT * FROM users WHERE username=?", (username,)).fetchone()
            if row is None:
                raise AuthError("unknown_user", "Unknown user.", 404)
            if row["role"] == "admin" and row["status"] == "active":
                count = int(conn.execute(
                    "SELECT count(*) FROM users WHERE role='admin' AND status='active'"
                ).fetchone()[0])
                if count <= 1:
                    raise AuthError("last_admin", "The final active administrator cannot be disabled.", 409)
            conn.execute("UPDATE users SET status='disabled', updated_at=? WHERE id=?", (now, row["id"]))
            conn.execute("DELETE FROM auth_sessions WHERE user_id=?", (row["id"],))
            self._audit(conn, "user.disable", "disabled", actor_user_id, "user", username)
            return self._user(conn.execute("SELECT * FROM users WHERE id=?", (row["id"],)).fetchone())

    def reset_password(self, username: str, actor_user_id: int | None = None) -> User:
        self.initialize()
        username = self._username(username)
        now = self.clock()
        with self._transaction() as conn:
            row = conn.execute("SELECT * FROM users WHERE username=?", (username,)).fetchone()
            if row is None:
                raise AuthError("unknown_user", "Unknown user.", 404)
            if row["role"] == "admin" and row["status"] == "active":
                count = int(conn.execute(
                    "SELECT count(*) FROM users WHERE role='admin' AND status='active'"
                ).fetchone()[0])
                if count <= 1:
                    raise AuthError(
                        "last_admin",
                        "Use the local reset-admin recovery command for the final administrator.",
                        409,
                    )
            conn.execute(
                "UPDATE users SET status='unclaimed', password_algorithm=NULL, password_iterations=NULL, "
                "password_salt=NULL, password_hash=NULL, approved_at=NULL, updated_at=? WHERE id=?",
                (now, row["id"]),
            )
            conn.execute("DELETE FROM auth_sessions WHERE user_id=?", (row["id"],))
            self._clear_attempts(conn, username)
            self._audit(conn, "user.reset_password", "unclaimed", actor_user_id, "user", username)
            return self._user(conn.execute("SELECT * FROM users WHERE id=?", (row["id"],)).fetchone())

    def authenticate(self, username: str, password: str) -> User:
        self.initialize()
        username = self._username(username)
        password = str(password or "")
        with self._transaction() as conn:
            self._check_attempt_lock(conn, username, "login")
            row = conn.execute("SELECT * FROM users WHERE username=?", (username,)).fetchone()
            if row is None or row["password_hash"] is None:
                self._dummy_verify(password)
                if row is not None and row["status"] == "unclaimed":
                    raise AuthError("unclaimed", "Set a password for this account first.", 403)
                retry_after = self._record_failure(conn, username, "login")
                self._audit(
                    conn,
                    "auth.login",
                    "locked" if retry_after is not None else "invalid",
                    None,
                    "user",
                    username,
                )
                if retry_after is not None:
                    raise AuthError(
                        "rate_limited", "Please wait before trying again.", 429, retry_after
                    )
                raise AuthError("invalid_credentials", "Invalid username or password.", 401)
            verified = self.verify_password(
                password,
                str(row["password_algorithm"]),
                int(row["password_iterations"]),
                bytes(row["password_salt"]),
                bytes(row["password_hash"]),
            )
            if not verified:
                retry_after = self._record_failure(conn, username, "login")
                self._audit(
                    conn,
                    "auth.login",
                    "locked" if retry_after is not None else "invalid",
                    int(row["id"]),
                    "user",
                    username,
                )
                if retry_after is not None:
                    raise AuthError(
                        "rate_limited", "Please wait before trying again.", 429, retry_after
                    )
                raise AuthError("invalid_credentials", "Invalid username or password.", 401)
            if row["status"] == "pending_approval":
                raise AuthError("pending_approval", "This account is waiting for administrator approval.", 403)
            if row["status"] == "disabled":
                raise AuthError("account_disabled", "This account is disabled.", 403)
            if row["status"] != "active":
                raise AuthError("unclaimed", "Set a password for this account first.", 403)
            self._clear_attempts(conn, username, "login")
            if (
                row["password_algorithm"] != PBKDF2_ALGORITHM
                or int(row["password_iterations"]) < self.pbkdf2_iterations
            ):
                algorithm, iterations, salt, password_hash = self.password_record(password)
                conn.execute(
                    "UPDATE users SET password_algorithm=?, password_iterations=?, password_salt=?, "
                    "password_hash=?, updated_at=? WHERE id=?",
                    (algorithm, iterations, salt, password_hash, self.clock(), row["id"]),
                )
            self._audit(conn, "auth.login", "ok", int(row["id"]), "user", username)
            return self._user(conn.execute("SELECT * FROM users WHERE id=?", (row["id"],)).fetchone())

    def list_users(self) -> list[User]:
        self.initialize()
        with self._connect() as conn:
            rows = conn.execute("SELECT * FROM users ORDER BY username COLLATE NOCASE").fetchall()
            return [self._user(row) for row in rows]

    @staticmethod
    def _token_hash(value: str) -> bytes:
        return hashlib.sha256(value.encode("ascii")).digest()

    def create_session(self, user_id: int) -> IssuedSession:
        self.initialize()
        now = self.clock()
        token = secrets.token_urlsafe(32)
        csrf_token = secrets.token_urlsafe(32)
        idle_expires_at = now + SESSION_IDLE_SECONDS
        absolute_expires_at = now + SESSION_ABSOLUTE_SECONDS
        with self._transaction() as conn:
            row = conn.execute("SELECT * FROM users WHERE id=?", (int(user_id),)).fetchone()
            if row is None:
                raise AuthError("unknown_user", "Unknown user.", 404)
            if row["status"] != "active":
                raise AuthError("account_inactive", "Only active users can create sessions.", 403)
            conn.execute(
                "INSERT INTO auth_sessions(user_id, token_hash, csrf_hash, created_at, last_used_at, "
                "idle_expires_at, absolute_expires_at) VALUES(?, ?, ?, ?, ?, ?, ?)",
                (
                    row["id"],
                    self._token_hash(token),
                    self._token_hash(csrf_token),
                    now,
                    now,
                    idle_expires_at,
                    absolute_expires_at,
                ),
            )
            self._audit(conn, "auth.session.create", "ok", int(row["id"]), "user", str(row["username"]))
            return IssuedSession(
                user=self._user(row),
                token=token,
                csrf_token=csrf_token,
                idle_expires_at=idle_expires_at,
                absolute_expires_at=absolute_expires_at,
            )

    def resolve_session(self, token: str, touch: bool = True) -> SessionPrincipal | None:
        self.initialize()
        if not token:
            return None
        try:
            token_hash = self._token_hash(token)
        except (UnicodeEncodeError, AttributeError):
            return None
        now = self.clock()
        with self._transaction() as conn:
            row = conn.execute(
                "SELECT s.id AS session_id, s.csrf_hash, s.last_used_at, s.idle_expires_at, "
                "s.absolute_expires_at, u.* FROM auth_sessions s "
                "JOIN users u ON u.id=s.user_id WHERE s.token_hash=?",
                (token_hash,),
            ).fetchone()
            if row is None:
                return None
            if (
                row["status"] != "active"
                or float(row["idle_expires_at"]) <= now
                or float(row["absolute_expires_at"]) <= now
            ):
                conn.execute("DELETE FROM auth_sessions WHERE id=?", (row["session_id"],))
                return None
            if touch and now - float(row["last_used_at"]) >= SESSION_TOUCH_SECONDS:
                next_idle = min(now + SESSION_IDLE_SECONDS, float(row["absolute_expires_at"]))
                conn.execute(
                    "UPDATE auth_sessions SET last_used_at=?, idle_expires_at=? WHERE id=?",
                    (now, next_idle, row["session_id"]),
                )
            return SessionPrincipal(
                user=self._user(row),
                session_id=int(row["session_id"]),
                csrf_hash=bytes(row["csrf_hash"]),
            )

    def verify_csrf(self, principal: SessionPrincipal, supplied: str) -> bool:
        if not supplied:
            return False
        try:
            supplied_hash = self._token_hash(supplied)
        except (UnicodeEncodeError, AttributeError):
            return False
        return hmac.compare_digest(supplied_hash, principal.csrf_hash)

    def logout(self, token: str, actor_user_id: int | None = None) -> bool:
        self.initialize()
        if not token:
            return False
        try:
            token_hash = self._token_hash(token)
        except (UnicodeEncodeError, AttributeError):
            return False
        with self._transaction() as conn:
            row = conn.execute(
                "SELECT id, user_id FROM auth_sessions WHERE token_hash=?", (token_hash,)
            ).fetchone()
            if row is None:
                return False
            conn.execute("DELETE FROM auth_sessions WHERE id=?", (row["id"],))
            session_user_id = int(row["user_id"])
            self._audit(
                conn,
                "auth.logout",
                "ok",
                actor_user_id if actor_user_id is not None else session_user_id,
                "user",
                str(session_user_id),
            )
            return True

    def revoke_user_sessions(self, user_id: int, actor_user_id: int | None = None) -> int:
        self.initialize()
        with self._transaction() as conn:
            cursor = conn.execute("DELETE FROM auth_sessions WHERE user_id=?", (int(user_id),))
            self._audit(
                conn,
                "auth.session.revoke_user",
                str(cursor.rowcount),
                actor_user_id,
                "user",
                str(user_id),
            )
            return int(cursor.rowcount)

    def revoke_all_sessions(self, actor_user_id: int | None = None) -> int:
        self.initialize()
        with self._transaction() as conn:
            cursor = conn.execute("DELETE FROM auth_sessions")
            self._audit(conn, "auth.session.revoke_all", str(cursor.rowcount), actor_user_id)
            return int(cursor.rowcount)

    def reset_admin_password(self, username: str, password: str) -> User:
        self.initialize()
        username = self._username(username)
        password = self._password(password)
        algorithm, iterations, salt, password_hash = self.password_record(password)
        now = self.clock()
        with self._transaction() as conn:
            row = conn.execute("SELECT * FROM users WHERE username=?", (username,)).fetchone()
            if row is None or row["role"] != "admin":
                raise AuthError("unknown_admin", "Unknown administrator.", 404)
            conn.execute(
                "UPDATE users SET status='active', password_algorithm=?, password_iterations=?, "
                "password_salt=?, password_hash=?, approved_at=?, updated_at=? WHERE id=?",
                (algorithm, iterations, salt, password_hash, now, now, row["id"]),
            )
            conn.execute("DELETE FROM auth_sessions")
            self._clear_attempts(conn, username)
            conn.execute(
                "INSERT INTO meta(key, value) VALUES('auth_enabled_at', ?) "
                "ON CONFLICT(key) DO UPDATE SET value=excluded.value",
                (str(now),),
            )
            self._audit(conn, "auth.reset_admin", "active", int(row["id"]), "user", username)
            return self._user(conn.execute("SELECT * FROM users WHERE id=?", (row["id"],)).fetchone())

    def disable_auth(self) -> None:
        self.initialize()
        now = self.clock()
        with self._transaction() as conn:
            conn.execute("DELETE FROM auth_sessions")
            conn.execute("DELETE FROM auth_attempts")
            conn.execute("DELETE FROM meta WHERE key='auth_enabled_at'")
            conn.execute(
                "UPDATE users SET status='unclaimed', password_algorithm=NULL, password_iterations=NULL, "
                "password_salt=NULL, password_hash=NULL, approved_at=NULL, updated_at=?",
                (now,),
            )
            self._audit(conn, "auth.disable", "ok")
