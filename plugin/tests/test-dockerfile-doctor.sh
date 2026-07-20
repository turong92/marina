#!/usr/bin/env bash
# Dockerfile Doctor: cache anti-patterns are diagnosed from Dockerfile text and surfaced in compose config.
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
TMP="$(mktemp -d)"; export MARINA_HOME="$TMP/home"; mkdir -p "$MARINA_HOME/proj"
trap 'rm -rf "$TMP"' EXIT

python3 - "$ROOT" "$TMP" <<'PY'
import json
import os
import sys
from pathlib import Path

root = Path(sys.argv[1])
tmp = Path(sys.argv[2])
sys.path.insert(0, str(root / "plugin" / "scripts"))

import marina_dockerfile as md
import marina_compose_svc as svc

bad = """\
FROM node:20
WORKDIR /app
COPY . .
RUN pnpm install
RUN apt-get update && apt-get install -y ffmpeg
"""
codes = [item["code"] for item in md.dockerfile_doctor(bad)]
assert "copy-before-install" in codes, codes
assert "missing-cache-mount" in codes, codes
assert "apt-cache-not-cleaned" in codes, codes

heavy = """\
FROM python:3.11-slim
RUN apt-get update && apt-get install -y ffmpeg chromium
RUN pip install torch opencv-python
RUN playwright install --with-deps chromium
"""
heavy_items = md.dockerfile_doctor(heavy)
heavy_codes = [item["code"] for item in heavy_items]
assert heavy_codes.count("heavy-dependency") == 3, heavy_items
heavy_details = " ".join(item["detail"] for item in heavy_items if item["code"] == "heavy-dependency")
for token in ("ffmpeg", "chromium", "torch", "opencv", "playwright"):
    assert token in heavy_details, heavy_items

good = """\
# syntax=docker/dockerfile:1.7
FROM node:20
WORKDIR /app
COPY package.json pnpm-lock.yaml ./
RUN --mount=type=cache,id=pnpm,target=/pnpm/store pnpm install --frozen-lockfile
COPY . .
"""
good_codes = [item["code"] for item in md.dockerfile_doctor(good)]
assert "copy-before-install" not in good_codes, good_codes
assert "missing-cache-mount" not in good_codes, good_codes

project_root = tmp / "proj-root"
(project_root / "web").mkdir(parents=True)
(project_root / "web" / "Dockerfile").write_text(bad, encoding="utf-8")
(Path(os.environ["MARINA_HOME"]) / "proj" / "docker-compose.yml").write_text("services:\n  web:\n    build: ./web\n", encoding="utf-8")
project = {"id": "proj", "composeFile": "docker-compose.yml"}

svc._docker_compose_config_json = lambda sp, root_path: ({
    "services": {
        "web": {
            "build": {"context": str(project_root / "web"), "dockerfile": "Dockerfile"},
            "ports": [],
        }
    }
}, "")
svc._compose_defined_services = lambda project_arg: ["web"]

view = svc.compose_resolved_view(project_root, project)
assert view["ok"], view
web = view["services"][0]
payload_codes = [item["code"] for item in web["doctor"]]
assert payload_codes == codes, json.dumps(web["doctor"], ensure_ascii=False)
print("ok dockerfile doctor")
PY

grep -q "dockerfileDoctorItems" "$ROOT/plugin/scripts/marina-web/app-5c-config.js" || {
  echo "FAIL: Dockerfile Doctor UI renderer missing"
  exit 1
}

echo "PASS test-dockerfile-doctor"
