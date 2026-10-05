"""`marina live` 서브커맨드의 인자 파싱과 부작용. 순수 로직은 marina_live.py 에 있다.

여기 있는 것: 레지스트리 읽기, docker compose 호출, 유닛 설치 호출, 출력 문구.
여기 없는 것: 경로 계산·레지스트리 해석·유닛 내용 — 그건 marina_live.py 가 정한다.
"""
from __future__ import annotations

import importlib.util
import os
import pathlib
import subprocess
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import marina_live as L     # noqa: E402

_HERE = pathlib.Path(__file__).resolve().parent
_MC = None


def mc():
    """marina-compose.py 재사용 — 파일명에 하이픈이 있어 import 문을 못 쓴다.
    같은 모듈을 쓰는 이유: live 와 개발이 서로 다른 compose 해석을 갖지 않게 한다."""
    global _MC
    if _MC is None:
        spec = importlib.util.spec_from_file_location("marina_compose", str(_HERE / "marina-compose.py"))
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        _MC = mod
    return _MC


USAGE = """사용법:
  marina live up <프로젝트>         # 운영 스택 기동 (재부팅 후 자동 기동 포함)
  marina live down <프로젝트>       # 정지 + 자동 기동 해제
  marina live status [<프로젝트>]   # 상태·주소·데이터 경로·자동 기동 여부
  marina live logs <프로젝트> [서비스]
  marina live restart <프로젝트> <서비스>
  marina live pin <프로젝트> <ref>  # 무엇을 운영할지 정한다 (배포 = 이걸 바꾸는 일)
"""

SUBS = ("up", "down", "status", "logs", "restart", "pin")


def _need_cfg(project_id: str, sub: str):
    cfg = L.live_config(L.load_registry(), project_id)
    if cfg is None:
        raise L.LiveConfigError(
            f"'{project_id}' 에 live 설정이 없다. `marina live pin {project_id} <ref>` 먼저."
        )
    return cfg


def cmd_pin(argv) -> int:
    if len(argv) < 2:
        print("사용법: marina live pin <프로젝트> <ref>", file=sys.stderr)
        return 2
    block = L.pin_ref(argv[0], argv[1])
    print(f"live ref 고정: {argv[0]} → {block['ref']}")
    if not block.get("services"):
        print("  주의: live.services 가 비어 있다 — `marina live up` 은 거부한다. "
              "운영에 띄울 서비스를 projects.json 의 live.services 에 적어라.", file=sys.stderr)
    else:
        print(f"  적용: marina live up {argv[0]}")
    return 0


def main(argv) -> int:
    if not argv or argv[0] not in SUBS:
        sys.stdout.write(USAGE)
        return 2
    sub, rest = argv[0], argv[1:]
    if sub == "status" and not rest:
        rest = [""]                       # status 는 프로젝트 생략 = 전체
    if not rest or not rest[0]:
        if sub != "status":
            print(f"프로젝트명이 필요하다.\n{USAGE}", file=sys.stderr)
            return 2
    try:
        if sub == "pin":
            return cmd_pin(rest)
        project_id = rest[0]
        cfg = _need_cfg(project_id, sub)
        print(f"[live {sub}] {project_id} ref={cfg.get('ref')}")
        return 0
    except L.LiveConfigError as exc:
        print(str(exc), file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
