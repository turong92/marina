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
import fcntl
import json
import os
import pathlib
import platform
import re
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


# 프로젝트 id 는 경로 조각(~/.marina/<id>/live)이자 docker·git·launchd 인자로 들어간다.
# 모양을 여기서 한 번 막는다 — '../' 하나로 ~/.marina 밖을 가리키고, 공백·따옴표는 유닛
# 파일(systemd ini 는 인용이 없다)과 셸 eval 에서 인자를 쪼갠다.
_ID_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$")


def check_project_id(project_id: str) -> str:
    pid = str(project_id or "")
    if not _ID_RE.match(pid) or pid in (".", "..") or ".." in pid:
        raise LiveConfigError(
            f"프로젝트 id 로 쓸 수 없는 값이다: {pid!r}. 영문·숫자로 시작하고 "
            f"영문·숫자·'.'·'_'·'-' 만 쓴다(64자 이내) — id 는 경로 조각이자 docker·git·"
            f"systemd 실행 인자로 들어간다.\n"
            f"  id 는 `marina project add` 가 디렉터리 이름에서 그대로 따 오므로, 한글·공백이 "
            f"들어간 디렉터리면 이렇게 된다. {projects_file()} 의 그 프로젝트 \"id\" 를 "
            f"쓸 수 있는 값으로 고치거나 다른 id 로 다시 등록해라(워크트리·서비스는 그대로다)."
        )
    return pid


def live_root(project_id: str) -> pathlib.Path:
    return marina_home() / check_project_id(project_id) / LIVE_SESSION


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


# ── ref 고정 체크아웃 ─────────────────────────────────────────────────────────
def _git(run, cwd, *args, **kw):
    what = kw.pop("what")
    r = run(["git", "-C", str(cwd), *args], capture_output=True, text=True)
    if r.returncode != 0:
        raise LiveConfigError(f"{what} 실패: {(r.stderr or r.stdout or '').strip()}")
    return (r.stdout or "").strip()


@contextlib.contextmanager
def src_lock(project_id: str):
    """같은 프로젝트의 live 조작을 직렬화한다 — `git worktree add`·하드 리셋·compose
    up/down·유닛 설치가 겹치면 반쯤 적용된 상태가 남는다.

    **pid 파일이 아니라 flock 이다.** pid 파일 방식은 두 가지로 틀렸다:
    ① 비정상 종료가 남긴 파일이 영구히 막아 재부팅 후 launchd 가 매번 잠금에 걸린다,
    ② 파일을 만든 뒤 pid 를 쓰기까지의 창에 다른 프로세스가 빈 내용을 '낡음' 으로 보고
    **살아 있는 잠금을 탈취**한다(그 창이 바로 잠금이 막으려던 동시 시작이다).
    flock 은 프로세스가 죽으면 커널이 풀어 주므로 두 문제가 함께 사라진다.
    같은 레포의 `RemoteController._mutation_lock` 이 쓰는 방식과 같다.
    """
    root = live_root(project_id)
    root.mkdir(parents=True, exist_ok=True)
    lock = root / ".lock"
    fd = os.open(str(lock), os.O_CREAT | os.O_RDWR, 0o600)
    try:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            raise LiveConfigError(
                f"'{project_id}' 의 live 작업이 이미 돌고 있다(잠금 {lock}). 끝나기를 "
                f"기다려라 — 자동 기동 유닛이 돌고 있을 수도 있다."
            )
        try:
            os.truncate(fd, 0)
            os.write(fd, str(os.getpid()).encode())   # 누가 쥐고 있는지 보기 위한 기록일 뿐
        except OSError:
            pass
        try:
            yield
        finally:
            fcntl.flock(fd, fcntl.LOCK_UN)
    finally:
        os.close(fd)
        # 파일은 **지우지 않는다** — 지우면 다른 프로세스가 이미 열어 둔 잠금과 다른
        # inode 를 쥐게 되어 둘이 동시에 들어온다.


