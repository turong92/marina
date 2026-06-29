#!/usr/bin/env bash
# detect_profile_var / is_profile_var — ARG 목록에서 profile 변수 감지(후보 우선순위).
set -euo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
python3 - "$HERE/../scripts" <<'PY'
import importlib.util, os, sys
sd = sys.argv[1]; sys.path.insert(0, sd)
spec = importlib.util.spec_from_file_location("marina_dockerfile", os.path.join(sd, "marina_dockerfile.py"))
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
assert m.detect_profile_var(["JAVA_TOOL_OPTIONS", "PROFILE"]) == "PROFILE", "ARG PROFILE 매칭"
assert m.detect_profile_var(["SPRING_PROFILES_ACTIVE"]) == "SPRING_PROFILES_ACTIVE", "spring 직접"
assert m.detect_profile_var(["PROFILE", "APP_ENV"]) == "PROFILE", "우선순위(PROFILE>APP_ENV)"
assert m.detect_profile_var(["FOO", "BAR"]) is None, "후보 없음(web 류)→None"
assert m.detect_profile_var([]) is None
assert m.is_profile_var("profile") is True and m.is_profile_var("PROFILE") is True, "대소문자 무시"
assert m.is_profile_var("JAVA_TOOL_OPTIONS") is False
print("ok profile-detect")
PY
echo "PASS test-profile-detect"
