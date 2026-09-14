"""marina_docker_gc.py — 워크트리에 묶이지 않는 도커 산출물의 주기 정리.

**왜 여기서.** 빌드캐시·dangling 이미지·익명 볼륨·e2e 잔재는 누가 만들었든 아무도 회수하지 않았다
(2026-09-14 실측: 7일 넘은 빌드캐시 21GB, e2e 이미지 383개, 익명 볼륨 319개). 형: "밖에서 cron 거는 건
의미 없다, marina 에서 컨트롤돼야 한다" — 정책도 실행도 marina 가 쥔다.

**범위 밖.** 워크트리 소유 이미지(remove_worktree → clear_worktree_images, marina_lifecycle) 는 여기서
다루지 않는다. 명명 볼륨(사용자 데이터일 수 있다)과 사용 중인 어떤 것도.

**구조.** 도커 호출은 전부 `run(args) -> str` 하나를 통해 나간다 — 테스트는 가짜 run 을 주입해 명령·순서·
판정을 검증하고, 실 도커를 만지는 테스트는 dry-run 경로만 탄다.
설계: docs/superpowers/specs/2026-09-14-docker-gc-policy-design.md
"""
from __future__ import annotations

import fnmatch
import json
import os
import re
import subprocess
import tempfile
import threading
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable

from marina_state import MARINA_HOME, _bin

POLICY_FILE = MARINA_HOME / "docker-gc.json"
STATE_FILE = MARINA_HOME / "docker-gc-state.json"
LOG_FILE = MARINA_HOME / "docker-gc.log"

E2E_LABEL = "marina.e2e"          # 테스트 하네스가 e2e 산출물에 붙이는 라벨(값 "1")

DEFAULT_POLICY: dict[str, Any] = {
    "enabled": True,
    "interval_hours": 24,
    "build_cache_keep_days": 7,
    "dangling_images": True,
    "anonymous_volumes": True,
    "stale_test_artifacts_days": 3,
    "stale_test_artifact_names": ["marina-*-e2e-*"],
}
_POLICY_TYPES: dict[str, str] = {
    "enabled": "bool",
    "interval_hours": "int",
    "build_cache_keep_days": "int",
    "dangling_images": "bool",
    "anonymous_volumes": "bool",
    "stale_test_artifacts_days": "int",
    "stale_test_artifact_names": "globs",
}

_TRUE = {"1", "true", "yes", "on", "y"}
_FALSE = {"0", "false", "no", "off", "n"}


# ─────────────────────────── 정책 ───────────────────────────

def _coerce(key: str, value: Any) -> Any:
    """CLI·API 가 주는 문자열도 받아 정책 타입으로. 틀리면 ValueError(메시지에 키)."""
    kind = _POLICY_TYPES.get(key)
    if kind is None:
        raise ValueError(f"모르는 정책 키: {key} (가능: {', '.join(_POLICY_TYPES)})")
    if kind == "bool":
        if isinstance(value, bool):
            return value
        s = str(value).strip().lower()
        if s in _TRUE:
            return True
        if s in _FALSE:
            return False
        raise ValueError(f"{key}: true/false 여야 합니다 (받은 값: {value!r})")
    if kind == "int":
        if isinstance(value, bool) or not isinstance(value, (int, str, float)):
            raise ValueError(f"{key}: 0 이상의 정수여야 합니다 (받은 값: {value!r})")
        try:
            n = int(str(value).strip())
        except ValueError:
            raise ValueError(f"{key}: 0 이상의 정수여야 합니다 (받은 값: {value!r})") from None
        if n < 0:
            raise ValueError(f"{key}: 0 이상의 정수여야 합니다 (받은 값: {value!r})")
        return n
    # globs — 목록 또는 쉼표 구분 문자열. 빈 목록은 "아무 이름도 안 잡음" 이라 허용하지 않는다(라벨은 여전히 잡힘이지만
    # 실수로 비우는 걸 막는다; 끄려면 stale_test_artifacts_days=0).
    items = value if isinstance(value, (list, tuple)) else str(value).split(",")
    globs = [str(x).strip() for x in items if str(x).strip()]
    if not globs:
        raise ValueError(f"{key}: 글롭을 하나 이상 주세요 (예: 'marina-*-e2e-*,mdce2e*')")
    return globs


