"""marina_cli.py — marina-control.py 에서 분리(레이어드). 동작 변경 0."""
from __future__ import annotations
import glob
import json
import os
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any
import importlib.util as _ilu

from marina_state import MARINA_SCRIPT, MARINA_HOME, _mc
from marina_registry import external_repos_for, source_root_for, subrepos_of, project_for
from marina_build_inputs import capture_build_inputs

def script(root: Path) -> Path:
    # 런처는 이 레포의 전역 marina.sh — worktree 위치와 무관 (구 SCRIPT_REL = 워크스페이스 내부 사본 탐색 제거).
    return MARINA_SCRIPT

_LOGIN_ENV_CACHE: dict = {}
def _login_env() -> dict[str, str]:
    """사용자 로그인 셸의 toolchain env(PATH + JAVA_HOME). 한 번 캡쳐 캐시 — PATH 보강 + JAVA_HOME 폴백용.
    데몬(launchd/systemd)은 최소 env 라 그대로 두면 대시보드 start/stop/restart/prebuild 가
    docker 못 찾거나 시스템 구버전 java(13) 로 빌드가 깨진다. sdkman 등은 .zshrc(interactive)에서
    JAVA_HOME/PATH 를 잡으므로 interactive 로그인(-lic)으로 캡쳐한다(bash -lc 는 zsh 사용자에게 안 통함).
    프로젝트별 java 는 x-marina.java(명시)로 잡는다 — 여기 JAVA_HOME 은 명시 없을 때의 전역 폴백."""
    if _LOGIN_ENV_CACHE:
        return _LOGIN_ENV_CACHE
    out_path, java_home = "", ""
    try:
        shell = os.environ.get("SHELL") or "/bin/zsh"
        # `env` 덤프 → 셸 문법 무관(fish 포함 KEY=VAL 동일). -l -i 로 사용자 설정(.zshrc 등 toolchain) 반영.
        with open(os.devnull) as devnull:
            out = subprocess.run([shell, "-l", "-i", "-c", "env"],
                                 stdin=devnull, capture_output=True, text=True, timeout=10)
        for line in (out.stdout or "").splitlines():
            if line.startswith("PATH="):
                out_path = line[len("PATH="):]
            elif line.startswith("JAVA_HOME="):
                java_home = line[len("JAVA_HOME="):]
    except Exception:
        pass
    _LOGIN_ENV_CACHE.update(PATH=out_path, JAVA_HOME=java_home)
    return _LOGIN_ENV_CACHE

def _resolve_java_home(val: str, suffix: str = "") -> str:
    """java 지정값 → JAVA_HOME 절대경로. 절대경로면 그대로. 아니면 sdkman candidates 매칭:
    정확 일치 > (배포판 suffix 일치 & major 접두) > major 접두(배포판 무관). suffix 는 Dockerfile 배포판(tem/amzn/…)."""
    val = (val or "").strip()
    if not val:
        return ""
    if os.path.isabs(val) and os.path.isdir(val):
        return val
    cand = Path.home() / ".sdkman" / "candidates" / "java"
    try:
        names = [d.name for d in cand.iterdir() if d.is_dir() and d.name != "current"]
    except OSError:
        return ""
    if val in names:
        return str(cand / val)
    major = val.split(".")[0].split("-")[0]
    def _pick(ns):
        return str(cand / sorted(ns)[-1]) if ns else ""   # 사전순 최대(대체로 최신 패치)
    if suffix:
        hit = _pick([n for n in names if n.startswith(major) and n.endswith("-" + suffix)])
        if hit:
            return hit
    return _pick([n for n in names if n.startswith(major)])

# Dockerfile base image(배포판) → sdkman java 배포판 suffix
_JDK_DISTRO = {"eclipse-temurin": "tem", "temurin": "tem", "amazoncorretto": "amzn", "corretto": "amzn",
               "azul": "zulu", "zulu": "zulu", "bellsoft": "librca", "liberica": "librca",
               "sapmachine": "sapmchn", "graalvm": "graalce", "graal": "graalce", "openjdk": "open", "microsoft": "ms"}
def _dockerfile_java_spec(path: Path):
    """Dockerfile 의 마지막 FROM(JDK base image)에서 (java 버전, sdkman 배포판 suffix). JDK 이미지 아니면 ('','')."""
    try:
        frm = ""
        for line in Path(path).read_text(encoding="utf-8").splitlines():
            s = line.strip()
            if s[:5].upper() == "FROM ":
                frm = s[5:].strip()
        if not frm:
            return "", ""
        img = frm.split()[0]                       # 'eclipse-temurin:21' ('AS build' 등 제거)
        name, _, tag = img.partition(":")
        base = name.split("/")[-1].lower()
        if not any(k in (base + " " + tag).lower() for k in list(_JDK_DISTRO) + ["jdk", "jre", "java"]):
            return "", ""                          # java 이미지 아님(python/node 등)
        suffix = next((v for k, v in _JDK_DISTRO.items() if k in base), "")
        m = re.search(r"(\d+(?:\.\d+)*)", tag)     # '21' / '21.0.5' / '21-jdk'
        return (m.group(1) if m else ""), suffix
    except Exception:
        return "", ""

