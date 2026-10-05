"""`marina live` 서브커맨드의 인자 파싱과 부작용. 순수 로직은 marina_live.py 에 있다.

여기 있는 것: 레지스트리 읽기, docker compose 호출, 유닛 설치 호출, 출력 문구.
여기 없는 것: 경로 계산·레지스트리 해석·유닛 내용 — 그건 marina_live.py 가 정한다.
"""
from __future__ import annotations

import importlib.util
import os
import pathlib
import subprocess
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import marina_live as L     # noqa: E402

_HERE = pathlib.Path(__file__).resolve().parent
_MC = None


def mc():
    """marina-compose.py 재사용 — 파일명에 하이픈이 있어 import 문을 못 쓴다.
    같은 모듈을 쓰는 이유: live 와 개발이 서로 다른 compose 해석을 갖지 않게 한다."""
    global _MC
    if _MC is None:
        spec = importlib.util.spec_from_file_location("marina_compose", str(_HERE / "marina-compose.py"))
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        _MC = mod
    return _MC


USAGE = """사용법:
  marina live up <프로젝트>         # 운영 스택 기동 (재부팅 후 자동 기동 포함)
  marina live down <프로젝트>       # 정지 + 자동 기동 해제
  marina live status [<프로젝트>]   # 상태·주소·데이터 경로·자동 기동 여부
  marina live logs <프로젝트> [서비스]
  marina live restart <프로젝트> <서비스>
  marina live pin <프로젝트> <ref>  # 무엇을 운영할지 정한다 (배포 = 이걸 바꾸는 일)
"""

SUBS = ("up", "down", "status", "logs", "restart", "pin")


def _need_cfg(project_id: str, sub: str):
    cfg = L.live_config(L.load_registry(), project_id)
    if cfg is None:
        raise L.LiveConfigError(
            f"'{project_id}' 에 live 설정이 없다. `marina live pin {project_id} <ref>` 먼저."
        )
    return cfg


def cmd_pin(argv) -> int:
    if len(argv) < 2:
        print("사용법: marina live pin <프로젝트> <ref>", file=sys.stderr)
        return 2
    block = L.pin_ref(argv[0], argv[1])
    print(f"live ref 고정: {argv[0]} → {block['ref']}")
    if not block.get("services"):
        print("  주의: live.services 가 비어 있다 — `marina live up` 은 거부한다. "
              "운영에 띄울 서비스를 projects.json 의 live.services 에 적어라.", file=sys.stderr)
    else:
        print(f"  적용: marina live up {argv[0]}")
    return 0


# ── 부작용 ────────────────────────────────────────────────────────────────────
def _remote_target():
    """live 는 원격이 설정됐는데 안 닿으면 **실패한다** — 개발의 조용한 로컬 폴백을 여기서는
    끈다. 두 기계에 같은 서비스가 뜨는 것이 조용히 틀린 상태이기 때문이다(설계 결정 4-4)."""
    return os.environ.get("MARINA_LIVE_REMOTE") or None


def _docker(args, remote=None, **kw):
    argv = ["docker"] + (["-H", remote] if remote else []) + list(args)
    return subprocess.run(argv, **kw)


def _compose(argv, remote=None, **kw):
    """argv 는 mc.up_argv 등이 만든 ["docker", "compose", ...]. 원격이면 -H 를 끼운다."""
    argv = list(argv)
    if remote and argv[:1] == ["docker"]:
        argv = ["docker", "-H", remote] + argv[1:]
    return subprocess.run(argv, **kw)


def _check_remote(remote) -> None:
    if not remote:
        return
    probe = _docker(["info"], remote=remote, capture_output=True, text=True)
    if probe.returncode != 0:
        raise L.LiveConfigError(
            f"원격 도커에 닿지 않는다: {remote}. live 는 로컬로 떨어지지 않는다 — "
            f"원격을 고치거나 MARINA_LIVE_REMOTE 를 비워라.\n"
            f"  {(probe.stderr or probe.stdout or '').strip().splitlines()[0] if (probe.stderr or probe.stdout) else ''}"
        )


def _project_name(project_id: str) -> str:
    return mc().compose_project_name(project_id, L.LIVE_SESSION)


def _compose_file(project_id: str, cfg) -> pathlib.Path:
    return L.live_src(project_id) / (cfg.get("composeFile") or "docker-compose.yml")


def _load_config(compose_file: pathlib.Path) -> dict:
    if not compose_file.exists():
        raise L.LiveConfigError(
            f"compose 파일이 없다: {compose_file}. live.composeFile 이 그 ref 안의 경로인지 확인해라."
        )
    try:
        return mc().load_compose_file(str(compose_file))
    except Exception as exc:
        raise L.LiveConfigError(f"compose 를 읽지 못했다({compose_file}): {exc}")


