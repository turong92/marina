"""런타임 타깃 — 이 워크트리의 컨테이너가 **어느 기계에서** 도는지.

원격(사무실 리눅스 박스)이 로컬과 다른 점은 세 가지뿐이고, 그 셋을 이 모듈에 모은다:

1. compose 가 향할 데몬 (`docker_env`)
2. 바인드 마운트를 풀 수 없다 (`volume_rewrite`) — `--project-directory` 가 빌드컨텍스트·watch 소스는
   *클라이언트*, 바인드 마운트는 *데몬* 에서 푸는 이중 역할이라, 원격이면 개발자 맥의 경로가 박스에 없다.
3. 부팅에 필요한 파일은 기동 **전에** 넣어야 한다 (`injection_plan`) — watch sync 는 *돌고 있는*
   컨테이너에 넣으므로 JVM 은 JAR 이 도착하기 전에 죽는다.

모드 플래그를 코드 곳곳에 흩뿌리는 대신 타깃에 물어보는 형태로 둔다. **로컬 타깃은 전부 지금 동작
(대개 no-op)을 반환하므로 로컬 경로는 물리적으로 바뀌지 않는다.**

설계: docs/superpowers/specs/2026-08-24-remote-runtime-design.md
"""

from __future__ import annotations

import json
import os
import re
import sys
import tempfile
from dataclasses import dataclass, field
from pathlib import Path

CONFIG_NAME = "runtime-target.json"
_VOLUME_PREFIX = "marina"


@dataclass(frozen=True)
class Injection:
    """기동 전에 `docker cp` 로 컨테이너에 넣어야 하는 한 건."""

    service: str
    source: str            # 개발자 머신 기준 경로(compose 표기 그대로)
    target: str            # 컨테이너 안 경로
    volume: str = ""       # 치환된 named volume 이름. 파일 주입은 볼륨이 없어 빈 문자열.


@dataclass(frozen=True)
class Mount:
    """볼륨 하나. **문자열로 합치지 않는다** — `"src:tgt"` 로 합쳐 되쪼개면 경로에 콜론이 있을 때
    엉뚱하게 갈린다(`/p/a: b` → source=`/p/a`). 손실 없는 표현을 그대로 주고받는다."""

    source: str
    target: str
    mode: str = ""


@dataclass
class VolumeRewrite:
    volumes: list                           # 서비스의 `volumes` 최종값 (list[Mount])
    named_volumes: dict[str, None] = field(default_factory=dict)   # top-level `volumes:` 에 선언할 것
    injections: list[Injection] = field(default_factory=list)
    # 입력 mounts 와 **같은 길이**. 각 자리의 최종 Mount, 빠진 것(파일 마운트)은 None.
    # 위치 대응으로 렌더링하면 빠진 자리에서 어긋난다(실제로 StopIteration 으로 터졌다).
    mapping: list = field(default_factory=list)


def _is_host_path(source: str) -> bool:
    """compose volume 의 앞부분이 호스트 경로인가(named volume 이 아닌가).

    compose 규칙: `.` `..` `/` `~` 로 시작하면 호스트 경로, 그 외 문자열은 named volume."""
    return source.startswith((".", "/", "~"))


def _volume_name(service: str, target: str) -> str:
    """서비스+컨테이너 경로로 결정적인 볼륨 이름을 만든다(같은 입력 → 같은 이름 → 재기동에 재사용)."""
    slug = re.sub(r"[^a-z0-9]+", "_", f"{service}_{target}".lower()).strip("_")
    return f"{_VOLUME_PREFIX}_{slug}"


def _looks_like_dir(source: str) -> bool:
    """바인드 소스를 디렉터리로 볼 것인가.

    **파일로 존재할 때만 파일**, 그 외(없는 경로 포함)는 디렉터리로 본다 — 도커가 바인드 소스를
    자동 생성할 때 쓰는 규칙과 같다. 첫 gradle 빌드 전이라 `build/libs` 가 아직 없는 경우가 흔한데,
    그걸 파일로 오판하면 볼륨을 안 만들어 JAR 을 넣을 그릇이 사라진다."""
    return not os.path.isfile(source)


