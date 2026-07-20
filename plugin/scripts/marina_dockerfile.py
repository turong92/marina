"""marina_dockerfile.py — marina-control.py 에서 분리(레이어드). 동작 변경 0."""
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

def _detect_injections(text: str) -> dict:
    """Dockerfile 텍스트 → '외부에서 넣어줘야 하는 것' 감지(portable·파싱만):
    args=ARG 선언(주입 가능 빌드인자), requiredArgs=가드(`[ -z "$X" ]`)로 필수, artifacts=COPY *.jar/war/ear(선빌드 필요),
    runtime=런타임 주입 힌트('런타임에 주입' 주석 등). 값·머신경로는 안 봄(선언만)."""
    if not text:
        return {"args": [], "requiredArgs": [], "artifacts": [], "runtime": []}
    args: list = []
    for m in re.finditer(r"^\s*ARG\s+([A-Za-z_]\w*)", text, re.M):
        if m.group(1) not in args:
            args.append(m.group(1))
    # 가드 탐지는 주석 줄 제외(코덱스 감사 #7: 주석 속 `-z "$X"` 오탐) + `${X:?}` shell guard 도 필수로 인정
    noncomment = "\n".join(ln for ln in text.splitlines() if not ln.lstrip().startswith("#"))
    required = [a for a in args
                if re.search(r"-z\s+\"?\$\{?" + re.escape(a) + r"\b", noncomment)
                or re.search(r"\$\{" + re.escape(a) + r"\s*:\?", noncomment)]
    artifacts = [ln.strip() for ln in text.splitlines()      # multistage 내부 산출물(COPY --from=…)은 선빌드 대상 아님 → 제외
                 if re.match(r"\s*COPY\s", ln) and re.search(r"\.(jar|war|ear)\b", ln)
                 and not re.search(r"--from=", ln)]
    runtime = [ln.strip() for ln in text.splitlines()
               if re.search(r"런타임에?\s*주입", ln)
               or (ln.lstrip().startswith("#") and re.search(r"\bAWS_|credential|secret", ln, re.I))][:5]
    return {"args": args, "requiredArgs": required, "artifacts": artifacts, "runtime": runtime}

_INSTALL_PATTERNS = (
    r"\bnpm\s+(?:ci|install)\b",
    r"\bpnpm\s+install\b",
    r"\byarn\s+(?:install|add)\b",
    r"\bpip3?\s+install\b",
    r"\bpoetry\s+install\b",
    r"\bbundle\s+install\b",
    r"\bgo\s+mod\s+download\b",
    r"\bmvn\s+(?:dependency:go-offline|package|install)\b",
    r"\bgradle(?:w)?\s+.*\b(?:build|assemble)\b",
)
_INSTALL_RE = re.compile("|".join(f"(?:{p})" for p in _INSTALL_PATTERNS), re.I)
_HEAVY_DEP_RE = re.compile(
    r"\b(playwright|chromium|chrome|ffmpeg|torch|tensorflow|opencv(?:-python)?|scikit-learn)\b",
    re.I,
)

def _logical_dockerfile_lines(text: str) -> list[tuple[int, str]]:
    lines: list[tuple[int, str]] = []
    pending = ""
    start = 0
    for idx, raw in enumerate((text or "").splitlines(), 1):
        stripped = raw.strip()
        if not stripped or stripped.startswith("#"):
            continue
        if not pending:
            start = idx
        pending += (" " if pending else "") + stripped.rstrip("\\").strip()
        if stripped.endswith("\\"):
            continue
        lines.append((start, pending))
        pending = ""
    if pending:
        lines.append((start, pending))
    return lines

def _docker_instruction(line: str) -> tuple[str, str]:
    match = re.match(r"^\s*([A-Za-z]+)\s+(.*)$", line)
    return (match.group(1).upper(), match.group(2).strip()) if match else ("", "")

def _copy_sources(args: str) -> list[str]:
    text = re.sub(r"--[A-Za-z0-9_-]+(?:=(?:\"[^\"]+\"|'[^']+'|\S+))?", "", args).strip()
    if text.startswith("["):
        try:
            value = json.loads(text)
            return [str(item) for item in value[:-1]] if isinstance(value, list) and len(value) >= 2 else []
        except json.JSONDecodeError:
            return []
    try:
        parts = shlex.split(text)
    except ValueError:
        parts = text.split()
    return parts[:-1] if len(parts) >= 2 else []

