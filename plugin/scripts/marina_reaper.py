#!/usr/bin/env python3
"""고아 백그라운드 프로세스 리퍼 — 데몬 폴링 스레드 + `marina reap [--dry-run]` CLI.

**왜.** Claude Code 세션이 Bash 로 백그라운드 실행한 프로세스는 세션이 끝나도 ppid=1 고아로
남는다. 2026-09-14 실측: `python -`(heredoc) 이 stdout 을 `/private/tmp/claude-501/<proj>/<sid>/
tasks/<id>.output` 에 둔 채 5일간 CPU 97%(출력 파일은 이미 삭제됨), ai-api `.venv/bin/python -`
8개 13일, storybook 49일, `python -m http.server` 779개(테스트 누수), dns-sd 33일.

**무엇을 죽이나.** 강한 시그니처 둘만 — 추측 없음:
  1) ppid==1 이고 fd1/fd2 가 `/private/tmp/claude-<uid>/**/tasks/*.output` — Claude 백그라운드
     태스크의 고아. 파일이 이미 삭제됐어도 lsof 는 경로를 그대로 보여준다(macOS 는 `(deleted)`
     표기가 없다 — 실측). 경로 매칭이라 삭제 여부와 무관하게 잡힌다.
  2) ppid==1 이고 cwd 디렉터리가 사라짐(삭제된 워크트리·/tmp 폴더). 단 marina 데몬($MARINA_HOME/
     dashboard.pid — launchd 가 띄워 ppid=1 이고 `marina reap` CLI 는 별도 프로세스라 os.getpid() 로는
     못 알아본다)·게이트웨이(caddy)·시스템 경로(/System /usr /Applications)는 제외.
여기에 시작 후 N시간(기본 6h, MARINA_REAPER_MIN_AGE_H)을 넘긴 것만 SIGTERM → 10s → SIGKILL.

**규칙.** 세션 liveness(marina_sessions)와 같다 — 판정에 argv 를 쓰지 않는다. ps 는 `comm=`(실행
파일명, 인자 없음)과 `etime=` 만, 나머지는 lsof 의 cwd/fd 다. argv 는 로그에 남길 뿐이다.
옵트아웃: MARINA_REAPER=0. 로그: $MARINA_HOME/reaper.log (pid·argv·cwd·사유).
"""
from __future__ import annotations

import argparse
import os
import signal
import subprocess
import sys
import time
from dataclasses import dataclass
from pathlib import Path

REASON_TASK_OUTPUT = "claude-task-output"
REASON_CWD_GONE = "cwd-gone"
_SYSTEM_PREFIXES = ("/System/", "/usr/", "/Applications/")
_USER_PREFIXES = ("/usr/local/",)            # 시스템 경로처럼 보이지만 사용자 설치(homebrew intel 등)
_EXCLUDED_COMMS = {"caddy"}                  # marina 게이트웨이(marina-gateway-control.sh 가 띄움)
_TERM_GRACE_S = 10.0
_INTERVAL_S = 600                            # 데몬 폴링 주기 — 수 주 묵은 고아를 잡는 일이라 촘촘할 이유가 없다
_LSOF_CHUNK = 200                            # lsof -p 목록이 너무 길면 실패한다 — 나눠서 부른다


def _home() -> Path:
    return Path(os.environ.get("MARINA_HOME") or (Path.home() / ".marina"))


def log_path() -> Path:
    return _home() / "reaper.log"


def enabled() -> bool:
    return os.environ.get("MARINA_REAPER", "1") not in ("0", "off", "false")


def min_age_s() -> int:
    raw = os.environ.get("MARINA_REAPER_MIN_AGE_H", "")
    try:
        return int(float(raw) * 3600) if raw else 6 * 3600
    except ValueError:
        return 6 * 3600


def protected_pids() -> set[int]:
    """절대 손대지 않는 pid — 이 프로세스 자신 + marina 데몬($MARINA_HOME/dashboard.pid)."""
    pids = {os.getpid()}
    try:
        text = (_home() / "dashboard.pid").read_text(encoding="utf-8").strip()
        if text.isdigit():
            pids.add(int(text))
    except OSError:
        pass
    return pids


def claude_tmp_root() -> str:
    # Claude Code 가 백그라운드 태스크 출력을 두는 곳: /private/tmp/claude-<uid>/<proj>/<sid>/tasks/<id>.output
    return f"/private/tmp/claude-{os.getuid()}"


