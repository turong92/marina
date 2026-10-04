#!/usr/bin/env bash
# 엮기 두 방향(2026-10-04 형): 프로젝트 기본은 워크트리 전용(9092→kafka 서비스)인데, 어떤 워크트리는 공용(host)이나
# dev 브로커(IP:포트)를 보고 싶다. → ① 타겟에 'IP:포트'(외부 주소) ② 워크트리별 덮어쓰기 <세션폴더>/forward.json.
# 앱 설정은 늘 localhost:<포트> 그대로 — 모드를 바꿔도 yml 을 안 건드린다.
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/harness.sh"   # 실 ~/.marina 격리
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
CP="$HERE/../scripts/marina-compose.py"
SD="$MARINA_HOME/sess"; mkdir -p "$SD"

python3 - "$CP" "$SD" <<'PY'
import importlib.util, json, sys
from pathlib import Path
spec=importlib.util.spec_from_file_location("mc", sys.argv[1]); mc=importlib.util.module_from_spec(spec); spec.loader.exec_module(mc)
sd = Path(sys.argv[2])
fails = []
def check(c, m):
    if not c: fails.append(m)

# ① 외부 주소 타겟 — 듣는 포트(9092)와 붙는 포트(31092)가 다를 수 있다. $H 셋업 불필요
s = mc._bind_script([("9092", "3.35.225.62:31092")])
check("TCP4-LISTEN:9092,fork,reuseaddr TCP:3.35.225.62:31092 &" in s, f"외부 v4: {s}")
check("TCP6-LISTEN:9092,fork,reuseaddr,ipv6only=1 TCP:3.35.225.62:31092 &" in s, f"외부 v6: {s}")
check("host.docker.internal" not in s, f"외부만이면 host 셋업 없음: {s}")
s = mc._bind_script([("6379", "redis"), ("9092", "dev.example.com:9092")])
check("TCP:redis:6379" in s and "TCP:dev.example.com:9092" in s, f"서비스+외부 혼합: {s}")

# 타겟 검증 — host · 서비스명 · 호스트:포트 만
svcs = {"kafka", "redis", "user-api"}
for ok in ("host", "kafka", "3.35.225.62:31092", "dev.example.com:9092"):
    check(mc.forward_target_error(ok, svcs) is None, f"허용: {ok} → {mc.forward_target_error(ok, svcs)}")
for bad in ("", "nosuch", "1.2.3.4:", "1.2.3.4:abc", ":9092", "a b:1", "1.2.3.4:99999",
            "\nhalt\n:1", "host ", "kafka\n", " kafka", "host:31092", "1.2.3.4:0", "1.2.3.4:²"):   # (리뷰 I1) 개행·공백 주입, host:포트 모호
    check(mc.forward_target_error(bad, svcs) is not None, f"거부: {bad!r}")

# ② 워크트리 덮어쓰기 — 없으면 {} · 쓰고 읽기 · reset 은 그 포트만 · 다 지우면 파일 삭제
check(mc.session_forward(sd) == {}, "파일 없음 → {}")
mc.set_session_forward(sd, "9092", "3.35.225.62:31092")
mc.set_session_forward(sd, "6379", "host")
check(mc.session_forward(sd) == {"9092": "3.35.225.62:31092", "6379": "host"}, f"쓰기: {mc.session_forward(sd)}")
mc.set_session_forward(sd, "9092", None)
check(mc.session_forward(sd) == {"6379": "host"}, f"reset 그 포트만: {mc.session_forward(sd)}")
mc.set_session_forward(sd, "6379", None)
check(not (sd / "forward.json").exists(), "다 지우면 파일 없음")
(sd / "forward.json").write_text("{깨짐")
check(mc.session_forward(sd) == {}, "깨진 파일 → {} (기동은 프로젝트 기본으로)")
(sd / "forward.json").write_text(json.dumps({"x": "host", "9092": "", "6379": 5}))
check(mc.session_forward(sd) == {}, f"잘못된 항목은 버림: {mc.session_forward(sd)}")
(sd / "forward.json").write_text(json.dumps({"9092": "\nhalt\n:1", "6379": "host ", "²": "host", "09092": "kafka", "0": "host", "8081": "user-api"}))
check(mc.session_forward(sd) == {"9092": "kafka", "8081": "user-api"}, f"(리뷰 I1·M3) 주입·공백 거부, 포트 정규화(09092→9092·²·0 버림): {mc.session_forward(sd)}")
(sd / "forward.json").unlink()
# (리뷰 M4) 사이드카 스크립트 직전에도 거른다 — x-marina·대시보드 경로로 온 이상한 타겟도 sh 에 안 들어감
s = mc._bind_script([("9092", "a;reboot"), ("6379", "redis")])
check("reboot" not in s and "TCP:redis:6379" in s, f"잘못된 타겟은 스크립트에서 빠짐: {s}")

# 합치기 — 워크트리 덮어쓰기가 x-marina(프로젝트 기본)·자동 서비스타겟을 이긴다
cfg = {"services": {"user-api": {"build": {"context": "."}, "ports": [{"target": 8081}]},
                    "kafka": {"image": "apache/kafka", "ports": [{"target": 9092}]}}}
xm = {"forward": {"9092": "kafka", "6379": "host"}}
base = mc.effective_forward({}, xm, cfg, sd)
check(base.get("9092") == "kafka" and base.get("6379") == "host" and base.get("8081") == "user-api", f"기본: {base}")
mc.set_session_forward(sd, "9092", "host")
eff = mc.effective_forward({}, xm, cfg, sd)
check(eff.get("9092") == "host" and eff.get("6379") == "host", f"덮어쓰기 우선: {eff}")
mc.set_session_forward(sd, "9092", None)

# CLI — marina forward 가 부르는 하위명령: set / reset / show
import subprocess
def run(*a):
    return subprocess.run([sys.executable, sys.argv[1], "forward", "--session-dir", str(sd), *a], capture_output=True, text=True)
r = run("9092", "3.35.225.62:31092")
check(r.returncode == 0 and mc.session_forward(sd) == {"9092": "3.35.225.62:31092"}, f"cli set: {r.returncode} {r.stderr}")
r = run("9092", "1.2.3.4:")
check(r.returncode == 2 and mc.session_forward(sd) == {"9092": "3.35.225.62:31092"}, f"cli 잘못된 타겟 거부·기존 유지: {r.returncode}")
r = run("9092", "host", "--reset")
check(r.returncode == 2, "cli 타겟과 --reset 동시 거부")
r = run("abc", "host")
check(r.returncode == 2, "cli 포트 숫자 아님 거부")
r = run()
check(r.returncode == 0 and "9092" in r.stdout and "3.35.225.62:31092" in r.stdout, f"cli show: {r.stdout}")
r = run("9092", "--reset")
check(r.returncode == 0 and mc.session_forward(sd) == {}, f"cli reset: {r.stderr}")
r = run()
check(r.returncode == 0 and "프로젝트 기본" in r.stdout, f"cli show 빈: {r.stdout}")

if fails:
    print("FAIL:\n  " + "\n  ".join(fails)); sys.exit(1)
PY
echo "PASS test-compose-forward-override"
