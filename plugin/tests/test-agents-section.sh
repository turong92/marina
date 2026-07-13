#!/usr/bin/env bash
# A1 — 카드 AGENTS 섹션: 워크트리에서 도는 Claude/Codex 세션 가시화.
# 1) 백엔드 단위: 가짜 ~/.claude/projects·claude-code-sessions·codex 구조로 수집 검증(매칭·ts·preview 80자 절단·7일 필터·최대 3개)
# 2) 실서버: /api/worktrees payload 에 agents 노출
# 3) 프론트: AGENTS 라벨·Claude/Codex 칩·별도 접힘 Set·문법
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SCR="$HERE/../scripts"
TMP="$(mktemp -d)"; TMP="$(cd "$TMP" && pwd -P)"   # macOS /var → /private/var 심링크 정렬(서버가 resolve() 를 쓴다)
trap 'rm -rf "$TMP"' EXIT

# ── 1) 백엔드 단위 ──
FAKE_HOME="$TMP/home"
SESS_DIR="$FAKE_HOME/claude-code-sessions/app/win"
PROJ_DIR="$FAKE_HOME/claude-projects"
CODEX_HOME_DIR="$FAKE_HOME/codex"
mkdir -p "$SESS_DIR" "$PROJ_DIR" "$CODEX_HOME_DIR/sessions"

WT="$TMP/worktree-a"; mkdir -p "$WT"
WT2="$TMP/worktree-b"; mkdir -p "$WT2"

python3 - "$SCR" "$SESS_DIR" "$PROJ_DIR" "$CODEX_HOME_DIR" "$WT" "$WT2" <<'PY'
import sys, os, json, time, re

scr, sess_dir, proj_dir, codex_home, wt, wt2 = sys.argv[1:7]
os.environ["CLAUDE_DESKTOP_SESSIONS_DIR"] = sess_dir
os.environ["CLAUDE_PROJECTS_DIR"] = proj_dir
os.environ["CODEX_HOME"] = codex_home
sys.path.insert(0, scr)
import marina_sessions as ms
from pathlib import Path

now = time.time()

def write_session(name, cli_id, worktree_path, title, mtime):
    p = Path(sess_dir) / f"local_{name}.json"
    json.dump({"cliSessionId": cli_id, "worktreePath": worktree_path, "title": title}, open(p, "w"))
    os.utime(p, (mtime, mtime))
    return p

def write_transcript(worktree_path, cli_id, lines):
    slug = re.sub(r"[/.]", "-", worktree_path)
    d = Path(proj_dir) / slug
    d.mkdir(parents=True, exist_ok=True)
    (d / f"{cli_id}.jsonl").write_text("\n".join(lines) + "\n", encoding="utf-8")

# 매칭 세션(가장 최근) — preview 대상, 긴 텍스트 → 80자 절단 확인
write_session("recent", "cli-recent", wt, "최근 세션", now)
long_text = "가" * 120
write_transcript(wt, "cli-recent", [
    json.dumps({"type": "user", "message": {"role": "user", "content": [{"type": "text", "text": "질문"}]}}),
    json.dumps({"type": "assistant", "message": {"role": "assistant", "content": [{"type": "text", "text": long_text}]}}),
])

# 최대 3개 캡 — extra1(가장 오래됨, 탈락) < extra2 < extra3 < recent(now)
write_session("extra1", "cli-extra1", wt, "extra1", now - 40)
write_session("extra2", "cli-extra2", wt, "extra2", now - 30)
write_session("extra3", "cli-extra3", wt, "extra3", now - 20)

# 7일↑ 미활동 — 제외돼야 함
write_session("old", "cli-old", wt, "오래된 세션", now - 8 * 86400)

# 다른 워크트리 — 매칭 안 돼야 함
write_session("other", "cli-other", "/some/other/wt", "다른 워크트리", now)

