"""marina_handler.py — marina-control.py 에서 분리(레이어드). 동작 변경 0."""
from __future__ import annotations
import glob
import http.client
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

from marina_state import CONTROL_SCRIPT, HOST, LOG_TAIL_BYTES, MARINA_HOME, PORT, _GATEWAY_ON, _GATEWAY_PORT, _PREVIEW_PORT, _PREVIEW_PUBLIC_PORT, _env, _gw, _mc, invalidate_registry_caches, json_bytes
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
from marina_mobile import disable_mobile_token, ensure_mobile_token, mobile_access_status, mobile_answer, mobile_catalog, mobile_interrupt, mobile_launch, mobile_request_ok, mobile_set_hidden, mobile_set_pin, mobile_send, mobile_state, mobile_update_session_settings, mobile_upload, mobile_upload_file, render_mobile_html, rotate_mobile_token
from marina_sessions import agent_activity, agent_belongs_to_root, agent_session_file_bytes, agent_session_files, agent_transcript, agent_transcript_image, agent_transcript_images, agent_usage, agents_payload, append_console_log, claude_session_titles, codex_session_titles, host_allowed, origin_allowed, provider_account_usage, safe_root, safe_service, session_payload, system_memory, worktree_info, worktree_status
from marina_term import term_input, term_kill, term_list, term_open, term_resize, term_stream
from marina_git import git_commit, git_commit_info, git_diff, git_fetch, git_graph, git_merge, git_pull, git_push, git_rebase, git_stash, git_wip_stat
from marina_lifecycle import _gateway_snapshot, attach_subrepo_action, cleanup_session, clear_worktree_cache, clear_worktree_images, clean_rebuild_service, detach_subrepo_action, rebuild_service, refresh_gateway, remove_worktree, restart_service, start_all, start_service, stop_all, stop_external, stop_service
from marina_auth_http import AUTH_DENIED, auth_controller
from marina_access import AccessPolicy, canonical_agent, canonical_root
from marina_auth import AuthError
from marina_auth_http import is_loopback_client
from marina_remote import RemoteControlError, RemoteController
from marina_remote_service import RemoteService

_WEB_DIR = Path(__file__).resolve().parent / "marina-web"

_ADMIN_GET_PATHS = {
    "/api/browse", "/api/repo-candidates", "/api/compose-detect", "/api/compose-config",
    "/api/compose-export", "/api/compose-scaffold",
}
_ROOT_GET_PATHS = {
    "/api/worktree-changes", "/api/git-graph", "/api/weave-map", "/api/git-wip-stat",
    "/api/git-commit-info", "/api/git-diff", "/api/links", "/api/build-summary",
    "/api/logs", "/api/logs/chunk", "/api/logs/download", "/api/logs/matches",
}
_ADMIN_POST_PATHS = {
    "/api/compose-service-args", "/api/compose-service-profile", "/api/compose-prebuild",
    "/api/infer-project", "/api/add-project", "/api/compose-scan", "/api/compose-validate",
    "/api/compose-register", "/api/compose-import", "/api/remove-project",
    "/api/restart-dashboard", "/api/update-claude", "/api/update-codex",
    "/api/set-default-attach", "/api/forward-set", "/api/expose-set",
}
_ROOT_POST_PATHS = {
    "/api/config", "/api/link-set", "/api/meta", "/api/stop-all", "/api/start-all",
    "/api/cleanup", "/api/remove-worktree", "/api/clear-cache", "/api/clear-images",
    "/api/git-commit", "/api/git-push", "/api/git-pull", "/api/git-merge",
    "/api/git-rebase", "/api/git-fetch", "/api/git-stash", "/api/attach-subrepo",
    "/api/detach-subrepo", "/api/start", "/api/stop", "/api/stop-external",
    "/api/restart", "/api/rebuild", "/api/clean-rebuild",
}
_REMOTE_CONTROLLER: RemoteController | None = None

def render_index_html() -> str:
    """marina-web/index.html 을 읽어 빌드 SHA 토큰을 치환해 반환 (프론트엔드는 marina-web/ 로 분리)."""
    html = (_WEB_DIR / "index.html").read_text(encoding="utf-8")
    return html.replace("{{MARINA_BUILD}}", _serving_sha() or "dev")

