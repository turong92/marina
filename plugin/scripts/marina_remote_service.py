"""Auth/readiness and dashboard-bind integration for remote access."""
from __future__ import annotations

import os
import tempfile
from pathlib import Path
from typing import Any, Callable

from marina_auth import ATTEMPT_LIMIT, ATTEMPT_WINDOW_SECONDS, LOCK_SECONDS, AuthError, AuthStore, SessionPrincipal


class RemoteService:
    def __init__(
        self,
        store: AuthStore,
        controller: Any,
        home: Path | str,
        control_host: str | None = None,
        control_port: int | None = None,
        guard_check: Callable[[], bool] | None = None,
    ) -> None:
        self.store = store
        self.controller = controller
        self.home = Path(home)
        self.bind_path = self.home / "dashboard-bind.env"
        persisted = self._read_bind()
        self.control_host = str(control_host or os.environ.get("MARINA_CONTROL_HOST") or persisted.get("MARINA_CONTROL_HOST") or "localhost")
        self.control_port = int(control_port or os.environ.get("MARINA_CONTROL_PORT") or persisted.get("MARINA_CONTROL_PORT") or 3900)
        self.guard_check = guard_check or (lambda: False)

    def _read_bind(self) -> dict[str, str]:
        try:
            lines = self.bind_path.read_text(encoding="utf-8").splitlines()
        except OSError:
            return {}
        return {
            key: value for line in lines for key, separator, value in [line.partition("=")]
            if separator and key in ("MARINA_CONTROL_HOST", "MARINA_CONTROL_PORT")
        }

    def _write_local_bind(self) -> None:
        self.home.mkdir(parents=True, exist_ok=True)
        descriptor, temporary = tempfile.mkstemp(prefix=".dashboard-bind-", dir=str(self.home))
        try:
            with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
                handle.write(f"MARINA_CONTROL_HOST=localhost\nMARINA_CONTROL_PORT={self.control_port}\n")
                handle.flush()
                os.fsync(handle.fileno())
            os.chmod(temporary, 0o600)
            os.replace(temporary, self.bind_path)
        finally:
            try:
                os.unlink(temporary)
            except FileNotFoundError:
                pass
        self.control_host = "localhost"

    def readiness(self, remote_status: dict[str, Any] | None = None) -> dict[str, Any]:
        remote_status = remote_status if remote_status is not None else self.controller.status()
        auth_enabled = self.store.auth_enabled()
        active_admin = self.store.active_admin_count() > 0
        localhost_bind = self.control_host in ("localhost", "127.0.0.1", "::1")
        try:
            guard_ok = bool(self.guard_check())
        except Exception:
            guard_ok = False
        rate_limit = ATTEMPT_LIMIT <= 5 and ATTEMPT_WINDOW_SECONDS > 0 and LOCK_SECONDS > 0
        checks = [
            {"id": "tailscale_installed", "label": "Tailscale 설치", "ok": bool(remote_status.get("installed"))},
            {"id": "tailscale_online", "label": "Tailscale 연결", "ok": bool(remote_status.get("online"))},
            {"id": "tailscale_config", "label": "Tailscale 설정 충돌 없음", "ok": not bool(remote_status.get("conflict"))},
            {"id": "auth_enabled", "label": "로그인 보호", "ok": auth_enabled},
            {"id": "active_admin", "label": "활성 관리자", "ok": active_admin},
            {"id": "localhost_bind", "label": "로컬 백엔드 바인드", "ok": localhost_bind},
            {"id": "auth_guard", "label": "비로그인 API 차단", "ok": guard_ok},
            {"id": "rate_limit", "label": "로그인 시도 제한", "ok": rate_limit},
        ]
        return {"ready": all(item["ok"] for item in checks), "checks": checks}

    @staticmethod
    def _require_admin(principal: SessionPrincipal | None) -> SessionPrincipal:
        if principal is None or principal.user.role != "admin":
            raise AuthError("admin_required", "Administrator access is required.", 403)
        return principal

    def status(self) -> dict[str, Any]:
        remote = self.controller.status()
        return {
            **remote,
            "readiness": self.readiness(remote),
            "dashboardHost": self.control_host,
            "dashboardPort": self.control_port,
        }

    def activate(
        self,
        mode: str,
        principal: SessionPrincipal | None,
        password: str = "",
    ) -> dict[str, Any]:
        principal = self._require_admin(principal)
        if mode not in ("serve", "funnel"):
            raise AuthError("invalid_remote_mode", "Remote mode must be serve or funnel.")
        if not self.store.auth_enabled():
            raise AuthError("auth_required", "Initialize Marina authentication first.", 409)
        if mode == "funnel":
            readiness = self.readiness(self.controller.status())
            if not readiness["ready"]:
                raise AuthError("remote_not_ready", "Public access safety checks are not complete.", 409)
            try:
                verified = self.store.authenticate(principal.user.username, password)
            except AuthError as exc:
                self.store.audit_action("remote.reauth", "failed", principal.user.id, "remote", mode)
                raise AuthError("reauth_failed", "Administrator password confirmation failed.", 403) from exc
            if verified.id != principal.user.id or verified.role != "admin":
                raise AuthError("reauth_failed", "Administrator password confirmation failed.", 403)
        result = self.controller.activate(mode, self.control_port)
        if result.get("state") == "action_required":
            self.store.audit_action("remote.change", "action_required", principal.user.id, "remote", mode)
            return {**result, "restartRequired": False, "readiness": self.readiness(result)}
        try:
            self._write_local_bind()
        except Exception:
            try:
                self.controller.off()
            finally:
                self.store.audit_action("remote.change", "bind_failed", principal.user.id, "remote", mode)
            raise
        self.store.audit_action("remote.change", "ok", principal.user.id, "remote", mode)
        return {**result, "restartRequired": True, "readiness": self.readiness(result)}

    def off(self, principal: SessionPrincipal | None) -> dict[str, Any]:
        principal = self._require_admin(principal)
        result = self.controller.off()
        self.store.audit_action("remote.change", "ok", principal.user.id, "remote", "off")
        return {**result, "restartRequired": False, "readiness": self.readiness(result)}
