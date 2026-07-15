"""marina_handler.py — marina-control.py 에서 분리(레이어드). 동작 변경 0."""
from __future__ import annotations
import glob
import json
import os
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.parse
from concurrent.futures import ThreadPoolExecutor
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any
import importlib.util as _ilu

from marina_state import CONTROL_SCRIPT, HOST, LOG_TAIL_BYTES, MARINA_HOME, PORT, _GATEWAY_ON, _GATEWAY_PORT, _env, _gw, _mc, invalidate_registry_caches, json_bytes
from marina_dockerfile import _compose_scaffold_service, _compose_scan, _detect_subrepos, _list_dockerfiles, _subrepo_compose, is_profile_var
from marina_logtext import read_log_chunk, redact_text, scan_log_matches
from marina_registry import containing_project_for, discover_all_roots, discover_roots, external_repos_for, is_source_checkout, load_projects, project_for, source_root_for, subrepos_of
from marina_paths import selected_log, session_dir, session_id, write_config, write_meta
from marina_cli import _marina_cli, run_marina, run_marina_registry
from marina_build import build_summary


def _apply_now(root: Path, service: str = "") -> None:
    """link-set 직후 이 워크트리에 apply(심링크/복제 즉시 생성) — 대시보드에서 넣으면 바로 뜨게.
    main(원본)은 대상 아님(apply 내부에서 src==dst skip 이지만, 불필요한 subprocess 도 생략). best-effort."""
    try:
        if is_source_checkout(root):
            return
        run_marina(root, "link", service) if service else run_marina(root, "link")
    except Exception:
        pass
from marina_update import _serving_sha, update_claude, update_codex, update_status
from marina_compose_svc import compose_resolved_view, compose_validate, merge_xmarina_into_yaml, unified_compose_yaml, weave_map
from marina_memory import memory_snapshot
from marina_sessions import agent_transcript, agents_payload, append_console_log, claude_session_titles, codex_session_titles, host_allowed, origin_allowed, safe_root, safe_service, session_payload, system_memory, worktree_info, worktree_status
from marina_term import term_input, term_kill, term_list, term_open, term_resize, term_stream
from marina_git import git_commit, git_commit_info, git_diff, git_fetch, git_graph, git_merge, git_pull, git_push, git_rebase, git_stash, git_wip_stat
from marina_lifecycle import _gateway_snapshot, attach_subrepo_action, cleanup_session, clear_worktree_cache, detach_subrepo_action, rebuild_service, refresh_gateway, remove_worktree, restart_service, start_all, start_service, stop_all, stop_external, stop_service

_WEB_DIR = Path(__file__).resolve().parent / "marina-web"

def render_index_html() -> str:
    """marina-web/index.html 을 읽어 빌드 SHA 토큰을 치환해 반환 (프론트엔드는 marina-web/ 로 분리)."""
    html = (_WEB_DIR / "index.html").read_text(encoding="utf-8")
    return html.replace("{{MARINA_BUILD}}", _serving_sha() or "dev")