def _is_broad_copy(args: str) -> bool:
    return any(src.strip().rstrip("/") in (".", "./") for src in _copy_sources(args))

def dockerfile_doctor(text: str) -> list[dict[str, Any]]:
    """Dockerfile cache hygiene 진단. 읽기 전용 lint라 프로젝트별 schema 없이 재사용 가능하다."""
    findings: list[dict[str, Any]] = []
    broad_copy_line: int | None = None
    for line_no, line in _logical_dockerfile_lines(text):
        inst, args = _docker_instruction(line)
        if inst in ("COPY", "ADD") and "--from=" not in args.lower() and _is_broad_copy(args):
            broad_copy_line = broad_copy_line or line_no
        if inst != "RUN":
            continue
        is_install = bool(_INSTALL_RE.search(args))
        if broad_copy_line and is_install:
            findings.append({
                "code": "copy-before-install",
                "severity": "high",
                "line": line_no,
                "title": "source COPY 뒤 dependency install",
                "detail": "manifest 파일만 먼저 COPY하고 install한 뒤 source COPY를 뒤로 옮기면 소스 수정이 dependency layer를 깨지 않습니다.",
            })
        if is_install and "--mount=type=cache" not in args:
            findings.append({
                "code": "missing-cache-mount",
                "severity": "medium",
                "line": line_no,
                "title": "dependency install cache mount 없음",
                "detail": "BuildKit cache mount를 쓰면 같은 dependency 입력에서 package manager 다운로드 캐시를 재사용할 수 있습니다.",
            })
        if re.search(r"\bapt-get\s+(?:update|install)\b", args) and "/var/lib/apt/lists" not in args and "apt-get clean" not in args:
            findings.append({
                "code": "apt-cache-not-cleaned",
                "severity": "medium",
                "line": line_no,
                "title": "apt cache 정리 없음",
                "detail": "apt-get install과 같은 RUN에서 /var/lib/apt/lists를 지우면 불필요한 image layer 증가를 줄일 수 있습니다.",
            })
        heavy = sorted({match.group(1).lower() for match in _HEAVY_DEP_RE.finditer(args)})
        if heavy:
            findings.append({
                "code": "heavy-dependency",
                "severity": "info",
                "line": line_no,
                "title": "무거운 의존성 항상 설치",
                "detail": f"{', '.join(heavy)} 설치가 항상 실행됩니다. 빌드가 느리면 프로젝트 Dockerfile에서 stage/build arg로 분리할 후보입니다.",
            })
    return findings

# profile(환경 선택) 변수 후보 — 우선순위 순. 프레임워크 표준 + mdc 관용(PROFILE).
# marina 는 이 중 그 서비스 Dockerfile 이 실제 선언한 ARG 를 profile 변수로 본다(추측 아님).
PROFILE_VAR_CANDIDATES = [
    "PROFILE", "SPRING_PROFILES_ACTIVE", "APP_ENV", "ASPNETCORE_ENVIRONMENT",
    "RAILS_ENV", "ENVIRONMENT", "STAGE", "ENV", "NODE_ENV",
]
_PROFILE_SET = {c.upper() for c in PROFILE_VAR_CANDIDATES}

def is_profile_var(name) -> bool:
    return bool(name) and str(name).upper() in _PROFILE_SET

def detect_profile_var(args):
    """ARG 이름 목록 → profile 변수(후보 우선순위 첫 매칭) 또는 None."""
    up = {str(a).upper(): a for a in (args or [])}
    for c in PROFILE_VAR_CANDIDATES:
        if c.upper() in up:
            return up[c.upper()]
    return None

def _prebuild_suggest(d: Path) -> str:
    """서브레포 빌드 도구 감지 → pre-build 명령 제안(portable·상대). gradlew/pom/package.json. 없으면 ""."""
    try:
        if (d / "gradlew").is_file():
            return "./gradlew assemble"   # build 아님 — 테스트/검증 제외, 아티팩트(jar)만 → 테스트 실패와 무관
        if (d / "pom.xml").is_file():
            return "mvn -q -DskipTests package"
        if (d / "package.json").is_file():
            pj = (d / "package.json").read_text(encoding="utf-8", errors="replace")
            return "pnpm install && pnpm turbo build" if "turbo" in pj else "pnpm install && pnpm build"
    except OSError:
        pass
    return ""