def load_policy() -> dict[str, Any]:
    """정책 파일 + 기본값. 없음/깨짐/모르는 키/틀린 타입은 그 키만 기본값으로 두고 `warnings` 에 적는다."""
    policy = {k: (list(v) if isinstance(v, list) else v) for k, v in DEFAULT_POLICY.items()}
    warnings: list[str] = []
    raw: Any = None
    if POLICY_FILE.exists():
        try:
            raw = json.loads(POLICY_FILE.read_text(encoding="utf-8"))
        except Exception as exc:
            warnings.append(f"정책 파일을 읽지 못해 기본값을 씁니다: {exc}")
            raw = None
        if raw is not None and not isinstance(raw, dict):
            warnings.append("정책 파일이 객체가 아니라 기본값을 씁니다")
            raw = None
    for key, value in (raw or {}).items():
        try:
            policy[key] = _coerce(key, value)
        except ValueError as exc:
            warnings.append(f"{exc} → 기본값")
    policy["warnings"] = warnings
    return policy


def _atomic_write_json(path: Path, data: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=str(path.parent), prefix="." + path.name + ".")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(data, f, ensure_ascii=False, indent=2)
            f.write("\n")
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, path)
    except BaseException:
        Path(tmp).unlink(missing_ok=True)
        raise


def set_policy(key: str, value: Any) -> dict[str, Any]:
    """한 키를 검증해 바꾸고 원자적으로 쓴다. 틀리면 ValueError 이고 파일은 안 건드린다."""
    coerced = _coerce(key, value)          # 파일 읽기 전에 검증 — 실패해도 파일 무변경
    current = load_policy()
    data = {k: current[k] for k in DEFAULT_POLICY}
    data[key] = coerced
    _atomic_write_json(POLICY_FILE, data)
    return load_policy()


# ─────────────────────────── 상태·주기 ───────────────────────────

def load_state() -> dict[str, Any]:
    try:
        data = json.loads(STATE_FILE.read_text(encoding="utf-8"))
        return data if isinstance(data, dict) else {}
    except Exception:
        return {}


def next_run_at(policy: dict[str, Any], state: dict[str, Any]) -> float | None:
    """마지막 실행(성공·실패 무관) + interval. 기록이 없으면 None(= 지금)."""
    last = state.get("finishedAt")
    if not isinstance(last, (int, float)):
        return None
    return float(last) + float(policy.get("interval_hours", DEFAULT_POLICY["interval_hours"])) * 3600.0


def due(policy: dict[str, Any], state: dict[str, Any], now: float | None = None) -> bool:
    if not policy.get("enabled", True):
        return False
    now = time.time() if now is None else now
    nxt = next_run_at(policy, state)
    return nxt is None or now >= nxt


# ─────────────────────────── 도커 호출·파싱 ───────────────────────────

Runner = Callable[[list[str]], str]


def _docker_run(args: list[str], timeout: float = 600) -> str:
    """실 도커. 실패는 RuntimeError(출력 꼬리 포함) — 단계별로 잡혀 다음 단계로 간다."""
    try:
        return subprocess.check_output([_bin("docker"), *args], text=True, stderr=subprocess.STDOUT, timeout=timeout)
    except subprocess.CalledProcessError as exc:
        tail = "\n".join((exc.output or "").strip().splitlines()[-3:])
        raise RuntimeError(f"docker {' '.join(args[:3])}: {tail or 'exit ' + str(exc.returncode)}") from None
    except subprocess.TimeoutExpired:
        raise RuntimeError(f"docker {' '.join(args[:3])}: {timeout:.0f}s 안에 안 끝남") from None
    except OSError as exc:
        raise RuntimeError(f"docker 실행 불가: {exc}") from None