def _write_overlay(project_id: str, config: dict) -> pathlib.Path:
    overlay = mc().build_overlay(
        config, live=True,
        extra_labels={L.LIVE_LABEL: "1", L.PROJECT_LABEL: project_id},
    )
    path = L.live_overlay_path(project_id)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(overlay, encoding="utf-8")
    return path


def _ps_rows(project_id: str, remote=None):
    """live 라벨로 찾은 컨테이너들 — (이름, 상태, 재시작횟수).

    compose 프로젝트명으로 찾지 않고 라벨로 찾는 이유: 라벨은 overlay 가 붙이는 marina 의
    표식이고, 프로젝트명은 compose 가 정하는 것이다. GC 면제도 같은 라벨을 본다."""
    out = _docker(["ps", "-a",
                   "--filter", f"label={L.LIVE_LABEL}=1",
                   "--filter", f"label={L.PROJECT_LABEL}={project_id}",
                   "--format", "{{.Names}}"], remote=remote, capture_output=True, text=True)
    names = [n for n in (out.stdout or "").split() if n]
    rows = []
    for n in names:
        ins = _docker(["inspect", n, "--format", "{{.State.Status}}\t{{.RestartCount}}"],
                      remote=remote, capture_output=True, text=True)
        parts = (ins.stdout or "").strip().split("\t")
        rows.append((n, parts[0] if parts else "?", parts[1] if len(parts) > 1 else "?"))
    return sorted(rows)


def _unit(action: str, project_id: str):
    return subprocess.run(["bash", str(_HERE / "marina-live-unit.sh"), action, project_id],
                          capture_output=True, text=True)


def cmd_up(project_id: str, cfg) -> int:
    remote = _remote_target()
    _check_remote(remote)                      # 체크아웃·기동 **전에** — 반쯤 한 상태를 안 남긴다
    services = list(cfg.get("services") or [])
    with L.src_lock(project_id):
        L.sync_src(cfg.get("root") or "", project_id, cfg["ref"])
        L.ensure_data_dir(project_id)
        compose_file = _compose_file(project_id, cfg)
        config = _load_config(compose_file)
        L.validate_services(config, services)
        for b in mc().project_dir_binds(config, str(L.live_src(project_id))):
            print(f"경고: 프로젝트 디렉토리 안을 가리키는 바인드 마운트 — {b}\n"
                  f"  소스 마운트면 운영에 적합하지 않다(다음 기동의 하드 리셋에 날아간다). "
                  f"live.composeFile 로 분리해라. 데이터 마운트면 그대로 둬도 된다 — "
                  f"{L.live_data(project_id)} 아래로 풀린다.", file=sys.stderr)
        overlay = _write_overlay(project_id, config)
        argv = mc().up_argv(str(compose_file), str(overlay), str(L.live_root(project_id)),
                            _project_name(project_id), services, build=True)
        rc = _compose(argv, remote=remote).returncode
        if rc != 0:
            print(f"기동 실패(docker compose up → {rc}). 위 출력을 봐라.", file=sys.stderr)
            return rc

    # 기동 직후 죽는 경우를 잡는다 — "떴다" 는 출력만 보고 운영을 믿으면 안 된다.
    rows = _ps_rows(project_id, remote)
    dead = [r for r in rows if r[1] not in ("running", "restarting")]
    for name, status, restarts in rows:
        print(f"  {name}: {status} (재시작 {restarts}회)")
    if dead:
        print("기동 직후 떠 있지 않은 컨테이너가 있다. 마지막 로그:", file=sys.stderr)
        for name, _s, _r in dead:
            logs = _docker(["logs", "--tail", "20", name], remote=remote,
                           capture_output=True, text=True)
            sys.stderr.write(f"--- {name}\n{(logs.stdout or '') + (logs.stderr or '')}\n")
        return 1

    # 유닛 설치 실패는 기동을 되돌리지 않는다 — 지금 돌고 있는 것이 더 중요하다.
    # 그 대신 status 가 "자동 기동: 안 됨" 을 계속 보여준다.
    u = _unit("install", project_id)
    sys.stdout.write(u.stdout or "")
    if u.returncode != 0:
        sys.stderr.write(u.stderr or "")
        print("경고: 자동 기동 등록에 실패했다. 지금 돌고 있는 것은 유지된다 — "
              "재부팅 후에는 `marina live up` 을 다시 해야 한다.", file=sys.stderr)
    _print_addresses(project_id, cfg, config)
    return 0


def _print_addresses(project_id: str, cfg, config: dict) -> None:
    print(f"데이터: {L.live_data(project_id)}")
    pub = []
    for name in sorted((config.get("services") or {})):
        if name not in (cfg.get("services") or []):
            continue
        for p in ((config["services"][name] or {}).get("ports") or []):
            if isinstance(p, dict) and p.get("published"):
                host = p.get("host_ip") or "127.0.0.1"
                pub.append(f"{name} → {host}:{p['published']}")
    if pub:
        print("선언 포트: " + ", ".join(pub))
    else:
        print("선언 포트 없음 — 컨테이너 DNS 로만 닿는다. 공개는 `marina live expose` (L2).")


