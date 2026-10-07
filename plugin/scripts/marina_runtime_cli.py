#!/usr/bin/env python3
"""marina runtime — 컨테이너를 어느 기계에서 돌릴지(런타임 타깃) 고르고 본다.

    marina runtime use [<ssh://user@host>]   원격으로. 주소를 생략하면 아래 계층의 주소를 물려받는다.
    marina runtime local                     그 계층을 로컬로 고정한다(옛 `remote off`).
    marina runtime inherit                   그 계층의 설정을 지운다 → 아래 계층을 따른다.
    marina runtime status                    지금 어디서 도나 + 어느 계층이 정했나 + 각 계층 값.

계층은 **전역 < 프로젝트 < 세션(워크트리)** 이고 위가 아래를 덮는다. 계층 고르기:
    (기본)                 이 워크트리(세션)
    --project [<id>]       프로젝트 — id 생략 시 현재 워크트리의 프로젝트
    --global               전역

해석·쓰기는 marina_runtime_target 한 곳(load_target / write_target)에 있다. 여기는 입출력만 한다.
`marina remote …` 는 Tailscale funnel 도구라 이 명령과 무관하다(옛 `remote use` 가 여기로 옮겨 왔다).
"""
from __future__ import annotations

import os
import subprocess
import sys
from pathlib import Path

import marina_runtime_target as rt

USAGE = "usage: marina runtime {use [<ssh://user@host>] | local | inherit | status} [--global | --project [<id>]]"
_KIND = {"use": "remote", "local": "local", "inherit": "inherit"}
_SUBS = ("use", "local", "inherit", "status", "env")


class CliError(Exception):
    pass


def _parse(argv: list[str]) -> dict:
    out = {"sub": "status", "host": None, "scope": "session", "project": None, "root": None}
    rest = list(argv)
    if "-h" in rest or "--help" in rest:
        out["help"] = True
        return out
    if "--root" in rest and rest.index("--root") + 1 < len(rest):   # 런처가 맨 앞에 붙이는 옵션 — 하위 명령 앞이라 먼저 뗀다
        i = rest.index("--root")
        out["root"] = rest[i + 1]
        del rest[i:i + 2]
    if rest and not rest[0].startswith("-"):
        out["sub"] = rest.pop(0)
    if out["sub"] not in _SUBS:
        raise CliError(f"알 수 없는 명령: {out['sub']}\n{USAGE}")
    scope_flags = 0
    i = 0
    while i < len(rest):
        a = rest[i]
        if a == "--global":
            out["scope"] = "global"; scope_flags += 1
        elif a == "--project":
            out["scope"] = "project"; scope_flags += 1
            # id 는 선택. 다음 토큰이 옵션도 주소(://)도 아니면 id.
            if i + 1 < len(rest) and not rest[i + 1].startswith("-") and "://" not in rest[i + 1]:
                i += 1
                out["project"] = rest[i]
        elif a.startswith("-"):
            raise CliError(f"알 수 없는 옵션 {a}\n{USAGE}")
        elif out["host"] is None:
            out["host"] = a
        else:
            raise CliError(f"인자가 너무 많다: {a}\n{USAGE}")
        i += 1
    if scope_flags > 1:
        raise CliError("--global 과 --project 는 함께 쓸 수 없다")
    if out["host"] is not None and out["sub"] != "use":
        raise CliError(f"주소는 use 에서만 받는다 (받은 값: {out['host']})")
    return out


def _root(opt: str | None) -> Path | None:
    raw = opt or os.environ.get("ROOT")
    if not raw:
        try:
            raw = subprocess.check_output(["git", "rev-parse", "--show-toplevel"], text=True,
                                          stderr=subprocess.DEVNULL).strip()
        except Exception:
            return None
    return Path(raw).expanduser().resolve() if raw else None


def _require_registered(root: Path | None) -> dict:
    """세션 범위·id 생략 --project 는 **등록된 프로젝트 안**에서만. 등록이 하나뿐일 때의 폴백
    (project_for)을 쓰면 무관한 폴더에서 그 프로젝트의 설정을 바꾸게 되므로 containing_project_for 를 쓴다."""
    import marina_registry
    project = marina_registry.containing_project_for(root) if root else None
    if not project:
        raise CliError("등록된 프로젝트 안이 아니다 — 프로젝트 워크트리에서 실행하거나 --project <id> · --global 을 주라")
    return project


def _project_id(opts: dict, root: Path | None) -> str:
    """--project 의 id. 명시 id 는 등록된 프로젝트여야 한다(오타가 조용히 새 폴더를 만들면 안 된다)."""
    import marina_registry
    if opts["project"]:
        known = [p["id"] for p in marina_registry.load_projects()]
        if opts["project"] not in known:
            raise CliError(f"등록되지 않은 프로젝트: {opts['project']} (등록된 것: {', '.join(known) or '없음'})")
        return opts["project"]
    return str(_require_registered(root)["id"])


