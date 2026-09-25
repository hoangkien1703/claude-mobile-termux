#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
LAUNCHER="$PROJECT_DIR/bin/claude-mobile"
LAUNCHER_REAL="$(readlink -f -- "$LAUNCHER")"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

MOCK_BIN="$TEST_ROOT/bin"
LOG="$TEST_ROOT/calls.log"
NATIVE="$TEST_ROOT/claude-native"
RUNTIME="$TEST_ROOT/runtime"
TEST_HOME="$TEST_ROOT/home"
mkdir -p "$MOCK_BIN" "$TEST_HOME"

# The fake Claude binary records its arguments and the environment it received.
cat > "$NATIVE" <<'EOF'
#!/usr/bin/env bash
printf 'native:%s\n' "$*" >> "$LOG"
printf 'env:LD_PRELOAD=%s\n' "${LD_PRELOAD-<unset>}" >> "$LOG"
printf 'env:DISABLE_AUTOUPDATER=%s\n' "${DISABLE_AUTOUPDATER-<unset>}" >> "$LOG"
printf 'env:BUN_OPTIONS=%s\n' "${BUN_OPTIONS-<unset>}" >> "$LOG"
printf 'env:BROWSER=%s\n' "${BROWSER-<unset>}" >> "$LOG"
EOF

cat > "$RUNTIME" <<'EOF'
#!/usr/bin/env bash
printf 'runtime:%s\n' "$*" >> "$LOG"
EOF

cat > "$MOCK_BIN/tmux" <<'EOF'
#!/usr/bin/env bash
printf 'tmux:%s\n' "$*" >> "$LOG"
if [[ "$1" == "has-session" ]]; then
  exit "${MOCK_HAS_SESSION:-1}"
fi
EOF

cat > "$MOCK_BIN/termux-wake-lock" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' 'wake-lock' >> "$LOG"
EOF

cat > "$MOCK_BIN/termux-open-url" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

