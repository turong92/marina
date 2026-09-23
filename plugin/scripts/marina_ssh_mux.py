"""원격 폴링이 쓰는 ssh 접속을 하나로 모은다(OpenSSH 멀티플렉싱).

**왜.** `DOCKER_HOST=ssh://…` 면 docker 호출 한 번이 **새 ssh 접속 하나**다 — TCP 핸드셰이크·키 교환·인증을
매번 다시 하고, 박스에는 sshd 가 하나 더 뜬다. 상태를 묻기만 하는 폴링이 그걸 계속 하는 건 낭비이고,
2026-09-17 사무실 박스(192.168.0.251)에 dial-stdio 고아가 쌓인 사고의 뿌리다. 그때 고친 건 **빈도**였고
(TTL 캐시·합치기·백오프), '호출마다 새 접속' 이라는 구조 자체는 그대로 남아 있었다.

**어떻게.** docker CLI 는 ssh 를 **PATH 에서 찾아** 실행한다(실측: `ssh -o ConnectTimeout=30 -T -- <host>
docker system dial-stdio`). 연결 헬퍼에 옵션을 넘길 수단은 없고, 형의 `~/.ssh/config` 를 고치면 marina 밖
ssh 까지 영향을 받는다. 그래서 가장 좁은 수단인 **ssh 껍데기 한 장**을 PATH 앞에 둔다 — 껍데기는 진짜 ssh 를
ControlMaster 옵션과 함께 exec 한다. ssh 는 같은 키워드가 여러 번 오면 **처음 값**을 쓰므로, 껍데기가 앞에
붙인 옵션이 docker 가 뒤에 붙이는 인자에 지지 않는다.

**폴링에만 쓴다.** sshd 의 MaxSessions(기본 10)를 넘는 동시 채널은 거부되는데, `compose up`·`build` 는 한
번에 여러 연결을 연다. 폴링은 박스당 한 번에 하나로 합쳐져 있어(_remote_compose_ps) 그 한계에 닿지 않는다.
수명 조작은 지금처럼 각자 접속한다 — 드물어서 누수가 아니다.

끄기: `MARINA_SSH_MUX=0`.
"""

from __future__ import annotations

import os
import shutil
import stat
import tempfile
import threading
from pathlib import Path

from marina_state import MARINA_HOME

# 유닉스 소켓 경로 한계(macOS sun_path 104B). `c-%C` 의 %C 는 40 hex 라 홈이 깊으면 넘을 수 있고, 넘으면 ssh 가
# "ControlPath too long" 으로 **접속 자체를 실패**한다(실측). 그런 환경에선 멀티플렉싱을 켜지 않는다.
_MAX_CONTROL_PATH = 100
_C_EXPANDED = 40          # ssh 가 %C 를 펴는 길이(SHA1 40 hex) — 리터럴 2글자로 재면 위험 구간을 통과시킨다

def _persist_seconds() -> str:
    """ControlPersist 값. 껍데기 **셸 스크립트 본문에 굽는** 값이라 숫자만 허용한다 —
    따옴표로 감싸는 대신 아예 메타문자가 들어올 수 없게 한다."""
    v = (os.environ.get("MARINA_SSH_MUX_PERSIST") or "").strip()
    return v if v.isdigit() else "300"


_CONTROL_PERSIST = _persist_seconds()

_lock = threading.Lock()
_shim_dir_cache = None          # None=아직 안 만듦, ""=불가(포기)


def enabled() -> bool:
    return (os.environ.get("MARINA_SSH_MUX", "1") or "1").strip().lower() not in ("0", "false", "no", "off")


def _control_path() -> str:
    """접속을 공유할 소켓 경로. 너무 길면 빈 문자열(= 멀티플렉싱 포기)."""
    p = str(MARINA_HOME / "ssh" / "c-%C")
    # **편 길이**로 잰다. `%C` 를 리터럴 2글자로 세면 실제로는 104B 를 넘는 경로를 통과시켜,
    # 이 가드가 막으려던 "ControlPath too long → 접속 자체 실패"가 그대로 일어난다(리뷰 지적).
    return p if len(p) - len("%C") + _C_EXPANDED <= _MAX_CONTROL_PATH else ""