class Handler(BaseHTTPRequestHandler):
    def _remote_controller(self) -> RemoteController:
        global _REMOTE_CONTROLLER
        if _REMOTE_CONTROLLER is None:
            _REMOTE_CONTROLLER = RemoteController(MARINA_HOME)
        return _REMOTE_CONTROLLER

    def _auth_guard_self_check(self) -> bool:
        host, port = self.server.server_address[:2]
        connect_host = "127.0.0.1" if str(host) in ("", "0.0.0.0", "::") else str(host)
        def status(path: str) -> tuple[int, str]:
            conn = http.client.HTTPConnection(connect_host, int(port), timeout=2)
            try:
                conn.request("GET", path, headers={"Host": f"127.0.0.1:{port}"})
                response = conn.getresponse()
                response.read()
                return response.status, str(response.getheader("location") or "")
            finally:
                conn.close()
        api_status, _ = status("/api/worktrees")
        page_status, location = status("/")
        return api_status == 401 and page_status == 302 and location.startswith("/login")

    def _remote_service(self) -> RemoteService:
        return RemoteService(
            auth_controller().store,
            self._remote_controller(),
            home=MARINA_HOME,
            control_host=HOST,
            control_port=PORT,
            guard_check=self._auth_guard_self_check,
        )

    def _host_allowed(self) -> bool:
        if host_allowed(self.headers.get("host")):
            return True
        if not is_loopback_client(self) or str(self.headers.get("x-forwarded-proto") or "").lower() != "https":
            return False
        try:
            supplied = urllib.parse.urlsplit("//" + str(self.headers.get("host") or "")).hostname
            expected = self._remote_controller().status().get("dnsName")
            return bool(supplied and expected and supplied.rstrip(".") == str(expected).rstrip("."))
        except Exception:
            return False

    def _origin_allowed(self, allow_any_local_port: bool = False) -> bool:
        origin = self.headers.get("origin")
        if origin_allowed(origin, allow_any_local_port):
            return True
        if str(self.headers.get("x-forwarded-proto") or "").lower() != "https":
            return False
        try:
            origin_parts = urllib.parse.urlsplit(str(origin))
            host_parts = urllib.parse.urlsplit("//" + str(self.headers.get("host") or ""))
            expected = str(self._remote_controller().status().get("dnsName") or "").rstrip(".").lower()
            origin_host = str(origin_parts.hostname or "").rstrip(".").lower()
            request_host = str(host_parts.hostname or "").rstrip(".").lower()
            return bool(
                expected and origin_parts.scheme == "https"
                and origin_host == request_host == expected
                and origin_parts.port in (None, 443)
                and host_parts.port in (None, 443)
            )
        except (TypeError, ValueError):
            return False

    def _schedule_dashboard_restart(self) -> None:
        dash = CONTROL_SCRIPT.parent / "marina-dashboard.sh"
        if os.environ.get("MARINA_RESTART_DRY_RUN") == "1":
            MARINA_HOME.mkdir(parents=True, exist_ok=True)
            with (MARINA_HOME / "restart-dry-run.log").open("a", encoding="utf-8") as fh:
                fh.write(f"would run: bash {dash} restart\n")
            return
        restart_script = f"sleep 1; MARINA_RESTART_HELPER=1 bash {shlex.quote(str(dash))} restart"
        launchctl = shutil.which("launchctl") if sys.platform == "darwin" else None
        if launchctl:
            label = f"marina.dashboard.restart.{os.getpid()}.{time.time_ns()}"
            helper_script = (
                f"{restart_script}; {shlex.quote(launchctl)} remove {shlex.quote(label)} "
                ">/dev/null 2>&1 || true"
            )
            try:
                submitted = subprocess.run(
                    [launchctl, "submit", "-l", label, "--", "/bin/bash", "-c", helper_script],
                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=3,
                )
                if submitted.returncode == 0:
                    return
            except (OSError, subprocess.SubprocessError):
                pass
        subprocess.Popen(
            ["bash", "-c", f"{restart_script};"],
            start_new_session=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )

    # ── 에이전트 API 이중 프리픽스 ──
    # 웹은 /mobile/api/* 를 못 부른다: auth 가 꺼진 로컬에서 principal 이 None 이라 모바일 토큰
    # 검사에 걸려 403 이다. 모바일은 /api/* 를 못 부른다: host_guarded 가 펀넬 호스트를 막는다.
    # 그래서 라우트를 옮기는 대신 웹 전용 별칭 /api/agent/<op> 를 /mobile/api/<op> 로 정규화해
    # **같은 라우트 본문**을 공유한다 (기존 /api/mobile-send·/api/mobile-state 별칭의 일반화).
    _AGENT_API_ALIAS = "/api/agent/"

    def _agent_api_alias(self, parsed: urllib.parse.ParseResult) -> urllib.parse.ParseResult:
        if not parsed.path.startswith(self._AGENT_API_ALIAS):
            return parsed
        self._agent_api_web = True
        return parsed._replace(path="/mobile/api/" + parsed.path[len(self._AGENT_API_ALIAS):])

    def _agent_api_ok(self, parsed: urllib.parse.ParseResult, principal: Any) -> bool:
        """에이전트 API 인증. 웹 경로는 이미 host_guarded(POST 는 origin/CSRF 도)를 통과했으므로
        모바일 토큰을 요구하지 않는다. 자원 권한(_require_root_access·can_resource)은 라우트 본문에서
        종전대로 검사하므로, 이 술어는 '이 표면에 말을 걸 자격'만 판정한다."""
        if principal is not None:
            return True
        if getattr(self, "_agent_api_web", False):
            # auth 꺼진 로컬 대시보드. **Origin 도 본다** — 이 라우트들은 아래쪽 공통 origin 검사에
            # 닿기 전에 반환하고, auth 가 꺼져 있으면 authorize() 도 CSRF 를 안 본다. 그래서 여기서
            # 안 막으면 임의 웹페이지가 text/plain 로 POST 해(프리플라이트 없이) cli-update·send·
            # launch 를 실행시킬 수 있다. origin_allowed 는 Origin 없음(curl)은 통과시키고 교차
            # 출처 브라우저 요청만 막는다.
            return is_loopback_client(self) and self._origin_allowed()
        # 모바일 토큰 경로는 CSRF 대상이 아니다 — 토큰은 쿠키가 아니라 헤더/쿼리라 브라우저가
        # 자동으로 붙여 주지 않고, 커스텀 헤더는 프리플라이트를 유발한다.
        return mobile_request_ok(self, parsed)

    def _git_diff_payload(self, root: Path, query: dict[str, list[str]]) -> dict[str, Any]:
        """git-diff 인자 조합 — 웹(/api/git-diff)과 모바일(/mobile/api/git-diff)이 공유한다.
        복붙해 두면 한쪽만 고쳐진다."""
        return git_diff(root, query.get("repo", ["."])[0],
                        file=query.get("file", [""])[0],
                        commit=query.get("commit", [""])[0])

    def _policy(self) -> AccessPolicy:
        return AccessPolicy(auth_controller().store)

    def _forbidden(self, message: str = "You do not have access to this resource.") -> bool:
        self.send_json({"error": "access_denied", "message": message}, 403)
        return False

    def _require_admin_access(self) -> bool:
        principal = getattr(self, "auth_principal", None)
        if principal is None or principal.user.role == "admin":
            return True
        return self._forbidden("Administrator access is required.")

    def _require_mobile_admin(self) -> bool:
        principal = getattr(self, "auth_principal", None)
        if principal is not None:
            return principal.user.role == "admin" or self._forbidden("Administrator access is required.")
        if not auth_controller().store.auth_enabled() and is_loopback_client(self):
            return True
        return self._forbidden("Mobile access can only be managed locally or by an administrator.")

    def _mobile_access_payload(self) -> dict[str, Any]:
        service = self._remote_service()
        return mobile_access_status(
            service.controller.status(), service.control_host, service.control_port,
            auth_enabled=auth_controller().store.auth_enabled(),
        )

    def _worktree_create(self, controller: Any, principal: Any, body: dict[str, Any]) -> None:
        """워크트리 생성 — 웹(/api/worktree-create)과 모바일(/mobile/api/worktree-create)이 공유한다.
        모바일이 /api/* 를 직접 못 부르는 이유: do_POST 의 host_guarded 가 /api/ 를 호스트로 막아서
        펀넬 호스트에서 오면 'forbidden host' 다(그래서 /api/mobile-send 만 예외로 빠져 있다)."""
        project_id = str(body.get("projectId") or "").strip()
        if project_id:
            proj = next((item for item in load_projects() if str(item.get("id")) == project_id), None)
            if not proj:
                raise ValueError("등록된 프로젝트를 찾지 못했습니다")
            target = Path(proj["root"])
        else:
            target = Path(str(body.get("projectRoot", "")).strip()).expanduser()
            if not str(body.get("projectRoot", "")).strip() or not target.is_dir():
                raise ValueError(f"디렉토리 없음: {body.get('projectRoot', '')}")
            proj = containing_project_for(target)
        if not proj or proj["root"].resolve() != target.resolve():
            raise ValueError("등록된 프로젝트 root 가 아닙니다 — 그 프로젝트의 main 카드에서 시도하세요")
        if not self._policy().can_project(principal, str(proj.get("id") or "")):
            self._forbidden()
            return
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
        if principal is not None:
            owner_root = canonical_root(new_root)
            controller.store.assign_resource_owner(
                "worktree", owner_root, principal.user.id, actor_user_id=principal.user.id
            )
            controller.store.audit_action(
                "worktree.create", "ok", principal.user.id, "worktree", owner_root
            )
        self.send_json({"ok": True, "root": new_root, "output": out.strip()[-2000:]})

    def _require_root_access(self, root: Path) -> bool:
        if self._policy().can_root(getattr(self, "auth_principal", None), root):
            return True
        return self._forbidden()

    def _term_allowed(self, term: dict[str, Any]) -> bool:
        principal = getattr(self, "auth_principal", None)
        tid = str(term.get("tid") or "")
        root = str(term.get("root") or "")
        return bool(tid and root and self._policy().can_resource(principal, "terminal", tid)
                    and self._policy().can_root(principal, root))

    def _term_access_allowed(self, tid: str) -> bool:
        term = next(
            (item for item in term_list().get("sessions", []) if str(item.get("tid") or "") == tid),
            None,
        )
        return bool(term and self._term_allowed(term))

    def _filter_mobile(self, payload: dict[str, Any]) -> dict[str, Any]:
        principal = getattr(self, "auth_principal", None)
        if principal is None or principal.user.role == "admin":
            return payload
        allowed_roots = {
            canonical_root(item.get("root", "")) for item in payload.get("worktrees", [])
            if item.get("root") and self._policy().can_root(principal, item["root"])
        }
        payload["worktrees"] = [item for item in payload.get("worktrees", [])
                                if item.get("root") and canonical_root(item["root"]) in allowed_roots]
        payload["terms"] = [item for item in payload.get("terms", []) if self._term_allowed(item)]
        allowed_tids = {str(item.get("tid")) for item in payload["terms"]}
        filtered = []
        for item in payload.get("sessions", []):
            root = item.get("root")
            if not root or canonical_root(root) not in allowed_roots:
                continue
            if item.get("kind") == "term" and str(item.get("tid")) not in allowed_tids:
                continue
            if item.get("kind") == "agent":
                key = canonical_agent(str(item.get("source") or ""), str(item.get("sid") or ""))
                self._policy().inherit_from_root("agent", key, root)
                if not self._policy().can_resource(principal, "agent", key):
                    continue
            filtered.append(item)
        payload["sessions"] = filtered
        return payload

    # 미리보기 프록시 — 폰에서 워크트리 앱 화면을 열기 위한 유일한 문.
    #
    # 앱은 이미 형 맥에서 돌고 있고(compose), 게이트웨이(Caddy)가 맥 안에서 라우팅까지 한다.
    # 없는 건 **밖에서 거기로 들어가는 문**이다. 게이트웨이 주소는 `<wt>.<proj>.localhost:3902`
    # 인데 `*.localhost` 는 폰에서 이름 해석이 안 되고, Funnel 도 3902 를 안 태운다.
    # 그래서 이미 공개돼 있고 로그인도 걸린 대시보드(3900)에 경로를 하나 내고 그 뒤로 넘긴다.
    #
    # 게이트웨이는 **Host 헤더로** 라우팅하므로, 127.0.0.1:3902 에 붙어 Host 만 갈아 끼우면 된다.
    # 첫 화면만 넘기면 안 된다 — 페이지가 열린 뒤 JS·CSS·API 를 계속 더 부르고 그 요청들도
    # 같은 문을 통과해야 한다. 그래서 단일 응답이 아니라 경로 전체를 그대로 넘긴다.
    _PREVIEW_LABEL_RE = re.compile(r"^[a-z0-9][a-z0-9.-]{0,120}$")
    # 홉바이홉 헤더는 그대로 옮기면 안 된다(연결 수명은 이쪽 소켓의 것이다).
    _HOP_BY_HOP = frozenset({"connection", "keep-alive", "proxy-authenticate", "proxy-authorization",
                             "te", "trailers", "transfer-encoding", "upgrade"})

    def _preview_cookie(self) -> str:
        for chunk in str(self.headers.get("cookie") or "").split(";"):
            name, _, value = chunk.strip().partition("=")
            if name == "marina_preview":
                value = urllib.parse.unquote(value).lower()
                return value if self._PREVIEW_LABEL_RE.match(value) else ""
        return ""

    # 대시보드 포트에는 **쿠키 기반 fallback 을 두지 않는다.**
    #
    # 한때 "미리보기 모드"라며 마리나 소유가 아닌 경로를 앱으로 흘렸는데, 그 목록이 닫혀 있다는
    # 전제가 틀렸다. 브라우저는 `/favicon.ico`·`/manifest.webmanifest`·`/apple-touch-icon.png`
    # 같은 걸 **알아서** 요청하고, 그게 전부 앱으로 새서 마리나 탭 아이콘이 Dozzle 것으로
    # 바뀌었다(형 발견). 소유 경로를 아무리 열거해도 브라우저·표준이 추가하는 경로를 다 못 쫓는다.
    #
    # 루트를 요구하는 앱은 **전용 포트**(PreviewHandler)가 담당한다 — 거긴 앱이 경로를 통째로
    # 소유하므로 이런 충돌 자체가 없다. 한 문제에 장치는 하나면 된다.

    def _serve_preview(self, parsed: urllib.parse.ParseResult, method: str) -> bool:
        """`/preview/<label>/<경로>` → 게이트웨이. 처리했으면 True."""
        rest = parsed.path[len("/preview/"):]
        label, _, tail = rest.partition("/")
        label = urllib.parse.unquote(label).lower()
        if not self._PREVIEW_LABEL_RE.match(label):
            self.send_json({"error": "invalid preview target"}, 400)
            return True
        target = "/" + tail + (f"?{parsed.query}" if parsed.query else "")
        return self._proxy_to_gateway(label, target, method)

    def _proxy_to_gateway(self, label: str, target: str, method: str, set_cookie: str = "") -> bool:
        if not _GATEWAY_ON:
            self.send_json({"error": "gateway_off",
                            "message": "게이트웨이가 꺼져 있어요 — marina gateway on 으로 켜주세요."}, 503)
            return True
        # 업그레이드 요청은 HTTP 응답이 아니라 터널이다 — http.client 로는 다룰 수 없다.
        if "websocket" in str(self.headers.get("upgrade") or "").lower():
            return self._proxy_websocket(label, target)
        body = b""
        length = int(self.headers.get("content-length") or 0)
        if length > 0:
            body = self.rfile.read(length)
        headers = {k: v for k, v in self.headers.items()
                   if k.lower() not in self._HOP_BY_HOP and k.lower() not in ("host", "cookie", "authorization")}
        # 쿠키·인증은 넘기지 않는다 — 마리나 세션 쿠키가 앱으로 새면 안 된다(앱은 남의 코드다).
        headers["Host"] = f"{label}.localhost"
        headers["Accept-Encoding"] = "identity"   # 중간에서 다시 압축 풀 일을 만들지 않는다
        try:
            conn = http.client.HTTPConnection("127.0.0.1", _GATEWAY_PORT, timeout=30)
            conn.request(method, target, body=body or None, headers=headers)
            upstream = conn.getresponse()
        except OSError as exc:
            self.send_json({"error": "preview_unreachable",
                            "message": f"미리보기에 연결하지 못했어요 ({exc}). 서비스가 떠 있는지 확인해주세요."}, 502)
            return True
        try:
            declared = upstream.getheader("content-length")
            # **스트리밍을 통째로 읽으면 안 된다.** SSE(text/event-stream)는 끝나지 않는 응답이라
            # read() 가 영원히 안 돌아온다 — Dozzle 이 "API 연결 시간 초과"를 띄운 게 이것이다.
            # 길이를 모르는 응답(=chunked·SSE)은 흘려보내고, 연결을 닫아 끝을 알린다.
            ctype = (upstream.getheader("content-type") or "").lower()
            streaming = declared is None or ctype.startswith("text/event-stream")
            self.send_response(upstream.status)
            for key, value in upstream.getheaders():
                if key.lower() in self._HOP_BY_HOP or key.lower() == "content-length":
                    continue
                # 앱이 굽는 쿠키는 그대로 두되 마리나 쿠키와 섞이지 않게 경로를 좁힌다 —
                # 앱 쿠키가 Path=/ 로 올라오면 대시보드 요청에도 딸려간다.
                if key.lower() == "set-cookie":
                    value = re.sub(r"(?i);\s*path=[^;]*", "", value) + "; Path=/"
                self.send_header(key, value)
            if set_cookie:
                # HttpOnly: 앱 JS 가 이 값을 읽을 이유가 없다. SameSite=Lax: 교차 사이트 요청엔 안 딸려간다.
                self.send_header("set-cookie",
                                 f"marina_preview={urllib.parse.quote(set_cookie)}; Path=/; SameSite=Lax; HttpOnly")
            if streaming:
                # **HTTP/1.1 + chunked 여야 한다.** 1.0 으로 "닫힐 때까지 읽어라" 식으로 흘리면
                # fetch 는 바이트를 받지만 **EventSource 는 이벤트를 하나도 안 뿜는다**(실측:
                # 앱 직접 evt=1 vs 프록시 evt=0, funnel 없이도 동일). Dozzle 은 EventSource 를
                # 쓰므로 컨테이너 목록이 영영 안 차고 "Loading…" 에 머문다.
                chunked = self.protocol_version == "HTTP/1.1"
                if chunked:
                    self.send_header("transfer-encoding", "chunked")
                else:
                    self.send_header("connection", "close")
                self.end_headers()
                if method != "HEAD":
                    while True:
                        # **read1 이어야 한다.** http.client 의 read(n) 은 n 바이트가 찰 때까지
                        # 블록해서, 이벤트 꼬리가 다음 이벤트가 올 때까지 우리 안에 갇힌다.
                        # 그러면 SSE 종결자(\n\n)가 제때 안 나가 EventSource 가 이벤트를 영영
                        # 완성하지 못한다(실측: 앱 직접은 종결자 포함 174,759B, 프록시는 172,200B
                        # =8192×21 에서 멈춤 → Dozzle 컨테이너 목록이 안 참). read1 은 있는 만큼만 준다.
                        chunk = upstream.read1(8192)
                        if not chunk:
                            break
                        if chunked:
                            self.wfile.write(b"%X\r\n" % len(chunk) + chunk + b"\r\n")
                        else:
                            self.wfile.write(chunk)
                        self.wfile.flush()   # SSE 는 즉시 나가야 의미가 있다 — 버퍼에 쌓아두면 실시간이 아니다
                    if chunked:
                        self.wfile.write(b"0\r\n\r\n")
                        self.wfile.flush()
            else:
                payload = upstream.read()
                self.send_header("content-length", str(len(payload)))
                self.end_headers()
                if method != "HEAD":
                    self.wfile.write(payload)
        except (BrokenPipeError, ConnectionResetError):
            pass          # 형이 탭을 닫은 것 — 스트리밍에선 정상 종료다
        finally:
            conn.close()
        return True

    def _proxy_websocket(self, label: str, target: str) -> bool:
        """WebSocket 업그레이드를 그대로 터널링한다. 처리했으면 True.

        http.client 로는 못 한다 — 101 이후는 HTTP 가 아니라 양방향 바이트 스트림이다.
        그래서 게이트웨이에 **생 소켓**으로 붙어 요청을 그대로 흘리고, 그 뒤부터는 두 소켓을
        서로 복사한다. 업그레이드 헤더(Upgrade·Connection)는 여기선 홉바이홉이 아니라 **본질**이라
        반드시 살려 보내야 한다(그걸 버려서 Dozzle 의 실시간 연결이 아예 안 붙었다).
        """
        import selectors
        import socket

        try:
            upstream = socket.create_connection(("127.0.0.1", _GATEWAY_PORT), timeout=10)
        except OSError as exc:
            self.send_json({"error": "preview_unreachable", "message": f"미리보기 연결 실패 ({exc})"}, 502)
            return True
        lines = [f"{self.command} {target} HTTP/1.1", f"Host: {label}.localhost"]
        for key, value in self.headers.items():
            if key.lower() in ("host", "cookie", "authorization"):
                continue          # 마리나 세션은 앱으로 넘기지 않는다
            lines.append(f"{key}: {value}")
        upstream.sendall(("\r\n".join(lines) + "\r\n\r\n").encode("latin-1", "ignore"))
        client = self.connection
        upstream.settimeout(None)
        client.settimeout(None)
        sel = selectors.DefaultSelector()
        sel.register(client, selectors.EVENT_READ, upstream)
        sel.register(upstream, selectors.EVENT_READ, client)
        try:
            while True:
                for key, _ in sel.select(timeout=300):
                    data = key.fileobj.recv(65536)
                    if not data:
                        return True
                    key.data.sendall(data)
        except OSError:
            return True
        finally:
            sel.close()
            try:
                upstream.close()
            except OSError:
                pass
        return True

    def send_json(self, payload: Any, status: int = 200, headers: list[tuple[str, str]] | None = None) -> None:
        data = json_bytes(payload)
        self.send_response(status)
        self.send_header("content-type", "application/json; charset=utf-8")
        self.send_header("cache-control", "no-store")
        origin = self.headers.get("origin")
        if origin and origin_allowed(origin, True):
            # localhost 웹앱(/api/console)만 CORS 응답 허용 — 구버전의 무차별 `*` 제거
            self.send_header("access-control-allow-origin", origin)
            self.send_header("vary", "origin")
        for name, value in headers or []:
            self.send_header(name, value)
        self.send_header("content-length", str(len(data)))
        auth_controller().add_security_headers(self)
        self.end_headers()
        self.wfile.write(data)

    def read_json(self) -> dict[str, Any]:
        length = int(self.headers.get("content-length", "0"))
        raw = self.rfile.read(length) if length else b"{}"
        return json.loads(raw.decode("utf-8"))

    def do_GET(self) -> None:  # noqa: N802
        parsed = urllib.parse.urlparse(self.path)
        host_guarded = parsed.path.startswith("/api/") and parsed.path not in ("/api/mobile-state",)
        if host_guarded and not self._host_allowed():
            self.send_json({"error": "forbidden host"}, 403)
            return
        parsed = self._agent_api_alias(parsed)   # /api/agent/<op> → /mobile/api/<op> (호스트 가드 '뒤')
        controller = auth_controller()
        if controller.dispatch(self, "GET", parsed):
            return
        principal = controller.authorize(self, "GET", parsed)
        if principal is AUTH_DENIED:
            return
        self.auth_principal = principal
        # 인증 통과 **뒤에** 둔다 — /preview 는 PUBLIC_PREFIXES 가 아니므로 로그인 없이는 여기 못 온다.
        if parsed.path.startswith("/preview/") and self._serve_preview(parsed, "GET"):
            return
        if parsed.path == "/api/mobile/access":
            if not self._require_mobile_admin():
                return
            self.send_json(self._mobile_access_payload())
            return
        if parsed.path == "/api/remote/status":
            try:
                remote = self._remote_service().status()
                browser_fields = (
                    "installed", "online", "state", "mode", "dnsName", "url", "owned",
                    "conflict", "actionUrl", "error", "message", "readiness",
                    "dashboardHost", "dashboardPort",
                )
                self.send_json({key: remote[key] for key in browser_fields if key in remote})
            except (AuthError, RemoteControlError) as exc:
                self.send_json({"error": exc.code, "message": exc.message}, getattr(exc, "status", 409))
            return
        if parsed.path == "/login":
            data = (_WEB_DIR / "login.html").read_bytes()
            self.send_response(200)
            self.send_header("content-type", "text/html; charset=utf-8")
            self.send_header("cache-control", "no-store")
            self.send_header("content-length", str(len(data)))
            controller.add_security_headers(self)
            self.end_headers()
            self.wfile.write(data)
            return
        if parsed.path == "/mobile":
            data = render_mobile_html(auth_enabled=principal is not None).encode("utf-8")
            self.send_response(200)
            self.send_header("content-type", "text/html; charset=utf-8")
            self.send_header("cache-control", "no-store, no-cache, must-revalidate")
            self.send_header("content-length", str(len(data)))
            controller.add_security_headers(self)
            self.end_headers()
            self.wfile.write(data)
            return
        # 서비스워커·매니페스트는 **정적 자산**이고 인증을 요구하면 안 된다. 서비스워커는 로그인
        # 쿠키 없이 등록되는 순간이 있고(설치 시점), 등록에 실패하면 푸시 알림 자체가 불가능해진다.
        # 내용에 비밀이 없다(코드뿐) — 알림 내용은 SW 가 인증된 요청으로 따로 가져온다.
        if parsed.path in ("/mobile/sw.js", "/mobile/manifest.webmanifest", "/mobile/icon.png"):
            asset = parsed.path.rsplit("/", 1)[1]
            try:
                data = (_WEB_DIR / asset).read_bytes()
            except OSError:
                self.send_json({"error": "not found"}, 404)
                return
            self.send_response(200)
            self.send_header("content-type",
                             "application/javascript; charset=utf-8" if asset.endswith(".js")
                             else "image/png" if asset.endswith(".png")
                             else "application/manifest+json; charset=utf-8")
            # 서비스워커는 최신이어야 한다 — 옛 SW 가 남으면 고친 알림 로직이 영영 안 걸린다.
            self.send_header("cache-control", "no-cache")
            self.send_header("content-length", str(len(data)))
            controller.add_security_headers(self)
            self.end_headers()
            self.wfile.write(data)
            return
        if parsed.path == "/mobile/api/push-key":
            if not self._agent_api_ok(parsed, principal):
                self.send_json({"error": "mobile disabled or invalid token"}, 403)
                return
            try:
                from marina_push import public_key
                self.send_json({"key": public_key()})
            except Exception as exc:
                self.send_json({"error": str(exc)}, 500)
            return
        if parsed.path == "/mobile/api/alerts":
            if not self._agent_api_ok(parsed, principal):
                self.send_json({"error": "mobile disabled or invalid token"}, 403)
                return
            from marina_notify import pending_alerts
            raw = urllib.parse.parse_qs(parsed.query).get("since", ["0"])[0]
            try:
                since = float(raw)
            except ValueError:
                since = 0.0
            self.send_json({"alerts": pending_alerts(since)})
            return
        if parsed.path == "/mobile/api/events":
            if not self._agent_api_ok(parsed, principal):
                self.send_json({"error": "mobile disabled or invalid token"}, 403)
                return
            self.stream_marina_events()
            return
        if parsed.path in ("/mobile/api/state", "/api/mobile-state"):
            if not self._agent_api_ok(parsed, principal):
                self.send_json({"error": "mobile disabled or invalid token"}, 403)
                return
            query = urllib.parse.parse_qs(parsed.query)
            self.send_json(self._filter_mobile(mobile_state(
                refresh=query.get("refresh", ["0"])[0] == "1",
                include_all=query.get("all", ["0"])[0] == "1")))
            return
        if parsed.path == "/mobile/api/catalog":
            if not self._agent_api_ok(parsed, principal):
                self.send_json({"error": "mobile disabled or invalid token"}, 403)
                return
            query = urllib.parse.parse_qs(parsed.query)
            try:
                root = safe_root(query.get("root", [""])[0])
                if not self._require_root_access(root):
                    return
                self.send_json(mobile_catalog(root, query.get("source", [""])[0], query.get("q", [""])[0]))
            except Exception as exc:
                self.send_json({"error": str(exc)}, 400)
            return
        if parsed.path == "/mobile/api/services":
            if not self._agent_api_ok(parsed, principal):
                self.send_json({"error": "mobile disabled or invalid token"}, 403)
                return
            query = urllib.parse.parse_qs(parsed.query)
            try:
                root = safe_root(query.get("root", [""])[0])
                if not self._require_root_access(root):
                    return
                session = session_payload(root)
                open_urls: dict[str, str] = {}
                if _GATEWAY_ON:
                    snapshot = next(
                        (item for item in _gateway_snapshot()
                         if item.get("id") == session.get("id") and item.get("projectId") == session.get("projectId")),
                        None,
                    )
                    if snapshot:
                        # 게이트웨이 주소(<wt>.<proj>.localhost:3902)는 **이 맥에서만** 열린다.
                        # 폰이나 다른 기기로 접속했으면 그 주소를 줘도 이름 해석이 안 돼 아무 일도
                        # 안 일어난다. 그때는 미리보기 문(전용 포트)을 거치는 주소를 준다 —
                        # 형이 접속에 쓴 호스트를 그대로 쓰므로 별도 설정이 필요 없다.
                        remote_host = str(self.headers.get("host") or "").split(":")[0]
                        is_local = remote_host in ("localhost", "127.0.0.1", "::1", "")
                        for route in _gw().summarize_gateway([snapshot], _GATEWAY_PORT):
                            name = str(route.get("service") or "")
                            domain = str(route.get("domain") or "")
                            if is_local:
                                open_urls[name] = f"http://{domain}/"
                            else:
                                label = domain.split(":")[0]
                                if label.endswith(".localhost"):
                                    label = label[: -len(".localhost")]
                                open_urls[name] = (f"https://{remote_host}:{_PREVIEW_PUBLIC_PORT}"
                                                   f"/__room?label={urllib.parse.quote(label)}")
                services = [{
                    "service": str(item.get("service") or ""),
                    "running": bool(item.get("running")),
                    "state": str(item.get("state") or ("running" if item.get("running") else "stopped")),
                    "stateReason": str(item.get("stateReason") or item.get("busyError") or ""),
                    "health": item.get("health"),
                    "port": item.get("port"),
                    "degraded": bool(item.get("degraded")),
                    "openUrl": open_urls.get(str(item.get("service") or ""), ""),
                    # 모바일 로그 시트의 run 선택 — 서버는 'current' 또는 'run-NNN.log' 만 받는다.
                    # 웹은 이 값을 세션 페이로드에서 받아 쓴다(app-4-logs renderRunSelect).
                    "logRuns": item.get("logRuns") or [],
                } for item in session.get("services", []) if item.get("service")]
                self.send_json({
                    "root": str(root), "running": sum(1 for item in services if item["running"]),
                    "defined": len(services), "services": services,
                })
            except Exception as exc:
                self.send_json({"error": str(exc)}, 400)
            return
        if parsed.path == "/mobile/api/transcript":
            if not self._agent_api_ok(parsed, principal):
                self.send_json({"error": "mobile disabled or invalid token"}, 403)
                return
            query = urllib.parse.parse_qs(parsed.query)
            try:
                root = safe_root(query.get("root", [""])[0])
                if not self._require_root_access(root):
                    return
                agent_key = canonical_agent(query.get("source", [""])[0], query.get("sid", [""])[0])
                self._policy().inherit_from_root("agent", agent_key, root)
                if not self._policy().can_resource(principal, "agent", agent_key):
                    self._forbidden()
                    return
                raw_before = query.get("before", [""])[0]
                before = int(raw_before) if raw_before else None
                payload = agent_transcript(root, query.get("source", [""])[0],
                                           query.get("sid", [""])[0], before=before, limit=40)
            except Exception as exc:
                self.send_json({"error": str(exc)}, 400)
                return
            self.send_json(payload)
            return
        if parsed.path in ("/mobile/api/session-files", "/mobile/api/session-file"):
            # 이 세션이 만든/바꾼 파일 — 목록(/session-files)과 원본(/session-file).
            # 원본 서빙은 새 노출면이라 좁게 잠근다: 경로가 워크트리 안으로 resolve 돼야 하고(심링크 탈출 차단),
            # 이미지 화이트리스트 외에는 전부 text/plain + nosniff(대시보드 오리진에서 HTML/JS 실행 방지).
            if not self._agent_api_ok(parsed, principal):
                self.send_json({"error": "mobile disabled or invalid token"}, 403)
                return
            query = urllib.parse.parse_qs(parsed.query)
            try:
                root = safe_root(query.get("root", [""])[0])
                if not self._require_root_access(root):
                    return
                if parsed.path == "/mobile/api/session-files":
                    source, sid = query.get("source", [""])[0], query.get("sid", [""])[0]
                    agent_key = canonical_agent(source, sid)
                    self._policy().inherit_from_root("agent", agent_key, root)
                    if not self._policy().can_resource(principal, "agent", agent_key):
                        self._forbidden()
                        return
                    if not agent_belongs_to_root(root, source, sid):
                        self._forbidden()
                        return
                    self.send_json(agent_session_files(root, source, sid))
                    return
                data, content_type = agent_session_file_bytes(root, query.get("path", [""])[0])
            except Exception as exc:
                self.send_json({"error": str(exc)}, 400)
                return
            self.send_response(200)
            self.send_header("content-type", content_type)
            self.send_header("x-content-type-options", "nosniff")
            self.send_header("content-disposition", "inline")
            self.send_header("cache-control", "private, no-cache")   # 파일은 계속 바뀐다 — 캐시 금지
            self.send_header("content-length", str(len(data)))
            auth_controller().add_security_headers(self)
            self.end_headers()
            self.wfile.write(data)
            return
        if parsed.path in ("/mobile/api/transcript-image", "/mobile/api/images"):
            # 대화 안 이미지 — 목록(/images)과 원본 바이트(/transcript-image). 트랜스크립트에 base64 로
            # 박혀 있어서 타임라인엔 ref 만 싣고 여기서 그 줄만 다시 읽어 준다.
            if not self._agent_api_ok(parsed, principal):
                self.send_json({"error": "mobile disabled or invalid token"}, 403)
                return
            query = urllib.parse.parse_qs(parsed.query)
            source = query.get("source", [""])[0]
            sid = query.get("sid", [""])[0]
            try:
                root = safe_root(query.get("root", [""])[0])
                if not self._require_root_access(root):
                    return
                agent_key = canonical_agent(source, sid)
                self._policy().inherit_from_root("agent", agent_key, root)
                if not self._policy().can_resource(principal, "agent", agent_key):
                    self._forbidden()
                    return
                if not agent_belongs_to_root(root, source, sid):
                    self._forbidden()
                    return
                if parsed.path == "/mobile/api/images":
                    raw_limit = query.get("limit", [""])[0]
                    payload = agent_transcript_images(root, source, sid,
                                                      int(raw_limit) if raw_limit.isdigit() else 0)
                    self.send_json(payload)
                    return
                data, content_type = agent_transcript_image(root, source, sid,
                                                            query.get("ref", [""])[0])
            except Exception as exc:
                self.send_json({"error": str(exc)}, 400)
                return
            self.send_response(200)
            self.send_header("content-type", content_type)
            # ref 는 (파일 오프셋, 블록 인덱스)라 내용이 안 바뀐다 — 길게 캐시해 폴링마다 재전송을 막는다.
            self.send_header("cache-control", "private, max-age=86400, immutable")
            self.send_header("content-length", str(len(data)))
            auth_controller().add_security_headers(self)
            self.end_headers()
            self.wfile.write(data)
            return
        if parsed.path == "/mobile/api/file":
            if not self._agent_api_ok(parsed, principal):
                self.send_json({"error": "mobile disabled or invalid token"}, 403)
                return
            query = urllib.parse.parse_qs(parsed.query)
            try:
                data, content_type = mobile_upload_file(query.get("name", [""])[0])
            except (FileNotFoundError, ValueError):
                self.send_json({"error": "not found"}, 404)
                return
            self.send_response(200)
            self.send_header("content-type", content_type)
            self.send_header("cache-control", "private, max-age=86400")
            self.send_header("content-length", str(len(data)))
            auth_controller().add_security_headers(self)
            self.end_headers()
            self.wfile.write(data)
            return
        if parsed.path == "/mobile/api/usage":
            if not self._agent_api_ok(parsed, principal):
                self.send_json({"error": "mobile disabled or invalid token"}, 403)
                return
            query = urllib.parse.parse_qs(parsed.query)
            try:
                root = safe_root(query.get("root", [""])[0])
                if not self._require_root_access(root):
                    return
                source = query.get("source", [""])[0]
                sid = query.get("sid", [""])[0]
                if not agent_belongs_to_root(root, source, sid):
                    self._forbidden()
                    return
                agent_key = canonical_agent(source, sid)
                self._policy().inherit_from_root("agent", agent_key, root)
                if not self._policy().can_resource(principal, "agent", agent_key):
                    self._forbidden()
                    return
                payload = agent_usage(root, source, sid)
                payload["accountUsage"] = provider_account_usage(source, root)
            except Exception as exc:
                self.send_json({"error": str(exc)}, 400)
                return
            self.send_json(payload)
            return
        if parsed.path == "/mobile/api/activity":
            if not self._agent_api_ok(parsed, principal):
                self.send_json({"error": "mobile disabled or invalid token"}, 403)
                return
            query = urllib.parse.parse_qs(parsed.query)
            try:
                root = safe_root(query.get("root", [""])[0])
                if not self._require_root_access(root):
                    return
                source = query.get("source", [""])[0]
                sid = query.get("sid", [""])[0]
                agent_key = canonical_agent(source, sid)
                self._policy().inherit_from_root("agent", agent_key, root)
                if not self._policy().can_resource(principal, "agent", agent_key):
                    self._forbidden()
                    return
                payload = {"subagents": agent_activity(root, source, sid)}
            except Exception as exc:
                self.send_json({"error": str(exc)}, 400)
                return
            self.send_json(payload)
            return
        if parsed.path in ("/mobile/api/logs/chunk", "/mobile/api/logs/matches"):
            # 모바일 로그 뷰어(읽기 전용). 서버 로직은 웹 /api/logs/* 와 **같은 함수**를 쓴다 — 신규 0.
            # 다운로드·콘솔로그·게이지·SSE 스트림은 넣지 않는다(작은 화면 ROI + 노출면 최소).
            if not self._agent_api_ok(parsed, principal):
                self.send_json({"error": "mobile disabled or invalid token"}, 403)
                return
            query = urllib.parse.parse_qs(parsed.query)
            try:
                root = safe_root(query.get("root", [""])[0])
                if not self._require_root_access(root):
                    return
                service = safe_service(query.get("service", [""])[0], root)
                path = selected_log(root, service, query.get("run", ["current"])[0])
                if parsed.path.endswith("/matches"):
                    q = query.get("q", [""])[0]
                    err_only = query.get("errOnly", ["0"])[0] == "1"
                    payload = ({"matches": [], "total": 0, "size": 0, "truncated": False}
                               if not q and not err_only else scan_log_matches(path, q, err_only))
                else:
                    after_raw = query.get("after", [None])[0]
                    payload = (read_log_chunk(path, after=int(after_raw)) if after_raw is not None
                               else read_log_chunk(path, before=int(query.get("before", ["0"])[0])))
            except Exception as exc:
                self.send_json({"error": str(exc)}, 400)
                return
            self.send_json(payload)
            return
        if parsed.path in ("/mobile/api/git-graph", "/mobile/api/git-wip-stat",
                           "/mobile/api/git-diff", "/mobile/api/git-commit-info"):
            # 모바일 깃(읽기 전용) — 커밋·푸시·머지 같은 쓰기는 의도적으로 노출하지 않는다.
            # 레인 그래프는 안 그리고 커밋 리스트로만 쓰므로 all_remotes/avatars 도 끈다.
            if not self._agent_api_ok(parsed, principal):
                self.send_json({"error": "mobile disabled or invalid token"}, 403)
                return
            query = urllib.parse.parse_qs(parsed.query)
            try:
                root = safe_root(query.get("root", [""])[0])
                if not self._require_root_access(root):
                    return
                repo = query.get("repo", ["."])[0]
                if parsed.path.endswith("git-graph"):
                    payload = git_graph(root, repo,
                                        refresh=query.get("refresh", ["0"])[0] == "1",
                                        all_remotes=False, want_avatars=False)
                elif parsed.path.endswith("git-wip-stat"):
                    payload = git_wip_stat(root, repo)
                elif parsed.path.endswith("git-commit-info"):
                    payload = git_commit_info(root, repo, query.get("commit", [""])[0])
                else:
                    payload = self._git_diff_payload(root, query)
            except Exception as exc:
                self.send_json({"error": str(exc)}, 400)
                return
            self.send_json(payload)
            return
        if parsed.path == "/mobile/api/update-status":
            # 모바일엔 업데이트 상태 라우트 자체가 없었다 — marina 플러그인도, CLI 버전도 못 봤다.
            # 웹의 /api/update-status 와 같은 페이로드(cli 키 포함)를 준다.
            if not self._agent_api_ok(parsed, principal):
                self.send_json({"error": "mobile disabled or invalid token"}, 403)
                return
            self.send_json(update_status())
            return
        if parsed.path == "/api/gateway-status":
            light = urllib.parse.parse_qs(parsed.query).get("light", ["0"])[0] == "1"   # light=1: enabled/port 만(routes=비싼 스냅샷 생략 — 카드 URL 계산용)
            if not light and not self._require_admin_access():
                return
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
            controller.add_security_headers(self)
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
            controller.add_security_headers(self)
            self.end_headers()
            self.wfile.write(data)
            return

        if parsed.path.startswith("/api/"):
            # Host 먼저 — origin_allowed 는 Origin 없는 요청을 통과시키는데 DNS 리바인딩된
            # same-origin GET 이 바로 그 모양이다(브라우저가 Origin 을 안 보낸다).
            if not self._host_allowed():
                self.send_json({"error": "forbidden host"}, 403)
                return

        if parsed.path in _ADMIN_GET_PATHS and not self._require_admin_access():
            return
        if parsed.path in _ROOT_GET_PATHS:
            query = urllib.parse.parse_qs(parsed.query)
            try:
                guarded_root = safe_root(query.get("root", [""])[0])
            except Exception as exc:
                self.send_json({"error": str(exc)}, 400)
                return
            if not self._require_root_access(guarded_root):
                return
            if not origin_allowed(self.headers.get("origin"), False):
                self.send_json({"error": "forbidden origin"}, 403)
                return

        if parsed.path == "/api/sessions":
            memory = memory_snapshot()
            roots = [root for root in discover_roots() if self._policy().can_root(principal, root)]
            sessions = [session_payload(root, memory=memory) for root in roots]
            for item in sessions:
                item["webPortConflictWith"] = []
            if principal is not None and principal.user.role != "admin":
                memory = {**memory, "containers": []}
            self.send_json({"sessions": sessions, "memory": memory})
            return

        if parsed.path == "/api/worktrees":
            query = urllib.parse.parse_qs(parsed.query)
            refresh = query.get("refresh", ["0"])[0] == "1"
            # 세션 타이틀은 앱에서 수정 시 빨리 반영돼야 해 캐시된 worktree_info 밖에서 신선하게 덧씌운다.
            titles = claude_session_titles(refresh)       # Claude 데스크톱 (20s 캐시)
            codex_titles = codex_session_titles(refresh)  # Codex (60s 캐시)
            roots = [root for root in discover_all_roots(refresh) if self._policy().can_root(principal, root)]
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
                agents = agents_payload(root, refresh)   # status/reachable/승격 다 resolve_session_liveness 경유(activate_agent_payloads 는 이제 이 경로엔 불필요)
                if principal is not None and principal.user.role != "admin":
                    visible_agents = []
                    for agent in agents:
                        key = canonical_agent(str(agent.get("source") or ""), str(agent.get("sid") or ""))
                        self._policy().inherit_from_root("agent", key, root)
                        if self._policy().can_resource(principal, "agent", key):
                            visible_agents.append(agent)
                    agents = visible_agents
                if agents:
                    info["agents"] = agents
                worktrees.append(info)
            projects = []
            for project in load_projects():
                project_id = str(project.get("id") or "")
                if not project_id or not self._policy().can_project(principal, project_id):
                    continue
                item = {"id": project_id, "label": project_id, "canCreate": True}
                if principal is None or principal.user.role == "admin":
                    item["root"] = str(project.get("root") or "")
                projects.append(item)
            self.send_json({"worktrees": worktrees, "projects": projects})
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
            if principal is None and (self.headers.get("x-forwarded-for") or self.headers.get("x-forwarded-host")):
                self.send_json({"error": "터미널은 로컬 대시보드에서만 쓸 수 있어요"}, 403)
                return
            if parsed.path == "/api/term-list":
                payload = term_list()
                if principal is not None and principal.user.role != "admin":
                    payload["sessions"] = [item for item in payload.get("sessions", []) if self._term_allowed(item)]
                self.send_json(payload)
                return
            query = urllib.parse.parse_qs(parsed.query)
            tids = [t for t in query.get("tid", [""])[0].split(",") if t]
            if principal is not None and principal.user.role != "admin":
                by_tid = {str(item.get("tid")): item for item in term_list().get("sessions", [])}
                if any(tid not in by_tid or not self._term_allowed(by_tid[tid]) for tid in tids):
                    self._forbidden()
                    return
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
                if not self._require_root_access(root):
                    return
                agent_key = canonical_agent(query.get("source", [""])[0], query.get("sid", [""])[0])
                self._policy().inherit_from_root("agent", agent_key, root)
                if not self._policy().can_resource(principal, "agent", agent_key):
                    self._forbidden()
                    return
                raw_before = query.get("before", [""])[0]
                before = int(raw_before) if raw_before else None
                payload = agent_transcript(root, query.get("source", [""])[0],
                                           query.get("sid", [""])[0], before=before, limit=40)
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
                payload = self._git_diff_payload(root, query)
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
            parsed = urllib.parse.urlparse(self.path)
            host_guarded = parsed.path.startswith("/api/") and parsed.path not in ("/api/mobile-send",)
            if host_guarded and not self._host_allowed():
                self.send_json({"error": "forbidden host"}, 403)
                return
            parsed = self._agent_api_alias(parsed)   # /api/agent/<op> → /mobile/api/<op> (호스트 가드 '뒤')
            controller = auth_controller()
            if controller.dispatch(self, "POST", parsed):
                return
            principal = controller.authorize(self, "POST", parsed)
            if principal is AUTH_DENIED:
                return
            self.auth_principal = principal
            # 앱이 페이지를 연 뒤 부르는 API 도 같은 문을 통과해야 한다 — GET 만 열면 화면이 반쪽 난다.
            if parsed.path.startswith("/preview/") and self._serve_preview(parsed, "POST"):
                return
            if parsed.path in ("/api/remote/serve", "/api/remote/funnel", "/api/remote/off"):
                if not self._require_admin_access():
                    return
                try:
                    body = self.read_json()
                    service = self._remote_service()
                    if parsed.path == "/api/remote/off":
                        result = service.off(principal)
                    else:
                        mode = parsed.path.rsplit("/", 1)[-1]
                        result = service.activate(mode, principal, str(body.get("password") or ""))
                    self.send_json(result)
                    if result.get("restartRequired"):
                        try:
                            self.wfile.flush()
                        except Exception:
                            pass
                        self._schedule_dashboard_restart()
                except (AuthError, RemoteControlError) as exc:
                    payload = {"error": exc.code, "message": exc.message}
                    payload.update(getattr(exc, "details", {}) or {})
                    self.send_json(payload, getattr(exc, "status", 409))
                return
            if parsed.path in ("/mobile/api/send", "/api/mobile-send"):
                if not self._agent_api_ok(parsed, principal):
                    self.send_json({"error": "mobile disabled or invalid token"}, 403)
                    return
                mobile_body = self.read_json()
                root = safe_root(str(mobile_body.get("root", "")))
                if not self._require_root_access(root):
                    return
                target = mobile_body.get("target") if isinstance(mobile_body.get("target"), dict) else {}
                target_type = str(target.get("type") or "shell")
                if target_type == "term":
                    tid = str(target.get("tid") or "")
                    if not self._policy().can_resource(principal, "terminal", tid):
                        self._forbidden()
                        return
                if target_type == "agent":
                    source, sid = str(target.get("source") or ""), str(target.get("sid") or "")
                    if not agent_belongs_to_root(root, source, sid):
                        self._forbidden()
                        return
                    agent_key = canonical_agent(source, sid)
                    self._policy().inherit_from_root("agent", agent_key, root)
                    if not self._policy().can_resource(principal, "agent", agent_key):
                        self._forbidden()
                        return
                result = mobile_send(mobile_body)
                if principal is not None:
                    self._policy().assign(principal, "terminal", str(result.get("tid") or ""), parent_root=root)
                    if target_type == "agent":
                        self._policy().assign(principal, "agent", agent_key, parent_root=root)
                    controller.store.audit_action(
                        "agent.prompt" if target_type == "agent" else "terminal.input",
                        "ok", principal.user.id, target_type, agent_key if target_type == "agent" else str(result.get("tid") or ""),
                    )
                self.send_json(result)
                return
            if parsed.path == "/mobile/api/upload":
                if not self._agent_api_ok(parsed, principal):
                    self.send_json({"error": "mobile disabled or invalid token"}, 403)
                    return
                try:
                    query = urllib.parse.parse_qs(parsed.query)
                    root = safe_root(query.get("root", [""])[0])
                    if not self._require_root_access(root):
                        return
                    length = int(self.headers.get("content-length", "0"))
                    if length <= 0:
                        raise ValueError("빈 파일")
                    if length > 20 * 1024 * 1024:
                        raise ValueError("파일이 너무 큽니다(최대 20MB)")
                    data = self.rfile.read(length)
                    raw_name = self.headers.get("x-marina-filename")
                    filename = (urllib.parse.unquote(raw_name) if raw_name
                                else query.get("filename", [""])[0] or "file")
                    result = mobile_upload(root, filename, data)
                    if principal is not None:
                        controller.store.audit_action(
                            "mobile.upload", "ok", principal.user.id, "worktree", canonical_root(root),
                        )
                    self.send_json(result)
                except Exception as exc:
                    self.send_json({"error": str(exc)}, 400)
                return
            if parsed.path == "/mobile/api/launch":
                # 에이전트 새 세션 직접 launch — 워크트리 만들고 셸 열고 `claude` 치던 3스텝을 한 번으로.
                # sid 가 없는 새 세션이라 agent 자원 권한 검사는 root 권한으로 갈음한다(세션이 아직 없다).
                if not self._agent_api_ok(parsed, principal):
                    self.send_json({"error": "mobile disabled or invalid token"}, 403)
                    return
                try:
                    mobile_body = self.read_json()
                    root = safe_root(str(mobile_body.get("root", "")))
                    if not self._require_root_access(root):
                        return
                    result = mobile_launch(mobile_body)
                    if principal is not None:
                        self._policy().assign(principal, "terminal", str(result.get("tid") or ""), parent_root=root)
                        controller.store.audit_action(
                            "agent.launch", "ok", principal.user.id, "terminal", str(result.get("tid") or ""),
                        )
                    self.send_json(result)
                except Exception as exc:
                    self.send_json({"error": str(exc)}, 400)
                return
            if parsed.path == "/mobile/api/interrupt":
                if not self._agent_api_ok(parsed, principal):
                    self.send_json({"error": "mobile disabled or invalid token"}, 403)
                    return
                try:
                    mobile_body = self.read_json()
                    root = safe_root(str(mobile_body.get("root", "")))
                    if not self._require_root_access(root):
                        return
                    target = mobile_body.get("target") if isinstance(mobile_body.get("target"), dict) else {}
                    source, sid = str(target.get("source") or ""), str(target.get("sid") or "")
                    if not agent_belongs_to_root(root, source, sid):
                        self._forbidden()
                        return
                    result = mobile_interrupt(mobile_body)
                    if principal is not None:
                        controller.store.audit_action(
                            "agent.interrupt", "ok", principal.user.id, "agent", canonical_agent(source, sid),
                        )
                    self.send_json(result)
                except Exception as exc:
                    self.send_json({"error": str(exc)}, 400)
                return
            if parsed.path == "/mobile/api/cli-update":
                # claude/codex CLI 자체를 올린다. 실행 파일을 갈아치우므로 그 하네스의 세션이
                # 하나라도 돌고 있으면 409 로 거부한다 — 돌던 세션이 깨지는 게 더 비싸다.
                if not self._agent_api_ok(parsed, principal):
                    self.send_json({"error": "mobile disabled or invalid token"}, 403)
                    return
                if not self._require_admin_access():
                    return
                try:
                    from marina_cliver import BusyError, cli_update
                    mobile_body = self.read_json()
                    result = cli_update(str(mobile_body.get("harness", "")))
                    if principal is not None:
                        controller.store.audit_action(
                            "cli.update", "ok", principal.user.id, "harness", str(result.get("harness") or ""),
                        )
                    self.send_json(result)
                except BusyError as exc:
                    self.send_json({"error": "busy", "busy": exc.busy}, 409)
                except Exception as exc:
                    self.send_json({"error": str(exc)}, 400)
                return
            if parsed.path in ("/mobile/api/pins", "/mobile/api/hidden", "/mobile/api/worktree-create"):
                # 모바일 표면은 /mobile/api/* 에 산다 — /api/* 는 호스트 가드에 막혀 펀넬에서 못 부른다.
                if not self._agent_api_ok(parsed, principal):
                    self.send_json({"error": "mobile disabled or invalid token"}, 403)
                    return
                try:
                    mobile_body = self.read_json()
                    if parsed.path == "/mobile/api/pins":
                        root = safe_root(str(mobile_body.get("root", "")))
                        if not self._require_root_access(root):
                            return
                        self.send_json(mobile_set_pin(mobile_body))
                        return
                    if parsed.path == "/mobile/api/hidden":
                        root = safe_root(str(mobile_body.get("root", "")))
                        if not self._require_root_access(root):
                            return
                        self.send_json(mobile_set_hidden(mobile_body))
                        return
                    self._worktree_create(controller, principal, mobile_body)
                except Exception as exc:
                    self.send_json({"error": str(exc)}, 400)
                return
            if parsed.path in ("/mobile/api/push-subscribe", "/mobile/api/push-unsubscribe"):
                if not self._agent_api_ok(parsed, principal):
                    self.send_json({"error": "mobile disabled or invalid token"}, 403)
                    return
                from marina_push import add_subscription, remove_subscription
                try:
                    body = self.read_json()
                    endpoint = str(body.get("endpoint") or "")
                    # endswith("subscribe") 로 가르면 unsubscribe 도 걸린다 — 경로를 정확히 본다.
                    self.send_json(add_subscription(endpoint, str(body.get("label") or ""))
                                   if parsed.path == "/mobile/api/push-subscribe"
                                   else remove_subscription(endpoint))
                except Exception as exc:
                    self.send_json({"error": str(exc)}, 400)
                return
            if parsed.path == "/mobile/api/answer":
                if not self._agent_api_ok(parsed, principal):
                    self.send_json({"error": "mobile disabled or invalid token"}, 403)
                    return
                try:
                    mobile_body = self.read_json()
                    root = safe_root(str(mobile_body.get("root", "")))
                    if not self._require_root_access(root):
                        return
                    target = mobile_body.get("target") if isinstance(mobile_body.get("target"), dict) else {}
                    source, sid = str(target.get("source") or ""), str(target.get("sid") or "")
                    if not agent_belongs_to_root(root, source, sid):
                        self._forbidden()
                        return
                    agent_key = canonical_agent(source, sid)
                    self._policy().inherit_from_root("agent", agent_key, root)
                    if not self._policy().can_resource(principal, "agent", agent_key):
                        self._forbidden()
                        return
                    result = mobile_answer(mobile_body)
                    if principal is not None:
                        controller.store.audit_action(
                            "agent.answer", "ok", principal.user.id, "agent", agent_key,
                        )
                    self.send_json(result)
                except Exception as exc:
                    self.send_json({"error": str(exc)}, 400)
                return
            if parsed.path == "/mobile/api/services/action":
                if not self._agent_api_ok(parsed, principal):
                    self.send_json({"error": "mobile disabled or invalid token"}, 403)
                    return
                try:
                    mobile_body = self.read_json()
                    root = safe_root(str(mobile_body.get("root", "")))
                    if not self._require_root_access(root):
                        return
                    service = safe_service(str(mobile_body.get("service", "")), root)
                    action = str(mobile_body.get("action") or "")
                    if action == "start":
                        result = start_service(root, service)
                    elif action == "stop":
                        result = stop_service(root, service)
                    elif action == "restart":
                        result = restart_service(root, service)
                    else:
                        raise ValueError("unknown service action")
                    if principal is not None:
                        controller.store.audit_action(
                            f"service.{action}", "ok", principal.user.id, "worktree",
                            canonical_root(root), request_meta="service=" + service,
                        )
                    self.send_json({"ok": True, "action": action, "service": service, "result": result})
                except Exception as exc:
                    self.send_json({"error": str(exc)}, 400)
                return
            if parsed.path == "/mobile/api/settings":
                if not self._agent_api_ok(parsed, principal):
                    self.send_json({"error": "mobile disabled or invalid token"}, 403)
                    return
                try:
                    mobile_body = self.read_json()
                    root = safe_root(str(mobile_body.get("root", "")))
                    if not self._require_root_access(root):
                        return
                    source, sid = str(mobile_body.get("source") or ""), str(mobile_body.get("sid") or "")
                    if not agent_belongs_to_root(root, source, sid):
                        self._forbidden()
                        return
                    result = mobile_update_session_settings(mobile_body)
                    if principal is not None:
                        controller.store.audit_action(
                            "agent.settings", "ok", principal.user.id, "agent", canonical_agent(source, sid),
                        )
                    self.send_json({"ok": True, **result})
                except Exception as exc:
                    self.send_json({"error": str(exc)}, 400)
                return
            if not self._host_allowed():
                self.send_json({"error": "forbidden host"}, 403)
                return
            if not self._origin_allowed(self.path == "/api/console"):
                self.send_json({"error": "forbidden origin"}, 403)
                return

            body = self.read_json()
            if self.path in ("/api/mobile/enable", "/api/mobile/rotate", "/api/mobile/disable"):
                if not self._require_mobile_admin():
                    return
                if self.path == "/api/mobile/enable":
                    ensure_mobile_token()
                elif self.path == "/api/mobile/rotate":
                    rotate_mobile_token()
                else:
                    disable_mobile_token()
                if principal is not None:
                    controller.store.audit_action(
                        "mobile.access.change", "ok", principal.user.id, "mobile",
                        self.path.rsplit("/", 1)[-1],
                    )
                self.send_json(self._mobile_access_payload())
                return
            if self.path in _ADMIN_POST_PATHS and not self._require_admin_access():
                return
            if self.path in _ROOT_POST_PATHS:
                try:
                    guarded_root = safe_root(str(body.get("root", "")))
                except Exception as exc:
                    self.send_json({"error": str(exc)}, 400)
                    return
                if not self._require_root_access(guarded_root):
                    return
            if self.path == "/api/console":
                self.send_json(append_console_log(body))
                return

            # 훅이 "방금 뭔가 했다"고 찌른다 — 감시 루프가 다음 주기를 기다리지 않게.
            # **로컬 전용**: 프록시를 거쳐 오면 거부한다. 아무 것도 바꾸지 않는 신호지만,
            # 외부에서 마음대로 부르면 상태 계산을 무한정 돌릴 수 있다(값싼 DoS 표면).
            if self.path == "/api/events-poke":
                if self.headers.get("x-forwarded-for") or self.headers.get("x-forwarded-host"):
                    self.send_json({"error": "local only"}, 403)
                    return
                from marina_events import poke
                self.send_json({"ok": True, "watching": poke()})
                return

            # ── 터미널 탭 — PTY 셸 = 원격 코드 실행. 로컬 대시보드 전용: 게이트웨이/프록시 경유(X-Forwarded-*) 거부 ──
            if self.path in ("/api/term-open", "/api/term-input", "/api/term-resize", "/api/term-kill"):
                if principal is None and (self.headers.get("x-forwarded-for") or self.headers.get("x-forwarded-host")):
                    self.send_json({"error": "터미널은 로컬 대시보드에서만 쓸 수 있어요"}, 403)
                    return
                if self.path == "/api/term-open":
                    agent = body.get("agent") or {}
                    root = safe_root(str(body.get("root", "")))
                    if not self._require_root_access(root):
                        return
                    agent_key = canonical_agent(str(agent.get("source", "")), str(agent.get("sid", "")))
                    if agent.get("sid"):
                        if not agent_belongs_to_root(
                            root, str(agent.get("source", "")), str(agent.get("sid", ""))
                        ):
                            self._forbidden()
                            return
                        self._policy().inherit_from_root("agent", agent_key, root)
                        if not self._policy().can_resource(principal, "agent", agent_key):
                            self._forbidden()
                            return
                    result = term_open(root, int(body.get("cols") or 80), int(body.get("rows") or 24),
                                       agent_source=str(agent.get("source", "")), agent_sid=str(agent.get("sid", "")))
                    if principal is not None:
                        self._policy().assign(principal, "terminal", str(result.get("tid") or ""), parent_root=root)
                        if agent.get("sid"):
                            self._policy().assign(principal, "agent", agent_key, parent_root=root)
                        controller.store.audit_action(
                            "terminal.open", "ok", principal.user.id, "terminal", str(result.get("tid") or "")
                        )
                    self.send_json(result)
                elif self.path == "/api/term-input":
                    tid = str(body.get("tid", ""))
                    if not self._term_access_allowed(tid):
                        self._forbidden()
                        return
                    self.send_json(term_input(tid, str(body.get("data", ""))))
                elif self.path == "/api/term-resize":
                    tid = str(body.get("tid", ""))
                    if not self._term_access_allowed(tid):
                        self._forbidden()
                        return
                    self.send_json(term_resize(tid, int(body.get("cols") or 80), int(body.get("rows") or 24)))
                else:
                    tid = str(body.get("tid", ""))
                    if not self._term_access_allowed(tid):
                        self._forbidden()
                        return
                    result = term_kill(tid)
                    if principal is not None:
                        controller.store.audit_action("terminal.kill", "ok", principal.user.id, "terminal", tid)
                    self.send_json(result)
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
                self._worktree_create(controller, principal, body)
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
                self._schedule_dashboard_restart()
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
                result = stop_all(root)
                if principal is not None:
                    controller.store.audit_action("service.stop_all", "ok", principal.user.id, "worktree", canonical_root(root))
                self.send_json(result)
                return

            if self.path == "/api/start-all":
                result = start_all(root, force=bool(body.get("force")))
                if principal is not None:
                    controller.store.audit_action("service.start_all", "ok", principal.user.id, "worktree", canonical_root(root))
                self.send_json(result)
                return

            if self.path == "/api/cleanup":
                result = cleanup_session(root)
                if principal is not None:
                    controller.store.audit_action("worktree.cleanup", "ok", principal.user.id, "worktree", canonical_root(root))
                self.send_json(result)
                return

            if self.path == "/api/remove-worktree":
                result = remove_worktree(root, force=bool(body.get("force")))
                root_result = result.get("root") if isinstance(result, dict) else None
                removed = isinstance(root_result, dict) and (
                    "removed" in root_result or "missing" in root_result
                )
                actor_id = principal.user.id if principal is not None else None
                if removed:
                    parent_key = canonical_root(root)
                    controller.store.remove_resources_by_parent(
                        "worktree", parent_key, actor_user_id=actor_id
                    )
                    controller.store.remove_resource_owner(
                        "worktree", parent_key, actor_user_id=actor_id
                    )
                if principal is not None:
                    controller.store.audit_action(
                        "worktree.remove", "ok" if removed else "failed", actor_id,
                        "worktree", canonical_root(root),
                    )
                self.send_json(result)
                return

            if self.path == "/api/clear-cache":
                self.send_json(clear_worktree_cache(root, str(body.get("category", "all"))))
                return

            if self.path == "/api/clear-images":
                self.send_json(clear_worktree_images(root))
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
            elif self.path == "/api/clean-rebuild":
                result = clean_rebuild_service(root, service, force=force)
            else:
                self.send_json({"error": "not found"}, 404)
                return
            if principal is not None:
                controller.store.audit_action(
                    "service." + self.path.rsplit("/", 1)[-1], "ok", principal.user.id,
                    "worktree", canonical_root(root), request_meta="service=" + service,
                )
            self.send_json(result)
        except Exception as exc:
            self.send_json({"error": str(exc)}, 400)

    def do_OPTIONS(self) -> None:  # noqa: N802
        origin = self.headers.get("origin")
        if not origin_allowed(origin, True):
            self.send_response(403)
            auth_controller().add_security_headers(self)
            self.end_headers()
            return
        self.send_response(204)
        if origin:
            self.send_header("access-control-allow-origin", origin)
            self.send_header("vary", "origin")
        self.send_header("access-control-allow-methods", "GET, POST, OPTIONS")
        self.send_header("access-control-allow-headers", "content-type, x-marina-csrf")
        auth_controller().add_security_headers(self)
        self.end_headers()

    def stream_marina_events(self) -> None:
        """상태 변화를 밀어준다 — 폰이 3초마다 물어보지 않아도 되게.

        연결이 끊겨도 화면은 폴링으로 계속 돈다(SSE 는 빠르게 하는 장치이지 유일한 통로가
        아니다). 터널·프록시가 스트림을 접는 환경이 실제로 있어서, 폴백을 없애면 그런 데서
        화면이 통째로 멈춘다. 하트비트를 주기적으로 보내 죽은 연결을 서로 빨리 알아챈다."""
        from marina_events import event_bus, sse_frame

        bus = event_bus()
        token = bus.subscribe()
        self.send_response(200)
        self.send_header("content-type", "text/event-stream")
        self.send_header("cache-control", "no-cache")
        self.send_header("x-accel-buffering", "no")   # 프록시가 모아뒀다 보내면 실시간이 아니다
        origin = self.headers.get("origin")
        if origin and origin_allowed(origin, True):
            self.send_header("access-control-allow-origin", origin)
            self.send_header("vary", "origin")
        auth_controller().add_security_headers(self)
        self.end_headers()
        try:
            self.wfile.write(b": connected\n\n")
            self.wfile.flush()
            while True:
                events = bus.wait(token, 20.0)
                if not events:
                    self.wfile.write(b": ping\n\n")      # 하트비트 — 끊긴 연결을 빨리 알아챈다
                else:
                    for event in events:
                        self.wfile.write(sse_frame(event))
                self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError, OSError, ValueError):
            pass                                          # 폰이 화면을 껐다 — 정상 종료다
        finally:
            bus.unsubscribe(token)

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
        auth_controller().add_security_headers(self)
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
        auth_controller().add_security_headers(self)
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