chmod +x "$NATIVE" "$RUNTIME" "$MOCK_BIN"/*
export PATH="$MOCK_BIN:$PATH" LOG HOME="$TEST_HOME"
unset BROWSER BUN_OPTIONS CLAUDE_MOBILE_DNS CLAUDE_MOBILE_SKIP_UPDATE TMUX

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

show_log() {
  printf '%s\n' 'Recorded calls:' >&2
  sed 's/^/  /' "$LOG" >&2
}

assert_log() {
  if ! grep -F -x -- "$1" "$LOG" >/dev/null; then
    show_log
    fail "missing log line: $1"
  fi
}

assert_log_contains() {
  if ! grep -F -- "$1" "$LOG" >/dev/null; then
    show_log
    fail "missing log text: $1"
  fi
}

refute_log_contains() {
  if grep -F -- "$1" "$LOG" >/dev/null; then
    show_log
    fail "unexpected log text: $1"
  fi
}

run_launcher() {
  CLAUDE_MOBILE_RUNTIME="$RUNTIME" bash "$LAUNCHER" "$@"
}

# Inside tmux, the launcher prepares the environment and runs Claude directly.
: > "$LOG"
TMUX=inside LD_PRELOAD=/fake/libtermux-exec.so CLAUDE_MOBILE_NATIVE="$NATIVE" \
  run_launcher "Review this repo" 2>/dev/null
assert_log 'wake-lock'
assert_log 'native:Review this repo'
assert_log 'env:LD_PRELOAD=<unset>'
assert_log 'env:DISABLE_AUTOUPDATER=1'
assert_log 'env:BROWSER=termux-open-url'
assert_log_contains 'env:BUN_OPTIONS=--preload '
grep -F '"8.8.8.8","8.8.4.4"' "$TEST_HOME/.local/claude-termux/setdns.js" >/dev/null || \
  fail 'DNS preload does not contain the default resolvers'
# An overridden binary skips the managed auto-update.
refute_log_contains 'runtime:'

# Custom resolvers are written to the preload; "off" disables it.
: > "$LOG"
TMUX=inside CLAUDE_MOBILE_NATIVE="$NATIVE" CLAUDE_MOBILE_DNS=1.1.1.1 run_launcher
grep -F '["1.1.1.1"]' "$TEST_HOME/.local/claude-termux/setdns.js" >/dev/null || \
  fail 'custom DNS server was not written'
: > "$LOG"
TMUX=inside CLAUDE_MOBILE_NATIVE="$NATIVE" CLAUDE_MOBILE_DNS=off run_launcher
assert_log 'env:BUN_OPTIONS=<unset>'

# Outside tmux, a new session re-runs the launcher with the original arguments.
: > "$LOG"
CLAUDE_MOBILE_NATIVE="$NATIVE" MOCK_HAS_SESSION=1 run_launcher --model test-model
assert_log "tmux:has-session -t =claude"
assert_log_contains "-e CLAUDE_MOBILE_NATIVE=$NATIVE"
assert_log_contains "-e CLAUDE_MOBILE_RUNTIME=$RUNTIME"
assert_log_contains "-s claude -- $LAUNCHER_REAL --model test-model"
refute_log_contains 'native:'
refute_log_contains 'wake-lock'

# An existing session is reattached.
: > "$LOG"
CLAUDE_MOBILE_NATIVE="$NATIVE" MOCK_HAS_SESSION=0 run_launcher
assert_log 'tmux:attach-session -t =claude'

# A custom session name is honoured.
: > "$LOG"
CLAUDE_MOBILE_NATIVE="$NATIVE" CLAUDE_MOBILE_SESSION=work MOCK_HAS_SESSION=1 run_launcher
assert_log_contains '-s work -- '

# Resume continues the latest conversation.
: > "$LOG"
TMUX=inside CLAUDE_MOBILE_NATIVE="$NATIVE" CLAUDE_MOBILE_RUNTIME="$RUNTIME" \
  bash "$PROJECT_DIR/bin/claude-mobile-resume" --model test-model
assert_log 'native:--continue --model test-model'

: > "$LOG"
CLAUDE_MOBILE_NATIVE="$NATIVE" CLAUDE_MOBILE_RUNTIME="$RUNTIME" MOCK_HAS_SESSION=1 \
  bash "$PROJECT_DIR/bin/claude-mobile-resume"
assert_log_contains "-- $LAUNCHER_REAL --claude-mobile-continue"

# Claude's own --resume flag is passed through untouched.
: > "$LOG"
TMUX=inside CLAUDE_MOBILE_NATIVE="$NATIVE" run_launcher --resume
assert_log 'native:--resume'

# One-shot commands bypass tmux and the wake lock.
for command in '--version' '-p hello' 'mcp list' 'doctor'; do
  : > "$LOG"
  # shellcheck disable=SC2086  # Split the command into arguments on purpose.
  CLAUDE_MOBILE_NATIVE="$NATIVE" run_launcher $command
  assert_log "native:$command"
  refute_log_contains 'tmux:'
  refute_log_contains 'wake-lock'
done

# CLAUDE_MOBILE_NO_TMUX runs an interactive session in the current terminal.
: > "$LOG"
CLAUDE_MOBILE_NATIVE="$NATIVE" CLAUDE_MOBILE_NO_TMUX=1 run_launcher
assert_log 'native:'
refute_log_contains 'tmux:'

# update, upgrade, and install are handled by the runtime manager.
: > "$LOG"
run_launcher update
assert_log 'runtime:update --force'
: > "$LOG"
run_launcher upgrade
assert_log 'runtime:update --force'
: > "$LOG"
run_launcher install 2.1.112
assert_log 'runtime:install 2.1.112'
refute_log_contains 'native:'

# The managed binary is updated (when due) before an interactive launch.
MANAGED_ROOT="$TEST_HOME/.local/claude-termux"
mkdir -p "$MANAGED_ROOT/versions"
cp "$NATIVE" "$MANAGED_ROOT/versions/1.0.0"
ln -sfn versions/1.0.0 "$MANAGED_ROOT/current"

: > "$LOG"
TMUX=inside run_launcher
assert_log 'runtime:update --if-due'
assert_log 'native:'

: > "$LOG"
TMUX=inside CLAUDE_MOBILE_SKIP_UPDATE=1 run_launcher
refute_log_contains 'runtime:'
assert_log 'native:'

# One-shot commands never wait for an update check.
: > "$LOG"
run_launcher --version
refute_log_contains 'runtime:'
assert_log 'native:--version'

# A failing update check still launches the installed version.
cat > "$RUNTIME" <<'EOF'
#!/usr/bin/env bash
printf 'runtime:%s\n' "$*" >> "$LOG"
exit 1
EOF
: > "$LOG"
TMUX=inside run_launcher 2>/dev/null
assert_log 'native:'

# A missing binary fails with a clear message.
if TMUX=inside CLAUDE_MOBILE_NATIVE="$TEST_ROOT/missing" run_launcher 2>/dev/null; then
  fail 'missing Claude binary should fail'
fi

printf '%s\n' 'Launcher tests passed.'
