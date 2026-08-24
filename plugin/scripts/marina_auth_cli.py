#!/usr/bin/env python3
"""Local recovery and user administration commands for Marina auth."""
from __future__ import annotations

import argparse
import urllib.parse
import getpass
import os
import sys
from pathlib import Path

from marina_auth import AUTH_DB, PBKDF2_ITERATIONS, AuthError, AuthStore, User


def _store() -> AuthStore:
    db = Path(os.environ.get("MARINA_AUTH_DB", str(AUTH_DB)))
    iterations = int(os.environ.get("MARINA_AUTH_PBKDF2_ITERATIONS", str(PBKDF2_ITERATIONS)))
    return AuthStore(db, pbkdf2_iterations=iterations)


def _print_user(user: User) -> None:
    print(f"{user.username}\t{user.role}\t{user.status}\t{user.display_name}")


def _password_from_terminal(stdin_mode: bool) -> str:
    if stdin_mode:
        return sys.stdin.readline().rstrip("\r\n")
    first = getpass.getpass("New administrator password: ")
    second = getpass.getpass("Confirm password: ")
    if first != second:
        raise AuthError("password_mismatch", "Passwords do not match.")
    return first


def parser() -> argparse.ArgumentParser:
    root = argparse.ArgumentParser(prog="marina")
    groups = root.add_subparsers(dest="group", required=True)

    auth = groups.add_parser("auth")
    auth_commands = auth.add_subparsers(dest="command", required=True)
    auth_commands.add_parser("status")
    reset = auth_commands.add_parser("reset-admin")
    reset.add_argument("username")
    reset.add_argument("--password-stdin", action="store_true")
    disable = auth_commands.add_parser("disable")
    disable.add_argument("--yes", action="store_true")

    user = groups.add_parser("user")
    user_commands = user.add_subparsers(dest="command", required=True)
    user_commands.add_parser("list")
    add = user_commands.add_parser("add")
    add.add_argument("username")
    add.add_argument("--name", dest="display_name", required=True)
    add.add_argument("--role", choices=("admin", "member"), default="member")
    for name in ("approve", "reject", "disable", "reset-password"):
        command = user_commands.add_parser(name)
        command.add_argument("username")
    # 멤버가 방을 보려면 **프로젝트 접근 + 그 워크트리 자원의 주인** 둘 다 필요하다
    # (marina_access.can_root). 지금까지 그 둘을 주는 길이 관리자 웹 API 뿐이라, 멤버 계정을
    # 만들어도 폰에 방이 하나도 안 보였다. 한 번에 주는 명령을 둔다.
    grant = user_commands.add_parser("grant")
    grant.add_argument("username")
    grant.add_argument("--project", action="append", default=[], metavar="ID",
                       help="접근을 줄 프로젝트 id (여러 번 가능)")
    grant.add_argument("--root", action="append", default=[], metavar="PATH",
                       help="주인으로 지정할 워크트리 경로 (여러 번 가능)")
    return root


def _invite_url(username: str) -> str:
    """초대 링크. 원격 주소를 알면 그걸 쓰고(폰으로 바로 보낼 수 있어야 한다), 모르면 로컬."""
    base = ""
    try:
        from marina_remote import RemoteController
        from marina_state import MARINA_HOME

        dns = str((RemoteController(MARINA_HOME).status() or {}).get("dnsName") or "").rstrip(".")
        if dns:
            base = f"https://{dns}:8443"
    except Exception:
        base = ""
    if not base:
        # 원격 이름을 못 얻는 경우가 실제로 있다(맥에서 GUI 앱과 CLI 가 다른 tailscaled 를 볼 때).
        # 그때는 로컬 주소로 낸다 — 형이 주소만 바꿔 건네면 된다.
        from marina_state import HOST, PORT

        base = f"http://{HOST}:{PORT}"
    return f"{base}/login?claim={urllib.parse.quote(username)}"


def run(args: argparse.Namespace) -> int:
    store = _store()
    if args.group == "auth":
        if args.command == "status":
            enabled = store.auth_enabled()
            users = store.list_users()
            active_admins = sum(user.role == "admin" and user.status == "active" for user in users)
            print(f"enabled={'true' if enabled else 'false'}")
            print(f"active-admins={active_admins}")
            print(f"db={store.db_path}")
            return 0
        if args.command == "reset-admin":
            user = store.reset_admin_password(args.username, _password_from_terminal(args.password_stdin))
            _print_user(user)
            return 0
        if not args.yes:
            print("error: auth disable requires --yes", file=sys.stderr)
            return 2
        store.disable_auth()
        print("enabled=false")
        return 0

    if args.command == "list":
        for user in store.list_users():
            _print_user(user)
        return 0
    if args.command == "grant":
        from pathlib import Path

        from marina_access import canonical_root

        user = store.user_by_username(args.username)
        if args.project:
            # **덮어쓰지 않고 더한다** — 한 프로젝트를 주려다 이미 있던 접근을 지우면
            # 다른 방들이 조용히 사라진다.
            이미 = store.project_access_for(user.id)
            store.set_project_access(user.id, sorted(이미 | set(args.project)), actor_user_id=None)
        for root in args.root:
            store.assign_resource_owner("worktree", canonical_root(Path(root).expanduser()),
                                        user.id, actor_user_id=None)
        print(f"user={user.username} projects={sorted(store.project_access_for(user.id))} "
              f"roots={[str(Path(r).expanduser()) for r in args.root]}")
        return 0
    if args.command == "add":
        result = store.add_user(args.username, args.display_name, args.role)
        _print_user(result)
        # **초대 링크를 같이 낸다.** 마리나엔 회원가입이 없다 — 계정은 관리자가 만들고 링크를
        # 건네는 초대 모델이다. 링크 없이는 초대받은 사람이 "있지도 않은 비밀번호"를 아무거나
        # 넣어 오류를 봐야 비밀번호 설정 화면에 닿는다(형 실사용에서 그 단계에서 헤맸다).
        print(f"invite={_invite_url(result.username)}")
        return 0
    elif args.command == "approve":
        result = store.approve_user(args.username)
    elif args.command == "reject":
        result = store.reject_user(args.username)
    elif args.command == "disable":
        result = store.disable_user(args.username)
    else:
        result = store.reset_password(args.username)
    _print_user(result)
    return 0


def main() -> int:
    try:
        return run(parser().parse_args())
    except BrokenPipeError:
        # `marina user add … | grep -q …` 처럼 상대가 먼저 파이프를 닫는 건 정상이다.
        # 그때 죽으면 파이프에 태워 쓰는 쪽이 전부 실패한다(실측: 초대 링크 한 줄을 더 찍자
        # 기존 테스트가 Broken pipe 로 깨졌다). 조용히 끝낸다.
        try:
            os.dup2(os.open(os.devnull, os.O_WRONLY), sys.stdout.fileno())
        except OSError:
            pass
        return 0
    except AuthError as exc:
        print(f"error: {exc.message}", file=sys.stderr)
        return 1
    except (OSError, ValueError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
