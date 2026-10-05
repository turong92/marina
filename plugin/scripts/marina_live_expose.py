"""L2 — live 스택을 인터넷에 공개한다. 두 길(Tailscale Funnel / Cloudflare 터널).

**포트는 443·8443·10000 셋뿐이다 — Tailscale Funnel 제약이고 marina 와 무관하다.**
그 안에서 live 는 **443 이 비어 있으면 443 루트를 쓴다.** 그러면 주소가
`https://<기계>.ts.net/` 로 깔끔하고, 경로 기반 공개가 아니라서 앱이 깨질 위험(절대경로
asset·쿠키 path·redirect)도 아예 없다.

443 을 못 쓰는 경우는 하나다: marina 자신의 원격 접근(대시보드)이 거기 리스너를 올려
둔 경우. `AllowFunnel` 은 **경로가 아니라 authority(host:port) 단위**라 같은 443 에
둘을 얹으면 대시보드까지 인터넷에 열린다 — 관리 UI 공개 금지 위반이다. 그래서
**둘 중 하나만** 443 을 쥔다: live 가 쥐고 있으면 `RemoteController.activate` 가
거부하고, 대시보드가 쥐고 있으면 live 가 8443 → 10000 으로 내려간다.

셋이 다 차면 거부하고 Cloudflare 터널을 안내한다 — **한도를 자동 배정으로 가리지 않는다**
(가리면 "왜 네 번째가 안 되냐"로 돌아온다).

tailscale 을 직접 부르지 않고 항상 `RemoteController` 를 쓴다 — 맥에서 tailscaled 와
Tailscale 앱이 같이 떠 있으면 `--socket` 없는 CLI 는 앱 쪽에 붙어 status 와 funnel 이
어긋난다(marina_remote 가 이미 그 소켓을 핀한다).
"""
from __future__ import annotations

import json
import os
import pathlib

import marina_live as L

FUNNEL_PORTS = (443, 8443, 10000)   # Tailscale Funnel 이 허용하는 전부. 443 을 먼저 쓴다.
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


def funnel_path(project_id: str, path=None, https_port: int = 443) -> str:
    """공개 경로. **443 은 루트 전용**이다 — 거기 경로를 붙일 이유가 없고(앱 하나를 루트에
    올리는 자리다), 붙이면 경로 기반 공개의 위험만 떠안는다. 8443·10000 은 두세 번째 앱
    자리라 경로로 가른다."""
    if int(https_port) == 443:
        if path and str(path).strip().strip("/"):
            raise L.LiveConfigError(
                f"443 에는 경로를 지정하지 않는다 — 443 은 앱 하나를 **루트**에 올리는 자리다. "
                f"경로로 가르고 싶으면 443 을 비워 두고 8443·10000 을 써라(그쪽은 경로 기반이라 "
                f"앱이 깨질 수 있고, {PATH_WARNING.split('—')[0].strip()})"
            )
        return "/"
    raw = str(path or f"/{project_id}").strip()
    raw = "/" + raw.strip("/")
    if raw == "/":
        raise L.LiveConfigError(
            f"{https_port} 에서 루트(/)는 쓸 수 없다 — 같은 포트에 앱이 하나뿐이면 443 을 써라."
        )
    return raw


