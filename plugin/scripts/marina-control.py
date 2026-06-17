#!/usr/bin/env python3
"""marina — local dashboard for worktree dev sessions."""

from __future__ import annotations

import glob
import json
import os
import re
import signal
import shlex
import shutil
import subprocess
import time
import urllib.error
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any


def _env(name: str, default: str) -> str:
    return os.environ.get(f"MARINA_{name}", default)


HOST = _env("CONTROL_HOST", "localhost")
PORT = int(_env("CONTROL_PORT", "3900"))
WORKTREES_ROOT = Path(os.environ.get("CODEX_WORKTREES_ROOT", str(Path.home() / ".codex" / "worktrees")))
CONTROL_SCRIPT = Path(__file__).resolve()
# 런처·attach 스크립트는 이 파일의 형제 — 위치독립(어느 프로젝트의 worktree 든 이 전역 스크립트를 쓴다).
MARINA_SCRIPT = CONTROL_SCRIPT.parent / "marina.sh"
MARINA_ATTACH = CONTROL_SCRIPT.parent / "attach-detached-subrepos.sh"
# 글로벌 프로젝트 레지스트리 — 한 데몬이 등록된 모든 프로젝트의 worktree 를 관리 (marina-standardization)
MARINA_HOME = Path(os.environ.get("MARINA_HOME", str(Path.home() / ".marina")))
PROJECTS_FILE = MARINA_HOME / "projects.json"
# 하네스 config·플러그인 매니페스트 위치 (업데이트 알림용). CLAUDE_CONFIG_DIR 는 marina-resolve 와 동일 규칙.
CLAUDE_CONFIG_DIR = Path(os.environ.get("CLAUDE_CONFIG_DIR", str(Path.home() / ".claude")))
CODEX_HOME = Path(os.environ.get("CODEX_HOME", str(Path.home() / ".codex")))
MARKETPLACE = "marina-dev"
PLUGIN_ID = "marina@marina-dev"
# 내장 서비스 없음 — 모든 서비스는 프로젝트 root 의 marina-services.json 에서 정의 (완전 generic)
_BUILTIN_SERVICES: tuple[str, ...] = ()
_BUILTIN_PORT_BASE: dict[str, int] = {}
# 발견·상태 저수준 폴백 — 미등록 root 의 서브레포 (없음; 레지스트리가 권위)
_DEFAULT_SUBREPOS: tuple[str, ...] = ()


def _registered_roots() -> list[Path]:
    # 레지스트리에 등록된 프로젝트 root 들. import 시점(load_projects 정의 전)에도 쓰이므로 파일 직접 읽기.
    try:
        data = json.loads(PROJECTS_FILE.read_text(encoding="utf-8"))
    except Exception:
        return []
    roots: list[Path] = []
    for entry in data.get("projects", []):
        try:
            roots.append(Path(str(entry["root"])).expanduser())
        except Exception:
            continue
    return roots


LOG_TAIL_BYTES = 64 * 1024   # SSE 초기 표시 분량 — 이전 내용은 /api/logs/chunk 페이징
LOG_CHUNK_BYTES = 64 * 1024  # "이전 더 보기" 1회 분량
_projects_cache: list[dict[str, Any]] = []
# 세션별 config 기본값 — generic 코어엔 내장 키 없음 (포트·프로파일 override 는 SERVICE_PORT_<N>/SERVICE_PROFILE_<N>).
CONFIG_DEFAULTS: dict[str, str] = {}
SENSITIVE_ASSIGNMENT_RE = re.compile(
    r"([A-Z0-9_]*(?:KEY|SECRET|TOKEN|PASSWORD|ACCESS|WEBHOOK|CREDENTIAL|PRIVATE)"
    r"[A-Z0-9_]*\s*=\s*)([^\s│]+)",
    re.IGNORECASE,
)
SENSITIVE_JSON_RE = re.compile(
    r'("(?:[^"]*(?:key|secret|token|password|access|webhook|credential|private)[^"]*)"\s*:\s*)"[^"]*"',
    re.IGNORECASE,
)
SENSITIVE_PY_OBJECT_RE = re.compile(
    r"('(?:[^']*(?:key|secret|token|password|access|webhook|credential|private)[^']*)'\s*:\s*)'[^']*'",
    re.IGNORECASE,
)


def json_bytes(payload: Any) -> bytes:
    return json.dumps(payload, ensure_ascii=False).encode("utf-8")


def _git_main_checkout(root: Path) -> Path | None:
    # worktree → 원본(main) 체크아웃을 git 토폴로지로 역추적. 레지스트리에 없는 root 의 폴백.
    # (worktree → 원본 체크아웃을 git common-dir 토폴로지로 역추적)
    if is_source_checkout(root):
        return root
    for repo in subrepos_of(root):
        repo_path = root / repo
        if not (repo_path / ".git").exists():
            continue
        try:
            common = subprocess.check_output(
                ["git", "-C", str(repo_path), "rev-parse", "--path-format=absolute", "--git-common-dir"],
                text=True, stderr=subprocess.DEVNULL,
            ).strip()
        except Exception:
            continue
        if common:
            candidate = Path(common).parent.parent  # <main>/<repo>/.git → <main>
            if candidate.is_dir():
                return candidate
    try:
        common = subprocess.check_output(
            ["git", "-C", str(root), "rev-parse", "--path-format=absolute", "--git-common-dir"],
            text=True, stderr=subprocess.DEVNULL,
        ).strip()
    except Exception:
        common = ""
    if common:
        candidate = Path(common).parent  # <main>/.git → <main>
        if candidate.is_dir():
            return candidate
    return None


def load_projects() -> list[dict[str, Any]]:
    # ~/.marina/projects.json — 명시 등록(marina project add)된 프로젝트만 읽는다.
    # 비면 빈 목록(대시보드 빈 상태) — 현재 체크아웃을 추측하지 않는다(명시 등록 marina project add 필요).
    if _projects_cache:
        return _projects_cache
    items: list[dict[str, Any]] = []
    try:
        data = json.loads(PROJECTS_FILE.read_text(encoding="utf-8"))
        for entry in data.get("projects", []):
            # resolve — 발견 경로와 매칭 일관성 (심볼릭링크·~)
            root = Path(str(entry["root"])).expanduser().resolve()
            _da = entry.get("defaultAttach")
            items.append({
                "id": str(entry.get("id") or root.name),
                "root": root,
                "subrepos": [str(s) for s in entry.get("subrepos", [])],
                "defaultAttach": [str(s) for s in _da] if isinstance(_da, list) else None,
                "worktreeGlobs": [str(g) for g in entry.get("worktreeGlobs", [])],
            })
    except Exception:
        items = []
    _projects_cache[:] = items
    return items


def project_for(root: Path) -> dict[str, Any] | None:
    # root 가 어느 프로젝트 소속인지 — 프로젝트 root 자신/하위(claude worktree),
    # 또는 codex 레이아웃(<worktrees>/<id>/<basename>) 한정 basename 일치. 단일 등록이면 항상 그 프로젝트.
    projects = load_projects()
    if not projects:
        return None
    try:
        rroot = root.resolve()
    except OSError:
        rroot = root
    best = None
    best_len = -1
    for project in projects:
        proot = project["root"].resolve()
        sproot = str(proot)
        if rroot == proot or str(rroot).startswith(sproot + os.sep):
            if len(sproot) > best_len:
                best, best_len = project, len(sproot)
    if best is not None:
        return best
    # codex 레이아웃(<worktrees>/<id>/<basename>) 한정 basename 매치 — 동일 basename 다중 프로젝트 충돌 방지
    try:
        in_codex_layout = rroot.parent.parent == WORKTREES_ROOT.resolve()
    except (OSError, ValueError):
        in_codex_layout = False
    if in_codex_layout:
        for project in projects:
            if root.name == project["root"].name:
                return project
    return projects[0] if len(projects) == 1 else None


def subrepos_of(root: Path) -> list[str]:
    project = project_for(root)
    return list(project["subrepos"]) if project else list(_DEFAULT_SUBREPOS)


def default_attach_of(root: Path) -> list[str] | None:
    # 전체 기본 attach 집합 (명시값). 부재 시 None → 호출부가 "전체 universe" 로 해석 (backward compatible).
    project = project_for(root)
    if not project:
        return None
    da = project.get("defaultAttach")
    return [str(s) for s in da] if isinstance(da, list) else None


def update_state(serving: str | None, installed: str | None, origin: str | None) -> str:
    # serving=실행 중 SHA, installed=받아진 SHA, origin=배포된 최신 SHA. 모두 short SHA.
    # serving/installed 모르면 판정 불가(dev/repo 실행) → unknown(배너 없음).
    if not serving or not installed:
        return "unknown"
    # origin 모르면(네트워크 실패) 무네트워크 판정: serving==installed 면 current, 아니면 stale.
    if origin is None:
        return "current" if serving == installed else "stale"
    if serving == origin:
        return "current"
    if installed == origin:
        return "stale"   # 파일은 최신, 데몬만 옛 코드 → 재시작
    return "new"         # 배포된 게 받아진 것보다 최신 → 업데이트(다음 세션/수동) 필요


_SHA_RE = re.compile(r"^([0-9a-f]{7,40}|\d+\.\d+)")
_origin_cache: dict[str, Any] = {}


def _serving_sha() -> str | None:
    env = os.environ.get("MARINA_SERVING_SHA")
    if env:
        return env[:12]
    # 설치 레이아웃: .../<marketplace>/marina/<SHA>/scripts/marina-control.py → <SHA> = parent.parent.name
    name = CONTROL_SCRIPT.parent.parent.name
    return name[:12] if _SHA_RE.match(name) else None   # 레포/dev 실행(name='plugin')은 None


def _installed_sha() -> str | None:
    env = os.environ.get("MARINA_INSTALLED_SHA")
    if env:
        return env[:12]
    for mf in (CLAUDE_CONFIG_DIR / "plugins" / "installed_plugins.json",
               CODEX_HOME / "plugins" / "installed_plugins.json"):
        try:
            data = json.loads(mf.read_text(encoding="utf-8"))
            raw = Path(str(data["plugins"][PLUGIN_ID][0]["installPath"])).name[:12]
            if _SHA_RE.match(raw):   # _serving_sha 와 대칭 — 비-SHA installPath 는 무시(오탐 방지)
                return raw
        except Exception:
            continue
    return None


def _marketplace_repo() -> str:
    # settings.json 의 marina-dev source.repo (fork 대응), 없으면 기본.
    try:
        s = json.loads((CLAUDE_CONFIG_DIR / "settings.json").read_text(encoding="utf-8"))
        repo = s["extraKnownMarketplaces"][MARKETPLACE]["source"]["repo"]
        if isinstance(repo, str) and repo:
            return repo
    except Exception:
        pass
    return "turong92/marina"


def _origin_sha() -> str | None:
    env = os.environ.get("MARINA_ORIGIN_SHA")
    if env:
        return env[:12]
    ttl = float(_env("UPDATE_TTL", "60"))
    now = time.time()
    if _origin_cache and now - _origin_cache.get("ts", 0) < ttl:
        return _origin_cache.get("sha")
    sha = _origin_cache.get("sha")  # 실패 시 마지막 값 유지
    try:
        out = subprocess.check_output(
            ["git", "ls-remote", f"https://github.com/{_marketplace_repo()}.git", "main"],
            text=True, timeout=5, stderr=subprocess.DEVNULL,
        )
        if out.strip():
            sha = out.split()[0][:12]
    except Exception:
        pass
    _origin_cache.update({"sha": sha, "ts": now})
    return sha


def _harnesses() -> list[str]:
    # 설치된 하네스 감지. Claude=installed_plugins.json, Codex=config.toml 에 설치 기록(installed_plugins.json 없음).
    out: list[str] = []
    if (CLAUDE_CONFIG_DIR / "plugins" / "installed_plugins.json").exists():
        out.append("claude")
    try:
        if f'[plugins."{PLUGIN_ID}"]' in (CODEX_HOME / "config.toml").read_text(encoding="utf-8"):
            out.append("codex")
    except Exception:
        pass
    return out


def _git_head(d: Path) -> str | None:
    try:
        out = subprocess.check_output(["git", "-C", str(d), "rev-parse", "HEAD"],
                                      text=True, timeout=5, stderr=subprocess.DEVNULL)
        sha = out.strip()[:12]
        return sha if _SHA_RE.match(sha) else None
    except Exception:
        return None


def _codex_marketplace() -> dict[str, str] | None:
    # ~/.codex/config.toml 의 [marketplaces.marina-dev] 블록 (text-parse; py3.9 라 tomllib 없음)
    try:
        t = (CODEX_HOME / "config.toml").read_text(encoding="utf-8")
    except Exception:
        return None
    m = re.search(r"\[marketplaces\.marina-dev\](.*?)(?=\n\[|\Z)", t, re.S)
    if not m:
        return None
    src = re.search(r'source\s*=\s*"([^"]+)"', m.group(1))
    typ = re.search(r'source_type\s*=\s*"([^"]+)"', m.group(1))
    return {"source": src.group(1), "sourceType": typ.group(1) if typ else ""} if src else None


def _harness_status() -> dict[str, Any]:
    # 하네스별 설치 버전 + origin 대비 뒤처짐 (배너 칩용). claude=설치 복사본 SHA, codex=마켓 스냅샷 git HEAD(라이브 참조)
    origin = _origin_sha()
    out: dict[str, Any] = {}
    try:
        data = json.loads((CLAUDE_CONFIG_DIR / "plugins" / "installed_plugins.json").read_text(encoding="utf-8"))
        ent = data["plugins"][PLUGIN_ID][0]
        sha = str(ent.get("gitCommitSha") or Path(str(ent["installPath"])).name)[:12]
        if _SHA_RE.match(sha):
            out["claude"] = {"installed": sha, "behind": bool(origin and sha != origin)}
    except Exception:
        pass
    mk = _codex_marketplace()
    if mk:
        sha = _git_head(Path(mk["source"]))
        if sha:
            out["codex"] = {"installed": sha, "behind": bool(origin and sha != origin), "sourceType": mk.get("sourceType", "")}
    return out


def _bin(name: str) -> str:
    # launchd 데몬의 최소 PATH(/usr/bin:/bin)엔 ~/.local/bin·/opt/homebrew/bin 등이 없어 CLI 를 못 찾음
    # (Errno 2 No such file or directory). PATH 우선 조회 후, 없으면 흔한 설치 위치를 보강해 절대경로로 해석.
    found = shutil.which(name)
    if found:
        return found
    home = Path.home()
    for d in (home / ".local/bin", Path("/opt/homebrew/bin"), Path("/usr/local/bin"),
              home / ".claude/local", home / ".bun/bin", home / ".volta/bin"):
        cand = d / name
        if cand.exists():
            return str(cand)
    return name


def update_codex() -> dict[str, Any]:
    # codex 는 마켓 스냅샷 디렉토리를 라이브로 읽으므로, 그 git repo 를 origin/main 으로 ff-pull = codex 갱신
    mk = _codex_marketplace()
    if not mk:
        raise ValueError("codex marina-dev 마켓플레이스를 찾을 수 없음 (codex 미설치?)")
    src = Path(mk["source"])
    try:
        out = subprocess.check_output(["git", "-C", str(src), "pull", "--ff-only", "origin", "main"],
                                      text=True, timeout=30, stderr=subprocess.STDOUT)
    except subprocess.CalledProcessError as exc:
        raise ValueError(f"codex 스냅샷 git pull 실패: {(exc.output or '').strip()[-200:]}")
    except Exception as exc:
        raise ValueError(f"codex 갱신 실패: {exc}")
    return {"ok": True, "harness": "codex", "installed": _git_head(src), "output": out.strip()[-160:]}


def update_claude() -> dict[str, Any]:
    # claude 는 plugin marketplace update → plugin update 두 단계로 설치 복사본을 교체
    if os.environ.get("MARINA_UPDATE_CLAUDE_DRY_RUN") == "1":
        MARINA_HOME.mkdir(parents=True, exist_ok=True)
        with (MARINA_HOME / "update-claude-dry-run.log").open("a", encoding="utf-8") as fh:
            fh.write("would run: claude plugin marketplace update marina-dev && claude plugin update marina@marina-dev\n")
        return {"ok": True, "harness": "claude", "output": "(dry-run)", "installed": _installed_sha()}
    try:
        out1 = subprocess.check_output(
            [_bin("claude"), "plugin", "marketplace", "update", "marina-dev"],
            text=True, timeout=60, stderr=subprocess.STDOUT,
        )
    except subprocess.CalledProcessError as exc:
        raise ValueError(f"claude marketplace update 실패: {(exc.output or '').strip()[-200:]}")
    except Exception as exc:
        raise ValueError(f"claude 마켓플레이스 갱신 실패: {exc}")
    try:
        out2 = subprocess.check_output(
            [_bin("claude"), "plugin", "update", "marina@marina-dev"],
            text=True, timeout=60, stderr=subprocess.STDOUT,
        )
    except subprocess.CalledProcessError as exc:
        raise ValueError(f"claude plugin update 실패: {(exc.output or '').strip()[-200:]}")
    except Exception as exc:
        raise ValueError(f"claude 플러그인 업데이트 실패: {exc}")
    combined = (out1.strip() + "\n" + out2.strip()).strip()[-160:]
    return {"ok": True, "harness": "claude", "installed": _installed_sha(), "output": combined}


def update_status() -> dict[str, Any]:
    serving, installed, origin = _serving_sha(), _installed_sha(), _origin_sha()
    return {
        "serving": serving,
        "installed": installed,
        "origin": origin,
        "state": update_state(serving, installed, origin),
        "harnesses": _harnesses(),
        "harnessStatus": _harness_status(),
    }


def project_label(root: Path) -> str:
    # 루트 레포 라벨 — 소속 프로젝트 root basename.
    project = project_for(root)
    return project["root"].name if project else root.name


def _expand_worktree_glob(project_root: Path, pattern: str) -> list[Path]:
    # worktreeGlobs 항목 전개. 절대(~ 포함)면 그대로, 상대면 프로젝트 root 기준.
    pat = os.path.expanduser(pattern)
    if not os.path.isabs(pat):
        pat = str(project_root / pat)
    return [Path(p) for p in glob.glob(pat)]


def _glob_source(pattern: str) -> str:
    # 카드 라벨용 출처 태그 — codex 레이아웃(~/.codex/worktrees/...)인지로 구분.
    return "codex" if ".codex" in pattern else "claude"


_root_sources: dict[str, str] = {}
_roots_cache: list[tuple[float, list[Path]]] = []
DISCOVER_TTL = 60.0


def discover_all_roots(refresh: bool = False) -> list[Path]:
    # 전수 목록 — worktree 정리 패널·safe_root 용. 등록된 모든 프로젝트 × worktreeGlobs 를 전개.
    # 폴링 틱마다 glob+resolve 를 돌리지 않게 60s 캐시 (새 worktree 는 최대 60s 늦게 보임 — Refresh 가 즉시 무효화)
    # clear()(remove 경로)와의 경합 대비 — 길이 체크와 인덱스 접근 사이가 안 벌어지게 슬라이스 스냅샷
    snapshot = _roots_cache[:]
    if not refresh and snapshot and time.time() - snapshot[0][0] < DISCOVER_TTL:
        return snapshot[0][1]
    if refresh:
        # 명시 Refresh — 레지스트리(projects.json)와 파생 캐시도 재로드 (marina project add 후 즉시 반영)
        _projects_cache.clear()
        _source_root_cache.clear()
        _session_id_cache.clear()
    roots: list[Path] = []
    seen: set[Path] = set()
    sources: dict[str, str] = {}
    for project in load_projects():
        proot = project["root"]
        try:
            rproot = proot.resolve()
        except OSError:
            rproot = proot
        if rproot not in seen and rproot.is_dir():
            roots.append(rproot)
            seen.add(rproot)
            sources[str(rproot)] = "main"
        for pattern in project["worktreeGlobs"]:
            src = _glob_source(pattern)
            for match in _expand_worktree_glob(proot, pattern):
                try:
                    resolved = match.resolve()
                except OSError:
                    continue
                if resolved in seen or not resolved.is_dir():
                    continue
                # worktree 후보는 .git 존재만 확인 (옛 fork 도 정리 대상으로 보이게)
                if not (resolved / ".git").exists():
                    continue
                roots.append(resolved)
                seen.add(resolved)
                sources[str(resolved)] = src
    # ThreadingHTTPServer 동시 요청 대비: 로컬에서 채운 뒤 한 번에 교체
    _root_sources.update(sources)
    _roots_cache[:] = [(time.time(), roots)]
    return roots


def root_source(root: Path) -> str:
    return _root_sources.get(str(root), "unknown")


def has_attached_subrepos(root: Path) -> bool:
    # 디렉토리만 있고 .git 링크가 없는 attach 중간 상태는 미attach 로 본다
    return any((root / repo / ".git").exists() for repo in subrepos_of(root))


def discover_roots() -> list[Path]:
    # 세션(관제) 목록 = 전수. 과거엔 claude 수십 개의 폴링 부담 때문에 "활성화된 것만"
    # 2계층으로 나눴지만, listener map 단일화·status 캐시로 틱이 충분히 싸져 통합 (카드는 기본 접힘).
    return discover_all_roots()


def is_source_checkout(root: Path) -> bool:
    # 원본(main) 체크아웃 판정. 레지스트리 우선 — root 가 등록된 프로젝트 root 자신이면 main.
    # (단일/모노레포 subrepos=[] 도 커버 — fs 판정만이면 서브레포 없는 프로젝트의 main 을 놓침)
    # 미등록 root 는 서브레포 .git 디렉토리(실제 레포 vs worktree 의 gitdir 파일)로 폴백.
    project = project_for(root)
    if project:
        try:
            return project["root"].resolve() == root.resolve()
        except OSError:
            return project["root"] == root
    return any((root / repo / ".git").is_dir() for repo in subrepos_of(root))


_session_id_cache: dict[str, str] = {}


def session_id(root: Path) -> str:
    # marina.sh session_id() 와 동일 규칙. codex 레이아웃은 <id>/<projectBasename> → 부모명,
    # claude 레이아웃은 .claude/worktrees/<name> 그 자체가 루트 → 자신명.
    # (dirname 일괄 적용이면 claude worktree 가 전부 "worktrees" 로 뭉개진다)
    key = str(root)
    if key not in _session_id_cache:
        if is_source_checkout(root):
            sid = "main"
        else:
            project = project_for(root)
            if project and root.name == project["root"].name:
                sid = root.parent.name  # codex <id>/<projectBasename>
            else:
                sid = root.name  # claude .claude/worktrees/<name>
        _session_id_cache[key] = sid
    return _session_id_cache[key]


def session_dir(root: Path) -> Path:
    # marina 우선, 구 dev-sessions 폴백 — 기존 worktree 세션 데이터(alias·overrides·로그) 보존.
    # 1회 mv 마이그레이션은 루트 marina.sh 진입점에서만 수행한다 (bash session_data_dir 와 동일 규칙).
    base = root / ".workspace" / "marina"
    if not base.is_dir() and (root / ".workspace" / "dev-sessions").is_dir():
        base = root / ".workspace" / "dev-sessions"
    return base / session_id(root)


def config_path(root: Path) -> Path:
    return session_dir(root) / "overrides.env"


def meta_path(root: Path) -> Path:
    return session_dir(root) / "meta.json"


def read_meta(root: Path) -> dict[str, str]:
    try:
        data = json.loads(meta_path(root).read_text(encoding="utf-8"))
    except Exception:
        return {"alias": ""}
    alias = str(data.get("alias", "")).strip()
    return {"alias": alias}