def sync_src(project_root: str, project_id: str, ref: str, run=subprocess.run) -> pathlib.Path:
    """live/src 를 ref 에 맞춘다. clone 이 아니라 `git worktree` 를 쓴다 —
    attach-detached-subrepos.sh 가 외부 레포에 쓰는 것과 같은 관례이고, 네트워크 없이
    되고 원격이 없는 로컬 전용 프로젝트에서도 된다.

    실패하면 기존 체크아웃을 **건드리지 않는다** — 돌고 있는 서비스의 소스를 날리지 않기
    위해서다(브랜치 force-push·태그 삭제로 ref 가 사라진 경우가 이 경로다).
    """
    src = live_src(project_id)
    if not ref:
        raise LiveConfigError(f"'{project_id}' 의 live.ref 가 비었다.")
    root = pathlib.Path(project_root or "")
    if not (root / ".git").exists():
        raise LiveConfigError(f"git 레포가 아니다: {project_root}. live 체크아웃은 git ref 로만 고정한다.")

    if (src / ".git").exists():
        # 기존 워크트리는 원격을 먼저 당긴다 — 브랜치 ref 가 움직였으면 그 뒤에 풀어야 한다.
        # **실패는 치명적이지 않다**: 재부팅 직후 유닛이 Wi-Fi 보다 먼저 돌거나 원격이
        # 사라진 레포에서, 로컬에 이미 있는 ref 로도 기동은 돼야 한다. 막으면 서비스 복귀가
        # 네트워크에 묶이고 최악에는 영구히 안 뜨면서 unit.log 만 커진다.
        try:
            _git(run, src, "fetch", "--all", "--tags", "--quiet", what="fetch")
        except LiveConfigError as exc:
            print(f"경고: {exc} — 로컬에 있는 ref 로 계속한다(원격이 움직였으면 반영되지 않는다).",
                  file=__import__("sys").stderr)

    # ref 가 실재하는지 **먼저** 확인하고 커밋 SHA 로 바꾼다. 두 이유가 있다.
    # ① 확인을 먼저 해야 아래에서 트리를 망친 뒤 실패하지 않는다(force-push 경로).
    # ② live/src 는 detached 라 거기서 'HEAD'·'main' 을 풀면 **이전 기동 시점**을 가리킨다.
    #    ref 는 항상 프로젝트 레포에서 풀고, 워크트리에는 풀린 SHA 를 준다.
    sha = _git(run, root, "rev-parse", "--verify", f"{ref}^{{commit}}",
               what=f"ref '{ref}' 확인")
    if not sha:
        raise LiveConfigError(f"ref '{ref}' 를 커밋으로 풀지 못했다.")

    if (src / ".git").exists():
        # 사람이 편집하는 곳이 아니라 하드 리셋이 안전하다.
        _git(run, src, "checkout", "--detach", "--force", sha, what=f"'{ref}' 체크아웃")
        _git(run, src, "reset", "--hard", "--quiet", sha, what="하드 리셋")
        _git(run, src, "clean", "-fdq", what="clean")
    else:
        src.parent.mkdir(parents=True, exist_ok=True)
        # src 를 손으로 지웠으면 레포에는 등록만 남아 add 가 '이미 등록됨' 으로 거부한다.
        _git(run, root, "worktree", "prune", what="stale worktree 정리")
        _git(run, root, "worktree", "add", "--detach", "--force", str(src), sha,
             what=f"live 체크아웃 생성({ref})")
    return src


# ── 기동 전 검사 ──────────────────────────────────────────────────────────────
def validate_services(compose_config: dict, wanted) -> None:
    """live.services 가 compose 에 실재하는지. compose 는 모르는 서비스 이름을 조용히
    무시하므로 여기서 막지 않으면 '떴다는데 아무것도 없다' 가 된다."""
    if not wanted:
        raise LiveConfigError(
            "live.services 가 비어 있다. 운영에 띄울 서비스를 명시해라 — 비워 두면 "
            "개발용 보조 서비스(mailpit 등)까지 운영에 끌려온다."
        )
    have = set((compose_config or {}).get("services") or {})
    missing = [s for s in wanted if s not in have]
    if missing:
        raise LiveConfigError(
            f"compose 에 없는 서비스다: {', '.join(missing)}. "
            f"있는 것: {', '.join(sorted(have)) or '(없음)'}"
        )