def cmd_down(project_id: str, cfg) -> int:
    remote = _remote_target()
    _check_remote(remote)
    # 유닛을 먼저 뗀다 — 내린 직후 자동 기동이 다시 올리는 경쟁을 없앤다.
    u = _unit("uninstall", project_id)
    sys.stdout.write(u.stdout or "")
    compose_file = _compose_file(project_id, cfg)
    overlay = L.live_overlay_path(project_id)
    if not compose_file.exists():
        # 체크아웃이 없어도 프로젝트명만으로 내릴 수 있다 — 중요하다. src 를 손으로 지운 뒤에도
        # 컨테이너를 거둘 길이 있어야 한다.
        argv = ["docker", "compose", "-p", _project_name(project_id), "down", "--remove-orphans"]
    else:
        argv = mc()._compose_base(str(compose_file), str(overlay), str(L.live_root(project_id)),
                                  _project_name(project_id)) + ["down", "--remove-orphans"]
    rc = _compose(argv, remote=remote).returncode
    if rc == 0:
        print(f"내렸다: {_project_name(project_id)} (데이터는 {L.live_data(project_id)} 에 남는다)")
    return rc


def cmd_status(project_id: str, cfg) -> int:
    remote = _remote_target()
    print(f"프로젝트: {project_id}  ref={cfg.get('ref')}  서비스={', '.join(cfg.get('services') or []) or '(없음)'}")
    rows = _ps_rows(project_id, remote)
    if rows:
        # "healthy" 라는 단일 초록불을 만들지 않는다 — 컨테이너 상태와 재시작 횟수는 다른
        # 것을 말해 준다(재시작이 늘고 있으면 크래시 루프다).
        for name, status, restarts in rows:
            print(f"  {name}: {status} (재시작 {restarts}회)")
    else:
        print("  컨테이너 없음 — 안 떠 있다")
    data = L.live_data(project_id)
    print(f"데이터: {data}" + ("" if data.is_dir() else "  (없음 — 아직 기동하지 않았다)"))
    print(f"체크아웃: {L.live_src(project_id)}  "
          f"(marina 소유 — 다음 기동에 ref 로 하드 리셋된다. 손으로 고치지 마라)")
    u = _unit("status", project_id)
    sys.stdout.write(u.stdout or "")
    if remote:
        print(f"원격: {remote} (안 닿으면 live 는 실패한다 — 로컬로 떨어지지 않는다)")
    return 0


def cmd_logs(project_id: str, cfg, rest) -> int:
    remote = _remote_target()
    compose_file = _compose_file(project_id, cfg)
    base = ["docker", "compose", "-p", _project_name(project_id)] if not compose_file.exists() else \
        mc()._compose_base(str(compose_file), str(L.live_overlay_path(project_id)),
                           str(L.live_root(project_id)), _project_name(project_id))
    return _compose(base + ["logs", "-f", "--tail", "200"] + list(rest), remote=remote).returncode


def cmd_restart(project_id: str, cfg, rest) -> int:
    remote = _remote_target()
    _check_remote(remote)
    compose_file = _compose_file(project_id, cfg)
    if not compose_file.exists():
        raise L.LiveConfigError(
            f"체크아웃이 없다: {L.live_src(project_id)}. `marina live up {project_id}` 로 먼저 띄워라."
        )
    base = mc()._compose_base(str(compose_file), str(L.live_overlay_path(project_id)),
                              str(L.live_root(project_id)), _project_name(project_id))
    targets = list(rest) or list(cfg.get("services") or [])
    return _compose(base + ["restart"] + targets, remote=remote).returncode


def main(argv) -> int:
    if not argv or argv[0] not in SUBS:
        sys.stdout.write(USAGE)
        return 2
    sub, rest = argv[0], argv[1:]
    if sub == "status" and not rest:
        rest = [""]                       # status 는 프로젝트 생략 = 전체
    if not rest or not rest[0]:
        if sub != "status":
            print(f"프로젝트명이 필요하다.\n{USAGE}", file=sys.stderr)
            return 2
    try:
        if sub == "pin":
            return cmd_pin(rest)
        project_id = rest[0]
        cfg = _need_cfg(project_id, sub)
        if sub == "up":
            return cmd_up(project_id, cfg)
        if sub == "down":
            return cmd_down(project_id, cfg)
        if sub == "status":
            return cmd_status(project_id, cfg)
        if sub == "logs":
            return cmd_logs(project_id, cfg, rest[1:])
        if sub == "restart":
            return cmd_restart(project_id, cfg, rest[1:])
        print(f"아직 구현되지 않은 하위명령: {sub}", file=sys.stderr)
        return 2
    except L.LiveConfigError as exc:
        print(str(exc), file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
