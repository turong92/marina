#!/usr/bin/env bash
# Claude 계정 사용량(5시간/7일)을 **직접** 가져오는 경로.
#
# 형 신고: "codex, claude 사용량 둘 다 안되는 꼴이".
# 원인은 marina 가 써드파티 플러그인(claude-hud)의 캐시 파일을 읽고 있던 것. 그 캐시는 47일째
# 멈춰 있었는데, 따라가 보면: 키체인에 같은 서비스명 항목이 둘 있고(acct=unknown / acct=<사용자>),
# `security find-generic-password -s <svc>` 는 계정을 안 주면 첫 항목만 준다. 첫 항목의 토큰이
# 만료돼 있었고 hud 는 만료면 갱신 없이 포기 → 캐시가 그 시점에 얼어붙었다.
# 그래서 marina 는 직접 가져오되, **항목을 전부 열거해 살아있는 토큰을 고른다.**
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"   # 실 ~/.marina 격리
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SCR="$HERE/../scripts"

PYTHONPATH="$SCR" python3 - <<'PY'
import time

import marina_usage as mu

# ── 키체인 서비스명 규칙 (CLI 와 동일: 기본 디렉터리면 그대로, 커스텀이면 sha256 앞 8자) ──
from pathlib import Path
assert mu.keychain_service_name(Path.home() / ".claude") == "Claude Code-credentials"
custom = mu.keychain_service_name(Path("/tmp/other-claude-dir"))
assert custom.startswith("Claude Code-credentials-") and len(custom.split("-")[-1]) == 8, custom

# ── 만료 판정 ──
future = (time.time() + 3600) * 1000
past = (time.time() - 3600) * 1000
assert mu._alive({"expiresAt": future}) is True
assert mu._alive({"expiresAt": past}) is False
assert mu._alive({}) is True, "만료 정보가 없으면 만료로 치지 않는다(있는 토큰은 써 본다)"

# ── **핵심**: 항목이 여럿이면 만료본을 건너뛰고 살아있는 걸 고른다 ──
#    hud 가 죽은 지점이 정확히 여기다.
orig_accounts, orig_run = mu._keychain_accounts, mu._run
import json as _json
blobs = {
    "unknown": _json.dumps({"claudeAiOauth": {"accessToken": "DEAD", "expiresAt": past}}),
    "sumin":   _json.dumps({"claudeAiOauth": {"accessToken": "LIVE", "expiresAt": future}}),
}
try:
    mu._keychain_accounts = lambda service: ["unknown", "sumin"]
    mu._run = lambda cmd, timeout=5.0: blobs.get(cmd[-1], "") if "-a" in cmd else ""
    assert mu._access_token() == "LIVE", "만료된 첫 항목을 집었다 — hud 와 같은 결함"

    # 전부 만료면 빈 문자열(요청을 아예 안 보낸다)
    mu._keychain_accounts = lambda service: ["unknown"]
    assert mu._access_token() == "", "만료본만 있는데 토큰을 반환했다"
finally:
    mu._keychain_accounts, mu._run = orig_accounts, orig_run

# ── 토큰이 없으면 네트워크를 치지 않는다 ──
orig_tok, orig_fetch = mu._access_token, mu._fetch
called = []
try:
    mu._access_token = lambda: ""
    mu._fetch = lambda token: called.append(token)
    mu._CACHE.clear()
    assert mu.claude_usage_payload(refresh=True) is None
    assert not called, "토큰 없이 요청을 보냈다"
finally:
    mu._access_token, mu._fetch = orig_tok, orig_fetch
    mu._CACHE.clear()

# ── 토큰 갱신은 하지 않는다(refresh_token 회전이 CLI 인증을 깨뜨린다) ──
# 소스에서 단어를 찾는 검사는 "왜 갱신 안 하나"를 적은 주석까지 잡는 오탐이었다. 실제 행동을 본다:
# 나가는 요청이 사용량 조회 GET **하나뿐**이어야 한다(토큰 엔드포인트로 POST 가 없어야 한다).
import urllib.request

sent = []
orig_urlopen = urllib.request.urlopen
try:
    urllib.request.urlopen = lambda req, *a, **k: sent.append(req) or (_ for _ in ()).throw(OSError("차단"))
    mu._CACHE.clear()
    mu._fetch("fake-token")
finally:
    urllib.request.urlopen = orig_urlopen
    mu._CACHE.clear()
assert len(sent) == 1, f"요청이 하나가 아니다: {len(sent)}"
assert sent[0].full_url == mu.USAGE_URL, f"사용량 말고 다른 곳을 친다: {sent[0].full_url}"
assert sent[0].get_method() == "GET", "본문을 실어 보낸다 — 갱신/쓰기 요청일 수 있다"
assert sent[0].data is None, "요청 본문이 있다 — 읽기 전용이 아니다"

print("PASS marina_usage: 서비스명 · 만료판정 · 살아있는 항목 선택 · 무토큰 무요청 · 갱신 안 함")
PY

# ── 배선: 직접 가져오기가 1순위, 플러그인 캐시는 폴백 ──
PYTHONPATH="$SCR" python3 - <<'PY'
import marina_sessions as ms

src = open(ms.__file__, encoding="utf-8").read()
assert "from marina_usage import claude_usage_payload" in src, "직접 가져오기가 배선되지 않았다"
live = src.index("claude_usage_payload")
cache = src.index("CLAUDE_USAGE_CACHE_FILE.read_text")
assert live < cache, "플러그인 캐시를 먼저 읽는다 — 직접 가져오기가 1순위여야 한다"

# codex: 계정 단위여야 한다(워크트리 우선이면 그 워크트리를 안 쓰는 동안 낡은 값이 뜬다)
fn = src[src.index("def _latest_codex_rate_limits"):]
fn = fn[:fn.index("\ndef ", 5)]
glob_at, root_at = fn.index("CODEX_ROLLOUT_DIRS"), fn.index("codex_agent_sessions")
assert glob_at < root_at, "codex 사용량이 아직 워크트리 우선이다"

# 모델별 주간 창이 값이 오면 뜨게 일반화돼 있다
for key in ("opusWeekly", "sonnetWeekly"):
    assert key in src, f"{key} 창이 없다"
print("PASS 배선: 직접 가져오기 1순위 · codex 계정 단위 · 모델별 창")
PY

echo "PASS test-claude-usage"