def write_meta(root: Path, updates: dict[str, str]) -> dict[str, str]:
    meta = read_meta(root)
    if "alias" in updates:
        meta["alias"] = updates["alias"].strip()[:40]
    path = meta_path(root)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(meta, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    return meta


def read_config(root: Path) -> dict[str, str]:
    config = dict(CONFIG_DEFAULTS)
    defaults = default_ports_for(root)
    for service in services_for(root):
        port = defaults.get(service, "")
        config[config_key_for_service_port(service)] = port
        config[f"SERVICE_PROFILE_{service.upper()}"] = "local"
    try:
        lines = config_path(root).read_text(encoding="utf-8").splitlines()
    except FileNotFoundError:
        return config

    for line in lines:
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        if key in config:
            config[key] = value
    return config


def write_config(root: Path, updates: dict[str, str]) -> dict[str, str]:
    config = read_config(root)
    for key, value in updates.items():
        if key not in config:
            raise ValueError(f"unknown config key: {key}")
        config[key] = value.strip()

    # 검증은 이번에 바꾸는 키(updates)로 한정 — 레거시 범위 밖 값이 파일에 남아 있어도
    # 무관한 키 저장이 막히는 false positive 방지
    for key in updates:
        value = str(config.get(key, ""))
        if key.startswith("SERVICE_PORT_") and value and not value.isdigit():
            raise ValueError(f"{key} 는 숫자만 허용")

    path = config_path(root)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("".join(f"{key}={value}\n" for key, value in sorted(config.items())), encoding="utf-8")
    return config


def log_dir(root: Path, service: str) -> Path:
    return session_dir(root) / "logs" / service


def service_log(root: Path, service: str) -> Path:
    return session_dir(root) / f"{service}.log"


def log_runs(root: Path, service: str) -> list[Path]:
    return sorted(log_dir(root, service).glob("run-*.log"), reverse=True)


def log_run_payload(root: Path, service: str) -> list[dict[str, str]]:
    runs = []
    current = service_log(root, service)
    try:
        current_target = current.resolve()
    except FileNotFoundError:
        current_target = None

    for path in log_runs(root, service):
        label = path.stem
        if current_target and path.resolve() == current_target:
            label = f"{label} (current)"
        try:
            stat = path.stat()
            kb = stat.st_size // 1024
            size_text = f"{kb / 1024:.1f}MB" if kb >= 1024 else f"{kb}KB"
            stamp = time.strftime("%m/%d %H:%M", time.localtime(stat.st_mtime))
            label = f"{label} · {stamp} · {size_text}"
        except OSError:
            pass
        runs.append({"id": path.name, "label": label})
    return runs


def next_log_path(root: Path, service: str) -> Path:
    directory = log_dir(root, service)
    directory.mkdir(parents=True, exist_ok=True)
    seq_path = session_dir(root) / f"{service}.seq"
    try:
        seq = int(seq_path.read_text().strip())
    except Exception:
        seq = 0
    seq += 1
    seq_path.write_text(f"{seq:03d}\n", encoding="utf-8")
    path = directory / f"run-{seq:03d}.log"
    path.write_text("", encoding="utf-8")

    current = service_log(root, service)
    current.unlink(missing_ok=True)
    current.symlink_to(path)

    keep = int(_env("LOG_KEEP", "10"))
    if keep > 0:
        # 사전순은 run-1000 < run-999 로 역전 → 숫자 키 정렬
        def run_seq(p: Path) -> int:
            match = re.search(r"run-(\d+)\.log", p.name)
            return int(match.group(1)) if match else 0

        for old in sorted(directory.glob("run-*.log"), key=run_seq)[:-keep]:
            if old != path:
                old.unlink(missing_ok=True)
    return path


def ensure_current_log(root: Path, service: str) -> Path:
    current = service_log(root, service)
    if current.exists():
        return current
    return next_log_path(root, service)


def selected_log(root: Path, service: str, run: str | None) -> Path:
    if not run or run == "current":
        return ensure_current_log(root, service)
    if not re.fullmatch(r"run-\d{3}\.log", run):
        raise ValueError("unknown log run")
    path = log_dir(root, service) / run
    if not path.is_file():
        raise ValueError("unknown log run")
    return path


ANSI_RE = re.compile(r"\x1b\[[0-9;]*m")
# 클라 detectLogLevel 과 동일 판정 — 한쪽 수정 시 반드시 양쪽 동기화 (게이지 매치 ↔ 화면 강조 일치)
_TB_START_RE = re.compile(r"Traceback \(most recent call last\)")
_TB_CONT_RE = re.compile(r"^[ \t]")
_TB_END_RE = re.compile(r"^[\w.]+(Error|Exception|Exit|Interrupt|Warning)\b")
_ERR_PATTERNS = (
    re.compile(r"^\s*(Caused by\b|at [\w.$<>/]+\()"),
    re.compile(r"\[(error|window\.error|unhandledrejection)\]", re.IGNORECASE),
    re.compile(r"\b(ERROR|FATAL|SEVERE)\b"),
    re.compile(r"\b[\w.]*(Exception|Error):"),
    re.compile(r"Exception|Traceback"),
)
_WARN_PATTERNS = (re.compile(r"\[warn\]", re.IGNORECASE), re.compile(r"\bWARN(ING)?\b"))


def _detect_log_level(plain: str, state: dict[str, Any]) -> str:
    if _TB_START_RE.search(plain):
        state["tb"] = True
        return "err"
    if state.get("tb"):
        if _TB_CONT_RE.search(plain) or plain == "":
            return "err"
        state["tb"] = False
        if _TB_END_RE.search(plain):
            return "err"
    for pattern in _ERR_PATTERNS:
        if pattern.search(plain):
            return "err"
    for pattern in _WARN_PATTERNS:
        if pattern.search(plain):
            return "warn"
    return ""


LOG_MATCH_CAP = 2000


# 파일 전체를 한 번 훑어 필터/에러 매치 라인을 수집 — 매치 전용 뷰·게이지 틱·점프용
def scan_log_matches(path: Path, query: str, err_only: bool) -> dict[str, Any]:
    query_lower = query.lower()
    matches: list[dict[str, Any]] = []
    total = 0
    state: dict[str, Any] = {}
    offset = 0
    with path.open("rb") as handle:
        for raw in handle:
            start = offset
            offset += len(raw)
            text = raw.decode("utf-8", errors="replace").rstrip("\r\n")
            redacted = redact_text(text)
            plain = ANSI_RE.sub("", redacted)
            if err_only and not _detect_log_level(plain, state):
                continue
            if query_lower and query_lower not in plain.lower():
                continue
            total += 1
            if len(matches) < LOG_MATCH_CAP:
                # 텍스트는 redact 만 — ANSI 는 클라 렌더러가 색으로 살린다
                matches.append({"o": start, "t": redacted})
    return {"matches": matches, "total": total, "size": offset, "truncated": total > len(matches)}


# 청크 바이트를 라인 단위로 — 각 라인에 파일 내 끝 오프셋(e)을 달아 클라가 표시 창을 추적
def _chunk_lines(data: bytes, start: int) -> list[dict[str, Any]]:
    pieces = data.split(b"\n")
    items: list[dict[str, Any]] = []
    pos = start
    for raw in pieces[:-1]:
        pos += len(raw) + 1
        items.append({"t": redact_text(raw.decode("utf-8", errors="replace")), "e": pos})
    tail = pieces[-1]
    if tail:  # 개행 없는 꼬리 — EOF 직전이거나 초장문 라인 절단
        pos += len(tail)
        items.append({"t": redact_text(tail.decode("utf-8", errors="replace")), "e": pos})
    return items


# before(역방향)/after(정방향) 한 청크를 라인 경계로 정렬해 반환 — 무한 스크롤 페이징
def read_log_chunk(path: Path, before: int | None = None, after: int | None = None) -> dict[str, Any]:
    size = path.stat().st_size
    if after is not None:
        start = max(0, min(after, size))
        with path.open("rb") as handle:
            if start > 0:
                # 게이지 시크 등 임의 오프셋 허용 — 라인 중간이면 다음 경계로 정렬
                handle.seek(start - 1)
                if handle.read(1) != b"\n":
                    handle.readline()
                start = handle.tell()
            else:
                handle.seek(0)
            data = handle.read(LOG_CHUNK_BYTES)
        end = start + len(data)
        if end < size and not data.endswith(b"\n"):
            cut = data.rfind(b"\n")
            if cut >= 0:
                # 마지막 라인이 중간에서 잘림 — 버리고 다음 페이지 경계로 넘긴다
                data = data[:cut + 1]
                end = start + cut + 1
    else:
        before = max(0, min(before or 0, size))
        start = max(before - LOG_CHUNK_BYTES, 0)
        with path.open("rb") as handle:
            handle.seek(start)
            data = handle.read(before - start)
        end = before
        if start > 0:
            cut = data.find(b"\n")
            if cut >= 0:
                # 첫 라인이 중간에서 잘림 — 버리고 다음 페이지 경계로 넘긴다
                start += cut + 1
                data = data[cut + 1:]
    return {
        "lines": _chunk_lines(data, start),
        "start": start,
        "end": end,
        "size": size,
        "atStart": start == 0,
        "atEnd": end >= size,
    }


def pid_file(root: Path, service: str) -> Path:
    return session_dir(root) / f"{service}.pid"


_source_root_cache: dict[str, Path] = {}


def source_root_for(root: Path) -> Path:
    # 이 worktree 가 속한 프로젝트의 원본(main) 체크아웃. 레지스트리 우선, git 토폴로지 폴백.
    key = str(root)
    cached = _source_root_cache.get(key)
    if cached is None:
        project = project_for(root)
        cached = project["root"] if project else (_git_main_checkout(root) or root)
        _source_root_cache[key] = cached
    return cached


def script(root: Path) -> Path:
    # 런처는 이 레포의 전역 marina.sh — worktree 위치와 무관 (구 SCRIPT_REL = 워크스페이스 내부 사본 탐색 제거).
    return MARINA_SCRIPT


def marina_env(root: Path, ignore_overrides: bool = False) -> dict[str, str]:
    source = source_root_for(root)
    env = {**os.environ, "ROOT": str(root)}
    if source != root:
        env["SOURCE_ROOT"] = str(source)
    # 전역 런처에 프로젝트 서브레포를 전달 (marina.sh 가 하드코딩 대신 받아 쓴다)
    env["MARINA_SUBREPOS"] = " ".join(subrepos_of(root))
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


def invalidate_registry_caches() -> None:
    # 레지스트리 변경(add/rm) 후 파생 캐시 무효화 — 다음 폴링/요청이 projects.json 을 재로드.
    _projects_cache.clear()
    _roots_cache.clear()
    _root_sources.clear()
    _source_root_cache.clear()
    _session_id_cache.clear()
    _worktree_info_cache.clear()


def git_output(args: list[str], cwd: Path) -> str:
    return subprocess.check_output(["git", *args], cwd=str(cwd), text=True, stderr=subprocess.STDOUT)


def status_lines(repo: Path, ignore_top_level: set[str] | None = None) -> list[str]:
    try:
        output = git_output(["status", "--porcelain", "--untracked-files=all"], repo)
    except Exception as exc:
        return [f"!! git status failed: {exc}"]
    lines: list[str] = []
    for line in output.splitlines():
        path = line[3:] if len(line) > 3 else ""
        top = path.split("/", 1)[0]
        if ignore_top_level and top in ignore_top_level:
            continue
        lines.append(line)
    return lines


def worktree_status(root: Path) -> dict[str, Any]:
    repos: list[dict[str, Any]] = []
    subrepos = subrepos_of(root)
    root_lines = status_lines(root, {*subrepos, ".workspace"})
    repos.append({
        "name": project_label(root),
        "path": str(root),
        "dirty": bool(root_lines),
        "changes": root_lines[:80],
        "changeCount": len(root_lines),
    })
    for repo in subrepos:
        path = root / repo
        if not path.exists():
            repos.append({
                "name": repo,
                "path": str(path),
                "missing": True,
                "dirty": False,
                "changes": [],
                "changeCount": 0,
            })
            continue
        lines = status_lines(path)
        repos.append({
            "name": repo,
            "path": str(path),
            "dirty": bool(lines),
            "changes": lines[:80],
            "changeCount": len(lines),
        })
    dirty = [item for item in repos if item.get("dirty")]
    return {"clean": not dirty, "repos": repos}


def config_key_for_service_port(service: str) -> str:
    return f"SERVICE_PORT_{service.upper()}"


_offset_cache: dict[str, int] = {}


def _posix_cksum(data: bytes) -> int:
    # POSIX cksum(CRC-32/CKSUM) — bash port_offset() 의 `cksum` 폴백과 동일 값.
    # claude worktree 이름(비-hex)이 많아져 fork 위임 대신 내장 계산.
    crc = 0
    for byte in data:
        crc ^= byte << 24
        for _ in range(8):
            crc = ((crc << 1) ^ 0x04C11DB7) & 0xFFFFFFFF if crc & 0x80000000 else (crc << 1) & 0xFFFFFFFF
    length = len(data)
    while length:
        crc ^= (length & 0xFF) << 24
        for _ in range(8):
            crc = ((crc << 1) ^ 0x04C11DB7) & 0xFFFFFFFF if crc & 0x80000000 else (crc << 1) & 0xFFFFFFFF
        length >>= 8
    return (~crc) & 0xFFFFFFFF


def port_offset_for(root: Path) -> int:
    # marina.sh port_offset() 의 파이썬 이식. 결과는 항상 10~89 (main 은 0).
    # 서비스 포트 = portBase + offset (해시 기반이라 worktree 마다 안정적으로 다른 대역)
    key = str(root)
    if key in _offset_cache:
        return _offset_cache[key]
    if is_source_checkout(root):
        offset = 0
    else:
        sid = session_id(root)
        if re.fullmatch(r"[0-9a-fA-F]+", sid):
            offset = (int(sid[-4:], 16) % 80) + 10
        else:
            offset = (_posix_cksum(sid.encode("utf-8")) % 80) + 10
    _offset_cache[key] = offset
    return offset


def read_overrides(root: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    try:
        lines = config_path(root).read_text(encoding="utf-8").splitlines()
    except FileNotFoundError:
        return values
    for line in lines:
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        values[key] = value
    return values


def default_ports_for(root: Path) -> dict[str, str]:
    offset = port_offset_for(root)
    return {service: str(base + offset) for service, base in port_base_for(root).items()}


def ports_for(root: Path) -> dict[str, str]:
    overrides = read_overrides(root)
    ports: dict[str, str] = {}
    for service, default in default_ports_for(root).items():
        ports[service] = overrides.get(config_key_for_service_port(service)) or default
    return ports


def listener_map() -> dict[str, list[int]]:
    # 전체 LISTEN 포트→pid 맵 — 폴링 틱마다 세션×서비스별 lsof(15~20회)를 1회로 줄인다
    try:
        output = subprocess.check_output(
            ["lsof", "-nP", "-iTCP", "-sTCP:LISTEN", "-Fpn"],
            text=True,
            stderr=subprocess.DEVNULL,
        )
    except Exception:
        return {}
    result: dict[str, set[int]] = {}
    pid: int | None = None
    for line in output.splitlines():
        if line.startswith("p"):
            try:
                pid = int(line[1:])
            except ValueError:
                pid = None
        elif line.startswith("n") and pid is not None:
            port = line.rsplit(":", 1)[-1]
            if port.isdigit():
                result.setdefault(port, set()).add(pid)
    return {port: sorted(pids) for port, pids in result.items()}


def listener_pids(port: str) -> list[int]:
    try:
        output = subprocess.check_output(
            ["lsof", "-tiTCP:" + port, "-sTCP:LISTEN"],
            text=True,
            stderr=subprocess.DEVNULL,
        )
    except Exception:
        return []
    pids: list[int] = []
    for line in output.splitlines():
        line = line.strip()
        if line.isdigit():
            pids.append(int(line))
    return pids


def pid_alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
        return True
    except OSError:
        return False


def read_pid(path: Path) -> int | None:
    try:
        text = path.read_text().strip()
    except FileNotFoundError:
        return None
    return int(text) if text.isdigit() else None


def process_snapshot() -> list[dict[str, Any]]:
    try:
        output = subprocess.check_output(
            ["ps", "axo", "pid=,pgid=,rss=,etime=,command="],
            text=True,
            stderr=subprocess.DEVNULL,
        )
    except Exception:
        return []
    rows: list[dict[str, Any]] = []
    for line in output.splitlines():
        parts = line.split(None, 4)
        if len(parts) < 5:
            continue
        try:
            rows.append({
                "pid": int(parts[0]),
                "pgid": int(parts[1]),
                "rssKb": int(parts[2]),
                "etime": parts[3],
                "command": parts[4],
            })
        except ValueError:
            continue
    return rows


_total_mem_mb_cache: list[int] = []


def system_memory() -> dict[str, Any]:
    info: dict[str, Any] = {"totalMb": None, "freePercent": None, "freeMb": None}
    if not _total_mem_mb_cache:
        try:
            total = int(subprocess.check_output(["sysctl", "-n", "hw.memsize"], text=True, stderr=subprocess.DEVNULL).strip())
            _total_mem_mb_cache.append(total // (1024 * 1024))
        except Exception:
            return info
    info["totalMb"] = _total_mem_mb_cache[0]
    try:
        output = subprocess.check_output(["memory_pressure", "-Q"], text=True, stderr=subprocess.DEVNULL)
        match = re.search(r"free percentage:\s*(\d+)", output)
        if match:
            info["freePercent"] = int(match.group(1))
            info["freeMb"] = info["totalMb"] * info["freePercent"] // 100
    except Exception:
        pass
    return info


def group_rss_mb(snapshot: list[dict[str, Any]], pids: set[int]) -> int:
    # 추적 pid 들이 속한 프로세스 그룹 전체의 RSS 합 (MB)
    if not pids:
        return 0
    pgids = {row["pgid"] for row in snapshot if row["pid"] in pids}
    total_kb = 0
    for row in snapshot:
        if row["pid"] in pids or row["pgid"] in pgids:
            total_kb += row["rssKb"]
    return total_kb // 1024


def terminate_pid_tree(pid: int, sig: int) -> None:
    # 가능하면 프로세스 그룹 전체, 아니면 단일 pid. 자기 그룹·init 그룹은 그룹 kill 제외.
    try:
        pgid = os.getpgid(pid)
    except OSError:
        pgid = None
    if pgid and pgid > 1 and pgid != os.getpgrp():
        # pgid 조회 후 pid 가 죽고 pgid 가 재사용됐을 수 있다 → killpg 직전 생존 재확인
        if pid_alive(pid):
            try:
                os.killpg(pgid, sig)
                return
            except OSError:
                pass
    try:
        os.kill(pid, sig)
    except OSError:
        pass


def wait_pids_gone(pids: set[int], timeout: float) -> bool:
    deadline = time.time() + timeout
    while time.time() < deadline:
        if not any(pid_alive(pid) for pid in pids):
            return True
        time.sleep(0.1)
    return not any(pid_alive(pid) for pid in pids)


# 헬스 3단계 — 포트 LISTEN 만으로는 빌드/부팅 시간이 ON 으로 보이는 문제의 해소.
# ok 판정 후 TTL 동안 재프로브를 쉬어 access 로그 오염을 분당 1줄로 제한.
_health_state: dict[str, dict[str, float]] = {}
HEALTH_OK_TTL = 60.0
# bad 는 "응답하던 서비스가 멎음"에만 적용 (everOk 게이트). 부팅(첫 응답 전)은 아무리
# 길어도 BOOT 유지 — 타이머 기반 오판(콜드 컴파일이 임계 초과 → ERR)이 실측으로 확인돼 제거.
HEALTH_BAD_AFTER = float(_env("HEALTH_BAD_AFTER", "60"))


def probe_http(port: str, timeout: float = 2.5) -> bool:
    # 응답 수신 = 부팅 완료. 상태코드는 무관 — be·uvicorn 의 GET / 는 404 가 정상이다.
    # 동기 호출이라 "LISTEN 인데 무응답" 서비스가 동시에 여럿이면 폴링 응답이 그만큼 밀린다
    # (ok 60s 캐시 + listener 없는 starting 은 프로브 0회라 평시엔 0~1회/틱).
    try:
        urllib.request.urlopen(f"http://localhost:{port}/", timeout=timeout)
        return True
    except urllib.error.HTTPError:
        return True
    except Exception:
        return False


def reset_health(root: Path, service: str) -> None:
    # stop→start 가 폴링 틱 사이에 끝나면 정지 틱을 못 봐 stale ok 가 남는다 → 전이 지점에서 명시 리셋
    _health_state.pop(f"{root}::{service}", None)


def service_health(root: Path, service: str, port: str | None, listening: bool) -> str:
    # ThreadingHTTPServer 동시 요청이 같은 키를 만질 수 있다 — clear() 로 내부를 비우는 대신
    # pop 으로 dict 자체를 떼어내 경쟁 창을 좁힌다 (로컬 단일 사용자 도구라 lock 은 과설계)
    key = f"{root}::{service}"
    now = time.time()
    if not listening or not port:
        # 프로세스는 살아있는데 LISTEN 전 (빌드·부팅 초기) — 프로브 무의미.
        # everOk 는 보존 — lsof 스냅샷이 한 틱 miss 돼도 "응답하던 서비스" 이력이 유지돼
        # 복귀 후 무응답이면 bad 가 제때 뜬다 (완전 리셋은 stop/start 의 reset_health 가 담당)
        state = _health_state.get(key)
        if state:
            state.pop("okUntil", None)
            state.pop("failSince", None)
        return "starting"
    state = _health_state.setdefault(key, {})
    if state.get("okUntil", 0.0) > now:
        return "ok"
    if probe_http(port):
        state["okUntil"] = now + HEALTH_OK_TTL
        state["everOk"] = 1.0
        state.pop("failSince", None)
        return "ok"
    if not state.get("everOk"):
        # 첫 응답 전 = 부팅 중. 콜드 컴파일·풀빌드가 며칠씩 느려져도 ERR 오판 없이 BOOT 유지
        return "starting"
    fail_since = state.setdefault("failSince", now)
    return "bad" if now - fail_since >= HEALTH_BAD_AFTER else "starting"


def service_status(
    root: Path,
    service: str,
    port: str | None,
    snapshot: list[dict[str, Any]] | None = None,
    listeners_by_port: dict[str, list[int]] | None = None,
) -> dict[str, Any]:
    tracked_pid = read_pid(pid_file(root, service))
    tracked_alive = bool(tracked_pid and pid_alive(tracked_pid))
    if tracked_pid and not tracked_alive:
        pid_file(root, service).unlink(missing_ok=True)
        tracked_pid = None
    if listeners_by_port is not None:
        listeners = listeners_by_port.get(port, []) if port else []
    else:
        listeners = listener_pids(port) if port else []
    running = tracked_alive or bool(listeners)
    pids = set(listeners)
    if tracked_pid:
        pids.add(tracked_pid)
    if running:
        health = service_health(root, service, port, bool(listeners))
    else:
        health = None
        reset_health(root, service)
    return {
        "service": service,
        "port": port,
        "running": running,
        "health": health,
        "trackedPid": tracked_pid,
        "trackedAlive": tracked_alive,
        "listenerPids": listeners,
        "rssMb": group_rss_mb(snapshot, pids) if snapshot is not None else None,
        "log": str(service_log(root, service)),
        "logRuns": log_run_payload(root, service),
    }


_status_cache: dict[str, tuple[float, dict[str, Any]]] = {}


def worktree_status_cached(root: Path, ttl: float = 15.0) -> dict[str, Any]:
    # dirty 표시는 5초 신선도가 필요 없다 — git status(레포 4개)를 폴링 핫패스에서 떼어냄.
    # 정확성이 필요한 경로(remove 가드·Changes 조회)는 worktree_status 직접 호출.
    key = str(root)
    cached = _status_cache.get(key)
    if cached and time.time() - cached[0] < ttl:
        return cached[1]
    status = worktree_status(root)
    _status_cache[key] = (time.time(), status)
    return status


def _read_services_file(path: Path) -> list[dict[str, Any]]:
    # 한 서비스 정의 파일 파싱 → 검증된 full dict 목록 (없거나 비-dict → []).
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        return []
    if not isinstance(data, dict):
        return []
    out: list[dict[str, Any]] = []
    for item in data.get("services", []):
        name = str(item.get("name", "")).strip()
        base = item.get("portBase")
        if name and name.isidentifier() and isinstance(base, int) and name not in _BUILTIN_SERVICES:
            orphan = item.get("orphanPattern")
            out.append({
                "name": name, "portBase": base,
                "cwd": str(item.get("cwd", "")), "run": str(item.get("run", "")),
                "cachePaths": [str(c) for c in item.get("cachePaths", []) if isinstance(c, str)],
                "orphanPattern": orphan if isinstance(orphan, str) else None,
            })
    return out


def extra_services_for(root: Path) -> list[dict[str, Any]]:
    # root(팀) ∪ 중앙(개인) 서비스. name 겹치면 중앙 우선. 각 항목 source 태그.
    project = project_for(root)
    proot = Path(project["root"]) if project else root
    merged: dict[str, dict[str, Any]] = {}
    for s in _read_services_file(proot / "marina-services.json"):
        merged[s["name"]] = {**s, "source": "root"}
    if project:
        for s in _read_services_file(MARINA_HOME / "services" / f"{project['id']}.json"):
            merged[s["name"]] = {**s, "source": "central"}
    return list(merged.values())


def services_for(root: Path) -> tuple[str, ...]:
    # root 가 속한 프로젝트의 서비스명 (per-project).
    # 과거 전역 EXTRA_SERVICES("첫 프로젝트" 하나만 반영)가 모든 프로젝트에 누수되던 것을 root 기준 per-project 해석으로 교체.
    # — 서비스 정의 파일 없는 프로젝트(예: homeserver)는 서비스 0개가 정상.
    return _BUILTIN_SERVICES + tuple(s["name"] for s in extra_services_for(root))


def port_base_for(root: Path) -> dict[str, int]:
    return {**_BUILTIN_PORT_BASE, **{s["name"]: s["portBase"] for s in extra_services_for(root)}}


def log_targets_for(root: Path) -> tuple[str, ...]:
    return (*services_for(root), "console")


# marina 가 띄울 수 있는 프로세스 패턴 — 세션 추적 밖에서 돌면 "유령"으로 표시.
# 내장은 marina 런처 자신(marina.sh)뿐 — 서비스별 패턴은 marina-services.json 의 orphanPattern(정규식)에서 온다.
# 느슨하면 grep 등 패턴 문자열을 들고 있는 셸 명령까지 오탐하니 실제 기동 cmdline 형태로 조인다.
_BASE_ORPHAN_RULES: list[tuple[str, re.Pattern[str]]] = [
    ("marina", re.compile(r"marina\.sh (?:foreground|start)")),
]


def orphan_rules_for(root: Path) -> list[tuple[str, "re.Pattern[str]"]]:
    rules: list[tuple[str, re.Pattern[str]]] = list(_BASE_ORPHAN_RULES)
    for svc in extra_services_for(root):
        pat = svc.get("orphanPattern")
        if isinstance(pat, str) and pat:
            try:
                rules.append((str(svc["name"]), re.compile(pat)))
            except re.error:
                pass
    return rules


def orphan_rules_all() -> list[tuple[str, "re.Pattern[str]"]]:
    # 시스템 전역 sweep 용 — 등록된 모든 프로젝트의 규칙 합집합 (패턴 문자열로 dedup).
    seen: set[str] = set()
    rules: list[tuple[str, re.Pattern[str]]] = []
    for name, pat in _BASE_ORPHAN_RULES:
        key = f"{name}:{pat.pattern}"
        if key not in seen:
            seen.add(key)
            rules.append((name, pat))
    for root in discover_roots():
        for name, pat in orphan_rules_for(root):
            key = f"{name}:{pat.pattern}"
            if key not in seen:
                seen.add(key); rules.append((name, pat))
    return rules


def service_subrepo(cwd: str, subrepos: list[str]) -> str:
    # 서비스 cwd → 소속 subrepo. 등록 subrepo 중 cwd 의 longest-prefix 매치
    #   (projects/react-skeleton 같은 슬래시 subrepo 대응 — '첫 세그먼트' 룰의 한계 보완).
    # 매치 없음: root('.'/빈값) → "" (ungrouped, 카드 상단). 그 외 → 첫 세그먼트(미등록 그룹, 토글 없이 노출).
    norm = cwd.strip().strip("/")
    if not norm or norm == ".":
        return ""
    best = ""
    for s in subrepos:
        if (norm == s or norm.startswith(s + "/")) and len(s) > len(best):
            best = s
    return best or norm.split("/", 1)[0]


def service_subrepo_map(root: Path) -> dict[str, str]:
    # {서비스명: 소속 subrepo} — 서비스 정의 파일의 cwd 기준.
    subs = subrepos_of(root)
    return {s["name"]: service_subrepo(s.get("cwd", ""), subs) for s in extra_services_for(root)}


def _tagged_services(
    root: Path,
    ports: dict[str, str],
    snapshot: list[dict[str, Any]] | None,
    listeners_by_port: dict[str, list[int]] | None,
) -> list[dict[str, Any]]:
    smap = service_subrepo_map(root)
    extra = extra_services_for(root)
    srcmap = {s["name"]: s.get("source", "root") for s in extra}
    defmap = {s["name"]: s for s in extra}
    out: list[dict[str, Any]] = []
    for svc in services_for(root):
        st = service_status(root, svc, ports.get(svc), snapshot, listeners_by_port)
        st["subrepo"] = smap.get(svc, "")
        st["source"] = srcmap.get(svc, "root")
        d = defmap.get(svc)
        if d:
            st["def"] = {
                "portBase": d.get("portBase"),
                "cwd": d.get("cwd", ""),
                "run": d.get("run", ""),
                "cachePaths": d.get("cachePaths", []),
                "orphanPattern": d.get("orphanPattern"),
            }
        out.append(st)
    return out


def session_payload(
    root: Path,
    snapshot: list[dict[str, Any]] | None = None,
    listeners_by_port: dict[str, list[int]] | None = None,
) -> dict[str, Any]:
    ports = ports_for(root)
    return {
        "id": session_id(root),
        "alias": read_meta(root).get("alias", ""),
        "source": root_source(root),
        "root": str(root),
        "ports": ports,
        "config": read_config(root),
        "worktreeStatus": worktree_status_cached(root),
        "services": _tagged_services(root, ports, snapshot, listeners_by_port),
        "consoleLogRuns": log_run_payload(root, "console"),
    }


def safe_root(root_text: str) -> Path:
    root = Path(root_text).expanduser().resolve()
    allowed = {r.resolve() for r in discover_all_roots()}
    if root not in allowed:
        # 생성 60s 내 새 worktree 가 discover 캐시에 없어 액션이 거부되는 엣지 — 1회 강제 재탐색
        allowed = {r.resolve() for r in discover_all_roots(refresh=True)}
    if root not in allowed:
        raise ValueError("unknown worktree root")
    return root


def safe_service(service: str, root: Path) -> str:
    if service not in log_targets_for(root):
        raise ValueError("unknown service")
    return service


def origin_allowed(origin: str | None, allow_any_local_port: bool) -> bool:
    # Origin 없음(curl·same-origin GET) 은 허용. 그 외에는 localhost 만,
    # 제어 엔드포인트는 대시보드 자신의 포트만 허용 (임의 웹사이트의 CSRF 차단).
    if not origin:
        return True
    try:
        parts = urllib.parse.urlsplit(origin)
    except ValueError:
        return False
    if parts.hostname not in ("127.0.0.1", "localhost", "::1"):
        return False
    if allow_any_local_port:
        return True
    return parts.port == PORT


def root_for_session_id(value: str) -> Path:
    for root in discover_roots():
        if session_id(root) == value:
            return root
    raise ValueError("unknown session")


def redact_text(value: str) -> str:
    redacted = SENSITIVE_ASSIGNMENT_RE.sub(r"\1<redacted>", value)
    redacted = SENSITIVE_JSON_RE.sub(r'\1"<redacted>"', redacted)
    redacted = SENSITIVE_PY_OBJECT_RE.sub(r"\1'<redacted>'", redacted)
    return redacted


def append_console_log(payload: dict[str, Any]) -> dict[str, Any]:
    root = root_for_session_id(str(payload.get("session", "")))
    path = ensure_current_log(root, "console")
    path.parent.mkdir(parents=True, exist_ok=True)

    level = str(payload.get("level", "log"))
    url = str(payload.get("url", ""))
    timestamp = str(payload.get("timestamp", ""))
    args = payload.get("args")
    if not isinstance(args, list):
        args = []

    message = " ".join(redact_text(str(item)) for item in args)
    with path.open("a", encoding="utf-8") as handle:
        handle.write(f"[{timestamp}] [{level}] {url}\n")
        if message:
            handle.write(message + "\n")
        handle.write("\n")

    return {"ok": True}


def stop_service(root: Path, service: str) -> dict[str, Any]:
    ports = ports_for(root)
    port = ports.get(service)
    status = service_status(root, service, port)
    # 구버전 버그: tracked pid 가 없으면 listener kill 을 통째로 건너뛰어 Stop 이 no-op 이었다.
    # 이제 tracked + listener 를 모두 대상에 넣고 TERM → 5s 대기 → KILL 로 에스컬레이션한다.
    targets: set[int] = set(status["listenerPids"])
    if status["trackedPid"] and status["trackedAlive"]:
        targets.add(status["trackedPid"])

    for pid in targets:
        terminate_pid_tree(pid, signal.SIGTERM)
    forced: list[int] = []
    if targets and not wait_pids_gone(targets, 5.0):
        for pid in targets:
            if pid_alive(pid):
                terminate_pid_tree(pid, signal.SIGKILL)
                forced.append(pid)
        wait_pids_gone(targets, 2.0)

    late = [pid for pid in (listener_pids(port) if port else []) if pid not in targets]
    for pid in late:
        terminate_pid_tree(pid, signal.SIGTERM)
    if late and not wait_pids_gone(set(late), 3.0):
        for pid in late:
            if pid_alive(pid):
                terminate_pid_tree(pid, signal.SIGKILL)
                forced.append(pid)

    pid_file(root, service).unlink(missing_ok=True)
    reset_health(root, service)
    result: dict[str, Any] = {"stopped": sorted(targets), "late": late, "forced": forced}
    return result


def stop_all(root: Path) -> dict[str, Any]:
    return {service: stop_service(root, service) for service in services_for(root)}


def cleanup_session(root: Path) -> dict[str, Any]:
    stop_all(root)
    path = session_dir(root)
    if path.exists():
        shutil.rmtree(path)
    return {"removed": str(path)}


def remove_git_worktree(source_repo: Path, target: Path, force: bool = False) -> dict[str, Any]:
    if not target.exists():
        return {"missing": str(target)}
    args = ["worktree", "remove"]
    if force:
        args.append("--force")  # 미커밋 변경·untracked 가 있어도 폐기하고 제거
    args.append(str(target))
    try:
        git_output(args, source_repo)
        return {"removed": str(target)}
    except subprocess.CalledProcessError as exc:
        return {"error": exc.output.strip() or str(exc), "path": str(target)}


def remove_worktree(root: Path, force: bool = False) -> dict[str, Any]:
    # 전역 대시보드는 프로젝트 worktree 밖(marina 레포)에서 돌므로 "자기 세션 삭제" 가드 불요.
    # 원본(main) 보호 — 레지스트리 root 일치(subrepos=[] 단일레포도 커버) 또는 서브레포 .git 존재.
    project = project_for(root)
    if (project and project["root"].resolve() == root.resolve()) or is_source_checkout(root):
        raise ValueError("원본 체크아웃(main)은 삭제할 수 없습니다")

    status = worktree_status(root)
    if not status["clean"] and not force:
        raise ValueError("변경사항이 있어 삭제할 수 없습니다 (force 로 폐기+삭제 가능): " + json.dumps(status, ensure_ascii=False))

    sid = session_id(root)
    stop_all(root)
    cleanup_session(root)
    bootout_session_dashboard(sid)

    # 브랜치/worktree 정리는 원본(main) 체크아웃에서 돌아야 한다 (삭제될 worktree 경로가 아니라).
    main_checkout = source_root_for(root)
    if main_checkout.resolve() == root.resolve():
        raise ValueError("원본 체크아웃을 찾지 못해 삭제를 중단합니다")
    branch = f"codex/{sid}"
    try:
        root_branch = git_output(["branch", "--show-current"], root).strip()
    except Exception:
        root_branch = ""
    results: dict[str, Any] = {"subrepos": {}, "branches": {}, "root": None}
    for repo in subrepos_of(root):
        target = root / repo
        source_repo = main_checkout / repo
        if source_repo.exists():
            removed = remove_git_worktree(source_repo, target, force=force)
            results["subrepos"][repo] = removed
            if "error" not in removed:
                # worktree 가 빠졌으니 codex/<id> 브랜치도 안전 삭제 시도 (미머지면 skipped)
                results["branches"][repo] = delete_merged_branch(source_repo, branch)
        elif target.exists():
            results["subrepos"][repo] = {"error": f"source repo not found: {source_repo}", "path": str(target)}

    results["root"] = remove_git_worktree(main_checkout, root, force=force)
    # 루트 레포 브랜치 정리: claude worktree 는 claude/<id> 를 물고 있음. codex 루트는 보통
    # detached HEAD 라 root_branch 가 비어 스킵되지만, 브랜치 체크아웃이면 동일하게 -d 시도.
    if root_branch and re.match(r"^(codex|claude)/", root_branch) and "removed" in (results["root"] or {}):
        results["branches"][project_label(main_checkout)] = delete_merged_branch(main_checkout, root_branch)
    # codex 레이아웃(<id>/<projectBasename>)은 제거 후 빈 부모 셸 <id>/ 가 남는다 → 정리
    parent = root.parent
    if "removed" in (results["root"] or {}) and root.name == main_checkout.name and parent.parent == WORKTREES_ROOT:
        try:
            if parent.is_dir() and not any(parent.iterdir()):
                parent.rmdir()
                results["parentDir"] = f"removed {parent}"
        except OSError:
            pass
    _worktree_info_cache.pop(str(root), None)
    _roots_cache.clear()  # 삭제된 root 가 60s 캐시에 남지 않게
    return results


def attach_subrepo_action(root: Path, subrepo: str) -> dict[str, Any]:
    # 단일 subrepo 물리 attach — 기존 attach 스크립트 재사용(MARINA_SUBREPOS=<하나>). idempotent + yml/env/venv 동기화.
    source = source_root_for(root)
    if source.resolve() == root.resolve():
        raise ValueError("원본 체크아웃에는 attach 대상이 없습니다")
    env = {
        **os.environ,
        "DEST_ROOT": str(root),
        "SOURCE_ROOT": str(source),
        "MARINA_SUBREPOS": subrepo,
        "SYNC_IDEA": os.environ.get("SYNC_IDEA", "false"),
    }
    try:
        out = subprocess.check_output([str(MARINA_ATTACH)], text=True, stderr=subprocess.STDOUT, env=env)
    except subprocess.CalledProcessError as exc:
        raise ValueError((exc.output or "").strip() or str(exc))
    _worktree_info_cache.pop(str(root), None)
    _status_cache.pop(str(root), None)
    return {"ok": True, "attached": subrepo, "output": out.strip()}


def detach_subrepo_action(root: Path, subrepo: str, force: bool = False, stop_services: bool = False) -> dict[str, Any]:
    target = root / subrepo
    if not (target / ".git").exists():
        return {"ok": True, "detached": subrepo, "note": "already detached"}
    # 1) 이 subrepo 의 구동 중 서비스 — 살아있는 프로세스가 디렉토리를 점유하므로 먼저 정지.
    smap = service_subrepo_map(root)
    ports = ports_for(root)
    running = [
        svc for svc in services_for(root)
        if smap.get(svc) == subrepo and service_status(root, svc, ports.get(svc))["running"]
    ]
    if running and not stop_services:
        return {"needsStop": running}
    for svc in running:
        stop_service(root, svc)
    # 정지 실패(고착 프로세스)면 git worktree remove 가 디렉토리 점유로 모호하게 실패 — 선제로 명확한 에러 반환.
    still_running = [svc for svc in running if service_status(root, svc, ports.get(svc))["running"]]
    if still_running:
        return {"error": f"서비스 정지 실패로 detach 중단: {', '.join(still_running)} (수동 정지 후 재시도)"}
    # 2) dirty working tree — clean 이면 지금 제거, 미커밋 변경 있으면 confirm 후 --force.
    status = worktree_status(root)
    entry = next((r for r in status["repos"] if r["name"] == subrepo), None)
    if entry and entry.get("dirty") and not force:
        return {"needsConfirm": True, "changes": entry.get("changes", [])}
    source_repo = source_root_for(root) / subrepo
    if not source_repo.exists():
        return {"error": f"source repo not found: {source_repo}"}
    # 브랜치는 보존(worktree remove 만) — 미머지 커밋 안전, 재attach 시 재사용.
    res = remove_git_worktree(source_repo, target, force=force)
    _worktree_info_cache.pop(str(root), None)
    _status_cache.pop(str(root), None)
    if "error" in res:
        return res
    return {"ok": True, "detached": subrepo, **res}


def memory_block(force: bool) -> dict[str, Any] | None:
    # 가용 메모리가 기준 미만이면 시작을 막는다 (UI confirm 후 force=true 로 재시도 가능)
    if force:
        return None
    info = system_memory()
    free_mb = info.get("freeMb")
    min_free = int(_env("MIN_FREE_MB", "4096"))
    if free_mb is not None and free_mb < min_free:
        return {"blocked": "low-memory", "freeMb": free_mb, "minFreeMb": min_free}
    return None


def start_service(root: Path, service: str, force: bool = False) -> dict[str, Any]:
    ports = ports_for(root)
    current = service_status(root, service, ports.get(service))
    if current["running"]:
        return {"alreadyRunning": True, "status": current}

    block = memory_block(force)
    if block:
        return block

    # 구버전은 foreground 모드 + 자체 로그 fd 로 띄워서 (1) 시작마다 로그 run 이 2개 생기고
    # (2) fd 가 누수됐다. CLI start 경로로 일원화 — 로그·pid 관리는 marina.sh 가 전담.
    session_dir(root).mkdir(parents=True, exist_ok=True)
    env = marina_env(root)
    # codex worktree 는 dashboard 기동 시 prepare 완료 — claude worktree 는 미attach 면 start 가 attach 수행
    env["MARINA_SKIP_PREPARE"] = "1" if has_attached_subrepos(root) else "0"
    try:
        output = subprocess.check_output(
            [str(script(root)), "start", f"--{service}"],
            cwd=str(root),
            text=True,
            stderr=subprocess.STDOUT,
            env=env,
            timeout=120,
        )
    except subprocess.CalledProcessError as exc:
        raise ValueError(f"start failed: {(exc.output or '')[-500:]}")
    except subprocess.TimeoutExpired:
        raise ValueError("start timed out (120s)")
    reset_health(root, service)
    return {"started": True, "output": output[-1000:]}


def restart_service(root: Path, service: str, force: bool = False) -> dict[str, Any]:
    stop_result = stop_service(root, service)
    time.sleep(0.5)
    start_result = start_service(root, service, force=force)
    if start_result.get("blocked"):
        return {**start_result, "stop": stop_result}
    return {"stop": stop_result, "start": start_result}


_worktree_info_cache: dict[str, tuple[float, dict[str, Any]]] = {}
WORKTREE_INFO_TTL = 600.0


def repo_last_commit_ts(repo: Path) -> int:
    try:
        out = subprocess.check_output(
            ["git", "-C", str(repo), "log", "-1", "--format=%ct"],
            text=True, stderr=subprocess.DEVNULL,
        )
        return int(out.strip() or "0")
    except Exception:
        return 0


def repo_branch(repo: Path) -> str:
    # detached HEAD(codex worktree 루트 기본 상태)는 빈 문자열
    try:
        out = subprocess.check_output(
            ["git", "-C", str(repo), "branch", "--show-current"],
            text=True, stderr=subprocess.DEVNULL,
        )
        return out.strip()
    except Exception:
        return ""


def repo_ahead_of_main(repo: Path) -> int | None:
    # 로컬 main 대비 이 worktree 브랜치에만 있는 커밋 수 (main 없으면 None)
    try:
        subprocess.check_output(
            ["git", "-C", str(repo), "rev-parse", "--verify", "main"],
            stderr=subprocess.DEVNULL,
        )
        out = subprocess.check_output(
            ["git", "-C", str(repo), "rev-list", "--count", "main..HEAD"],
            text=True, stderr=subprocess.DEVNULL,
        )
        return int(out.strip())
    except Exception:
        return None


def disk_usage_mb(path: Path) -> int | None:
    try:
        out = subprocess.check_output(
            ["du", "-sk", str(path)], text=True, stderr=subprocess.DEVNULL, timeout=30,
        )
        return int(out.split()[0]) // 1024
    except Exception:
        return None


def worktree_info(root: Path, refresh: bool = False) -> dict[str, Any]:
    key = str(root)
    cached = _worktree_info_cache.get(key)
    if cached and not refresh and time.time() - cached[0] < WORKTREE_INFO_TTL:
        return cached[1]

    is_main = is_source_checkout(root)
    subs = subrepos_of(root)
    # 물리 attach 상태(fs 판정). main 체크아웃은 원본 클론이라 전부 attach 로 본다.
    attached_subrepos = list(subs) if is_main else [s for s in subs if (root / s / ".git").exists()]
    default_explicit = default_attach_of(root)
    status = worktree_status(root)
    last_ts = 0
    ahead: dict[str, int] = {}
    branches: dict[str, str] = {}
    # claude worktree 는 서브레포가 없는 경우가 많아 root 레포도 활동·ahead 에 포함
    repos_to_scan = [(project_label(root), root)] + [(name, root / name) for name in subrepos_of(root)]
    for repo_name, repo in repos_to_scan:
        if not (repo / ".git").exists():
            continue
        last_ts = max(last_ts, repo_last_commit_ts(repo))
        count = repo_ahead_of_main(repo)
        if count is not None:
            ahead[repo_name] = count
        branch = repo_branch(repo)
        if branch:
            branches[repo_name] = branch
    sdir = session_dir(root)
    if sdir.exists():
        try:
            last_ts = max(last_ts, int(sdir.stat().st_mtime))
        except OSError:
            pass

    ahead_total = sum(ahead.values())
    idle_days = round((time.time() - last_ts) / 86400, 1) if last_ts else None
    stale_days = float(_env("STALE_DAYS", "7"))
    if is_main:
        verdict = "main"
    elif not status["clean"]:
        verdict = "dirty"
    elif ahead_total > 0:
        verdict = "has-commits"
    elif idle_days is not None and idle_days >= stale_days:
        verdict = "stale"
    else:
        verdict = "active"

    cache_by_cat = cache_category_mb(root)
    project = project_for(root)
    info = {
        "id": session_id(root),
        "alias": read_meta(root).get("alias", ""),
        "source": root_source(root),
        "root": str(root),
        # 프로젝트 식별 — 대시보드 좌측 패널 그룹핑 키 (멀티프로젝트)
        "projectId": project["id"] if project else project_label(root),
        "projectLabel": project_label(root),
        "projectRoot": str(project["root"]) if project else str(root),
        # 레지스트리에 등록된 subrepos(큐레이션된 집합) — switcher "subrepos 편집" 프리필용. fs 의 universe(infer)와 구분.
        "subrepos": list(project["subrepos"]) if project else [],
        # 이 worktree 에 물리 attach 된 subrepo (fs 판정; main 은 전부). 클라이언트 트리 attach 상태원.
        "attachedSubrepos": attached_subrepos,
        # 전체 기본 attach 집합 — 명시값 없으면 universe(=전부). main 카드 "기본" 토글 프리필.
        "defaultAttach": default_explicit if default_explicit is not None else list(subs),
        "isMain": is_main,
        "clean": status["clean"],
        # main 체크아웃 전체 du 는 수백 GB 라 비싸고 UI 에서도 안 씀 → 스킵
        "diskMb": None if is_main else disk_usage_mb(root),
        # 캐시는 후보 경로 한정 du(실측 ~0.1s) + TTL 600s — main 도 계산해 Clear cache 노출
        "cacheMb": sum(cache_by_cat.values()),
        "cacheCats": cache_by_cat,
        "idleDays": idle_days,
        "ahead": ahead,
        "aheadTotal": ahead_total,
        "branches": branches,
        "verdict": verdict,
    }
    _worktree_info_cache[key] = (time.time(), info)
    return info


# worktree 안에서 재생성 가능한 빌드 캐시 — Clear cache 대상.
# 카테고리 = 서비스명, 경로 = marina-services.json 의 서비스별 cachePaths(root 상대, glob 가능). 내장 경로 없음.
def cache_guard_services(category: str, root: Path) -> tuple[str, ...]:
    # 캐시 회수 전 가드할 서비스 — 카테고리(서비스명) 자신, "all"이면 cachePaths 가진 전 서비스.
    if category == "all":
        return tuple(s["name"] for s in extra_services_for(root) if s.get("cachePaths"))
    return (category,)


def cache_paths_by_category(root: Path) -> dict[str, list[Path]]:
    root_resolved = root.resolve()
    result: dict[str, list[Path]] = {}
    for svc in extra_services_for(root):
        rels = svc.get("cachePaths") or []
        kept: list[Path] = []
        for rel in rels:
            for path in (sorted(root.glob(rel)) if "*" in rel else [root / rel]):
                if not path.is_dir() or path.is_symlink():
                    continue
                try:
                    resolved = path.resolve()
                except OSError:
                    continue
                # 심링크 경유로 원본(main) 캐시를 지우는 사고 방지 — 실위치가 worktree 밖이면 제외
                if not str(resolved).startswith(str(root_resolved) + os.sep):
                    continue
                kept.append(path)
        if kept:
            result[svc["name"]] = kept
    return result


def cache_category_mb(root: Path) -> dict[str, int]:
    return {
        category: sum(disk_usage_mb(path) or 0 for path in paths)
        for category, paths in cache_paths_by_category(root).items()
    }


def clear_worktree_cache(root: Path, category: str = "all") -> dict[str, Any]:
    by_category = cache_paths_by_category(root)
    if category != "all" and category not in by_category:
        raise ValueError("unknown cache category")
    ports = ports_for(root)
    # 삭제 대상 캐시를 쓰는 서비스만 가드
    for service in cache_guard_services(category, root):
        if service in services_for(root) and service_status(root, service, ports.get(service))["running"]:
            raise ValueError(f"{service} 가 구동 중이야 — Stop 후 캐시를 비워줘")
    targets = [p for cat, paths in by_category.items() if category in ("all", cat) for p in paths]
    removed: list[str] = []
    freed = 0
    for path in targets:
        size = disk_usage_mb(path) or 0
        try:
            shutil.rmtree(path)
            removed.append(str(path.relative_to(root)))
            freed += size
        except OSError as exc:
            removed.append(f"{path.relative_to(root)} (실패: {exc})")
    _worktree_info_cache.pop(str(root), None)
    return {"removed": removed, "freedMb": freed}


def _other_session_ports(root: Path) -> set[str]:
    taken: set[str] = set()
    for other in discover_roots():
        if other.resolve() == root.resolve():
            continue
        taken.update(p for p in ports_for(other).values() if p)
    return taken


def fix_port_conflict(root: Path) -> dict[str, Any]:
    # 해시 오프셋 충돌은 cleanup(설정 리셋)으로는 같은 해시 → 같은 포트라 풀리지 않는다.
    # 전 서비스를 빈 오프셋 기준으로 한꺼번에 재배정한다.
    if is_source_checkout(root):
        raise ValueError("main 은 포트 기준(오프셋 0)이라 옮기지 않아 — 충돌 상대 세션 카드에서 해결해줘")
    taken = _other_session_ports(root)
    listeners = listener_map()
    for offset in range(10, 90):
        candidate = {svc: str(base + offset) for svc, base in port_base_for(root).items()}
        if any(p in taken or p in listeners for p in candidate.values()):
            continue
        updates = {config_key_for_service_port(svc): p for svc, p in candidate.items()}
        write_config(root, updates)
        return {"movedToOffset": offset, "ports": candidate}
    raise ValueError("10~89 범위에서 모든 서비스가 비는 오프셋을 찾지 못했어")


def delete_merged_branch(source_repo: Path, branch: str) -> dict[str, Any]:
    # 안전 삭제(-d): 미머지 커밋이 있으면 git 이 거부 → skipped 로 보고
    try:
        git_output(["branch", "-d", branch], source_repo)
        return {"deleted": branch}
    except subprocess.CalledProcessError as exc:
        return {"skipped": branch, "reason": (exc.output or "").strip()[-200:]}
    except Exception as exc:
        return {"skipped": branch, "reason": str(exc)[-200:]}


def bootout_session_dashboard(sid: str) -> None:
    # worktree 삭제 후 launchd 에 세션 라벨이 유령으로 남는 것 방지 (best-effort)
    if not shutil.which("launchctl"):
        return
    # 신 라벨 + 리네이밍 전 설치본 라벨 둘 다 정리
    for label in (f"marina.dashboard.{sid}", f"dev.codex.session-dashboard.{sid}"):
        subprocess.run(
            ["launchctl", "bootout", f"gui/{os.getuid()}/{label}"],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )


def tracked_pid_groups(snapshot: list[dict[str, Any]]) -> set[int]:
    tracked: set[int] = set()
    for root in discover_roots():
        for service in services_for(root):
            pid = read_pid(pid_file(root, service))
            if pid and pid_alive(pid):
                tracked.add(pid)
    pgids = {row["pgid"] for row in snapshot if row["pid"] in tracked}
    for row in snapshot:
        if row["pgid"] in pgids:
            tracked.add(row["pid"])
    return tracked


def orphan_processes() -> list[dict[str, Any]]:
    snapshot = process_snapshot()
    tracked = tracked_pid_groups(snapshot)
    self_pgid = os.getpgrp()
    orphans: list[dict[str, Any]] = []
    for row in snapshot:
        if row["pid"] in tracked or row["pid"] == os.getpid() or row["pgid"] == self_pgid:
            continue
        for label, pattern in orphan_rules_all():
            if pattern.search(row["command"]):
                orphans.append({
                    "pid": row["pid"],
                    "label": label,
                    "rssMb": row["rssKb"] // 1024,
                    "etime": row["etime"],
                    "command": redact_text(row["command"][:160]),
                })
                break
    orphans.sort(key=lambda item: -item["rssMb"])
    return orphans


def kill_orphans(pids: list[int]) -> dict[str, Any]:
    # pid 재사용 경합 방지: kill 직전 스냅샷에서 패턴 일치 + 추적 그룹 비편입을 재확인한 pid 만 종료
    rows = process_snapshot()
    snapshot = {row["pid"]: row for row in rows}
    tracked = tracked_pid_groups(rows)
    results: dict[str, str] = {}
    valid: set[int] = set()
    for pid in pids:
        row = snapshot.get(pid)
        if not row or not any(pattern.search(row["command"]) for _, pattern in orphan_rules_all()):
            results[str(pid)] = "skipped (no longer matches)"
            continue
        if pid in tracked:
            results[str(pid)] = "skipped (now tracked)"
            continue
        terminate_pid_tree(pid, signal.SIGTERM)
        valid.add(pid)
        results[str(pid)] = "terminated"
    if valid and not wait_pids_gone(valid, 5.0):
        for pid in valid:
            if pid_alive(pid):
                terminate_pid_tree(pid, signal.SIGKILL)
                results[str(pid)] = "killed (SIGKILL)"
    return {"results": results}


INDEX_HTML = r"""<!doctype html>
<html lang="ko">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title>Marina</title>
  <style>
    :root {
      color-scheme: light;
      --sys-bg-base: hsl(220, 20%, 96%);
      --sys-bg-surface: hsl(0, 0%, 100%);
      --sys-bg-surface-hover: hsl(220, 22%, 97%);
      --sys-cont-neutral-default: hsl(228, 10%, 12%);
      --sys-cont-neutral-light: hsl(225, 8%, 38%);
      --sys-cont-neutral-lightest: hsl(225, 7%, 56%);
      --sys-cont-primary-default: hsl(215, 95%, 48%);
      --sys-cont-positive-default: hsl(148, 64%, 35%);
      --sys-cont-negative-default: hsl(358, 68%, 50%);
      --sys-style-neutral-light: hsl(220, 14%, 90%);
      --sys-style-neutral-default: hsl(220, 12%, 82%);
      --sys-code-bg: hsl(225, 16%, 10%);
      --sys-code-fg: hsl(210, 18%, 92%);
      font-family: Pretendard, ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
    }
    * { box-sizing: border-box; }
    body { margin: 0; background: var(--sys-bg-base); color: var(--sys-cont-neutral-default); }
    header { height: 56px; display: flex; align-items: center; justify-content: space-between; padding: 0 20px; border-bottom: 1px solid var(--sys-style-neutral-light); background: var(--sys-bg-surface); }
    h1 { margin: 0; font-size: 16px; font-weight: 700; line-height: 1; letter-spacing: 0; }
    .brand-sub { color: var(--sys-cont-neutral-lightest); font-size: 12px; font-weight: 500; }
    button, select, input { font: inherit; font-size: 13px; line-height: 1; }
    button { height: 32px; border: 1px solid var(--sys-style-neutral-default); border-radius: 6px; background: var(--sys-bg-surface); color: var(--sys-cont-neutral-default); padding: 0 10px; cursor: pointer; }
    button:hover { background: var(--sys-bg-surface-hover); }
    button.primary { border-color: var(--sys-cont-primary-default); color: var(--sys-cont-primary-default); }
    button.danger { color: var(--sys-cont-negative-default); }
    button.active { background: var(--sys-cont-neutral-default); border-color: var(--sys-cont-neutral-default); color: white; }
    /* busy 표시 — 모든 진행중 버튼이 공통으로 쓰는 떠다니는 점 (currentColor 라 버튼 색 따라감) */
    .busy-dots { display: inline-flex; align-items: center; gap: 3px; line-height: 1; }
    .busy-dots i { width: 4px; height: 4px; border-radius: 50%; background: currentColor; animation: busyfloat 0.9s ease-in-out infinite; }
    .busy-dots i:nth-child(2) { animation-delay: 0.15s; }
    .busy-dots i:nth-child(3) { animation-delay: 0.3s; }
    @keyframes busyfloat { 0%, 70%, 100% { transform: translateY(0); opacity: 0.45; } 35% { transform: translateY(-3px); opacity: 1; } }
    @media (prefers-reduced-motion: reduce) { .busy-dots i { animation: none; opacity: 0.6; } }
    input, select { height: 32px; min-width: 0; border: 1px solid var(--sys-style-neutral-default); border-radius: 6px; background: var(--sys-bg-surface); color: var(--sys-cont-neutral-default); padding: 0 10px; }
    main { display: grid; grid-template-columns: minmax(420px, 520px) 16px minmax(0, 1fr); height: calc(100vh - 56px); }
    .rail { display: flex; align-items: center; justify-content: center; background: var(--sys-bg-base); cursor: pointer; }
    .rail:hover { background: var(--sys-bg-surface-hover); }
    .rail button { display: flex; align-items: center; justify-content: center; width: 16px; height: 72px; padding: 0; border-radius: 8px; border: 1px solid var(--sys-style-neutral-default); background: var(--sys-bg-surface); color: var(--sys-cont-neutral-light); font-size: 10px; line-height: 1; pointer-events: none; }
    .rail:hover button { color: var(--sys-cont-neutral-default); }
    /* 접힌 상태: 동일한 필 디자인을 화면 좌측에 fixed 고정 — 어떤 레이아웃 상태에서도 가려질 수 없게 */
    main.aside-collapsed .rail button { position: fixed; left: 3px; top: 50%; transform: translateY(-50%); z-index: 40; color: var(--sys-cont-primary-default); border-color: var(--sys-cont-primary-default); }
    main.aside-collapsed { grid-template-columns: 0 16px minmax(0, 1fr); }
    /* display:none 은 grid 자리를 한 칸씩 밀어 섹션이 16px 트랙에 끼는 사고 — 자리 유지한 채 숨김 */
    main.aside-collapsed aside { visibility: hidden; overflow: hidden; min-width: 0; border-right: 0; }
    .sessions-bar { display: flex; align-items: center; justify-content: space-between; gap: 8px; padding: 12px 14px 0; }
    .sessions-bar > button { height: 26px; padding: 0 8px; font-size: 12px; color: var(--sys-cont-neutral-light); }
    .switcher { position: relative; min-width: 0; flex: 1; }
    .switcher-toggle { display: flex; align-items: center; gap: 6px; width: 100%; height: 28px; padding: 0 8px; border: 1px solid var(--sys-style-neutral-default); border-radius: 8px; background: var(--sys-bg-surface); color: var(--sys-cont-neutral-default); }
    .switcher-toggle:hover { background: var(--sys-bg-surface-hover); }
    .switcher-current { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; font-size: 13px; font-weight: 700; }
    .switcher-chev { margin-left: auto; font-size: 10px; color: var(--sys-cont-neutral-light); }
    .switcher-menu { position: absolute; z-index: 50; top: 32px; left: 0; right: 0; max-height: 60vh; overflow-y: auto; padding: 4px; border: 1px solid var(--sys-style-neutral-default); border-radius: 10px; background: var(--sys-bg-surface); box-shadow: 0 6px 24px rgba(0,0,0,0.18); }
    .switcher-row { display: flex; align-items: center; gap: 6px; padding: 8px; border-radius: 8px; cursor: pointer; }
    .switcher-row:hover { background: var(--sys-bg-surface-hover); }
    .switcher-row.active { background: var(--sys-bg-surface-hover); }
    .switcher-row-name { flex: 1; min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; font-size: 13px; font-weight: 600; color: var(--sys-cont-neutral-default); }
    .switcher-row-actions { display: none; gap: 2px; }
    .switcher-row:hover .switcher-row-actions { display: flex; }
    .switcher-row-actions button { width: 22px; height: 22px; padding: 0; font-size: 12px; color: var(--sys-cont-neutral-light); }
    .switcher-chip { font-size: 11px; padding: 1px 6px; border-radius: 999px; white-space: nowrap; }
    .switcher-chip.on { color: var(--sys-cont-primary-default); border: 1px solid var(--sys-cont-primary-default); }
    .switcher-chip.conflict { color: #c0392b; border: 1px solid #c0392b; }
    .switcher-chip.idle { color: var(--sys-cont-neutral-light); border: 1px solid var(--sys-style-neutral-default); }
    .switcher-register { width: 100%; margin-top: 4px; padding: 8px; border-top: 1px solid var(--sys-style-neutral-light); border-radius: 0 0 8px 8px; text-align: left; font-size: 13px; color: var(--sys-cont-primary-default); }
    .switcher-register:hover { background: var(--sys-bg-surface-hover); }
    /* display 를 명시한 요소는 UA 의 [hidden]→display:none 을 덮어쓴다 — hidden 속성이 항상 이기도록 강제 */
    [hidden] { display: none !important; }
    .modal-backdrop { position: fixed; inset: 0; z-index: 100; display: flex; align-items: center; justify-content: center; background: rgba(0,0,0,0.45); }
    .register-panel { width: 680px; max-width: calc(100vw - 32px); max-height: calc(100vh - 48px); overflow-y: auto; padding: 24px; display: flex; flex-direction: column; gap: 12px; border: 1px solid var(--sys-style-neutral-default); border-radius: 12px; background: var(--sys-bg-surface); box-shadow: 0 12px 40px rgba(0,0,0,0.3); }
    .register-head { display: flex; align-items: center; justify-content: space-between; }
    .register-title { font-size: 14px; font-weight: 700; color: var(--sys-cont-neutral-default); }
    .register-label { font-size: 12px; color: var(--sys-cont-neutral-light); }
    .register-path-row { display: flex; gap: 6px; }
    .register-input { flex: 1; height: 30px; padding: 0 8px; border: 1px solid var(--sys-style-neutral-default); border-radius: 8px; background: var(--sys-bg-surface); color: var(--sys-cont-neutral-default); }
    .register-path-row button, .register-confirm { height: 30px; padding: 0 12px; border: 1px solid var(--sys-cont-primary-default); border-radius: 8px; background: var(--sys-bg-surface); color: var(--sys-cont-primary-default); }
    .register-error { font-size: 12px; color: #c0392b; }
    .register-preview { display: flex; flex-direction: column; gap: 8px; }
    .register-meta { font-size: 12px; color: var(--sys-cont-neutral-light); }
    .register-checklist-head { font-size: 13px; font-weight: 600; color: var(--sys-cont-neutral-default); }
    .register-hint { font-weight: 400; color: var(--sys-cont-neutral-light); }
    .register-checklist { display: flex; flex-direction: column; gap: 4px; max-height: 40vh; overflow-y: auto; }
    .register-check { display: flex; align-items: center; gap: 8px; font-size: 13px; color: var(--sys-cont-neutral-default); }
    .check-remove { margin-left: auto; width: 22px; height: 22px; padding: 0; border: 0; border-radius: 6px; background: transparent; color: var(--sys-cont-neutral-light); font-size: 12px; cursor: pointer; }
    .check-remove:hover { color: #c0392b; background: var(--sys-bg-surface-hover); }
    .register-empty { font-size: 12px; color: var(--sys-cont-neutral-light); }
    .register-confirm { align-self: flex-start; }
    .browse-panel { display: flex; flex-direction: column; gap: 6px; max-height: 40vh; border: 1px solid var(--sys-style-neutral-default); border-radius: 8px; padding: 8px; }
    .browse-bar { display: flex; align-items: center; gap: 6px; }
    .browse-path { flex: 1; min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; font-size: 12px; color: var(--sys-cont-neutral-light); }
    .browse-bar button { height: 26px; padding: 0 10px; border: 1px solid var(--sys-cont-primary-default); border-radius: 8px; background: var(--sys-bg-surface); color: var(--sys-cont-primary-default); }
    .browse-list { overflow-y: auto; display: flex; flex-direction: column; }
    .browse-row { display: flex; align-items: center; gap: 8px; padding: 6px 8px; border-radius: 6px; cursor: pointer; font-size: 13px; color: var(--sys-cont-neutral-default); }
    .browse-row:hover { background: var(--sys-bg-surface-hover); }
    .browse-row .repo-badge { margin-left: auto; font-size: 11px; color: var(--sys-cont-primary-default); }
    .register-manual { display: flex; gap: 6px; }
    .register-manual button { height: 30px; padding: 0 12px; border: 1px solid var(--sys-cont-primary-default); border-radius: 8px; background: var(--sys-bg-surface); color: var(--sys-cont-primary-default); }
    /* 서비스 추가/편집 모달 */
    .svc-modal-field { display: flex; flex-direction: column; gap: 4px; }
    .svc-modal-field label { font-size: 12px; color: var(--sys-cont-neutral-light); }
    .svc-modal-field input, .svc-modal-field textarea { width: 100%; box-sizing: border-box; border: 1px solid var(--sys-style-neutral-default); border-radius: 8px; background: var(--sys-bg-surface); color: var(--sys-cont-neutral-default); padding: 6px 10px; font: inherit; font-size: 13px; }
    .svc-modal-field textarea { height: 64px; resize: vertical; line-height: 1.5; }
    .svc-modal-adv { display: flex; flex-direction: column; gap: 8px; }
    .svc-modal-adv-toggle { background: none; border: none; color: var(--sys-cont-neutral-light); font-size: 12px; cursor: pointer; padding: 0; text-align: left; height: auto; }
    .svc-modal-adv-toggle:hover { color: var(--sys-cont-neutral-default); }
    .svc-modal-actions { display: flex; gap: 8px; }
    .svc-modal-actions button { height: 30px; padding: 0 14px; border-radius: 8px; }
    .svc-edit-btn, .svc-del-btn { height: 22px; min-width: 22px; padding: 0 5px; font-size: 12px; border-radius: 5px; }
    aside { border-right: 1px solid var(--sys-style-neutral-light); overflow-y: auto; min-height: 0; }
    section { min-width: 0; min-height: 0; display: flex; flex-direction: column; }
    .toolbar { display: flex; gap: 8px; align-items: center; }
    .sessions { padding: 14px; display: grid; gap: 12px; }
    .session { border: 1px solid var(--sys-style-neutral-light); border-radius: 8px; background: var(--sys-bg-surface); overflow: hidden; }
    .session-head { padding: 12px; border-bottom: 1px solid var(--sys-style-neutral-light); cursor: pointer; }
    .session-head:hover { background: var(--sys-bg-surface-hover); }
    .session-title { display: flex; align-items: flex-start; justify-content: space-between; gap: 12px; }
    /* 툴바(프리셋+버튼들)가 max-content 로 벌어져도 제목이 짜부되지 않게 최소 폭 보장 — 초과분은 툴바가 내부 wrap */
    .session-main { min-width: 120px; flex: 1; }
    .alias-row { display: flex; align-items: center; gap: 8px; min-width: 0; }
    .alias-input { height: 28px; min-width: 0; width: 160px; font-size: 14px; font-weight: 700; padding: 0 8px; }
    .alias-display { min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; font-size: 14px; font-weight: 700; line-height: 1.3; cursor: text; border-bottom: 1px dashed transparent; }
    .alias-display:hover { border-bottom-color: var(--sys-style-neutral-default); }
    .sid-sub { margin: 3px 0 0 14px; color: var(--sys-cont-neutral-lightest); font-size: 11px; line-height: 1.4; overflow-wrap: anywhere; }
    .root { color: var(--sys-cont-neutral-lightest); font-size: 12px; line-height: 1.6; margin-top: 4px; overflow-wrap: anywhere; }
    .root .root-meta { white-space: nowrap; }
    .session-tools { display: flex; gap: 6px; flex-wrap: wrap; justify-content: flex-end; }
    .session-tools button { height: 28px; min-width: 30px; padding: 0 6px; white-space: nowrap; font-size: 14px; }
    .session-tools button.icon { display: inline-flex; align-items: center; justify-content: center; padding: 0; }
    .session-tools button.icon svg { width: 16px; height: 16px; }
    /* 즉시 툴팁 — 네이티브 title 의 ~1s 지연 제거 (mouseover 위임이 title→data-tip 으로 흡수) */
    /* width:max-content — 박스 너비를 앵커 위치와 분리. 없으면 우측 끝 버튼(↗ 등)에서 shrink-to-fit 이 뷰포트 우변까지 짜부돼 한 글자씩 세로로 쏟아짐 (clamp 로직이 가로로 밀어줌) */
    #tip { position: fixed; z-index: 99; width: max-content; max-width: min(380px, calc(100vw - 16px)); padding: 6px 10px; border-radius: 6px; background: var(--sys-cont-neutral-default); color: var(--sys-bg-surface); font-size: 12px; line-height: 1.55; pointer-events: none; opacity: 0; transform: translateX(-50%); transition: opacity .06s; white-space: pre-wrap; word-break: break-word; }
    #tip.on { opacity: 1; }
    .stat-row { display: flex; flex-wrap: wrap; gap: 4px 6px; margin-top: 8px; }
    .pill-stat { display: inline-flex; align-items: center; height: 22px; padding: 0 8px; border-radius: 6px; border: 1px solid var(--sys-style-neutral-light); background: var(--sys-bg-base); color: var(--sys-cont-neutral-light); font-size: 11px; font-weight: 500; line-height: 1; white-space: nowrap; }
    button.pill-stat { cursor: pointer; }
    .pill-stat.warn { background: hsl(36, 90%, 94%); border-color: transparent; color: hsl(30, 80%, 38%); font-weight: 700; }
    /* 긴 브랜치명이 카드 폭을 넘으면 말줄임 — 전체 매핑은 title 로 */
    .pill-stat.pill-branch { display: inline-block; max-width: 100%; height: 22px; line-height: 20px; overflow: hidden; text-overflow: ellipsis; }
    .pill-stat.danger { background: hsl(358, 70%, 96%); border-color: transparent; color: var(--sys-cont-negative-default); font-weight: 700; }
    details { margin-top: 10px; }
    summary { color: var(--sys-cont-neutral-light); cursor: pointer; font-size: 12px; font-weight: 500; line-height: 1.6; }
    .summary-sub { color: var(--sys-cont-neutral-lightest); font-weight: 400; margin-left: 4px; }
    .config-label { margin: 12px 0 6px; color: var(--sys-cont-neutral-lightest); font-size: 11px; font-weight: 700; letter-spacing: 0.02em; }
    .config-services { display: grid; grid-template-columns: 64px minmax(0, 1fr) minmax(0, 1fr); gap: 6px; align-items: center; }
    .config-head { color: var(--sys-cont-neutral-lightest); font-size: 11px; font-weight: 700; }
    .config-name { color: var(--sys-cont-neutral-light); font-size: 12px; }
    .config-services input { height: 30px; padding: 0 8px; font-size: 12px; width: 100%; }
    .config-actions { display: flex; gap: 8px; margin-top: 10px; }
    .svc-list { display: grid; }
    .session.collapsed .svc-list, .session.collapsed [data-config-details], .session.collapsed .root { display: none; }
    .session.collapsed .session-head { border-bottom: 0; }
    .svc { display: grid; grid-template-columns: 86px 72px minmax(0, 1fr); gap: 8px; align-items: center; padding: 10px 12px; border-top: 1px solid var(--sys-style-neutral-light); cursor: pointer; }
    .svc:hover, .svc.selected { background: var(--sys-bg-surface-hover); }
    /* subrepo ⊃ service 트리 */
    .subrepo-row { display: flex; align-items: center; justify-content: space-between; gap: 8px; padding: 8px 12px; border-top: 1px solid var(--sys-style-neutral-light); background: var(--sys-bg-base); }
    .subrepo-row.detached { opacity: 0.72; }
    .subrepo-main { display: flex; align-items: center; gap: 8px; min-width: 0; cursor: pointer; flex: 1; }
    .subrepo-name { font-size: 13px; font-weight: 700; line-height: 1; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
    .subrepo-count { color: var(--sys-cont-neutral-lightest); font-size: 11px; white-space: nowrap; }
    .subrepo-count.muted { font-style: italic; }
    .subrepo-ctl { display: flex; align-items: center; gap: 8px; flex-shrink: 0; }
    .subrepo-chip { display: inline-flex; align-items: center; height: 20px; padding: 0 8px; border-radius: 6px; font-size: 11px; font-weight: 700; background: var(--sys-style-neutral-light); color: var(--sys-cont-neutral-light); }
    .subrepo-chip.warn { background: hsl(36, 90%, 94%); color: hsl(30, 80%, 38%); }
    .subrepo-toggle { display: inline-flex; align-items: center; gap: 5px; font-size: 11px; font-weight: 700; color: var(--sys-cont-neutral-light); cursor: pointer; }
    .subrepo-toggle input { margin: 0; cursor: pointer; }
    .subrepo-act { height: 24px; padding: 0 10px; font-size: 11px; font-weight: 700; }
    .subrepo-act.icon { width: 28px; padding: 0; display: inline-flex; align-items: center; justify-content: center; }
    .subrepo-act.icon svg { width: 15px; height: 15px; display: block; }
    .subrepo-act.default-toggle { color: var(--sys-cont-neutral-lightest); }   /* off: 흐린 윤곽 핀 */
    .subrepo-act.default-toggle.on { color: var(--sys-cont-neutral-default); border-color: var(--sys-cont-neutral-default); background: var(--sys-style-neutral-light); }   /* on: 채워진 중립 핀 — 실행(파랑)과 구분 */
    .subrepo-act.default-toggle.on svg { fill: currentColor; }
    .subrepo-body { display: grid; }
    .subrepo-body .svc { padding-left: 30px; }   /* nested 들여쓰기 */
    .svc.disabled { cursor: default; opacity: 0.5; }
    .svc.disabled:hover { background: transparent; }
    .svc.disabled .actions { display: none; }
    .svc-name { font-size: 13px; font-weight: 700; line-height: 1; }
    .svc-src { font-size: 10px; padding: 1px 6px; border-radius: 6px; margin-left: 6px; }
    .svc-src.central { background: hsl(36,90%,94%); color: hsl(30,80%,38%); }
    .svc-src.root { background: var(--sys-style-neutral-light); color: var(--sys-cont-neutral-light); }
    .svc-port { color: var(--sys-cont-neutral-lightest); font-size: 12px; line-height: 1.6; margin-top: 3px; }
    .pill { display: inline-flex; align-items: center; justify-content: center; width: 52px; height: 24px; border-radius: 6px; font-size: 12px; font-weight: 700; }
    .run { background: hsl(148, 55%, 94%); color: var(--sys-cont-positive-default); }
    .stop { background: hsl(358, 70%, 96%); color: var(--sys-cont-negative-default); }
    .boot { background: hsl(36, 90%, 94%); color: hsl(30, 80%, 38%); }
    .bad { background: var(--sys-cont-negative-default); color: white; }
    .actions { display: flex; gap: 6px; flex-wrap: wrap; justify-content: flex-end; }
    .actions button { height: 28px; min-width: 30px; padding: 0 7px; font-size: 13px; }
    /* grid auto 컬럼은 flex-wrap 을 무시하고 max-content 로 벌어져 좁은 폭에서 제목을 뭉갠다 → flex-wrap */
    .log-head { display: flex; flex-direction: column; border-bottom: 1px solid var(--sys-style-neutral-light); background: var(--sys-bg-surface); }
    .log-src { display: flex; flex-wrap: wrap; gap: 8px 12px; align-items: center; padding: 10px 16px 6px; }
    .log-title { flex: 1 1 220px; min-width: 0; }
    .log-kicker { color: var(--sys-cont-neutral-lightest); font-size: 12px; line-height: 1.6; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
    .log-name { font-size: 16px; font-weight: 700; line-height: 1.6; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
    .log-src-tools { display: flex; gap: 8px; align-items: center; flex-wrap: wrap; justify-content: flex-end; }
    .log-toolbar { display: flex; flex-wrap: wrap; gap: 6px 8px; align-items: center; padding: 0 16px 10px; }
    .search-ic { color: var(--sys-cont-neutral-lightest); font-size: 16px; }
    .match-count { color: var(--sys-cont-neutral-light); font-size: 12px; white-space: nowrap; }
    .log-actions { display: flex; gap: 6px; margin-left: auto; }
    .log-actions button { min-width: 34px; }
    .segments { display: none; gap: 4px; padding: 3px; border: 1px solid var(--sys-style-neutral-default); border-radius: 8px; background: var(--sys-bg-base); }
    .segments.visible { display: flex; }
    .segments button { height: 26px; border: 0; background: transparent; }
    .segments button.active { background: var(--sys-bg-surface); color: var(--sys-cont-neutral-default); border: 1px solid var(--sys-style-neutral-light); }
    .follow-btn.active { background: var(--sys-cont-primary-default); border-color: var(--sys-cont-primary-default); color: white; }
    #logErrOnly.active { background: hsl(358, 70%, 96%); border-color: var(--sys-cont-negative-default); color: var(--sys-cont-negative-default); font-weight: 700; }
    .gauge-bar { display: flex; gap: 10px; align-items: center; padding: 6px 16px; border-bottom: 1px solid var(--sys-style-neutral-light); background: var(--sys-bg-surface); }
    .gauge-note { color: var(--sys-cont-neutral-lightest); font-size: 11px; white-space: nowrap; }
    .gauge-track { flex: 1; position: relative; height: 10px; min-width: 80px; border-radius: 5px; background: var(--sys-bg-base); border: 1px solid var(--sys-style-neutral-light); cursor: pointer; }
    .gauge-window { position: absolute; top: 1px; bottom: 1px; background: var(--sys-cont-primary-default); opacity: 0.75; border-radius: 4px; min-width: 3px; pointer-events: none; }
    .gauge-tick { position: absolute; top: 1px; bottom: 1px; width: 2px; background: var(--sys-cont-negative-default); pointer-events: none; }
    .log-body { flex: 1; min-height: 0; margin: 0; padding: 10px 0; overflow: auto; overscroll-behavior: contain; background: var(--sys-code-bg); color: var(--sys-code-fg); font-family: ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace; font-size: 12px; line-height: 1.55; scrollbar-gutter: stable; }
    .log-line { padding: 1px 16px; white-space: pre-wrap; word-break: break-word; }
    .log-line:hover { background: hsla(0, 0%, 100%, 0.05); }
    .log-line.err { color: hsl(358, 85%, 72%); background: hsla(358, 70%, 50%, 0.08); border-left: 2px solid hsl(358, 75%, 55%); padding-left: 14px; }
    .log-line.warn { color: hsl(42, 90%, 65%); background: hsla(42, 90%, 50%, 0.06); border-left: 2px solid hsl(42, 85%, 50%); padding-left: 14px; }
    .log-line.jump-hit { background: hsla(215, 95%, 48%, 0.3); transition: background 1.2s ease; }
    .log-line.match-row { cursor: pointer; }
    .log-line.match-row:hover { background: hsla(215, 95%, 60%, 0.12); }
    .log-body .empty { color: hsl(220, 8%, 50%); padding: 8px 16px; }
    #logFilter { width: 200px; }
    .empty { color: var(--sys-cont-neutral-lightest); padding: 18px; }
    .chev { display: inline-block; width: 14px; color: var(--sys-cont-neutral-lightest); font-size: 11px; }
    .run-summary { color: var(--sys-cont-positive-default); font-size: 12px; font-weight: 700; white-space: nowrap; }
    .mem { display: flex; align-items: center; gap: 8px; color: var(--sys-cont-neutral-light); font-size: 12px; line-height: 1; }
    .mem-bar { width: 110px; height: 8px; border-radius: 4px; background: var(--sys-style-neutral-light); overflow: hidden; }
    .mem-bar i { display: block; height: 100%; background: var(--sys-cont-primary-default); }
    .tool-label { color: var(--sys-cont-neutral-lightest); font-size: 12px; }
    .ghost-chip { color: var(--sys-cont-neutral-light); }
    .ghost-chip.alert { border-color: var(--sys-cont-negative-default); color: var(--sys-cont-negative-default); font-weight: 700; }
    .update-banner { display: flex; align-items: center; gap: 10px; flex-wrap: wrap; padding: 8px 16px; background: hsl(36, 90%, 94%); color: hsl(30, 80%, 30%); border-bottom: 1px solid var(--sys-style-neutral-light); font-size: 13px; }
    .update-banner.stale { background: hsl(215, 90%, 95%); color: hsl(215, 70%, 35%); }
    .update-banner .ub-msg { font-weight: 700; }
    .update-banner .ub-sha { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: 12px; opacity: 0.8; }
    .update-banner .ub-actions { display: flex; gap: 6px; margin-left: auto; flex-wrap: wrap; align-items: center; }
    .update-banner button { height: 26px; padding: 0 10px; font-size: 12px; font-weight: 700; }
    .update-banner .ub-note { font-size: 12px; opacity: 0.85; }
    .ub-hrow { display: inline-flex; align-items: center; gap: 5px; }
    .ub-hchip { display: inline-flex; align-items: center; gap: 5px; height: 22px; padding: 0 8px; border-radius: 6px; font-size: 12px; font-weight: 700; background: rgba(125, 75, 0, 0.10); }
    .ub-hchip.old { background: rgba(125, 75, 0, 0.20); }
    .ub-hchip .sha { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-weight: 500; opacity: 0.8; }
    .orphan-pop { position: fixed; top: 60px; right: 16px; z-index: 30; width: min(520px, calc(100vw - 32px)); max-height: 70vh; overflow: auto; border: 1px solid var(--sys-style-neutral-default); border-radius: 10px; background: var(--sys-bg-surface); box-shadow: 0 8px 24px hsla(0, 0%, 0%, 0.18); padding: 12px 14px; }
    .orphan-head { color: var(--sys-cont-neutral-light); font-size: 12px; line-height: 1.6; }
    .mem.warn { color: var(--sys-cont-negative-default); font-weight: 700; }
    .mem.warn .mem-bar i { background: var(--sys-cont-negative-default); }
    .orphans { padding: 14px 14px 0; }
    .orphans > details { border: 1px solid var(--sys-style-neutral-light); border-radius: 8px; background: var(--sys-bg-surface); padding: 10px 12px; margin: 0; }
    .orphans > details > summary { font-size: 12px; font-weight: 700; line-height: 1.6; color: var(--sys-cont-neutral-default); }
    .orphans.alert > details { border-color: var(--sys-cont-negative-default); }
    .orphans.alert > details > summary { color: var(--sys-cont-negative-default); }
    .orphan-row { display: grid; grid-template-columns: minmax(0, 1fr) auto; gap: 8px; align-items: center; padding: 8px 0; border-top: 1px solid var(--sys-style-neutral-light); margin-top: 8px; }
    .orphan-row button { height: 26px; padding: 0 8px; }
    .orphan-meta { font-size: 12px; line-height: 1.6; color: var(--sys-cont-neutral-light); overflow-wrap: anywhere; }
    .orphan-meta b { color: var(--sys-cont-neutral-default); }
    .orphan-actions { display: flex; justify-content: flex-end; margin-top: 8px; }
    .session-main .wt-changes { margin-top: 8px; }
    .wt-changes { grid-column: 1 / -1; margin-top: 6px; padding: 8px 10px; border-radius: 6px; background: var(--sys-code-bg); color: var(--sys-code-fg); font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: 11px; line-height: 1.6; white-space: pre-wrap; word-break: break-all; max-height: 220px; overflow: auto; }
    @media (max-width: 980px) {
      main, main.aside-collapsed { grid-template-columns: 1fr; height: auto; min-height: calc(100vh - 56px); }
      .rail { display: none; }
      /* 좁은 화면에선 좌우 접기 비활성 — 토글(레일)이 숨어 패널을 못 되살리는 함정 방지 */
      main.aside-collapsed aside { visibility: visible; overflow: auto; }
      aside { border-right: 0; border-bottom: 1px solid var(--sys-style-neutral-light); max-height: 48vh; }
      section { min-height: 60vh; }
      #logFilter { width: 90px; }
    }
    /* 다크 테마 — JS 가 html.dark 클래스로 적용 (시스템/라이트/다크 드롭다운 + localStorage) */
    :root.dark {
      color-scheme: dark;
      --sys-bg-base: hsl(228, 14%, 9%);
      --sys-bg-surface: hsl(228, 13%, 12%);
      --sys-bg-surface-hover: hsl(228, 12%, 16%);
      --sys-cont-neutral-default: hsl(220, 16%, 90%);
      --sys-cont-neutral-light: hsl(220, 10%, 64%);
      --sys-cont-neutral-lightest: hsl(220, 8%, 48%);
      --sys-cont-primary-default: hsl(215, 95%, 64%);
      --sys-cont-positive-default: hsl(148, 55%, 52%);
      --sys-cont-negative-default: hsl(358, 78%, 64%);
      --sys-style-neutral-light: hsl(228, 10%, 19%);
      --sys-style-neutral-default: hsl(228, 9%, 27%);
      --sys-code-bg: hsl(228, 16%, 7%);
      --sys-code-fg: hsl(210, 18%, 88%);
    }
    .dark button.active { color: hsl(228, 14%, 9%); }
    .dark .segments button.active { color: var(--sys-cont-neutral-default); }
    .dark .run { background: hsl(148, 45%, 14%); color: hsl(148, 60%, 58%); }
    .dark .stop { background: hsl(358, 45%, 15%); color: hsl(358, 75%, 66%); }
    .dark .boot { background: hsl(36, 50%, 14%); color: hsl(36, 85%, 60%); }
    .dark #logErrOnly.active { background: hsl(358, 45%, 15%); color: hsl(358, 75%, 66%); }
    /* .bad 는 negative 토큰이 다크 변형을 이미 제공 (밝은 빨강 + 흰 글자 대비 유지) — 별도 .dark .bad 불필요 */
    .dark .pill-stat.warn { background: hsl(36, 50%, 14%); color: hsl(36, 85%, 60%); }
    .dark .pill-stat.danger { background: hsl(358, 45%, 15%); }
  </style>
</head>
<body>
  <header>
    <h1>Marina <span class="brand-sub">dev sessions</span></h1>
    <div class="toolbar">
      <button class="ghost-chip" id="orphanChip" hidden title="marina 패턴인데 세션 추적 밖에서 도는 프로세스 — 클릭해서 확인·정리"></button>
      <div class="mem" id="mem" hidden title="dev = marina 추적 서비스의 RSS 합 / 시스템 = OS 전체 사용량(브라우저·IDE 등 모든 앱 포함, memory_pressure 기준이라 활동 모니터 수치와 다를 수 있음). 가용 4GB 미만이면 적색 + 서비스 시작 차단"><span id="memText"></span><span class="mem-bar"><i id="memBar"></i></span></div>
      <select id="themeSelect" title="대시보드 테마 — 시스템은 OS 다크/라이트 실시간 추종">
        <option value="system">시스템</option>
        <option value="light">라이트</option>
        <option value="dark">다크</option>
      </select>
      <button id="refresh" title="새로고침 — 세션·유령·디스크 분석(du) 전체 재계산">↻</button>
    </div>
  </header>
  <div class="update-banner" id="updateBanner" hidden></div>
  <div class="orphan-pop" id="orphanPanel" hidden></div>
  <main>
    <aside>
      <div class="sessions-bar">
        <div class="switcher" id="switcher">
          <button id="switcherToggle" class="switcher-toggle" title="프로젝트 전환">
            <span id="switcherCurrent" class="switcher-current">프로젝트</span>
            <span class="switcher-chev">▾</span>
          </button>
          <div id="switcherMenu" class="switcher-menu" hidden></div>
        </div>
        <button id="collapseAll" title="세션 카드 전체 접기/펼치기">⇈</button>
      </div>
      <div class="sessions" id="sessions"></div>
    </aside>
    <div class="rail"><button id="asideToggle" title="세션 패널 좌우 접기/펼치기 (로그 전체 화면)">◀</button></div>
    <section>
      <div class="log-head">
        <div class="log-src">
          <div class="log-title">
            <div class="log-kicker" id="selectedRoot">Select a service</div>
            <div class="log-name" id="selectedLabel">Logs</div>
          </div>
          <div class="log-src-tools">
            <div class="segments" id="logModeTabs">
              <button data-log-mode="service" class="active" title="서비스 프로세스의 서버 로그">Server</button>
              <button data-log-mode="console" title="브라우저 콘솔 수집 로그 (대시보드로 띄운 web 에서 전송)">Console</button>
            </div>
            <select id="runSelect" title="로그 run 선택 — 재시작마다 새 run 파일 (최신 10개 유지)"></select>
          </div>
        </div>
        <div class="log-toolbar">
          <span class="search-ic" aria-hidden="true">⌕</span>
          <input id="logFilter" placeholder="필터 — 파일 전체에서 찾기" />
          <button id="logErrOnly" title="에러·경고 라인만 표시 — 게이지에 위치 틱이 찍힘">에러만</button>
          <span class="match-count" id="matchCount"></span>
          <div class="log-actions">
            <button id="followLog" class="follow-btn active" title="Follow — 로그 하단 자동 추적 (스크롤 올리면 해제, 과거 탐색 중 누르면 최신으로 복귀)">⤓</button>
            <button id="logClear" title="화면만 비움 (파일 로그는 유지)">⌫</button>
            <button id="logDownload" title="로그 파일 전체 다운로드 (민감값 마스킹 적용)">↓</button>
            <button id="openWeb" hidden title="이 세션의 web 을 브라우저로 열기">↗</button>
          </div>
        </div>
      </div>
      <div class="gauge-bar" id="olderBar" hidden>
        <span class="gauge-note" id="olderInfo"></span>
        <div class="gauge-track" id="gaugeTrack" title="파일 전체에서 현재 보는 구간 — 클릭하면 그 위치로 이동, 빨간 틱 = 매치">
          <div class="gauge-window" id="gaugeWindow"></div>
        </div>
        <span class="gauge-note" id="gaugePos"></span>
      </div>
      <div class="log-body" id="log"><div class="empty">Select a service row.</div></div>
    </section>
  </main>
  <div class="modal-backdrop" id="registerBackdrop" hidden>
    <div class="register-panel" id="registerPanel">
      <div class="register-head">
        <span class="register-title" id="registerTitle">프로젝트 등록</span>
        <button id="registerClose" title="닫기">✕</button>
      </div>
      <label class="register-label">프로젝트 경로</label>
      <div class="register-path-row">
        <input id="registerPath" class="register-input" placeholder="~/path/to/project" />
        <button id="registerBrowse" title="폴더 탐색">찾아보기</button>
        <button id="registerInfer">분석</button>
      </div>
      <div class="register-error" id="registerError" hidden></div>
      <div class="browse-panel" id="browsePanel" hidden>
        <div class="browse-bar"><span class="browse-path" id="browsePath"></span><button id="browseSelect" title="이 폴더 선택">이 폴더 선택</button></div>
        <div class="browse-list" id="browseList"></div>
      </div>
      <div class="register-preview" id="registerPreview" hidden>
        <div class="register-meta" id="registerMeta"></div>
        <div class="register-checklist-head">서브레포 <span class="register-hint">(체크된 것만 등록)</span></div>
        <div class="register-checklist" id="registerChecklist"></div>
        <div class="register-manual">
          <input id="registerManualPath" class="register-input" placeholder="추가 subrepo 상대경로 (예: projects/react-skeleton)" />
          <button id="registerManualBrowse" title="프로젝트 안에서 폴더 선택">찾아보기</button>
          <button id="registerManualAdd">+ 추가</button>
        </div>
        <button id="registerConfirm" class="register-confirm">등록</button>
      </div>
    </div>
  </div>
  <div class="modal-backdrop" id="serviceBackdrop" hidden>
    <div class="register-panel" id="servicePanel" style="width:540px">
      <div class="register-head">
        <span class="register-title" id="serviceModalTitle">서비스 추가</span>
        <button id="serviceModalClose" title="닫기">✕</button>
      </div>
      <div class="register-error" id="serviceModalError" hidden></div>
      <div class="svc-modal-field">
        <label for="svcName">서비스 이름 *</label>
        <input id="svcName" placeholder="예: web, be, index" />
      </div>
      <div class="svc-modal-field">
        <label for="svcPortBase">portBase *</label>
        <input id="svcPortBase" type="number" placeholder="예: 3000" />
      </div>
      <div class="svc-modal-field">
        <label for="svcCwd">cwd (subrepo 상대경로, 비워두면 루트)</label>
        <input id="svcCwd" list="svcCwdList" placeholder="예: web-app-monorepo" />
        <datalist id="svcCwdList"></datalist>
      </div>
      <div class="svc-modal-field">
        <label for="svcRun">실행 커맨드 * (치환자: {port} {profile} {python} {root})</label>
        <textarea id="svcRun" placeholder="exec pnpm dev --port {port}"></textarea>
      </div>
      <div class="svc-modal-adv">
        <button class="svc-modal-adv-toggle" id="svcAdvToggle" type="button">▸ 고급</button>
        <div id="svcAdvFields" hidden>
          <div class="svc-modal-field" style="margin-bottom:8px">
            <label for="svcCachePaths">cachePaths (쉼표 구분, 루트 상대경로)</label>
            <input id="svcCachePaths" placeholder="예: web-app-monorepo/.next, web-app-monorepo/node_modules" />
          </div>
          <div class="svc-modal-field">
            <label for="svcOrphanPattern">orphanPattern (정규식 — 유령 프로세스 감지)</label>
            <input id="svcOrphanPattern" placeholder="예: pnpm dev" />
          </div>
        </div>
      </div>
      <label class="register-check" style="margin-top:4px">
        <input type="checkbox" id="svcTeamShare" />
        팀 공유 (프로젝트 루트 marina-services.json 에 커밋)
      </label>
      <div class="svc-modal-actions">
        <button id="svcModalSave" class="register-confirm">저장</button>
        <button id="svcModalCancel">취소</button>
      </div>
    </div>
  </div>
  <script>
    let sessions = [];
    let selected = null;
    let source = null;
    let configDirty = false;
    let followLog = true;
    // 표시 창 — 로그 파일에서 DOM 에 올라와 있는 바이트 구간 [top, bottom). live = SSE tail 수신 중
    let logWindow = {top: 0, bottom: 0, live: false};
    let logPaging = {loadingUp: false, loadingDown: false, atStart: true};
    let logFileSize = 0;  // 게이지 분모 — meta/chunk/matches 응답으로 갱신
    let logMatches = {offsets: [], total: 0, truncated: false, active: false};
    let matchScanTimer = null;
    // 매치 전용 뷰 — 필터/에러만 ON 이면 파일 전체의 매치를 한 번에 목록으로 (스크롤 페이징 대신)
    let matchView = false;
    let sessionSignature = '';
    const openConfigRoots = new Set();
    const expandedRoots = new Set();
    const subrepoOpen = new Map();   // `${root}::${subrepo}` → bool (펼침). 미설정이면 attached=펼침 기본.
    let selectedProjectId = localStorage.getItem('marinaSelectedProject') || null;
    let switcherOpen = false;

    function projectSummaries() {
      // worktreeData 가 모든 등록 프로젝트의 main 엔트리를 포함 → projectId 로 그룹.
      const byId = new Map();
      for (const wt of worktreeData) {
        if (!byId.has(wt.projectId)) {
          byId.set(wt.projectId, { id: wt.projectId, label: wt.projectLabel || wt.projectId, root: wt.projectRoot, on: 0, conflict: 0 });
        }
      }
      for (const s of sessions) {
        const wt = worktreeData.find(w => w.root === s.root);
        if (!wt) continue;
        const sum = byId.get(wt.projectId);
        if (!sum) continue;
        if ((s.services || []).some(svc => svc.running)) sum.on += 1;
        if ((s.webPortConflictWith || []).length) sum.conflict += 1;
      }
      return [...byId.values()];
    }

    function setSelectedProject(id) {
      selectedProjectId = id;
      if (id) localStorage.setItem('marinaSelectedProject', id);
      else localStorage.removeItem('marinaSelectedProject');
      switcherOpen = false;
      render();
    }

    function chipHtml(sum) {
      if (sum.conflict) return `<span class="switcher-chip conflict">${sum.conflict} 충돌</span>`;
      if (sum.on) return `<span class="switcher-chip on">${sum.on} ON</span>`;
      return '<span class="switcher-chip idle">idle</span>';
    }

    function renderSwitcher() {
      const summaries = projectSummaries();
      const current = summaries.find(s => s.id === selectedProjectId);
      document.getElementById('switcherCurrent').textContent = current ? current.label : (summaries.length ? '프로젝트 선택' : '등록된 프로젝트 없음');
      const menu = document.getElementById('switcherMenu');
      menu.hidden = !switcherOpen;
      if (!switcherOpen) return;
      menu.innerHTML = '';
      for (const sum of summaries) {
        const row = document.createElement('div');
        row.className = `switcher-row${sum.id === selectedProjectId ? ' active' : ''}`;
        row.innerHTML = `
          <span class="switcher-row-name" title="${escapeHtml(sum.root)}">${escapeHtml(sum.label)}</span>
          ${chipHtml(sum)}
          <span class="switcher-row-actions">
            <button data-edit-subrepos title="subrepos 편집">⚙</button>
            <button data-remove-project class="danger" title="프로젝트 등록 해제">✕</button>
          </span>`;
        row.querySelector('.switcher-row-name').onclick = () => setSelectedProject(sum.id);
        row.querySelector('[data-edit-subrepos]').onclick = (e) => { e.stopPropagation(); openSubrepoEdit(sum); };
        row.querySelector('[data-remove-project]').onclick = (e) => { e.stopPropagation(); removeProject(sum); };
        menu.appendChild(row);
      }
      const reg = document.createElement('button');
      reg.className = 'switcher-register';
      reg.textContent = '+ 프로젝트 등록';
      reg.onclick = () => openRegisterPanel();
      menu.appendChild(reg);
    }

    document.getElementById('switcherToggle').onclick = () => { switcherOpen = !switcherOpen; renderSwitcher(); };
    document.addEventListener('click', (e) => {
      if (switcherOpen && !e.target.closest('#switcher')) { switcherOpen = false; renderSwitcher(); }
    });

    function showRegisterPanel(show) {
      document.getElementById('registerBackdrop').hidden = !show;
    }

    function openRegisterPanel() {
      switcherOpen = false;
      document.getElementById('registerTitle').textContent = '프로젝트 등록';
      document.getElementById('registerPath').value = '';
      document.getElementById('registerPath').disabled = false;
      document.getElementById('registerBrowse').hidden = false;  // 등록: 경로 탐색·분석 노출
      document.getElementById('registerInfer').hidden = false;
      document.getElementById('registerPreview').hidden = true;
      document.getElementById('registerError').hidden = true;
      document.getElementById('browsePanel').hidden = true;
      // 이전 infer 잔재 제거 — 새 등록은 빈 상태에서 시작
      document.getElementById('registerChecklist').innerHTML = '';
      document.getElementById('registerMeta').textContent = '';
      showRegisterPanel(true);
      renderSwitcher();
    }

    function addChecklistRow(name, checked, removable) {
      const box = document.getElementById('registerChecklist');
      if ([...box.querySelectorAll('input')].some(c => c.value === name)) return; // 중복 방지
      const empty = box.querySelector('.register-empty'); if (empty) empty.remove();
      const row = document.createElement('label');
      row.className = 'register-check';
      const cb = document.createElement('input');
      cb.type = 'checkbox'; cb.value = name; cb.checked = checked;
      row.appendChild(cb);
      row.appendChild(document.createTextNode(name));
      if (removable) {
        // 수동 추가분만 ✕ 로 목록에서 제거 가능. infer 가 잡은 기본 subrepo 는 디스크에 실재 → 체크해제만(재분석 시 부활)
        const rm = document.createElement('button');
        rm.type = 'button'; rm.className = 'check-remove'; rm.textContent = '✕'; rm.title = '목록에서 제거';
        rm.onclick = (e) => { e.preventDefault(); e.stopPropagation(); row.remove(); };
        row.appendChild(rm);
      }
      box.appendChild(row);
    }
    function renderChecklist(universe, checked, inferred) {
      const box = document.getElementById('registerChecklist');
      box.innerHTML = '';
      if (!universe.length && !checked.length) {
        box.innerHTML = '<div class="register-empty">monorepo (subrepos 없음) — 필요하면 아래에 직접 추가</div>';
        return;
      }
      // inferred(코드로 잡힌 기본)는 ✕ 없음, universe 중 inferred 아닌 것(수동/깊은)만 removable
      for (const name of universe) addChecklistRow(name, checked.includes(name), !inferred.includes(name));
    }
    document.getElementById('registerManualAdd').onclick = () => {
      const input = document.getElementById('registerManualPath');
      const name = input.value.trim().replace(/^\/+|\/+$/g, '');
      const err = document.getElementById('registerError');
      if (!name) return;
      if (name.startsWith('/') || name.split('/').includes('..')) {
        err.textContent = '프로젝트 root 상대경로만 (선행 / 또는 .. 불가)'; err.hidden = false; return;
      }
      err.hidden = true;
      addChecklistRow(name, true, true);
      input.value = '';
    };

    async function inferAndPreview(path, checkedDefault) {
      const err = document.getElementById('registerError');
      err.hidden = true;
      try {
        const info = await api('/api/infer-project', {
          method: 'POST', headers: {'content-type': 'application/json'},
          body: JSON.stringify({ path }),
        });
        document.getElementById('registerMeta').textContent =
          `id: ${info.id} · ${info.worktreeGlobs.join(', ')}`;
        const inferred = info.subrepos || [];
        const checked = checkedDefault === null ? inferred : checkedDefault;
        // edit: 등록돼 있지만 infer 가 못 잡은(깊은/수동) subrepo 도 universe 에 포함 → 체크된 채 보이게
        const universe = [...inferred, ...checked.filter(n => !inferred.includes(n))];
        renderChecklist(universe, checked, inferred);
        document.getElementById('registerPreview').hidden = false;
        return info;
      } catch (e) {
        err.textContent = String(e.message || e); err.hidden = false;
        document.getElementById('registerPreview').hidden = true;
        return null;
      }
    }

    document.getElementById('registerClose').onclick = () => showRegisterPanel(false);
    // 모달: 배경 클릭·Esc 로 닫기 (등록 중이 아닐 때만 — 빈 레지스트리 기본 뷰면 닫아도 render 가 다시 염)
    document.getElementById('registerBackdrop').onclick = (e) => { if (e.target.id === 'registerBackdrop') showRegisterPanel(false); };
    document.addEventListener('keydown', (e) => {
      if (e.key === 'Escape' && !document.getElementById('registerBackdrop').hidden) showRegisterPanel(false);
    });

    let browseCurrent = '';
    let browseMode = 'project';  // 'project' = registerPath 채움 / 'subrepo' = 상대경로로 체크리스트 추가
    let browseRoot = '';         // subrepo 모드의 resolved 프로젝트 root (상대경로 계산 기준)
    function relPath(root, target) {
      // root 기준 target 의 상대경로 — root 밖이면 ../ 포함 (자유 등록 허용)
      const r = root.replace(/\/+$/, '').split('/');
      const t = target.replace(/\/+$/, '').split('/');
      let i = 0; while (i < r.length && i < t.length && r[i] === t[i]) i++;
      return [...r.slice(i).map(() => '..'), ...t.slice(i)].join('/') || '.';
    }
    async function openBrowse(path) {
      const panel = document.getElementById('browsePanel');
      try {
        const data = await api('/api/browse' + (path ? ('?path=' + enc(path)) : ''));
        browseCurrent = data.path;
        document.getElementById('browsePath').textContent = data.path;
        const list = document.getElementById('browseList');
        list.innerHTML = '';
        if (data.parent) {
          const up = document.createElement('div');
          up.className = 'browse-row'; up.innerHTML = '<span>📁 ..</span>';
          up.onclick = () => openBrowse(data.parent);
          list.appendChild(up);
        }
        for (const e of data.entries) {
          const row = document.createElement('div');
          row.className = 'browse-row';
          row.innerHTML = `<span>📁 ${escapeHtml(e.name)}</span>${e.isGitRepo ? '<span class="repo-badge">git</span>' : ''}`;
          row.onclick = () => openBrowse(data.path.replace(/\/$/, '') + '/' + e.name);
          list.appendChild(row);
        }
        panel.hidden = false;
      } catch (err) {
        const el = document.getElementById('registerError');
        el.textContent = String(err.message || err); el.hidden = false;
      }
    }
    document.getElementById('registerBrowse').onclick = () => {
      browseMode = 'project';
      document.getElementById('registerError').after(document.getElementById('browsePanel')); // 경로줄 아래로
      const cur = document.getElementById('registerPath').value.trim();
      openBrowse(cur || '');
    };
    document.getElementById('registerManualBrowse').onclick = async () => {
      const root = document.getElementById('registerPath').value.trim();
      const err = document.getElementById('registerError');
      if (!root) { err.textContent = '프로젝트 경로 먼저 입력'; err.hidden = false; return; }
      err.hidden = true;
      browseMode = 'subrepo';
      document.querySelector('.register-manual').after(document.getElementById('browsePanel')); // 수동 입력줄 바로 아래로
      try {
        const data = await api('/api/browse?path=' + enc(root));
        browseRoot = data.path;                 // resolved 프로젝트 root — 이 위로는 못 올라감
        openBrowse(data.path);
      } catch (e) { err.textContent = String(e.message || e); err.hidden = false; }
    };
    document.getElementById('browseSelect').onclick = () => {
      if (browseMode === 'subrepo') {
        const rel = relPath(browseRoot, browseCurrent);
        if (rel !== '.') addChecklistRow(rel, true, true);  // root 자신만 제외, 그 외(../ 상위 포함)는 자유 등록
      } else {
        document.getElementById('registerPath').value = browseCurrent;
      }
      document.getElementById('browsePanel').hidden = true;
    };
    document.getElementById('registerInfer').onclick = () => {
      const path = document.getElementById('registerPath').value.trim();
      if (path) inferAndPreview(path, null); // 신규 = 전체 체크 기본
    };
    document.getElementById('registerConfirm').onclick = async () => {
      const path = document.getElementById('registerPath').value.trim();
      const subrepos = [...document.querySelectorAll('#registerChecklist input:checked')].map(c => c.value);
      const err = document.getElementById('registerError');
      const btn = document.getElementById('registerConfirm');
      const label = btn.textContent;
      err.hidden = true;
      btn.disabled = true; btn.innerHTML = BUSY_DOTS;
      let res;
      try {
        res = await api('/api/add-project', {
          method: 'POST', headers: {'content-type': 'application/json'},
          body: JSON.stringify({ path, subrepos }),
        });
      } catch (e) {
        err.textContent = String(e.message || e); err.hidden = false;
        btn.disabled = false; btn.textContent = label;
        return; // 패널 유지 — 사용자가 경로 고쳐 재시도
      }
      showRegisterPanel(false);
      await loadWorktrees(true);
      await load({ force: true });
      btn.disabled = false; btn.textContent = label;
      // 서버가 돌려준 resolved id 로 선택 (타이핑 경로 문자열 매칭의 basename 충돌·trailing slash 함정 회피)
      if (res && res.id && [...new Set(worktreeData.map(w => w.projectId))].includes(res.id)) setSelectedProject(res.id);
      else render();
    };

    async function openSubrepoEdit(sum) {
      switcherOpen = false;
      document.getElementById('registerTitle').textContent = `subrepos 편집 — ${sum.label}`;
      document.getElementById('registerPath').value = sum.root;
      document.getElementById('registerPath').disabled = true;
      document.getElementById('registerBrowse').hidden = true;   // 편집: 경로 고정이라 탐색·분석 숨김(분석은 누르면 리셋 위험)
      document.getElementById('registerInfer').hidden = true;
      document.getElementById('registerError').hidden = true;
      document.getElementById('registerPreview').hidden = true;
      document.getElementById('browsePanel').hidden = true;
      showRegisterPanel(true);
      renderSwitcher();
      // universe = infer(현재 nested-git 전수), checked = 레지스트리에 등록된 큐레이션 집합(main 엔트리 payload).
      const mainEntry = worktreeData.find(w => w.projectId === sum.id && w.isMain);
      const current = mainEntry ? (mainEntry.subrepos || []) : [];
      await inferAndPreview(sum.root, current);
    }

    async function removeProject(sum) {
      if (!confirm(`'${sum.label}' 등록을 해제할까요? (코드·worktree 는 그대로, 레지스트리에서만 제거)`)) return;
      try {
        await api('/api/remove-project', {
          method: 'POST', headers: {'content-type': 'application/json'},
          body: JSON.stringify({ id: sum.id }),
        });
      } catch (e) {
        alert(`등록 해제 실패: ${e.message || e}`);
        return;
      }
      if (selectedProjectId === sum.id) setSelectedProject(null);
      await loadWorktrees(true);
      await load({ force: true });
      render();
    }

    async function api(path, options) {
      const res = await fetch(path, options);
      if (!res.ok) throw new Error(await res.text());
      return res.json();
    }

    function enc(value) { return encodeURIComponent(value); }
    function selectedServiceKey() { return selected ? `${selected.root}::${selected.service}` : ''; }
    function escapeHtml(value) {
      return String(value ?? '').replace(/[&<>"']/g, ch => ({
        '&': '&amp;',
        '<': '&lt;',
        '>': '&gt;',
        '"': '&quot;',
        "'": '&#39;'
      })[ch]);
    }

    function serviceMeta(root, service) {
      const session = sessions.find(item => item.root === root);
      if (!session) return {session: null, service: null};
      return {session, service: session.services.find(item => item.service === service)};
    }

    // ── 서비스 추가/편집 모달 ──────────────────────────────────────────────────
    let svcModalTarget = null; // {root, subrepo, editName} — editName null 이면 신규

    function showServiceModal(show) {
      document.getElementById('serviceBackdrop').hidden = !show;
    }

    function openServiceModal(root, subrepo, svc) {
      // svc=null → 신규 추가, svc=object → 편집
      svcModalTarget = {root, subrepo, editName: svc ? svc.service : null};
      document.getElementById('serviceModalTitle').textContent = svc ? ('서비스 편집 — ' + svc.service) : '서비스 추가';
      document.getElementById('serviceModalError').hidden = true;
      document.getElementById('svcName').value = svc ? svc.service : '';
      document.getElementById('svcName').disabled = !!svc; // 편집 시 이름 고정
      document.getElementById('svcTeamShare').disabled = !!svc; // 편집 시 저장 위치 고정
      document.getElementById('svcPortBase').value = svc && svc.def ? (svc.def.portBase ?? '') : '';
      document.getElementById('svcCwd').value = svc && svc.def ? (svc.def.cwd || '') : (subrepo || '');
      document.getElementById('svcRun').value = svc && svc.def ? (svc.def.run || '') : '';
      // 고급 필드
      const cachePaths = svc && svc.def ? (svc.def.cachePaths || []).join(', ') : '';
      document.getElementById('svcCachePaths').value = cachePaths;
      document.getElementById('svcOrphanPattern').value = svc && svc.def ? (svc.def.orphanPattern || '') : '';
      document.getElementById('svcAdvFields').hidden = true;
      document.getElementById('svcAdvToggle').textContent = '▸ 고급';
      // 팀 공유 체크박스: source=root → 팀 공유, source=central → 내 override
      // 신규 추가 기본: 중앙(미체크) — 팀 공유는 opt-in
      const teamShare = svc ? (svc.source === 'root') : false;
      document.getElementById('svcTeamShare').checked = teamShare;
      // datalist: 현재 세션의 subrepos
      const dl = document.getElementById('svcCwdList');
      dl.innerHTML = '';
      const session = sessions.find(s => s.root === root);
      const wt = worktreeData.find(w => w.root === root);
      const subs = wt ? (wt.subrepos || []) : [];
      for (const sub of subs) {
        const opt = document.createElement('option');
        opt.value = sub;
        dl.appendChild(opt);
      }
      showServiceModal(true);
    }

    document.getElementById('serviceModalClose').onclick = () => showServiceModal(false);
    document.getElementById('serviceBackdrop').onclick = (e) => { if (e.target.id === 'serviceBackdrop') showServiceModal(false); };
    document.addEventListener('keydown', (e) => {
      if (e.key === 'Escape' && !document.getElementById('serviceBackdrop').hidden) showServiceModal(false);
    });
    document.getElementById('svcAdvToggle').onclick = () => {
      const adv = document.getElementById('svcAdvFields');
      adv.hidden = !adv.hidden;
      document.getElementById('svcAdvToggle').textContent = adv.hidden ? '▸ 고급' : '▾ 고급';
    };
    document.getElementById('svcModalCancel').onclick = () => showServiceModal(false);

    document.getElementById('svcModalSave').onclick = async () => {
      const errEl = document.getElementById('serviceModalError');
      errEl.hidden = true;
      if (!svcModalTarget) return;
      const name = document.getElementById('svcName').value.trim();
      const portBaseRaw = document.getElementById('svcPortBase').value.trim();
      const cwd = document.getElementById('svcCwd').value.trim();
      const run = document.getElementById('svcRun').value.trim();
      const cachePathsRaw = document.getElementById('svcCachePaths').value.trim();
      const orphanPattern = document.getElementById('svcOrphanPattern').value.trim();
      const teamShare = document.getElementById('svcTeamShare').checked;
      if (!name) { errEl.textContent = '서비스 이름은 필수입니다'; errEl.hidden = false; return; }
      if (!run) { errEl.textContent = '실행 커맨드는 필수입니다'; errEl.hidden = false; return; }
      const portBase = parseInt(portBaseRaw, 10);
      if (!portBaseRaw || isNaN(portBase)) { errEl.textContent = 'portBase 는 숫자여야 합니다'; errEl.hidden = false; return; }
      const svc = {name, portBase, cwd, run};
      if (cachePathsRaw) {
        svc.cachePaths = cachePathsRaw.split(',').map(s => s.trim()).filter(Boolean);
      }
      if (orphanPattern) svc.orphanPattern = orphanPattern;
      const btn = document.getElementById('svcModalSave');
      const label = btn.textContent;
      btn.disabled = true; btn.textContent = '저장 중…';
      try {
        await api('/api/add-service', {
          method: 'POST', headers: {'content-type': 'application/json'},
          body: JSON.stringify({root: svcModalTarget.root, service: svc, central: !teamShare}),
        });
        showServiceModal(false);
        await load({force: true});
      } catch (e) {
        errEl.textContent = String(e.message || e); errEl.hidden = false;
      } finally {
        btn.disabled = false; btn.textContent = label;
      }
    };

    async function deleteSvc(session, svc) {
      if (!confirm('서비스 \'' + svc.service + '\' 를 삭제할까요?')) return;
      try {
        await api('/api/remove-service', {
          method: 'POST', headers: {'content-type': 'application/json'},
          body: JSON.stringify({root: session.root, name: svc.service, central: svc.source === 'central'}),
        });
        await load({force: true});
      } catch (e) {
        alert('삭제 실패: ' + (e.message || e));
      }
    }
    // ─────────────────────────────────────────────────────────────────────────

    // 진행 중 표시 + 중복 클릭 방지: 누른 버튼은 라벨 교체, group 버튼들은 함께 비활성화.
    // 완료 후 보통 재렌더로 교체되지만, 에러·취소 경로를 위해 finally 에서 원복.
    // 모든 진행중 표시 공통 — 떠다니는 점 3개. withBusy 의 label 인자는 이제 표시에 안 쓰임(점으로 통일), 호환 위해 시그니처만 유지
    const BUSY_DOTS = '<span class="busy-dots" role="status" aria-label="처리 중"><i></i><i></i><i></i></span>';
    function withBusy(btn, label, fn, group) {
      if (btn.disabled) return;
      const targets = group ? Array.from(group) : [btn];
      const original = btn.innerHTML;   // innerHTML — 아이콘(SVG) 버튼도 보존 (textContent 면 복원 시 자식 노드 소실 → 빈 버튼)
      for (const b of targets) b.disabled = true;
      btn.innerHTML = BUSY_DOTS;
      fn().catch(alert).finally(() => {
        for (const b of targets) b.disabled = false;
        btn.innerHTML = original;
      });
    }

    async function action(type, root, service, force = false) {
      const result = await api(`/api/${type}`, {
        method: 'POST',
        headers: {'content-type': 'application/json'},
        body: JSON.stringify({root, service, force})
      });
      if (result?.blocked === 'low-memory') {
        const freeGb = (result.freeMb / 1024).toFixed(1);
        const minGb = (result.minFreeMb / 1024).toFixed(1);
        if (confirm(`메모리 여유가 ${freeGb}GB뿐이라 시작을 막았어 (기준 ${minGb}GB).\n유령 프로세스/다른 세션 먼저 정리하는 걸 추천. 그래도 시작할까?`)) {
          return action(type, root, service, true);
        }
        return;
      }
      await load({force: true});
      selectLog(root, service, 'current', selected?.mode ?? 'service');
    }

    function renderMemory(memory, sessionList) {
      const box = document.getElementById('mem');
      if (!memory || memory.freePercent == null) { box.hidden = true; return; }
      box.hidden = false;
      // "시스템"은 OS 전체(브라우저·IDE 등 모든 앱 포함) — dev 서비스 합과 단위가 다르다는
      // 혼동이 있어 둘을 분리 표기. dev = marina 가 추적 중인 서비스 RSS 합.
      const usedPercent = 100 - memory.freePercent;
      const usedGb = ((memory.totalMb - memory.freeMb) / 1024).toFixed(1);
      const totalGb = Math.round(memory.totalMb / 1024);
      const devMb = (sessionList ?? []).reduce((sum, s) => sum + s.services.reduce((a, svc) => a + (svc.running && svc.rssMb ? svc.rssMb : 0), 0), 0);
      const devPart = devMb ? `dev ${(devMb / 1024).toFixed(1)}GB · ` : '';
      document.getElementById('memText').textContent = `${devPart}시스템 ${usedGb}/${totalGb}GB (${usedPercent}%)`;
      document.getElementById('memBar').style.width = `${usedPercent}%`;
      box.classList.toggle('warn', memory.freeMb < 4096);
    }

    let orphanSignature = '';
    async function loadOrphans() {
      const data = await api('/api/orphans');
      const nextSignature = JSON.stringify(data.orphans ?? []);
      if (nextSignature === orphanSignature) return; // 변화 없으면 패널 재구성 스킵
      orphanSignature = nextSignature;
      renderOrphans(data.orphans ?? []);
    }

    function renderOrphans(orphans) {
      const chip = document.getElementById('orphanChip');
      const panel = document.getElementById('orphanPanel');
      if (!orphans.length) {
        chip.hidden = true;
        panel.hidden = true;
        panel.innerHTML = '';
        return;
      }
      const totalMb = orphans.reduce((sum, o) => sum + (o.rssMb || 0), 0);
      chip.hidden = false;
      chip.textContent = `유령 ${orphans.length} · ${totalMb}MB`;
      chip.classList.toggle('alert', totalMb > 1024);
      panel.innerHTML = `
        <div class="orphan-head">marina 패턴인데 세션 추적 밖인 프로세스</div>
        ${orphans.map(o => `
          <div class="orphan-row">
            <div class="orphan-meta"><b>${escapeHtml(o.label)}</b> pid=${o.pid} · ${o.rssMb}MB · up ${escapeHtml(o.etime)}<br>${escapeHtml(o.command)}</div>
            <button class="danger" data-kill-pid="${o.pid}" title="프로세스 그룹 TERM→KILL">Kill</button>
          </div>`).join('')}
        <div class="orphan-actions"><button class="danger" data-kill-all ${orphans.length ? '' : 'disabled'}>Kill all</button></div>`;
      const orphanButtons = panel.querySelectorAll('.orphan-row button, [data-kill-all]');
      for (const btn of panel.querySelectorAll('[data-kill-pid]')) {
        btn.onclick = () => {
          withBusy(btn, 'Killing…', () => killOrphans([Number(btn.dataset.killPid)]), orphanButtons);
        };
      }
      const killAllBtn = panel.querySelector('[data-kill-all]');
      killAllBtn.onclick = () => {
        if (orphans.length && confirm(`유령 프로세스 ${orphans.length}개를 종료할까?`)) {
          withBusy(killAllBtn, 'Killing…', () => killOrphans(orphans.map(o => o.pid)), orphanButtons);
        }
      };
    }

    async function killOrphans(pids) {
      await api('/api/kill-orphans', {
        method: 'POST',
        headers: {'content-type': 'application/json'},
        body: JSON.stringify({pids})
      });
      await loadOrphans();
      await load({passive: true});
    }

    let worktreeData = [];
    let worktreeSignature = '';
    let worktreesLoaded = false;  // 첫 /api/worktrees 응답 전엔 "빈 레지스트리" 판정 보류 (cold load 스퓨리어스 등록 모달 방지)
    async function loadWorktrees(refresh = false) {
      const data = await api(`/api/worktrees${refresh ? '?refresh=1' : ''}`);
      const nextSignature = JSON.stringify(data.worktrees ?? []);
      // 변화 없으면 재렌더 스킵 — 60초 폴링이 입력·진행 중 버튼을 흔들지 않게
      if (!refresh && nextSignature === worktreeSignature) return;
      worktreeSignature = nextSignature;
      worktreeData = data.worktrees ?? [];
      worktreesLoaded = true;
      if (!configDirty) render(); // 카드의 디스크·캐시·배지 라인 갱신
    }


    async function saveConfig(root, card, restartRunning) {
      const config = {};
      for (const input of card.querySelectorAll('[data-config-key]')) {
        config[input.dataset.configKey] = input.value.trim();
      }
      await api('/api/config', {
        method: 'POST',
        headers: {'content-type': 'application/json'},
        body: JSON.stringify({root, config})
      });
      configDirty = false;
      if (restartRunning) {
        // 구동 중인 서비스만 재시작 (포트·프로파일 변경 반영) — 특정 서비스명 하드코딩 제거
        const sess = sessions.find(s => s.root === root);
        for (const svc of (sess?.services ?? [])) {
          if (svc.running) await action('restart', root, svc.service);
        }
      }
      await load({force: true});
    }

    async function saveAlias(session, input) {
      const alias = input.value.trim();
      await api('/api/meta', {
        method: 'POST',
        headers: {'content-type': 'application/json'},
        body: JSON.stringify({root: session.root, meta: {alias}})
      });
      session.alias = alias;
      await load({force: true});
    }

    async function sessionAction(type, session) {
      if (type === 'cleanup' && !confirm(`${session.alias || session.id} 세션을 리셋할까?\n(로그·pid·포트 설정·alias 삭제 — 코드/worktree 는 무관)`)) return;
      await api(`/api/${type}`, {
        method: 'POST',
        headers: {'content-type': 'application/json'},
        body: JSON.stringify({root: session.root})
      });
      await load({force: true});
    }

    async function setDefaultAttach(session, wt, name, want) {
      const cur = new Set(wt?.defaultAttach ?? wt?.subrepos ?? []);
      if (want) cur.add(name); else cur.delete(name);
      const r = await api('/api/set-default-attach', {
        method: 'POST', headers: {'content-type': 'application/json'},
        body: JSON.stringify({root: session.root, subrepos: [...cur]}),
      });
      if (r?.error) { alert(`기본 attach 변경 실패: ${r.error}`); }
      await loadWorktrees(true);
      render();
    }

    async function attachSubrepo(session, name) {
      const r = await api('/api/attach-subrepo', {
        method: 'POST', headers: {'content-type': 'application/json'},
        body: JSON.stringify({root: session.root, subrepo: name}),
      });
      if (r?.error) { alert(`attach 실패: ${r.error}`); return; }
      await loadWorktrees(true);
      await load({force: true});
    }

    async function detachSubrepo(session, name) {
      const body = {root: session.root, subrepo: name};
      const send = () => api('/api/detach-subrepo', {
        method: 'POST', headers: {'content-type': 'application/json'}, body: JSON.stringify(body),
      });
      let r = await send();
      if (r?.needsStop) {
        if (!confirm(`${name} 에서 구동 중인 서비스(${r.needsStop.join('·')})를 정지하고 detach 할까?`)) return;
        body.stopServices = true;
        r = await send();
      }
      if (r?.needsConfirm) {
        if (!confirm(`${name} 에 미커밋 변경분이 있어. detach 하면 변경·untracked 가 폐기돼 (브랜치·커밋은 보존). 폐기하고 detach 할까?`)) return;
        body.force = true;
        r = await send();
      }
      if (r?.error) { alert(`detach 실패: ${r.error}`); return; }
      await loadWorktrees(true);
      await load({force: true});
    }

    // ── 로그 뷰어 엔진: 라인 단위 렌더 + ANSI 컬러 + 레벨 하이라이트 + 필터 + 5천줄 링버퍼 ──
    const LOG_MAX_LINES = 5000;
    const LOG_MATCH_CAP = 2000;  // 서버 LOG_MATCH_CAP 과 동기
    let logEntries = [];
    let logFilterText = '';
    let logErrorsOnly = false;

    const ANSI_FG = {
      30: 'hsl(220, 8%, 50%)', 31: 'hsl(358, 75%, 62%)', 32: 'hsl(148, 55%, 48%)',
      33: 'hsl(40, 85%, 52%)', 34: 'hsl(215, 90%, 62%)', 35: 'hsl(280, 70%, 68%)',
      36: 'hsl(190, 80%, 52%)', 37: 'hsl(220, 14%, 80%)',
      90: 'hsl(220, 8%, 55%)', 91: 'hsl(358, 80%, 68%)', 92: 'hsl(148, 60%, 55%)',
      93: 'hsl(45, 90%, 58%)', 94: 'hsl(215, 95%, 68%)', 95: 'hsl(280, 75%, 74%)',
      96: 'hsl(190, 85%, 60%)', 97: 'hsl(0, 0%, 95%)'
    };

    function ansiToHtml(raw) {
      const parts = raw.split(/\x1b\[([0-9;]*)m/);
      let html = '';
      let color = null;
      let bold = false;
      for (let i = 0; i < parts.length; i++) {
        if (i % 2 === 0) {
          if (!parts[i]) continue;
          const style = [color ? `color:${color}` : '', bold ? 'font-weight:700' : ''].filter(Boolean).join(';');
          html += style ? `<span style="${style}">${escapeHtml(parts[i])}</span>` : escapeHtml(parts[i]);
        } else {
          for (const code of (parts[i] || '0').split(';')) {
            const n = Number(code || 0);
            if (n === 0) { color = null; bold = false; }
            else if (n === 1) bold = true;
            else if (n === 22) bold = false;
            else if (n === 39) color = null;
            else if (ANSI_FG[n]) color = ANSI_FG[n];
          }
        }
      }
      return html;
    }

    function stripAnsi(raw) { return raw.replace(/\x1b\[[0-9;]*m/g, ''); }

    // 파이썬 트레이스백은 여러 줄 한 덩어리 — 시작 줄 이후 들여쓴 연속 줄과
    // 마지막 예외 줄(XxxError: ...)까지 err 로 묶는다 (Err 필터에서 통째로 보이게)
    let logTracebackSticky = false;
    function detectLogLevel(plain) {
      if (/Traceback \(most recent call last\)/.test(plain)) { logTracebackSticky = true; return 'err'; }
      if (logTracebackSticky) {
        if (/^[ \t]/.test(plain) || plain === '') return 'err';
        logTracebackSticky = false;
        if (/^[\w.]+(Error|Exception|Exit|Interrupt|Warning)\b/.test(plain)) return 'err';
      }
      if (/^\s*(Caused by\b|at [\w.$<>/]+\()/.test(plain)) return 'err';
      if (/\[(error|window\.error|unhandledrejection)\]/i.test(plain) || /\b(ERROR|FATAL|SEVERE)\b/.test(plain) || /\b[\w.]*(Exception|Error):/.test(plain) || /Exception|Traceback/.test(plain)) return 'err';
      if (/\[warn\]/i.test(plain) || /\bWARN(ING)?\b/.test(plain)) return 'warn';
      return '';
    }

    function logEntryVisible(entry) {
      if (logErrorsOnly && !entry.level) return false;
      if (logFilterText && !entry.plainLower.includes(logFilterText)) return false;
      return true;
    }

    function updateLogCount() {
      const posEl = document.getElementById('gaugePos');
      if (!selected) { posEl.textContent = ''; renderMatchCount(); return; }
      if (matchView) {
        posEl.textContent = `매치 ${logEntries.length}건 표시`;
      } else {
        const size = Math.max(logFileSize, logWindow.bottom);
        const pct = size ? Math.min(100, Math.round((logWindow.bottom / size) * 100)) : 100;
        posEl.textContent = `${pct}% 지점 · 창 ${logEntries.length}줄`;
      }
      renderMatchCount();
    }

    function renderMatchCount() {
      const el = document.getElementById('matchCount');
      if (!logMatches.active) { el.textContent = ''; return; }
      if (matchView) {
        const cap = logMatches.truncated ? ` (파일 앞쪽 ${logMatches.items?.length ?? 0}건만 표시)` : '';
        el.textContent = `파일 전체 ${logMatches.total}건${cap}`;
        return;
      }
      const visible = logEntries.reduce((sum, entry) => sum + (logEntryVisible(entry) ? 1 : 0), 0);
      const cap = logMatches.truncated ? ` (파일 앞쪽 ${logMatches.offsets.length}건만 틱 표시)` : '';
      el.textContent = `파일 전체 ${logMatches.total}건 · 화면 ${visible}건${cap}`;
    }

    let gaugeRaf = 0;
    function renderGauge() {
      if (gaugeRaf) return;
      gaugeRaf = requestAnimationFrame(() => {
        gaugeRaf = 0;
        const track = document.getElementById('gaugeTrack');
        const win = document.getElementById('gaugeWindow');
        const size = Math.max(logFileSize, logWindow.bottom, 1);
        if (matchView) {
          // 매치 뷰는 파일 전체를 커버 — 창 띠도 전체
          win.style.left = '0%';
          win.style.width = '100%';
        } else {
          win.style.left = `${(logWindow.top / size) * 100}%`;
          win.style.width = `${Math.max(((logWindow.bottom - logWindow.top) / size) * 100, 0.5)}%`;
        }
        for (const tick of track.querySelectorAll('.gauge-tick')) tick.remove();
        if (!logMatches.offsets.length) return;
        // 0.5% 버킷으로 병합 — 매치 수천 개여도 DOM 틱은 최대 200개
        const buckets = new Set();
        for (const offset of logMatches.offsets) buckets.add(Math.round((offset / size) * 200));
        for (const bucket of buckets) {
          const tick = document.createElement('div');
          tick.className = 'gauge-tick';
          tick.style.left = `${bucket / 2}%`;
          track.appendChild(tick);
        }
      });
    }

    function scheduleMatchScan() {
      clearTimeout(matchScanTimer);
      matchScanTimer = setTimeout(() => fetchMatches().catch(console.error), 350);
    }

    async function fetchMatches() {
      logMatches = {offsets: [], total: 0, truncated: false, active: false};
      if (!selected || (!logFilterText && !logErrorsOnly)) {
        renderMatchCount();
        renderGauge();
        if (matchView) {
          // 필터 해제 — 일반 tail 뷰로 복귀 (선택이 사라졌으면 상태만 내린다)
          matchView = false;
          if (selected) selectLog(selected.root, selected.service, selected.run, selected.mode);
        }
        return;
      }
      const actualService = selected.mode === 'console' ? 'console' : selected.service;
      const reqKey = `${selected.root}|${actualService}|${selected.run}|${logFilterText}|${logErrorsOnly}`;
      const data = await api(`/api/logs/matches?root=${enc(selected.root)}&service=${enc(actualService)}&run=${enc(selected.run)}&q=${enc(logFilterText)}&errOnly=${logErrorsOnly ? 1 : 0}`);
      const nowService = selected && (selected.mode === 'console' ? 'console' : selected.service);
      const nowKey = selected && `${selected.root}|${nowService}|${selected.run}|${logFilterText}|${logErrorsOnly}`;
      if (nowKey !== reqKey) return;  // 응답 대기 중 선택/필터가 바뀜 — 구식 응답 폐기
      logMatches = {offsets: data.matches.map(item => item.o), items: data.matches, total: data.total, truncated: data.truncated, active: true};
      logFileSize = Math.max(logFileSize, data.size);
      enterMatchView();
      renderMatchCount();
      renderGauge();
    }

    // 매치 전용 뷰 — 파일 전체의 매치를 한 번에 목록으로 (cap 2000 ≤ LOG_MAX_LINES 라 안전)
    function enterMatchView() {
      matchView = true;
      resetLogView();
      logTracebackSticky = false;
      const logEl = document.getElementById('log');
      const fragment = document.createDocumentFragment();
      for (const item of logMatches.items ?? []) {
        logTracebackSticky = false;  // 매치는 비연속 발췌 — sticky 가 다음 매치 색상을 오염시키지 않게
        const entry = makeLogEntry(item.t, null);
        entry.matchOffset = item.o;  // 게이지 클릭 → 목록 내 위치 탐색용
        entry.el.hidden = false;  // 서버가 이미 매치 판정 — 클라 재판정으로 숨기지 않는다
        entry.el.classList.add('match-row');
        entry.el.title = '클릭하면 필터를 풀고 이 위치 맥락으로 이동';
        entry.el.onclick = () => exitMatchViewTo(item.o);
        logEntries.push(entry);
        fragment.appendChild(entry.el);
      }
      if (!logEntries.length) {
        logEl.innerHTML = '<div class="empty">매치 없음</div>';
      } else {
        logEl.appendChild(fragment);
        logEl.scrollTop = logEl.scrollHeight;  // 최신 매치부터 — tail 멘탈 유지
      }
      lastLogScrollTop = logEl.scrollTop;
      updateOlderBar();
      updateLogCount();
    }

    // 매치 행 클릭 — 필터를 풀고 그 위치의 전후 맥락으로 점프
    function exitMatchViewTo(offset) {
      matchView = false;
      logFilterText = '';
      document.getElementById('logFilter').value = '';
      logErrorsOnly = false;
      document.getElementById('logErrOnly').classList.remove('active');
      logMatches = {offsets: [], total: 0, truncated: false, active: false};
      renderMatchCount();
      jumpToOffset(offset).catch(console.error);
    }

    // 매치 뷰 중 라이브 신규 라인 — 매치만 목록 끝에 합류 (비매치는 버림)
    function appendLiveMatchLine(raw, end) {
      const lineStart = logWindow.bottom;
      if (end != null) {
        logWindow.bottom = Math.max(logWindow.bottom, end);
        logFileSize = Math.max(logFileSize, end);
      }
      const entry = makeLogEntry(raw, end);
      if (!logEntryVisible(entry)) return;
      entry.matchOffset = lineStart;
      entry.el.hidden = false;
      entry.el.classList.add('match-row');
      entry.el.title = '클릭하면 필터를 풀고 이 위치 맥락으로 이동';
      entry.el.onclick = () => exitMatchViewTo(lineStart);
      logEntries.push(entry);
      logMatches.total += 1;
      if (logMatches.offsets.length < LOG_MATCH_CAP) logMatches.offsets.push(lineStart);
      // 매치 뷰에서 dropOldestLines 의 logWindow.top 갱신은 무의미하지만 무해 — 복귀 시 jumpToOffset 이 덮어씀
      dropOldestLines(logEntries.length - LOG_MAX_LINES);
      const logEl = document.getElementById('log');
      const placeholder = logEl.querySelector('.empty');
      if (placeholder) placeholder.remove();
      logEl.appendChild(entry.el);
      if (followLog) {
        logEl.scrollTop = logEl.scrollHeight;
        lastLogScrollTop = logEl.scrollTop;
      }
      updateLogCount();
      renderGauge();
    }

    // 게이지 클릭/매치 탐색 — 그 파일 위치로 점프 (근처 매치 틱이 있으면 스냅)
    let jumpInFlight = false;
    async function jumpToOffset(offset) {
      if (!selected || jumpInFlight) return;
      jumpInFlight = true;
      if (source) source.close();
      resetLogView();
      followLog = false;
      document.getElementById('followLog').classList.remove('active');
      logWindow = {top: offset, bottom: offset, live: false};
      logPaging = {loadingUp: false, loadingDown: false, atStart: offset === 0};
      const actualService = selected.mode === 'console' ? 'console' : selected.service;
      const base = `/api/logs/chunk?root=${enc(selected.root)}&service=${enc(actualService)}&run=${enc(selected.run)}`;
      const jumpKey = `${selected.root}|${actualService}|${selected.run}`;
      const stale = () => !selected || matchView || `${selected.root}|${selected.mode === 'console' ? 'console' : selected.service}|${selected.run}` !== jumpKey;
      try {
        const down = await api(`${base}&after=${offset}`);
        if (stale()) return;  // 응답 대기 중 다른 서비스/run 으로 전환 — 구식 응답 폐기
        // 서버가 라인 경계로 정렬한 실제 시작점 — before 도 같은 경계에서 만나 누락·중복 0
        const aligned = down.start;
        logWindow = {top: aligned, bottom: aligned, live: false};
        appendChunkLines(down.lines);
        logWindow.bottom = Math.max(logWindow.bottom, down.end);
        logFileSize = Math.max(logFileSize, down.size);
        const up = await api(`${base}&before=${aligned}`);
        if (stale()) return;
        prependLogLines(up.lines);
        logWindow.top = up.start;
        logFileSize = Math.max(logFileSize, up.size);
        logPaging.atStart = up.atStart;
        const target = logEntries.find(entry => entry.end != null && entry.end > aligned);
        if (target) {
          target.el.scrollIntoView({block: 'center'});
          target.el.classList.add('jump-hit');
          setTimeout(() => target.el.classList.remove('jump-hit'), 1500);
        }
      } catch (err) {
        console.error(err);
      } finally {
        jumpInFlight = false;
        lastLogScrollTop = document.getElementById('log').scrollTop;
        updateOlderBar();
        updateLogCount();
      }
    }

    function appendLogLine(raw, end) {
      const logEl = document.getElementById('log');
      const lineStart = logWindow.bottom;
      const entry = makeLogEntry(raw, end);
      logEntries.push(entry);
      if (entry.end != null) {
        logWindow.bottom = Math.max(logWindow.bottom, entry.end);
        logFileSize = Math.max(logFileSize, entry.end);
        // 라이브 신규 라인도 매치면 게이지 틱·카운트에 합류 (스캔 결과의 연장)
        if (logMatches.active && logEntryVisible(entry)) {
          logMatches.total += 1;
          if (logMatches.offsets.length < LOG_MATCH_CAP) logMatches.offsets.push(lineStart);
        }
      }
      dropOldestLines(logEntries.length - LOG_MAX_LINES);
      logEl.appendChild(entry.el);
      if (followLog) {
        logEl.scrollTop = logEl.scrollHeight;
        lastLogScrollTop = logEl.scrollTop;  // follow 점프를 '위로 스크롤' 로 오판하지 않게
      }
      updateLogCount();
      renderGauge();
    }

    function applyLogFilter() {
      if (matchView) { updateLogCount(); return; }  // 매치 뷰는 재스캔(fetchMatches)이 뷰를 재구성
      for (const entry of logEntries) entry.el.hidden = !logEntryVisible(entry);
      updateLogCount();
      if (followLog) {
        const logEl = document.getElementById('log');
        logEl.scrollTop = logEl.scrollHeight;
      }
    }

    function resetLogView(placeholder = '') {
      logEntries = [];
      logTracebackSticky = false;
      const logEl = document.getElementById('log');
      logEl.innerHTML = placeholder ? `<div class="empty">${escapeHtml(placeholder)}</div>` : '';
      logEl.scrollTop = 0;
      lastLogScrollTop = 0;
      updateLogCount();
    }

    function selectLog(root, service, run = 'current', mode = 'service') {
      const {session, service: svc} = serviceMeta(root, service);
      const actualService = mode === 'console' ? 'console' : service;
      selected = {root, service, run, mode};
      expandedRoots.add(root);
      document.getElementById('selectedRoot').textContent = root;
      document.getElementById('selectedLabel').textContent = `${session?.alias || session?.id || '-'} / ${service} / ${mode === 'console' ? 'browser console' : 'server log'}`;
      const isWeb = service === 'web';
      document.getElementById('logModeTabs').classList.toggle('visible', isWeb);
      document.getElementById('openWeb').hidden = !isWeb;
      for (const btn of document.querySelectorAll('[data-log-mode]')) btn.classList.toggle('active', btn.dataset.logMode === mode);
      renderRunSelect(session, service, mode, run);
      render();
      renderSelection();

      if (source) source.close();
      matchView = false;  // 필터가 살아 있으면 fetchMatches 가 새 대상 스캔 후 다시 진입
      resetLogView();
      logWindow = {top: 0, bottom: 0, live: false};
      logPaging = {loadingUp: false, loadingDown: false, atStart: true};
      logFileSize = 0;
      // 새 선택 = 최신 tail 부터 — follow 가 꺼진 채 재진입하면 화면이 창 맨 위에 고정되는 버그 방지
      followLog = true;
      document.getElementById('followLog').classList.add('active');
      updateOlderBar();
      openStream(null);
      fetchMatches().catch(console.error);  // 필터 활성 시 새 대상 재스캔, 아니면 클리어
    }

    // SSE tail 연결 — from 이 있으면 그 오프셋부터 이어받아 forward 페이징과 갭 없이 연결
    function openStream(from) {
      if (source) source.close();
      const actualService = selected.mode === 'console' ? 'console' : selected.service;
      const fromParam = from != null ? `&from=${from}` : '';
      source = new EventSource(`/api/logs?root=${enc(selected.root)}&service=${enc(actualService)}&run=${enc(selected.run)}${fromParam}`);
      logWindow.live = true;
      source.addEventListener('meta', (event) => {
        // 서버가 보낸 표시 시작 오프셋 — 그 이전 구간은 위로 스크롤해 페이징
        const meta = JSON.parse(event.data);
        if (!logEntries.length) logWindow.top = meta.start;  // 재연결이면 기존 창 유지
        logWindow.bottom = Math.max(logWindow.bottom, meta.start);
        logFileSize = Math.max(logFileSize, meta.size || 0);
        logPaging.atStart = logWindow.top === 0;
        updateOlderBar();
        updateLogCount();
      });
      source.onmessage = (event) => {
        const item = JSON.parse(event.data);
        if (matchView) appendLiveMatchLine(item.line, item.end);
        else appendLogLine(item.line, item.end);
      };
      source.onerror = () => {
        appendLogLine('[log stream disconnected]');
        source.close();
        logWindow.live = false;
      };
    }

    function fmtKb(bytes) {
      const kb = Math.max(1, Math.round(bytes / 1024));
      return kb >= 1024 ? `${(kb / 1024).toFixed(1)}MB` : `${kb}KB`;
    }

    function updateOlderBar() {
      document.getElementById('olderBar').hidden = !selected;
      if (!selected) return;
      const downNote = logWindow.live ? '' : ' · ↓ 아래로';
      document.getElementById('olderInfo').textContent =
        matchView ? '● 매치 목록 — 파일 전체'
        : logPaging.loadingUp ? '불러오는 중…'
        : logPaging.atStart ? `● 파일 시작${downNote}`
        : `↑ 위에 ${fmtKb(logWindow.top)} 더${downNote}`;
      renderGauge();
    }

    function makeLogEntry(raw, end) {
      const plain = stripAnsi(raw);
      const el = document.createElement('div');
      const level = detectLogLevel(plain);
      el.className = `log-line${level ? ' ' + level : ''}`;
      el.innerHTML = ansiToHtml(raw) || '&nbsp;';
      const entry = {level, plainLower: plain.toLowerCase(), el, end: end ?? null};
      el.hidden = !logEntryVisible(entry);
      return entry;
    }

    // 창 상단(과거쪽) 라인 제거 — 제거된 라인의 끝 오프셋으로 top 경계 전진
    function dropOldestLines(excess) {
      let dropped = false;
      while (excess-- > 0 && logEntries.length) {
        const removed = logEntries.shift();
        removed.el.remove();
        if (removed.end != null) logWindow.top = removed.end;
        dropped = true;
      }
      if (dropped) {
        logPaging.atStart = logWindow.top === 0;
        updateOlderBar();
      }
    }

    // 창 하단(최신쪽) 라인 제거 — 최신 구간을 버렸으니 SSE tail 도 분리 (아래로 스크롤해 복귀)
    function dropNewestLines(excess) {
      let dropped = false;
      while (excess-- > 0 && logEntries.length) {
        logEntries.pop().el.remove();
        dropped = true;
      }
      if (dropped) {
        const last = logEntries[logEntries.length - 1];
        if (last?.end != null) logWindow.bottom = last.end;
        if (logWindow.live) {
          if (source) source.close();
          logWindow.live = false;
        }
        followLog = false;
        document.getElementById('followLog').classList.remove('active');
      }
    }

    // 과거 청크를 위에 끼워 넣는다 — 화면 위치 보존, cap 초과분은 최신(아래쪽)부터 제거
    function prependLogLines(lines) {
      if (!lines.length) return;
      const logEl = document.getElementById('log');
      const entries = lines.map(item => makeLogEntry(item.t, item.e));
      const fragment = document.createDocumentFragment();
      for (const entry of entries) fragment.appendChild(entry.el);
      const prevHeight = logEl.scrollHeight;
      const prevTop = logEl.scrollTop;
      logEl.insertBefore(fragment, logEl.firstChild);
      logEntries = entries.concat(logEntries);
      dropNewestLines(logEntries.length - LOG_MAX_LINES);
      logEl.scrollTop = prevTop + (logEl.scrollHeight - prevHeight);
      lastLogScrollTop = logEl.scrollTop;  // 보정 점프를 '아래로 스크롤' 로 오판하지 않게 동기화
      updateLogCount();
    }

    // 이후(최신쪽) 청크를 아래에 붙인다 — cap 초과분은 과거(위쪽)부터 제거
    function appendChunkLines(lines) {
      if (!lines.length) return;
      const logEl = document.getElementById('log');
      const entries = lines.map(item => makeLogEntry(item.t, item.e));
      const fragment = document.createDocumentFragment();
      for (const entry of entries) fragment.appendChild(entry.el);
      logEl.appendChild(fragment);
      logEntries = logEntries.concat(entries);
      const last = entries[entries.length - 1];
      if (last.end != null) logWindow.bottom = Math.max(logWindow.bottom, last.end);
      dropOldestLines(logEntries.length - LOG_MAX_LINES);
      updateLogCount();
    }

    async function loadOlder() {
      // 매치 뷰는 파일 전체 매치가 이미 다 떠 있다 — 스크롤 페이징 불필요
      if (!selected || matchView || logPaging.atStart || logPaging.loadingUp || jumpInFlight) return;
      logPaging.loadingUp = true;
      updateOlderBar();
      try {
        const actualService = selected.mode === 'console' ? 'console' : selected.service;
        const reqTop = logWindow.top;
        const data = await api(`/api/logs/chunk?root=${enc(selected.root)}&service=${enc(actualService)}&run=${enc(selected.run)}&before=${reqTop}`);
        // 대기 중 창이 움직였거나 매치 뷰로 전환됐으면 구식 응답 — 폐기
        // (필터 토글 직후 hidden 으로 인한 scrollHeight 급감 → scroll 이벤트 → 여기 진입하는 race 가 실재)
        if (matchView || logWindow.top !== reqTop) return;
        prependLogLines(data.lines);
        logWindow.top = data.start;
        logFileSize = Math.max(logFileSize, data.size);
        logPaging.atStart = data.atStart;
      } catch (err) {
        console.error(err);
      } finally {
        logPaging.loadingUp = false;
        updateOlderBar();
      }
    }

    async function loadNewer() {
      if (!selected || matchView || logWindow.live || logPaging.loadingDown || jumpInFlight) return;
      logPaging.loadingDown = true;
      try {
        const actualService = selected.mode === 'console' ? 'console' : selected.service;
        const data = await api(`/api/logs/chunk?root=${enc(selected.root)}&service=${enc(actualService)}&run=${enc(selected.run)}&after=${logWindow.bottom}`);
        if (matchView) return;  // 대기 중 매치 뷰로 전환 — 구식 응답 폐기
        appendChunkLines(data.lines);
        logWindow.bottom = Math.max(logWindow.bottom, data.end);
        logFileSize = Math.max(logFileSize, data.size);
        // 파일 끝에 닿았고 current 면 끊긴 지점부터 SSE 재연결 — 갭·중복 없는 라이브 복귀
        if (data.atEnd && selected.run === 'current') openStream(logWindow.bottom);
      } catch (err) {
        console.error(err);
      } finally {
        logPaging.loadingDown = false;
        updateOlderBar();
      }
    }

    function renderRunSelect(session, service, mode, selectedRun) {
      const select = document.getElementById('runSelect');
      select.innerHTML = '';
      const runs = mode === 'console'
        ? session?.consoleLogRuns
        : session?.services.find(item => item.service === service)?.logRuns;
      const current = document.createElement('option');
      current.value = 'current';
      current.textContent = 'current';
      select.appendChild(current);
      for (const run of runs ?? []) {
        const option = document.createElement('option');
        option.value = run.id;
        option.textContent = run.label;
        select.appendChild(option);
      }
      select.value = selectedRun;
    }

    function renderSelection() {
      const key = selectedServiceKey();
      for (const row of document.querySelectorAll('[data-service-key]')) {
        row.classList.toggle('selected', row.dataset.serviceKey === key);
      }
    }

    function buildSessionSignature(items) {
      return items.map(item => item.root).join('|');
    }

    function runSummaryText(session) {
      const on = session.services.filter(svc => svc.running).map(svc => svc.service);
      return on.length ? `▶ ${on.join('·')}` : '';
    }

    function shortPath(path) {
      return path.replace(/^\/(?:Users|home)\/[^/]+/, '~');  // macOS·Linux 홈 단축
    }

    const CACHE_CAT_LABEL = {};  // 라벨은 서비스명 (marina-services.json cachePaths 기준) — 아래 ?? cat 폴백
    function renderCacheDetails(area, session, wt) {
      const cats = Object.entries(wt?.cacheCats ?? {}).filter(([, mb]) => mb > 0);
      area.innerHTML = cats.length ? cats.map(([cat, mb]) =>
        `<div>${CACHE_CAT_LABEL[cat] ?? cat} — ${(mb / 1024).toFixed(1)}GB <button data-clear-cat="${cat}">Clear</button></div>`
      ).join('') : '회수할 캐시 없음';
      for (const btn of area.querySelectorAll('[data-clear-cat]')) {
        btn.onclick = () => {
          const cat = btn.dataset.clearCat;
          const mb = wt?.cacheCats?.[cat] ?? 0;
          if (!confirm(`${session.alias || session.id} 의 ${cat} 캐시(${(mb / 1024).toFixed(1)}GB)를 비울까?\n다음 dev 시작 때 재생성돼. ${cat} 서비스 구동 중이면 거부돼.`)) return;
          withBusy(btn, 'Clearing…', async () => {
            const result = await api('/api/clear-cache', {
              method: 'POST',
              headers: {'content-type': 'application/json'},
              body: JSON.stringify({root: session.root, category: cat})
            });
            alert(`캐시 ${((result.freedMb || 0) / 1024).toFixed(1)}GB 회수`);
            await loadWorktrees(true);
            await load({force: true});
          });
        };
      }
    }

    // 헬스 3단계 pill — 첫 HTTP 응답 전은 시간 제한 없이 BOOT, 응답 이력(everOk) 있는 서비스가 멎으면 ERR
    const HEALTH_PILLS = {
      ok: {text: 'ON', cls: 'run', title: 'HTTP 응답 확인됨 — 사용 가능'},
      starting: {text: 'BOOT', cls: 'boot', title: '프로세스는 떴고 첫 HTTP 응답 대기 중 — 빌드·컴파일이 길어도 시간 제한 없이 BOOT 유지'},
      bad: {text: 'ERR', cls: 'bad', title: '응답하던 서비스가 응답을 멈춤 — 로그 확인 필요'},
    };
    function pillState(svc) {
      if (!svc.running) return {text: 'OFF', cls: 'stop', title: '정지됨'};
      return HEALTH_PILLS[svc.health] ?? HEALTH_PILLS.ok;
    }

    function updateServiceStates() {
      for (const session of sessions) {
        const card = document.querySelector(`[data-root="${CSS.escape(session.root)}"]`);
        const summary = card?.querySelector('[data-run-summary]');
        if (summary) summary.textContent = runSummaryText(session);
        const stopAllBtn = card?.querySelector('[data-stop-all]');   // 시작/정지에 맞춰 정지(■) 표시 동기화 (busy 중엔 건드리지 않음)
        if (stopAllBtn && !stopAllBtn.disabled) stopAllBtn.hidden = !session.services.some(svc => svc.running);
        for (const svc of session.services) {
          const row = document.querySelector(`[data-service-key="${CSS.escape(`${session.root}::${svc.service}`)}"]`);
          if (!row) continue;
          if (row.classList.contains('disabled')) continue;   // 미attach subrepo 의 서비스 — 라이브 상태로 덮지 않음
          const port = row.querySelector('[data-port]');
          const rss = row.querySelector('[data-rss]');
          const pill = row.querySelector('[data-state]');
          if (port) port.textContent = svc.port ?? '-';
          if (rss) rss.textContent = svc.running && svc.rssMb ? ` · ${svc.rssMb}MB` : '';
          if (pill) {
            const state = pillState(svc);
            pill.textContent = state.text;
            pill.className = `pill ${state.cls}`;
            pill.title = state.title;
          }
          // 상태 적응형 액션 — 정지: ▶ / 구동: ■·↻ (busy 중엔 건드리지 않음)
          for (const btn of row.querySelectorAll('[data-act]')) {
            if (btn.disabled) continue;
            btn.hidden = btn.dataset.act === 'start' ? svc.running : !svc.running;
          }
        }
      }
      renderSelection();
    }

    function render() {
      const sessionsEl = document.getElementById('sessions');
      sessionsEl.innerHTML = '';

      const wtByRoot = new Map(worktreeData.map(w => [w.root, w]));
      // 등록 프로젝트 목록 — 선택 보정(선택이 사라졌으면 첫 프로젝트로 폴백)
      const projectIds = [...new Set(worktreeData.map(w => w.projectId))];
      if (selectedProjectId && !projectIds.includes(selectedProjectId)) selectedProjectId = null;
      if (!selectedProjectId && projectIds.length) selectedProjectId = projectIds[0];
      renderSwitcher();
      // 빈 레지스트리 → 등록 패널이 기본 뷰 (spec C). 단 첫 worktree 로드 완료 후에만 — 로딩 중 스퓨리어스 방지
      if (worktreesLoaded && !projectIds.length) { showRegisterPanel(true); return; }
      // 선택 프로젝트로 스코프 — project-group 스태킹 대체 (세로 카드 목록 그대로)
      const scopedSessions = sessions.filter(s => wtByRoot.get(s.root)?.projectId === selectedProjectId);
      for (const session of scopedSessions) {
        const card = document.createElement('div');
        const isExpanded = expandedRoots.has(session.root);
        const wt = wtByRoot.get(session.root);
        // 상태를 원자적 칩으로 — 칩 내부는 개행 금지, 칩 사이에서만 줄바꿈
        const pills = [];
        const changeCount = (session.worktreeStatus?.repos ?? []).reduce((sum, repo) => sum + (repo.changeCount || 0), 0);
        if (!session.worktreeStatus?.clean) {
          pills.push(`<button class="pill-stat danger" data-changes-toggle title="미커밋 변경 파일 보기/접기">변경분 ${changeCount} ▾</button>`);
        }
        if (wt && wt.cacheMb > 50) {
          pills.push(`<button class="pill-stat" data-cache-toggle title="재생성 가능한 빌드 캐시 (marina-services.json cachePaths) — 클릭해 카테고리별 보기·개별 회수">캐시 ${(wt.cacheMb / 1024).toFixed(1)}GB ▾</button>`);
        }
        if (wt && !wt.isMain) {
          // 디스크·미활동은 정보성 — 칩이 아니라 root 메타 줄에 합산 (칩은 액션·경고만)
          if (wt.verdict === 'stale') pills.push('<span class="pill-stat danger" title="clean · 미머지 0 · 7일↑ 미활동 — 지워도 안전">삭제 권장</span>');
          if (wt.aheadTotal > 0) pills.push(`<span class="pill-stat warn" title="main 에 없는 커밋 — Remove 해도 브랜치는 보존">미머지 ${wt.aheadTotal}</span>`);
        }
        if (wt?.branches && Object.keys(wt.branches).length) {
          // 체크아웃 브랜치 — main 카드에 비-main 브랜치가 섞여 있으면 커밋이 거기로 들어가는 함정 신호.
          // 같은 브랜치는 그룹핑, main 카드의 main(기본 상태) 레포는 생략 — 전부 main 이면 칩 자체 생략 (무소음).
          // worktree 카드는 main 포함 전부 표시 (일부만 main 인 혼합 상태도 알아야 할 정보)
          const shortRepo = (name) => name;
          const fullMap = Object.entries(wt.branches).map(([repo, branch]) => `${shortRepo(repo)}=${branch}`).join(' · ');
          const offMain = session.source === 'main' && Object.values(wt.branches).some(branch => branch !== 'main');
          const grouped = {};
          for (const [repo, branch] of Object.entries(wt.branches)) {
            if (session.source === 'main' && branch === 'main') continue;
            (grouped[branch] ??= []).push(shortRepo(repo));
          }
          const parts = Object.entries(grouped).map(([branch, repos]) =>
            repos.length === Object.keys(wt.branches).length ? branch : `${branch} (${repos.join('·')})`);
          if (parts.length) {
            pills.push(`<span class="pill-stat pill-branch${offMain ? ' warn' : ''}" title="체크아웃 브랜치 — ${escapeHtml(fullMap)}${offMain ? ' · main 체크아웃에 비-main 브랜치가 섞여 있음: 여기서 커밋하면 그 브랜치로 들어간다' : ''}">⎇ ${escapeHtml(parts.join(' · '))}</span>`);
          }
        }
        if (session.webPortConflictWith?.length) {
          const conflictText = `⚠ 포트 충돌: ${session.webPortConflictWith.map(escapeHtml).join(', ')}`;
          if (session.source === 'main') {
            pills.push(`<span class="pill-stat danger" title="다른 세션이 main 기준 포트와 같은 포트를 쓰고 있어 — 해당 세션 카드의 충돌 칩으로 옮겨줘">${conflictText}</span>`);
          } else {
            pills.push(`<button class="pill-stat danger" data-fix-conflict title="설정/해시 파생 포트가 다른 세션과 동일 — 클릭하면 전 서비스 포트를 빈 오프셋으로 재배정 (cleanup 은 같은 해시 → 같은 포트라 못 풀어)">${conflictText} · 해결</button>`);
          }
        }
        card.className = `session ${isExpanded ? '' : 'collapsed'}`;
        card.dataset.root = session.root;
        card.innerHTML = `
          <div class="session-head">
            <div class="session-title">
              <div class="session-main">
                <div class="alias-row">
                  <span class="chev">${isExpanded ? '▾' : '▸'}</span>
                  <span class="alias-display" data-alias-display title="클릭해서 별칭 수정">${escapeHtml(session.alias || session.id)}</span>
                  <input class="alias-input" data-alias value="${escapeHtml(session.alias || '')}" placeholder="별칭" aria-label="session alias" title="별칭 — Enter 로 저장" hidden />
                  <span class="run-summary" data-run-summary>${runSummaryText(session)}</span>
                </div>
                ${session.alias ? `<div class="sid-sub">${escapeHtml(session.id)}</div>` : ''}
              </div>
              <div class="session-tools">
                ${wt && wt.cacheMb > 50 ? '<button data-clear-cache title="Clear cache — 빌드 캐시 전체 회수 (marina-services.json cachePaths). 카테고리별 회수는 캐시 칩 클릭">♻</button>' : ''}
                <button data-stop-all title="Stop all — 이 세션의 서비스 전부 정지">■</button>
                <button data-cleanup class="icon" title="Cleanup — 로그·pid·포트설정·alias 리셋 (코드는 무관)"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M19 20h-10.5l-4.21 -4.3a1 1 0 0 1 0 -1.41l10 -10a1 1 0 0 1 1.41 0l5 5a1 1 0 0 1 0 1.41l-9.2 9.3"/><path d="M18 13.3l-6.3 -6.3"/></svg></button>
                ${session.source === 'main' ? '' : '<button data-remove class="danger" title="Remove — worktree 삭제. 미머지 브랜치는 보존, 변경분은 confirm 후 폐기">✕</button>'}
              </div>
            </div>
            ${pills.length ? `<div class="stat-row">${pills.join('')}</div>` : ''}
            <div class="wt-changes" data-session-changes hidden></div>
            <div class="wt-changes" data-cache-details hidden></div>
            <div class="root" title="${escapeHtml(session.root)}">${escapeHtml(shortPath(session.root))}${wt && !wt.isMain ? ` <span class="root-meta">·${wt.diskMb != null ? ` ${(wt.diskMb / 1024).toFixed(1)}GB` : ''}${wt.idleDays != null ? ` · ${Math.round(wt.idleDays)}일 미활동` : ''}</span>` : ''}</div>
            ${renderConfigRows(session)}
          </div>
          <div class="svc-list"></div>
        `;
        card.querySelector('.session-head').onclick = (event) => {
          if (event.target.closest('button,input,select,summary,details,[data-changes-toggle],[data-alias-display],.wt-changes')) return;
          if (expandedRoots.has(session.root)) expandedRoots.delete(session.root);
          else expandedRoots.add(session.root);
          render();
        };
        const aliasInput = card.querySelector('[data-alias]');
        aliasInput.onkeydown = (event) => {
          if (event.key === 'Enter') {
            event.preventDefault();
            aliasInput.blur();
          }
        };
        const aliasDisplay = card.querySelector('[data-alias-display]');
        aliasDisplay.onclick = () => {
          aliasDisplay.hidden = true;
          aliasInput.hidden = false;
          aliasInput.focus();
          aliasInput.select();
        };
        aliasInput.onblur = () => {
          if ((session.alias || '') !== aliasInput.value.trim()) {
            saveAlias(session, aliasInput).catch(alert);
          } else {
            aliasInput.hidden = true;
            aliasDisplay.hidden = false;
          }
        };
        const details = card.querySelector('[data-config-details]');
        if (details) {
          details.open = openConfigRoots.has(session.root);
          details.ontoggle = () => {
            if (details.open) openConfigRoots.add(session.root);
            else openConfigRoots.delete(session.root);
          };
        }
        const toolButtons = card.querySelectorAll('.session-tools button');
        const saveBtn = card.querySelector('[data-save-config]');
        saveBtn.onclick = () => withBusy(saveBtn, 'Saving…', () => saveConfig(session.root, card, false));
        const saveRestartBtn = card.querySelector('[data-save-restart]');
        saveRestartBtn.onclick = () => withBusy(saveRestartBtn, 'Restarting…', () => saveConfig(session.root, card, true));
        const stopAllBtn = card.querySelector('[data-stop-all]');
        stopAllBtn.hidden = !session.services.some(svc => svc.running);   // 정지할 게 없으면 숨김 — 개별 서비스 버튼과 동일한 상태적응
        stopAllBtn.onclick = () => withBusy(stopAllBtn, '…', () => sessionAction('stop-all', session), toolButtons);
        const cleanupBtn = card.querySelector('[data-cleanup]');
        cleanupBtn.onclick = () => withBusy(cleanupBtn, '…', () => sessionAction('cleanup', session), toolButtons);
        const changesToggle = card.querySelector('[data-changes-toggle]');
        if (!session.worktreeStatus?.clean) {
          changesToggle.onclick = () => {
            (async () => {
              const area = card.querySelector('[data-session-changes]');
              if (!area.hidden) {
                area.hidden = true;
                changesToggle.textContent = `변경분 ${changeCount} ▾`;
                return;
              }
              const data = await api(`/api/worktree-changes?root=${enc(session.root)}`);
              area.textContent = (data.repos ?? []).filter(r => r.dirty).map(r => {
                const lines = (r.changes ?? []).join('\n');
                const more = r.changeCount > (r.changes ?? []).length ? `\n... +${r.changeCount - r.changes.length} more` : '';
                return `■ ${r.name} (${r.changeCount})\n${lines}${more}`;
              }).join('\n\n') || '(변경분 없음 — Refresh 해봐)';
              area.hidden = false;
              changesToggle.textContent = `변경분 ${changeCount} ▴`;
            })().catch(alert);
          };
        }
        const cacheToggle = card.querySelector('[data-cache-toggle]');
        if (cacheToggle) {
          cacheToggle.onclick = () => {
            const area = card.querySelector('[data-cache-details]');
            if (!area.hidden) {
              area.hidden = true;
              return;
            }
            renderCacheDetails(area, session, wtByRoot.get(session.root));
            area.hidden = false;
          };
        }
        const fixConflictBtn = card.querySelector('[data-fix-conflict]');
        if (fixConflictBtn) {
          fixConflictBtn.onclick = () => {
            if (!confirm(`${session.alias || session.id} 의 모든 서비스 포트를 빈 오프셋으로 재배정할까?\n(해시 오프셋이 다른 세션과 겹친 상태 — cleanup 으론 같은 해시라 다시 같은 포트가 나와)\n구동 중인 서비스는 Restart 해야 적용돼.`)) return;
            withBusy(fixConflictBtn, 'Moving…', async () => {
              const result = await api('/api/fix-port-conflict', {
                method: 'POST',
                headers: {'content-type': 'application/json'},
                body: JSON.stringify({root: session.root})
              });
              alert(`오프셋 ${result.movedToOffset} 로 이동 — web=${result.ports.web} · be=${result.ports.be}\n구동 중 서비스는 Restart 해야 새 포트로 떠.`);
              await load({force: true});
            });
          };
        }
        const clearCacheBtn = card.querySelector('[data-clear-cache]');
        if (clearCacheBtn) {
          clearCacheBtn.onclick = () => {
            const cacheGb = ((wtByRoot.get(session.root)?.cacheMb || 0) / 1024).toFixed(1);
            if (!confirm(`${session.alias || session.id} 의 빌드 캐시(${cacheGb}GB)를 비울까?\n다음 dev 시작 때 재생성돼. 서비스 구동 중이면 거부돼.`)) return;
            withBusy(clearCacheBtn, '…', async () => {
              const result = await api('/api/clear-cache', {
                method: 'POST',
                headers: {'content-type': 'application/json'},
                body: JSON.stringify({root: session.root})
              });
              alert(`캐시 ${((result.freedMb || 0) / 1024).toFixed(1)}GB 회수`);
              await loadWorktrees(true);
              await load({force: true});
            }, toolButtons);
          };
        }
        const removeBtn = card.querySelector('[data-remove]');
        if (removeBtn) {
          removeBtn.onclick = () => {
            const wtInfo = wtByRoot.get(session.root);
            if (wtInfo?.aheadTotal > 0 && !confirm(`미머지 커밋 ${wtInfo.aheadTotal}개가 있어. worktree 만 제거되고 브랜치는 보존돼 (미머지 브랜치는 -d 가 거부). 계속할까?`)) return;
            let force = false;
            if (!session.worktreeStatus?.clean) {
              if (!confirm(`${session.alias || session.id} 에 미커밋 변경분이 있어 (has local changes 클릭으로 확인).\n삭제하면 미커밋 변경·untracked 파일이 영구 폐기돼. 폐기하고 삭제할까?`)) return;
              force = true;
            }
            if (!confirm(`${session.alias || session.id} worktree 를 삭제할까?\n\n${session.root}`)) return;
            withBusy(removeBtn, '…', async () => {
              await api('/api/remove-worktree', {
                method: 'POST',
                headers: {'content-type': 'application/json'},
                body: JSON.stringify({root: session.root, force})
              });
              if (selected?.root === session.root) {
                selected = null;
                if (source) source.close();
                resetLogView('Select a service row.');
                updateOlderBar();
              }
              await load({force: true});
              await loadWorktrees(true);
            }, toolButtons);
          };
        }
        renderServiceTree(card.querySelector('.svc-list'), session, wt);
        sessionsEl.appendChild(card);
      }
      const collapseBtn = document.getElementById('collapseAll');
      collapseBtn.textContent = expandedRoots.size ? '⇈' : '⇊';
      collapseBtn.dataset.tip = expandedRoots.size ? '세션 카드 모두 접기' : '세션 카드 모두 펼치기';
      renderSelection();
    }

    function makeSvcRow(session, svc, disabled) {
      const row = document.createElement('div');
      row.className = 'svc nested' + (disabled ? ' disabled' : '');
      row.dataset.serviceKey = `${session.root}::${svc.service}`;
      const state = pillState(svc);
      row.title = disabled ? 'subrepo 미attach — attach 후 사용 가능' : '클릭하면 이 서비스의 로그를 우측에 표시';
      const src = svc.source === 'central'
        ? '<span class="svc-src central" title="내 로컬 override (~/.marina/services)">내 override</span>'
        : '<span class="svc-src root" title="팀 공유 (marina-services.json, repo)">팀</span>';
      row.innerHTML = `
        <div><div class="svc-name">${svc.service}${src}</div><div class="svc-port"><span data-port>${svc.port ?? '-'}</span><span data-rss>${svc.running && svc.rssMb ? ` · ${svc.rssMb}MB` : ''}</span></div></div>
        <div class="pill ${disabled ? 'stop' : state.cls}" data-state title="${escapeHtml(disabled ? 'subrepo 미attach' : state.title)}">${disabled ? '—' : state.text}</div>
        <div class="actions"></div>
      `;
      if (disabled) return row;
      row.onclick = () => selectLog(session.root, svc.service, 'current', 'service');
      const actions = row.querySelector('.actions');
      const busyLabels = {start: '…', stop: '…', restart: '…'};
      const actionTitles = {
        start: 'Start — 기동. 포트 점유 시 빈 포트로 자동 이동, 가용 메모리 부족 시 차단',
        stop: 'Stop — 프로세스 그룹 정지 (TERM→KILL)',
        restart: 'Restart — 정지 후 재기동',
      };
      for (const [label, type, cls] of [['▶', 'start', 'primary'], ['■', 'stop', 'danger'], ['↻', 'restart', '']]) {
        const btn = document.createElement('button');
        btn.textContent = label;
        btn.title = actionTitles[type];
        btn.dataset.act = type;
        if (cls) btn.className = cls;
        btn.hidden = type === 'start' ? svc.running : !svc.running;
        btn.onclick = (event) => {
          event.stopPropagation();
          withBusy(btn, busyLabels[type], () => action(type, session.root, svc.service), actions.querySelectorAll('button'));
        };
        actions.appendChild(btn);
      }
      // 편집·삭제 — 사용자 정의 서비스(def 있음)에만 표시
      if (svc.def) {
        const editBtn = document.createElement('button');
        editBtn.className = 'svc-edit-btn';
        editBtn.textContent = '✎';
        editBtn.title = '서비스 정의 편집';
        editBtn.onclick = (event) => { event.stopPropagation(); openServiceModal(session.root, svc.subrepo || '', svc); };
        actions.appendChild(editBtn);
        const delBtn = document.createElement('button');
        delBtn.className = 'svc-del-btn danger';
        delBtn.textContent = '✕';
        delBtn.title = '서비스 삭제';
        delBtn.onclick = (event) => { event.stopPropagation(); deleteSvc(session, svc); };
        actions.appendChild(delBtn);
      }
      return row;
    }

    function renderSubrepoHead(name, o) {
      const chev = o.count ? `<span class="chev">${o.open ? '▾' : '▸'}</span>` : '<span class="chev"></span>';
      // 아이콘 토글 — attached→unlink(=detach 동작), detached→link(=attach 동작). Tabler link/unlink (MIT). 상태는 행 흐림(.detached)+아이콘으로 구분, 별도 칩 없음
      const UNLINK_ICON = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M10 14a3.5 3.5 0 0 0 5 0l4 -4a3.5 3.5 0 0 0 -5 -5l-.5 .5"/><path d="M14 10a3.5 3.5 0 0 0 -5 0l-4 4a3.5 3.5 0 0 0 5 5l.5 -.5"/><path d="M16 21v-2"/><path d="M19 16h2"/><path d="M3 8h2"/><path d="M8 3v2"/></svg>';
      const LINK_ICON = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M9 15l6 -6"/><path d="M11 6l.463 -.536a5 5 0 0 1 7.071 7.072l-.534 .464"/><path d="M13 18l-.397 .534a5.068 5.068 0 0 1 -7.127 0a4.972 4.972 0 0 1 0 -7.071l.524 -.463"/></svg>';
      // 핀 토글 — main 카드의 "기본"(새 worktree 자동 attach 대상) 체크박스 대체. on 이면 채워진 파란 핀
      const PIN_ICON = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M9 4v6l-2 4v2h10v-2l-2 -4v-6"/><path d="M12 16l0 5"/><path d="M8 4l8 0"/></svg>';
      let control = '';
      if (!o.inUniverse) {
        control = '<span class="subrepo-chip warn" title="서비스 cwd 가 가리키는 subrepo 가 레지스트리에 없음 — ⚙ 에서 등록하면 attach 가능">미등록</span>';
      } else if (o.isMain) {
        control = `<button class="subrepo-act icon default-toggle ${o.isDefault ? 'on' : ''}" data-default-toggle aria-label="기본 attach 대상" title="기본 — 새 worktree 자동 attach 대상(전체 기본). 끄면 새 worktree 부터 제외 (main 의 클론은 보존)">${PIN_ICON}</button>`;
      } else if (o.isAttached) {
        control = `<button class="subrepo-act icon" data-detach aria-label="detach" title="이 worktree 에서 detach (git worktree remove) — 브랜치·미머지 커밋은 보존">${UNLINK_ICON}</button>`;
      } else {
        control = `<button class="subrepo-act icon primary" data-attach aria-label="attach" title="이 worktree 에 attach (git worktree add) — 같은 이름 브랜치 있으면 재사용">${LINK_ICON}</button>`;
      }
      // 서비스 추가 — 수동 폼(+) + LLM 위임(✨, 명령 복사). 아이콘은 link/unlink/pin 과 같은 subrepo-act icon 박스. Tabler plus / sparkles (MIT)
      const PLUS_ICON = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M12 5l0 14"/><path d="M5 12l14 0"/></svg>';
      const SPARKLE_ICON = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M16 18a2 2 0 0 1 2 2a2 2 0 0 1 2 -2a2 2 0 0 1 -2 -2a2 2 0 0 1 -2 2zm0 -12a2 2 0 0 1 2 2a2 2 0 0 1 2 -2a2 2 0 0 1 -2 -2a2 2 0 0 1 -2 2zm-7 12a6 6 0 0 1 6 -6a6 6 0 0 1 -6 -6a6 6 0 0 1 -6 6a6 6 0 0 1 6 6z"/></svg>';
      const addSvcBtn = o.inUniverse ? `<button class="subrepo-act icon" data-add-svc title="이 subrepo 에 서비스 추가 (수동 폼)" aria-label="서비스 추가">${PLUS_ICON}</button>` : '';
      const llmSvcBtn = o.inUniverse ? `<button class="subrepo-act icon" data-llm-svc title="LLM 으로 등록 — /marina:add-service 명령 복사" aria-label="LLM 으로 서비스 등록">${SPARKLE_ICON}</button>` : '';
      return `
        <div class="subrepo-main">
          ${chev}
          <span class="subrepo-name">${escapeHtml(name)}</span>
          ${o.count ? `<span class="subrepo-count">${o.count} svc</span>` : '<span class="subrepo-count muted">no svc</span>'}
        </div>
        <div class="subrepo-ctl">${control}${addSvcBtn}${llmSvcBtn}</div>
      `;
    }

    function renderServiceTree(list, session, wt) {
      list.innerHTML = '';
      const universe = wt?.subrepos ?? [];
      const isMain = !!wt?.isMain;
      const attached = new Set(wt?.attachedSubrepos ?? universe);
      const defaults = new Set(wt?.defaultAttach ?? universe);

      // 서비스 → subrepo 그룹핑 (svc.subrepo 태그). 빈 태그 = root cwd → ungrouped.
      const byGroup = new Map();
      const rootSvcs = [];
      for (const svc of session.services) {
        const g = svc.subrepo || '';
        if (!g) { rootSvcs.push(svc); continue; }
        if (!byGroup.has(g)) byGroup.set(g, []);
        byGroup.get(g).push(svc);
      }
      // 그룹 순서: universe 순서 + 서비스만 참조하는 미등록 그룹은 뒤에.
      const groups = [...universe];
      for (const g of byGroup.keys()) if (!groups.includes(g)) groups.push(g);

      // 1) 루트(cwd '.') 서비스 — 카드 상단 ungrouped.
      for (const svc of rootSvcs) list.appendChild(makeSvcRow(session, svc, false));

      // 2) subrepo ⊃ service.
      for (const name of groups) {
        const inUniverse = universe.includes(name);
        const isAttached = isMain || attached.has(name);
        const isDefault = defaults.has(name);
        const svcs = byGroup.get(name) ?? [];
        const key = `${session.root}::${name}`;
        const open = subrepoOpen.has(key) ? subrepoOpen.get(key) : isAttached;

        const head = document.createElement('div');
        head.className = 'subrepo-row' + (isAttached ? '' : ' detached');
        head.innerHTML = renderSubrepoHead(name, {isMain, isAttached, isDefault, inUniverse, open, count: svcs.length});
        list.appendChild(head);

        const body = document.createElement('div');
        body.className = 'subrepo-body';
        body.hidden = !open;
        for (const svc of svcs) body.appendChild(makeSvcRow(session, svc, !isAttached));
        list.appendChild(body);

        head.querySelector('.subrepo-main').onclick = () => {
          subrepoOpen.set(key, !open);
          render();
        };
        wireSubrepoToggle(head, session, wt, name, {isMain, isAttached, isDefault, inUniverse});
      }
    }

    function wireSubrepoToggle(head, session, wt, name, o) {
      if (o.isMain && o.inUniverse) {
        const cb = head.querySelector('[data-default-toggle]');
        if (cb) cb.onclick = (e) => { e.stopPropagation(); withBusy(cb, '…', () => setDefaultAttach(session, wt, name, !o.isDefault)); };
      }
      const attachBtn = head.querySelector('[data-attach]');
      if (attachBtn) attachBtn.onclick = (e) => { e.stopPropagation(); withBusy(attachBtn, '…', () => attachSubrepo(session, name)); };
      const detachBtn = head.querySelector('[data-detach]');
      if (detachBtn) detachBtn.onclick = (e) => { e.stopPropagation(); withBusy(detachBtn, '…', () => detachSubrepo(session, name)); };
      const addSvcBtn = head.querySelector('[data-add-svc]');
      if (addSvcBtn) addSvcBtn.onclick = (e) => { e.stopPropagation(); openServiceModal(session.root, name, null); };
      const llmSvcBtn = head.querySelector('[data-llm-svc]');
      if (llmSvcBtn) llmSvcBtn.onclick = async (e) => {
        e.stopPropagation();
        // 대시보드는 LLM 세션을 직접 호출 못함 → 명령을 클립보드에 넣고 세션에 붙여넣도록 안내. 클립보드 실패해도 alert 로 명령 노출(복사 폴백)
        const cmd = `/marina:add-service ${session.root}`;
        try { await navigator.clipboard.writeText(cmd); } catch {}
        alert(`복사됨:\n${cmd}\n\nClaude/Codex 세션에 붙여넣어 실행하세요. (구조를 분석해 서비스를 등록합니다)`);
      };
    }

    function configInput(session, key, fallback = '') {
      const value = session.config?.[key] ?? fallback;
      return `<input data-config-key="${escapeHtml(key)}" value="${escapeHtml(value)}" />`;
    }

    function renderConfigRows(session) {
      return `
        <details data-config-details>
          <summary title="세션별 포트·프로파일 설정 — 저장 후 (재)시작 시 적용">⚙ <span class="summary-sub">포트 · 프로파일</span></summary>
          <div class="config-label">포트·프로파일은 세션별 override (SERVICE_PORT_&lt;NAME&gt; / SERVICE_PROFILE_&lt;NAME&gt;) · 서비스 정의는 marina-services.json</div>
          <div class="config-services">
            <span class="config-head">서비스</span><span class="config-head">포트</span><span class="config-head">프로파일</span>
            ${session.services.map(svc => `
              <span class="config-name">${svc.service}</span>
              ${configInput(session, 'SERVICE_PORT_' + svc.service.toUpperCase(), svc.port ?? '')}
              ${configInput(session, 'SERVICE_PROFILE_' + svc.service.toUpperCase(), 'local')}
            `).join('')}
          </div>
          <div class="config-actions">
            <button data-save-config>Save</button>
            <button data-save-restart class="primary">Save + restart running</button>
          </div>
        </details>
      `;
    }

    async function load({force = false, passive = false} = {}) {
      const data = await api('/api/sessions');
      renderMemory(data.memory, data.sessions);
      const nextSessions = data.sessions;
      const nextSignature = buildSessionSignature(nextSessions);
      const sessionListChanged = nextSignature !== sessionSignature;
      sessions = nextSessions;
      sessionSignature = nextSignature;
      if (passive && !sessionListChanged) {
        updateServiceStates();
        return;
      }
      if (configDirty && !force) {
        updateServiceStates();
        return;
      }
      render();
      if (!selected) {
        const firstSession = sessions[0];
        const firstWeb = firstSession?.services.find(item => item.service === 'web') ?? firstSession?.services[0];
        if (firstSession && firstWeb) selectLog(firstSession.root, firstWeb.service, 'current', 'service');
      }
    }

    let updateBusy = false;
    async function loadUpdateStatus() {
      let s;
      try { s = await api('/api/update-status'); } catch { return; }
      renderUpdateBanner(s);
    }

    function renderUpdateBanner(s) {
      const el = document.getElementById('updateBanner');
      if (!s || s.state === 'current' || s.state === 'unknown') { el.hidden = true; el.innerHTML = ''; return; }
      el.hidden = false;
      el.classList.toggle('stale', s.state === 'stale');
      if (s.state === 'stale') {
        el.innerHTML = `<span class="ub-msg">업데이트 설치됨 — 재시작하면 적용</span>
          <span class="ub-sha">${escapeHtml(s.serving || '?')} → ${escapeHtml(s.installed || '?')}</span>
          <span class="ub-actions"><button data-restart class="primary">재시작</button></span>`;
      } else { // new — 하네스별 뒤처짐 칩 (정보) + 단일 [지금 받기] 버튼
        const hs = s.harnessStatus || {};
        const chips = [];
        for (const h of (s.harnesses || [])) {
          const st = hs[h];
          if (!st) continue;
          const cur = !st.behind;
          chips.push(`<span class="ub-hchip ${cur ? 'cur' : 'old'}">${escapeHtml(h)} <span class="sha">${escapeHtml(st.installed || '?')}</span> ${cur ? '최신' : '뒤처짐'}</span>`);
        }
        const anyBehind = (s.harnesses || []).some(h => hs[h]?.behind);
        const updateBtn = anyBehind ? '<button data-update-now class="primary">지금 받기</button>' : '';
        el.innerHTML = `<span class="ub-msg">새 버전 ${escapeHtml(s.origin || '?')}</span>
          <span class="ub-actions">${chips.join('')}${updateBtn}</span>`;
      }
      const restartBtn = el.querySelector('[data-restart]');
      if (restartBtn) restartBtn.onclick = () => doRestartDashboard(restartBtn);
      const updateNowBtn = el.querySelector('[data-update-now]');
      if (updateNowBtn) updateNowBtn.onclick = () => doUpdateNow(updateNowBtn);
    }

    async function doRestartDashboard(btn) {
      if (updateBusy) return;
      if (!confirm('대시보드를 재시작해 새 코드로 띄울까요?\n(dev 서버는 유지 · 브라우저 자동 새로고침 · 수 초)')) return;
      updateBusy = true;
      btn.disabled = true; btn.innerHTML = BUSY_DOTS;
      try {
        await api('/api/restart-dashboard', {method: 'POST', headers: {'content-type': 'application/json'}, body: '{}'});
      } catch {}
      // 서버만 재시작하면 브라우저는 옛 INDEX_HTML(HTML/JS/CSS) 그대로라 UI 변경이 안 보임 →
      // 데몬이 죽었다 다시 살아나는 걸 감지하면 페이지를 새로고침해 새 코드 전체 반영
      let down = false;
      for (let i = 0; i < 20; i++) {                 // 최대 ~8초
        await new Promise(r => setTimeout(r, 400));
        try {
          const ok = (await fetch('/api/update-status', {cache: 'no-store'})).ok;
          if (!ok) { down = true; continue; }        // 데몬 내려감 감지
          if (down) { location.reload(); return; }   // 죽었다 다시 살아남 → 새로고침
        } catch { down = true; }
      }
      location.reload();                             // fallback — transition 못 봐도 새로고침
    }

    async function doUpdateNow(btn) {
      if (updateBusy) return;
      if (!confirm('새 버전을 받아 대시보드만 재시작합니다.\n실행 중인 dev 서버(be/web 등)는 그대로 유지됩니다 · 약 1초.\n진행할까요?')) return;
      updateBusy = true;
      btn.disabled = true; btn.innerHTML = BUSY_DOTS;
      const errs = [];
      // 뒤처진 하네스만 업데이트
      let s;
      try { s = await api('/api/update-status'); } catch { s = null; }
      const hs = s?.harnessStatus || {};
      if (hs.claude?.behind) {
        try {
          const r = await api('/api/update-claude', {method: 'POST', headers: {'content-type': 'application/json'}, body: '{}'});
          if (r?.error) errs.push('claude: ' + r.error);
        } catch (e) { errs.push('claude: ' + e); }
      }
      if (hs.codex?.behind) {
        try {
          const r = await api('/api/update-codex', {method: 'POST', headers: {'content-type': 'application/json'}, body: '{}'});
          if (r?.error) errs.push('codex: ' + r.error);
        } catch (e) { errs.push('codex: ' + e); }
      }
      if (errs.length) {
        alert('업데이트 실패:\n' + errs.join('\n'));
        updateBusy = false; btn.disabled = false; btn.innerHTML = '지금 받기';
        return;
      }
      // 업데이트 성공 → 재시작 (confirm 이미 했으므로 바로 진행)
      try {
        await api('/api/restart-dashboard', {method: 'POST', headers: {'content-type': 'application/json'}, body: '{}'});
      } catch {}
      setTimeout(() => { updateBusy = false; loadUpdateStatus().catch(() => {}); }, 3000);
    }

    document.getElementById('orphanChip').onclick = () => {
      const panel = document.getElementById('orphanPanel');
      panel.hidden = !panel.hidden;
    };
    document.addEventListener('click', (event) => {
      const panel = document.getElementById('orphanPanel');
      if (panel.hidden) return;
      if (event.target.closest('#orphanPanel, #orphanChip')) return;
      panel.hidden = true;
    });

    const themeSelect = document.getElementById('themeSelect');
    const themeMedia = window.matchMedia('(prefers-color-scheme: dark)');
    function applyTheme() {
      const pref = localStorage.getItem('devSessionTheme') || 'system';
      themeSelect.value = pref;
      const dark = pref === 'dark' || (pref === 'system' && themeMedia.matches);
      document.documentElement.classList.toggle('dark', dark);
    }
    themeSelect.onchange = () => {
      localStorage.setItem('devSessionTheme', themeSelect.value);
      applyTheme();
    };
    themeMedia.addEventListener('change', applyTheme);
    applyTheme();

    document.getElementById('collapseAll').onclick = () => {
      if (expandedRoots.size) expandedRoots.clear();
      else for (const session of sessions) expandedRoots.add(session.root);
      render();
    };
    // 레일 띠 전체가 클릭 영역 (버튼은 pointer-events 없음 — 이중 토글 방지)
    document.querySelector('.rail').onclick = () => {
      const collapsed = document.querySelector('main').classList.toggle('aside-collapsed');
      document.getElementById('asideToggle').textContent = collapsed ? '▶' : '◀';
    };
    document.getElementById('logFilter').oninput = (event) => {
      logFilterText = event.target.value.trim().toLowerCase();
      applyLogFilter();
      scheduleMatchScan();  // 로드된 창은 즉시 거르고, 파일 전체 매치는 디바운스 스캔
    };
    document.getElementById('logErrOnly').onclick = () => {
      logErrorsOnly = !logErrorsOnly;
      document.getElementById('logErrOnly').classList.toggle('active', logErrorsOnly);
      applyLogFilter();
      fetchMatches().catch(console.error);
    };
    document.getElementById('logClear').onclick = () => resetLogView();
    // 무한 스크롤 — 상단 근접 시 과거 로드, (tail 분리 상태에서) 하단 근접 시 이후 로드
    let lastLogScrollTop = 0;
    document.getElementById('log').addEventListener('scroll', () => {
      if (!selected) return;
      const logEl = document.getElementById('log');
      // 방향 가드 — 아래로 내리는 중에 위 청크가 로드되는 오발 방지
      const goingUp = logEl.scrollTop < lastLogScrollTop;
      lastLogScrollTop = logEl.scrollTop;
      if (goingUp && logEl.scrollTop < 400) loadOlder();
      if (!goingUp && !logWindow.live && logEl.scrollHeight - logEl.scrollTop - logEl.clientHeight < 400) loadNewer();
    }, {passive: true});
    // 게이지 클릭 — 그 위치로 시크, 근처(±2%)에 매치 틱이 있으면 거기로 스냅
    document.getElementById('gaugeTrack').onclick = (event) => {
      if (!selected) return;
      const rect = event.currentTarget.getBoundingClientRect();
      const ratio = Math.min(Math.max((event.clientX - rect.left) / rect.width, 0), 1);
      const size = Math.max(logFileSize, logWindow.bottom, 1);
      let target = Math.round(ratio * size);
      let best = null;
      for (const offset of logMatches.offsets) {
        if (best == null || Math.abs(offset - target) < Math.abs(best - target)) best = offset;
      }
      if (matchView) {
        // 매치 뷰 — 게이지 클릭은 목록 안에서 그 위치의 매치로 스크롤 (필터 유지, 모드 이탈 없음)
        const entry = best != null ? logEntries.find(e => e.matchOffset === best) : null;
        if (entry) {
          followLog = false;
          document.getElementById('followLog').classList.remove('active');
          entry.el.scrollIntoView({block: 'center'});
          lastLogScrollTop = document.getElementById('log').scrollTop;
          entry.el.classList.add('jump-hit');
          setTimeout(() => entry.el.classList.remove('jump-hit'), 1500);
        }
        return;
      }
      if (best != null && Math.abs(best - target) / size < 0.02) target = best;
      jumpToOffset(target).catch(console.error);
    };
    document.getElementById('logDownload').onclick = () => {
      if (!selected) return;
      const actualService = selected.mode === 'console' ? 'console' : selected.service;
      window.open(`/api/logs/download?root=${enc(selected.root)}&service=${enc(actualService)}&run=${enc(selected.run)}`, '_blank');
    };

    document.getElementById('refresh').onclick = () => {
      configDirty = false;
      load({force: true}).catch(alert);
      loadOrphans().catch(console.error);
      loadWorktrees(true).catch(console.error); // du·ahead 강제 재계산 포함
    };
    document.getElementById('sessions').addEventListener('input', (event) => {
      if (event.target?.matches?.('[data-config-key]')) configDirty = true;
    });
    document.getElementById('runSelect').onchange = (event) => {
      if (!selected) return;
      selectLog(selected.root, selected.service, event.target.value, selected.mode);
    };
    document.getElementById('logModeTabs').onclick = (event) => {
      const mode = event.target?.dataset?.logMode;
      if (!mode || !selected) return;
      selectLog(selected.root, selected.service, 'current', mode);
    };
    document.getElementById('openWeb').onclick = () => {
      if (!selected) return;
      const {session} = serviceMeta(selected.root, selected.service);
      const web = session?.services.find(item => item.service === 'web');
      if (web?.port) window.open(`http://localhost:${web.port}/`, '_blank');
    };
    document.getElementById('followLog').onclick = () => {
      followLog = !followLog;
      document.getElementById('followLog').classList.toggle('active', followLog);
      if (followLog) {
        if (selected && !logWindow.live) {
          // 과거 탐색으로 tail 이 분리된 상태 — 최신부터 다시 연다
          selectLog(selected.root, selected.service, selected.run, selected.mode);
          return;
        }
        const log = document.getElementById('log');
        log.scrollTop = log.scrollHeight;
      }
    };
    document.getElementById('log').addEventListener('wheel', (event) => {
      // scrollTop 0 에선 위로 휠을 돌려도 scroll 이벤트가 없다 — 휠 방향으로 직접 과거 로드
      if (event.deltaY < 0 && document.getElementById('log').scrollTop < 400) loadOlder();
      if (!followLog) return;
      followLog = false;
      document.getElementById('followLog').classList.remove('active');
    }, {passive: true});

    // 즉시 툴팁 — 네이티브 title 의 ~1초 지연 제거. mouseover 위임이 title 을 data-tip 으로 흡수해
    // 동적 생성 노드(render 마다 새 카드)도 자동 적용. 80ms 만 기다려 스쳐 갈 때 번쩍임 방지.
    const tipEl = document.createElement('div');
    tipEl.id = 'tip';
    document.body.appendChild(tipEl);
    let tipTimer = 0;
    function hideTip() {
      clearTimeout(tipTimer);
      tipEl.classList.remove('on');
    }
    document.addEventListener('mouseover', (event) => {
      const target = event.target.closest?.('[title], [data-tip]');
      if (!target) return;
      if (target.title) {
        target.dataset.tip = target.title;
        target.removeAttribute('title');
      }
      const text = target.dataset.tip;
      if (!text) return;
      clearTimeout(tipTimer);
      tipTimer = setTimeout(() => {
        tipEl.textContent = text;
        const rect = target.getBoundingClientRect();
        tipEl.style.top = `${rect.bottom + 8}px`;
        tipEl.style.left = `${rect.left + rect.width / 2}px`;
        tipEl.classList.add('on');
        requestAnimationFrame(() => {
          const tipRect = tipEl.getBoundingClientRect();
          let shift = 0;
          if (tipRect.left < 4) shift = 4 - tipRect.left;
          else if (tipRect.right > innerWidth - 4) shift = (innerWidth - 4) - tipRect.right;
          if (shift) tipEl.style.left = `${rect.left + rect.width / 2 + shift}px`;
          if (tipRect.bottom > innerHeight - 4) tipEl.style.top = `${Math.max(4, rect.top - 8 - tipRect.height)}px`;
        });
      }, 80);
    });
    document.addEventListener('mouseout', (event) => {
      if (event.target.closest?.('[data-tip]')) hideTip();
    });
    document.addEventListener('scroll', hideTip, {capture: true, passive: true});
    document.addEventListener('click', hideTip, true);

    let pollTimer = null;
    let pollTick = 0;
    function startPolling() {
      if (pollTimer) return;
      pollTimer = setInterval(() => {
        pollTick += 1;
        load({passive: true}).catch(console.error);
        if (pollTick % 2 === 0) loadOrphans().catch(console.error);
        if (pollTick % 2 === 0) loadUpdateStatus().catch(console.error);
        // 60초마다 — 서버 10분 캐시를 타서 비용 ~0, 배지(삭제 권장)·디스크 표시 신선도 유지
        if (pollTick % 12 === 0) loadWorktrees().catch(console.error);
      }, 5000);
    }
    function stopPolling() {
      clearInterval(pollTimer);
      pollTimer = null;
    }
    // 탭이 안 보이면 폴링 정지 (백그라운드 탭 서버 부하 0), 복귀 시 즉시 1회 갱신 후 재개
    document.addEventListener('visibilitychange', () => {
      if (document.hidden) { stopPolling(); return; }
      load({passive: true}).catch(console.error);
      loadOrphans().catch(console.error);
      loadWorktrees().catch(console.error);
      loadUpdateStatus().catch(console.error);
      startPolling();
    });

    load().catch(alert);
    loadOrphans().catch(console.error);
    loadWorktrees().catch(console.error);
    loadUpdateStatus().catch(console.error);
    startPolling();
  </script>
</body>
</html>
"""

class Handler(BaseHTTPRequestHandler):
    def send_json(self, payload: Any, status: int = 200) -> None:
        data = json_bytes(payload)
        self.send_response(status)
        self.send_header("content-type", "application/json; charset=utf-8")
        origin = self.headers.get("origin")
        if origin and origin_allowed(origin, True):
            # localhost 웹앱(/api/console)만 CORS 응답 허용 — 구버전의 무차별 `*` 제거
            self.send_header("access-control-allow-origin", origin)
            self.send_header("vary", "origin")
        self.send_header("content-length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def read_json(self) -> dict[str, Any]:
        length = int(self.headers.get("content-length", "0"))
        raw = self.rfile.read(length) if length else b"{}"
        return json.loads(raw.decode("utf-8"))

    def do_GET(self) -> None:  # noqa: N802
        parsed = urllib.parse.urlparse(self.path)
        if parsed.path == "/":
            data = INDEX_HTML.encode("utf-8")
            self.send_response(200)
            self.send_header("content-type", "text/html; charset=utf-8")
            self.send_header("content-length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
            return

        if parsed.path.startswith("/api/") and not origin_allowed(self.headers.get("origin"), False):
            self.send_json({"error": "forbidden origin"}, 403)
            return

        if parsed.path == "/api/sessions":
            snapshot = process_snapshot()
            listeners = listener_map()
            sessions = [session_payload(root, snapshot, listeners) for root in discover_roots()]
            # 세션 간 web 포트 충돌(해시 오프셋 동일 or 오버라이드 중복) 표시
            by_web_port: dict[str, list[str]] = {}
            for item in sessions:
                port = item["ports"].get("web")
                if port:
                    by_web_port.setdefault(port, []).append(item["id"])
            for item in sessions:
                port = item["ports"].get("web")
                item["webPortConflictWith"] = [sid for sid in by_web_port.get(port, []) if sid != item["id"]]
            self.send_json({"sessions": sessions, "memory": system_memory()})
            return

        if parsed.path == "/api/orphans":
            self.send_json({"orphans": orphan_processes(), "memory": system_memory()})
            return

        if parsed.path == "/api/worktrees":
            query = urllib.parse.parse_qs(parsed.query)
            refresh = query.get("refresh", ["0"])[0] == "1"
            self.send_json({"worktrees": [worktree_info(root, refresh) for root in discover_all_roots(refresh)]})
            return

        if parsed.path == "/api/update-status":
            self.send_json(update_status())
            return

        if parsed.path == "/api/browse":
            query = urllib.parse.parse_qs(parsed.query)
            raw = query.get("path", [""])[0]
            try:
                base = (Path(raw).expanduser() if raw else Path.home()).resolve()
                if not base.is_dir():
                    raise ValueError(f"디렉토리 아님: {raw or '~'}")
                entries = []
                for child in sorted(base.iterdir(), key=lambda p: p.name.lower()):
                    if child.name.startswith("."):
                        continue
                    try:
                        if not child.is_dir():
                            continue
                    except OSError:
                        continue
                    entries.append({
                        "name": child.name,
                        "isDir": True,
                        "isGitRepo": (child / ".git").exists(),
                    })
                parent = str(base.parent) if base.parent != base else None
                self.send_json({"path": str(base), "parent": parent, "entries": entries})
            except Exception as exc:
                self.send_json({"error": str(exc)}, 400)
            return

        if parsed.path == "/api/worktree-changes":
            query = urllib.parse.parse_qs(parsed.query)
            try:
                root = safe_root(query.get("root", [""])[0])
            except Exception as exc:
                self.send_json({"error": str(exc)}, 400)
                return
            self.send_json({"repos": worktree_status(root)["repos"]})
            return

        if parsed.path in ("/api/logs", "/api/logs/chunk", "/api/logs/download", "/api/logs/matches"):
            query = urllib.parse.parse_qs(parsed.query)
            try:
                root = safe_root(query.get("root", [""])[0])
                service = safe_service(query.get("service", [""])[0], root)
                run = query.get("run", ["current"])[0]
            except Exception as exc:
                self.send_json({"error": str(exc)}, 400)
                return
            if parsed.path == "/api/logs/matches":
                try:
                    q = query.get("q", [""])[0]
                    err_only = query.get("errOnly", ["0"])[0] == "1"
                    if not q and not err_only:
                        self.send_json({"matches": [], "total": 0, "size": 0, "truncated": False})
                    else:
                        self.send_json(scan_log_matches(selected_log(root, service, run), q, err_only))
                except Exception as exc:
                    self.send_json({"error": str(exc)}, 400)
                return
            if parsed.path == "/api/logs/chunk":
                try:
                    after_raw = query.get("after", [None])[0]
                    if after_raw is not None:
                        result = read_log_chunk(selected_log(root, service, run), after=int(after_raw))
                    else:
                        before = int(query.get("before", ["0"])[0])
                        result = read_log_chunk(selected_log(root, service, run), before=before)
                    self.send_json(result)
                except Exception as exc:
                    self.send_json({"error": str(exc)}, 400)
                return
            if parsed.path == "/api/logs/download":
                try:
                    self.download_log(root, service, run)
                except Exception as exc:
                    self.send_json({"error": str(exc)}, 400)
                return
            from_raw = query.get("from", [None])[0]
            try:
                from_offset = int(from_raw) if from_raw is not None else None
            except ValueError:
                self.send_json({"error": "invalid from"}, 400)
                return
            self.stream_log(root, service, run, from_offset)
            return

        self.send_json({"error": "not found"}, 404)

    def do_POST(self) -> None:  # noqa: N802
        try:
            if not origin_allowed(self.headers.get("origin"), self.path == "/api/console"):
                self.send_json({"error": "forbidden origin"}, 403)
                return

            body = self.read_json()
            if self.path == "/api/console":
                self.send_json(append_console_log(body))
                return

            if self.path == "/api/kill-orphans":
                pids = body.get("pids")
                if not isinstance(pids, list) or not all(isinstance(p, int) for p in pids):
                    raise ValueError("pids must be a list of integers")
                self.send_json(kill_orphans(pids))
                return

            if self.path == "/api/infer-project":
                target = Path(str(body.get("path", "")).strip()).expanduser()
                if not str(body.get("path", "")).strip() or not target.is_dir():
                    raise ValueError(f"디렉토리 없음: {body.get('path', '')}")
                try:
                    out = run_marina_registry("project", "infer", str(target))
                except subprocess.CalledProcessError as exc:
                    raise ValueError((exc.output or "").strip() or str(exc))
                self.send_json(json.loads(out.strip().splitlines()[-1]))
                return

            if self.path == "/api/add-project":
                target = Path(str(body.get("path", "")).strip()).expanduser()
                if not str(body.get("path", "")).strip() or not target.is_dir():
                    raise ValueError(f"디렉토리 없음: {body.get('path', '')}")
                subrepos = body.get("subrepos", [])
                if not isinstance(subrepos, list) or not all(isinstance(s, str) for s in subrepos):
                    raise ValueError("subrepos must be a list of strings")
                try:
                    out = run_marina_registry("project", "add", str(target), "--subrepos", ",".join(subrepos))
                except subprocess.CalledProcessError as exc:
                    raise ValueError((exc.output or "").strip() or str(exc))
                invalidate_registry_caches()
                # id = realpath basename (registry_infer 와 동일) — 클라이언트가 새 프로젝트 선택에 사용
                self.send_json({"ok": True, "id": target.resolve().name, "output": out.strip()})
                return

            if self.path == "/api/remove-project":
                pid = str(body.get("id", "")).strip()
                if not pid:
                    raise ValueError("id required")
                try:
                    out = run_marina_registry("project", "rm", pid)
                except subprocess.CalledProcessError as exc:
                    raise ValueError((exc.output or "").strip() or str(exc))
                invalidate_registry_caches()
                self.send_json({"ok": True, "output": out.strip()})
                return

            if self.path == "/api/restart-dashboard":
                # 응답 먼저(연결 flush) → detached 로 재기동(자기 종료 후에도 살아남게 setsid).
                self.send_json({"ok": True, "restarting": True})
                try:
                    self.wfile.flush()   # 데몬 종료 전 응답이 클라이언트에 전달되도록 명시 flush
                except Exception:
                    pass
                dash = CONTROL_SCRIPT.parent / "marina-dashboard.sh"
                if os.environ.get("MARINA_RESTART_DRY_RUN") == "1":
                    MARINA_HOME.mkdir(parents=True, exist_ok=True)
                    with (MARINA_HOME / "restart-dry-run.log").open("a", encoding="utf-8") as fh:
                        fh.write(f"would run: bash {dash} restart\n")
                    return
                subprocess.Popen(
                    ["bash", "-c", f"sleep 1; exec bash {shlex.quote(str(dash))} restart"],
                    start_new_session=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                )
                return

            if self.path == "/api/update-claude":
                self.send_json(update_claude())
                return

            if self.path == "/api/update-codex":
                self.send_json(update_codex())
                return

            root = safe_root(str(body.get("root", "")))
            if self.path == "/api/config":
                config_body = body.get("config")
                if not isinstance(config_body, dict):
                    raise ValueError("config must be an object")
                result = write_config(root, {str(k): str(v) for k, v in config_body.items()})
                self.send_json({"config": result})
                return

            if self.path == "/api/meta":
                meta_body = body.get("meta")
                if not isinstance(meta_body, dict):
                    raise ValueError("meta must be an object")
                result = write_meta(root, {str(k): str(v) for k, v in meta_body.items()})
                self.send_json({"meta": result})
                return

            if self.path == "/api/stop-all":
                self.send_json(stop_all(root))
                return

            if self.path == "/api/cleanup":
                self.send_json(cleanup_session(root))
                return

            if self.path == "/api/remove-worktree":
                self.send_json(remove_worktree(root, force=bool(body.get("force"))))
                return

            if self.path == "/api/clear-cache":
                self.send_json(clear_worktree_cache(root, str(body.get("category", "all"))))
                return

            if self.path == "/api/fix-port-conflict":
                self.send_json(fix_port_conflict(root))
                return

            if self.path == "/api/set-default-attach":
                project = project_for(root)
                if not project:
                    raise ValueError("미등록 프로젝트")
                # main/project 카드 전용 — worktree 에서 호출 거부.
                if not (project["root"].resolve() == root.resolve() or is_source_checkout(root)):
                    raise ValueError("기본 attach 편집은 main 카드에서만 가능합니다")
                subs = body.get("subrepos")
                if not isinstance(subs, list) or not all(isinstance(s, str) for s in subs):
                    raise ValueError("subrepos must be a list of strings")
                universe = set(subrepos_of(root))
                bad = [s for s in subs if s not in universe]
                if bad:
                    raise ValueError(f"등록되지 않은 subrepo: {', '.join(bad)}")
                try:
                    out = run_marina_registry("project", "default", project["id"], ",".join(subs))
                except subprocess.CalledProcessError as exc:
                    raise ValueError((exc.output or "").strip() or str(exc))
                invalidate_registry_caches()
                self.send_json({"ok": True, "output": out.strip()})
                return

            if self.path in ("/api/add-service", "/api/remove-service"):
                project = project_for(root)
                if not project:
                    raise ValueError("미등록 프로젝트")
                central = bool(body.get("central", True))
                args = [] if central else ["--root"]
                if self.path == "/api/add-service":
                    svc = body.get("service")
                    if not isinstance(svc, dict):
                        raise ValueError("service must be an object")
                    try:
                        out = run_marina_registry("service", "add", project["id"], json.dumps(svc, ensure_ascii=False), *args)
                    except subprocess.CalledProcessError as exc:
                        raise ValueError((exc.output or "").strip() or str(exc))
                else:
                    name = str(body.get("name", "")).strip()
                    if not name:
                        raise ValueError("name required")
                    try:
                        out = run_marina_registry("service", "rm", project["id"], name, *args)
                    except subprocess.CalledProcessError as exc:
                        raise ValueError((exc.output or "").strip() or str(exc))
                invalidate_registry_caches()
                self.send_json({"ok": True, "output": out.strip()})
                return

            if self.path in ("/api/attach-subrepo", "/api/detach-subrepo"):
                subrepo = str(body.get("subrepo", "")).strip()
                if subrepo not in subrepos_of(root):
                    raise ValueError("등록되지 않은 subrepo")
                project = project_for(root)
                is_main_card = (project and project["root"].resolve() == root.resolve()) or is_source_checkout(root)
                if is_main_card:
                    raise ValueError("main 체크아웃은 물리 attach/detach 하지 않습니다 (기본 attach 편집만)")
                if self.path == "/api/attach-subrepo":
                    self.send_json(attach_subrepo_action(root, subrepo))
                else:
                    self.send_json(detach_subrepo_action(
                        root, subrepo,
                        force=bool(body.get("force")),
                        stop_services=bool(body.get("stopServices")),
                    ))
                return

            service = safe_service(str(body.get("service", "")), root)
            force = bool(body.get("force"))
            if self.path == "/api/start":
                result = start_service(root, service, force=force)
            elif self.path == "/api/stop":
                result = stop_service(root, service)
            elif self.path == "/api/restart":
                result = restart_service(root, service, force=force)
            else:
                self.send_json({"error": "not found"}, 404)
                return
            self.send_json(result)
        except Exception as exc:
            self.send_json({"error": str(exc)}, 400)

    def do_OPTIONS(self) -> None:  # noqa: N802
        origin = self.headers.get("origin")
        if not origin_allowed(origin, True):
            self.send_response(403)
            self.end_headers()
            return
        self.send_response(204)
        if origin:
            self.send_header("access-control-allow-origin", origin)
            self.send_header("vary", "origin")
        self.send_header("access-control-allow-methods", "GET, POST, OPTIONS")
        self.send_header("access-control-allow-headers", "content-type")
        self.end_headers()

    def stream_log(self, root: Path, service: str, run: str | None, from_offset: int | None = None) -> None:
        path = selected_log(root, service, run)
        path.parent.mkdir(parents=True, exist_ok=True)
        path.touch(exist_ok=True)

        self.send_response(200)
        self.send_header("content-type", "text/event-stream")
        self.send_header("cache-control", "no-cache")
        origin = self.headers.get("origin")
        if origin and origin_allowed(origin, True):
            self.send_header("access-control-allow-origin", origin)
            self.send_header("vary", "origin")
        self.end_headers()

        idle = 0.0
        with path.open("rb") as handle:
            size = path.stat().st_size
            if from_offset is not None:
                # 클라이언트가 forward 페이징으로 EOF 까지 따라온 뒤 갭 없이 이어받는 재연결 지점
                start = max(0, min(from_offset, size))
                handle.seek(start)
            else:
                start = max(size - LOG_TAIL_BYTES, 0)
                handle.seek(start)
                if start > 0:
                    handle.readline()  # 중간에서 잘린 첫 라인 정렬 — 버린 만큼은 chunk 페이징으로 조회
                    start = handle.tell()
            # 표시 시작 오프셋 + 파일 크기 — 클라이언트 표시 창(top) 초기값과 게이지 분모
            meta = json.dumps({"start": start, "size": size})
            try:
                self.wfile.write(f"event: meta\ndata: {meta}\n\n".encode("utf-8"))
                self.wfile.flush()
            except (BrokenPipeError, ConnectionResetError, OSError):
                return
            while True:
                line = handle.readline()
                if line:
                    idle = 0.0
                    text = line.decode("utf-8", errors="replace").rstrip("\r\n")
                    payload = json.dumps({"line": redact_text(text), "end": handle.tell()}, ensure_ascii=False)
                    try:
                        self.wfile.write(f"data: {payload}\n\n".encode("utf-8"))
                        self.wfile.flush()
                    except (BrokenPipeError, ConnectionResetError, OSError):
                        return
                else:
                    time.sleep(0.5)
                    idle += 0.5
                    if idle >= 10.0:
                        # 로그가 조용하면 write 가 없어 끊긴 클라이언트를 영영 감지 못했다
                        # → keepalive 로 연결 검증, 끊겼으면 스레드 종료 (스레드/fd 누수 방지)
                        idle = 0.0
                        try:
                            self.wfile.write(b": keepalive\n\n")
                            self.wfile.flush()
                        except (BrokenPipeError, ConnectionResetError, OSError):
                            return

    # 전체 로그 파일을 redact 하며 attachment 스트리밍 — 브라우저 DOM 을 거치지 않아 크기 무관
    def download_log(self, root: Path, service: str, run: str | None) -> None:
        path = selected_log(root, service, run)
        run_name = run if run and run != "current" else "current"
        # 세션 id 는 디렉토리명 유래 — 헤더 오염 방지로 안전 문자만
        filename = re.sub(
            r"[^A-Za-z0-9._-]", "_",
            f"marina-{session_id(root)}-{service}-{run_name.removesuffix('.log')}.log",
        )
        self.send_response(200)
        self.send_header("content-type", "text/plain; charset=utf-8")
        self.send_header("content-disposition", f'attachment; filename="{filename}"')
        origin = self.headers.get("origin")
        if origin and origin_allowed(origin, True):
            self.send_header("access-control-allow-origin", origin)
            self.send_header("vary", "origin")
        self.end_headers()
        try:
            with path.open("rb") as handle:
                for raw in handle:
                    text = raw.decode("utf-8", errors="replace").rstrip("\r\n")
                    self.wfile.write(redact_text(text).encode("utf-8") + b"\n")
        except (BrokenPipeError, ConnectionResetError, OSError):
            return

    def log_message(self, fmt: str, *args: Any) -> None:
        print("[marina]", fmt % args)


def main() -> None:
    server = ThreadingHTTPServer((HOST, PORT), Handler)
    print(f"marina: http://{HOST}:{PORT}")
    server.serve_forever()


if __name__ == "__main__":
    main()