_JAVA_HOMES_CACHE: dict[str, dict] = {}   # project id → {서브레포|default: JAVA_HOME 절대경로}
def _subrepo_java_homes(root: Path) -> dict[str, str]:
    """서브레포별 호스트 빌드 JAVA_HOME. 각 서비스 Dockerfile 의 FROM(JDK base)에서 유도(SoT=Dockerfile) →
    x-marina.java(문자열=default, dict=서브레포별)로 override. {서브레포|default: 절대경로}. project id 별 캐시."""
    proj = project_for(root)
    if not proj:
        return {}
    pid = str(proj.get("id", ""))
    if pid in _JAVA_HOMES_CACHE:
        return _JAVA_HOMES_CACHE[pid]
    out: dict[str, str] = {}
    try:
        stored = MARINA_HOME / pid / (proj.get("composeFile") or "docker-compose.yml")
        src = source_root_for(root)                # Dockerfile 은 소스(main)에 항상 있음(워크트리는 미apply 일 수 있음)
        mc = _mc()
        data = mc._yaml().safe_load(Path(stored).read_text(encoding="utf-8")) or {}
        for _name, svc in (data.get("services") or {}).items():   # 1) Dockerfile FROM → 서브레포별 JDK
            if not isinstance(svc, dict):
                continue
            b = svc.get("build")
            ctx, dfile = ((b, "Dockerfile") if isinstance(b, str)
                          else ((b.get("context") or ".", b.get("dockerfile") or "Dockerfile") if isinstance(b, dict) else (None, None)))
            if ctx is None:
                continue
            sub = (ctx or ".").lstrip("./").split("/")[0] or "."
            if sub in out:
                continue
            spec, suffix = _dockerfile_java_spec(Path(src) / (ctx or ".").lstrip("./") / dfile)
            if spec:
                jh = _resolve_java_home(spec, suffix)
                if jh:
                    out[sub] = jh
        jv = (mc.xmarina_for_stored(str(stored)) or {}).get("java")   # 2) x-marina.java override
        if isinstance(jv, str):
            jv = {"default": jv}
        if isinstance(jv, dict):
            for k, v in jv.items():
                jh = _resolve_java_home(str(v))
                if jh:
                    out[str(k)] = jh
    except Exception:
        pass
    _JAVA_HOMES_CACHE[pid] = out
    return out

def marina_env(root: Path, ignore_overrides: bool = False) -> dict[str, str]:
    source = source_root_for(root)
    env = {**os.environ, "ROOT": str(root)}
    _login = _login_env()
    # 데몬 최소 PATH 보강 — 로그인 셸 PATH(docker·node 등) 앞에 병합 + 흔한 위치 폴백. 중복 제거(순서 유지).
    _seen: list[str] = []
    for _d in _login.get("PATH", "").split(os.pathsep) + (env.get("PATH") or "").split(os.pathsep) \
              + [str(Path.home() / ".local/bin"), "/opt/homebrew/bin", "/usr/local/bin"]:
        if _d and _d not in _seen:
            _seen.append(_d)
    env["PATH"] = os.pathsep.join(_seen)
    # JAVA_HOME: Dockerfile FROM(SoT) 유도 → x-marina.java override → 전역 셸 폴백. 서브레포별 맵은 prebuild 로 전달.
    _jh = _subrepo_java_homes(root)
    _default = _jh.get("default") or (next(iter(_jh.values())) if len(_jh) == 1 else "")
    if _default:                                                # 단일/기본 SDK — 프로세스 JAVA_HOME
        env["JAVA_HOME"] = _default
    elif not env.get("JAVA_HOME") and _login.get("JAVA_HOME") and os.path.isdir(_login["JAVA_HOME"]):
        env["JAVA_HOME"] = _login["JAVA_HOME"]                   # 폴백: 데몬 최소 env 에 없으면 로그인 셸 JAVA_HOME
    if _jh:
        env["MARINA_JAVA_HOMES"] = json.dumps(_jh)              # prebuild 가 서브레포별로 JAVA_HOME override
    if source != root:
        env["SOURCE_ROOT"] = str(source)
    # 전역 런처에 프로젝트 서브레포를 전달 (marina.sh 가 하드코딩 대신 받아 쓴다)
    env["MARINA_SUBREPOS"] = " ".join(subrepos_of(root))
    env["MARINA_EXTERNAL_REPOS"] = "\n".join(f"{e['name']}={e['source']}" for e in external_repos_for(root))
    if ignore_overrides:
        env["MARINA_IGNORE_PORT_OVERRIDES"] = "1"
    return env

