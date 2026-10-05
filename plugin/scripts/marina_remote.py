"""Non-destructive Tailscale Serve and Funnel state control for Marina."""
from __future__ import annotations

import fcntl
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
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
        tailscale_socket: Union[Path, str, None] = None,
    ) -> None:
        self.marina_home = Path(marina_home or DEFAULT_MARINA_HOME)
        self.state_path = self.marina_home / "remote-state.json"
        self.lock_path = self.marina_home / "remote-state.lock"
        bin_pinned = bool(tailscale_bin or os.environ.get("MARINA_TAILSCALE_BIN"))
        self.tailscale_bin = str(tailscale_bin or os.environ.get("MARINA_TAILSCALE_BIN", "tailscale"))
        self.tailscale_socket = str(tailscale_socket or os.environ.get("MARINA_TAILSCALE_SOCKET") or "")
        # 맥에 오픈소스 tailscaled(LaunchDaemon)와 Tailscale 앱이 같이 떠 있으면, --socket 없는 CLI 는
        # **앱 쪽**에 붙는다. 형 funnel 은 tailscaled 에 걸려 있는데 status 가 앱 노드의 dnsName 을 돌려주면
        # 펀넬 Host 가드가 진짜 공개 주소를 403 으로 막는다(2026-09-28 재부팅 후 앱 자동 실행으로 실측).
        # tailscaled 소켓이 있으면 그쪽을 명시한다. 바이너리를 주입한 경우(테스트)는 건드리지 않는다.
        if (not self.tailscale_socket and not bin_pinned and sys.platform == "darwin"
                and os.path.exists(self._TAILSCALED_SOCKET)):
            self.tailscale_socket = self._TAILSCALED_SOCKET
        self.clock = clock
        self._cache: dict[str, Any] = {}

    _TAILSCALED_SOCKET = "/var/run/tailscaled.socket"   # 맥 오픈소스 tailscaled 기본 소켓

    def _argv(self, executable: str, *args: str) -> list[str]:
        socket = ["--socket", self.tailscale_socket] if self.tailscale_socket else []
        return [executable, *socket, *args]

    # launchd/systemd 데몬은 최소 PATH(/usr/bin:/bin:/usr/sbin:/sbin)로 뜬다 — homebrew 등이 빠져
    # shutil.which("tailscale") 가 None 을 돌려주고, 그러면 원격 status=tailscale_not_found·dnsName=None 이
    # 되어 펀넬 Host 가드가 접속을 403 으로 막는다. 재시작이 이 최소 PATH 를 plist 에 그대로 구워 재현되므로,
    # PATH 에 의존하지 않게 알려진 설치 위치를 폴백으로 확인한다.
    _TAILSCALE_FALLBACKS = (
        "/opt/homebrew/bin/tailscale",                            # Apple Silicon homebrew
        "/usr/local/bin/tailscale",                               # Intel homebrew / 수동
        "/Applications/Tailscale.app/Contents/MacOS/Tailscale",   # Mac 앱 번들 CLI
        "/usr/bin/tailscale", "/bin/tailscale",                   # Linux
    )

    def _executable(self) -> Union[str, None]:
        if os.path.dirname(self.tailscale_bin):
            path = Path(self.tailscale_bin)
            return str(path) if path.is_file() and os.access(str(path), os.X_OK) else None
        found = shutil.which(self.tailscale_bin)
        if found:
            return found
        for cand in self._TAILSCALE_FALLBACKS:
            if os.path.isfile(cand) and os.access(cand, os.X_OK):
                return cand
        return None

    def _run_json(self, executable: str, *args: str) -> Any:
        completed = subprocess.run(
            self._argv(executable, *args),
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
                self._argv(executable, *args),
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

    # ── live(상시 운영) 라우트 ────────────────────────────────────────────────
    # marina 자신의 원격 접근은 443 의 "/" 에 리스너 **하나**만 둔다. 상시 운영(marina live)
    # 공개는 그와 별개로 8443·10000 에 경로 라우트를 더한다. 그 둘을 섞으면:
    #   · activate() 의 검증(_matches)이 "라우트가 1개" 를 요구해 롤백한다
    #   · off() 의 검증이 live 라우트를 보고 "안 꺼졌다" 로 판정한다
    #   · 설정 지문이 달라져 status 가 conflict 를 올리고 off() 가 "남의 것" 이라며 거부한다
    # 그래서 저장 상태에 live 라우트를 기록하고, **소유 판정에서 걷어낸 뒤** marina 자신의
    # 리스너만 보고 판단한다. 지문은 live 변경 때마다 다시 저장해 소유를 유지한다.
    def _saved_live_routes(self) -> list[dict[str, Any]]:
        saved = self._saved_state().get("liveRoutes")
        return [r for r in saved if isinstance(r, dict)] if isinstance(saved, list) else []

    @staticmethod
    def _route_key(route: dict[str, Any]) -> tuple:
        return (int(route.get("httpsPort") or 443), str(route.get("path") or "/"), str(route.get("backend") or ""))

    def _own_routes(self, status: dict[str, Any]) -> list[dict[str, Any]]:
        """marina 자신의 원격 접근 라우트만 — live 공개 라우트는 뺀다."""
        routes = status.get("routes")
        if not isinstance(routes, list):
            return []
        live_keys = {self._route_key(r) for r in self._saved_live_routes()}
        return [r for r in routes if isinstance(r, dict) and self._route_key(r) not in live_keys]

    def _own_mode(self, status: dict[str, Any]) -> str:
        own = self._own_routes(status)
        if not own:
            return "off"
        funnel = next((r for r in own if r.get("mode") == "funnel"), None)
        return str((funnel or own[0]).get("mode") or "off")

    def _matches(self, status: dict[str, Any], mode: str, backend: str) -> bool:
        routes = self._own_routes(status)
        if len(routes) != 1:
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
            "liveRoutes": self._saved_live_routes(),
        })
        payload["ownMode"] = self._own_mode(payload)
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
            self._refresh_fingerprint()
            restored = self.status(refresh=True)
            valid = self._matches(restored, str(previous_mode), previous_backend) and (
                # live 라우트가 있으면 전체 지문은 당연히 다르다 — 그 경우 라우트 일치로 판정한다
                bool(self._saved_live_routes())
                or restored.get("configFingerprint") == previous_fingerprint
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
            self._refresh_fingerprint()
            removed = self.status(refresh=True)
            valid = self._own_mode(removed) == "off" and not removed.get("conflict")
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
            self._refresh_fingerprint()         # live 라우트가 남아 설정이 비지 않는다 — 위 설명 참고
            after_disable = self.status(refresh=True)
            if self._own_mode(after_disable) != "off" or after_disable.get("conflict"):
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
            "liveRoutes": self._saved_live_routes(),      # live 공개는 443 과 별개 — 모드 전환이 지우지 않는다
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

    # Funnel 이 허용하는 포트는 443·8443·10000 셋뿐이고, marina 자신의 원격 접근이 443 을
    # 쓴다(activate 는 --https=443 고정). **443 의 경로로 앱을 공개하면 안 된다**: AllowFunnel 은
    # 경로가 아니라 authority(host:port) 단위라, /app 을 공개하려고 funnel 을 켜면 같은 443 의
    # "/" 에 있는 **대시보드까지 인터넷에 열린다**(관리 UI 공개 금지). 그래서 live 는 8443·10000
    # 만 쓰고, 그 결과 동시에 공개할 수 있는 앱은 최대 2개다 — 숨기지 않고 그대로 알린다.
    LIVE_FUNNEL_PORTS = (8443, 10000)

    def add_live_route(self, mode: str, https_port: int, path: str, backend: str) -> dict[str, Any]:
        with self._mutation_lock():
            return self._add_live_route_unlocked(mode, https_port, path, backend)

    def _add_live_route_unlocked(self, mode: str, https_port: int, path: str, backend: str) -> dict[str, Any]:
        if mode not in ("serve", "funnel"):
            raise ValueError("mode must be 'serve' or 'funnel'")
        if int(https_port) == 443:
            raise RemoteControlError(
                "live_port_reserved",
                "443 is reserved for Marina's own remote access; funnel there would publish the dashboard.",
            )
        if not str(path).startswith("/") or str(path) == "/":
            raise ValueError("path must start with '/' and must not be '/'")
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
        executable = self._executable()
        if executable is None:
            raise RemoteControlError("tailscale_not_found", "Tailscale CLI is not installed.")
        entry = {"mode": mode, "httpsPort": int(https_port), "path": str(path), "backend": str(backend)}
        completed = self._mutate(executable, mode, "--bg", f"--https={int(https_port)}",
                                 f"--set-path={path}", backend)
        if completed.returncode != 0:
            message = (completed.stderr or completed.stdout or "Tailscale command failed.").strip()
            match = CONSENT_URL_RE.search((completed.stdout or "") + "\n" + (completed.stderr or ""))
            if match:
                return {**self.status(refresh=True), "state": "action_required",
                        "actionUrl": match.group(0).rstrip(".,);]"),
                        "error": {"code": "consent_required", "message": message}}
            raise RemoteControlError("tailscale_command_failed", message)
        self._persist_live_routes(self._saved_live_routes() + [entry])
        current = self.status(refresh=True)
        if not any(self._route_key(r) == self._route_key(entry) for r in (current.get("routes") or [])):
            # 되돌린다 — 반쯤 켜진 상태를 남기면 "공개됐다고 하는데 안 열린다" 가 된다.
            self._mutate(executable, mode, f"--https={int(https_port)}", f"--set-path={path}", "off")
            self._persist_live_routes([r for r in self._saved_live_routes()
                                       if self._route_key(r) != self._route_key(entry)])
            raise RemoteControlError("verification_failed",
                                     "Tailscale did not report the requested live route.")
        return current

    def remove_live_route(self, https_port: int, path: str) -> dict[str, Any]:
        with self._mutation_lock():
            return self._remove_live_route_unlocked(https_port, path)

    def _remove_live_route_unlocked(self, https_port: int, path: str) -> dict[str, Any]:
        """멱등 — 이미 없으면 성공으로 끝낸다. 공개 해제는 몇 번 불러도 같아야 한다."""
        saved = self._saved_live_routes()
        target = [r for r in saved if int(r.get("httpsPort") or 0) == int(https_port)
                  and str(r.get("path") or "") == str(path)]
        status = self.status(refresh=True)
        present = any(int(r.get("httpsPort") or 0) == int(https_port) and str(r.get("path") or "") == str(path)
                      for r in (status.get("routes") or []))
        if not target and not present:
            return status
        if not status.get("installed") or not status.get("online"):
            raise RemoteControlError("tailscale_offline", "Tailscale daemon is not running.")
        executable = self._executable()
        if executable is None:
            raise RemoteControlError("tailscale_not_found", "Tailscale CLI is not installed.")
        mode = str((target[0].get("mode") if target else "funnel") or "funnel")
        if present:
            completed = self._mutate(executable, mode, f"--https={int(https_port)}", f"--set-path={path}", "off")
            if completed.returncode != 0:
                message = (completed.stderr or completed.stdout or "Tailscale command failed.").strip()
                raise RemoteControlError("tailscale_command_failed", message)
        self._persist_live_routes([r for r in saved
                                   if not (int(r.get("httpsPort") or 0) == int(https_port)
                                           and str(r.get("path") or "") == str(path))])
        current = self.status(refresh=True)
        if any(int(r.get("httpsPort") or 0) == int(https_port) and str(r.get("path") or "") == str(path)
               for r in (current.get("routes") or [])):
            raise RemoteControlError("verification_failed", "Tailscale did not remove the live route.")
        return current

    def _refresh_fingerprint(self) -> None:
        """**우리 자신이** 설정을 바꾼 직후, 저장된 지문을 현재 설정으로 갱신한다.

        왜 필요한가: live 라우트가 남아 있으면 marina 자신의 리스너를 끄거나 바꿔도 설정이
        비지 않는다. 그러면 저장된 지문이 낡아 `owned=False` → `conflict=True` 가 되고,
        "남의 설정이라 건드리지 않는다" 라는 안전장치가 **우리 자신의 변경** 때문에
        작동해 off/activate 가 영구히 실패한다(실측). 지문의 목적은 '밖에서 바뀐 것'을
        감지하는 것이므로, 우리가 바꾼 직후에는 갱신이 맞다."""
        if not self._saved_live_routes():
            return
        probe = self.status(refresh=True)
        state = dict(self._saved_state())
        state["configFingerprint"] = probe.get("configFingerprint")
        state["updatedAt"] = self.clock()
        self._write_state(state)
        self._cache = {}

    def _persist_live_routes(self, routes: list) -> None:
        """live 라우트 목록과 **새 설정 지문**을 함께 저장한다. 지문을 갱신하지 않으면
        status 가 conflict 를 올려 대시보드가 원격을 끄지도 켜지도 못한다."""
        state = dict(self._saved_state())
        state.setdefault("version", 1)
        state["liveRoutes"] = list(routes)
        probe = self.status(refresh=True)
        state["configFingerprint"] = probe.get("configFingerprint")
        state["updatedAt"] = self.clock()
        self._write_state(state)
        self._cache = {}        # 지문이 바뀌었으니 다음 status 는 다시 읽는다

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
        if self._own_mode(before) == "off":
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
        # conflict 는 보지 않는다: live 라우트가 남아 있으면 **우리 자신의 off** 로 지문이
        # 달라져 반드시 conflict 가 된다. 진짜 검증은 "내 리스너가 사라졌나" 다.
        if self._own_mode(current) != "off":
            raise RemoteControlError(
                "verification_failed",
                "Tailscale did not remove the owned Marina listener.",
            )
        live = self._saved_live_routes()
        state = {
            "version": 1,
            "mode": "off",
            "backend": None,
            "httpsPort": 443,
            "path": "/",
            # live 라우트가 남아 있으면 설정은 여전히 marina 것이다 — 지문을 버리면 다음 번에
            # conflict 로 보여 live 를 끌 수도 없게 된다.
            "configFingerprint": current.get("configFingerprint") if live else None,
            "liveRoutes": live,
            "updatedAt": self.clock(),
        }
        self._write_state(state)
        self._cache = {}
        return self.status(refresh=True)
