#!/usr/bin/env bash
# cache discovery: compose cache-ish named volumes are clearable, state/data volumes are not.
set -euo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT="$(cd "$HERE/../.." && pwd -P)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

export MARINA_HOME="$TMP/marina-home"
mkdir -p "$MARINA_HOME/proj"

python3 - "$ROOT" "$TMP" <<'PY'
import json
import os
import sys
from pathlib import Path

root = Path(sys.argv[1])
tmp = Path(sys.argv[2])
scripts = root / "plugin" / "scripts"
sys.path.insert(0, str(scripts))

project_root = tmp / "project"
project_root.mkdir()
(project_root / ".git").mkdir()
(project_root / "web").mkdir()
(project_root / "api" / ".cache").mkdir(parents=True)
(project_root / "api" / ".cache" / "artifact.txt").write_text("x" * (2 * 1024 * 1024), encoding="utf-8")
(project_root / "api" / "node_modules").mkdir(parents=True)
(project_root / "api" / "node_modules" / "dep.txt").write_text("dep", encoding="utf-8")

marina_home = Path(os.environ["MARINA_HOME"])
(marina_home / "projects.json").write_text(json.dumps({
    "projects": [{
        "id": "proj",
        "root": str(project_root),
        "subrepos": ["web", "api"],
        "worktreeGlobs": [],
        "kind": "compose",
        "composeFile": "docker-compose.yml"
    }]
}), encoding="utf-8")
(marina_home / "proj" / "docker-compose.yml").write_text("""
services:
  web:
    build: ./web
    volumes:
      - web_node:/app/node_modules
      - web_next:/app/.next
      - db_data:/var/lib/postgresql/data
  api:
    build: ./api
  redis:
    image: redis:7
volumes:
  web_node: {}
  web_next: {}
  db_data: {}
""", encoding="utf-8")

import marina_cache
import marina_lifecycle

existing = {"proj-main_web_node", "proj-main_web_next", "proj-main_db_data"}
removed = []
removed_images = []

marina_cache.docker_volume_exists = lambda name: name in existing
marina_cache.docker_volume_sizes_mb = lambda names=None: {
    "proj-main_web_node": 120,
    "proj-main_web_next": 80,
    "proj-main_db_data": 999,
}
marina_cache.docker_volume_rm = lambda name: removed.append(name) or True
marina_cache.docker_image_rm = lambda image_id: removed_images.append(image_id) or True
marina_lifecycle.docker_volume_rm = marina_cache.docker_volume_rm
marina_lifecycle.docker_image_rm = marina_cache.docker_image_rm

def fake_check_output(args, **kwargs):
    text = " ".join(str(arg) for arg in args)
    if args and str(args[0]) == "du":
        return "2048\t/path\n"
    if "system df" in text:
        return json.dumps({
            "Images": [{"Size": "3.5GB"}],
            "BuildCache": [{"Size": "12GB"}],
            "Volumes": [{"Name": "proj-main_web_next", "Size": "80MB"}],
        })
    if "images --format json web" in text:
        return json.dumps([{
            "Service": "web",
            "ID": "sha256:web",
            "Repository": "proj-web",
            "Tag": "latest",
            "Size": "512MB",
        }])
    if "images --format json api" in text:
        return ""
    if "images --format json redis" in text:
        raise AssertionError("image-only services must not be inspected for cleanup")
    raise AssertionError(f"unexpected docker command: {text}")

marina_cache.subprocess.check_output = fake_check_output

items = marina_cache.cache_items_by_category(project_root)
assert "web_node" in items and "web_next" in items, items
assert "db_data" not in items, items
assert any(i["type"] == "volume" and i["volume"] == "proj-main_web_node" for i in items["web_node"]), items
assert "api_cache" in items and any(i["type"] == "path" for i in items["api_cache"]), items
assert "api_node_modules" not in items, items

sizes = marina_cache.cache_category_mb(project_root)
assert sizes["web_node"] == 120, sizes
assert sizes["web_next"] == 80, sizes
assert sizes["api_cache"] > 0, sizes

result = marina_lifecycle.clear_worktree_cache(project_root, "web_node")
assert "proj-main_web_node" in removed, removed
assert result["freedMb"] == 120, result

result = marina_lifecycle.clear_worktree_cache(project_root, "api_cache")
assert not (project_root / "api" / ".cache").exists(), result
assert result["freedMb"] > 0, result

summary = marina_cache.docker_disk_summary()
assert summary == {"imagesMb": 3584, "buildCacheMb": 12288, "volumesMb": 80}, summary

images = marina_cache.compose_build_image_items(project_root)
assert images == [{
    "type": "image",
    "category": "images",
    "service": "web",
    "imageId": "sha256:web",
    "repository": "proj-web",
    "tag": "latest",
    "sizeMb": 512,
}], images

marina_lifecycle._worktree_du_cache[str(project_root)] = (0, 1, {}, 512, {})
result = marina_lifecycle.clear_worktree_images(project_root)
assert result["removed"] == ["sha256:web"], result
assert result["freedMb"] == 512, result
assert removed_images == ["sha256:web"], removed_images
assert str(project_root) not in marina_lifecycle._worktree_du_cache

print("ok cache discovery")
PY

echo "PASS test-cache-discovery"
