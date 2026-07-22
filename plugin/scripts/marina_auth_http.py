"""HTTP adapter for Marina's local account store."""
from __future__ import annotations

import ipaddress
import os
import ssl
import urllib.parse
from http.cookies import SimpleCookie
from pathlib import Path
from typing import Any

from marina_auth import AUTH_DB, PBKDF2_ITERATIONS, SESSION_ABSOLUTE_SECONDS, AuthError, AuthStore, SessionPrincipal


AUTH_DENIED = object()
SESSION_COOKIE = "marina_session"
CSRF_COOKIE = "marina_csrf"
PUBLIC_PATHS = {
    "/login",
    "/api/health",
    "/api/auth/status",
    "/api/auth/bootstrap",
    "/api/auth/claim",
    "/api/auth/login",
}
PUBLIC_PREFIXES = ("/web/",)
AUTH_API_PREFIX = "/api/auth/"


def is_loopback_client(handler: Any) -> bool:
    try:
        return ipaddress.ip_address(str(handler.client_address[0])).is_loopback
    except (ValueError, TypeError, IndexError, AttributeError):
        return False


class AuthHTTPController:
    def __init__(self, store: AuthStore):
        self.store = store

    @staticmethod
    def _cookies(handler: Any) -> SimpleCookie[str]:
        cookies: SimpleCookie[str] = SimpleCookie()
        try:
            cookies.load(handler.headers.get("cookie", ""))
        except Exception:
            return SimpleCookie()
        return cookies

    def _session_token(self, handler: Any) -> str:
        morsel = self._cookies(handler).get(SESSION_COOKIE)
        return morsel.value if morsel else ""

    def _principal(self, handler: Any) -> SessionPrincipal | None:
        return self.store.resolve_session(self._session_token(handler))

    @staticmethod
    def _origin_allowed(handler: Any) -> bool:
        origin = str(handler.headers.get("origin") or "").strip()
        if not origin:
            return True
        host = str(handler.headers.get("host") or "").strip().lower()
        try:
            parsed = urllib.parse.urlsplit(origin)
        except ValueError:
            return False
        return parsed.scheme in ("http", "https") and parsed.netloc.lower() == host

    @staticmethod
    def _is_https(handler: Any) -> bool:
        if isinstance(getattr(handler, "connection", None), ssl.SSLSocket):
            return True
        return is_loopback_client(handler) and str(handler.headers.get("x-forwarded-proto") or "").lower() == "https"

    def add_security_headers(self, handler: Any, https: bool | None = None) -> None:
        handler.send_header(
            "content-security-policy",
            "default-src 'self'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; "
            "img-src 'self' data:; connect-src 'self'; object-src 'none'; base-uri 'none'; frame-ancestors 'none'",
        )
        handler.send_header("x-frame-options", "DENY")
        handler.send_header("x-content-type-options", "nosniff")
        handler.send_header("referrer-policy", "no-referrer")
        if self._is_https(handler) if https is None else https:
            handler.send_header("strict-transport-security", "max-age=31536000")

    def _cookie_header(self, name: str, value: str, http_only: bool, delete: bool = False) -> str:
        cookie: SimpleCookie[str] = SimpleCookie()
        cookie[name] = value
        morsel = cookie[name]
        morsel["path"] = "/"
        morsel["samesite"] = "Lax"
        if http_only:
            morsel["httponly"] = True
        if delete:
            morsel["max-age"] = 0
        else:
            morsel["max-age"] = SESSION_ABSOLUTE_SECONDS
        return morsel.OutputString()

    def _session_headers(self, handler: Any, token: str, csrf_token: str) -> list[tuple[str, str]]:
        secure = self._is_https(handler)
        headers = [
            ("set-cookie", self._cookie_header(SESSION_COOKIE, token, True)),
            ("set-cookie", self._cookie_header(CSRF_COOKIE, csrf_token, False)),
        ]
        if secure:
            headers = [(name, value + "; Secure") for name, value in headers]
        return headers

    def _clear_cookie_headers(self, handler: Any) -> list[tuple[str, str]]:
        secure = self._is_https(handler)
        headers = [
            ("set-cookie", self._cookie_header(SESSION_COOKIE, "", True, delete=True)),
            ("set-cookie", self._cookie_header(CSRF_COOKIE, "", False, delete=True)),
        ]
        if secure:
            headers = [(name, value + "; Secure") for name, value in headers]
        return headers

    @staticmethod
    def _error_payload(exc: AuthError) -> dict[str, object]:
        payload: dict[str, object] = {"error": exc.code, "message": exc.message}
        if exc.retry_after:
            payload["retryAfter"] = exc.retry_after
        return payload

    def _send_auth_error(self, handler: Any, exc: AuthError) -> None:
        headers = [("retry-after", str(exc.retry_after))] if exc.retry_after else None
        handler.send_json(self._error_payload(exc), exc.status, headers=headers)

    def _redirect_login(self, handler: Any, parsed: urllib.parse.ParseResult) -> None:
        target = parsed.path + (("?" + parsed.query) if parsed.query else "")
        location = "/login?next=" + urllib.parse.quote(target, safe="")
        handler.send_response(302)
        handler.send_header("location", location)
        handler.send_header("cache-control", "no-store")
        self.add_security_headers(handler)
        handler.end_headers()

    def _require_principal(
        self,
        handler: Any,
        method: str,
        admin: bool = False,
    ) -> SessionPrincipal | None:
        if not self.store.auth_enabled():
            handler.send_json({"error": "auth_not_initialized", "message": "Authentication is not initialized."}, 409)
            return None
        principal = self._principal(handler)
        if principal is None:
            handler.send_json({"error": "authentication_required", "message": "Sign in to continue."}, 401)
            return None
        if method not in ("GET", "HEAD", "OPTIONS"):
            if not self._origin_allowed(handler):
                handler.send_json({"error": "forbidden_origin", "message": "Request origin is not allowed."}, 403)
                return None
            supplied = str(handler.headers.get("x-marina-csrf") or "")
            if not self.store.verify_csrf(principal, supplied):
                handler.send_json({"error": "csrf_failed", "message": "Request verification failed."}, 403)
                return None
        if admin and principal.user.role != "admin":
            handler.send_json({"error": "admin_required", "message": "Administrator access is required."}, 403)
            return None
        return principal

    def _user_rows(self) -> list[dict[str, object]]:
        users = self.store.list_users()
        active_admins = sum(user.role == "admin" and user.status == "active" for user in users)
        rows = []
        for user in users:
            row = user.to_dict()
            row["projectIds"] = sorted(self.store.project_access_for(user.id))
            final_admin = user.role == "admin" and user.status == "active" and active_admins <= 1
            row["canDisable"] = user.status != "disabled" and not final_admin
            row["canResetPassword"] = user.status != "disabled" and not final_admin
            rows.append(row)
        return rows

    def _resource_rows(self) -> list[dict[str, object]]:
        from marina_access import canonical_agent, canonical_root
        from marina_registry import containing_project_for, discover_all_roots
        from marina_sessions import agents_payload
        from marina_term import term_list

        admin = self.store.first_active_admin()
        if admin is None:
            return []
        resources: list[tuple[str, str, str, str]] = []
        for root in discover_all_roots():
            key = canonical_root(root)
            project = containing_project_for(root)
            resources.append(("worktree", key, Path(key).name, str((project or {}).get("id") or "")))
            try:
                for agent in agents_payload(root):
                    source, sid = str(agent.get("source") or ""), str(agent.get("sid") or "")
                    if source and sid:
                        resources.append(("agent", canonical_agent(source, sid), str(agent.get("title") or sid), key))
            except Exception:
                pass
        for term in term_list().get("sessions", []):
            tid = str(term.get("tid") or "")
            if tid:
                resources.append(("terminal", tid, str(term.get("fg") or term.get("cmd") or tid), str(term.get("root") or "")))
        owners = self.store.all_resource_owners()
        for resource_type, key, _label, context in resources:
            owner = owners.get((resource_type, key))
            parent_key = canonical_root(context) if resource_type != "worktree" and context else None
            parent = ("worktree", parent_key) if parent_key else None
            if owner is None:
                owner = admin.id
            if (resource_type, key) not in owners or self.store.resource_parent(resource_type, key) != parent:
                self.store.assign_resource_owner(
                    resource_type, key, owner, actor_user_id=admin.id,
                    parent_type="worktree" if parent_key else None, parent_key=parent_key,
                )
        owners = self.store.all_resource_owners()
        usernames = {user.id: user.username for user in self.store.list_users()}
        return [
            {
                "resourceType": resource_type, "resourceKey": key, "label": label,
                "context": context, "owner": usernames.get(owners.get((resource_type, key)), ""),
            }
            for resource_type, key, label, context in resources
        ]

    def dispatch(self, handler: Any, method: str, parsed: urllib.parse.ParseResult) -> bool:
        path = parsed.path
        if path != "/api/health" and not path.startswith(AUTH_API_PREFIX):
            return False
        try:
            if path == "/api/health" and method == "GET":
                handler.send_json({"ok": True})
                return True
            enabled = self.store.auth_enabled()
            if path == "/api/auth/status" and method == "GET":
                principal = self._principal(handler) if enabled else None
                handler.send_json({
                    "enabled": enabled,
                    "bootstrapAllowed": not enabled and is_loopback_client(handler),
                    "user": principal.user.to_dict() if principal else None,
                })
                return True
            if path == "/api/auth/bootstrap" and method == "POST":
                if not is_loopback_client(handler):
                    raise AuthError("loopback_required", "Initial administrator setup is local-only.", 403)
                if not self._origin_allowed(handler):
                    raise AuthError("forbidden_origin", "Request origin is not allowed.", 403)
                body = handler.read_json()
                user = self.store.bootstrap_admin(body.get("username", ""), body.get("displayName", ""), body.get("password", ""))
                issued = self.store.create_session(user.id)
                handler.send_json({"user": user.to_dict()}, 201, headers=self._session_headers(handler, issued.token, issued.csrf_token))
                return True
            if path == "/api/auth/claim" and method == "POST":
                if not self._origin_allowed(handler):
                    raise AuthError("forbidden_origin", "Request origin is not allowed.", 403)
                body = handler.read_json()
                user = self.store.claim_user(body.get("username", ""), body.get("password", ""))
                handler.send_json({"status": user.status}, 202)
                return True
            if path == "/api/auth/login" and method == "POST":
                if not self._origin_allowed(handler):
                    raise AuthError("forbidden_origin", "Request origin is not allowed.", 403)
                body = handler.read_json()
                user = self.store.authenticate(body.get("username", ""), body.get("password", ""))
                issued = self.store.create_session(user.id)
                handler.send_json({"user": user.to_dict()}, headers=self._session_headers(handler, issued.token, issued.csrf_token))
                return True
            if path == "/api/auth/logout" and method == "POST":
                principal = self._require_principal(handler, method)
                if principal is None:
                    return True
                self.store.logout(self._session_token(handler), actor_user_id=principal.user.id)
                handler.send_json({"ok": True}, headers=self._clear_cookie_headers(handler))
                return True
            if path == "/api/auth/users" and method == "GET":
                if self._require_principal(handler, method, admin=True) is None:
                    return True
                from marina_registry import load_projects
                projects = [
                    {"id": str(project.get("id") or ""), "label": str(project.get("label") or project.get("id") or "")}
                    for project in load_projects() if project.get("id")
                ]
                handler.send_json({"users": self._user_rows(), "projects": projects})
                return True
            if path == "/api/auth/access/projects" and method == "POST":
                principal = self._require_principal(handler, method, admin=True)
                if principal is None:
                    return True
                body = handler.read_json()
                user = self.store.user_by_username(body.get("username", ""))
                project_ids = body.get("projectIds")
                if not isinstance(project_ids, list) or not all(isinstance(item, str) for item in project_ids):
                    raise AuthError("invalid_projects", "projectIds must be a list of strings.")
                from marina_registry import load_projects
                known = {str(project.get("id")) for project in load_projects() if project.get("id")}
                unknown = sorted(set(project_ids) - known)
                if unknown:
                    raise AuthError("unknown_project", "Unknown project: " + ", ".join(unknown), 404)
                assigned = self.store.set_project_access(user.id, project_ids, principal.user.id)
                handler.send_json({"ok": True, "projectIds": sorted(assigned)})
                return True
            if path == "/api/auth/access/owner" and method == "POST":
                principal = self._require_principal(handler, method, admin=True)
                if principal is None:
                    return True
                body = handler.read_json()
                user = self.store.user_by_username(body.get("username", ""))
                resource_type = str(body.get("resourceType") or "")
                resource_key = str(body.get("resourceKey") or "")
                if resource_type not in ("worktree", "terminal", "agent"):
                    raise AuthError("invalid_resource", "Unsupported resource type.")
                self.store.assign_resource_owner(
                    resource_type, resource_key, user.id, actor_user_id=principal.user.id
                )
                handler.send_json({"ok": True})
                return True
            if path == "/api/auth/access/resources" and method == "GET":
                if self._require_principal(handler, method, admin=True) is None:
                    return True
                handler.send_json({"resources": self._resource_rows()})
                return True
            if path == "/api/auth/sessions/revoke-all" and method == "POST":
                principal = self._require_principal(handler, method, admin=True)
                if principal is None:
                    return True
                count = self.store.revoke_all_sessions(actor_user_id=principal.user.id)
                handler.send_json({"ok": True, "revoked": count}, headers=self._clear_cookie_headers(handler))
                return True
            action_paths = {
                "/api/auth/users/add": "add",
                "/api/auth/users/approve": "approve",
                "/api/auth/users/reject": "reject",
                "/api/auth/users/disable": "disable",
                "/api/auth/users/reset-password": "reset-password",
            }
            action = action_paths.get(path)
            if action and method == "POST":
                principal = self._require_principal(handler, method, admin=True)
                if principal is None:
                    return True
                body = handler.read_json()
                if action == "add":
                    user = self.store.add_user(
                        body.get("username", ""),
                        body.get("displayName", ""),
                        body.get("role", "member"),
                        actor_user_id=principal.user.id,
                    )
                    status = 201
                elif action == "approve":
                    user, status = self.store.approve_user(
                        body.get("username", ""), actor_user_id=principal.user.id
                    ), 200
                elif action == "reject":
                    user, status = self.store.reject_user(
                        body.get("username", ""), actor_user_id=principal.user.id
                    ), 200
                elif action == "disable":
                    user, status = self.store.disable_user(
                        body.get("username", ""), actor_user_id=principal.user.id
                    ), 200
                else:
                    user, status = self.store.reset_password(
                        body.get("username", ""), actor_user_id=principal.user.id
                    ), 200
                handler.send_json({"user": user.to_dict()}, status)
                return True
            handler.send_json({"error": "not_found", "message": "Auth endpoint not found."}, 404)
            return True
        except AuthError as exc:
            self._send_auth_error(handler, exc)
            return True
        except Exception as exc:
            print(f"[marina] auth unavailable: {exc!r}")
            handler.send_json({
                "error": "auth_unavailable",
                "message": "Authentication storage is unavailable. Check the local Marina logs.",
            }, 503)
            return True

    def authorize(
        self,
        handler: Any,
        method: str,
        parsed: urllib.parse.ParseResult,
    ) -> SessionPrincipal | None | object:
        try:
            if parsed.path in PUBLIC_PATHS or parsed.path.startswith(PUBLIC_PREFIXES):
                return None
            if not self.store.auth_enabled():
                return None
            principal = self._principal(handler)
            if principal is None:
                if method == "GET" and parsed.path in ("/", "/mobile"):
                    self._redirect_login(handler, parsed)
                else:
                    handler.send_json({"error": "authentication_required", "message": "Sign in to continue."}, 401)
                return AUTH_DENIED
            if method not in ("GET", "HEAD", "OPTIONS"):
                if not self._origin_allowed(handler):
                    handler.send_json({"error": "forbidden_origin", "message": "Request origin is not allowed."}, 403)
                    return AUTH_DENIED
                if not self.store.verify_csrf(principal, str(handler.headers.get("x-marina-csrf") or "")):
                    handler.send_json({"error": "csrf_failed", "message": "Request verification failed."}, 403)
                    return AUTH_DENIED
            return principal
        except Exception as exc:
            print(f"[marina] auth unavailable: {exc!r}")
            if method == "GET" and parsed.path in ("/", "/mobile"):
                self._redirect_login(handler, parsed)
            else:
                handler.send_json({
                    "error": "auth_unavailable",
                    "message": "Authentication storage is unavailable. Check the local Marina logs.",
                }, 503)
            return AUTH_DENIED


_CONTROLLERS: dict[tuple[str, int], AuthHTTPController] = {}


def auth_controller() -> AuthHTTPController:
    db_path = Path(os.environ.get("MARINA_AUTH_DB", str(AUTH_DB)))
    iterations = int(os.environ.get("MARINA_AUTH_PBKDF2_ITERATIONS", str(PBKDF2_ITERATIONS)))
    key = (str(db_path), iterations)
    controller = _CONTROLLERS.get(key)
    if controller is None:
        controller = AuthHTTPController(AuthStore(db_path, pbkdf2_iterations=iterations))
        _CONTROLLERS[key] = controller
    return controller