class LocalTarget:
    """지금 동작. 아무것도 바꾸지 않는다."""

    name = "local"
    is_remote = False

    def docker_env(self) -> dict[str, str]:
        return {}

    def volume_rewrite(self, service: str, mounts: list, is_dir_fn=None) -> VolumeRewrite:
        return VolumeRewrite(volumes=list(mounts), mapping=list(mounts))

    def injection_plan(self, per_service_mounts: dict) -> list[Injection]:
        return []


class RemoteTarget:
    """컨테이너가 다른 기계에서 돈다."""

    name = "remote"
    is_remote = True

    def __init__(self, host: str):
        self.host = host

    def docker_env(self) -> dict[str, str]:
        return {"DOCKER_HOST": self.host}

    def volume_rewrite(self, service: str, mounts: list, is_dir_fn=None) -> VolumeRewrite:
        """호스트 경로 바인드를 원격에서 풀 수 있는 형태로 바꾼다.

        **디렉터리**는 named volume 으로 치환한다(내용을 담을 그릇이 필요하다).
        **파일**은 마운트를 아예 없앤다 — named volume 은 디렉터리로 마운트되므로 파일 경로에 얹으면
        도커가 컨테이너 생성을 거부한다(`source /.../.env is not directory`). 파일은 볼륨 없이 컨테이너
        안으로 바로 넣으면 되고(이미지에 이미 그 경로가 있다), 주입 목록엔 그대로 남는다."""
        is_dir_fn = is_dir_fn or _looks_like_dir
        out: list = []
        named: dict[str, None] = {}
        injections: list[Injection] = []
        mapping: list = []
        for m in mounts:
            if not _is_host_path(m.source):
                out.append(m)                        # named volume 등 — 데몬 쪽에 살아서 그대로 둔다
                mapping.append(m)
                continue
            if not is_dir_fn(m.source):              # 파일 — 마운트를 빼고 주입만
                injections.append(Injection(service=service, source=m.source, target=m.target))
                mapping.append(None)
                continue
            vol = _volume_name(service, m.target)
            new = Mount(source=vol, target=m.target, mode=m.mode)
            out.append(new)
            mapping.append(new)
            named[vol] = None
            injections.append(Injection(service=service, source=m.source, target=m.target, volume=vol))
        return VolumeRewrite(volumes=out, named_volumes=named, injections=injections, mapping=mapping)

    def injection_plan(self, per_service_mounts: dict, is_dir_fn=None) -> list[Injection]:
        plan: list[Injection] = []
        for service, mounts in per_service_mounts.items():
            plan.extend(self.volume_rewrite(service, mounts, is_dir_fn).injections)
        return plan


def _read_config(path: Path) -> dict | None:
    """설정 하나를 읽는다. 없거나 깨졌거나 kind 가 없으면 None(= 이 계층은 말을 안 한 것).

    **파일이 있는데 못 읽으면 경고한다.** 조용히 넘기면 원격으로 돌리려던 워크트리가 아무 말 없이
    로컬로 강등돼, 안 돌리려던 노트북에서 스택이 뜬다."""
    if not path.exists():
        return None
    try:
        raw = json.loads(path.read_text(encoding="utf-8"))
    except Exception as exc:
        sys.stderr.write(f"warning: runtime-target 설정을 읽지 못했습니다({path}): {exc} — 로컬로 처리합니다\n")
        return None
    if not isinstance(raw, dict) or not raw.get("kind"):
        sys.stderr.write(f"warning: runtime-target 설정에 kind 가 없습니다({path}) — 로컬로 처리합니다\n")
        return None
    return raw