class PreviewHandler(BaseHTTPRequestHandler):
    """미리보기 전용 리스너 — **앱이 URL 루트를 소유한다**.

    경로 접두사(`/preview/<label>/`)로는 안 되는 앱이 있다. Dozzle 처럼 `base:""` 로 자기가
    루트에 있다고 믿는 SPA 는, 접두사가 붙은 주소를 받으면 자기 라우터가 길을 잃어 "페이지 없음"을
    띄운다(형 실측). 자산을 아무리 잘 흘려줘도 이건 못 고친다 — 앱이 루트를 가져야 한다.

    그래서 대시보드(443/3900)와 **다른 포트**에 문을 하나 더 낸다. 방 선택은 쿠키로 하고,
    나머지 경로는 전부 앱 것이다. 쿠키는 포트를 가리지 않으므로 마리나 로그인 세션이 그대로
    먹는다 — 인증을 새로 만들 필요가 없다.

    바깥 노출은 `tailscale funnel --https=8443 http://127.0.0.1:<PREVIEW_PORT>` 로 붙인다.
    """

    server_version = "marina-preview"
    # HTTP/1.1 이어야 chunked 로 스트리밍할 수 있다. 1.0 으로 흘리면 EventSource 가 이벤트를
    # 하나도 안 뿜어 Dozzle 같은 앱이 영영 "Loading…" 에 머문다(실측). 대시보드 쪽은 건드리지
    # 않는다 — 거긴 keep-alive 반응이 달라질 수 있고, 스트리밍이 필요한 건 이 리스너다.
    protocol_version = "HTTP/1.1"
    _ROOM_PATH = "/__room"      # 방 선택 진입점. 앱 경로와 겹치지 않게 이중 밑줄로 격리한다.
    # Handler 의 프록시 코드를 그대로 빌려 쓴다(중복 구현 금지) — 그 코드가 **self 에서 찾는 것**은
    # 상수든 메서드든 전부 여기에도 있어야 한다. 값을 복사하지 않고 같은 객체를 가리키게 둔다.
    # (빠뜨리면 런타임 AttributeError 로 빈 응답이 나간다 — 상수·메서드 각각 한 번씩 겪었다.)
    _PREVIEW_LABEL_RE = Handler._PREVIEW_LABEL_RE
    _HOP_BY_HOP = Handler._HOP_BY_HOP
    _proxy_websocket = Handler._proxy_websocket

    def send_json(self, payload: Any, status: int = 200,
                  headers: list[tuple[str, str]] | None = None) -> None:
        # Handler._proxy_to_gateway 를 그대로 빌려 쓰므로 같은 이름이 필요하다(오류 응답에 쓴다).
        body = json_bytes(payload)
        self.send_response(status)
        self.send_header("content-type", "application/json; charset=utf-8")
        for key, value in (headers or []):
            self.send_header(key, value)
        self.send_header("content-length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _deny(self, status: int, message: str) -> None:
        self.send_json({"error": message}, status)

    def _handle(self, method: str) -> None:
        parsed = urllib.parse.urlparse(self.path)
        controller = auth_controller()
        try:
            if controller.store.auth_enabled() and controller._principal(self) is None:
                # 미리보기 포트에는 로그인 폼을 두지 않는다 — 대시보드에서 로그인하고 오면 쿠키가 따라온다.
                self._deny(401, "먼저 마리나 대시보드에서 로그인해주세요.")
                return
        except Exception as exc:
            self._deny(503, f"auth unavailable: {exc}")
            return
        if parsed.path == self._ROOM_PATH or parsed.path.startswith(self._ROOM_PATH + "/"):
            query = urllib.parse.parse_qs(parsed.query)
            label = (query.get("label", [""])[0] or parsed.path[len(self._ROOM_PATH):].strip("/")).lower()
            if not Handler._PREVIEW_LABEL_RE.match(label):
                self._deny(400, "invalid preview target")
                return
            self.send_response(302)
            self.send_header("location", "/")
            self.send_header("set-cookie",
                             f"marina_preview={urllib.parse.quote(label)}; Path=/; SameSite=Lax; HttpOnly")
            self.send_header("content-length", "0")
            self.end_headers()
            return
        label = Handler._preview_cookie(self)
        if not label:
            self._deny(400, "어느 방을 볼지 안 정해졌어요 — 대시보드에서 미리보기를 눌러주세요.")
            return
        target = parsed.path + (f"?{parsed.query}" if parsed.query else "")
        Handler._proxy_to_gateway(self, label, target, method)

    def do_GET(self) -> None:      # noqa: N802
        self._handle("GET")

    def do_POST(self) -> None:     # noqa: N802
        self._handle("POST")

    def do_HEAD(self) -> None:     # noqa: N802
        self._handle("HEAD")

    def do_PUT(self) -> None:      # noqa: N802
        self._handle("PUT")

    def do_DELETE(self) -> None:   # noqa: N802
        self._handle("DELETE")

    def log_message(self, fmt: str, *args: Any) -> None:
        print("[marina-preview]", fmt % args)


def main() -> None:
    server = ThreadingHTTPServer((HOST, PORT), Handler)
    print(f"marina: http://{HOST}:{PORT}")
    if _PREVIEW_PORT:
        import threading as _pt
        try:
            preview = ThreadingHTTPServer((HOST, _PREVIEW_PORT), PreviewHandler)
        except OSError as exc:
            print(f"[marina] preview 포트 {_PREVIEW_PORT} 을 열지 못했습니다: {exc}")
        else:
            _pt.Thread(target=preview.serve_forever, daemon=True, name="marina-preview").start()
            print(f"marina preview: http://{HOST}:{_PREVIEW_PORT} (funnel 8443 로 연결)")
    if _GATEWAY_ON:                                            # 동적반영: 백그라운드 폴링(빠짐없음, diff-reload) + 이벤트 훅(즉각)
        import threading
        import time
        def _gw_loop():
            while True:
                refresh_gateway()
                time.sleep(max(2, int(_env("GATEWAY_POLL", "5") or "5")))   # MARINA_GATEWAY_POLL (빈 문자열 방어)
        threading.Thread(target=_gw_loop, daemon=True).start()
        print(f"marina gateway: caddy {'있음' if _gw().caddy_bin() else '미설치(안내)'} · :{_GATEWAY_PORT} · 폴링+이벤트 동적반영")
    # 모바일 보류함 드레이너 — 작업 중이라 미뤄둔 메시지를 세션이 유휴가 되는 순간 전달한다.
    # (진행 중인 턴을 끊지 않기 위한 장치이므로 폴링 주기는 짧게. 할 일이 없으면 즉시 반환한다.)
    import threading as _threading
    import time as _time

    def _outbox_loop() -> None:
        from marina_mobile import mobile_outbox_drain, mobile_settings_drain
        while True:
            try:
                mobile_outbox_drain()
                mobile_settings_drain()   # 미뤄둔 모델·강도 예약도 유휴 순간 회수(같은 장치)
            except Exception:
                pass
            _time.sleep(max(2, int(_env("OUTBOX_POLL", "3") or "3")))

    _threading.Thread(target=_outbox_loop, daemon=True, name="mobile-outbox").start()

    def _warm_loop() -> None:
        # 부팅 직후 worktree 배지 캐시를 채운다 — 첫 화면이 git 서브프로세스를 기다리지 않게.
        # (이후 만료는 worktree_info 의 stale-while-revalidate 가 알아서 처리한다.)
        try:
            from marina_registry import discover_all_roots
            from marina_sessions import warm_worktree_info

            warm_worktree_info(list(discover_all_roots()))
        except Exception:
            pass

    _threading.Thread(target=_warm_loop, daemon=True, name="worktree-warm").start()

    # 변화 감지 — 화면에 밀어주고(SSE), 사람을 불러야 하면 폰을 깨운다(푸시).
    # 이 루프가 없으면 폰은 계속 3초마다 물어봐야 하고, "방금 바뀌었다"를 아는 곳이 없어
    # 알림을 보낼 근거 자체가 생기지 않는다.
    _tick = {"n": 0, "services": {}}

    def _events_snapshot() -> dict:
        from marina_events import SERVICE_EVERY_N_TICKS, build_snapshot
        from marina_mobile import mobile_watch_state

        def services():
            memory = memory_snapshot()
            return [session_payload(root, memory=memory) for root in discover_roots()]

        # 세션은 매 틱, 서비스는 N 틱마다. 서비스 조회는 compose·git 을 타서 비싸다.
        _tick["n"] += 1
        due = _tick["n"] % SERVICE_EVERY_N_TICKS == 1
        snapshot = build_snapshot(mobile_watch_state, services if due else None, _tick["services"])
        _tick["services"] = snapshot["services"]
        return snapshot

    def _on_events(events: list) -> None:
        from marina_events import _WATCHER
        from marina_notify import is_engaged, record_alerts, should_notify
        from marina_push import broadcast, subscriptions

        marks = (getattr(_WATCHER, "_previous", None) or {}).get("sessions") or {}
        now = _time.time()
        alerts = [e for e in events
                  if should_notify(e, engaged=is_engaged(e, marks, now),
                                   hidden=False, now=now)]
        if not alerts:
            return
        record_alerts(alerts, now)
        if subscriptions():
            broadcast()      # 내용 없는 푸시 — 깨어난 서비스워커가 위 기록을 가져간다

    def _events_loop() -> None:
        try:
            from marina_events import IDLE_INTERVAL_S, WATCH_INTERVAL_S, event_bus, start_watching
            from marina_push import subscriptions

            def _pace() -> float:
                # 듣는 사람(SSE 연결·등록된 폰)이 있을 때만 촘촘히 본다. 없으면 캐시만 데운다.
                listening = event_bus().subscriber_count() > 0 or bool(subscriptions())
                return WATCH_INTERVAL_S if listening else IDLE_INTERVAL_S

            start_watching(_events_snapshot, _on_events, interval_fn=_pace)
        except Exception:
            pass             # 감지층이 못 떠도 폴링 화면은 그대로 돈다

    _threading.Thread(target=_events_loop, daemon=True, name="marina-events-boot").start()
    server.serve_forever()