@dataclass
class Candidate:
    pid: int
    reason: str
    age_s: int
    comm: str
    cwd: str
    fd_path: str          # 시그니처 1 의 근거 경로(없으면 "")
    argv: str = ""        # 로그용 — 판정에는 쓰지 않는다


# ── 파싱 ────────────────────────────────────────────────────────────────────────────────

def parse_etime(text: str) -> int:
    """ps etime= 의 [[dd-]hh:]mm:ss → 초. 못 읽으면 0(나이 0 은 절대 안 죽인다 — 보수적)."""
    text = text.strip()
    days = 0
    if "-" in text:
        d, _, text = text.partition("-")
        if not d.isdigit():
            return 0
        days = int(d)
    parts = text.split(":")
    if not 2 <= len(parts) <= 3 or not all(p.isdigit() for p in parts):
        return 0
    parts = [int(p) for p in parts]
    while len(parts) < 3:
        parts.insert(0, 0)
    h, m, s = parts
    return days * 86400 + h * 3600 + m * 60 + s


def parse_ps(text: str) -> dict[int, tuple[int, int, str]]:
    """`ps -axo pid=,ppid=,etime=,comm=` → pid → (ppid, age_s, comm). comm 은 공백을 품을 수 있다
    (앱 번들 경로, `redis-server *:6379`) — 앞 세 칸만 자르고 나머지를 통째로 comm 으로 둔다."""
    table: dict[int, tuple[int, int, str]] = {}
    for line in text.splitlines():
        parts = line.strip().split(None, 3)
        if len(parts) < 4 or not parts[0].isdigit() or not parts[1].isdigit():
            continue
        table[int(parts[0])] = (int(parts[1]), parse_etime(parts[2]), parts[3].strip())
    return table


def parse_lsof(text: str) -> dict[int, dict[str, str]]:
    """`lsof -a -p ... -d cwd,1,2 -Fpfn` → pid → {"cwd": path, "1": path, "2": path} (없으면 "")."""
    out: dict[int, dict[str, str]] = {}
    cur: dict[str, str] | None = None
    fd = ""
    for line in text.splitlines():
        if not line:
            continue
        tag, val = line[0], line[1:]
        if tag == "p" and val.strip().isdigit():
            cur = out.setdefault(int(val), {"cwd": "", "1": "", "2": ""})
            fd = ""
        elif tag == "f":
            fd = val.strip()
        elif tag == "n" and cur is not None and fd in cur:
            cur[fd] = val.strip()
    return out


# ── 판정(순수) ───────────────────────────────────────────────────────────────────────────

def _is_task_output(path: str) -> bool:
    if not path or not path.startswith(claude_tmp_root() + "/"):
        return False
    p = Path(path)
    return p.suffix == ".output" and p.parent.name == "tasks"


def classify(pid: int, ppid: int, age_s: int, comm: str, fds: dict[str, str], *,
             min_age_s: int, protected: set[int]) -> str | None:
    """죽일 사유 또는 None. ppid==1 + 나이 조건은 두 시그니처 공통. argv 는 보지 않는다."""
    if ppid != 1 or pid in protected or age_s <= 0 or age_s < min_age_s:
        return None
    if _is_task_output(fds.get("1", "")) or _is_task_output(fds.get("2", "")):
        return REASON_TASK_OUTPUT           # Claude 태스크 고아는 실행파일이 무엇이든 그 자체로 근거
    cwd = fds.get("cwd", "")
    if not cwd:
        return None                         # lsof 가 cwd 를 못 줬으면 판단하지 않는다
    if Path(comm).name in _EXCLUDED_COMMS or (
            comm.startswith(_SYSTEM_PREFIXES) and not comm.startswith(_USER_PREFIXES)):
        return None
    if not Path(cwd).is_dir():
        return REASON_CWD_GONE
    return None


# ── 수집 ────────────────────────────────────────────────────────────────────────────────

def _run(args: list[str], timeout: float) -> str:
    try:
        return subprocess.run(args, check=False, capture_output=True, text=True, timeout=timeout).stdout
    except (OSError, subprocess.SubprocessError):
        return ""


def _lsof(pids: list[int]) -> dict[int, dict[str, str]]:
    out: dict[int, dict[str, str]] = {}
    for i in range(0, len(pids), _LSOF_CHUNK):
        chunk = ",".join(str(p) for p in pids[i:i + _LSOF_CHUNK])
        out.update(parse_lsof(_run(["lsof", "-a", "-p", chunk, "-d", "cwd,1,2", "-Fpfn"], timeout=15)))
    return out