agents = ms.agents_payload(Path(wt), refresh=True)
assert len(agents) == 3, f"max 3개여야: {agents}"
titles = [a["title"] for a in agents]
assert titles == ["최근 세션", "extra3", "extra2"], f"ts 내림차순·최대3(extra1 탈락) 실패: {titles}"
assert "오래된 세션" not in titles and "다른 워크트리" not in titles

recent = agents[0]
assert recent["source"] == "claude"
assert isinstance(recent["ts"], int) and recent["ts"] > 0
assert recent.get("preview"), f"preview 없음: {recent}"
assert len(recent["preview"]) == 80, f"preview 80자 절단 실패(len={len(recent['preview'])})"
assert "preview" not in agents[1], "트랜스크립트 없는 세션은 preview 생략"
print("ok claude_agent_sessions/agents_payload (매칭·ts·preview 80자·7일 필터·최대3)")

# ── 행 클릭 뷰어(agent_transcript) — sid 노출 + user/assistant 텍스트 턴 + sid 검증 ──
assert recent.get("sid") == "cli-recent", f"claude sid 노출 실패: {recent}"
tr = ms.agent_transcript(Path(wt), "claude", "cli-recent")
assert [t["role"] for t in tr["turns"]] == ["user", "assistant"], tr
assert tr["turns"][0]["text"] == "질문", tr
try:
    ms.agent_transcript(Path(wt), "claude", "../evil")
    raise AssertionError("sid 형식 검증 뚫림")
except ValueError:
    pass
print("ok agent_transcript (claude — 턴 추출·sid 형식 검증)")

# ── Codex: title+ts 만(preview 생략) ──
index_path = Path(codex_home) / "session_index.jsonl"
index_path.write_text(json.dumps({"id": "codex-1", "thread_name": "코덱스 세션"}) + "\n", encoding="utf-8")
rollout = Path(codex_home) / "sessions" / "rollout-1.jsonl"
rollout.write_text(json.dumps({
    "type": "session_meta",
    "payload": {"cwd": wt2, "id": "codex-1", "timestamp": "2026-07-01T00:00:00Z"},
}) + "\n" + json.dumps({
    "type": "response_item",
    "payload": {"type": "message", "role": "assistant", "content": [{"type": "output_text", "text": "코덱스 응답"}]},
}) + "\n", encoding="utf-8")

codex_agents = ms.agents_payload(Path(wt2), refresh=True)
assert len(codex_agents) == 1, codex_agents
cx = codex_agents[0]
assert cx["source"] == "codex" and cx["title"] == "코덱스 세션", cx
assert isinstance(cx["ts"], int) and cx["ts"] > 0
assert "preview" not in cx, f"codex 는 preview 생략이어야: {cx}"
assert cx.get("sid") == "codex-1", f"codex sid 노출 실패: {cx}"
trx = ms.agent_transcript(Path(wt2), "codex", "codex-1")
assert [t["text"] for t in trx["turns"]] == ["코덱스 응답"], trx
print("ok codex_agent_sessions (title+ts·sid, rollout 턴 추출)")
PY

# ── 2) 실서버: /api/worktrees payload 에 agents 노출 ──
P="$TMP/proj"; mkdir -p "$P"
git -C "$P" init -q
git -C "$P" config user.email "t@example.invalid"
git -C "$P" config user.name "Marina Test"
printf 'ok\n' > "$P/r"; git -C "$P" add r; git -C "$P" commit -qm init

MARINA_HOME="$TMP/marina-home"; mkdir -p "$MARINA_HOME"
printf '{"projects":[{"id":"proj","root":"%s","subrepos":[],"worktreeGlobs":[".claude/worktrees/*"]}],"schemaVersion":1}\n' "$P" > "$MARINA_HOME/projects.json"

SRV_SESS_DIR="$TMP/srv-sessions/app/win"; mkdir -p "$SRV_SESS_DIR"
python3 -c "
import json, os, time
p = os.path.join('$SRV_SESS_DIR', 'local_x.json')
json.dump({'cliSessionId': 'cli-x', 'worktreePath': '$P', 'title': 'A1 서버 노출 세션'}, open(p, 'w'))
os.utime(p, (time.time(), time.time()))
"

