#!/bin/bash
# 시제품: claude auth login 을 tmux 에 띄우고, Aside(u0) 로 승인 → 코드를 파일(600)로만 넘겨 터미널에 붙인다. 코드는 화면·로그에 안 남긴다.
set -u
S=marina-login-renew
W="$(mktemp -d)"; trap 'rm -rf "${W:?}"; tmux kill-session -t "$S" 2>/dev/null' EXIT
chmod 700 "$W"
tmux kill-session -t "$S" 2>/dev/null
tmux new-session -d -s "$S" -x 400 -y 50 "cd ~ && env -u CLAUDECODE -u CLAUDE_CODE_ENTRYPOINT BROWSER=/usr/bin/true claude auth login; sleep 60"
URL=""
for _ in $(seq 1 30); do
  URL=$(tmux capture-pane -p -J -t "$S" | grep -o 'https://claude.com/cai/oauth[^ ]*' | head -1)
  [ -n "$URL" ] && break; sleep 1
done
[ -n "$URL" ] || { echo "주소 못 받음"; exit 1; }
OUT=$(aside repl --account u0 "
const p = await openTab('$URL'); await sleep(3000);
const b = p.getByRole('button', {name: /^(승인|Authorize)\$/});
if (!(await b.count())) { console.log('NO_BUTTON'); } else {
  await b.first().click(); await sleep(5000);
  const t = await p.evaluate(() => document.body.innerText);
  const m = t.match(/[A-Za-z0-9_#-]{40,}/);
  console.log(m ? 'CODE=' + m[0] : 'NO_CODE');
}
await closeTab(p);" 2>&1)
CODE=$(printf '%s\n' "$OUT" | sed -n 's/^CODE=//p' | head -1)
[ -n "$CODE" ] || { echo "코드 못 받음: $(printf '%s\n' "$OUT" | grep -E 'NO_|rror' | head -2)"; exit 1; }
tmux send-keys -t "$S" -l "$CODE"; unset CODE OUT; sleep 1; tmux send-keys -t "$S" Enter
for _ in $(seq 1 20); do
  tmux capture-pane -p -t "$S" | grep -q "Login successful" && { echo "OK"; exit 0; }
  sleep 1
done
echo "성공 문구 없음"; exit 1
