"""Non-destructive Tailscale Serve and Funnel state control for Marina."""
from __future__ import annotations

import fcntl
import hashlib
import json
import os
import re
import shutil
import subprocess
import tempfile
import threading
import time
from contextlib import contextmanager
from pathlib import Path
from typing import Any, Callable, Union


DEFAULT_MARINA_HOME = Path(os.environ.get("MARINA_HOME", str(Path.home() / ".marina")))
CACHE_SECONDS = 15.0
CONSENT_URL_RE = re.compile(r"https://[^\s<>\"']+")
_THREAD_LOCKS: dict[str, threading.Lock] = {}
_THREAD_LOCKS_GUARD = threading.Lock()


class RemoteControlError(RuntimeError):
    def __init__(self, code: str, message: str, details: Union[dict[str, Any], None] = None):
        super().__init__(message)
        self.code = code
        self.message = message
        self.details = details or {}

    def to_dict(self) -> dict[str, Any]:
        return {"code": self.code, "message": self.message, **self.details}


def canonical_fingerprint(value: Any) -> str:
    encoded = json.dumps(
        value,
        ensure_ascii=True,
        sort_keys=True,
        separators=(",", ":"),
    ).encode("utf-8")
    return hashlib.sha256(encoded).hexdigest()


def _nonempty(value: Any) -> bool:
    if isinstance(value, dict):
        return any(_nonempty(item) for item in value.values())
    if isinstance(value, list):
        return any(_nonempty(item) for item in value)
    return value not in (None, False, "", 0)


def _routes(configuration: Any) -> list[dict[str, Any]]:
    if not isinstance(configuration, dict):
        return []
    routes: list[dict[str, Any]] = []
    services = configuration.get("Services")
    if isinstance(services, dict):
        for service in services.values():
            routes.extend(_routes(service))
    web = configuration.get("Web")
    funnel = configuration.get("AllowFunnel")
    funnel_hosts = {
        str(host) for host, enabled in funnel.items() if enabled
    } if isinstance(funnel, dict) else set()
    if not isinstance(web, dict):
        return routes
    for authority, server in web.items():
        if not isinstance(server, dict):
            continue
        handlers = server.get("Handlers")
        if not isinstance(handlers, dict):
            continue
        authority_text = str(authority)
        host, separator, port_text = authority_text.rpartition(":")
        try:
            port = int(port_text) if separator else 443
        except ValueError:
            port = 443
        if not separator:
            host = authority_text
        for path, handler in handlers.items():
            if not isinstance(handler, dict) or not handler.get("Proxy"):
                continue
            routes.append({
                "mode": "funnel" if authority_text in funnel_hosts else "serve",
                "host": host.rstrip("."),
                "httpsPort": port,
                "path": str(path),
                "backend": str(handler["Proxy"]),
            })
    return routes