_TIME_RE = re.compile(r"^(\d{4}-\d\d-\d\d)[ T](\d\d:\d\d:\d\d)(?:\.\d+)?\s*(Z|[+-]\d\d:?\d\d)?")


def parse_docker_time(value: Any) -> float | None:
    """docker 목록("2026-09-14 11:36:49 +0900 KST")·inspect("…T02:36:49.729Z") 시각 → epoch. 못 읽으면 None."""
    m = _TIME_RE.match(str(value or "").strip())
    if not m:
        return None
    date, clock, tz = m.groups()
    tz = "+00:00" if not tz or tz == "Z" else (tz if ":" in tz else tz[:3] + ":" + tz[3:])
    try:
        return datetime.fromisoformat(f"{date}T{clock}{tz}").timestamp()
    except ValueError:
        return None


def _size_mb(value: Any) -> int:
    from marina_cache import _parse_size_mb
    return _parse_size_mb(value)


def parse_reclaimed_mb(text: str) -> int | None:
    """prune 계열 출력의 `Total reclaimed space: 2.5GB` → MB. 없으면 None(예상치를 쓴다)."""
    m = re.search(r"Total reclaimed space:\s*([0-9.]+\s*[KMGT]?i?B)", text or "", re.IGNORECASE)
    return _size_mb(m.group(1).replace(" ", "")) if m else None


def fmt_mb(mb: int | float) -> str:
    mb = max(0, int(mb or 0))
    if mb == 0:
        return "0B"
    return f"{mb / 1024:.1f}GB" if mb >= 1024 else f"{mb}MB"


def _ndjson(text: str) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    for line in (text or "").splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            doc = json.loads(line)
        except json.JSONDecodeError:
            continue
        if isinstance(doc, dict):
            rows.append(doc)
        elif isinstance(doc, list):
            rows.extend(d for d in doc if isinstance(d, dict))
    return rows


def _labels_of(value: Any) -> dict[str, str]:
    """`docker ps/network ls --format json` 의 Labels 는 "k=v,k=v" 문자열, inspect 는 dict."""
    if isinstance(value, dict):
        return {str(k): str(v) for k, v in value.items()}
    out: dict[str, str] = {}
    for part in str(value or "").split(","):
        if "=" in part:
            k, v = part.split("=", 1)
            out[k.strip()] = v.strip()
    return out


def _is_e2e(name: str, labels: dict[str, str], globs: list[str]) -> bool:
    if labels.get(E2E_LABEL) == "1":
        return True
    name = name.lstrip("/")
    return any(fnmatch.fnmatchcase(name, g) for g in globs)


_ANON_VOLUME_RE = re.compile(r"^[0-9a-f]{64}$")


# ─────────────────────────── 판정·실행 ───────────────────────────

_RUN_LOCK = threading.Lock()          # 데몬 자동 + 대시보드 "지금" 겹침 방지(같은 프로세스 안)
_RUNNING = {"active": False}
_STEP_NAMES = ("build-cache", "dangling", "volumes", "e2e")


def _step(name: str) -> dict[str, Any]:
    return {"name": name, "reclaimedMb": 0, "items": [], "error": None, "skipped": False}


class _Docker:
    """한 번의 GC 안에서 도커 조회를 묶는다 — system df 는 비싸서 단계끼리 공유한다."""

    def __init__(self, run: Runner):
        self.run = run
        self._df: dict[str, Any] | None = None

    def df(self) -> dict[str, Any]:
        if self._df is None:
            docs = _ndjson(self.run(["system", "df", "-v", "--format", "json"]))
            self._df = docs[0] if docs else {}
        return self._df

    def containers(self) -> list[dict[str, Any]]:
        """[{id, status, image, name, created, labels}] — ps -a -q + inspect 한 번(라벨·정확한 이미지 sha 포함)."""
        ids = [line.strip() for line in self.run(["ps", "-a", "-q"]).splitlines() if line.strip()]
        if not ids:
            return []
        fmt = "{{.Id}}\t{{.State.Status}}\t{{.Image}}\t{{.Name}}\t{{.Created}}\t{{json .Config.Labels}}"
        out: list[dict[str, Any]] = []
        for line in self.run(["inspect", "--format", fmt, *ids]).splitlines():
            parts = line.rstrip("\n").split("\t")
            if len(parts) < 6:
                continue
            cid, status, image, name, created, labels = parts[:6]
            try:
                labels_d = _labels_of(json.loads(labels) or {})
            except json.JSONDecodeError:
                labels_d = {}
            out.append({"id": cid, "status": status, "image": image.removeprefix("sha256:"), "name": name,
                        "created": parse_docker_time(created), "labels": labels_d})
        return out


