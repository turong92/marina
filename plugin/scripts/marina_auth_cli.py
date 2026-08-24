#!/usr/bin/env python3
"""Local recovery and user administration commands for Marina auth."""
from __future__ import annotations

import argparse
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
    except AuthError as exc:
        print(f"error: {exc.message}", file=sys.stderr)
        return 1
    except (OSError, ValueError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
