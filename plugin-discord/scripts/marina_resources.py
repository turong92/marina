"""방별 자원(CPU·메모리) 상위 — #상태 꼬리말용 (형 2026-11-06 "상태 채널에 자원 얼마나 쳐먹나 찍어 줄 수 있어?").

측정은 한 판에 ps 1·tmux 1·lsof 1·docker 1 회. 실패는 조용히 빈 값. docker stats 가 ~2초라 뒤 스레드에서 60초마다 읽고
그리기는 캐시만 본다.

귀속 규칙
- 방 tmux 세션의 pane 프로세스와 그 자손 전부 = 그 방(claude·flutter·node 등).
- 부모가 1 인 java(GradleDaemon·코틀린 컴파일 데몬)는 cwd 로 — 방 root 하위(또는 그 방 scratchpad 하위)면 그 방, 아니면 공용.
- 도커 컨테이너는 이름 접두사 `<project>-<root 폴더 이름>-` 로. 주인을 모르면 "공용 · 도커".
"""
from __future__ import annotations

import os
import re
import shutil
import subprocess
import threading
import time
import unicodedata
from typing import Any

TTL = 60.0          # 이만큼 지나면 뒤에서 다시 잰다
MAX_AGE = 180.0     # 이보다 묵은 값은 안 그린다
MIN_CPU = 5.0       # % — 이 미만이고
MIN_RSS = 200 * (1 << 20)   # 이 미만이면 뺀다
NAME_MAX = 22
TEXT_MAX = 400      # 꼬리말 표가 #상태 한 메시지(4000자) 안에 들게 — 넘치면 render 가 표를 뺀다

_UNITS = {"b": 1, "kb": 1000, "kib": 1 << 10, "mb": 1000 ** 2, "mib": 1 << 20, "gb": 1000 ** 3, "gib": 1 << 30,
          "tb": 1000 ** 4, "tib": 1 << 40}


def _exe(name: str, extra: tuple = ()) -> str:
    """launchd 데몬 PATH 는 짧다 — 못 찾으면 흔한 설치 경로로."""
    found = shutil.which(name)
    if found:
        return found
    for cand in extra:
        if os.access(cand, os.X_OK):
            return cand
    return name


def _out(argv: list, timeout: float = 10.0, any_rc: bool = False) -> str:
    """명령 stdout. 실패·시간 초과는 빈 문자열(any_rc 면 종료 코드를 무시 — lsof 는 죽은 pid 가 섞이면 1 로 나와도 나머지를 준다)."""
    try:
        r = subprocess.run(argv, capture_output=True, text=True, timeout=timeout, stdin=subprocess.DEVNULL)
    except (OSError, subprocess.SubprocessError):
        return ""
    return r.stdout if (any_rc or r.returncode == 0) else ""


def parse_ps(out: str) -> dict:
    """pid -> {ppid, cpu, rss(bytes), comm}"""
    procs: dict = {}
    for line in out.splitlines():
        f = line.split(None, 4)
        if len(f) < 5:
            continue
        try:
            procs[int(f[0])] = {"ppid": int(f[1]), "cpu": float(f[2]), "rss": int(f[3]) * 1024, "comm": f[4]}
        except ValueError:
            continue
    return procs


def parse_bytes(s: str) -> int:
    m = re.match(r"\s*([\d.]+)\s*([A-Za-z]*)", s or "")
    if not m:
        return 0
    return int(float(m.group(1)) * _UNITS.get(m.group(2).lower() or "b", 1))


def parse_docker(out: str) -> list:
    """[(이름, cpu%, rss bytes)]"""
    rows = []
    for line in out.splitlines():
        f = line.split("\t")
        if len(f) < 3:
            continue
        try:
            rows.append((f[0].strip(), float(f[1].strip().rstrip("%")), parse_bytes(f[2].split("/")[0])))
        except ValueError:
            continue
    return rows


def parse_lsof_cwd(out: str) -> dict:
    """lsof -Fn 출력 -> pid -> cwd"""
    cwds: dict = {}
    pid = None
    for line in out.splitlines():
        if line.startswith("p") and line[1:].isdigit():
            pid = int(line[1:])
        elif line.startswith("n") and pid is not None:
            cwds[pid] = line[1:]
    return cwds


