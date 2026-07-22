#!/usr/bin/env python3
"""Local CLI for Marina Tailscale remote access."""
from __future__ import annotations

import argparse
import getpass
import http.client
import json
import os
import subprocess
import sys
from pathlib import Path

from marina_auth import AUTH_DB, PBKDF2_ITERATIONS, AuthError, AuthStore, SessionPrincipal
from marina_remote import RemoteControlError, RemoteController
from marina_remote_service import RemoteService


def parser() -> argparse.ArgumentParser:
    root = argparse.ArgumentParser(prog="marina remote")
    root.add_argument("command", choices=("status", "serve", "funnel", "off"))
    root.add_argument("--password-stdin", action="store_true")
    return root


def _service(store: AuthStore, home: Path) -> RemoteService:
    def guard_check() -> bool:
        bind = RemoteService(store, RemoteController(home), home)
        host = "127.0.0.1" if bind.control_host in ("localhost", "0.0.0.0", "::") else bind.control_host
        def probe(path: str) -> tuple[int, str]:
            conn = http.client.HTTPConnection(host, bind.control_port, timeout=2)
            try:
                conn.request("GET", path, headers={"Host": f"127.0.0.1:{bind.control_port}"})
                response = conn.getresponse(); response.read()
                return response.status, str(response.getheader("location") or "")
            finally:
                conn.close()
        api, _ = probe("/api/worktrees")
        page, location = probe("/")
        return api == 401 and page == 302 and location.startswith("/login")
    return RemoteService(store, RemoteController(home), home, guard_check=guard_check)


def _principal(store: AuthStore) -> SessionPrincipal:
    admin = store.first_active_admin()
    if admin is None:
        raise AuthError("active_admin_required", "No active Marina administrator exists.", 409)
    return SessionPrincipal(admin, 0, b"")


def _print_status(payload: dict) -> None:
    for key in ("state", "mode", "installed", "online", "dnsName", "url", "dashboardHost", "dashboardPort"):
        if key in payload:
            value = payload.get(key)
            if isinstance(value, bool):
                value = "true" if value else "false"
            print(f"{key}={'' if value is None else value}")
    readiness = payload.get("readiness") or {}
    print(f"public-ready={'true' if readiness.get('ready') else 'false'}")
    for check in readiness.get("checks") or []:
        print(f"check.{check.get('id')}={'ok' if check.get('ok') else 'blocked'}")


def run(args: argparse.Namespace) -> int:
    home = Path(os.environ.get("MARINA_HOME", str(Path.home() / ".marina")))
    store = AuthStore(
        Path(os.environ.get("MARINA_AUTH_DB", str(AUTH_DB))),
        pbkdf2_iterations=int(os.environ.get("MARINA_AUTH_PBKDF2_ITERATIONS", str(PBKDF2_ITERATIONS))),
    )
    service = _service(store, home)
    if args.command == "status":
        _print_status(service.status())
        return 0
    principal = _principal(store)
    if args.command == "off":
        result = service.off(principal)
    else:
        password = ""
        if args.command == "funnel":
            password = sys.stdin.readline().rstrip("\r\n") if args.password_stdin else getpass.getpass("Administrator password: ")
        result = service.activate(args.command, principal, password=password)
    _print_status({**result, "dashboardHost": service.control_host, "dashboardPort": service.control_port})
    if result.get("restartRequired") and os.environ.get("MARINA_REMOTE_NO_RESTART") != "1":
        dashboard = Path(__file__).resolve().parent / "marina-dashboard.sh"
        subprocess.run(["bash", str(dashboard), "restart"], check=True)
    return 0


def main() -> int:
    try:
        return run(parser().parse_args())
    except (AuthError, RemoteControlError, OSError, ValueError, subprocess.SubprocessError) as exc:
        print(f"error: {getattr(exc, 'message', str(exc))}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
