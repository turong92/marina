"""원격 박스 "주인 확인" — 같은 이름의 compose 프로젝트가 남의 것이면 건드리지 않는다.

박스는 여러 팀원이 같이 쓰는 docker 데몬이고 compose 프로젝트 이름은 `<project-id>-<워크트리 이름>` 뿐이다.
두 사람이 같은 id·같은 워크트리 이름(예: 둘 다 mdc/main)을 쓰면 이름이 겹쳐, 한 사람의 start·stop·rebuild·삭제 회수가
다른 사람의 컨테이너·볼륨을 재생성하거나 지운다. 이름을 바꾸면 이미 떠 있는 팀원 스택이 붕 뜨므로 이름은 그대로 두고,
원격에서 **만들거나 바꾸거나 지우기 전에** 컨테이너 라벨 `com.docker.compose.project.working_dir`(compose 가 `--project-directory`
로 박아 두는 값)을 내 것과 비교한다.

- 그 이름의 컨테이너(멈춘 것 포함)가 하나도 없으면 내 것(새로 만든다).
- 있으면 모두 내 `--project-directory` 와 같아야 내 것. 하나라도 다르면 남의 것.
- 조회 자체가 실패하면 진행하지 않는다 — 모르면 건드리지 않는다.
- 탈출구: `MARINA_REMOTE_ADOPT=1` (맥을 바꾸거나 폴더를 옮긴 같은 사람의 스택을 이어받을 때). 이 경우 조회도 안 한다.

로컬 타깃에서는 이 모듈을 부르지 않는다(호출부가 원격일 때만 부른다) — 로컬 호출·출력은 바뀌지 않는다.

조회는 `docker ps -a --filter label=…` 한 번이다. marina_compose_svc 의 박스 단위 배치(`_remote_ps_all`)는 폴링용 TTL 캐시라
**쓰기 직전의 최신값**이 필요한 여기엔 맞지 않고(옛 결과로 판정하면 안 된다), ssh 멀티플렉싱 껍데기는 폴링 전용이라
(compose up 의 동시 채널과 섞지 않는다) 쓰지 않는다. 쓰기 명령 한 번에 조회 한 번이다.
"""

from __future__ import annotations

import json
import os
import signal
import subprocess
import tempfile
import time

LABEL_PROJECT = "com.docker.compose.project"
LABEL_WORKDIR = "com.docker.compose.project.working_dir"
ADOPT_ENV = "MARINA_REMOTE_ADOPT"
_TIMEOUT_S = 20
OWNED_FILE = "remote-owned.json"      # 이 워크트리가 그 박스에 스택을 띄운 적이 있다는 기록(세션 폴더 안)
EXIT_FOREIGN = 3                       # 남의 스택 — 호출부(워크트리 삭제)가 "박스에 내 것 없음"으로 읽는다
EXIT_UNVERIFIED = 4                    # 확인 불가(박스 불통 등) — 모르면 건드리지 않는다


class Verdict(object):
    """ok=True 면 진행. reason: none(컨테이너 없음) | mine | adopt | foreign | unreachable."""

    def __init__(self, ok, reason, owner_dir="", detail=""):
        self.ok = ok
        self.reason = reason
        self.owner_dir = owner_dir
        self.detail = detail


def _norm(path):
    path = (path or "").strip()
    return os.path.normpath(path) if path else ""


def box_working_dirs(project_name, env=None, docker_bin="docker", timeout=_TIMEOUT_S):
    """박스에서 그 compose 프로젝트의 컨테이너(멈춘 것 포함)마다 working_dir 라벨 값. 실패는 예외로."""
    argv = [docker_bin, "ps", "-a", "--filter", "label=%s=%s" % (LABEL_PROJECT, project_name),
            "--format", '{{.Label "%s"}}' % LABEL_WORKDIR]
    proc = subprocess.Popen(argv, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                            universal_newlines=True, start_new_session=True)
    try:
        out, err = proc.communicate(timeout=timeout)
    except BaseException:                             # 타임아웃·Ctrl-C 모두 — docker 와 그 자식 ssh 를 프로세스 그룹째 죽인다
        try:
            os.killpg(proc.pid, signal.SIGKILL)
        except OSError:
            pass
        try:
            proc.communicate(timeout=5)
        except Exception:
            pass
        raise
    if proc.returncode != 0:
        raise subprocess.CalledProcessError(proc.returncode, argv, out, err)
    return [line.strip() for line in out.splitlines()]      # 컨테이너 하나당 한 줄(라벨 없으면 빈 줄)