def ensure_data_dir(project_id: str) -> pathlib.Path:
    """도커는 바인드 마운트 소스를 자동 생성하지 않는다(Docker Desktop 은 거부한다).
    없으면 첫 기동이 'bind source path does not exist' 로 깨진다 — 홈서버 구현에서 실측."""
    d = live_data(project_id)
    d.mkdir(parents=True, exist_ok=True)
    return d


# ── 부팅 지속성 유닛 ──────────────────────────────────────────────────────────
DEFAULT_UNIT_PATH = "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
UNIT_RETRY_SECONDS = 10     # 도커 데몬이 뜰 때까지 재시도하는 간격
# 재시도는 **무한**이다(launchd KeepAlive·systemd Restart=on-failure). 설계는 "유한 횟수
# 재시도하고 한도를 넘으면 실패를 로그에 남긴다" 였는데, 유한으로 두면 도커 데몬이 늦게
# 뜨는 기계에서 서비스가 영구히 안 뜬다 — 운영에서는 '계속 시도' 가 '포기' 보다 낫다.
# 대신 매 시도의 실패가 unit.log 에 쌓이므로 원인은 남는다(`marina live status` 가 그
# 경로를 알려준다). 설계와 다른 선택이라 여기 적어 둔다.


def unit_path(project_id: str) -> pathlib.Path:
    ext = "plist" if platform.system() == "Darwin" else "service"
    return live_root(project_id) / f"unit.{ext}"


def unit_label(project_id: str) -> str:
    return f"dev.marina.live.{project_id}"


def unit_env_path() -> str:
    """유닛에 넣을 PATH. launchd 는 최소 PATH(/usr/bin:/bin:/usr/sbin:/sbin) 만 주므로
    docker 를 못 찾아 "재부팅했는데 서비스가 없다" 가 된다 — marina-dashboard.sh 가
    DAEMON_PATH 로 같은 문제를 다룬다."""
    return os.environ.get("PATH") or DEFAULT_UNIT_PATH


