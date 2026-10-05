"""L3 — 띄운 뒤에 **알아보고, 지키고, 되돌릴** 수 있게 한다.

세 가지가 전부 홈서버 구현에서 실측한 함정에서 나왔다.

① 백업: marina 는 **경로만 알려주고 실행은 사용자 도구에 맡긴다.** 홈서버에서 미마운트
   외장 매체에 조용히 백업해 내부 디스크를 채우는 사고를 겪었다 — marina 가 rsync 를
   직접 돌면 그 사고를 marina 가 떠안는다. 대신 **무엇을 왜** 백업해야 하는지는 끝까지
   알려준다: 비밀 파일이 백업에서 빠져 데이터가 영구히 잠기는 사고도 실측했다.
② 배포·롤백: `pin` 이 '무엇을 운영할지' 를 정하는 하나의 손잡이다. 이력을 남기고,
   **마이그레이션은 되돌아가지 않는다**는 경고를 같이 낸다.
③ 헬스: "healthy" 라는 단일 초록불을 만들지 않는다. 앱이 모든 경로를 인증 뒤에 두면
   헬스체크가 401 을 받고, 그걸 살아 있음으로 처리하면 **DB 가 죽어도 healthy** 로 남는
   것을 실측했다. 컨테이너 상태·재시작 횟수·HTTP 상태코드를 **따로** 보여준다.
"""
from __future__ import annotations

import json
import os
import pathlib
import time
import urllib.error
import urllib.request

import marina_live as L

MIGRATION_WARNING = (
    "주의: 롤백은 코드만 되돌린다 — DB 마이그레이션은 되돌아가지 않는다. "
    "옛 ref 로 내려갔는데 스키마가 앞서 있으면 그 코드가 깨질 수 있다. "
    "marina 가 풀 수 있는 문제가 아니라서 숨기지 않고 매번 알린다."
)


# ── 백업 대상 ────────────────────────────────────────────────────────────────
def backup_paths(project_id: str) -> list:
    """백업해야 할 경로와 **왜** 그것이 필요한지. 실행은 사용자 백업 도구가 한다."""
    root = L.live_root(project_id)
    reg = L.load_registry()
    cfg = None
    for p in (reg.get("projects") or []):
        if p.get("id") == project_id:
            cfg = dict(p.get("live") or {})
            cfg["root"] = p.get("root")
            break
    cfg = cfg or {}
    items = [
        {"path": str(L.live_data(project_id)), "secret": False,
         "why": "서비스 데이터 — 이게 전부다. 없으면 복원이 아니라 새 설치다."},
        {"path": str(L.projects_file()), "secret": True,
         "why": "live.ref·live.services 가 여기 있다. 없으면 데이터를 복원해도 "
                "무엇을 어떻게 띄웠는지 모른다."},
        {"path": str(root / "expose.json"), "secret": False,
         "why": "공개 설정(Funnel 포트·경로, Cloudflare 도메인). 없으면 공개를 다시 만들어야 한다."},
        {"path": str(root / "secrets.env"), "secret": True,
         "why": "Cloudflare 터널 토큰 등. 홈서버에서 비밀이 백업에서 빠져 데이터가 "
                "잠기는 사고를 실측했다 — 이것만은 빠뜨리면 안 된다."},
        {"path": str(root / "history.jsonl"), "secret": False,
         "why": "배포 이력. 없어도 서비스는 뜨지만 '언제 무엇을 올렸나' 가 사라진다."},
    ]
    env_file = str(cfg.get("envFile") or "").strip()
    if env_file:
        base = pathlib.Path(env_file)
        resolved = base if base.is_absolute() else (L.live_src(project_id) / base)
        items.append({"path": str(resolved), "secret": True,
                      "why": f"프로젝트가 선언한 환경 파일(live.envFile={env_file}) — "
                             f"DB 비밀번호·시드가 보통 여기 있다."})
    for it in items:
        it["exists"] = pathlib.Path(it["path"]).exists()
    # src/ 는 넣지 않는다 — ref 로 다시 뽑을 수 있다. overlay·unit 도 생성물이다.
    return items


def backup_warnings(project_id: str) -> list:
    out = []
    secrets = [i for i in backup_paths(project_id) if i["secret"]]
    if secrets:
        out.append(
            "위 목록에 **비밀이 들어 있는 파일**이 있다(" +
            ", ".join(pathlib.Path(i["path"]).name for i in secrets) +
            "). 백업 대상에서 제외하면 데이터는 돌아와도 열 수 없다 — 홈서버에서 실측한 사고다. "
            "백업 매체의 접근 권한을 그만큼 좁혀라."
        )
    missing = [i for i in backup_paths(project_id) if not i["exists"]]
    if missing:
        out.append("아직 없는 경로: " + ", ".join(pathlib.Path(i["path"]).name for i in missing) +
                   " (기동·공개 설정 전이면 정상)")
    out.append("marina 는 복사를 직접 하지 않는다 — 미마운트 매체에 조용히 백업해 내부 디스크를 "
               "채우는 사고를 떠안지 않으려고 경로만 알려 준다. rsync·restic·Time Machine 중 "
               "쓰는 것에 이 목록을 넣어라.")
    return out


# ── 배포 이력 ────────────────────────────────────────────────────────────────
def history_file(project_id: str) -> pathlib.Path:
    return L.live_root(project_id) / "history.jsonl"


def append_history(project_id: str, ref: str, note: str = "") -> pathlib.Path:
    """줄 하나 = 한 배포. append-only 라 동시에 써도 줄이 섞이지 않는다."""
    p = history_file(project_id)
    p.parent.mkdir(parents=True, exist_ok=True)
    row = {"at": time.strftime("%Y-%m-%dT%H:%M:%S%z"), "ref": str(ref), "note": str(note or "")}
    with p.open("a", encoding="utf-8") as fh:
        fh.write(json.dumps(row, ensure_ascii=False) + "\n")
    return p