def _workdir_from_dockerfile(text: str) -> str:
    """Dockerfile 의 마지막 WORKDIR(런타임 작업 디렉터리) — 마운트 dest 자동제안용. 없으면 ""."""
    ws = re.findall(r"^\s*WORKDIR\s+(\S+)", text or "", re.M)
    return ws[-1].strip().rstrip("/") if ws else ""

def _find_config_files(d: Path) -> list:
    """런타임 설정 후보 — application*.y*ml / *.properties / .env*. 흔한 위치만 glob(전체 walk 안 함=대형 모노레포서도 빠름).
    (서브레포 찾기처럼, 마운트할 파일을 사람이 안 뒤지게 marina 가 찾아줌)."""
    locs = [d, d / "config", d / "src" / "main" / "resources", d / "src" / "main" / "resources" / "config"]
    pats = ("application*.yml", "application*.yaml", "application*.properties", ".env*", "*.env")
    out = set()
    for loc in locs:
        for pat in pats:
            try:
                for p in loc.glob(pat):
                    if p.is_file():
                        out.add(str(p.relative_to(d)))
            except OSError:
                pass
    return sorted(out)[:40]

def _is_dockerfile_name(name: str) -> bool:
    """Dockerfile 이름 규칙(대소문자 무관): dockerfile / dockerfile.<x> / <x>.dockerfile.
    'DockerFile'(대문자 F) 같은 변형은 잡고, 'Dockerfile_Backup_250908' 류는 제외(macOS 케이스무시 FS 대응)."""
    n = name.lower()
    return n == "dockerfile" or n.startswith("dockerfile.") or n.endswith(".dockerfile")

def _subrepo_compose(d: Path) -> str:
    """서브레포 루트의 compose 파일명(있으면) — docker-compose.yml/yaml, compose.yml/yaml 순. 없으면 ""."""
    for n in ("docker-compose.yml", "docker-compose.yaml", "compose.yml", "compose.yaml"):
        try:
            if (d / n).is_file():
                return n
        except OSError:
            pass
    return ""

def _detect_subrepos(target: Path) -> list:
    """등록 전 서브레포/서비스 후보 감지 — 1단계 하위에서 .git(독립 클론)·Dockerfile·compose 중 하나라도 있는 폴더."""
    out = []
    try:   # 단일레포/루트: 루트 자체에 Dockerfile/compose 면 '.'(루트) 도 후보 — 서브레포 없는 프로젝트도 등록 가능
        root_df = any(p.is_file() and _is_dockerfile_name(p.name) for p in target.iterdir())
    except OSError:
        root_df = False
    if root_df or _subrepo_compose(target):
        out.append(".")
    try:
        for d in sorted(target.iterdir()):
            if not d.is_dir() or d.name.startswith(".") or d.name in ("node_modules", ".workspace"):
                continue
            has_df = False
            try:
                has_df = any(p.is_file() and _is_dockerfile_name(p.name) for p in d.iterdir())
            except OSError:
                pass
            if (d / ".git").is_dir() or has_df or _subrepo_compose(d):
                out.append(d.name)
    except OSError:
        pass
    return out

def _list_dockerfiles(repo: Path) -> list:
    """레포 안 Dockerfile 들의 상대경로(루트 우선, 그다음 정렬). 대소문자 무관(DockerFile 등),
    node_modules/.git·백업류(Dockerfile_Backup…) 제외 — 이름 규칙은 _is_dockerfile_name."""
    found = []
    try:
        for p in repo.rglob("*"):
            if not p.is_file() or not _is_dockerfile_name(p.name):
                continue
            if "node_modules" in p.parts or ".git" in p.parts:
                continue
            found.append(str(p.relative_to(repo)))
    except OSError:
        pass
    root = sorted(f for f in found if "/" not in f)       # 루트 Dockerfile(케이싱 무관) 우선
    rest = sorted(f for f in found if "/" in f)
    return [*root, *rest]

def _dockerfile_expose(path: Path):
    """Dockerfile 의 첫 EXPOSE 포트(숫자 문자열). 없으면 None."""
    try:
        for ln in path.read_text(errors="replace").splitlines():
            m = re.match(r"\s*EXPOSE\s+(\d{2,5})", ln, re.I)
            if m:
                return m.group(1)
    except OSError:
        pass
    return None