def _subtree(procs: dict, kids: dict, root: int, seen: set) -> tuple:
    cpu, rss, stack = 0.0, 0, [root]
    while stack:
        p = stack.pop()
        if p in seen or p not in procs:
            continue
        seen.add(p)
        cpu += procs[p]["cpu"]
        rss += procs[p]["rss"]
        stack.extend(kids.get(p, ()))
    return cpu, rss


def _under(path: str, root: str) -> bool:
    return path == root or path.startswith(root + "/")


def compose_prefix(project: str, root: str) -> str:
    """이 방 컨테이너 이름의 앞부분 `<compose -p>-`. plugin/scripts 의 marina-compose.py compose_project_name(project_id, session_id(root))
    와 같은 규칙을 복제한다(데몬 PYTHONPATH 에 그 모듈이 없다): 원본 체크아웃 = 'main', codex 레이아웃(root 이름이 프로젝트 root 이름)
    = 부모 폴더 이름, 그 밖(.claude/worktrees/<name>) = 자기 폴더 이름. 이름은 소문자·[^a-z0-9_-]+ → '-'·양끝 -/_ 제거."""
    import marina_session as ms
    try:
        proot = str(ms.project_root(project))
    except Exception:
        proot = ""
    if proot and root == proot:
        sid = "main"
    elif proot and os.path.basename(root) == os.path.basename(proot):
        sid = os.path.basename(os.path.dirname(root))
    else:
        sid = os.path.basename(root)
    return (re.sub(r"[^a-z0-9_-]+", "-", ("%s-%s" % (project, sid)).lower()).strip("-_") or "marina") + "-"


def room_usage(recs: list) -> list:
    """방마다 {ref, cpu, rss, docker_cpu, docker_rss} + 공용 항목(ref = "공용 <이름>")."""
    import marina_session as ms
    rooms: dict = {}     # ref -> item
    roots: list = []     # (root 실경로, ref, 컨테이너 접두사)
    tmux_names: dict = {}
    for rec in recs:
        if not rec.get("project") or not rec.get("task"):
            continue
        ref = "%s/%s" % (rec.get("project"), rec.get("task"))
        rooms[ref] = {"ref": ref, "cpu": 0.0, "rss": 0, "docker_cpu": 0.0, "docker_rss": 0}
        if rec.get("tmux"):
            tmux_names[str(rec["tmux"])] = ref
        if rec.get("root"):
            real = os.path.realpath(os.path.expanduser(str(rec["root"])))
            roots.append((real, ref, compose_prefix(str(rec.get("project") or ""), real)))
    roots.sort(key=lambda x: -len(x[0]))     # 메인 레포 root 안에 워크트리 root 가 있다 — 깊은 쪽이 이긴다
    shared: dict = {}

    def share(name: str) -> dict:
        return shared.setdefault(name, {"ref": name + " (shared)","cpu": 0.0, "rss": 0, "docker_cpu": 0.0, "docker_rss": 0})

    procs = parse_ps(_out(["/bin/ps", "-Ao", "pid=,ppid=,pcpu=,rss=,comm="]))
    kids: dict = {}
    for pid, p in procs.items():
        kids.setdefault(p["ppid"], []).append(pid)
    seen: set = set()
    if procs and tmux_names:
        panes = _out(ms._tmux_base() + ["list-panes", "-a", "-F", "#{session_name} #{pane_pid}"])
        for line in panes.splitlines():
            name, _, pid = line.rpartition(" ")
            if name in tmux_names and pid.isdigit():
                c, r = _subtree(procs, kids, int(pid), seen)
                rooms[tmux_names[name]]["cpu"] += c
                rooms[tmux_names[name]]["rss"] += r

    daemons = [pid for pid, p in procs.items()
               if pid not in seen and os.path.basename(p["comm"]).startswith("java")]
    if daemons:
        cwds = parse_lsof_cwd(_out(["/usr/sbin/lsof" if os.access("/usr/sbin/lsof", os.X_OK) else "lsof", "-a", "-p",
                                    ",".join(str(p) for p in daemons), "-d", "cwd", "-Fn"], any_rc=True))
        # 코틀린 데몬을 먼저 — gradle 데몬의 자식으로 떠 있어도 gradle 합에 섞이지 않고 seen 에 먼저 들어간다
        daemons.sort(key=lambda pid: "kotlin" not in cwds.get(pid, ""))
        for pid in daemons:
            cwd = cwds.get(pid, "")
            owner = next((ref for root, ref, _ in roots
                          if cwd and (_under(cwd, root) or ("/" + re.sub(r"[^A-Za-z0-9]", "-", root) + "/") in cwd + "/")), None)
            if owner:
                item = rooms[owner]
            else:
                item = share("kotlin-daemon" if "kotlin" in cwd else "gradle-daemon" if cwd else "java-daemon")
            c, r = _subtree(procs, kids, pid, seen)
            item["cpu"] += c
            item["rss"] += r

    docker = parse_docker(_out([_exe("docker", ("/usr/local/bin/docker", "/opt/homebrew/bin/docker",
                                                 "/Applications/Docker.app/Contents/Resources/bin/docker")),
                                "stats", "--no-stream", "--format", "{{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}"], timeout=20.0))
    prefixes = sorted(((pre.lower(), ref) for _, ref, pre in roots), key=lambda x: -len(x[0]))
    for name, cpu, rss in docker:
        owner = next((ref for pre, ref in prefixes if name.lower().startswith(pre)), None)
        item = rooms[owner] if owner else share("docker")
        item["docker_cpu"] += cpu
        item["docker_rss"] += rss
    return list(rooms.values()) + list(shared.values())