class RemoteController:
    def __init__(
        self,
        marina_home: Union[Path, str, None] = None,
        tailscale_bin: Union[Path, str, None] = None,
        clock: Callable[[], float] = time.time,
    ) -> None:
        self.marina_home = Path(marina_home or DEFAULT_MARINA_HOME)
        self.state_path = self.marina_home / "remote-state.json"
        self.lock_path = self.marina_home / "remote-state.lock"
        self.tailscale_bin = str(tailscale_bin or os.environ.get("MARINA_TAILSCALE_BIN", "tailscale"))
        self.clock = clock
        self._cache: dict[str, Any] = {}

    def _executable(self) -> Union[str, None]:
        if os.path.dirname(self.tailscale_bin):
            path = Path(self.tailscale_bin)
            return str(path) if path.is_file() and os.access(str(path), os.X_OK) else None
        return shutil.which(self.tailscale_bin)

    def _run_json(self, executable: str, *args: str) -> Any:
        completed = subprocess.run(
            [executable, *args],
            check=True,
            capture_output=True,
            text=True,
            timeout=10,
        )
        return json.loads(completed.stdout or "{}")

    def _saved_state(self) -> dict[str, Any]:
        try:
            value = json.loads(self.state_path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            return {}
        return value if isinstance(value, dict) else {}

    def _write_state(self, state: dict[str, Any]) -> None:
        self.marina_home.mkdir(parents=True, exist_ok=True)
        try:
            self.marina_home.chmod(0o700)
        except OSError:
            pass
        descriptor, temporary = tempfile.mkstemp(
            prefix=".remote-state-",
            suffix=".tmp",
            dir=str(self.marina_home),
        )
        try:
            with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
                json.dump(state, handle, ensure_ascii=True, sort_keys=True, separators=(",", ":"))
                handle.write("\n")
                handle.flush()
                os.fsync(handle.fileno())
            os.chmod(temporary, 0o600)
            os.replace(temporary, self.state_path)
        finally:
            try:
                os.unlink(temporary)
            except FileNotFoundError:
                pass

    def _mutate(self, executable: str, *args: str) -> subprocess.CompletedProcess[str]:
        try:
            return subprocess.run(
                [executable, *args],
                check=False,
                capture_output=True,
                text=True,
                timeout=15,
            )
        except (OSError, subprocess.SubprocessError) as exc:
            raise RemoteControlError("tailscale_command_failed", str(exc)) from exc

    @contextmanager
    def _mutation_lock(self):
        self.marina_home.mkdir(parents=True, exist_ok=True)
        try:
            self.marina_home.chmod(0o700)
        except OSError:
            pass
        lock_key = str(self.lock_path.resolve())
        with _THREAD_LOCKS_GUARD:
            thread_lock = _THREAD_LOCKS.setdefault(lock_key, threading.Lock())
        with thread_lock:
            descriptor = os.open(self.lock_path, os.O_CREAT | os.O_RDWR, 0o600)
            try:
                os.chmod(self.lock_path, 0o600)
                fcntl.flock(descriptor, fcntl.LOCK_EX)
                yield
            finally:
                fcntl.flock(descriptor, fcntl.LOCK_UN)
                os.close(descriptor)

    @staticmethod
    def _matches(status: dict[str, Any], mode: str, backend: str) -> bool:
        routes = status.get("routes")
        if not isinstance(routes, list) or len(routes) != 1:
            return False
        route = routes[0]
        return (
            route.get("mode") == mode
            and route.get("backend") == backend
            and route.get("httpsPort") == 443
            and route.get("path") == "/"
        )

    def _finish_status(self, payload: dict[str, Any]) -> dict[str, Any]:
        self._cache = {"at": self.clock(), "payload": payload}
        return payload

    def status(self, refresh: bool = False) -> dict[str, Any]:
        now = self.clock()
        if (
            not refresh
            and self._cache
            and now - float(self._cache["at"]) < CACHE_SECONDS
        ):
            return self._cache["payload"]
        executable = self._executable()
        if executable is None:
            return self._finish_status({
                "state": "unavailable",
                "installed": False,
                "online": False,
                "checkedAt": now,
                "error": {
                    "code": "tailscale_not_found",
                    "message": "Tailscale CLI is not installed.",
                },
            })
        try:
            version_data = self._run_json(executable, "version", "--json")
            status_data = self._run_json(executable, "status", "--json")
        except (OSError, subprocess.SubprocessError, json.JSONDecodeError) as exc:
            return self._finish_status({
                "state": "error",
                "installed": True,
                "online": False,
                "checkedAt": now,
                "error": {"code": "tailscale_status_failed", "message": str(exc)},
            })

        own = status_data.get("Self") if isinstance(status_data.get("Self"), dict) else {}
        backend_state = str(status_data.get("BackendState") or "")
        online = backend_state == "Running" and own.get("Online") is not False
        version = ""
        if isinstance(version_data, dict):
            version = str(version_data.get("long") or version_data.get("version") or "")
        dns_name = str(own.get("DNSName") or "").rstrip(".")
        ips = status_data.get("TailscaleIPs") or own.get("TailscaleIPs") or []
        payload = {
            "state": "off" if online else "offline",
            "installed": True,
            "online": online,
            "version": version,
            "dnsName": dns_name or None,
            "ips": [str(value) for value in ips] if isinstance(ips, list) else [],
            "checkedAt": now,
            "error": None,
        }
        if not online:
            payload["error"] = {
                "code": "tailscale_offline",
                "message": "Tailscale daemon is not running.",
            }
            return self._finish_status(payload)

        try:
            serve_config = self._run_json(executable, "serve", "status", "--json")
            funnel_config = self._run_json(executable, "funnel", "status", "--json")
        except (OSError, subprocess.SubprocessError, json.JSONDecodeError) as exc:
            payload.update({
                "state": "error",
                "error": {"code": "tailscale_config_failed", "message": str(exc)},
            })
            return self._finish_status(payload)

        configuration = {"serve": serve_config, "funnel": funnel_config}
        fingerprint = canonical_fingerprint(configuration)
        saved = self._saved_state()
        nonempty = _nonempty(serve_config) or _nonempty(funnel_config)
        owned = bool(nonempty and saved.get("configFingerprint") == fingerprint)
        found = _routes(serve_config) + _routes(funnel_config)
        deduplicated: dict[tuple[Any, ...], dict[str, Any]] = {}
        for route in found:
            key = (route["host"], route["httpsPort"], route["path"], route["backend"])
            previous = deduplicated.get(key)
            if previous is None or route["mode"] == "funnel":
                deduplicated[key] = route
        routes = list(deduplicated.values())
        primary = next((route for route in routes if route["mode"] == "funnel"), None)
        if primary is None and routes:
            primary = routes[0]
        mode = str(primary["mode"]) if primary else "off"
        if nonempty and not routes:
            mode = "off"
        cert_domains = status_data.get("CertDomains") or []
        cert_names = {str(value).rstrip(".") for value in cert_domains} if isinstance(cert_domains, list) else set()
        magic_suffix = str(status_data.get("MagicDNSSuffix") or "").rstrip(".")
        payload.update({
            "state": "conflict" if nonempty and not routes else mode,
            "mode": mode,
            "url": ("https://" + str(primary["host"])) if primary else None,
            "backend": str(primary["backend"]) if primary else None,
            "httpsReady": bool(dns_name and dns_name in cert_names),
            "magicDNSReady": bool(dns_name and magic_suffix and dns_name.endswith("." + magic_suffix)),
            "owned": owned,
            "conflict": bool(nonempty and not owned),
            "configFingerprint": fingerprint if nonempty else None,
            "configuration": configuration,
            "routes": routes,
        })
        if nonempty and routes:
            payload["state"] = mode
        return self._finish_status(payload)

    def activate(self, mode: str, port: int) -> dict[str, Any]:
        with self._mutation_lock():
            return self._activate_unlocked(mode, port)

    def _activate_unlocked(self, mode: str, port: int) -> dict[str, Any]:
        if mode not in ("serve", "funnel"):
            raise ValueError("mode must be 'serve' or 'funnel'")
        if isinstance(port, bool) or not isinstance(port, int) or not 1 <= port <= 65535:
            raise ValueError("port must be an integer between 1 and 65535")
        backend = f"http://127.0.0.1:{port}"
        before = self.status(refresh=True)
        if not before.get("installed"):
            raise RemoteControlError("tailscale_not_found", "Tailscale CLI is not installed.")
        if not before.get("online"):
            raise RemoteControlError("tailscale_offline", "Tailscale daemon is not running.")
        if before.get("conflict"):
            raise RemoteControlError(
                "config_conflict",
                "Tailscale has nonempty configuration not owned by Marina.",
                {"configFingerprint": before.get("configFingerprint")},
            )
        if before.get("owned") and self._matches(before, mode, backend):
            return before

        executable = self._executable()
        if executable is None:
            raise RemoteControlError("tailscale_not_found", "Tailscale CLI is not installed.")
        saved = self._saved_state()
        previous_mode = saved.get("mode") if before.get("owned") else None
        previous_backend = saved.get("backend") if before.get("owned") else None
        previous_fingerprint = saved.get("configFingerprint") if before.get("owned") else None

        def restore_previous() -> tuple[bool, dict[str, Any], str]:
            if previous_mode not in ("serve", "funnel") or not isinstance(previous_backend, str):
                return True, self.status(refresh=True), ""
            restored_command = self._mutate(
                executable,
                str(previous_mode),
                "--bg",
                "--https=443",
                previous_backend,
            )
            if restored_command.returncode != 0:
                message = (
                    restored_command.stderr
                    or restored_command.stdout
                    or "Tailscale rollback command failed."
                ).strip()
                return False, self.status(refresh=True), message
            restored = self.status(refresh=True)
            valid = (
                self._matches(restored, str(previous_mode), previous_backend)
                and restored.get("configFingerprint") == previous_fingerprint
            )
            return valid, restored, "" if valid else "Rollback verification failed."

        def remove_requested() -> tuple[bool, dict[str, Any], str]:
            removed_command = self._mutate(executable, mode, "--https=443", "off")
            if removed_command.returncode != 0:
                message = (
                    removed_command.stderr
                    or removed_command.stdout
                    or "Tailscale cleanup command failed."
                ).strip()
                return False, self.status(refresh=True), message
            removed = self.status(refresh=True)
            valid = removed.get("mode") == "off" and not removed.get("conflict")
            return valid, removed, "" if valid else "Cleanup verification failed."

        def rollback_requested() -> tuple[bool, dict[str, Any], str]:
            cleanup_ok, cleaned, cleanup_error = remove_requested()
            if not cleanup_ok:
                return False, cleaned, cleanup_error
            return restore_previous() if removed_previous else (True, cleaned, "")

        removed_previous = False
        if previous_mode in ("serve", "funnel"):
            disabled = self._mutate(executable, str(previous_mode), "--https=443", "off")
            if disabled.returncode != 0:
                message = (disabled.stderr or disabled.stdout or "Tailscale command failed.").strip()
                raise RemoteControlError("transition_failed", message, {"rollback": "not_needed"})
            after_disable = self.status(refresh=True)
            if after_disable.get("mode") != "off" or after_disable.get("conflict"):
                raise RemoteControlError(
                    "transition_failed",
                    "The previous Tailscale listener was not removed; the new mode was not enabled.",
                    {"rollback": "not_needed"},
                )
            removed_previous = True

        completed = self._mutate(executable, mode, "--bg", "--https=443", backend)
        if completed.returncode != 0:
            message = (completed.stderr or completed.stdout or "Tailscale command failed.").strip()
            match = CONSENT_URL_RE.search((completed.stdout or "") + "\n" + (completed.stderr or ""))
            rollback_ok, restored, rollback_error = restore_previous() if removed_previous else (True, before, "")
            if match:
                action_url = match.group(0).rstrip(".,);]")
                return {
                    **restored,
                    "state": "action_required",
                    "actionUrl": action_url,
                    "error": {
                        "code": "consent_required",
                        "message": message,
                        "rollback": "succeeded" if rollback_ok else "failed",
                        "rollbackError": rollback_error or None,
                    },
                }
            if removed_previous:
                raise RemoteControlError(
                    "transition_failed",
                    message,
                    {
                        "rollback": "succeeded" if rollback_ok else "failed",
                        "rollbackError": rollback_error or None,
                    },
                )
            raise RemoteControlError("tailscale_command_failed", message)

        current = self.status(refresh=True)
        if not self._matches(current, mode, backend):
            rollback_ok, _restored, rollback_error = rollback_requested()
            raise RemoteControlError(
                "transition_failed" if removed_previous else "verification_failed",
                "Tailscale did not report the requested Marina route.",
                {
                    "rollback": "succeeded" if rollback_ok else "failed",
                    "rollbackError": rollback_error or None,
                },
            )
        state = {
            "version": 1,
            "mode": mode,
            "backend": backend,
            "httpsPort": 443,
            "path": "/",
            "configFingerprint": current["configFingerprint"],
            "updatedAt": self.clock(),
        }
        try:
            self._write_state(state)
        except OSError as exc:
            rollback_ok, _restored, rollback_error = rollback_requested()
            raise RemoteControlError(
                "state_write_failed",
                str(exc),
                {
                    "rollback": "succeeded" if rollback_ok else "failed",
                    "rollbackError": rollback_error or None,
                },
            ) from exc
        current["owned"] = True
        current["conflict"] = False
        return current

    def off(self) -> dict[str, Any]:
        with self._mutation_lock():
            return self._off_unlocked()

    def _off_unlocked(self) -> dict[str, Any]:
        before = self.status(refresh=True)
        if not before.get("installed"):
            raise RemoteControlError("tailscale_not_found", "Tailscale CLI is not installed.")
        if not before.get("online"):
            raise RemoteControlError("tailscale_offline", "Tailscale daemon is not running.")
        if before.get("conflict"):
            raise RemoteControlError(
                "config_conflict",
                "Tailscale configuration does not match Marina's saved fingerprint.",
                {"configFingerprint": before.get("configFingerprint")},
            )
        if before.get("mode") == "off":
            return before

        saved = self._saved_state()
        mode = saved.get("mode")
        if not before.get("owned") or mode not in ("serve", "funnel"):
            raise RemoteControlError(
                "config_not_owned",
                "Marina will not disable a Tailscale listener it does not own.",
            )
        executable = self._executable()
        if executable is None:
            raise RemoteControlError("tailscale_not_found", "Tailscale CLI is not installed.")
        completed = self._mutate(executable, str(mode), "--https=443", "off")
        if completed.returncode != 0:
            message = (completed.stderr or completed.stdout or "Tailscale command failed.").strip()
            raise RemoteControlError("tailscale_command_failed", message)

        current = self.status(refresh=True)
        if current.get("mode") != "off" or current.get("conflict"):
            raise RemoteControlError(
                "verification_failed",
                "Tailscale did not remove the owned Marina listener.",
            )
        state = {
            "version": 1,
            "mode": "off",
            "backend": None,
            "httpsPort": 443,
            "path": "/",
            "configFingerprint": None,
            "updatedAt": self.clock(),
        }
        self._write_state(state)
        return current