def _image_used(image_id: str, containers: list[dict[str, Any]]) -> bool:
    short = image_id.removeprefix("sha256:")
    return any(c["image"].startswith(short) or short.startswith(c["image"]) for c in containers if c["image"])


def _run_steps(policy: dict[str, Any], dry_run: bool, now: float, run: Runner) -> list[dict[str, Any]]:
    dk = _Docker(run)
    steps: list[dict[str, Any]] = []
    globs = list(policy.get("stale_test_artifact_names") or DEFAULT_POLICY["stale_test_artifact_names"])

    # ① 빌드캐시 — InUse 아니고 keep_days 넘게 안 쓴 것(LastUsedAt, 없으면 CreatedAt)
    st = _step("build-cache"); steps.append(st)
    keep_days = int(policy.get("build_cache_keep_days") or 0)
    if keep_days <= 0:
        st["skipped"] = True
    else:
        try:
            cutoff = now - keep_days * 86400
            for entry in dk.df().get("BuildCache") or []:
                if str(entry.get("InUse", "")).lower() == "true":
                    continue
                ts = parse_docker_time(entry.get("LastUsedAt")) or parse_docker_time(entry.get("CreatedAt"))
                if ts is None or ts >= cutoff:
                    continue
                size = _size_mb(entry.get("Size"))
                st["reclaimedMb"] += size
                st["items"].append(f"build-cache {entry.get('ID', '?')} {fmt_mb(size)}")
            if not dry_run:
                out = run(["builder", "prune", "-f", "--filter", f"until={keep_days * 24}h"])
                got = parse_reclaimed_mb(out)
                if got is not None:
                    st["reclaimedMb"] = got
        except Exception as exc:
            st["error"] = str(exc)

    # ② dangling 이미지 — 어떤 컨테이너(실행 여부 무관)도 안 쓰는 <none>:<none>
    st = _step("dangling"); steps.append(st)
    if not policy.get("dangling_images", True):
        st["skipped"] = True
    else:
        try:
            containers = dk.containers()
            for img in _ndjson(run(["images", "-f", "dangling=true", "--format", "json"])):
                iid = str(img.get("ID") or "")
                if not iid or _image_used(iid, containers):
                    continue
                size = _size_mb(img.get("Size"))
                st["reclaimedMb"] += size
                st["items"].append(f"image {iid} <none> {fmt_mb(size)}")
            if not dry_run:
                got = parse_reclaimed_mb(run(["image", "prune", "-f"]))
                if got is not None:
                    st["reclaimedMb"] = got
        except Exception as exc:
            st["error"] = str(exc)

    # ③ 익명 볼륨 — 붙은 컨테이너 없는(dangling) 64hex 이름만. 명명 볼륨은 절대 아님(--all 안 씀).
    st = _step("volumes"); steps.append(st)
    if not policy.get("anonymous_volumes", True):
        st["skipped"] = True
    else:
        try:
            sizes = {str(v.get("Name")): _size_mb(v.get("Size")) for v in dk.df().get("Volumes") or []}
            for vol in _ndjson(run(["volume", "ls", "-f", "dangling=true", "--format", "json"])):
                name = str(vol.get("Name") or "")
                if not _ANON_VOLUME_RE.match(name):
                    continue
                size = sizes.get(name, 0)
                st["reclaimedMb"] += size
                st["items"].append(f"volume {name[:12]}… {fmt_mb(size)}")
            if not dry_run:
                got = parse_reclaimed_mb(run(["volume", "prune", "-f"]))
                if got is not None:
                    st["reclaimedMb"] = got
        except Exception as exc:
            st["error"] = str(exc)

    # ④ e2e 잔재 — 라벨 marina.e2e=1 또는 이름 글롭, days 넘게 오래된 것. 실행 중·사용 중은 제외하고 -f 없이 지운다.
    st = _step("e2e"); steps.append(st)
    st["counts"] = {"containers": 0, "images": 0, "networks": 0}
    days = int(policy.get("stale_test_artifacts_days") or 0)
    if days <= 0:
        st["skipped"] = True
    else:
        cutoff = now - days * 86400
        try:
            containers = dk.containers()
            doomed = [c for c in containers
                      if c["status"] not in ("running", "paused", "restarting")
                      and c["created"] is not None and c["created"] < cutoff
                      and _is_e2e(c["name"], c["labels"], globs)]
            for c in doomed:
                st["items"].append(f"container {c['name'].lstrip('/')} ({c['status']})")
                if not dry_run:
                    run(["rm", c["id"]])          # -f 없음 — 그 사이 떴으면 도커가 거부한다
            st["counts"]["containers"] = len(doomed)
            # 이미지: 컨테이너 정리 **뒤** 남은 컨테이너가 쓰는 것은 제외(지워진 컨테이너가 쓰던 이미지는 회수)
            remaining = dk.containers() if not dry_run else [c for c in containers if c not in doomed]
            labeled = {line.strip() for line in run(["images", "--filter", f"label={E2E_LABEL}=1", "-q"]).splitlines() if line.strip()}
            for img in _ndjson(run(["images", "--format", "json"])):
                iid = str(img.get("ID") or "")
                ref = f"{img.get('Repository')}:{img.get('Tag')}"
                is_e2e = any(iid.startswith(l) or l.startswith(iid) for l in labeled) \
                    or any(fnmatch.fnmatchcase(str(img.get("Repository") or ""), g) or fnmatch.fnmatchcase(ref, g) for g in globs)
                ts = parse_docker_time(img.get("CreatedAt"))
                if not iid or not is_e2e or ts is None or ts >= cutoff or _image_used(iid, remaining):
                    continue
                size = _size_mb(img.get("Size"))
                st["items"].append(f"image {ref} {fmt_mb(size)}")
                if not dry_run:
                    run(["image", "rm", iid])     # -f 없음 — 사용 중이면 도커가 거부한다
                st["reclaimedMb"] += size
                st["counts"]["images"] += 1
            nets = [n for n in _ndjson(run(["network", "ls", "--format", "json"]))
                    if _is_e2e(str(n.get("Name") or ""), _labels_of(n.get("Labels")), globs)
                    and (parse_docker_time(n.get("CreatedAt")) or now) < cutoff]
            if nets:
                attached: dict[str, int] = {}
                for line in run(["network", "inspect", "--format", "{{.Id}}\t{{len .Containers}}", *[str(n["ID"]) for n in nets]]).splitlines():
                    parts = line.split("\t")
                    if len(parts) >= 2:
                        attached[parts[0]] = int(parts[1] or 0)
                for n in nets:
                    nid = str(n["ID"])
                    if next((v for k, v in attached.items() if k.startswith(nid) or nid.startswith(k)), 0):
                        continue                  # 붙은 컨테이너가 있다 — 사용 중
                    st["items"].append(f"network {n.get('Name')}")
                    if not dry_run:
                        run(["network", "rm", nid])
                    st["counts"]["networks"] += 1
        except Exception as exc:
            st["error"] = str(exc)
    return steps


