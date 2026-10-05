"""L2 — live 스택을 인터넷에 공개한다. 두 길(Tailscale Funnel / Cloudflare 터널).

**Funnel 은 443 을 쓰지 않는다.** marina 자신의 원격 접근이 443 을 쓰고(`marina_remote`
의 activate 는 `--https=443` 고정), Tailscale 의 `AllowFunnel` 은 **경로가 아니라
authority(host:port) 단위**다. 443 의 `/app` 을 공개하려고 funnel 을 켜면 같은 443 의
`/` 에 있는 **대시보드까지 인터넷에 열린다** — 관리 UI 공개 금지 원칙 정면 위반이다.
그래서 live 는 Funnel 이 허용하는 나머지 두 포트(8443·10000)만 쓴다. 동시에 공개할 수
있는 앱이 최대 2개라는 뜻이고, **그 한도를 숨기지 않는다**: 세 번째는 거부하고 Cloudflare
터널을 안내한다(한도를 자동 배정으로 가리면 "왜 세 번째가 안 되냐"로 돌아온다).

tailscale 을 직접 부르지 않고 항상 `RemoteController` 를 쓴다 — 맥에서 tailscaled 와
Tailscale 앱이 같이 떠 있으면 `--socket` 없는 CLI 는 앱 쪽에 붙어 status 와 funnel 이
어긋난다(marina_remote 가 이미 그 소켓을 핀한다).
"""
from __future__ import annotations

import json
import os
import pathlib

import marina_live as L

FUNNEL_PORTS = (8443, 10000)      # 443 은 marina 자신의 원격 접근 — 위 docstring 참고
CLOUDFLARE_REQUIRED = ("token", "zone", "account", "tunnel")

PATH_WARNING = (
    "경고: 경로 기반 공개다. 앱이 자기가 루트(/)에 있다고 가정하면 깨진다 — "
    "절대경로 asset(/assets/x.js), 쿠키 path, 로그인 redirect 가 대표적이다. "
    "Vite 면 base, Spring 이면 server.servlet.context-path 를 맞춰야 한다. "
    "루트가 필요하거나 앱이 둘 이상이면 도메인을 사서 Cloudflare 터널을 써라."
)


def expose_file(project_id: str) -> pathlib.Path:
    return L.live_root(project_id) / "expose.json"


def secrets_file(project_id: str) -> pathlib.Path:
    return L.live_root(project_id) / "secrets.env"


def expose_config(project_id: str) -> dict:
    p = expose_file(project_id)
    if not p.exists():
        return {}
    try:
        data = json.loads(p.read_text(encoding="utf-8"))
    except Exception:
        return {}
    return data if isinstance(data, dict) else {}


def save_expose_config(project_id: str, cfg: dict) -> pathlib.Path:
    p = expose_file(project_id)
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(json.dumps(cfg, ensure_ascii=False, indent=1) + "\n", encoding="utf-8")
    return p


