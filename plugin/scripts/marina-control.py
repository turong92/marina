#!/usr/bin/env python3
"""marina-control.py — marina 대시보드 데몬 entry. 레이어드 모듈을 조립·재export 한다.
구현은 marina_{state,dockerfile,logtext,cli,registry,update,compose_svc,sessions,lifecycle,handler}.py 로 분리."""
import os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import marina_state
import marina_dockerfile
import marina_logtext
import marina_cache
import marina_registry
import marina_paths
import marina_cli
import marina_update
import marina_compose_svc
import marina_sessions
import marina_lifecycle
import marina_handler

# 전 모듈 심볼을 이 모듈 네임스페이스로 재export — 테스트(spec_from_file_location)가 mc.<symbol> 로 접근.
for _m in (marina_state, marina_dockerfile, marina_logtext, marina_cache, marina_registry, marina_paths, marina_cli, marina_update, marina_compose_svc, marina_sessions, marina_lifecycle, marina_handler):
    globals().update({k: v for k, v in vars(_m).items() if not k.startswith("__")})

from marina_handler import Handler, main  # noqa: E402  (조립 진입점)

if __name__ == "__main__":
    # CLI 훅(서버 미기동): marina.sh start 가 up 직후 호출 — 게이트웨이 자동 기동+라우트 반영
    if len(sys.argv) > 1 and sys.argv[1] == "gateway-ensure":
        marina_lifecycle.ensure_gateway()
        sys.exit(0)
    main()