def run_text(args: list[str], cwd: Path) -> str:
    return subprocess.check_output(args, cwd=str(cwd), text=True, stderr=subprocess.STDOUT)

def run_marina(root: Path, *args: str, ignore_overrides: bool = False) -> str:
    return subprocess.check_output(
        [str(script(root)), *args],
        cwd=str(root),
        text=True,
        stderr=subprocess.STDOUT,
        env=marina_env(root, ignore_overrides=ignore_overrides),
    )

def run_marina_registry(*args: str) -> str:
    # 레지스트리 CLI(add/infer/rm)는 위치 무관 — worktree ROOT/MARINA_SUBREPOS env 없이 전역 런처 호출.
    return subprocess.check_output(
        [str(MARINA_SCRIPT), *args],
        text=True,
        stderr=subprocess.STDOUT,
    )

def _marina_cli(root: Path, *args: str, timeout: float = 120) -> str:
    return subprocess.check_output(
        [str(script(root)), *args], cwd=str(root), text=True,
        stderr=subprocess.STDOUT, env=marina_env(root), timeout=timeout,
    )

def _marina_cli_logged(root: Path, *args: str, timeout: float = 120, extra_env: dict | None = None) -> None:
    """_marina_cli 의 build-log 스트리밍판 — prebuild·docker build 진행 출력이 메모리 버퍼(성공 시 폐기,
    실패 시 500자)로 사라지지 않고 per-session 'build' 로그 run 에 실린다(대시보드 /api/logs 재사용).
    실패 시 CalledProcessError(output=파일 끝 4KB) — busyError 500자 계약 유지."""
    from marina_build import write_build_meta
    from marina_paths import next_log_path

    log_path = next_log_path(root, "build")
    env = marina_env(root)
    if extra_env:
        env.update(extra_env)
    argv = [str(script(root)), *args]
    started_at = time.time()
    op = args[0] if args else ""
    meta = {
        "status": "running",
        "op": op,
        "startedAt": started_at,
        "inputs": {"version": 1, "status": "pending"},
    }
    write_build_meta(log_path, meta)
    rc = None
    timed_out = False
    try:
        with open(log_path, "a", encoding="utf-8") as fh:
            fh.write(f"$ marina {' '.join(args)}\n")
            fh.flush()
            proc = subprocess.Popen(
                argv,
                cwd=str(root),
                env=env,
                stdout=fh,
                stderr=subprocess.STDOUT,
                text=True,
            )
            try:
                rc = proc.wait(timeout=timeout)
            except subprocess.TimeoutExpired:
                timed_out = True
                proc.kill()
                proc.wait(5)
                raise
    finally:
        ended_at = time.time()
        try:
            inputs = capture_build_inputs(root, tuple(args), env)
        except Exception:
            inputs = {"version": 1, "status": "unknown"}
        final = {
            **meta,
            "status": "timeout" if timed_out else ("success" if rc == 0 else "failed"),
            "endedAt": ended_at,
            "durationSec": round(max(0.0, ended_at - started_at), 3),
            "inputs": inputs,
        }
        if rc is not None:
            final["exitCode"] = rc
        write_build_meta(log_path, final)
    if rc != 0:
        tail = ""
        try:
            size = os.path.getsize(log_path)
            with open(log_path, "rb") as f:
                f.seek(max(0, size - 4096))
                tail = f.read().decode("utf-8", "replace")
        except OSError:
            pass
        raise subprocess.CalledProcessError(rc, argv, output=tail)

def _direct_cli_root(cwd: Path | None = None) -> Path:
    if os.environ.get("ROOT"):
        return Path(os.environ["ROOT"]).expanduser().resolve()
    start = (cwd or Path.cwd()).resolve()
    try:
        raw = subprocess.check_output(
            ["git", "-C", str(start), "rev-parse", "--show-toplevel"],
            text=True,
            stderr=subprocess.DEVNULL,
        ).strip()
        root = Path(raw).resolve()
    except Exception:
        root = start

    project = project_for(root)
    subrepos = [str(s) for s in (project or {}).get("subrepos", [])]
    if root.name in subrepos:
        parent = root.parent.resolve()
        if project is None or parent.name == project["root"].name or project_for(parent):
            return parent
    return root

def exec_marina_with_env(args: list[str]) -> int:
    if not args:
        print("usage: marina_cli.py exec <marina.sh args...>", file=sys.stderr)
        return 2
    root = _direct_cli_root()
    target = script(root)
    os.execve(str(target), [str(target), *args], marina_env(root))
    return 127

def main(argv: list[str] | None = None) -> int:
    argv = list(sys.argv[1:] if argv is None else argv)
    if argv[:1] == ["exec"]:
        return exec_marina_with_env(argv[1:])
    print("usage: marina_cli.py exec <marina.sh args...>", file=sys.stderr)
    return 2

if __name__ == "__main__":
    raise SystemExit(main())