def _argv(pid: int) -> str:
    return _run(["ps", "-o", "args=", "-p", str(pid)], timeout=2).strip()


def scan(min_age_s: int) -> list[Candidate]:
    """현재 프로세스 표에서 후보를 고른다 — 죽이지 않는다."""
    table = parse_ps(_run(["ps", "-axo", "pid=,ppid=,etime=,comm="], timeout=5))
    protected = protected_pids()
    orphans = [pid for pid, (ppid, age, _) in table.items()
               if ppid == 1 and pid not in protected and 0 < age and age >= min_age_s]
    if not orphans:
        return []
    fds = _lsof(orphans)
    found: list[Candidate] = []
    for pid in orphans:
        ppid, age, comm = table[pid]
        pfd = fds.get(pid, {"cwd": "", "1": "", "2": ""})
        reason = classify(pid, ppid, age, comm, pfd, min_age_s=min_age_s, protected=protected)
        if reason is None:
            continue
        fd_path = next((pfd[k] for k in ("1", "2") if _is_task_output(pfd[k])), "")
        found.append(Candidate(pid, reason, age, comm, pfd["cwd"], fd_path, _argv(pid)))
    return found


# ── 처형·로그 ───────────────────────────────────────────────────────────────────────────

def _log(lines: list[str]) -> None:
    try:
        path = log_path()
        path.parent.mkdir(parents=True, exist_ok=True)
        stamp = time.strftime("%Y-%m-%d %H:%M:%S")
        with path.open("a", encoding="utf-8") as f:
            for line in lines:
                f.write(f"{stamp} {line}\n")
    except OSError:
        pass


def _alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True


def _signal(pid: int, sig: signal.Signals) -> bool:
    try:
        os.kill(pid, sig)
        return True
    except (ProcessLookupError, PermissionError):
        return False


def _describe(c: Candidate) -> str:
    age_h = c.age_s / 3600
    base = f"pid={c.pid} reason={c.reason} age={age_h:.1f}h comm={c.comm} cwd={c.cwd or '-'}"
    if c.fd_path:
        base += f" fd={c.fd_path}"
    return base + f" argv={c.argv or '-'}"


def reap(min_age_s: int, dry_run: bool = False, only: set[int] | None = None) -> list[Candidate]:
    """후보에 SIGTERM → 10s 유예 → SIGKILL. `only` 는 테스트용(그 pid 들만 손댄다). 매 회 로그."""
    cands = [c for c in scan(min_age_s) if only is None or c.pid in only]
    if not cands:
        return []
    if dry_run:
        _log([f"dry-run {_describe(c)}" for c in cands])
        return cands
    _log([f"SIGTERM {_describe(c)}" for c in cands])
    for c in cands:
        _signal(c.pid, signal.SIGTERM)
    deadline = time.time() + _TERM_GRACE_S
    pending = {c.pid for c in cands}
    while pending and time.time() < deadline:
        time.sleep(0.2)
        pending = {p for p in pending if _alive(p)}
    if pending:
        _log([f"SIGKILL pid={p} (SIGTERM 10s 무응답)" for p in sorted(pending)])
        for p in pending:
            _signal(p, signal.SIGKILL)
    return cands


def run_forever() -> None:
    """데몬 폴링 스레드 본체 — 어떤 예외도 삼킨다(리퍼가 데몬을 죽이면 본말전도)."""
    while True:
        try:
            reap(min_age_s())
        except Exception as exc:              # noqa: BLE001
            _log([f"error {exc!r}"])
        time.sleep(_INTERVAL_S)


# ── CLI ─────────────────────────────────────────────────────────────────────────────────

def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(prog="marina reap", description="고아 백그라운드 프로세스 정리")
    ap.add_argument("--dry-run", action="store_true", help="후보만 보여주고 죽이지 않는다")
    ap.add_argument("--min-age-hours", type=float, default=None,
                    help=f"이 시간(h) 넘게 산 것만 (기본 MARINA_REAPER_MIN_AGE_H, 현재 {min_age_s() / 3600:g}h)")
    args = ap.parse_args(argv)
    age = int(args.min_age_hours * 3600) if args.min_age_hours is not None else min_age_s()
    cands = reap(age, dry_run=args.dry_run)
    if not cands:
        print("reap: 대상 없음")
        return 0
    verb = "후보(dry-run)" if args.dry_run else "종료"
    print(f"reap: {verb} {len(cands)}개 — 로그 {log_path()}")
    for c in cands:
        print("  " + _describe(c))
    return 0


if __name__ == "__main__":
    sys.exit(main())