def _log_line(report: dict[str, Any]) -> str:
    when = datetime.fromtimestamp(report["finishedAt"], timezone.utc).astimezone().isoformat(timespec="seconds")
    src = f"{report['source']}/dry" if report["dryRun"] else report["source"]
    verb = "would reclaim" if report["dryRun"] else "reclaimed"
    parts = []
    for s in report["steps"]:
        if s.get("skipped"):
            continue
        piece = f"{s['name']} {fmt_mb(s['reclaimedMb'])}"
        if s["name"] == "e2e":
            c = s.get("counts") or {}
            piece = f"e2e ≈{fmt_mb(s['reclaimedMb'])}({c.get('containers', 0)} containers, {c.get('images', 0)} images, {c.get('networks', 0)} networks)"
        parts.append(piece)
    line = f"{when} {src:<9} {verb} {fmt_mb(report['reclaimedMb'])}  {' · '.join(parts) or '(모든 단계 꺼짐)'}"
    for s in report["steps"]:
        if s.get("error"):
            line += f"  FAILED {s['name']}: {s['error']}"
    return line


def _append_log(line: str) -> None:
    try:
        LOG_FILE.parent.mkdir(parents=True, exist_ok=True)
        with LOG_FILE.open("a", encoding="utf-8") as f:
            f.write(line + "\n")
    except OSError:
        pass


