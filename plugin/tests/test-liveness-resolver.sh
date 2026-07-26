#!/usr/bin/env bash
# resolve_session_liveness — status(merge_agent_status) + reachable(live_tids) + D3(강등)/D4(승격)
# 을 하나로 묶은 순수 함수. 여러 호출부가 각자 계산하던 걸 여기 하나로 캐논화한다.
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SCRIPTS="$HERE/../scripts"

python3 - "$SCRIPTS" <<'PY'
import sys
from pathlib import Path
scripts = Path(sys.argv[1])
sys.path.insert(0, str(scripts))
import marina_sessions as ms

R = Path('/Users/sumin/work/wt')
fails = []

N_work = {'status': 'working', 'statusTs': 100.0}   # S4 트랜스크립트 working

# D3: working 인데 살아있는 cwd 없음 → idle 강등
r = ms.resolve_session_liveness('claude', 's1', R, native=N_work, event=None, live_cwds=set(), live_tids={})
if r['status'] != 'idle' or r['reachable']:
    fails.append(('D3', r))
if r.get('reason') != '프로세스 없음':
    fails.append(('D3-reason', r))

# working + cwd 있음 → working 유지
r = ms.resolve_session_liveness('claude', 's1', R, native=N_work, event=None, live_cwds={R}, live_tids={})
if r['status'] != 'working':
    fails.append(('working-live', r))

# D4: completed + reachable PTY → waiting 승격
N_done = {'status': 'completed', 'statusTs': 100.0}
r = ms.resolve_session_liveness('claude', 's2', R, native=N_done, event=None, live_cwds={R},
                                 live_tids={('claude', 's2'): 'tid9'})
if r['status'] != 'waiting' or r['tid'] != 'tid9' or not r['reachable']:
    fails.append(('D4', r))

# completed + not reachable → completed 유지
r = ms.resolve_session_liveness('claude', 's2', R, native=N_done, event=None, live_cwds=set(), live_tids={})
if r['status'] != 'completed':
    fails.append(('completed-stays', r))

# reachable 판정 — status 는 working 이더라도 tid/reachable 은 live_tids 로만 결정
r = ms.resolve_session_liveness('claude', 's3', R, native=N_work, event=None, live_cwds={R},
                                 live_tids={('claude', 's3'): 'tidA'})
if not r['reachable'] or r['tid'] != 'tidA':
    fails.append(('reachable', r))

# not reachable → tid == ""
r = ms.resolve_session_liveness('claude', 's4', R, native=N_work, event=None, live_cwds={R}, live_tids={})
if r['reachable'] or r['tid'] != '':
    fails.append(('not-reachable-empty-tid', r))

if fails:
    print("FAIL")
    for f in fails:
        print("  -", f)
    sys.exit(1)
print("PASS: resolve_session_liveness — status(merge)+D3 downgrade+D4 promote+reachable/tid")
PY
