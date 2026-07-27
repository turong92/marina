#!/usr/bin/env bash
# 모바일 큐/질문 surface 실브라우저 e2e — Aside 로컬 검증(문서/수동). CI 아님(Aside 앱 + `~/.local/bin/aside` 필요).
# 없으면 SKIP. 2026-07-26 실측 통과:
#   A 큐 문신 자동정리 — 죽은 tid(state.terms 결석)+age>4s pending 을 폴 render 가 failed 로 전환
#   B 탭 취소 — ✕ 로 pending 레코드 제거 + 말풍선 사라짐(↻ 재시도 버튼도 렌더)
#   C 질문 surface — 훅 상태파일(ts 포함) → 세션리스트 ❓마커 + 구조화 질문카드
set -uo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"   # 실 환경 격리
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO="$(cd -- "$HERE/../.." && pwd -P)"
ASIDE="$HOME/.local/bin/aside"; PORT=3910; TOK=e2etoken
command -v "$ASIDE" >/dev/null 2>&1 || { echo "SKIP: aside CLI 없음"; exit 0; }
SID="334a1b6b-cefe-4b4d-9232-2ed5581b97c0"   # 아무 살아있는 claude 세션이면 됨(없으면 A/B 만이라도)
TMP="$(mktemp -d)"; QF="$HOME/.marina/agent-questions/claude-$SID.json"
# 이 e2e 는 살아있는 실제 세션을 봐야 해서 실 MARINA_HOME 을 쓴다 — 그래서 뒷정리가 특히 중요하다.
# 데몬은 **띄운 pid 로만** 끊는다. 예전엔 pkill -f "MARINA_CONTROL_PORT=$PORT" 였는데 그건
# 환경변수라 argv 에 안 나와 절대 매치되지 않았고, 데몬이 실 MARINA_HOME 을 쥔 채 유출됐다
# (포트 3910 을 점유한 고아 프로세스로 발견).
DAEMON_PID=""; QF_MINE=""
cleanup() {
  [ -n "$DAEMON_PID" ] && kill "$DAEMON_PID" 2>/dev/null
  [ -n "$QF_MINE" ] && rm -f "$QF"          # 내가 만든 질문 파일만 지운다(실 세션 상태 보호)
  rm -rf "$TMP"
}
trap cleanup EXIT
MARINA_CONTROL_PORT=$PORT MARINA_CONTROL_HOST=127.0.0.1 MARINA_HOME="$HOME/.marina" \
  MARINA_MOBILE_TOKEN="$TOK" MARINA_AUTH_DB="$TMP/a.db" nohup python3 "$REPO/plugin/scripts/marina-control.py" >"$TMP/c.log" 2>&1 &
DAEMON_PID=$!
sleep 3
curl -s -o /dev/null --max-time 5 "http://127.0.0.1:$PORT/mobile" || { echo "FAIL :$PORT 미기동"; exit 1; }
[ -e "$QF" ] && { echo "SKIP: 실제 pending 질문이 이미 있다 — 덮어쓰지 않는다"; exit 0; }
QF_MINE=1
mkdir -p "$(dirname "$QF")"
python3 -c "import json,time;open('$QF','w').write(json.dumps({'sid':'$SID','questions':[{'question':'E2E?','header':'확인','options':[{'label':'응','description':'d'}]}],'toolUseId':'e2e','ts':time.time()}))"

read -r -d '' JS <<'EOF'
const sleep=ms=>new Promise(r=>setTimeout(r,ms));
const p=await openTab('http://127.0.0.1:3910/mobile?token=e2etoken');
await sleep(3800);
await p.evaluate(async()=>{try{await load({});}catch(e){}});
await sleep(1500);
const out={};
out.queue=await p.evaluate(async()=>{
  const s=(state.sessions||[]).find(x=>x.kind==='agent')||(state.sessions||[])[0]; if(!s)return{skip:1};
  selectedSessionKey=s.key; if(typeof showChat==='function')showChat();
  pendingTurns[s.key]=[{id:'e2e1',role:'user',text:'stuck',baseline:0,pending:true,delivery:'queue',createdAt:Date.now()-10000,tid:'__dead__',target:s.target,root:s.root}];
  render(); await sleep(200);
  const t=document.getElementById('turns'); const rec=(pendingTurns[s.key]||[])[0]||{};
  const failed=rec.failed===true; const cancelBtn=!!t.querySelector('[data-pending-cancel]'); const retryBtn=!!t.querySelector('[data-pending-retry]');
  if(cancelBtn)t.querySelector('[data-pending-cancel]').click(); await sleep(200);
  const removed=!(pendingTurns[s.key]||[]).some(r=>r.id==='e2e1');
  return {ok: failed&&cancelBtn&&retryBtn&&removed, failed,cancelBtn,retryBtn,removed};
});
out.question=await p.evaluate(()=>{
  const s=(state.sessions||[]).find(x=>(x.sid||'').startsWith('334a1b6b')); if(!s)return{skip:1};
  const badge=!!document.querySelector('.session-question-badge,[data-session-question-badge]');
  selectedSessionKey=s.key; if(typeof showChat==='function')showChat(); if(typeof renderLiveQuestion==='function')renderLiveQuestion(s);
  const lq=document.getElementById('liveQuestion'); const card=!!(lq&&/questionCard/.test(lq.innerHTML));
  return {ok: !!(s.pendingQuestion&&badge&&card), pendingQuestion:!!s.pendingQuestion, badge, card};
});
console.log('RESULT='+JSON.stringify(out));
EOF
RES="$("$ASIDE" repl "$JS" 2>&1 | grep -o 'RESULT=.*' | head -1)"
echo "$RES"
python3 - "$RES" <<'PY'
import sys,json
raw=sys.argv[1] if len(sys.argv)>1 else ""
if not raw.startswith("RESULT="): print("SKIP: Aside 결과 없음"); sys.exit(0)
d=json.loads(raw[len("RESULT="):])
bad=[k for k,v in d.items() if not (v.get("ok") or v.get("skip"))]
if bad: print("FAIL:",", ".join(bad)); sys.exit(1)
print("PASS: mobile queue auto-fail/cancel/retry + question marker/card e2e")
PY