def _compose_scaffold_service(target: Path, subrepo: str, dockerfile: str = "",
                              build_context: str = "") -> str:
    """무-LLM 스캐폴드: **Dockerfile 한 개 = 서비스 한 개**. 서브레포가 자체 서브레포 N개를 품으면
    각 Dockerfile 마다 호출 → 각각 서비스. 이름·컨텍스트는 그 Dockerfile 의 디렉터리 기준(자체 서브레포).
    build_context 주면 그 베이스(외부=.workspace/external/<name> 마운트), 아니면 ./<subrepo>(내부)."""
    raw = (subrepo or "").strip().strip("/")
    is_root = raw in ("", ".")                                       # 단일레포/루트 서비스
    ctx_base = build_context.strip() or ("." if is_root else f"./{raw}")
    scan_dir = target if is_root else (target / raw)
    if dockerfile.strip():
        df_rel = dockerfile.strip()
    else:   # 루트 Dockerfile(케이싱 무관) 자동 — 얕게만 스캔
        try:
            _roots = sorted(p.name for p in scan_dir.iterdir()
                            if p.is_file() and _is_dockerfile_name(p.name))
        except OSError:
            _roots = []
        df_rel = _roots[0] if _roots else ""
    subpath = df_rel.rsplit("/", 1)[0] if "/" in df_rel else ""      # 중첩: "index_api" / 루트: ""
    df_name = df_rel.rsplit("/", 1)[-1] if df_rel else ""            # "Dockerfile" / "Dockerfile.api"
    base = (subpath.rsplit("/", 1)[-1] if subpath
            else (target.name if is_root else raw.rsplit("/", 1)[-1]))   # 루트면 프로젝트명
    name = re.sub(r"[^a-z0-9_-]+", "-", base.lower()).strip("-_") or "app"
    ctx = ctx_base + ("/" + subpath if subpath else "")              # 컨텍스트 = Dockerfile 의 디렉터리(루트면 ".")
    port = _dockerfile_expose(scan_dir / df_rel) if df_rel else None
    try:
        _df_text = (scan_dir / df_rel).read_text(encoding="utf-8", errors="replace") if df_rel else ""
    except OSError:
        _df_text = ""
    required = _detect_injections(_df_text)["requiredArgs"] if _df_text else []
    lines = [f"  {name}:"]
    if (not df_rel or df_name == "Dockerfile") and not required:
        lines.append(f"    build: {ctx}")
    else:
        lines += ["    build:", f"      context: {ctx}"]
        if df_rel and df_name != "Dockerfile":
            lines.append(f"      dockerfile: {df_name}")
        if required:                                             # 필수 ARG 는 build.args 로 — environment 는 런타임이라 빌드에 전달 안 됨(코덱스 P2)
            lines.append("      args:")
            lines += [f'        {k}: "???"          # 필수 빌드 인자 — 값 채우기' for k in required]
    if port:
        lines += [f'    expose: ["{port}"]          # 컨테이너 간 DNS — 다른 서비스가 http://{name}:{port} 로 호출',
                  f'    # ports: ["{port}:{port}"]   # 호스트에서 직접 열 때만 (marina 가 포트 자동 격리)']
    return "\n".join(lines) + "\n"

def _compose_scan(root: Path) -> dict:
    """비-LLM 스캔 — 서브레포(루트 '.' 포함)별 Dockerfile 감지 + 주입 필요 항목(ARG·필수ARG·아티팩트·
    런타임힌트)·EXPOSE·설정후보(상대경로). LLM 안 씀(제거된 LLM compose 보조의 스캔 부분만 부활). 위저드 스텝1 입력.
    헬퍼(_list_dockerfiles·_dockerfile_expose·_detect_injections·_find_config_files) 재사용."""
    out = []
    for sub in _detect_subrepos(root):
        base = root if sub in (".", "") else (root / sub)
        cfgs = []
        for c in _find_config_files(base)[:5]:               # 설정후보(application*.yml·.env*) — root 상대 경로로 정규화
            try:
                cfgs.append(str((base / c).relative_to(root)))
            except ValueError:
                cfgs.append(os.path.basename(str(c)))
        dfs = []
        for df in _list_dockerfiles(base):
            dfp = base / df
            inj = (_detect_injections(dfp.read_text(errors="replace")) if dfp.is_file()
                   else {"args": [], "requiredArgs": [], "artifacts": [], "runtime": []})
            dfs.append({"dockerfile": df, "expose": _dockerfile_expose(dfp),
                        "args": inj["args"], "requiredArgs": inj["requiredArgs"],
                        "artifacts": inj["artifacts"], "runtime": inj["runtime"],
                        "configCandidates": cfgs})
        out.append({"subrepo": sub, "dockerfiles": dfs})
    return {"projectName": root.name, "subrepos": out}