def _xml(value) -> str:
    return (str(value).replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;"))


def plist_body(project_id: str, marina_bin: str) -> str:
    """launchd 유닛. RunAtLoad 로 로그인 시 기동하고, KeepAlive(SuccessfulExit=false)로
    도커 데몬이 아직 안 떴을 때 재시도한다. 유닛은 로직을 복제하지 않고 `marina live up`
    을 그대로 재실행한다 — 복제하면 두 경로가 갈라진다."""
    root = live_root(project_id)
    return f"""<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>{_xml(unit_label(project_id))}</string>
  <key>ProgramArguments</key>
  <array>
    <string>{_xml(marina_bin)}</string>
    <string>live</string>
    <string>up</string>
    <string>{_xml(project_id)}</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key>
    <string>{_xml(unit_env_path())}</string>
    <key>MARINA_HOME</key>
    <string>{_xml(marina_home())}</string>
    <key>PYTHONUNBUFFERED</key>
    <string>1</string>
  </dict>
  <key>StandardOutPath</key>
  <string>{_xml(root / "unit.log")}</string>
  <key>StandardErrorPath</key>
  <string>{_xml(root / "unit.log")}</string>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <dict>
    <key>SuccessfulExit</key>
    <false/>
  </dict>
  <key>ThrottleInterval</key>
  <integer>{UNIT_RETRY_SECONDS}</integer>
</dict>
</plist>
"""


def systemd_body(project_id: str, marina_bin: str) -> str:
    """systemd user unit. `loginctl enable-linger` 가 없으면 로그아웃과 함께 죽는다 —
    marina-dashboard.sh:273 이 이미 그 호출을 하고, 설치 스크립트가 같이 호출한다."""
    return f"""[Unit]
Description=marina live stack for {project_id}
After=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart={marina_bin} live up {project_id}
ExecStop={marina_bin} live down {project_id}
Restart=on-failure
RestartSec={UNIT_RETRY_SECONDS}
Environment=PATH={unit_env_path()}
Environment=MARINA_HOME={marina_home()}
Environment=PYTHONUNBUFFERED=1
StandardOutput=append:{live_root(project_id) / "unit.log"}
StandardError=append:{live_root(project_id) / "unit.log"}

[Install]
WantedBy=default.target
"""


def autostart_state(project_id: str, run=subprocess.run) -> dict:
    """재부팅 후 자동 기동이 **정말** 등록돼 있나.

    유닛 파일 존재만 보면 안 된다 — 그 파일은 marina 자신이 방금 썼고, 그 뒤의
    `launchctl bootstrap` 이 실패해도 파일은 남는다. 그러면 "등록됨" 초록불이 켜진 채
    재부팅하면 서비스가 없다. 설계가 "유닛 설치가 실패해도 기동은 유지되므로 이 줄이
    유일한 신호다" 라고 못 박은 줄이라, 거짓말을 하면 기능 자체가 무의미해진다.

    그래서 **감독자(launchd/systemd)에게 직접 묻는다.**
    """
    unit = unit_path(project_id)
    label = unit_label(project_id)
    out = {"registered": False, "how": "", "detail": "", "unit": str(unit),
           "unitFile": unit.exists()}
    home = pathlib.Path(os.path.expanduser("~"))
    if marina_home() != home / ".marina":
        out["detail"] = (f"MARINA_HOME 이 {home / '.marina'} 가 아니라 기계 등록을 생략했다 "
                         f"— 이 홈에서는 재부팅 자동 기동이 없다")
        return out
    if not unit.exists():
        out["detail"] = "유닛 파일이 없다"
        return out
    if platform.system() == "Darwin":
        out["how"] = "launchd"
        login_plist = home / "Library" / "LaunchAgents" / f"{label}.plist"
        if not login_plist.exists():
            out["detail"] = (f"{login_plist} 가 없다 — launchctl bootstrap 은 이번 로그인 "
                             f"세션에만 등록된다. 이 파일이 없으면 재부팅을 못 넘긴다")
            return out
        r = run(["launchctl", "print", f"gui/{os.getuid()}/{label}"],
                capture_output=True, text=True)
        if getattr(r, "returncode", 1) != 0:
            out["detail"] = f"launchd 에 등록되지 않았다 ({label})"
            return out
        out["registered"] = True
        out["detail"] = str(login_plist)
        return out
    out["how"] = "systemd"
    r = run(["systemctl", "--user", "is-enabled", f"{label}.service"],
            capture_output=True, text=True)
    if getattr(r, "returncode", 1) != 0:
        out["detail"] = f"systemd user unit 이 enable 되지 않았다 ({label}.service)"
        return out
    out["registered"] = True
    out["detail"] = f"{label}.service"
    return out


def write_unit(project_id: str, marina_bin: str) -> pathlib.Path:
    """유닛 파일을 쓴다. 멱등 — 같은 입력이면 같은 내용이다."""
    p = unit_path(project_id)
    p.parent.mkdir(parents=True, exist_ok=True)
    body = plist_body(project_id, marina_bin) if platform.system() == "Darwin" \
        else systemd_body(project_id, marina_bin)
    p.write_text(body, encoding="utf-8")
    return p


# ── 게이트웨이 등록 ───────────────────────────────────────────────────────────
# live 도 로컬 게이트웨이에 `live.<프로젝트>.localhost` 로 올린다. 공개(L2)와는 다른
# 용도다 — 공개가 꺼져 있어도 개발자는 게이트웨이로 들어가야 하고, 공개를 해제해도 이
# 주소는 계속 살아 있어야 한다.
def live_service_ports(project_id: str, run=subprocess.run) -> dict:
    """{서비스명: 호스트포트} — 실행 중인 live 컨테이너가 실제로 게시한 포트.

    선언 포트를 쓰지 않고 실측하는 이유: 게이트웨이는 **지금 닿는 곳**으로 보내야 한다.
    안 뜬 서비스로 보내면 죽은 컨테이너로 프록시하게 된다(게이트웨이의 기존 running 규칙과 같다).
    """
    r = run(["docker", "ps",
             "--filter", f"label={LIVE_LABEL}=1",
             "--filter", f"label={PROJECT_LABEL}={project_id}",
             "--format", '{{.Label "com.docker.compose.service"}}\t{{.Ports}}'],
            capture_output=True, text=True)
    out = {}
    if getattr(r, "returncode", 1) != 0:
        return out
    for line in (getattr(r, "stdout", "") or "").splitlines():
        if "\t" not in line:
            continue
        svc, ports = line.split("\t", 1)
        svc = svc.strip()
        if not svc:
            continue
        for chunk in ports.split(","):
            chunk = chunk.strip()
            if "->" not in chunk:
                continue
            left = chunk.split("->", 1)[0]
            host = left.rsplit(":", 1)[-1]
            if host.isdigit():
                out.setdefault(svc, int(host))
                break
    return out


def classify_binds(binds, project_id: str) -> list:
    """compose 의 바인드 마운트가 **어디로 풀리는지** 구분한다.

    live 는 `--project-directory` 를 `~/.marina/<id>/live` 로 주므로 상대 경로의 기준이
    워크트리가 아니라 그곳이다. 그래서 `./src` 는 **체크아웃(live/src) 자신**을 가리키고
    `./data/x` 는 `live/data/x` 를 가리킨다. 전자는 다음 기동의 하드 리셋에 날아가지만
    후자는 사용자의 데이터다 — 둘을 같은 문구로 경고하면 사용자가 경고를 무시하게 된다.
    """
    root, src, data = live_root(project_id), live_src(project_id), live_data(project_id)
    out = []
    for b in (binds or []):
        raw = str(b).split(":", 1)[0]
        resolved = pathlib.Path(raw) if os.path.isabs(raw) else (root / raw)
        resolved = pathlib.Path(os.path.normpath(str(resolved)))
        def _under(parent):
            try:
                resolved.relative_to(parent)
                return True
            except ValueError:
                return False
        out.append({"bind": str(b), "resolved": str(resolved),
                    "in_checkout": _under(src), "in_data": _under(data),
                    "in_live": _under(root)})
    return out


def live_containers(project_id: str, remote=None, run=subprocess.run) -> list:
    """live 컨테이너들 — [{name, service, state, restarts}]. 라벨로 찾는다(프로젝트명이 아니라)
    — 라벨은 overlay 가 붙이는 marina 의 표식이고 GC 면제도 같은 라벨을 본다.

    한 곳에만 둔다: CLI status 와 대시보드 API 가 **같은 신호**를 봐야 "CLI 는 떴다는데
    대시보드는 아니다" 가 안 생긴다.
    """
    pre = ["docker"] + (["-H", remote] if remote else [])
    r = run(pre + ["ps", "-a",
                   "--filter", f"label={LIVE_LABEL}=1",
                   "--filter", f"label={PROJECT_LABEL}={project_id}",
                   "--format", '{{.Names}}	{{.Label "com.docker.compose.service"}}'],
            capture_output=True, text=True)
    rows = []
    if getattr(r, "returncode", 1) != 0:
        return rows
    for line in (getattr(r, "stdout", "") or "").splitlines():
        if not line.strip():
            continue
        parts = line.split("	")
        name = parts[0].strip()
        if not name:
            continue
        svc = parts[1].strip() if len(parts) > 1 else ""
        ins = run(pre + ["inspect", name, "--format", "{{.State.Status}}	{{.RestartCount}}"],
                  capture_output=True, text=True)
        got = (getattr(ins, "stdout", "") or "").strip().split("	")
        rows.append({"name": name, "service": svc,
                     "state": got[0] if got and got[0] else "?",
                     "restarts": int(got[1]) if len(got) > 1 and got[1].isdigit() else 0})
    return sorted(rows, key=lambda x: x["name"])


def live_gateway_entry(project_id: str, ports: dict, primary: str = "") -> dict:
    """게이트웨이 스냅샷 항목. 워크트리 id 자리에 예약어 'live' 를 넣어
    `live.<프로젝트>.localhost` 가 되게 한다 — 워크트리와 한눈에 구분된다."""
    return {
        "id": LIVE_SESSION,
        "projectId": project_id,
        "primary": primary or "",
        "services": [{"service": s, "port": ports[s], "running": True, "routes": [],
                      "cors": False, "corsConsumers": []}
                     for s in sorted(ports)],
    }