def ssh_options() -> list:
    """직접 ssh 를 실행하는 호출부(박스 메모리 읽기 등)가 앞에 붙일 옵션. 못 쓰면 빈 목록.

    ServerAlive 는 마스터가 **멈춘 박스에 매달려 있지 않게** 한다 — 45초면 끊고, 다음 호출이 새로 연다."""
    cp = _control_path()
    if not enabled() or not cp:
        return []
    return ["-o", "ControlMaster=auto", "-o", "ControlPath=" + cp, "-o", "ControlPersist=" + _CONTROL_PERSIST,
            "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=3"]


def _real_ssh(shim_dir: Path) -> str:
    """껍데기가 exec 할 진짜 ssh. **껍데기 자신은 제외**한다 — 아니면 무한 exec."""
    parts = [d for d in (os.environ.get("PATH") or "").split(os.pathsep)
             if d and os.path.realpath(d) != os.path.realpath(str(shim_dir))]
    found = shutil.which("ssh", path=os.pathsep.join(parts)) if parts else None
    if not found:
        found = "/usr/bin/ssh" if os.path.exists("/usr/bin/ssh") else ""
    return found


def _shim_dir() -> str:
    """`ssh` 껍데기가 든 디렉터리. 만들 수 없으면 빈 문자열."""
    global _shim_dir_cache
    if _shim_dir_cache is not None:
        return _shim_dir_cache
    with _lock:
        if _shim_dir_cache is not None:
            return _shim_dir_cache
        _shim_dir_cache = ""
        cp = _control_path()
        if not cp:
            return _shim_dir_cache
        d = MARINA_HOME / "ssh" / "bin"
        try:
            d.mkdir(parents=True, exist_ok=True)
            os.chmod(str(MARINA_HOME / "ssh"), 0o700)   # 소켓 디렉터리는 나만
            real = _real_ssh(d)
            if not real:
                return _shim_dir_cache
            body = (
                "#!/bin/sh\n"
                "# marina 가 만든 ssh 껍데기 — 원격 폴링이 접속 하나를 나눠 쓰게 한다(marina_ssh_mux.py).\n"
                "# 지우면 다음 폴링에서 다시 만들어진다. ssh 는 같은 옵션의 **처음 값**을 쓰므로 여기 값이 이긴다.\n"
                'exec "%s" -o ControlMaster=auto -o "ControlPath=%s" -o ControlPersist=%s '
                '-o ServerAliveInterval=15 -o ServerAliveCountMax=3 "$@"\n' % (real, cp, _CONTROL_PERSIST)
            )
            shim = d / "ssh"
            if not (shim.exists() and shim.read_text(encoding="utf-8") == body):
                fd, tmp = tempfile.mkstemp(dir=str(d), prefix=".ssh.")
                try:
                    with os.fdopen(fd, "w", encoding="utf-8") as f:
                        f.write(body)
                    os.chmod(tmp, stat.S_IRWXU)
                    os.replace(tmp, str(shim))      # 원자 교체 — 반쪽 파일을 exec 하면 원격이 통째로 멈춘다
                except BaseException:
                    Path(tmp).unlink(missing_ok=True)
                    raise
            _shim_dir_cache = str(d)
        except OSError:
            _shim_dir_cache = ""                    # 못 만들면 조용히 지금 동작(접속마다 새 ssh)
        return _shim_dir_cache


def mux_env(env: dict) -> dict:
    """docker 호출용 env 에 껍데기 PATH 를 얹는다. 못 쓰면 받은 env 그대로."""
    if not enabled():
        return env
    d = _shim_dir()
    if not d:
        return env
    out = dict(env)
    path = out.get("PATH") or os.environ.get("PATH") or "/usr/bin:/bin"
    if path.split(os.pathsep)[0] != d:
        out["PATH"] = d + os.pathsep + path
    return out


def _reset_for_tests() -> None:
    global _shim_dir_cache
    _shim_dir_cache = None
