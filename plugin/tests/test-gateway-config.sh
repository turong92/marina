#!/usr/bin/env bash
# 게이트웨이 config 생성: 스냅샷 → Caddyfile. 서비스별 서브도메인, 대표 web 은 bare, diff.
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
GW="$HERE/../scripts/marina-gateway.py"

python3 - "$GW" <<'PY'
import importlib.util, sys
spec=importlib.util.spec_from_file_location("gw", sys.argv[1]); gw=importlib.util.module_from_spec(spec); spec.loader.exec_module(gw)

# 스냅샷: 워크트리 2개, 각 web+api. 라이브 호스트포트.
snap=[
  {"id":"main","projectId":"shop","services":[
      {"service":"web","port":"55001","running":True},
      {"service":"api","port":"55002","running":True}]},
  {"id":"feat-x","projectId":"shop","services":[
      {"service":"web","port":"55003","running":True},
      {"service":"db","port":"","running":True}]},   # 포트 없음(미퍼블리시) → 라우트 X
]
cfg=gw.build_caddyfile(snap, port=80)
# 대표 web → bare 도메인, 그 외 → <id>-<svc>
assert "http://main.shop.localhost:80 {" in cfg, cfg
assert "reverse_proxy 127.0.0.1:55001" in cfg, cfg
assert "http://main-api.shop.localhost:80 {" in cfg and "127.0.0.1:55002" in cfg, cfg
assert "http://feat-x.shop.localhost:80 {" in cfg and "127.0.0.1:55003" in cfg, cfg
assert "db" not in cfg, "포트 없는 서비스는 라우트 없음"
assert "bind 127.0.0.1 ::1" in cfg, "로컬 전용 loopback 바인드(LAN 노출 방지, 코덱스 P1)"
# admin API + auto_https off (localhost)
assert "admin localhost:2021" in cfg and "auto_https off" in cfg, cfg
# 빈 스냅샷 → 사이트 0 (전역 블록만)
empty=gw.build_caddyfile([], port=80)
assert "localhost:80 {" not in empty and "admin localhost:2021" in empty, empty
# 도메인 sanitize — 대문자/언더스코어/슬래시 → 소문자·하이픈
assert gw._domain_label("Feat_Branch/2")=="feat-branch-2", gw._domain_label("Feat_Branch/2")
# 대표 web 선택: web/fe/frontend 우선, 없으면 첫 포트보유 서비스
assert gw._is_primary([{"service":"api","port":"1","running":True},{"service":"web","port":"2","running":True}], "web") is True
assert gw._is_primary([{"service":"api","port":"1","running":True},{"service":"worker","port":"2","running":True}], "api") is True   # web 없음 → 첫(api)
assert gw._is_primary([{"service":"api","port":"1","running":True},{"service":"worker","port":"2","running":True}], "worker") is False
assert gw._is_primary([{"service":"api","port":"1","running":False},{"service":"web","port":"2","running":True}], "web") is True   # 미실행 api 는 후보 제외
# diff: 같은 config 면 False, 다르면 True (reload 억제용)
import tempfile, os
d=tempfile.mkdtemp(); sp=os.path.join(d,"state")
assert gw.config_changed(cfg, sp) is True      # 최초
gw.write_config(cfg, sp)
assert gw.config_changed(cfg, sp) is False     # 동일 → 변화 없음
assert gw.config_changed(empty, sp) is True    # 달라짐
# codex review P2#2: 미실행(running False) 서비스는 포트 있어도 라우트 안 함 (stop 된 서비스 라우트 방지)
snap_stop=[{"id":"m","projectId":"p","services":[{"service":"web","port":"5000","running":False}]}]
assert "localhost:80 {" not in gw.build_caddyfile(snap_stop, 80), "stopped 서비스 라우트 없어야"
# codex review P2#1: reload 실패 시 applied 미갱신 → 다음 폴링 재시도; 성공 시 applied 갱신(config_path 는 항상 최신)
cp=os.path.join(d,"cf"); ap=cp+".applied"; _orig=gw.reload_caddy
gw.reload_caddy=lambda p: False                     # reload 실패 강제
assert gw.apply(snap, 80, cp, ap) is False
assert os.path.exists(cp) and not os.path.exists(ap), "config 는 쓰되 applied 는 미기록(재시도 대상)"
gw.reload_caddy=lambda p: True                      # 이제 성공
assert gw.apply(snap, 80, cp, ap) is True           # 같은 snapshot 이어도 applied 미기록이라 재시도→성공
assert os.path.exists(ap), "성공하면 applied 기록"
assert gw.apply(snap, 80, cp, ap) is False          # 이제 applied==desired → reload 안 함
gw.reload_caddy=_orig
# codex review P2: sanitize 충돌(feat_x vs feat-x) → 해시 disambiguate, 둘 다 유니크 라우트(전체 reject 방지)
coll=[{"id":"feat_x","projectId":"p","services":[{"service":"web","port":"1","running":True}]},
      {"id":"feat-x","projectId":"p","services":[{"service":"web","port":"2","running":True}]}]
import re as _re
doms=_re.findall(r'http://(\S+) \{', gw.build_caddyfile(coll, 80))
assert len(doms)==2 and len(set(doms))==2, ("충돌해도 2개 유니크 도메인", doms)
print("ok gateway-config")
PY
echo "PASS test-gateway-config"
