#!/usr/bin/env python3
"""marina chain request|unlimited|stop — 구현 에이전트가 형 말을 듣고 부른다(스펙 6.3).

내가 어느 세션인지는 **프로세스 조상**으로 찾는다: 부모를 따라 올라가 ~/.claude/sessions/<pid>.json 을 가진
claude 를 만난다. 데몬이 그 pid·sid·procStart·워크트리를 다시 확인한다.
"""
from __future__ import annotations

import argparse
import json
import os
import sys
import urllib.request
from pathlib import Path


def find_caller(table: dict, start_pid: int, sessions_dir: Path) -> dict | None:
    from marina_agent_procs import ancestors
    for pid in ancestors(start_pid, table):
        path = sessions_dir / f"{pid}.json"
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            continue
        if data.get("sessionId"):
            return {"pid": pid, "sid": str(data["sessionId"])}
    return None


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="marina chain")
    parser.add_argument("action", choices=["request", "unlimited", "stop"])
    args = parser.parse_args(argv)
    from marina_agent_procs import ps_table
    from marina_state import HOST, PORT
    caller = find_caller(ps_table(), os.getpid(), Path.home() / ".claude" / "sessions")
    if caller is None:
        print("marina chain: Claude 세션 안에서만 쓸 수 있어요", file=sys.stderr)
        return 2
    body = json.dumps({"action": args.action, **caller, "cwd": os.getcwd()}).encode("utf-8")
    req = urllib.request.Request(f"http://{HOST}:{PORT}/api/chain", data=body, method="POST",
                                 headers={"content-type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=15) as resp:
            print(resp.read().decode("utf-8"))
            return 0
    except Exception as exc:
        print(f"marina chain: 데몬에 못 닿았어요 · {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
