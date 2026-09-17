"""marina_docker_gc.py — 워크트리에 묶이지 않는 도커 산출물의 주기 정리.

**왜 여기서.** 빌드캐시·dangling 이미지·익명 볼륨·e2e 잔재는 누가 만들었든 아무도 회수하지 않았다
(2026-09-14 실측: 7일 넘은 빌드캐시 21GB, e2e 이미지 383개, 익명 볼륨 319개). 형: "밖에서 cron 거는 건
의미 없다, marina 에서 컨트롤돼야 한다" — 정책도 실행도 marina 가 쥔다.

**범위 밖.** 워크트리 소유 이미지(remove_worktree → clear_worktree_images, marina_lifecycle) 는 여기서
다루지 않는다 — 단 marina 밖에서 지워진 워크트리의 이미지·정지 컨테이너는 ⑤ orphans 가 회수한다.
명명 볼륨(사용자 데이터일 수 있다)과 사용 중인 어떤 것도 **어느 단계에서도** 지우지 않는다.

**구조.** 도커 호출은 전부 `run(args) -> str` 하나를 통해 나간다 — 테스트는 가짜 run 을 주입해 명령·순서·
판정을 검증하고, 실 도커를 만지는 테스트는 dry-run 경로만 탄다.
설계: docs/superpowers/specs/2026-09-14-docker-gc-policy-design.md
"""
from __future__ import annotations

import contextlib
import fcntl
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
LOCK_FILE = MARINA_HOME / "docker-gc.lock"
VOLUMES_SEEN_FILE = MARINA_HOME / "docker-gc-volumes-seen.json"   # 익명 볼륨을 "처음 dangling 으로 본 시각" — 유예 판정용   # 프로세스 간 직렬화(데몬 자동 ↔ CLI --now ↔ 대시보드) — flock


@contextlib.contextmanager
def _file_lock():
    """같은 호스트의 다른 marina 프로세스와 실행·정책 쓰기를 직렬화한다(코덱스 리뷰: threading.Lock 은 프로세스 안에서만).
    잠금 파일을 못 만들면(권한 등) 잠그지 않고 진행 — GC 가 락 때문에 멈추는 쪽이 더 나쁘다."""
    try:
        LOCK_FILE.parent.mkdir(parents=True, exist_ok=True)
        fd = os.open(LOCK_FILE, os.O_RDWR | os.O_CREAT, 0o600)
    except OSError:
        yield
        return
    try:
        fcntl.flock(fd, fcntl.LOCK_EX)
        yield
    finally:
        try:
            fcntl.flock(fd, fcntl.LOCK_UN)
        finally:
            os.close(fd)

E2E_LABEL = "marina.e2e"          # 테스트 하네스가 e2e 산출물에 붙이는 라벨(값 "1")