def _fmt_rss(b: int) -> str:
    g = b / (1 << 30)
    return "%.1fG" % g if g >= 1 else "%dM" % round(b / (1 << 20))


def _dw(s: str) -> int:
    """고정폭 글꼴에서의 칸 수 — 한글 등 넓은 글자는 2칸."""
    return sum(2 if unicodedata.east_asian_width(c) in "WF" else 1 for c in s)


def _cell(s: str, w: int) -> str:
    """w 칸에 맞춰 자르고(ASCII '~' — 폭 1 보장) 오른쪽을 빈칸으로 채운다."""
    if _dw(s) > w:
        while s and _dw(s) > w - 1:
            s = s[:-1]
        s += "~"
    return s + " " * (w - _dw(s))


def usage_text(items: list, top: int = 5, ncpu: "int | None" = None) -> str:
    """'### 🔥 많이 쓰는 곳' 제목 + 코드 블록 하나(칸 제목 줄 + 행) — CPU 순 상위(형 2026-11-06 "제대로").
    표 안은 ASCII(공용 이름도 영어)라 글꼴이 달라도 칸이 맞는다. CPU 는 맥 전체(코어 수) 대비 %."""
    ncpu = max(1, int(ncpu or os.cpu_count() or 1))
    rows = []
    for it in items:
        cpu, rss = it["cpu"] + it["docker_cpu"], it["rss"] + it["docker_rss"]
        if cpu < MIN_CPU and rss < MIN_RSS:
            continue
        rows.append((cpu, rss, it["ref"]))
    rows.sort(key=lambda x: (-x[0], -x[1]))
    if not rows:
        return ""
    body = ["%s %4s %5s" % (" " * NAME_MAX, "CPU", "MEM")] + [
        "%s %4s %5s" % (_cell(ref, NAME_MAX), "%d%%" % round(min(100.0, cpu / ncpu)), _fmt_rss(rss)) for cpu, rss, ref in rows[:top]]
    text = "\n".join(["### 🔥 많이 쓰는 곳 (1분마다)", "```"] + body + ["```"])
    while len(text) > TEXT_MAX and len(body) > 2:
        body.pop()
        text = "\n".join(["### 🔥 많이 쓰는 곳 (1분마다)", "```"] + body + ["```"])
    return text


_CACHE: list = []      # [(시각, 항목들)] — 비었거나 하나
_BUSY = threading.Event()


def _refresh(recs: list) -> None:
    try:
        _CACHE[:] = [(time.time(), room_usage(recs))]
    except Exception:
        pass
    finally:
        _BUSY.clear()


def cached_text(recs: list, wait: bool = False) -> str:
    """마지막으로 잰 값의 글. 60초 지났으면 뒤에서 다시 잰다(wait=True 면 기다린다 — 시험용). 180초 넘게 묵은 값은 ""."""
    got = _CACHE[0] if _CACHE else None
    if (not got or time.time() - got[0] > TTL) and not _BUSY.is_set():
        _BUSY.set()
        if wait:
            _refresh(recs)
        else:
            try:
                threading.Thread(target=_refresh, args=(recs,), name="room-resources", daemon=True).start()
            except Exception:
                _BUSY.clear()        # 스레드를 못 띄웠으면 다음 판에 다시 시도
        got = _CACHE[0] if _CACHE else None
    if got and time.time() - got[0] <= MAX_AGE:
        return usage_text(got[1])
    return ""