class Handler(BaseHTTPRequestHandler):
    def send_json(self, payload: Any, status: int = 200) -> None:
        data = json_bytes(payload)
        self.send_response(status)
        self.send_header("content-type", "application/json; charset=utf-8")
        origin = self.headers.get("origin")
        if origin and origin_allowed(origin, True):
            # localhost 웹앱(/api/console)만 CORS 응답 허용 — 구버전의 무차별 `*` 제거
            self.send_header("access-control-allow-origin", origin)
            self.send_header("vary", "origin")
        self.send_header("content-length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def read_json(self) -> dict[str, Any]:
        length = int(self.headers.get("content-length", "0"))
        raw = self.rfile.read(length) if length else b"{}"
        return json.loads(raw.decode("utf-8"))

    def do_GET(self) -> None:  # noqa: N802
        parsed = urllib.parse.urlparse(self.path)
        if parsed.path == "/api/gateway-status":
            light = urllib.parse.parse_qs(parsed.query).get("light", ["0"])[0] == "1"   # light=1: enabled/port 만(routes=비싼 스냅샷 생략 — 카드 URL 계산용)
            out = {"enabled": _GATEWAY_ON, "caddy": bool(_gw().caddy_bin()), "port": _GATEWAY_PORT}
            if not light:
                out["routes"] = _gw().build_caddyfile(_gateway_snapshot(), _GATEWAY_PORT)
            self.send_json(out)
            return
        if parsed.path == "/":
            # 떠있는 빌드 SHA 를 페이지에 주입 — 브라우저가 어느 버전을 로드했는지 검증·디버깅용
            data = render_index_html().encode("utf-8")
            self.send_response(200)
            self.send_header("content-type", "text/html; charset=utf-8")
            # no-store — 라이브 대시보드 HTML 은 캐시 금지. 없으면 브라우저가 옛 INDEX_HTML 을 캐시로
            # 서빙해서, 재시작 후 location.reload()·수동 새로고침이 옛 UI/JS 를 받는다 (새 코드 안 보임).
            self.send_header("cache-control", "no-store, no-cache, must-revalidate")
            self.send_header("content-length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
            return

        if parsed.path.startswith("/web/"):    # 정적 프론트엔드 자산 (marina-web/styles.css·app.js)
            name = parsed.path[len("/web/"):]
            if not name or "/" in name or "\\" in name or ".." in name:
                self.send_error(404)
                return
            fp = _WEB_DIR / name
            if not fp.is_file():
                self.send_error(404)
                return
            ctype = ("text/css; charset=utf-8" if name.endswith(".css")
                     else "image/png" if name.endswith(".png")
                     else "image/svg+xml" if name.endswith(".svg")
                     else "image/x-icon" if name.endswith(".ico")
                     else "application/javascript; charset=utf-8" if name.endswith(".js")
                     else "application/octet-stream")
            data = fp.read_bytes()
            self.send_response(200)
            self.send_header("content-type", ctype)
            self.send_header("cache-control", "no-store, no-cache, must-revalidate")
            self.send_header("content-length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
            return

        if parsed.path.startswith("/api/"):
            # Host 먼저 — origin_allowed 는 Origin 없는 요청을 통과시키는데 DNS 리바인딩된
            # same-origin GET 이 바로 그 모양이다(브라우저가 Origin 을 안 보낸다).
            if not host_allowed(self.headers.get("host")):
                self.send_json({"error": "forbidden host"}, 403)
                return
            if not origin_allowed(self.headers.get("origin"), False):
                self.send_json({"error": "forbidden origin"}, 403)
                return

        if parsed.path == "/api/sessions":
            memory = memory_snapshot()
            sessions = [session_payload(root, memory=memory) for root in discover_roots()]
            for item in sessions:
                item["webPortConflictWith"] = []
            self.send_json({"sessions": sessions, "memory": memory})
            return

        if parsed.path == "/api/worktrees":
            query = urllib.parse.parse_qs(parsed.query)
            refresh = query.get("refresh", ["0"])[0] == "1"
            # 세션 타이틀은 앱에서 수정 시 빨리 반영돼야 해 캐시된 worktree_info 밖에서 신선하게 덧씌운다.
            titles = claude_session_titles(refresh)       # Claude 데스크톱 (20s 캐시)
            codex_titles = codex_session_titles(refresh)  # Codex (60s 캐시)
            roots = discover_all_roots(refresh)
            # 깃 배지 계산은 root 당 ~0.3s(전부 git subprocess 대기)라 직렬로는 root 수에 비례 —
            # root 끼리 독립이니 병렬 프리컴퓨트(실측 14 roots 4.4s→0.8s). 오버레이는 캐시 히트라 직렬 유지.
            with ThreadPoolExecutor(max_workers=8) as pool:
                infos = list(pool.map(lambda r: dict(worktree_info(r, refresh)), roots))
            worktrees = []
            for root, info in zip(roots, infos):
                entry = titles.get(str(root))
                if entry:
                    info["sessionTitle"] = entry["title"]
                    info["titleSource"] = entry["titleSource"]
                elif str(root) in codex_titles:
                    info["sessionTitle"] = codex_titles[str(root)]
                    info["titleSource"] = "codex"
                agents = agents_payload(root, refresh)   # A1 — 카드 AGENTS 섹션(같은 titles 캐시 리듬에 편승)
                if agents:
                    info["agents"] = agents
                worktrees.append(info)
            self.send_json({"worktrees": worktrees})
            return

        if parsed.path == "/api/update-status":
            self.send_json(update_status())
            return


        if parsed.path == "/api/browse":
            query = urllib.parse.parse_qs(parsed.query)
            raw = query.get("path", [""])[0]
            try:
                base = (Path(raw).expanduser() if raw else Path.home()).resolve()
                if not base.is_dir():
                    raise ValueError(f"디렉토리 아님: {raw or '~'}")
                entries = []
                for child in sorted(base.iterdir(), key=lambda p: p.name.lower()):
                    if child.name.startswith("."):
                        continue
                    try:
                        if not child.is_dir():
                            continue
                    except OSError:
                        continue
                    entries.append({
                        "name": child.name,
                        "isDir": True,
                        "isGitRepo": (child / ".git").exists(),
                    })
                parent = str(base.parent) if base.parent != base else None
                self.send_json({"path": str(base), "parent": parent, "entries": entries})
            except Exception as exc:
                self.send_json({"error": str(exc)}, 400)
            return

        if parsed.path == "/api/repo-candidates":
            # 등록 워크벤치 진입(R1) — 관례 루트(존재하는 것만)를 2단계까지 스캔해 .git 후보를 모은다.
            # 자동 아님(버튼에서만 호출) · 홈 전체 rglob 금지 · 상한 100개.
            CONVENTION_ROOTS = ["~/IdeaProjects", "~/projects", "~/dev", "~/workspace"]
            SKIP_NAMES = {"node_modules", ".git", ".workspace"}
            LIMIT = 100
            registered_roots: set[str] = set()
            for proj in load_projects():
                try:
                    registered_roots.add(str(Path(proj["root"]).resolve()))
                except Exception:
                    continue

            def _has_compose(d: Path) -> bool:
                try:
                    return next(d.glob("*compose*.y*ml"), None) is not None
                except OSError:
                    return False

            def _subdirs(d: Path) -> list[Path]:
                try:
                    return sorted(
                        (c for c in d.iterdir()
                         if c.is_dir() and not c.name.startswith(".") and c.name not in SKIP_NAMES),
                        key=lambda p: p.name.lower(),
                    )
                except OSError:
                    return []

            candidates: list[dict[str, Any]] = []
            seen: set[str] = set()

            def _consider(d: Path) -> None:
                if len(candidates) >= LIMIT:
                    return
                try:
                    if not (d / ".git").exists():
                        return
                    rp = str(d.resolve())
                except OSError:
                    return
                if rp in seen:
                    return
                seen.add(rp)
                candidates.append({
                    "path": rp,
                    "name": d.name,
                    "hasCompose": _has_compose(d),
                    "registered": rp in registered_roots,
                })

            scanned: list[str] = []
            for raw in CONVENTION_ROOTS:
                base = Path(raw).expanduser()
                if not base.is_dir():
                    continue
                scanned.append(str(base))
                for d1 in _subdirs(base):
                    if len(candidates) >= LIMIT:
                        break
                    _consider(d1)
                    for d2 in _subdirs(d1):
                        if len(candidates) >= LIMIT:
                            break
                        _consider(d2)
            self.send_json({"candidates": candidates[:LIMIT], "scanned": scanned})
            return

        if parsed.path == "/api/compose-detect":
            qs = urllib.parse.parse_qs(parsed.query)
            target = Path((qs.get("path", [""])[0] or "").strip()).expanduser()
            if not target.is_dir():
                self.send_json({"ok": False, "files": [], "stored": None})
                return
            # 루트 + 1단계 하위(서브레포)만 — 깊은 node_modules walk 회피
            search_dirs = [target]
            try:
                search_dirs += [d for d in sorted(target.iterdir())
                                if d.is_dir() and not d.name.startswith(".")
                                and d.name not in ("node_modules", ".workspace")]
            except OSError:
                pass
            files, seen = [], set()
            for d in search_dirs:
                for p in sorted(d.glob("*compose*.y*ml")):
                    if p.name == "marina-overlay.yml" or p in seen:
                        continue
                    seen.add(p)
                    try:
                        content = p.read_text(encoding="utf-8", errors="replace")
                    except OSError:
                        continue
                    files.append({"path": str(p), "rel": str(p.relative_to(target)), "content": content})
                    if len(files) >= 50:
                        break
                if len(files) >= 50:
                    break
            stored = None
            proj = containing_project_for(target)   # 단일 등록 폴백 금지 — 무관한 레포에 남의 저장본을 제안하지 않게(코덱스 P2)
            if proj and proj.get("kind") == "compose":
                sp = MARINA_HOME / proj["id"] / proj.get("composeFile", "docker-compose.yml")
                if sp.exists():
                    stored = {"yaml": sp.read_text(encoding="utf-8"),
                              "composeFile": proj.get("composeFile", "docker-compose.yml"),
                              "envVar": proj.get("composeEnvVar", ""),
                              "envDefault": proj.get("composeEnvDefault", "local")}
            ext_repos = []   # 등록된 외부 서브레포 → ✎ 재오픈 시 행 복원(재등록해도 안 드롭)
            for er in external_repos_for(target):
                src = er.get("source")
                if not er.get("name") or not src:
                    continue
                try:
                    sub = os.path.relpath(src, str(target)).replace(os.sep, "/")
                except ValueError:
                    sub = src
                ext_repos.append({"name": er["name"], "sub": sub,
                                  "mount": "./.workspace/external/" + er["name"]})
            self.send_json({"ok": True, "files": files, "stored": stored,
                            "subrepos": _detect_subrepos(target), "externalRepos": ext_repos})
            return

        if parsed.path == "/api/compose-config":   # 읽기전용 구성 뷰 — 서비스가 어떤 Dockerfile/compose 로 구성됐나
            qs = urllib.parse.parse_qs(parsed.query)
            root = Path((qs.get("root", [""])[0] or "").strip()).expanduser()
            proj = project_for(root)
            if not proj or proj.get("kind") != "compose":
                self.send_json({"ok": False, "error": "compose 프로젝트가 아니거나 미등록"})
                return
            self.send_json(compose_resolved_view(root, proj))
            return

        if parsed.path == "/api/compose-export":   # 등록된 프로젝트 → '하나의 정규 설정'(공유용 복사) compose+x-marina
            qs = urllib.parse.parse_qs(parsed.query)
            root = Path((qs.get("root", [""])[0] or "").strip()).expanduser()
            proj = project_for(root)
            if not proj or proj.get("kind") != "compose":
                self.send_json({"ok": False, "error": "compose 프로젝트가 아니거나 미등록"}, 400)
                return
            try:
                self.send_json({"ok": True, "yaml": unified_compose_yaml(root, proj)})
            except Exception as exc:
                self.send_json({"ok": False, "error": str(exc)}, 400)
            return

        if parsed.path == "/api/compose-scaffold":   # 무-LLM: 서브레포 → compose 서비스 블록(Dockerfile 기반)
            qs = urllib.parse.parse_qs(parsed.query)
            target = Path((qs.get("path", [""])[0] or "").strip()).expanduser()
            subrepo = (qs.get("subrepo", [""])[0] or "").strip()
            chosen = (qs.get("dockerfile", [""])[0] or "").strip()   # 피커에서 선택한 Dockerfile
            ctx = (qs.get("context", [""])[0] or "").strip()         # 외부 마운트 경로(있으면)
            if not target.is_dir() or not subrepo:
                self.send_json({"ok": False, "error": "path·subrepo 필요"})
                return
            sub_dir = target / subrepo.strip("/")
            sub_compose = _subrepo_compose(sub_dir)
            if sub_compose and not chosen:   # 자체 compose 보유 → include 로 가져옴(서비스 스캐폴드 대신)
                inc = (ctx.rstrip("/") + "/" + sub_compose) if ctx else ("./" + subrepo.strip("/") + "/" + sub_compose)
                self.send_json({"ok": True, "include": inc})
                return
            dfs = _list_dockerfiles(sub_dir)
            if not chosen and len(dfs) > 1:   # Dockerfile 여러 개 → 각각 서비스(선택)
                self.send_json({"ok": True, "needPick": True, "dockerfiles": dfs})
                return
            if not chosen and len(dfs) == 1 and "/" in dfs[0]:   # 단일 중첩 → 자동으로 그 Dockerfile
                chosen = dfs[0]
            self.send_json({"ok": True, "yaml": _compose_scaffold_service(
                target, subrepo, dockerfile=chosen, build_context=ctx)})
            return

        if parsed.path == "/api/worktree-changes":
            query = urllib.parse.parse_qs(parsed.query)
            try:
                root = safe_root(query.get("root", [""])[0])
            except Exception as exc:
                self.send_json({"error": str(exc)}, 400)
                return
            self.send_json({"repos": worktree_status(root)["repos"]})
            return

        if parsed.path == "/api/git-graph":
            query = urllib.parse.parse_qs(parsed.query)
            try:
                root = safe_root(query.get("root", [""])[0])
                payload = git_graph(root, query.get("repo", ["."])[0],
                                    refresh=query.get("refresh", ["0"])[0] == "1",
                                    all_remotes=query.get("all", ["0"])[0] == "1",
                                    want_avatars=query.get("avatars", ["0"])[0] == "1")
            except Exception as exc:
                self.send_json({"error": str(exc)}, 400)
                return
            self.send_json(payload)
            return

        if parsed.path == "/api/weave-map":   # 연결 탭(P3) — 엮기(forward) 최종 맵 + 서비스별 적용분. compose 미등록/미해석 → ok:false(200).
            query = urllib.parse.parse_qs(parsed.query)
            try:
                root = safe_root(query.get("root", [""])[0])
            except Exception as exc:
                self.send_json({"ok": False, "error": str(exc)}, 400)
                return
            proj = project_for(root)
            if not proj or proj.get("kind") != "compose":
                self.send_json({"ok": False, "error": "compose 프로젝트가 아니거나 미등록"})
                return
            result = weave_map(root, proj)
            if result.get("ok"):
                result["services"] = session_payload(root).get("services") or []
            self.send_json(result)
            return

        if parsed.path in ("/api/term-stream", "/api/term-list"):   # 터미널 — POST 쪽과 같은 로컬 전용 가드
            if self.headers.get("x-forwarded-for") or self.headers.get("x-forwarded-host"):
                self.send_json({"error": "터미널은 로컬 대시보드에서만 쓸 수 있어요"}, 403)
                return
            if parsed.path == "/api/term-list":
                self.send_json(term_list())
                return
            query = urllib.parse.parse_qs(parsed.query)
            tids = [t for t in query.get("tid", [""])[0].split(",") if t]
            froms: dict[str, int] = {}
            for pair in query.get("from", [""])[0].split(","):       # from=tid:off,tid:off
                key, sep, value = pair.partition(":")
                if sep and key:
                    try:
                        froms[key] = int(value)
                    except ValueError:
                        pass                                          # 잘못된 from 은 버림 → snap 폴백
                                                                      # (/api/logs 는 같은 실수에 400 을 내지만 여기선 tid 가 여럿 —
                                                                      #  한 항목 때문에 400 이면 멀쩡한 터미널 스트림까지 죽는다)
            try:
                term_stream(self, tids, froms)
            except ValueError as exc:
                self.send_json({"error": str(exc)}, 400)
            return

        if parsed.path == "/api/agent-transcript":   # AGENTS 행 클릭 — user/assistant 텍스트 턴(마스킹 적용)
            query = urllib.parse.parse_qs(parsed.query)
            try:
                root = safe_root(query.get("root", [""])[0])
                payload = agent_transcript(root, query.get("source", [""])[0], query.get("sid", [""])[0])
            except Exception as exc:
                self.send_json({"error": str(exc)}, 400)
                return
            self.send_json(payload)
            return

        if parsed.path == "/api/git-wip-stat":   # WIP 상세 — 파일별 +/-(numstat)·untracked
            query = urllib.parse.parse_qs(parsed.query)
            try:
                root = safe_root(query.get("root", [""])[0])
                payload = git_wip_stat(root, query.get("repo", ["."])[0])
            except Exception as exc:
                self.send_json({"error": str(exc)}, 400)
                return
            self.send_json(payload)
            return

        if parsed.path == "/api/git-commit-info":   # 깃 탭 우측 상세 패널 — 커밋 메타+파일 목록(파일 클릭=변경 탭 드릴인)
            query = urllib.parse.parse_qs(parsed.query)
            try:
                root = safe_root(query.get("root", [""])[0])
                payload = git_commit_info(root, query.get("repo", ["."])[0], query.get("commit", [""])[0])
            except Exception as exc:
                self.send_json({"error": str(exc)}, 400)
                return
            self.send_json(payload)
            return

        if parsed.path == "/api/git-diff":
            query = urllib.parse.parse_qs(parsed.query)
            try:
                root = safe_root(query.get("root", [""])[0])
                payload = git_diff(root, query.get("repo", ["."])[0],
                                   file=query.get("file", [""])[0],
                                   commit=query.get("commit", [""])[0])
            except Exception as exc:
                self.send_json({"error": str(exc)}, 400)
                return
            self.send_json(payload)
            return

        if parsed.path == "/api/links":   # 서비스 effective links (기본 glob + service + override) — 대시보드 표시용
            query = urllib.parse.parse_qs(parsed.query)
            try:
                root = safe_root(query.get("root", [""])[0])
                service = safe_service(query.get("service", [""])[0], root)
            except Exception as exc:
                self.send_json({"error": str(exc)}, 400)
                return
            subrepo = re.sub(r"[^A-Za-z0-9_./-]", "", query.get("subrepo", [""])[0])[:120]   # present 정밀(compose) — 안전 문자만
            try:
                out = run_marina(root, "links-json", service, subrepo) if subrepo else run_marina(root, "links-json", service)
                last = [ln for ln in out.splitlines() if ln.strip()]
                links = json.loads(last[-1]) if last else []
            except Exception as exc:
                self.send_json({"error": str(exc)}, 400)
                return
            self.send_json({"links": links})
            return

        if parsed.path == "/api/build-summary":
            query = urllib.parse.parse_qs(parsed.query)
            try:
                root = safe_root(query.get("root", [""])[0])
                safe_service("build", root)
                run = query.get("run", ["current"])[0]
                summary = build_summary(selected_log(root, "build", run))
                steps = [
                    {**step, "label": redact_text(str(step.get("label", "")))}
                    for step in summary.get("steps", [])
                ]
                bottleneck = summary.get("bottleneck")
                if bottleneck:
                    bottleneck = {
                        **bottleneck,
                        "label": redact_text(str(bottleneck.get("label", ""))),
                    }
                reasons = [{
                    "kind": str(reason.get("kind") or "unknown"),
                    "service": redact_text(str(reason.get("service") or "")),
                    "label": redact_text(str(reason.get("label") or "")),
                    "change": str(reason.get("change") or "unknown"),
                } for reason in summary.get("reasons", []) if isinstance(reason, dict)]
                self.send_json({**summary, "steps": steps, "bottleneck": bottleneck, "reasons": reasons})
            except Exception as exc:
                self.send_json({"error": str(exc)}, 400)
            return

        if parsed.path in ("/api/logs", "/api/logs/chunk", "/api/logs/download", "/api/logs/matches"):
            query = urllib.parse.parse_qs(parsed.query)
            try:
                root = safe_root(query.get("root", [""])[0])
                service = safe_service(query.get("service", [""])[0], root)
                run = query.get("run", ["current"])[0]
            except Exception as exc:
                self.send_json({"error": str(exc)}, 400)
                return
            if parsed.path == "/api/logs/matches":
                try:
                    q = query.get("q", [""])[0]
                    err_only = query.get("errOnly", ["0"])[0] == "1"
                    if not q and not err_only:
                        self.send_json({"matches": [], "total": 0, "size": 0, "truncated": False})
                    else:
                        self.send_json(scan_log_matches(selected_log(root, service, run), q, err_only))
                except Exception as exc:
                    self.send_json({"error": str(exc)}, 400)
                return
            if parsed.path == "/api/logs/chunk":
                try:
                    after_raw = query.get("after", [None])[0]
                    if after_raw is not None:
                        result = read_log_chunk(selected_log(root, service, run), after=int(after_raw))
                    else:
                        before = int(query.get("before", ["0"])[0])
                        result = read_log_chunk(selected_log(root, service, run), before=before)
                    self.send_json(result)
                except Exception as exc:
                    self.send_json({"error": str(exc)}, 400)
                return
            if parsed.path == "/api/logs/download":
                try:
                    self.download_log(root, service, run)
                except Exception as exc:
                    self.send_json({"error": str(exc)}, 400)
                return
            from_raw = query.get("from", [None])[0]
            try:
                from_offset = int(from_raw) if from_raw is not None else None
            except ValueError:
                self.send_json({"error": "invalid from"}, 400)
                return
            self.stream_log(root, service, run, from_offset)
            return

        self.send_json({"error": "not found"}, 404)

    def do_POST(self) -> None:  # noqa: N802
        try:
            if not host_allowed(self.headers.get("host")):
                self.send_json({"error": "forbidden host"}, 403)
                return
            if not origin_allowed(self.headers.get("origin"), self.path == "/api/console"):
                self.send_json({"error": "forbidden origin"}, 403)
                return

            body = self.read_json()
            if self.path == "/api/console":
                self.send_json(append_console_log(body))
                return

            # ── 터미널 탭 — PTY 셸 = 원격 코드 실행. 로컬 대시보드 전용: 게이트웨이/프록시 경유(X-Forwarded-*) 거부 ──
            if self.path in ("/api/term-open", "/api/term-input", "/api/term-resize", "/api/term-kill"):
                if self.headers.get("x-forwarded-for") or self.headers.get("x-forwarded-host"):
                    self.send_json({"error": "터미널은 로컬 대시보드에서만 쓸 수 있어요"}, 403)
                    return
                if self.path == "/api/term-open":
                    agent = body.get("agent") or {}
                    self.send_json(term_open(safe_root(str(body.get("root", ""))),
                                             int(body.get("cols") or 80), int(body.get("rows") or 24),
                                             agent_source=str(agent.get("source", "")), agent_sid=str(agent.get("sid", ""))))
                elif self.path == "/api/term-input":
                    self.send_json(term_input(str(body.get("tid", "")), str(body.get("data", ""))))
                elif self.path == "/api/term-resize":
                    self.send_json(term_resize(str(body.get("tid", "")), int(body.get("cols") or 80), int(body.get("rows") or 24)))
                else:
                    self.send_json(term_kill(str(body.get("tid", ""))))
                return

            if self.path == "/api/compose-service-args":   # ⓘ 모달에서 build args 저장 → ~/.marina/<id>/build-args.json
                root = Path(str(body.get("root", "")).strip()).expanduser()
                service = str(body.get("service", "")).strip()
                args = body.get("args")
                if not service or not isinstance(args, dict):
                    raise ValueError("service·args(dict) 필요")
                proj = project_for(root)
                if not proj or proj.get("kind") != "compose":
                    raise ValueError("compose 프로젝트 아님")
                clean = {str(k).strip(): str(v) for k, v in args.items() if str(k).strip()}
                d = MARINA_HOME / str(proj["id"]); d.mkdir(parents=True, exist_ok=True)
                bf = d / "build-args.json"
                try:
                    cur = json.loads(bf.read_text(encoding="utf-8"))
                    if not isinstance(cur, dict):
                        raise ValueError("object 아님")
                except FileNotFoundError:
                    cur = {}                              # 없으면 새로 시작
                except (ValueError, OSError) as _e:       # 있는데 손상이면 거부 — {} 로 덮어 다른 서비스 설정 날리지 않게(코덱스 감사 #6)
                    raise ValueError(f"{bf.name} 손상으로 저장 거부(기존 설정 보호) — 파일 확인 후 재시도: {_e}")
                _old = cur.get(service) if isinstance(cur.get(service), dict) else {}   # profile 키는 전용 컨트롤 소관 — build args 저장이 안 지우게 보존
                for _k, _v in _old.items():
                    if is_profile_var(_k) and _k not in clean:
                        clean[_k] = _v
                if clean:
                    cur[service] = clean
                else:
                    cur.pop(service, None)   # 비우면 제거
                bf.write_text(json.dumps(cur, ensure_ascii=False, indent=2), encoding="utf-8")
                self.send_json({"ok": True, "service": service, "args": clean})
                return

            if self.path == "/api/compose-service-profile":   # profile = build-args.json 의 profile 변수 키. var=클라 지정 또는 Dockerfile ARG 감지.
                root = Path(str(body.get("root", "")).strip()).expanduser()
                service = str(body.get("service", "")).strip()
                value = str(body.get("value", "")).strip()
                if not service:
                    raise ValueError("service 필요")
                proj = project_for(root)
                if not proj or proj.get("kind") != "compose":
                    raise ValueError("compose 프로젝트 아님")
                var = str(body.get("var", "")).strip()
                if not var:                              # 클라가 var 안 보내면 그 서비스 resolved view 의 profileVar 로 감지(docker 필요)
                    view = compose_resolved_view(root, proj)
                    svc = next((s for s in (view.get("services") or []) if s.get("service") == service), None)
                    var = (svc or {}).get("profileVar") or ""
                if not var:
                    raise ValueError("이 서비스에서 profile 변수를 찾지 못했습니다 (compose 의 command/env_file 로 자기완결되는 서비스일 수 있음)")
                d = MARINA_HOME / str(proj["id"]); d.mkdir(parents=True, exist_ok=True)
                bf = d / "build-args.json"
                try:
                    cur = json.loads(bf.read_text(encoding="utf-8"))
                    if not isinstance(cur, dict):
                        raise ValueError("object 아님")
                except FileNotFoundError:
                    cur = {}
                except (ValueError, OSError) as _e:       # 손상이면 거부(다른 서비스 build args 보호)
                    raise ValueError(f"{bf.name} 손상으로 저장 거부 — 파일 확인 후 재시도: {_e}")
                if not isinstance(cur.get(service), dict):
                    cur[service] = {}
                if value:
                    cur[service][var] = value
                else:
                    cur[service].pop(var, None)           # 빈 값 = 해제(stored 기본값으로)
                bf.write_text(json.dumps(cur, ensure_ascii=False, indent=2), encoding="utf-8")
                self.send_json({"ok": True, "service": service, "var": var, "value": value})
                return

            if self.path == "/api/compose-prebuild":   # B: 서브레포별 pre-build 명령 저장 → ~/.marina/<id>/prebuild.json
                root = Path(str(body.get("root", "")).strip()).expanduser()
                subrepo = str(body.get("subrepo", "")).strip()
                command = str(body.get("command", "")).strip()
                if not subrepo:
                    raise ValueError("subrepo 필요")
                proj = project_for(root)
                if not proj or proj.get("kind") != "compose":
                    raise ValueError("compose 프로젝트 아님")
                d = MARINA_HOME / str(proj["id"]); d.mkdir(parents=True, exist_ok=True)
                bf = d / "prebuild.json"
                try:
                    cur = json.loads(bf.read_text(encoding="utf-8"))
                    if not isinstance(cur, dict):
                        raise ValueError("object 아님")
                except FileNotFoundError:
                    cur = {}                              # 없으면 새로 시작
                except (ValueError, OSError) as _e:       # 있는데 손상이면 거부 — {} 로 덮어 다른 서비스 설정 날리지 않게(코덱스 감사 #6)
                    raise ValueError(f"{bf.name} 손상으로 저장 거부(기존 설정 보호) — 파일 확인 후 재시도: {_e}")
                if command:
                    cur[subrepo] = command
                else:
                    cur.pop(subrepo, None)
                bf.write_text(json.dumps(cur, ensure_ascii=False, indent=2), encoding="utf-8")
                self.send_json({"ok": True, "subrepo": subrepo, "command": command})
                return

            if self.path == "/api/infer-project":
                target = Path(str(body.get("path", "")).strip()).expanduser()
                if not str(body.get("path", "")).strip() or not target.is_dir():
                    raise ValueError(f"디렉토리 없음: {body.get('path', '')}")
                try:
                    out = run_marina_registry("project", "infer", str(target))
                except subprocess.CalledProcessError as exc:
                    raise ValueError((exc.output or "").strip() or str(exc))
                self.send_json(json.loads(out.strip().splitlines()[-1]))
                return

            if self.path == "/api/add-project":
                target = Path(str(body.get("path", "")).strip()).expanduser()
                if not str(body.get("path", "")).strip() or not target.is_dir():
                    raise ValueError(f"디렉토리 없음: {body.get('path', '')}")
                subrepos = body.get("subrepos", [])
                if not isinstance(subrepos, list) or not all(isinstance(s, str) for s in subrepos):
                    raise ValueError("subrepos must be a list of strings")
                try:
                    out = run_marina_registry("project", "add", str(target), "--subrepos", ",".join(subrepos))
                except subprocess.CalledProcessError as exc:
                    raise ValueError((exc.output or "").strip() or str(exc))
                invalidate_registry_caches()
                # 등록 후 projects.json 을 root 로 재조회한 실제 id (basename 충돌 시 -<해시> 붙은 최종 id)
                final_id = (project_for(target) or {}).get("id") or target.resolve().name
                self.send_json({"ok": True, "id": final_id, "output": out.strip()})
                return

            if self.path == "/api/worktree-create":   # A4 — 대시보드에서 워크트리 생성 (marina worktree create CLI 재사용)
                target = Path(str(body.get("projectRoot", "")).strip()).expanduser()
                if not str(body.get("projectRoot", "")).strip() or not target.is_dir():
                    raise ValueError(f"디렉토리 없음: {body.get('projectRoot', '')}")
                proj = containing_project_for(target)              # 등록 프로젝트 root 자신만 허용 — 워크트리/하위경로에서는 거부
                if not proj or proj["root"].resolve() != target.resolve():
                    raise ValueError("등록된 프로젝트 root 가 아닙니다 — 그 프로젝트의 main 카드에서 시도하세요")
                branch = str(body.get("branch", "")).strip()
                if not re.fullmatch(r"[A-Za-z0-9._/-]+", branch) or ".." in branch:
                    raise ValueError("브랜치명은 영문/숫자/./_/-(슬래시 포함)만 가능 — 공백·'..' 금지")
                try:
                    out = _marina_cli(target, "worktree", "create", branch, timeout=180)
                except subprocess.CalledProcessError as exc:
                    raise ValueError((exc.output or "").strip() or str(exc))
                except subprocess.TimeoutExpired:
                    raise ValueError("워크트리 생성 시간 초과(180s) — 서브레포 attach 가 오래 걸릴 수 있습니다. 잠시 후 새로고침해 확인하세요")
                invalidate_registry_caches()
                m = re.search(r"✓ 워크트리:\s*(.+)", out)   # worktree_create() 의 성공 출력에서 실경로 추출, 실패 시 관례 경로로 폴백
                if m:
                    new_root = m.group(1).strip()
                else:
                    san = re.sub(r"[/:]", "-", branch)
                    new_root = str(target / ".claude" / "worktrees" / san)
                self.send_json({"ok": True, "root": new_root, "output": out.strip()[-2000:]})
                return

            if self.path == "/api/compose-serialize":   # 위저드 검토: services YAML + x-marina dict → 합쳐진 compose 미리보기
                yaml_text = str(body.get("yaml", ""))
                xmarina = body.get("xmarina") if isinstance(body.get("xmarina"), dict) else {}
                build_args = body.get("buildArgs") if isinstance(body.get("buildArgs"), dict) else {}
                try:
                    self.send_json({"ok": True, "yaml": merge_xmarina_into_yaml(yaml_text, xmarina, build_args)})
                except Exception as exc:
                    raise ValueError(f"직렬화 실패: {exc}")
                return

            if self.path == "/api/compose-scan":   # 비-LLM 스캔 — 서브레포 Dockerfile/ARG/EXPOSE/설정후보 (위저드 스텝1, LLM 안 씀)
                target = Path(str(body.get("root", "")).strip()).expanduser()
                if not str(body.get("root", "")).strip() or not target.is_dir():
                    raise ValueError(f"디렉토리 없음: {body.get('root', '')}")
                self.send_json({"ok": True, **_compose_scan(target)})
                return

            if self.path == "/api/compose-validate":   # 등록 없이 단독 검증(M5 인라인 검증) — compose-register 와 같은 compose_validate 재사용
                yaml_text = str(body.get("yaml", ""))
                target = Path(str(body.get("path", "")).strip()).expanduser()
                if not yaml_text.strip():
                    raise ValueError("yaml required")
                if not str(body.get("path", "")).strip() or not target.is_dir():
                    raise ValueError(f"디렉토리 없음: {body.get('path', '')}")
                _own4 = containing_project_for(target)             # 포함 프로젝트만 승격 — 단일 폴백이면 무관 레포 검증이 남의 트리에서 돎(코덱스 P2)
                if _own4 and Path(_own4["root"]).resolve() != target.resolve():
                    target = Path(_own4["root"])
                self.send_json(compose_validate(
                    yaml_text, target,
                    str(body.get("envVar", "")).strip(), str(body.get("envDefault", "")).strip()))
                return

            if self.path == "/api/compose-register":
                target = Path(str(body.get("path", "")).strip()).expanduser()
                if not str(body.get("path", "")).strip() or not target.is_dir():
                    raise ValueError(f"디렉토리 없음: {body.get('path', '')}")
                _own = containing_project_for(target)              # 워크트리 경로면 그걸 실제로 포함하는 프로젝트로 승격 —
                if _own and Path(_own["root"]).resolve() != target.resolve():   # 워크트리 신규등록 버그 차단.
                    target = Path(_own["root"])                    # (project_for 단일 폴백 금지 — 무관한 새 레포 흡수 방지)
                yaml_text = str(body.get("yaml", ""))
                if not yaml_text.strip():
                    raise ValueError("yaml required")
                env_var = str(body.get("envVar", "")).strip()
                env_default = str(body.get("envDefault", "")).strip() or "local"
                compose_file = str(body.get("composeFile", "")).strip() or "docker-compose.yml"
                v = compose_validate(yaml_text, target, env_var, env_default)
                if not v["ok"]:
                    self.send_json({"ok": False, **v})
                    return
                with tempfile.TemporaryDirectory() as td:
                    tmp = Path(td) / compose_file
                    tmp.write_text(yaml_text, encoding="utf-8")
                    args = [str(target), "--compose", str(tmp)]
                    if env_var:
                        args += ["--env-var", env_var, "--env-default", env_default]
                    for er in (body.get("externalRepos") or []):   # 외부 서브레포 기록(워크트리별 격리용)
                        if isinstance(er, dict) and er.get("name") and er.get("sub"):
                            src = str((target / str(er["sub"]).strip("/")).resolve())
                            args += ["--external", f"{er['name']}={src}"]
                    try:
                        out = run_marina_registry("project", "add", *args)
                    except subprocess.CalledProcessError as exc:
                        raise ValueError((exc.output or "").strip() or str(exc))
                invalidate_registry_caches()
                final_id = (project_for(target) or {}).get("id") or target.resolve().name   # 충돌 시 -<해시> 최종 id
                applied = None
                if body.get("apply"):
                    try:
                        applied = _marina_cli(target, "start", "--all")[-1000:]   # up -d: 변경된 서비스만 재생성
                    except subprocess.CalledProcessError as exc:   # docker 빌드/기동 에러를 그대로 노출(원인 보이게)
                        applied = "적용 실패 (compose 는 저장됨 · 수동 재시작 필요):\n" + ((exc.output or "").strip()[-1500:] or str(exc))
                    except Exception as exc:
                        applied = f"적용 실패 (compose 는 저장됨 · 수동 재시작 필요): {exc}"
                invalidate_registry_caches()
                self.send_json({"ok": True, "id": final_id,
                                "output": out.strip(), "warnings": v.get("warnings", []), "applied": applied})
                return

            if self.path == "/api/compose-import":   # 팀원 공유 블록(compose+x-marina) 한 번에 등록+적용 — 위저드/개별설정 생략
                target = Path(str(body.get("root", "")).strip()).expanduser()
                _own2 = containing_project_for(target)             # 워크트리 → 포함 프로젝트 승격(위와 동일 가드, 단일 폴백 금지)
                if _own2 and target.is_dir() and Path(_own2["root"]).resolve() != target.resolve():
                    target = Path(_own2["root"])
                blob = str(body.get("blob", ""))
                if not str(body.get("root", "")).strip() or not target.is_dir():
                    raise ValueError(f"디렉토리 없음: {body.get('root', '')}")
                if not blob.strip():
                    raise ValueError("blob(공유 compose 블록) 필요")
                try:                                  # x-marina 파싱 가능 검증(PyYAML 부재·깨진 YAML → 4xx, 등록 전에 차단)
                    _mc().parse_xmarina(blob)
                except Exception as exc:
                    raise ValueError(f"compose/x-marina 파싱 실패: {exc}")
                env_var = str(body.get("envVar", "")).strip()
                env_default = str(body.get("envDefault", "")).strip() or "local"
                compose_file = str(body.get("composeFile", "")).strip() or "docker-compose.yml"
                v = compose_validate(blob, target, env_var, env_default)   # compose 유효·레포 매칭(빌드컨텍스트 존재) — 불일치면 4xx
                if not v["ok"]:
                    self.send_json({"ok": False, **v}, 400)
                    return
                with tempfile.TemporaryDirectory() as td:
                    tmp = Path(td) / compose_file
                    tmp.write_text(blob, encoding="utf-8")   # blob 그대로 보관 = x-marina 가 stored compose 에 동봉(런타임이 거기서 읽음)
                    args = [str(target), "--compose", str(tmp)]
                    if env_var:
                        args += ["--env-var", env_var, "--env-default", env_default]
                    try:
                        out = run_marina_registry("project", "add", *args)
                    except subprocess.CalledProcessError as exc:
                        raise ValueError((exc.output or "").strip() or str(exc))
                invalidate_registry_caches()
                final_id = (project_for(target) or {}).get("id") or target.resolve().name
                applied = None
                if body.get("apply"):
                    try:
                        applied = _marina_cli(target, "start", "--all")[-1000:]
                    except subprocess.CalledProcessError as exc:
                        applied = "적용 실패 (compose 는 저장됨 · 수동 재시작 필요):\n" + ((exc.output or "").strip()[-1500:] or str(exc))
                    except Exception as exc:
                        applied = f"적용 실패 (compose 는 저장됨 · 수동 재시작 필요): {exc}"
                invalidate_registry_caches()
                self.send_json({"ok": True, "id": final_id, "output": out.strip(),
                                "warnings": v.get("warnings", []), "applied": applied})
                return

            if self.path == "/api/remove-project":
                pid = str(body.get("id", "")).strip()
                if not pid:
                    raise ValueError("id required")
                try:
                    out = run_marina_registry("project", "rm", pid)
                except subprocess.CalledProcessError as exc:
                    raise ValueError((exc.output or "").strip() or str(exc))
                invalidate_registry_caches()
                self.send_json({"ok": True, "output": out.strip()})
                return

            if self.path == "/api/restart-dashboard":
                # 응답 먼저(연결 flush) → detached 로 재기동(자기 종료 후에도 살아남게 setsid).
                self.send_json({"ok": True, "restarting": True})
                try:
                    self.wfile.flush()   # 데몬 종료 전 응답이 클라이언트에 전달되도록 명시 flush
                except Exception:
                    pass
                dash = CONTROL_SCRIPT.parent / "marina-dashboard.sh"
                if os.environ.get("MARINA_RESTART_DRY_RUN") == "1":
                    MARINA_HOME.mkdir(parents=True, exist_ok=True)
                    with (MARINA_HOME / "restart-dry-run.log").open("a", encoding="utf-8") as fh:
                        fh.write(f"would run: bash {dash} restart\n")
                    return
                subprocess.Popen(
                    ["bash", "-c", f"sleep 1; exec bash {shlex.quote(str(dash))} restart"],
                    start_new_session=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                )
                return

            if self.path == "/api/update-claude":
                self.send_json(update_claude())
                return

            if self.path == "/api/update-codex":
                self.send_json(update_codex())
                return

            root = safe_root(str(body.get("root", "")))
            if self.path == "/api/config":
                config_body = body.get("config")
                if not isinstance(config_body, dict):
                    raise ValueError("config must be an object")
                result = write_config(root, {str(k): str(v) for k, v in config_body.items()})
                self.send_json({"config": result})
                return

            if self.path == "/api/link-set":   # host/worktree symlink 링크 쓰기 — 프로젝트 공유(~/.marina/<id>/links.json) | 워크트리 override(overrides.json)
                _svc_raw = str(body.get("service", "")).strip()
                service = "" if not _svc_raw else safe_service(_svc_raw, root)   # ""=워크트리 레벨(모든 서비스/서브레포) override
                name = str(body.get("name", "")).strip()
                op = str(body.get("op", "")).strip()
                scope = str(body.get("scope", "override")).strip()
                if not name or op not in ("disable", "clear", "set") or scope not in ("base", "override"):
                    raise ValueError("name·op(disable|clear|set)·scope(base|override) 필요")
                clean = None
                if op == "set":
                    rule = body.get("rule")
                    if not isinstance(rule, dict):
                        raise ValueError("set 은 rule(object) 필요")
                    if rule.get("glob"):
                        clean = {"glob": str(rule["glob"]), "kind": ("dir" if rule.get("kind") == "dir" else "file")}
                        mode = str(rule.get("mode") or rule.get("op") or "symlink").strip()
                        if mode not in ("symlink", "copy"):
                            raise ValueError("rule.mode 은 symlink|copy 여야 함")
                        if mode == "copy":
                            clean["mode"] = "copy"
                        if rule.get("subrepo"):                 # 구조 열어둠 — 특정 서브레포만(비면 전 서브레포)
                            clean["subrepo"] = str(rule["subrepo"])
                    else:
                        raise ValueError("rule 은 {glob,kind[,mode]} 여야 함")

                if scope == "base":
                    # 링크의 단일 SoT = stored compose 의 x-marina.links (이 머신 로컬 설정 = 공유 단위). 대시보드가 직접 편집(links.json 미사용).
                    #   리스트에 있으면 적용·없으면 안 함 — '켜짐/꺼짐' 별도 상태 없음. set=추가(+폴더 탐색) · clear=빼기(🗑)
                    # ruamel 없어 전체 regen 은 주석 손실 → set_xmarina_link 가 x-marina 블록만 갱신하고 위쪽(services 주석)은 보존.
                    if op not in ("set", "clear"):
                        raise ValueError("base 는 set|clear 만 (x-marina 리스트에 추가/빼기)")
                    proj = project_for(root)
                    if not proj:
                        raise ValueError("프로젝트 미등록 — base 링크 저장 불가")
                    cdir = MARINA_HOME / str(proj["id"]); cdir.mkdir(parents=True, exist_ok=True)
                    stored = cdir / proj.get("composeFile", "docker-compose.yml")
                    _sub = (clean.get("subrepo") if clean else None) or str(body.get("subrepo") or "").strip() or "."
                    if op == "set":
                        _mc().set_xmarina_link(str(stored), _sub, clean["glob"], clean.get("mode") or "symlink", remove=False)
                    else:                              # clear = 🗑 빼기
                        _mc().set_xmarina_link(str(stored), _sub, name, remove=True)
                    _apply_now(root, service)          # 즉시 materialize — 넣으면 바로 이 워크트리에 뜸(main 은 src==dst 라 내부 skip)
                    self.send_json({"ok": True})
                    return

                # scope == override → overrides.json (그 워크트리만): disable(null)·clear(되돌림)·set(리다이렉트)
                sdir = session_dir(root); sdir.mkdir(parents=True, exist_ok=True)
                ojson = sdir / "overrides.json"
                try:
                    cur = json.loads(ojson.read_text(encoding="utf-8")) if ojson.exists() else {}
                    if not isinstance(cur, dict):
                        raise ValueError("object 아님")
                except (ValueError, OSError) as _e:
                    raise ValueError(f"overrides.json 손상으로 저장 거부(기존 설정 보호): {_e}")
                cur.setdefault("version", 1)
                links = cur.setdefault("links", {})
                if not isinstance(links, dict):
                    links = cur["links"] = {}
                svc_links = links.setdefault(service, {})
                if not isinstance(svc_links, dict):
                    svc_links = links[service] = {}
                if op == "disable":
                    svc_links[name] = None
                elif op == "clear":
                    svc_links.pop(name, None)
                else:
                    svc_links[name] = clean
                if not svc_links:
                    links.pop(service, None)
                tmp = ojson.with_suffix(".json.tmp")
                tmp.write_text(json.dumps(cur, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
                tmp.replace(ojson)
                _apply_now(root, service)              # 즉시 materialize — 이 워크트리에 apply(켜기/리다이렉트 바로 반영)
                self.send_json({"ok": True})
                return

            if self.path == "/api/forward-set":   # 연결 탭에서 x-marina.forward(호스트 인프라 localhost 맵) 편집. 재시작해야 적용(컨테이너 기동 때 세팅).
                port = str(body.get("port", "")).strip()
                target = str(body.get("target", "host")).strip() or "host"
                op = str(body.get("op", "")).strip()   # 'set' | 'remove'
                if not port.isdigit() or op not in ("set", "remove"):
                    raise ValueError("port(숫자)·op(set|remove) 필요")
                proj = project_for(root)
                if not proj:
                    raise ValueError("프로젝트 미등록 — forward 저장 불가")
                cdir = MARINA_HOME / str(proj["id"]); cdir.mkdir(parents=True, exist_ok=True)
                stored = cdir / proj.get("composeFile", "docker-compose.yml")
                ok = _mc().set_xmarina_forward(str(stored), port, target, remove=(op == "remove"))
                self.send_json({"ok": bool(ok), "needsRestart": True})
                return

            if self.path == "/api/expose-set":   # 연결 탭에서 x-marina.gateway.expose(서비스↔서비스 URL env 주입) 편집. env 라 재시작해야 적용.
                consumer = str(body.get("consumer", "")).strip()
                var = str(body.get("var", "")).strip()
                target = str(body.get("target", "")).strip()
                mode = str(body.get("mode", "gateway")).strip() or "gateway"
                op = str(body.get("op", "")).strip()   # 'set' | 'remove'
                if not consumer or not var or op not in ("set", "remove"):
                    raise ValueError("consumer·var·op(set|remove) 필요")
                if op == "set" and not target:
                    raise ValueError("set 은 target(서비스명) 필요")
                if mode not in ("gateway", "origin"):
                    raise ValueError("mode 는 gateway|origin")
                proj = project_for(root)
                if not proj:
                    raise ValueError("프로젝트 미등록 — expose 저장 불가")
                cdir = MARINA_HOME / str(proj["id"]); cdir.mkdir(parents=True, exist_ok=True)
                stored = cdir / proj.get("composeFile", "docker-compose.yml")
                ok = _mc().set_xmarina_expose(str(stored), consumer, var, target, mode, remove=(op == "remove"))
                self.send_json({"ok": bool(ok), "needsRestart": True})
                return

            if self.path == "/api/meta":
                meta_body = body.get("meta")
                if not isinstance(meta_body, dict):
                    raise ValueError("meta must be an object")
                result = write_meta(root, {str(k): str(v) for k, v in meta_body.items()})
                self.send_json({"meta": result})
                return

            if self.path == "/api/stop-all":
                self.send_json(stop_all(root))
                return

            if self.path == "/api/start-all":
                self.send_json(start_all(root))
                return

            if self.path == "/api/cleanup":
                self.send_json(cleanup_session(root))
                return

            if self.path == "/api/remove-worktree":
                self.send_json(remove_worktree(root, force=bool(body.get("force"))))
                return

            if self.path == "/api/clear-cache":
                self.send_json(clear_worktree_cache(root, str(body.get("category", "all"))))
                return

            if self.path == "/api/git-commit":   # 깃 탭 WIP 커밋(P2) — root 는 워크트리, main 체크아웃은 백엔드가 거부
                files = body.get("files")
                if not isinstance(files, list) or not all(isinstance(f, str) for f in files):
                    raise ValueError("files must be a list of strings")
                self.send_json(git_commit(root, str(body.get("repo", ".")), files, str(body.get("message", ""))))
                return

            if self.path == "/api/git-push":
                self.send_json(git_push(root, str(body.get("repo", ".")), force=bool(body.get("force"))))
                return

            if self.path == "/api/git-pull":   # D&D ☁→로컬 당겨오기 (기본 ff-only, rebase 옵션)
                self.send_json(git_pull(root, str(body.get("repo", ".")), rebase=bool(body.get("rebase"))))
                return

            if self.path == "/api/git-merge":   # D&D 로컬→로컬 병합 — root = 타깃 브랜치의 워크트리
                self.send_json(git_merge(root, str(body.get("repo", ".")), str(body.get("branch", ""))))
                return

            if self.path == "/api/git-rebase":   # D&D 리베이스 — root = 소스 브랜치의 워크트리, onto = 타깃
                self.send_json(git_rebase(root, str(body.get("repo", ".")), str(body.get("onto", ""))))
                return

            if self.path == "/api/git-fetch":   # REMOTE 섹션 ⇣ — origin 갱신(prune)
                self.send_json(git_fetch(root, str(body.get("repo", "."))))
                return

            if self.path == "/api/git-stash":   # 스태시 — save(WIP 패널)/apply/drop(STASHES 섹션)
                self.send_json(git_stash(root, str(body.get("repo", ".")), str(body.get("op", "")),
                                         ref=str(body.get("ref", "")), message=str(body.get("message", ""))))
                return

            if self.path == "/api/set-default-attach":
                project = project_for(root)
                if not project:
                    raise ValueError("미등록 프로젝트")
                # main/project 카드 전용 — worktree 에서 호출 거부.
                if not (project["root"].resolve() == root.resolve() or is_source_checkout(root)):
                    raise ValueError("기본 attach 편집은 main 카드에서만 가능합니다")
                subs = body.get("subrepos")
                if not isinstance(subs, list) or not all(isinstance(s, str) for s in subs):
                    raise ValueError("subrepos must be a list of strings")
                universe = set(subrepos_of(root))
                bad = [s for s in subs if s not in universe]
                if bad:
                    raise ValueError(f"등록되지 않은 subrepo: {', '.join(bad)}")
                try:
                    out = run_marina_registry("project", "default", project["id"], ",".join(subs))
                except subprocess.CalledProcessError as exc:
                    raise ValueError((exc.output or "").strip() or str(exc))
                invalidate_registry_caches()
                self.send_json({"ok": True, "output": out.strip()})
                return

            if self.path in ("/api/attach-subrepo", "/api/detach-subrepo"):
                subrepo = str(body.get("subrepo", "")).strip()
                if subrepo not in subrepos_of(root):
                    raise ValueError("등록되지 않은 subrepo")
                project = project_for(root)
                is_main_card = (project and project["root"].resolve() == root.resolve()) or is_source_checkout(root)
                if is_main_card:
                    raise ValueError("main 체크아웃은 물리 attach/detach 하지 않습니다 (기본 attach 편집만)")
                if self.path == "/api/attach-subrepo":
                    self.send_json(attach_subrepo_action(root, subrepo))
                else:
                    self.send_json(detach_subrepo_action(
                        root, subrepo,
                        force=bool(body.get("force")),
                        stop_services=bool(body.get("stopServices")),
                    ))
                return

            service = safe_service(str(body.get("service", "")), root)
            force = bool(body.get("force"))
            if self.path == "/api/start":
                result = start_service(root, service, force=force)
            elif self.path == "/api/stop":
                result = stop_service(root, service)
            elif self.path == "/api/stop-external":   # '외부 :<port>' — IDE/터미널 직접 실행 프로세스 정지
                result = stop_external(root, service, int(body.get("port") or 0))
            elif self.path == "/api/restart":
                result = restart_service(root, service, force=force)
            elif self.path == "/api/rebuild":
                result = rebuild_service(root, service, force=force)
            else:
                self.send_json({"error": "not found"}, 404)
                return
            self.send_json(result)
        except Exception as exc:
            self.send_json({"error": str(exc)}, 400)

    def do_OPTIONS(self) -> None:  # noqa: N802
        origin = self.headers.get("origin")
        if not origin_allowed(origin, True):
            self.send_response(403)
            self.end_headers()
            return
        self.send_response(204)
        if origin:
            self.send_header("access-control-allow-origin", origin)
            self.send_header("vary", "origin")
        self.send_header("access-control-allow-methods", "GET, POST, OPTIONS")
        self.send_header("access-control-allow-headers", "content-type")
        self.end_headers()

    def stream_log(self, root: Path, service: str, run: str | None, from_offset: int | None = None) -> None:
        path = selected_log(root, service, run)
        path.parent.mkdir(parents=True, exist_ok=True)
        path.touch(exist_ok=True)

        self.send_response(200)
        self.send_header("content-type", "text/event-stream")
        self.send_header("cache-control", "no-cache")
        origin = self.headers.get("origin")
        if origin and origin_allowed(origin, True):
            self.send_header("access-control-allow-origin", origin)
            self.send_header("vary", "origin")
        self.end_headers()

        idle = 0.0
        with path.open("rb") as handle:
            size = path.stat().st_size
            if from_offset is not None:
                # 클라이언트가 forward 페이징으로 EOF 까지 따라온 뒤 갭 없이 이어받는 재연결 지점
                start = max(0, min(from_offset, size))
                handle.seek(start)
            else:
                start = max(size - LOG_TAIL_BYTES, 0)
                handle.seek(start)
                if start > 0:
                    handle.readline()  # 중간에서 잘린 첫 라인 정렬 — 버린 만큼은 chunk 페이징으로 조회
                    start = handle.tell()
            # 표시 시작 오프셋 + 파일 크기 — 클라이언트 표시 창(top) 초기값과 게이지 분모
            meta = json.dumps({"start": start, "size": size})
            try:
                self.wfile.write(f"event: meta\ndata: {meta}\n\n".encode("utf-8"))
                self.wfile.flush()
            except (BrokenPipeError, ConnectionResetError, OSError):
                return
            while True:
                line = handle.readline()
                if line:
                    idle = 0.0
                    text = line.decode("utf-8", errors="replace").rstrip("\r\n")
                    payload = json.dumps({"line": redact_text(text), "end": handle.tell()}, ensure_ascii=False)
                    try:
                        self.wfile.write(f"data: {payload}\n\n".encode("utf-8"))
                        self.wfile.flush()
                    except (BrokenPipeError, ConnectionResetError, OSError):
                        return
                else:
                    time.sleep(0.5)
                    idle += 0.5
                    # run rotation 감지 — restart 가 <svc>.log 심링크를 새 run 으로 옮겨도 열린 핸들은
                    # 옛 inode 를 tail 해 "재시작 후 로그가 안 뜨는" 원인이었다. 심링크가 다른 파일을
                    # 가리키면 rotated 이벤트로 클라이언트를 새 파일에 재접속시킨다. (~2s 마다)
                    if idle % 2.0 < 0.25:
                        try:
                            if path.stat().st_ino != os.fstat(handle.fileno()).st_ino:
                                try:
                                    self.wfile.write(b"event: rotated\ndata: {}\n\n")
                                    self.wfile.flush()
                                except (BrokenPipeError, ConnectionResetError, OSError):
                                    pass
                                return
                        except OSError:
                            pass
                    if idle >= 10.0:
                        # 로그가 조용하면 write 가 없어 끊긴 클라이언트를 영영 감지 못했다
                        # → keepalive 로 연결 검증, 끊겼으면 스레드 종료 (스레드/fd 누수 방지)
                        idle = 0.0
                        try:
                            self.wfile.write(b": keepalive\n\n")
                            self.wfile.flush()
                        except (BrokenPipeError, ConnectionResetError, OSError):
                            return

    # 전체 로그 파일을 redact 하며 attachment 스트리밍 — 브라우저 DOM 을 거치지 않아 크기 무관
    def download_log(self, root: Path, service: str, run: str | None) -> None:
        path = selected_log(root, service, run)
        run_name = run if run and run != "current" else "current"
        # 세션 id 는 디렉토리명 유래 — 헤더 오염 방지로 안전 문자만
        filename = re.sub(
            r"[^A-Za-z0-9._-]", "_",
            f"marina-{session_id(root)}-{service}-{run_name.removesuffix('.log')}.log",
        )
        self.send_response(200)
        self.send_header("content-type", "text/plain; charset=utf-8")
        self.send_header("content-disposition", f'attachment; filename="{filename}"')
        origin = self.headers.get("origin")
        if origin and origin_allowed(origin, True):
            self.send_header("access-control-allow-origin", origin)
            self.send_header("vary", "origin")
        self.end_headers()
        try:
            with path.open("rb") as handle:
                for raw in handle:
                    text = raw.decode("utf-8", errors="replace").rstrip("\r\n")
                    self.wfile.write(redact_text(text).encode("utf-8") + b"\n")
        except (BrokenPipeError, ConnectionResetError, OSError):
            return

    def log_message(self, fmt: str, *args: Any) -> None:
        print("[marina]", fmt % args)

def main() -> None:
    server = ThreadingHTTPServer((HOST, PORT), Handler)
    print(f"marina: http://{HOST}:{PORT}")
    if _GATEWAY_ON:                                            # 동적반영: 백그라운드 폴링(빠짐없음, diff-reload) + 이벤트 훅(즉각)
        import threading
        import time
        def _gw_loop():
            while True:
                refresh_gateway()
                time.sleep(max(2, int(_env("GATEWAY_POLL", "5") or "5")))   # MARINA_GATEWAY_POLL (빈 문자열 방어)
        threading.Thread(target=_gw_loop, daemon=True).start()
        print(f"marina gateway: caddy {'있음' if _gw().caddy_bin() else '미설치(안내)'} · :{_GATEWAY_PORT} · 폴링+이벤트 동적반영")
    server.serve_forever()