def _fmt(cfg: dict | None, inherited: str | None) -> str:
    if cfg is None:
        return "(없음)"
    if cfg.get("kind") != "remote":
        return "로컬 고정"
    if cfg.get("host"):
        return f"원격 {cfg['host']}"
    return f"원격 (주소 없음 → {inherited} 물려받음)" if inherited else "원격 (주소 없음 — 물려받을 주소도 없어 로컬로 동작)"


def _status(opts: dict, root: Path | None, home: str) -> int:
    import marina_paths
    scope = opts["scope"]
    sess, pid = "", None
    if scope == "project":
        pid = _project_id(opts, root)
    elif scope == "session":
        _require_registered(root)
        pid = rt.project_id_for_root(root)
        sess = str(marina_paths.session_dir(root))
    ly = rt.layers(sess, home=home, project_id=pid)        # 한 번만 읽는다 — 깨진 설정 경고가 두 번 나오지 않게
    d = rt.describe_layers(ly)
    name = {"session": "세션", "project": f"프로젝트({pid})", "global": "전역", "default": "없음 — 기본값"}[d["scope"]]
    print(f"런타임: 원격 ({d['host']})" if d["kind"] == "remote" else "런타임: 로컬")
    print(f"정한 계층: {name}")
    if scope == "session":
        print(f"  세션   : {_fmt(ly['session'], rt.inherited_host(ly, 'session'))}")
    if scope in ("session", "project"):
        print(f"  프로젝트: {_fmt(ly['project'], rt.inherited_host(ly, 'project')) if pid else '(알 수 없음)'}")
    print(f"  전역   : {_fmt(ly['global'], None)}")
    return 0


def _env(root: Path | None) -> int:
    """셸이 source 할 docker env 줄(`DOCKER_HOST=…`). 로컬이면 아무것도 안 낸다 — 셸 쪽 호출이 한 글자도 안 바뀐다."""
    for k, v in sorted(rt.docker_env_for_root(root).items()):
        print(f"{k}={v}")
    return 0


def _write(opts: dict, root: Path | None, home: str) -> int:
    import marina_paths
    sub, scope, host = opts["sub"], opts["scope"], opts["host"]
    if sub == "use" and host is not None and not (host.startswith("ssh://") and len(host) > len("ssh://")):
        raise CliError(f"박스 주소는 ssh://user@host 형식이어야 한다 (받은 값: {host})")
    try:
        if scope == "global":
            directory, label, pid = home, "전역", None
        elif scope == "project":
            pid = _project_id(opts, root)
            directory, label = rt.project_dir(pid, home), f"프로젝트 {pid}"
        else:
            project = _require_registered(root)
            pid = str(project["id"])
            directory, label = str(marina_paths.session_dir(root)), "이 워크트리"
    except ValueError as e:
        raise CliError(str(e))
    if sub == "use" and host is None:
        # 주소 없는 remote 는 아래 계층에서 주소를 물려받을 때만 의미가 있다. 못 물려받으면 해석 결과가 로컬이라
        # "→ 원격" 을 찍고 실제론 로컬로 도는 거짓말이 된다 — 쓰기 전에 막는다.
        ly = rt.layers("", home=home, project_id=pid)
        if scope == "global" or rt.inherited_host(ly, scope) is None:
            raise CliError("박스 주소가 없다 — `marina runtime use ssh://… --project` 처럼 주소를 주거나 전역에 먼저 저장하라"
                           " (`marina runtime use ssh://… --global`)")
    try:
        rt.write_target(directory, _KIND[sub], host)
    except ValueError as e:
        raise CliError(str(e))
    if sub == "use":
        print(f"runtime: {label} → 원격{f' ({host})' if host else ''}")
    elif sub == "local":
        print(f"runtime: {label} → 로컬 고정")
    else:
        print(f"runtime: {label} 설정 제거 → 아래 계층을 따름")
    if sub != "inherit":
        print("  (이미 도는 컨테이너는 원래 기계에 남는다 — 바꾸기 전에 marina stop --all)")
    return 0


def main(argv: list[str] | None = None) -> int:
    argv = list(sys.argv[1:] if argv is None else argv)
    try:
        opts = _parse(argv)
        if opts.get("help"):
            print(USAGE)
            return 0
        root = _root(opts["root"])
        home = os.environ.get("MARINA_HOME") or os.path.expanduser("~/.marina")
        if opts["sub"] == "env":
            return _env(root)
        return _status(opts, root, home) if opts["sub"] == "status" else _write(opts, root, home)
    except CliError as e:
        sys.stderr.write(f"error: {e}\n")
        return 2


if __name__ == "__main__":
    sys.exit(main())