def pick_funnel_port(taken) -> int:
    """비어 있는 Funnel 포트. 443 을 먼저 쓴다. 셋 다 차면 거부하고 **왜 셋뿐인지** 말한다."""
    used = {int(t) for t in (taken or [])}
    for p in FUNNEL_PORTS:
        if p not in used:
            return p
    raise L.LiveConfigError(
        "Funnel 로 공개할 포트가 없다. **Tailscale Funnel 이 허용하는 포트는 443·8443·10000 "
        "셋뿐이고**(marina 의 제약이 아니다) 셋 다 차 있다. 앱을 더 공개하려면 도메인을 사서 "
        "Cloudflare 터널을 쓰거나(`marina live expose <앱> --cloudflare --domain ...`), "
        "쓰지 않는 공개를 `marina live unexpose <앱>` 으로 내려라."
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


def tunnel_target(service: str, container_port: int) -> str:
    """Cloudflare 터널 ingress 가 가리킬 주소. **컨테이너 DNS** 다 —
    `127.0.0.1` 로 쓰면 그건 cloudflared **컨테이너 자신**이라 아무것도 없다.
    cloudflared 는 같은 compose 네트워크에 있으므로 서비스명으로 닿는다."""
    return f"http://{service}:{int(container_port)}"


def cloudflared_service_lines(project_id: str, domain: str, service: str,
                              container_port: int) -> list:
    """live overlay 의 **services 영역에 끼워 넣을** cloudflared 블록(줄 목록).

    문자열로 돌려주고 overlay 뒤에 붙이면 안 된다 — build_overlay 는 끝에 top-level
    `networks:` 를 붙이므로 cloudflared 가 **네트워크 정의**로 들어가 compose 가
    `networks.cloudflared additional properties ... not allowed` 로 거부한다(실측).

    **live 세션에서만** 들어간다 — 터널 하나에 커넥터가 여럿이면 Cloudflare 가 공개
    요청을 그중 아무 데로나 보낸다(홈서버 구현에서 실측). 개발 워크트리마다 커넥터가
    뜨면 공개 트래픽이 무작위 워크트리로 들어간다.
    """
    if not domain or not service or not container_port:
        return []
    return [
        "  cloudflared:",
        "    image: cloudflare/cloudflared:latest",
        '    command: ["tunnel", "--no-autoupdate", "run"]',
        "    restart: unless-stopped",
        "    env_file:",
        f"      - {json.dumps(str(secrets_file(project_id)))}",
        "    labels:",
        f'      {json.dumps(L.LIVE_LABEL)}: "1"',
        f"      {json.dumps(L.PROJECT_LABEL)}: {json.dumps(project_id)}",
    ]
    # 환경변수로 도메인·백엔드를 넘기지 **않는다**: 토큰 터널은 ingress 를 Cloudflare 가
    # 관리하므로(remote-managed) cloudflared 는 그런 변수를 읽지 않고, 레포 어디에도 읽는
    # 코드가 없다 — 읽히지 않는 설정은 "설정했으니 됐겠지" 라는 거짓 확신만 만든다.
    # 사용자가 Cloudflare 에 입력할 주소는 expose 출력과 expose.json 이 알려준다.


def missing_cloudflare_secrets(project_id: str) -> list:
    """Cloudflare 공개가 설정됐는데 비밀 파일이 없거나 토큰이 비었으면 그 이유들.

    compose 에 맡기면 `env file ... not found` 라는 알아듣기 어려운 말로 기동이 깨진다.
    이 경로는 **백업에서 secrets.env 가 빠진 복원** 에서 정확히 발생한다(L3 결정 4).
    """
    cf = expose_config(project_id).get("cloudflare") or {}
    if not cf.get("domain"):
        return []
    p = secrets_file(project_id)
    if not p.exists():
        return [f"{p} 가 없다 — Cloudflare 터널 토큰이 사라졌다. "
                f"`marina live expose {project_id} --cloudflare --domain {cf.get('domain')} "
                f"--token ...` 로 다시 넣거나, 공개를 쓰지 않으려면 "
                f"`marina live unexpose {project_id}`."]
    try:
        text = p.read_text(encoding="utf-8")
    except OSError as exc:
        return [f"{p} 를 읽지 못했다: {exc}"]
    if "TUNNEL_TOKEN=" not in text or not text.split("TUNNEL_TOKEN=", 1)[1].strip():
        return [f"{p} 에 TUNNEL_TOKEN 이 비어 있다 — cloudflared 가 터널에 붙지 못한다."]
    return []


def _project_using_tunnel(tunnel_id: str, exclude: str = ""):
    """그 터널을 이미 쓰고 있는 다른 프로젝트 id. 없으면 None.

    ~/.marina/*/live/expose.json 을 훑는다 — 레지스트리가 아니라 공개 설정이 진실이다
    (프로젝트를 레지스트리에서 지웠는데 공개가 남아 있는 경우도 잡아야 한다)."""
    home = L.marina_home()
    if not home.is_dir():
        return None
    for child in sorted(home.iterdir()):
        if not child.is_dir() or child.name == exclude:
            continue
        f = child / L.LIVE_SESSION / "expose.json"
        if not f.exists():
            continue
        try:
            cf = (json.loads(f.read_text(encoding="utf-8")) or {}).get("cloudflare") or {}
        except Exception:
            continue
        if str(cf.get("tunnel") or "") == str(tunnel_id):
            return child.name
    return None


def _controller(controller=None):
    if controller is not None:
        return controller
    from marina_remote import RemoteController
    return RemoteController(marina_home=L.marina_home())


def _taken_funnel_ports(status) -> list:
    """이미 쓰이는 Funnel 포트 — live 가 쥔 것 **과** marina 자신의 리스너가 쥔 것.

    후자를 빼먹으면 대시보드가 443 에 있는데 live 가 거기 얹어 **대시보드를 공개해 버린다.**
    """
    live = [int(r.get("httpsPort") or 0) for r in (status.get("liveRoutes") or [])]
    live_keys = {(int(r.get("httpsPort") or 0), str(r.get("path") or ""))
                 for r in (status.get("liveRoutes") or [])}
    own = [int(r.get("httpsPort") or 0) for r in (status.get("routes") or [])
           if (int(r.get("httpsPort") or 0), str(r.get("path") or "")) not in live_keys]
    return live + own


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
            out["url"] = (f"https://{host}{r['path']}" if int(r["httpsPort"]) == 443
                          else f"https://{host}:{r['httpsPort']}{r['path']}")
            if out["mode"] == "funnel" and int(r["httpsPort"]) != 443:
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
    # 같은 프로젝트를 두 번 공개하지 않는다 — 포트가 비어 있으면 조용히 **두 번째 공개
    # 주소**가 생겨서, 내렸다고 생각한 주소가 살아 있는 상태가 된다.
    mine = expose_config(project_id)
    if mine.get("httpsPort") and mine.get("path"):
        for r in (status.get("routes") or []):
            if int(r.get("httpsPort") or 0) == int(mine["httpsPort"]) \
                    and str(r.get("path") or "") == str(mine["path"]):
                raise L.LiveConfigError(
                    f"'{project_id}' 는 이미 공개돼 있다 "
                    f"({mine['httpsPort']}{mine['path']}). 바꾸려면 "
                    f"`marina live unexpose {project_id}` 로 먼저 내려라."
                )
    port = pick_funnel_port(_taken_funnel_ports(status))
    want = funnel_path(project_id, path, port)
    for r in (status.get("routes") or []):
        if int(r.get("httpsPort") or 0) == port and str(r.get("path") or "") == want:
            raise L.LiveConfigError(
                f"{port} 의 경로 {want} 는 이미 공개돼 있다. 다른 --path 를 쓰거나 "
                f"`marina live unexpose` 로 먼저 내려라."
            )
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
    url = f"https://{host}{want}" if port == 443 else f"https://{host}:{port}{want}"
    warnings = []
    if port == 443:
        warnings.append(
            "443 을 이 앱이 쥐었다. 그 동안 대시보드 원격 접근(`marina remote serve|funnel`)은 "
            "443 에 올릴 수 없다 — AllowFunnel 이 host:port 단위라 올리는 순간 대시보드까지 "
            "인터넷에 열린다. 대시보드는 Tailscale 사설망에서 <기계>:3900 으로 그냥 닿는다."
        )
    else:
        warnings.append(PATH_WARNING)
    return {
        "mode": "funnel", "httpsPort": port, "path": want,
        "url": url,
        "warnings": warnings,
    }


def expose_cloudflare(project_id: str, domain: str, creds: dict, service: str,
                      container_port: int, controller=None, call=None) -> dict:
    """도메인 + Cloudflare 터널. 자격증명 넷이 다 있어야 **아무것도 만들기 전에** 시작한다."""
    if not str(domain or "").strip():
        raise L.LiveConfigError("--domain 이 필요하다 (예: app.example.com).")
    if not service or not container_port:
        raise L.LiveConfigError(
            "터널이 가리킬 서비스와 컨테이너 포트를 알 수 없다. compose 의 ports: 에 "
            "포트를 선언하거나 --service 로 골라라."
        )
    validate_cloudflare(creds)
    creds_full = {k: str(creds[k]).strip() for k in CLOUDFLARE_REQUIRED}
    # **터널은 프로젝트마다 하나다.** 두 live 프로젝트가 한 터널을 공유하면 각자 자기
    # compose 네트워크에서 cloudflared 를 띄워 **커넥터가 둘**이 된다. Cloudflare 는
    # 요청을 그중 아무 데로나 보내는데(실측), A 의 커넥터는 B 의 서비스를 DNS 로 찾을 수
    # 없다 — 다른 네트워크다. 그래서 절반이 502 가 된다. 홈서버 테라폼은 스택 하나에
    # 커넥터 하나·앱 여러 개라 이 문제가 없지만, live 는 프로젝트가 격리 단위라 다르다.
    # **아무것도 만들기 전에** 막는다(비밀 파일도 쓰기 전이다).
    other = _project_using_tunnel(creds_full["tunnel"], exclude=project_id)
    if other:
        raise L.LiveConfigError(
            f"터널 {creds_full['tunnel']} 은 이미 '{other}' 가 쓰고 있다. 한 터널을 두 "
            f"프로젝트가 쓰면 커넥터가 둘 생기고, Cloudflare 가 요청을 아무 커넥터로나 "
            f"보내는데 서로 다른 compose 네트워크라 상대 서비스를 못 찾아 절반이 502 가 "
            f"된다. **프로젝트마다 터널을 따로 만들어라**(Cloudflare 에서 새 터널을 하나 "
            f"더 만들면 된다 — 도메인·zone 은 공유해도 괜찮다)."
        )
    write_secrets(project_id, {"TUNNEL_TOKEN": creds_full["token"]})
    cfg = dict(expose_config(project_id))
    cfg["cloudflare"] = {
        "domain": str(domain).strip(),
        "zone": str(creds["zone"]).strip(),
        "account": str(creds["account"]).strip(),
        "tunnel": str(creds["tunnel"]).strip(),
        "service": str(service),
        "containerPort": int(container_port),
    }
    save_expose_config(project_id, cfg)
    target = tunnel_target(service, container_port)
    # DNS 레코드와 터널 ingress 를 **직접 만든다.** 커넥터만 띄우고 "공개됐다" 고 말하면
    # 거짓이다 — 토큰 터널은 ingress 가 Cloudflare 쪽에 있어서, 그게 없으면 트래픽이 흐르지
    # 않는다. 홈서버 테라폼이 이미 둘을 만드는데 여기서 안 만들 이유가 없다.
    # 실패하면 그대로 올린다: "만들었다" 와 "만들지 못했다" 를 섞으면 안 된다.
    import marina_live_cloudflare as CF
    dns = CF.ensure_dns(creds_full, domain, call=call)
    ingress = CF.ensure_ingress(creds_full, domain, target, call=call)
    return {
        "mode": "cloudflare",
        "domain": cfg["cloudflare"]["domain"],
        "url": f"https://{cfg['cloudflare']['domain']}",
        "secrets": str(secrets_file(project_id)),
        "target": target,
        "dns": dns,
        "ingress": ingress,
        "warnings": [
            "cloudflared 는 live 세션에만 뜬다 — 개발 워크트리에서 같은 터널의 커넥터를 띄우면 "
            "Cloudflare 가 공개 요청을 그중 아무 데로나 보낸다(실측).",
            f"{secrets_file(project_id)} 는 백업 목록에 들어 있어야 한다 — "
            f"`marina live backup-paths {project_id}` 로 확인해라.",
            f"커넥터는 다음 기동에 뜬다: marina live up {project_id} "
            f"(그때까지 도메인은 502 를 돌려준다)",
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
    if removed:
        # 디스크의 overlay 는 지운 secrets.env 를 계속 참조한다. `up` 은 overlay 를 다시
        # 써서 자기 치유하지만 `restart`·`logs` 는 **낡은 overlay** 를 읽어
        # `env file ... not found` 로 깨진다(실측). 생성물이므로 지우는 것이 맞다.
        L.live_overlay_path(project_id).unlink(missing_ok=True)
    return {"removed": removed,
            "note": "로컬 접근은 그대로다 — 선언 포트와 게이트웨이는 공개와 무관하다. "
                    "overlay 는 다음 `marina live up` 이 다시 만든다."}
