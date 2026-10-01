# marina session 테스트 공통 준비 — lib/harness.sh 를 source 한 **다음에** source 한다.
# 만드는 것: 테스트 전용 tmux 소켓 · 가짜 claude · 임시 git 프로젝트(proj) · discord.json · 토큰 파일.
# 가짜 Discord 는 start_fake_discord 로 필요한 테스트만 띄운다.
command -v tmux >/dev/null 2>&1 || { echo "SKIP(tmux 없음)"; exit 0; }
FIX_HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SCRIPTS="$(cd -- "$FIX_HERE/../../scripts" && pwd -P)"
MARINA_SH="$SCRIPTS/marina.sh"
TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/marina-session.XXXXXX")"; TMPROOT="$(cd "$TMPROOT" && pwd -P)"
export MARINA_TMUX_SOCKET="marina-test-$$"          # 형의 tmux 와 절대 섞이지 않게
export MARINA_CHANNELS_DIR="$MARINA_HOME/channels"  # 형의 ~/.claude/channels 대신
export MARINA_SESSION_BOOT_WAIT=0.5
export MARINA_CLAUDE_JSON="$TMPROOT/claude.json"       # 형의 ~/.claude.json(폴더 신뢰) 대신
export MARINA_CLAUDE_PROJECTS="$TMPROOT/claude-projects"  # 형의 ~/.claude/projects(대화 기록) 대신
FD="$TMPROOT/fakediscord"; mkdir -p "$FD"
FAKE_OUT="$TMPROOT/claude-calls"; mkdir -p "$FAKE_OUT"
FD_PID=""
fixture_cleanup() {
  tmux -L "$MARINA_TMUX_SOCKET" kill-server 2>/dev/null || true
  [ -n "$FD_PID" ] && kill "$FD_PID" 2>/dev/null || true
  rm -rf "$TMPROOT"
}
trap fixture_cleanup EXIT

# 가짜 claude — env -i 로 떠서 환경변수를 못 받으므로 경로를 스크립트에 박는다.
mkdir -p "$TMPROOT/bin"
cat > "$TMPROOT/bin/claude" <<SH
#!/bin/sh
d="$FAKE_OUT/\$\$"; mkdir -p "\$d"
printf '%s\0' "\$@" > "\$d/argv"
env > "\$d/env"
pwd -P > "\$d/cwd"
[ -e "$TMPROOT/claude-fail" ] && exit 1
exec sleep 300
SH
chmod +x "$TMPROOT/bin/claude"
export PATH="$TMPROOT/bin:$PATH"

gi() { mkdir -p "$1"; git -C "$1" init -q -b main; git -C "$1" config user.email t@t.invalid; git -C "$1" config user.name T; echo ok > "$1/r"; git -C "$1" add r; git -C "$1" commit -qm init; }
SRC="$TMPROOT/proj"; gi "$SRC"
printf '{"projects":[{"id":"proj","root":"%s","subrepos":[],"worktreeGlobs":[".claude/worktrees/*"]}],"schemaVersion":1}\n' "$SRC" > "$MARINA_HOME/projects.json"
printf 'DISCORD_BOT_TOKEN=test-token\n' > "$MARINA_HOME/token.env"
cat > "$MARINA_HOME/discord.json" <<JSON
{"guildId":"G1","tokenFile":"$MARINA_HOME/token.env","projects":{"proj":{"categoryId":null,"allow":["U1"]}}}
JSON

start_fake_discord() {
  python3 "$FIX_HERE/fake_discord.py" "$FD" & FD_PID=$!
  for _ in $(seq 50); do [ -s "$FD/port" ] && break; sleep 0.1; done
  [ -s "$FD/port" ] || { echo "FAIL: 가짜 Discord 기동 실패"; exit 1; }
  export MARINA_DISCORD_API="http://127.0.0.1:$(cat "$FD/port")"
}
msess() { ( cd "$TMPROOT" && bash "$MARINA_SH" session "$@" ); }