def load_target(session_dir: str, home: str | None = None):
    """런타임 타깃을 계층으로 해석한다: **전역 기본 < 세션(워크트리) override**.

    - 전역   `<MARINA_HOME>/runtime-target.json` — 박스 주소를 여기 한 번 저장한다.
    - 세션   `<session_dir>/runtime-target.json` — 이 워크트리만 켜고 끈다. 전역을 양방향으로 덮는다.

    세션이 `{"kind":"remote"}` 만 적고 주소를 생략하면 **전역 주소를 물려받는다** — 팀원이 워크트리를
    원격으로 넘길 때 매번 IP 를 칠 일이 없게. 물려받을 주소도 없으면 로컬로 떨어진다: 어디로 가는지
    모르는 채 원격을 시도하는 것이 로컬로 도는 것보다 위험하다."""
    home = home or os.environ.get("MARINA_HOME") or os.path.expanduser("~/.marina")
    g = _read_config(Path(home, CONFIG_NAME)) or {}
    sess = _read_config(Path(session_dir, CONFIG_NAME)) if session_dir else None
    cfg = sess if sess is not None else g                     # 세션이 말했으면 그게 최종(양방향 override)
    if cfg.get("kind") != "remote":
        return LocalTarget()
    host = cfg.get("host") or (g.get("host") if sess is not None else None)   # 세션이 주소 생략 → 전역 물려받기
    if not isinstance(host, str) or not host.strip():
        return LocalTarget()
    return RemoteTarget(host.strip())

_KINDS = ("local", "remote", "inherit")


def write_target(directory: str, kind: str, host: str | None) -> None:
    """한 계층의 설정을 쓴다. `inherit` 는 파일을 **지운다**(= 위 계층을 따른다).

    원자적으로 쓴다 — 중간에 끊겨 반쪽 파일이 남으면 조용히 로컬로 강등된다.

    주소 없는 `remote` 는 **세션 계층에선 정상**이다(전역 주소를 물려받는다). 전역 계층에서만
    무의미하므로, 그 규칙은 계층을 아는 호출부(CLI·API)가 갖는다 — 여기서 막으면 정상 형태를
    표현할 수 없다."""
    if kind not in _KINDS:
        raise ValueError(f"kind 는 {'|'.join(_KINDS)} 중 하나 (받은 값: {kind})")
    path = Path(directory, CONFIG_NAME)
    if kind == "inherit":
        path.unlink(missing_ok=True)
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    data = {"kind": kind, **({"host": host.strip()} if kind == "remote" and (host or "").strip() else {})}
    fd, tmp = tempfile.mkstemp(dir=str(path.parent), prefix="." + CONFIG_NAME + ".")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(data, f, ensure_ascii=False)
            f.write("\n")
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, path)
    except BaseException:
        Path(tmp).unlink(missing_ok=True)
        raise


def describe(session_dir: str, home: str | None = None) -> dict:
    """대시보드가 그대로 그릴 수 있는 상태.

    `scope` 는 **누가 정했는지**다 — session(이 워크트리가 덮음) / global / default(아무도 안 말함).
    UI 가 "이 워크트리만 다르다"를 구분해 보여주고 되돌릴 수 있어야 하므로 globalHost 도 같이 준다."""
    home = home or os.environ.get("MARINA_HOME") or os.path.expanduser("~/.marina")
    g = _read_config(Path(home, CONFIG_NAME)) or {}
    sess = _read_config(Path(session_dir, CONFIG_NAME)) if session_dir else None
    target = load_target(session_dir, home=home)
    scope = "session" if sess is not None else ("global" if g else "default")
    return {
        "kind": "remote" if target.is_remote else "local",
        "host": getattr(target, "host", None) if target.is_remote else None,
        "scope": scope,
        "globalHost": (g.get("host") if g.get("kind") == "remote" else None),
    }


def docker_env_for_root(root) -> dict:
    """워크트리 root → docker 호출에 얹을 env 델타. 로컬이면 `{}`.

    **라우팅 규칙은 여기 한 군데만 산다.** 호출부마다 다시 구현하면 또 빠뜨린다 — 실제로 compose
    수명·메모리·ps 를 따로 고치다 게이트웨이용 ps 를 놓쳤다. docker 를 실행하는 곳은 이걸 쓴다."""
    if not root:
        return {}
    try:
        import marina_paths
        return load_target(str(marina_paths.session_dir(Path(root)))).docker_env()
    except Exception:
        return {}