def check(project_name, project_dir, env=None, docker_bin="docker", timeout=_TIMEOUT_S):
    """주인 판정. `env` 는 DOCKER_HOST 가 든 docker 호출용 env(이 안의 MARINA_REMOTE_ADOPT 도 본다)."""
    src = env if env is not None else os.environ
    if (src.get(ADOPT_ENV) or "").strip() == "1":
        return Verdict(True, "adopt")
    try:
        dirs = box_working_dirs(project_name, env, docker_bin, timeout)
    except Exception as exc:
        tail = ""
        if isinstance(exc, subprocess.TimeoutExpired):
            tail = "박스가 %d초 동안 응답하지 않았다" % int(timeout)
        elif isinstance(exc, subprocess.CalledProcessError):
            tail = (exc.stderr or exc.output or "").strip().splitlines()[-1:] or [""]
            tail = tail[0]
        return Verdict(False, "unreachable", detail=tail or str(exc) or exc.__class__.__name__)
    if not dirs:
        return Verdict(True, "none")
    mine = _norm(project_dir)
    for d in dirs:
        if not d or _norm(d) != mine:
            return Verdict(False, "foreign", owner_dir=d or "(알 수 없음 — 라벨 없음)")
    return Verdict(True, "mine")


def message(project_name, verdict, project_dir=""):
    """거부 안내. 무엇이 겹쳤는지 + 해결법 둘."""
    if verdict.reason == "unreachable":
        return ("error: 박스에서 `%s` 의 주인을 확인하지 못해 아무것도 하지 않습니다 (%s).\n"
                "  모르면 건드리지 않습니다. 박스 연결을 확인한 뒤 다시 시도하세요.\n"
                "  정말 내 스택이라면 확인 없이 진행: MARINA_REMOTE_ADOPT=1 marina …"
                % (project_name, verdict.detail))
    return ("error: 박스에 같은 이름 `%s` 의 다른 사람 스택이 있어 아무것도 하지 않습니다.\n"
            "  겹친 프로젝트 이름: %s\n"
            "  상대 폴더(주인): %s\n"
            "  내 폴더: %s\n"
            "  해결: ① 내 워크트리 이름이나 `marina project` id 를 바꿔 이름이 겹치지 않게 한다.\n"
            "        ② 정말 내 스택이면(맥을 바꿨거나 폴더를 옮겼다): MARINA_REMOTE_ADOPT=1 marina …"
            % (project_name, project_name, verdict.owner_dir, project_dir or "(알 수 없음)"))


def status_warning(project_name, verdict):
    return "warning: 박스에 같은 이름 `%s` 의 다른 사람 스택이 있다 — 주인 폴더: %s" % (project_name, verdict.owner_dir)


def exit_code(verdict):
    """거부 종료 코드. 남의 것=3, 확인 불가=4. 진행이면 0."""
    if verdict.ok:
        return 0
    return EXIT_FOREIGN if verdict.reason == "foreign" else EXIT_UNVERIFIED


# ── "이 워크트리가 그 박스에 띄운 적이 있다" 기록 ───────────────────────────────────
# 컨테이너가 0개(상대가 내려 둔 동안)면 라벨로 주인을 알 수 없다. 떠 있는 동안만 주인을 안다 — 그래서 지우는 쪽만
# 보수적으로: 기록이 없으면 회수를 건너뛴다(실패 방향은 누수). up 이 성공하면 남긴다.

def _owned_path(session_dir):
    return os.path.join(str(session_dir), OWNED_FILE)


def write_owned(session_dir, host, project_name):
    """기록을 남긴다(원자적). 실패해도 기동을 깨지 않는다 — 호출부가 예외를 삼킨다."""
    os.makedirs(str(session_dir), exist_ok=True)
    data = {"host": host, "project": project_name, "at": time.strftime("%Y-%m-%dT%H:%M:%S%z")}
    fd, tmp = tempfile.mkstemp(dir=str(session_dir), prefix="." + OWNED_FILE + ".")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(data, f, ensure_ascii=False)
            f.write("\n")
        os.replace(tmp, _owned_path(session_dir))
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def read_owned(session_dir, host, project_name):
    """이 워크트리가 **그 박스에서 그 이름으로** 띄운 기록이 있나."""
    try:
        with open(_owned_path(session_dir), encoding="utf-8") as f:
            d = json.load(f)
    except (OSError, ValueError):
        return False
    return isinstance(d, dict) and d.get("host") == host and d.get("project") == project_name


def volume_exists(project_name, env=None, docker_bin="docker", timeout=_TIMEOUT_S):
    """박스에 그 compose 프로젝트 라벨의 볼륨이 있나. 조회 실패는 False(경고용이라 막지 않는다)."""
    argv = [docker_bin, "volume", "ls", "-q", "--filter", "label=%s=%s" % (LABEL_PROJECT, project_name)]
    try:
        out = subprocess.run(argv, env=env, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                             universal_newlines=True, timeout=timeout, start_new_session=True)
    except Exception:
        return False
    return out.returncode == 0 and bool(out.stdout.strip())


VOLUME_WARNING = "warning: 박스에 같은 이름의 볼륨이 이미 있다 — 다른 사람이 내려 둔 스택일 수 있다 (`%s`)"
