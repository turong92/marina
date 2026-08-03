#!/usr/bin/env bash
# claude/codex **CLI 자체** 버전 감지. marina_update.py 와 다르다 — 저쪽은 marina 플러그인의 SHA,
# 여기는 하네스 CLI 의 버전이다. 새 버전은 터미널에서 CLI 를 띄울 때만 보였고, 대시보드·모바일에서는
# 알 길이 없었다(형 환경은 installMethod=native + autoUpdates=false 라 자동으로 올라가지도 않는다).
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"   # 실 ~/.marina 격리

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SCR="$HERE/../scripts"

PYTHONPATH="$SCR" python3 - <<'PY'
import marina_cliver as cv

# ── 버전 파싱 — 두 CLI 의 실제 출력 형식 ──
assert cv._parse_version("2.1.220 (Claude Code)") == "2.1.220"
assert cv._parse_version("codex-cli 0.146.0") == "0.146.0"
assert cv._parse_version("0.146.0\n") == "0.146.0"
assert cv._parse_version("2.2.0-beta.1 (Claude Code)") == "2.2.0-beta.1"
assert cv._parse_version("") == ""
assert cv._parse_version("command not found") == ""

# ── behind 판정 — 숫자 세그먼트 비교. 문자열 비교면 2.1.9 > 2.1.10 으로 오판한다 ──
assert cv._version_behind("2.1.220", "2.2.0") is True
assert cv._version_behind("2.1.9", "2.1.10") is True
assert cv._version_behind("2.2.0", "2.2.0") is False
assert cv._version_behind("2.3.0", "2.2.0") is False      # 앞서 있으면(로컬 빌드) 배너 없음
assert cv._version_behind("", "2.2.0") is False           # 설치본을 모르면 배너 없음
assert cv._version_behind("2.2.0", "") is False           # 네트워크 실패 → 배너 없음
assert cv._version_behind("2.1.220", "2.1.220") is False

# ── 설치 방식 → 업데이트 명령 ──
assert cv._update_cmd("claude", "native") == ["claude", "update"]
assert cv._update_cmd("claude", "global") == ["npm", "i", "-g", "@anthropic-ai/claude-code"]
assert cv._update_cmd("claude", "npm") == ["npm", "i", "-g", "@anthropic-ai/claude-code"]
assert cv._update_cmd("codex", "brew") == ["brew", "upgrade", "codex"]
assert cv._update_cmd("codex", "npm") == ["npm", "i", "-g", "@openai/codex"]
assert cv._update_cmd("codex", "unknown") is None
assert cv._update_cmd("codex", "") is None

# ── codex 설치 방식 판별 (경로로) ──
assert cv._codex_method("/opt/homebrew/bin/codex") == "brew"
assert cv._codex_method("/usr/local/bin/codex") == "brew"
assert cv._codex_method("/Users/x/.nvm/versions/node/v22/bin/codex") == "npm"
assert cv._codex_method("") == ""

# ── 네트워크 실패는 조용히: behind=False, latest=None ──
cv._LATEST_CACHE.clear(); cv._STATUS_CACHE.clear()
orig_fetch, orig_ver = cv._fetch_latest, cv._installed_version
cv._fetch_latest = lambda pkg: None
cv._installed_version = lambda h: "1.0.0"
try:
    st = cv.cli_status(refresh=True)
    assert st, "설치본이 있으면 항목이 나와야 한다"
    for name, item in st.items():
        assert item["behind"] is False, f"{name}: 최신을 모르면 behind 는 False"
        assert item["latest"] is None, f"{name}: latest 는 None"
finally:
    cv._fetch_latest, cv._installed_version = orig_fetch, orig_ver
    cv._LATEST_CACHE.clear(); cv._STATUS_CACHE.clear()

