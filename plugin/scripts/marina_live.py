"""live(상시 운영) 범위의 순수 로직 — 경로 계산, 레지스트리 읽기, 유닛 내용 생성.

**왜 별 파일인가.** 이 계산들은 도커 없이 테스트할 수 있고, marina-compose.py 는 이미
2600줄이라 더 키우지 않는다. 부작용이 있는 것(docker 호출·유닛 등록)은 marina_live_cli.py
와 marina-live-unit.sh 로 밀어낸다.

**live 는 예약된 세션 이름이다.** marina 의 실행 단위는 (프로젝트, 세션) 쌍이고 세션은
보통 워크트리다. `live` 가 그 자리에 들어가면 compose_project_name(id, "live") 가
`<id>-live` 라는 안정된 프로젝트명을 주고 기존 start/stop/logs 경로가 거의 그대로 재사용된다.
워크트리와 다른 점: 체크아웃을 marina 가 ~/.marina/<id>/live/src 에 ref 로 고정해 만들고
사람이 그 안에서 편집하지 않는다. 워크트리를 지워도 live 는 영향을 받지 않는다.
"""
from __future__ import annotations

import contextlib
import json
import os
import pathlib
import platform
import subprocess
import tempfile

LIVE_SESSION = "live"          # 예약 세션 이름. 다른 값은 받지 않는다.
LIVE_LABEL = "marina.live"     # 값 "1". marina_docker_gc 가 회수 제외 판정에 쓴다.
PROJECT_LABEL = "marina.project"


class LiveConfigError(Exception):
    """사용자에게 그대로 보여줄 한 줄 메시지를 담는다."""


def marina_home() -> pathlib.Path:
    # MARINA_HOME 은 테스트 하네스와 다중 설치가 쓰는 기존 관례다.
    return pathlib.Path(os.environ.get("MARINA_HOME") or (pathlib.Path.home() / ".marina"))


def live_root(project_id: str) -> pathlib.Path:
    return marina_home() / project_id / LIVE_SESSION


def live_src(project_id: str) -> pathlib.Path:
    return live_root(project_id) / "src"


def live_data(project_id: str) -> pathlib.Path:
    return live_root(project_id) / "data"


def live_overlay_path(project_id: str) -> pathlib.Path:
    return live_root(project_id) / "overlay.yml"


def projects_file() -> pathlib.Path:
    return marina_home() / "projects.json"


def load_registry() -> dict:
    """projects.json 원문. marina_registry.load_projects() 를 쓰지 않는 이유: 그쪽은
    알려진 키만 뽑아 담아서 `live` 블록이 사라진다. 여기서는 원문이 필요하다."""
    p = projects_file()
    if not p.exists():
        return {"projects": []}
    try:
        data = json.loads(p.read_text(encoding="utf-8"))
    except Exception as exc:
        raise LiveConfigError(f"{p} 를 읽지 못했다: {exc}")
    return data if isinstance(data, dict) else {"projects": []}


def live_config(registry: dict, project_id: str):
    """프로젝트의 live 블록(+root·composeFile 채움). live 미설정이면 None,
    프로젝트 자체가 없으면 에러.

    'live 미설정' 과 '프로젝트 없음' 을 구분하는 이유: 후자를 None 으로 돌려주면
    오타 난 프로젝트명이 "live 설정이 없다" 로 보여 원인을 못 찾는다.
    """
    for p in (registry or {}).get("projects") or []:
        if p.get("id") != project_id:
            continue
        cfg = p.get("live")
        if not cfg:
            return None
        if not cfg.get("ref"):
            raise LiveConfigError(
                f"'{project_id}' 의 live.ref 가 없다. `marina live pin {project_id} <ref>` 로 "
                f"무엇을 운영할지 먼저 정해라."
            )
        out = dict(cfg)
        out["root"] = p.get("root")
        out.setdefault("composeFile", p.get("composeFile") or "docker-compose.yml")
        return out
    raise LiveConfigError(f"등록된 프로젝트가 아니다: '{project_id}'. `marina project ls` 로 확인해라.")


def _write_registry(data: dict) -> None:
    """원자적 교체 — 중간에 죽어서 projects.json 이 반쯤 쓰이면 marina 전체가 프로젝트를
    못 읽는다(load_projects 는 예외를 먹고 빈 목록을 돌려준다)."""
    p = projects_file()
    p.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=str(p.parent), prefix=".projects-", suffix=".json")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            json.dump(data, fh, ensure_ascii=False, indent=1)
            fh.write("\n")
        os.replace(tmp, str(p))
    except BaseException:
        pathlib.Path(tmp).unlink(missing_ok=True)
        raise


def pin_ref(project_id: str, ref: str) -> dict:
    """무엇을 운영할지 정한다. 배포도 롤백도 이 값을 바꾸는 일이다.

    기동하지 않는다 — `marina live pin` 과 `marina live up` 을 쪼개 둔 이유는, 배포가
    '정하기' 와 '적용하기' 두 단계로 보여야 롤백이 같은 모양이 되기 때문이다.
    """
    if not ref:
        raise LiveConfigError("ref 가 비었다. 태그·브랜치·커밋 중 하나를 줘라.")
    data = load_registry()
    for p in data.get("projects") or []:
        if p.get("id") != project_id:
            continue
        block = dict(p.get("live") or {})
        block["ref"] = ref
        p["live"] = block
        _write_registry(data)
        return block
    raise LiveConfigError(f"등록된 프로젝트가 아니다: '{project_id}'. `marina project ls` 로 확인해라.")