def read_history(project_id: str, limit: int = 0) -> list:
    """깨진 줄은 건너뛴다 — append-only 파일은 중간에 끊길 수 있고, 한 줄 때문에 전체
    이력을 못 읽으면 '언제 무엇을 올렸나' 가 사라진다."""
    p = history_file(project_id)
    if not p.exists():
        return []
    rows = []
    for line in p.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            row = json.loads(line)
        except Exception:
            continue
        if isinstance(row, dict) and row.get("ref"):
            rows.append(row)
    return rows[-limit:] if limit else rows


# ── 데이터 용량 ──────────────────────────────────────────────────────────────
def _human(n: int) -> str:
    units = ("B", "KB", "MB", "GB", "TB")
    size = float(n)
    for u in units:
        if size < 1024 or u == units[-1]:
            return (f"{int(size)} {u}" if u == "B" else f"{size:.1f} {u}")
        size /= 1024
    return f"{n} B"


def data_usage(project_id: str) -> dict:
    """'없음' 과 '0 B' 를 구분한다 — 첫 기동 전과 데이터 유실은 다른 사건이고,
    둘을 똑같이 0 으로 보여주면 유실을 못 알아본다."""
    d = L.live_data(project_id)
    if not d.is_dir():
        return {"exists": False, "bytes": 0, "human": "없음", "path": str(d)}
    total = 0
    for base, _dirs, files in os.walk(str(d)):
        for f in files:
            try:
                total += os.lstat(os.path.join(base, f)).st_size
            except OSError:
                continue
    return {"exists": True, "bytes": total, "human": _human(total), "path": str(d)}


# ── 헬스 신호 ────────────────────────────────────────────────────────────────
def health_url(cfg, ports: dict):
    """live.health(경로) + 게시 포트 → URL. 선언이 없으면 None — 조용히 통과시키지 않고
    '선언 없음' 으로 보여 준다."""
    live = (cfg or {}).get("live") if isinstance(cfg, dict) and "live" in cfg else cfg
    live = live or {}
    path = str(live.get("health") or "").strip()
    if not path:
        return None
    if not path.startswith("/"):
        path = "/" + path
    svc = str(live.get("healthService") or "").strip()
    port = None
    if svc:
        port = (ports or {}).get(svc)
    elif len(ports or {}) == 1:
        port = list((ports or {}).values())[0]
    if not port:
        return None
    return f"http://127.0.0.1:{int(port)}{path}"


def health_probe(url: str, timeout: float = 3.0) -> dict:
    """**HTTP 상태코드 그 자체**를 돌려준다. 401 을 2xx 와 섞어 '살아 있음' 으로 만들지
    않는다 — 그러면 DB 가 죽어도 healthy 로 남는다(홈서버 실측)."""
    req = urllib.request.Request(url, method="GET")
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return {"code": int(resp.status), "error": None, "url": url}
    except urllib.error.HTTPError as exc:
        return {"code": int(exc.code), "error": None, "url": url}
    except Exception as exc:
        # 닫힌 포트·타임아웃은 코드가 아니라 **오류**다. 0 이나 500 으로 뭉개면
        # "서버가 500 을 준다" 와 "서버가 없다" 를 구분할 수 없다.
        return {"code": None, "error": f"{type(exc).__name__}: {exc}", "url": url}


# ── 대시보드용 종합 보고 ──────────────────────────────────────────────────────
def live_report(project_id: str) -> dict:
    """대시보드 live 영역이 그릴 것 전부. CLI status 와 **같은 신호**를 쓴다.

    `healthy` 같은 단일 불린을 **내보내지 않는다** — UI 가 그걸로 초록불을 만들면 401 이
    장애를 가린다(홈서버 실측). state·restarts·httpCode 를 따로 준다.
    """
    import marina_live_expose as X        # 순환 import 방지 — 쓰는 자리에서만
    reg = L.load_registry()
    cfg = None
    for p in (reg.get("projects") or []):
        if p.get("id") == project_id:
            cfg = dict(p.get("live") or {})
            break
    cfg = cfg or {}
    containers = L.live_containers(project_id)
    ports = L.live_service_ports(project_id)
    url = health_url({"live": cfg}, ports)
    probe = health_probe(url) if url else {"code": None, "error": None, "url": None}
    auto = L.autostart_state(project_id)
    ex = X.expose_config(project_id)
    return {
        "project": project_id,
        "ref": cfg.get("ref"),
        "services": list(cfg.get("services") or []),
        "containers": containers,
        "restartsTotal": sum(c["restarts"] for c in containers),
        "health": {"url": url, "code": probe["code"], "error": probe["error"],
                   "declared": bool(url)},
        "autostart": {"registered": auto["registered"], "path": auto["unit"],
                      "how": auto["how"], "detail": auto["detail"]},
        "data": data_usage(project_id),
        "ports": ports,
        "expose": {"funnel": ({"httpsPort": ex.get("httpsPort"), "path": ex.get("path")}
                              if ex.get("path") else None),
                   "cloudflare": ex.get("cloudflare") or None},
        "lastDeploy": (read_history(project_id, limit=1) or [None])[0],
        "checkout": str(L.live_src(project_id)),
    }


def live_reports() -> list:
    """live.ref 가 설정된 모든 프로젝트."""
    reg = L.load_registry()
    return [live_report(str(p.get("id")))
            for p in (reg.get("projects") or [])
            if p.get("id") and (p.get("live") or {}).get("ref")]