def write_secrets(project_id: str, values: dict) -> pathlib.Path:
    """비밀은 0600 으로 ~/.marina 안에. **백업 목록에 반드시 들어간다**(L3 결정 4) —
    홈서버에서 비밀이 백업에서 빠져 데이터가 잠기는 사고를 실측했다."""
    p = secrets_file(project_id)
    p.parent.mkdir(parents=True, exist_ok=True)
    fd = os.open(str(p), os.O_CREAT | os.O_WRONLY | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as fh:
        for k in sorted(values):
            fh.write(f"{k}={values[k]}\n")
    os.chmod(str(p), 0o600)
    return p


def funnel_path(project_id: str, path=None) -> str:
    raw = str(path or f"/{project_id}").strip()
    raw = "/" + raw.strip("/")
    if raw == "/":
        raise L.LiveConfigError("경로가 '/' 면 안 된다 — 443 의 루트는 marina 자신의 원격 접근 자리다.")
    return raw


def pick_funnel_port(taken) -> int:
    """비어 있는 Funnel 포트. 없으면 거부하고 **왜 2개뿐인지** 말한다."""
    used = {int(t) for t in (taken or [])}
    for p in FUNNEL_PORTS:
        if p not in used:
            return p
    raise L.LiveConfigError(
        f"Funnel 로 공개할 포트가 없다. Tailscale Funnel 은 443·8443·10000 만 허용하고, "
        f"443 은 marina 자신의 원격 접근(대시보드)이 쓴다 — 443 에 경로를 붙이면 그 대시보드까지 "
        f"인터넷에 열린다. 남은 {FUNNEL_PORTS[0]}·{FUNNEL_PORTS[1]} 가 이미 차 있다. "
        f"앱을 더 공개하려면 도메인을 사서 Cloudflare 터널을 쓰거나, 쓰지 않는 공개를 "
        f"`marina live unexpose <프로젝트>` 로 내려라."
    )


def validate_cloudflare(creds: dict) -> None:
    """자격증명이 **하나라도** 비면 아무것도 만들기 전에 거부한다. 홈서버 구현에서 얻은 교훈:
    반쯤 만들어진 터널은 DNS 레코드만 남아 디버깅이 불가능해진다."""
    missing = [k for k in CLOUDFLARE_REQUIRED if not str((creds or {}).get(k) or "").strip()]
    if missing:
        raise L.LiveConfigError(
            f"Cloudflare 자격증명이 모자라다: {', '.join(missing)}. "
            f"넷({', '.join(CLOUDFLARE_REQUIRED)}) 이 다 있어야 시작한다 — 반쯤 만든 터널은 "
            f"DNS 레코드만 남아 원인을 못 찾는다."
        )


def cloudflared_overlay(project_id: str, domain: str, backend_port: int) -> str:
    """live overlay 에 덧붙일 cloudflared 서비스. **live 세션에서만** 들어간다 —
    터널 하나에 커넥터가 여럿이면 Cloudflare 가 공개 요청을 그중 아무 데로나 보낸다
    (홈서버 구현에서 실측). 개발 워크트리마다 커넥터가 뜨면 공개 트래픽이 무작위
    워크트리로 들어간다."""
    if not domain or not backend_port:
        return ""
    return (
        "services:\n"
        "  cloudflared:\n"
        "    image: cloudflare/cloudflared:latest\n"
        '    command: ["tunnel", "--no-autoupdate", "run"]\n'
        "    restart: unless-stopped\n"
        "    env_file:\n"
        f"      - {json.dumps(str(secrets_file(project_id)))}\n"
        "    labels:\n"
        f"      {json.dumps(L.LIVE_LABEL)}: \"1\"\n"
        f"      {json.dumps(L.PROJECT_LABEL)}: {json.dumps(project_id)}\n"
        "    environment:\n"
        f"      MARINA_LIVE_DOMAIN: {json.dumps(str(domain))}\n"
        f"      MARINA_LIVE_BACKEND: {json.dumps('http://127.0.0.1:%d' % int(backend_port))}\n"
    )


def _controller(controller=None):
    if controller is not None:
        return controller
    from marina_remote import RemoteController
    return RemoteController(marina_home=L.marina_home())


def _live_route_ports(status) -> list:
    return [int(r.get("httpsPort") or 0) for r in (status.get("liveRoutes") or [])]


def _require_tailscale(status) -> None:
    if not status.get("installed"):
        raise L.LiveConfigError(
            "Tailscale 이 설치돼 있지 않다. 공개는 Tailscale Funnel 또는 도메인+Cloudflare "
            "터널로만 한다 — 포트포워딩은 열지 않는다."
        )
    if not status.get("online"):
        raise L.LiveConfigError("Tailscale 이 연결돼 있지 않다. `tailscale up` 먼저.")
    if status.get("conflict"):
        raise L.LiveConfigError(
            "Tailscale serve/funnel 설정이 marina 가 저장한 지문과 다르다. 손으로 바꾼 설정이 "
            "있으면 marina 는 그것을 건드리지 않는다 — `tailscale serve status` 로 확인하고 정리해라."
        )


def expose_status(project_id: str, controller=None) -> dict:
    """공개 상태를 읽는다. Tailscale 이 없으면 **거부 이유를 담아** 돌려준다 —
    조용히 빈 상태를 보여주면 "공개한 줄 알았는데 아니었다" 가 된다."""
    ctl = _controller(controller)
    status = ctl.status(refresh=True)
    cfg = expose_config(project_id)
    out = {
        "project": project_id,
        "installed": bool(status.get("installed")),
        "online": bool(status.get("online")),
        "conflict": bool(status.get("conflict")),
        "mode": "off",
        "url": None,
        "path": cfg.get("path"),
        "httpsPort": cfg.get("httpsPort"),
        "cloudflare": cfg.get("cloudflare") or None,
        "reason": "",
        "warnings": [],
    }
    if not out["installed"]:
        out["reason"] = "Tailscale CLI 가 없다 — Funnel 공개를 쓸 수 없다."
        return out
    if not out["online"]:
        out["reason"] = "Tailscale 이 연결돼 있지 않다 — 공개 상태를 읽을 수 없다."
        return out
    if out["conflict"]:
        out["reason"] = "Tailscale 설정이 marina 소유가 아니다 — 공개를 바꾸지 않는다."
    host = status.get("dnsName") or ""
    for r in (status.get("routes") or []):
        if cfg.get("httpsPort") and int(r.get("httpsPort") or 0) == int(cfg["httpsPort"]) \
                and str(r.get("path") or "") == str(cfg.get("path") or ""):
            out["mode"] = str(r.get("mode") or "off")
            out["url"] = f"https://{host}:{r['httpsPort']}{r['path']}"
            if out["mode"] == "funnel":
                out["warnings"].append(PATH_WARNING)
            break
    if out["cloudflare"]:
        out["warnings"].append(
            f"Cloudflare 터널로도 공개 중: https://{out['cloudflare'].get('domain')} "
            f"(커넥터는 live 세션에만 뜬다 — 개발 워크트리에서는 절대 띄우지 마라)"
        )
    return out


def expose_funnel(project_id: str, backend_port: int, path=None, controller=None) -> dict:
    """443 이 아닌 Funnel 포트 하나를 이 프로젝트에 붙인다. 경로 기반 공개 경고를 **반드시** 낸다."""
    ctl = _controller(controller)
    status = ctl.status(refresh=True)
    _require_tailscale(status)
    want = funnel_path(project_id, path)
    for r in (status.get("routes") or []):
        if str(r.get("path") or "") == want:
            raise L.LiveConfigError(
                f"경로 {want} 는 이미 {r.get('httpsPort')} 에 공개돼 있다. 다른 --path 를 쓰거나 "
                f"`marina live unexpose` 로 먼저 내려라."
            )
    port = pick_funnel_port(_live_route_ports(status))
    backend = f"http://127.0.0.1:{int(backend_port)}"
    after = ctl.add_live_route("funnel", port, want, backend)
    if after.get("state") == "action_required":
        raise L.LiveConfigError(
            f"Tailscale 이 Funnel 승인을 요구한다. 열어서 허용한 뒤 다시 해라: {after.get('actionUrl')}"
        )
    cfg = dict(expose_config(project_id))
    cfg.update({"mode": "funnel", "httpsPort": port, "path": want, "backendPort": int(backend_port)})
    save_expose_config(project_id, cfg)
    host = after.get("dnsName") or (status.get("dnsName") or "")
    return {
        "mode": "funnel", "httpsPort": port, "path": want,
        "url": f"https://{host}:{port}{want}",
        "warnings": [PATH_WARNING],
    }


def expose_cloudflare(project_id: str, domain: str, creds: dict, backend_port: int,
                      controller=None) -> dict:
    """도메인 + Cloudflare 터널. 자격증명 넷이 다 있어야 **아무것도 만들기 전에** 시작한다."""
    if not str(domain or "").strip():
        raise L.LiveConfigError("--domain 이 필요하다 (예: app.example.com).")
    validate_cloudflare(creds)
    write_secrets(project_id, {"TUNNEL_TOKEN": str(creds["token"]).strip()})
    cfg = dict(expose_config(project_id))
    cfg["cloudflare"] = {
        "domain": str(domain).strip(),
        "zone": str(creds["zone"]).strip(),
        "account": str(creds["account"]).strip(),
        "tunnel": str(creds["tunnel"]).strip(),
        "backendPort": int(backend_port),
    }
    save_expose_config(project_id, cfg)
    return {
        "mode": "cloudflare",
        "domain": cfg["cloudflare"]["domain"],
        "url": f"https://{cfg['cloudflare']['domain']}",
        "secrets": str(secrets_file(project_id)),
        "warnings": [
            "cloudflared 는 live 세션에만 뜬다 — 개발 워크트리에서 같은 터널의 커넥터를 띄우면 "
            "Cloudflare 가 공개 요청을 그중 아무 데로나 보낸다(실측).",
            f"{secrets_file(project_id)} 는 백업 목록에 들어 있어야 한다 — "
            f"`marina live backup-paths {project_id}` 로 확인해라.",
            f"다음 기동에 적용된다: marina live up {project_id}",
        ],
    }


def unexpose(project_id: str, controller=None) -> dict:
    """멱등 — 이미 안 열려 있어도 성공한다. 공개를 내려도 **로컬 접근은 계속 된다**
    (선언 포트와 게이트웨이는 그대로다)."""
    cfg = dict(expose_config(project_id))
    removed = []
    if cfg.get("httpsPort") and cfg.get("path"):
        ctl = _controller(controller)
        ctl.remove_live_route(int(cfg["httpsPort"]), str(cfg["path"]))
        removed.append(f"funnel {cfg['httpsPort']}{cfg['path']}")
        cfg.pop("httpsPort", None)
        cfg.pop("path", None)
        cfg.pop("mode", None)
    if cfg.get("cloudflare"):
        removed.append(f"cloudflare {cfg['cloudflare'].get('domain')}")
        cfg.pop("cloudflare", None)
        secrets_file(project_id).unlink(missing_ok=True)
    save_expose_config(project_id, cfg)
    return {"removed": removed,
            "note": "로컬 접근은 그대로다 — 선언 포트와 게이트웨이는 공개와 무관하다."}
