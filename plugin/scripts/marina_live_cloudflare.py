"""Cloudflare 터널 공개의 마지막 두 조각 — DNS 레코드와 터널 ingress.

**왜 marina 가 이걸 하나.** 커넥터(cloudflared)만 띄워 놓고 "공개됐다" 고 말하면 거짓이다.
토큰 터널은 ingress 를 Cloudflare 쪽에서 관리하므로, 사용자가 대시보드에서 호스트명→서비스
매핑을 손으로 만들지 않으면 트래픽이 흐르지 않는다. 홈서버 테라폼 쪽은 그 둘을 이미 만든다
(`cloudflare_dns_record` + `cloudflare_zero_trust_tunnel_cloudflared_config`) — 같은 수준을
여기서도 맞춘다.

**두 가지를 특히 조심한다.**
① ingress PUT 은 설정을 **통째로** 바꾼다. 읽지 않고 쓰면 다른 앱의 공개가 조용히 사라진다.
   그래서 항상 GET → 병합 → PUT 이고, **GET 이 실패하면 쓰지 않는다.**
② 같은 이름에 CNAME 이 아닌 레코드가 있으면 거부한다. 말없이 바꾸면 그 호스트가 가리키던
   것이 사라진다.

표준 라이브러리만 쓴다(레포 규칙). 호출부를 주입받아 테스트가 실제 API 를 안 건드린다.
"""
from __future__ import annotations

import json
import urllib.error
import urllib.request

import marina_live as L

API = "https://api.cloudflare.com/client/v4"
TUNNEL_CNAME_SUFFIX = ".cfargotunnel.com"
CATCH_ALL = {"service": "http_status:404"}


class CloudflareError(Exception):
    """API 가 돌려준 메시지를 그대로 담는다 — 토큰 권한 문제를 찾으려면 원문이 필요하다."""


def api_call(method: str, url: str, token: str, body=None, timeout: float = 15.0):
    data = json.dumps(body).encode("utf-8") if body is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("Authorization", f"Bearer {token}")
    req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            payload = json.loads(resp.read().decode("utf-8") or "{}")
    except urllib.error.HTTPError as exc:
        raw = exc.read().decode("utf-8", "replace")
        try:
            errs = json.loads(raw).get("errors") or []
            msg = "; ".join(str(e.get("message") or e) for e in errs) or raw[:300]
        except Exception:
            msg = raw[:300]
        raise CloudflareError(f"HTTP {exc.code}: {msg}")
    except Exception as exc:
        raise CloudflareError(f"{type(exc).__name__}: {exc}")
    if isinstance(payload, dict) and payload.get("success") is False:
        errs = payload.get("errors") or []
        raise CloudflareError("; ".join(str(e.get("message") or e) for e in errs) or "unknown error")
    return payload


def _call(creds: dict, method: str, url: str, body=None, call=None):
    fn = call or (lambda m, u, t, b=None: api_call(m, u, t, b))
    try:
        return fn(method, url, str(creds["token"]), body)
    except CloudflareError as exc:
        raise L.LiveConfigError(f"Cloudflare API 실패 ({method} {url.split('/v4/')[-1]}): {exc}")


def ensure_dns(creds: dict, domain: str, call=None) -> dict:
    """`<domain>` → `<tunnel>.cfargotunnel.com` CNAME(proxied). 멱등."""
    zone, tunnel = str(creds["zone"]), str(creds["tunnel"])
    want = f"{tunnel}{TUNNEL_CNAME_SUFFIX}"
    listed = _call(creds, "GET", f"{API}/zones/{zone}/dns_records?name={domain}", call=call)
    existing = [r for r in (listed.get("result") or []) if str(r.get("name")) == domain]
    for rec in existing:
        if str(rec.get("type")) != "CNAME":
            raise L.LiveConfigError(
                f"{domain} 에 이미 {rec.get('type')} 레코드가 있다 — marina 가 그것을 CNAME 으로 "
                f"바꾸지 않는다(그 호스트가 가리키던 것이 사라진다). Cloudflare 에서 먼저 정리하거나 "
                f"다른 호스트명을 써라."
            )
    body = {"type": "CNAME", "name": domain, "content": want, "proxied": True}
    if existing:
        rec = existing[0]
        if str(rec.get("content")) == want and bool(rec.get("proxied")) is True:
            return {"action": "unchanged", "name": domain, "content": want}
        _call(creds, "PATCH", f"{API}/zones/{zone}/dns_records/{rec['id']}", body, call=call)
        return {"action": "updated", "name": domain, "content": want, "was": rec.get("content")}
    _call(creds, "POST", f"{API}/zones/{zone}/dns_records", body, call=call)
    return {"action": "created", "name": domain, "content": want}


def ensure_ingress(creds: dict, domain: str, service: str, call=None) -> dict:
    """터널 ingress 에 `<domain> → <service>` 규칙을 **병합**한다.

    PUT 이 설정을 통째로 교체하므로 반드시 GET 먼저다. GET 이 실패하면 **쓰지 않는다** —
    못 읽은 상태로 쓰면 다른 호스트명이 조용히 사라진다.
    """
    account, tunnel = str(creds["account"]), str(creds["tunnel"])
    url = f"{API}/accounts/{account}/cfd_tunnel/{tunnel}/configurations"
    try:
        current = _call(creds, "GET", url, call=call)
    except L.LiveConfigError as exc:
        raise L.LiveConfigError(
            f"터널 설정을 읽지 못해 아무것도 바꾸지 않았다 — 읽지 않고 쓰면 다른 호스트명의 "
            f"공개가 사라진다. 원인: {exc}"
        )
    rules = (((current.get("result") or {}).get("config") or {}).get("ingress")) or []
    kept = [r for r in rules if isinstance(r, dict) and r.get("hostname")
            and str(r.get("hostname")) != domain]
    merged = kept + [{"hostname": domain, "service": str(service)}, dict(CATCH_ALL)]
    _call(creds, "PUT", url, {"config": {"ingress": merged}}, call=call)
    return {"action": "updated", "hostname": domain, "service": str(service),
            "kept": [str(r.get("hostname")) for r in kept]}
