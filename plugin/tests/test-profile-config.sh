#!/usr/bin/env bash
# _service_profile — ARG 목록 + (marina overlay, stored) build args → {profileVar, profileValue}.
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
python3 - "$HERE/../scripts" <<'PY'
import importlib.util, os, sys
sd = sys.argv[1]; sys.path.insert(0, sd)
spec = importlib.util.spec_from_file_location("marina_compose_svc", os.path.join(sd, "marina_compose_svc.py"))
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
assert m._service_profile(["PROFILE"], {"PROFILE": "dev"}, {"PROFILE": "local"}) == {"profileVar": "PROFILE", "profileValue": "dev"}, "marina overlay 우선"
assert m._service_profile(["PROFILE"], {}, {"PROFILE": "local"}) == {"profileVar": "PROFILE", "profileValue": "local"}, "stored 폴백"
assert m._service_profile(["PROFILE"], {}, {}) == {"profileVar": "PROFILE", "profileValue": ""}, "값 없음"
assert m._service_profile(["FOO"], {}, {}) == {"profileVar": None, "profileValue": ""}, "후보 없음→None"
# _profile_value: 카드 칩용 — 명시 설정된 profile 후보 키의 값
assert m._profile_value({"PROFILE": "dev", "EXTRA": "x"}) == "dev", "profile 후보 값"
assert m._profile_value({"EXTRA": "x"}) == "", "후보 키 없음→''"
assert m._profile_value({}) == "" and m._profile_value(None) == ""
print("ok profile-config")
PY
echo "PASS test-profile-config"