DEFAULT_POLICY: dict[str, Any] = {
    "enabled": True,
    "interval_hours": 24,
    "build_cache_keep_days": 7,
    "dangling_images": True,
    "anonymous_volumes": True,
    "anonymous_volume_grace_days": 3,
    "stale_test_artifacts_days": 3,
    "stale_test_artifact_names": ["marina-*-e2e-*"],
    "orphan_worktree_days": 7,
}
_POLICY_TYPES: dict[str, str] = {
    "enabled": "bool",
    "interval_hours": "int",
    "build_cache_keep_days": "int",
    "dangling_images": "bool",
    "anonymous_volumes": "bool",
    "anonymous_volume_grace_days": "int",
    "stale_test_artifacts_days": "int",
    "stale_test_artifact_names": "globs",
    "orphan_worktree_days": "int",
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
    """한 키를 검증해 바꾸고 원자적으로 쓴다. 틀리면 ValueError 이고 파일은 안 건드린다.
    읽기-수정-쓰기 전체를 파일 락으로 감싼다 — _atomic_write_json 은 "쓰기" 만 원자적이라, 락 없이는 CLI 와 대시보드가
    동시에 다른 키를 바꿀 때 한쪽 변경이 덮어써진다."""
    coerced = _coerce(key, value)          # 파일 읽기 전에 검증 — 실패해도 파일 무변경
    with _file_lock():
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
    """prune 계열 출력의 회수량 → MB. 없으면 None.
    image/volume prune 은 `Total reclaimed space: 2.5GB`, builder prune 은 `Total:\t2.5GB` 로 낸다(실측 2026-09-17 —
    예전엔 앞 형식만 읽어 builder prune 결과를 못 읽고 실행 전 추정치를 '회수량' 으로 기록했다)."""
    m = re.search(r"(?:Total reclaimed space|^Total):\s*([0-9.]+\s*[KMGT]?i?B)", text or "", re.IGNORECASE | re.MULTILINE)
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


def _load_volumes_seen() -> dict[str, float]:
    try:
        data = json.loads(VOLUMES_SEEN_FILE.read_text(encoding="utf-8"))
        return {str(k): float(v) for k, v in data.items()} if isinstance(data, dict) else {}
    except Exception:
        return {}


def _save_volumes_seen(seen: dict[str, float]) -> None:
    try:
        _atomic_write_json(VOLUMES_SEEN_FILE, seen)
    except OSError:
        pass


# ─────────────────────────── 판정·실행 ───────────────────────────

_RUN_LOCK = threading.Lock()          # 데몬 자동 + 대시보드 "지금" 겹침 방지(같은 프로세스 안)
_RUNNING = {"active": False}
_STEP_NAMES = ("build-cache", "dangling", "volumes", "e2e", "orphans")


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
            if dry_run:
                # 레코드별 LastUsedAt 로 센 값은 **상한**이다 — 오래된 레코드라도 최근 빌드가 참조하면 buildkit 이 안 지운다.
                st["estimate"] = "upper"
            else:
                # --all 필수: 없으면 buildkit 은 어디에도 안 걸린(dangling) 캐시만 지워 일반 캐시가 영영 남는다(실측 0B).
                out = run(["builder", "prune", "--all", "-f", "--filter", f"until={keep_days * 24}h"])
                got = parse_reclaimed_mb(out)
                st["reclaimedMb"] = got if got is not None else 0   # 실행 결과만 기록 — 못 읽으면 0(추정치로 부풀리지 않는다)
                if got is None:
                    st["note"] = "회수량을 읽지 못함"
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

    # ③ 익명 볼륨 — 붙은 컨테이너 없는(dangling) 64hex 이름만. 명명 볼륨은 절대 아님.
    #    유예(코드리뷰 지적): `marina stop --all`(= compose down) 직후엔 살아 있는 서비스의 익명 볼륨도 dangling 으로 보인다.
    #    그래서 "처음 dangling 으로 본 시각"을 기록해 grace_days 넘게 계속 떠 있던 것만 지운다. 다시 붙은 볼륨은 기록도 지운다.
    #    prune -f 는 나이를 못 가리므로 안 쓰고, 이름을 집어 `volume rm` 한다(도커가 사용 중이면 스스로 거부).
    st = _step("volumes"); steps.append(st)
    st["waiting"] = 0
    grace_days = int(policy.get("anonymous_volume_grace_days", DEFAULT_POLICY["anonymous_volume_grace_days"]) or 0)
    if not policy.get("anonymous_volumes", True):
        st["skipped"] = True
    else:
        try:
            sizes = {str(v.get("Name")): _size_mb(v.get("Size")) for v in dk.df().get("Volumes") or []}
            dangling: list[str] = []
            for vol in _ndjson(run(["volume", "ls", "-f", "dangling=true", "--format", "json"])):
                name = str(vol.get("Name") or "")
                if _ANON_VOLUME_RE.match(name):
                    dangling.append(name)
            before = _load_volumes_seen()
            seen = {name: float(before.get(name) or now) for name in dangling}
            _save_volumes_seen(seen)
            cutoff = now - grace_days * 86400
            doomed = [name for name in dangling if seen[name] <= cutoff]
            st["waiting"] = len(dangling) - len(doomed)
            for name in doomed:
                size = sizes.get(name, 0)
                st["reclaimedMb"] += size
                st["items"].append(f"volume {name[:12]}… {fmt_mb(size)}")
            if not dry_run and doomed:
                removed: set[str] = set()
                errors: list[str] = []
                for name in doomed:
                    try:
                        run(["volume", "rm", name])
                        removed.add(name)
                    except Exception as exc:          # 하나가 막혀도(사용 중 등) 나머지는 계속
                        errors.append(f"{name[:12]}…: {exc}")
                if removed:
                    _save_volumes_seen({n: t for n, t in seen.items() if n not in removed})
                    st["reclaimedMb"] = sum(sizes.get(n, 0) for n in removed)
                if errors:
                    st["error"] = "; ".join(errors)
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

    # ⑤ 사라진 워크트리의 잔재 — marina 밖(git·Claude 앱)에서 지운 워크트리는 워크트리 GC 의 회수를 못 타서 그 compose
    #    프로젝트의 이미지(수 GB)·정지 컨테이너가 남는다(2026-09-14 mdc-main 이미지 28개·50GB 가 이 경우).
    #    **명명 볼륨은 지우지 않는다**(코드리뷰 Critical): 워크트리 이름을 바꾸거나 디스크가 잠시 빠지면 살아 있는 워크트리도
    #    발견에서 사라져 고아로 보인다(실측 재현). 지우는 건 다시 만들 수 있는 것(정지 컨테이너·이미지)뿐 — 오판의 대가는 재빌드.
    #    판정: compose 프로젝트 라벨이 **등록 프로젝트 id 로 시작**(marina 가 만든 것)하는데 지금 발견되는 어느 워크트리의
    #    프로젝트명과도 안 맞고, days 넘게 오래된 것. 그 프로젝트에 **실행 중 컨테이너가 하나라도 있으면 통째로 건너뛴다**.
    #    프로젝트 루트가 사라진(옮겨진) 프로젝트는 발견이 비므로 믿지 않고 건너뛴다 — 전부 고아로 오판해 지우는 사고 방지.
    st = _step("orphans"); steps.append(st)
    st["counts"] = {"projects": 0, "containers": 0, "images": 0}
    days = int(policy.get("orphan_worktree_days") or 0)
    if days <= 0:
        st["skipped"] = True
    else:
        try:
            live = _live_compose_projects()
            if live is None:
                st["skipped"] = True
                st["note"] = "등록 프로젝트를 읽지 못해 건너뜀"
            else:
                live_names, owner_prefixes = live
                cutoff = now - days * 86400

                def orphan(project: str) -> bool:
                    return bool(project) and project not in live_names and any(project.startswith(p) for p in owner_prefixes)

                containers = dk.containers()
                by_project: dict[str, list] = {}
                for c in containers:
                    proj = c["labels"].get("com.docker.compose.project", "")
                    if orphan(proj):
                        by_project.setdefault(proj, []).append(c)
                busy = {p for p, cs in by_project.items() if any(c["status"] in ("running", "paused", "restarting") for c in cs)}
                projects: set[str] = set()
                for proj, cs in sorted(by_project.items()):
                    if proj in busy:
                        continue
                    for c in cs:
                        st["items"].append(f"container {c['name'].lstrip('/')} ({c['status']}) [{proj}]")
                        if not dry_run:
                            run(["rm", c["id"]])            # -f 없음
                        st["counts"]["containers"] += 1
                        projects.add(proj)
                remaining = dk.containers() if not dry_run else [c for c in containers
                                                                 if c["labels"].get("com.docker.compose.project", "") not in by_project
                                                                 or c["labels"].get("com.docker.compose.project", "") in busy]
                imgs = _ndjson(run(["image", "ls", "--filter", "label=com.docker.compose.project", "--format", "json"]))
                img_proj: dict[str, str] = {}
                if imgs:
                    for line in run(["image", "inspect", "--format", '{{.Id}}\t{{index .Config.Labels "com.docker.compose.project"}}',
                                     *[str(i.get("ID")) for i in imgs if i.get("ID")]]).splitlines():
                        parts = line.split("\t")
                        if len(parts) >= 2:
                            img_proj[parts[0].removeprefix("sha256:")] = parts[1]
                for img in imgs:
                    iid = str(img.get("ID") or "")
                    proj = next((v for k, v in img_proj.items() if k.startswith(iid) or iid.startswith(k)), "")
                    ts = parse_docker_time(img.get("CreatedAt"))
                    if not iid or not orphan(proj) or proj in busy or ts is None or ts >= cutoff or _image_used(iid, remaining):
                        continue
                    size = _size_mb(img.get("Size"))
                    st["items"].append(f"image {img.get('Repository')}:{img.get('Tag')} {fmt_mb(size)} [{proj}]")
                    if not dry_run:
                        run(["image", "rm", iid])           # -f 없음 — 사용 중이면 도커가 거부
                    st["reclaimedMb"] += size
                    st["counts"]["images"] += 1
                    projects.add(proj)
                st["counts"]["projects"] = len(projects)
        except Exception as exc:
            st["error"] = str(exc)
    return steps


def _compose_project_prefix(project_id: str) -> str:
    """marina-compose.compose_project_name 과 같은 정규화 + '-'. 등록 프로젝트가 만든 compose 프로젝트인지 가르는 접두사."""
    return re.sub(r"[^a-z0-9_-]+", "-", str(project_id).lower()).strip("-_") + "-"


def _live_compose_projects():
    """(지금 발견되는 모든 워크트리의 compose 프로젝트명, 믿을 수 있는 등록 프로젝트 접두사들). 못 읽으면 None.
    루트가 없는 프로젝트는 접두사에서 뺀다 — 발견이 비어 그 프로젝트 전부가 고아로 보이는 것을 막는다. 테스트가 바꾸는 이음매."""
    from marina_registry import discover_all_roots, load_projects, project_for
    from marina_paths import session_id
    projects = load_projects()
    if not projects:
        return None
    prefixes = [_compose_project_prefix(p["id"]) for p in projects if Path(p["root"]).is_dir()]
    from marina_state import _mc
    mc = _mc()
    live: set[str] = set()
    for root in discover_all_roots(refresh=True):
        proj = project_for(root) or {}
        live.add(mc.compose_project_name(str(proj.get("id", "")), session_id(root)))   # 실행 경로와 같은 함수 — 규칙이 갈라지지 않게
    return live, prefixes


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
        elif s["name"] == "orphans":
            c = s.get("counts") or {}
            piece = f"orphans {fmt_mb(s['reclaimedMb'])}({c.get('projects', 0)} projects: {c.get('containers', 0)} containers, {c.get('images', 0)} images)"
        elif s["name"] == "build-cache" and s.get("estimate") == "upper":
            piece = f"build-cache ≤{fmt_mb(s['reclaimedMb'])}"
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
    with _RUN_LOCK, _file_lock():          # 프로세스 안(스레드) + 프로세스 간(flock) — 같은 대상을 두 번 지우려다 한쪽이 오류로 남지 않게
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


def status(with_disk: bool = True, now: float | None = None, refresh: bool = False) -> dict[str, Any]:
    policy = load_policy()
    state = load_state()
    now = time.time() if now is None else now
    return {
        "policy": policy, "state": state, "due": due(policy, state, now), "nextRunAt": next_run_at(policy, state),
        "running": _RUNNING["active"], "disk": docker_disk(force=refresh) if with_disk else None,
        "logFile": str(LOG_FILE), "policyFile": str(POLICY_FILE),
    }


# ─────────────────────────── 데몬 틱 ───────────────────────────

def recorded_daemon_port() -> int | None:
    """marina dashboard start 가 적어둔 포트(dashboard-bind.env). 없거나 못 읽으면 None."""
    try:
        for line in (MARINA_HOME / "dashboard-bind.env").read_text(encoding="utf-8").splitlines():
            key, _, value = line.partition("=")
            if key.strip() == "MARINA_CONTROL_PORT":
                return int(value.strip())
    except (OSError, ValueError):
        return None
    return None


def daemon_tick(port: int, now: float | None = None, run: Runner | None = None, primary: bool | None = None) -> str:
    """데몬 폴링 루프의 한 틱. 예외를 절대 밖으로 안 낸다 — 반환 문자열로만 보고한다.

    **기록된 데몬**(dashboard-bind.env 의 포트)만 자동 실행한다. 푸시 알림(is_primary_notifier)보다 엄격하다 —
    거기선 기록이 없으면 "막지 않음" 이지만, 여기선 기록이 없으면 **안 돈다**. 실측(2026-09-14): 격리 홈으로 띄운
    리뷰 프리뷰(:3940)가 기록이 없어 primary 로 잡혀, 부팅 60초 뒤 실 도커의 빌드캐시 9.2GB 를 자동으로 지웠다.
    도커는 호스트 하나를 모든 인스턴스가 공유하므로, 자동 정리는 정식으로 설치된 데몬 하나만 해야 한다."""
    try:
        if primary is None:
            recorded = recorded_daemon_port()
            primary = recorded is not None and recorded == int(port)
        if not primary:
            return "skipped:not-primary"
        policy = load_policy()
        if not due(policy, load_state(), now):
            return "skipped:not-due"
        report = collect(policy, source="auto", now=now, run=run)
        return "ran" if not report.get("error") else f"ran:{report['error']}"
    except Exception as exc:
        _append_log(f"{datetime.now().astimezone().isoformat(timespec='seconds')} auto      FAILED {exc}")
        return f"failed:{exc}"