def collect(policy: dict[str, Any], source: str = "cli", dry_run: bool = False,
            now: float | None = None, run: Runner | None = None) -> dict[str, Any]:
    """네 단계를 순서대로. 단계 하나가 실패해도 다음으로 간다. dry_run 이면 삭제 명령 0회·상태 파일 무변경."""
    run = run or _docker_run
    started = time.time() if now is None else now
    with _RUN_LOCK:
        _RUNNING["active"] = True
        try:
            steps = _run_steps(policy, dry_run, started, run)
        finally:
            _RUNNING["active"] = False
    finished = max(time.time(), started) if now is None else now
    errors = [f"{s['name']}: {s['error']}" for s in steps if s.get("error")]
    report = {
        "startedAt": started, "finishedAt": finished, "source": source, "dryRun": dry_run,
        "reclaimedMb": sum(int(s["reclaimedMb"]) for s in steps), "steps": steps,
        "error": "; ".join(errors) or None,
    }
    _append_log(_log_line(report))
    if not dry_run:
        try:
            _atomic_write_json(STATE_FILE, {k: report[k] for k in ("startedAt", "finishedAt", "source", "reclaimedMb", "error")}
                               | {"steps": [{"name": s["name"], "reclaimedMb": s["reclaimedMb"], "count": len(s["items"]),
                                             "skipped": s["skipped"], "error": s["error"]} for s in steps]})
        except OSError:
            pass
    return report


def plan(policy: dict[str, Any], now: float | None = None, run: Runner | None = None, source: str = "cli") -> dict[str, Any]:
    """dry-run — 지울 것과 예상 회수량만. 아무것도 안 지운다."""
    return collect(policy, source=source, dry_run=True, now=now, run=run)


# ─────────────────────────── 상태 조회(대시보드·CLI) ───────────────────────────

_DISK_CACHE: dict[str, Any] = {"ts": 0.0, "value": None}
_DISK_TTL = 60.0


def docker_disk(force: bool = False) -> dict[str, int]:
    """docker system df 요약(imagesMb/buildCacheMb/volumesMb) — 12초까지 걸려 60초 캐시."""
    now = time.monotonic()
    if force or _DISK_CACHE["value"] is None or now - _DISK_CACHE["ts"] > _DISK_TTL:
        from marina_cache import docker_disk_summary
        _DISK_CACHE["value"] = docker_disk_summary()
        _DISK_CACHE["ts"] = now
    return dict(_DISK_CACHE["value"])


def status(with_disk: bool = True, now: float | None = None) -> dict[str, Any]:
    policy = load_policy()
    state = load_state()
    now = time.time() if now is None else now
    return {
        "policy": policy, "state": state, "due": due(policy, state, now), "nextRunAt": next_run_at(policy, state),
        "running": _RUNNING["active"], "disk": docker_disk() if with_disk else None,
        "logFile": str(LOG_FILE), "policyFile": str(POLICY_FILE),
    }