# ── CLI 가 없으면 항목 자체를 안 낸다 (배너를 띄울 근거가 없다) ──
orig_ver = cv._installed_version
cv._installed_version = lambda h: ""
try:
    cv._STATUS_CACHE.clear()
    assert cv.cli_status(refresh=True) == {}, "설치 안 된 하네스는 항목이 없어야 한다"
finally:
    cv._installed_version = orig_ver
    cv._STATUS_CACHE.clear()

# ── behind 계산이 실제로 붙어 있다 ──
cv._LATEST_CACHE.clear(); cv._STATUS_CACHE.clear()
orig_fetch, orig_ver, orig_cfg = cv._fetch_latest, cv._installed_version, cv._claude_config
cv._fetch_latest = lambda pkg: "99.0.0"
cv._installed_version = lambda h: "1.0.0"
cv._claude_config = lambda: {"installMethod": "native", "autoUpdates": False}
try:
    st = cv.cli_status(refresh=True)
    assert st["claude"]["behind"] is True
    assert st["claude"]["latest"] == "99.0.0"
    assert st["claude"]["method"] == "native"
    assert st["claude"]["cmd"] == "claude update"
    assert st["claude"]["autoUpdates"] is False
finally:
    cv._fetch_latest, cv._installed_version, cv._claude_config = orig_fetch, orig_ver, orig_cfg
    cv._LATEST_CACHE.clear(); cv._STATUS_CACHE.clear()

# ── busy 가드: 돌고 있는 세션이 있으면 실행 파일을 갈아치우지 않는다 ──
assert isinstance(cv.busy_agents("claude"), list)

orig_busy, orig_run = cv.busy_agents, cv._run_update
ran = []
cv.busy_agents = lambda source: [{"title": "asdf", "status": "running"}]
cv._run_update = lambda cmd: ran.append(cmd) or ""
try:
    try:
        cv.cli_update("claude")
        raise AssertionError("busy 인데 업데이트가 실행됐다")
    except cv.BusyError as exc:
        assert exc.busy and exc.busy[0]["status"] == "running"
    assert not ran, "busy 인데 명령이 실행됐다"
finally:
    cv.busy_agents, cv._run_update = orig_busy, orig_run

# ── 유휴면 실행한다 ──
orig_busy, orig_run, orig_ver = cv.busy_agents, cv._run_update, cv._installed_version
ran = []
cv.busy_agents = lambda source: []
cv._run_update = lambda cmd: ran.append(cmd) or "updated"
cv._installed_version = lambda h: "99.0.0"
cv._STATUS_CACHE.clear()
try:
    out = cv.cli_update("codex")
    assert ran and ran[0][0] in ("brew", "npm"), ran
    assert out["ok"] is True and out["harness"] == "codex"
    assert out["installed"] == "99.0.0"
finally:
    cv.busy_agents, cv._run_update, cv._installed_version = orig_busy, orig_run, orig_ver
    cv._STATUS_CACHE.clear()

# ── 알 수 없는 하네스는 거부 ──
try:
    cv.cli_update("gemini")
    raise AssertionError("알 수 없는 하네스가 통과했다")
except ValueError:
    pass

print("PASS marina_cliver: 파싱 · behind · 설치방식 · 무네트워크 · busy 가드 · 실행")
PY

# ── 라우트·페이로드 배선 ──
PYTHONPATH="$SCR" python3 - <<'PY'
import marina_handler as mh
import marina_update as mu

src = open(mh.__file__, encoding="utf-8").read()
assert '"/mobile/api/update-status"' in src, "모바일 update-status 라우트가 없다"
assert '"/mobile/api/cli-update"' in src, "cli-update 라우트가 없다"
assert "BusyError" in src, "busy 가드가 라우트에 없다"

payload = mu.update_status()
assert "cli" in payload, "update_status 에 cli 키가 없다"
assert isinstance(payload["cli"], dict)
print("PASS 배선: /api/update-status 의 cli 키 + 모바일 라우트")
PY

echo "PASS test-cli-version"