PORT="$(python3 - <<'PY' || exit $?
import socket, sys
s = socket.socket()
try:
    s.bind(("127.0.0.1", 0))
except PermissionError:
    sys.exit(42)
print(s.getsockname()[1])
s.close()
PY
)" || { code=$?; [[ "$code" == "42" ]] && { echo "SKIP test-agents-section 서버구간 (localhost bind unavailable)"; exit 0; }; exit "$code"; }

MARINA_CONTROL_PORT=$PORT MARINA_CONTROL_HOST=127.0.0.1 MARINA_HOME="$MARINA_HOME" \
CLAUDE_DESKTOP_SESSIONS_DIR="$TMP/srv-sessions" CLAUDE_PROJECTS_DIR="$TMP/srv-nonexistent-projects" \
python3 "$SCR/marina-control.py" >/dev/null 2>&1 &
SRV=$!
cleanup(){ kill "$SRV" 2>/dev/null || true; }
trap 'cleanup; rm -rf "$TMP"' EXIT
b="http://127.0.0.1:$PORT"; H=(-H "Origin: $b")
for _ in $(seq 1 50); do curl -s -o /dev/null "$b/api/worktrees" && break; sleep 0.1; done

curl -s "${H[@]}" "$b/api/worktrees?refresh=1" | python3 -c "
import json, sys
d = json.load(sys.stdin)
entry = next((w for w in d['worktrees'] if w['root'] == '$P'), None)
assert entry is not None, d
agents = entry.get('agents') or []
assert any(a['title'] == 'A1 서버 노출 세션' and a['source'] == 'claude' for a in agents), entry
print('ok /api/worktrees agents 노출')
" || { echo "FAIL: 실서버 /api/worktrees 에 agents 없음"; exit 1; }

kill "$SRV" 2>/dev/null || true
wait "$SRV" 2>/dev/null || true

# ── 3) 프론트 ──
J="$SCR/marina-web/app-5-sessions.js"
# 형 통일 지시(2026-07-13) — AGENTS 접힘은 별도 Set 이 아니라 카드 펼침(expandedRoots)을 그대로 따르고, 행 클릭=대화 뷰어.
! grep -q "expandedAgentRoots" "$J" || { echo "FAIL: 별도 Set 잔재 — SERVICES 와 통일(expandedRoots) 계약 위반"; exit 1; }
grep -q "openAgentTranscript" "$J" || { echo "FAIL: 행 클릭=대화 뷰어(openAgentTranscript) 배선 없음"; exit 1; }
grep -q "data-agent-sid" "$J" || { echo "FAIL: 행 sid(식별자) 없음 — 클릭 열람 불가"; exit 1; }
grep -q "openAgentTranscript" "$SCR/marina-web/app-6-modals.js" || { echo "FAIL: 대화 뷰어 모달 없음"; exit 1; }
grep -q "AGENTS (" "$J" || { echo "FAIL: AGENTS 섹션 라벨 없음"; exit 1; }
grep -q "data-agents-toggle" "$J" || { echo "FAIL: AGENTS 접힘 토글 없음"; exit 1; }
grep -q "'Codex' : 'Claude'" "$J" || { echo "FAIL: Claude/Codex 텍스트칩 없음(풀네임 — 형 피드백 2026-07-13)"; exit 1; }
grep -q "svc-tail" "$J" || { echo "FAIL: preview 행에 svc-tail 재사용 없음"; exit 1; }
! grep -qE "🤖|👤|🔵" "$J" || { echo "FAIL: 이모지 사용 금지 위반"; exit 1; }

if command -v node >/dev/null 2>&1; then
  for f in "$SCR/marina-web/"app-*.js; do
    node --check "$f" || { echo "FAIL: 문법 오류 $f"; exit 1; }
  done
fi

echo "PASS test-agents-section"
