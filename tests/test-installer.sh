#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

MOCK_BIN="$TEST_ROOT/mock-bin"
RELEASES="$TEST_ROOT/releases"
REAL_LN="$(command -v ln)"
mkdir -p "$MOCK_BIN" "$TEST_ROOT/glibc/bin" "$TEST_ROOT/glibc/lib"

cat > "$MOCK_BIN/pkg" <<'EOF'
#!/usr/bin/env bash
printf 'pkg:%s\n' "$*" >> "$LOG"
EOF

cat > "$MOCK_BIN/ln" <<EOF
#!/usr/bin/env bash
if [[ -n "\${MOCK_LN_FAIL_TARGET:-}" ]] && \
   [[ "\${*: -1}" == "\$MOCK_LN_FAIL_TARGET" ]]; then
  exit 1
fi
exec "$REAL_LN" "\$@"
EOF

cat > "$TEST_ROOT/glibc/bin/patchelf" <<'EOF'
#!/usr/bin/env bash
printf 'patchelf:%s\n' "$*" >> "$LOG"
EOF
: > "$TEST_ROOT/glibc/lib/ld-linux-aarch64.so.1"

chmod +x "$MOCK_BIN/pkg" "$MOCK_BIN/ln" "$TEST_ROOT/glibc/bin/patchelf"
export PATH="$MOCK_BIN:$PATH"

# A local release mirror stands in for downloads.claude.ai.
publish() {
  local body="$2" dir="$RELEASES/$1" checksum
  mkdir -p "$dir/linux-arm64"
  printf '%s\n' '#!/usr/bin/env bash' "$body" > "$dir/linux-arm64/claude"
  checksum="$(sha256sum "$dir/linux-arm64/claude" | cut -d' ' -f1)"
  printf '{"platforms":{"linux-arm64":{"checksum":"%s","size":1}}}\n' \
    "$checksum" > "$dir/manifest.json"
}
publish 9.9.9 'exit 0'
publish 8.8.8 'exit 0'
publish 6.6.6 'kill -SEGV $$'
printf '%s\n' 8.8.8 > "$RELEASES/stable"

export CLAUDE_MOBILE_RELEASES_URL="file://$RELEASES"
export CLAUDE_MOBILE_GLIBC_LD="$TEST_ROOT/glibc/lib/ld-linux-aarch64.so.1"
export CLAUDE_MOBILE_PATCHELF="$TEST_ROOT/glibc/bin/patchelf"
export CLAUDE_MOBILE_SMOKE_TIMEOUT=10

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

new_case() {
  local name="$1"
  CASE_ROOT="$TEST_ROOT/$name"
  TEST_HOME="$CASE_ROOT/home"
  TEST_PREFIX="$CASE_ROOT/prefix"
  LOG="$CASE_ROOT/install.log"
  mkdir -p "$TEST_HOME" "$TEST_PREFIX/bin"
  : > "$LOG"
  export LOG
  unset MOCK_LN_FAIL_TARGET
}

run_installer() {
  HOME="$TEST_HOME" PREFIX="$TEST_PREFIX" CLAUDE_MOBILE_TESTING=1 \
    CLAUDE_MOBILE_ARCH=aarch64 CLAUDE_MOBILE_VERSION="${1:-stable}" \
    node "$PROJECT_DIR/npm-bin/install.js"
}

run_uninstaller() {
  HOME="$TEST_HOME" PREFIX="$TEST_PREFIX" CLAUDE_MOBILE_TESTING=1 \
    node "$PROJECT_DIR/npm-bin/install.js" uninstall "$@"
}

node "$PROJECT_DIR/npm-bin/install.js" --help | \
  grep -F 'uninstall [--purge]' >/dev/null || fail 'npm command help is missing'

new_case invalid-command
if HOME="$TEST_HOME" PREFIX="$TEST_PREFIX" CLAUDE_MOBILE_TESTING=1 \
  node "$PROJECT_DIR/npm-bin/install.js" uninstal >/dev/null 2>&1; then
  fail 'unknown npm command should fail'
fi

# A fresh installation creates the managed command without a backup.
new_case fresh-install
run_installer 9.9.9 >/dev/null 2>&1
for launcher in claude-mobile claude-mobile-resume claude-mobile-runtime; do
  [[ -x "$TEST_PREFIX/bin/$launcher" ]] || fail "$launcher not installed"
done
[[ -L "$TEST_PREFIX/bin/claude" ]] || fail 'claude command symlink not installed'
[[ "$(readlink "$TEST_PREFIX/bin/claude")" == "claude-mobile" ]] || \
  fail 'claude command points to the wrong launcher'
[[ ! -e "$TEST_PREFIX/bin/claude.claude-mobile-backup" ]] || \
  fail 'fresh install unexpectedly created a backup'
[[ -x "$TEST_HOME/.shortcuts/Claude Mobile" ]] || fail 'Widget launcher not installed'
[[ -x "$TEST_HOME/.shortcuts/Claude Mobile Resume" ]] || fail 'Widget resume launcher not installed'
[[ "$(readlink "$TEST_HOME/.local/claude-termux/current")" == versions/9.9.9 ]] || \
  fail 'requested Claude Code version not installed'
grep -F 'pkg:install -y glibc-runner patchelf-glibc' "$LOG" >/dev/null || \
  fail 'glibc-runner was not installed'
grep -F 'patchelf:--set-interpreter' "$LOG" >/dev/null || fail 'binary was not patched'

# Reinstalling must remain successful; the default is the stable channel.
run_installer >/dev/null 2>&1
[[ ! -e "$TEST_PREFIX/bin/claude.claude-mobile-backup" ]] || \
  fail 'repeat install unexpectedly created a backup'
[[ "$(readlink "$TEST_HOME/.local/claude-termux/current")" == versions/8.8.8 ]] || \
  fail 'stable channel not installed by default'

# An existing command is backed up and restored by uninstall.
new_case existing-command
printf '%s\n' '#!/usr/bin/env bash' 'printf old-claude' > "$TEST_PREFIX/bin/claude"
chmod +x "$TEST_PREFIX/bin/claude"
run_installer >/dev/null 2>&1
[[ -x "$TEST_PREFIX/bin/claude.claude-mobile-backup" ]] || \
  fail 'existing claude command not backed up'

run_uninstaller >/dev/null
for launcher in claude-mobile claude-mobile-resume claude-mobile-runtime; do
  [[ ! -e "$TEST_PREFIX/bin/$launcher" ]] || fail "$launcher not removed"
done
[[ ! -e "$TEST_HOME/.shortcuts/Claude Mobile" ]] || fail 'Widget launcher not removed'
[[ -x "$TEST_PREFIX/bin/claude" ]] || fail 'previous claude command not restored'
[[ ! -e "$TEST_PREFIX/bin/claude.claude-mobile-backup" ]] || \
  fail 'claude backup not consumed'
grep -F 'old-claude' "$TEST_PREFIX/bin/claude" >/dev/null || \
  fail 'restored claude command is incorrect'
[[ -d "$TEST_HOME/.local/claude-termux" ]] || fail 'runtime removed without --purge'

run_uninstaller --purge >/dev/null
[[ ! -e "$TEST_HOME/.local/claude-termux" ]] || fail 'runtime not purged'

# A command/backup collision fails before downloads or filesystem changes.
new_case collision
printf '%s\n' 'original-command' > "$TEST_PREFIX/bin/claude"
printf '%s\n' 'original-backup' > "$TEST_PREFIX/bin/claude.claude-mobile-backup"
if run_installer >/dev/null 2>&1; then
  fail 'command/backup collision should fail'
fi
[[ ! -s "$LOG" ]] || fail 'collision invoked a package manager'
[[ ! -e "$TEST_PREFIX/bin/claude-mobile" ]] || fail 'collision installed a launcher'
[[ ! -e "$TEST_HOME/.local" ]] || fail 'collision created the runtime directory'
[[ ! -e "$TEST_HOME/.shortcuts" ]] || fail 'collision created shortcuts'
grep -Fx 'original-command' "$TEST_PREFIX/bin/claude" >/dev/null || \
  fail 'collision changed the existing command'
grep -Fx 'original-backup' "$TEST_PREFIX/bin/claude.claude-mobile-backup" >/dev/null || \
  fail 'collision changed the existing backup'

# A release that crashes on this device leaves the existing command untouched.
new_case crashing-release
printf '%s\n' 'working-command' > "$TEST_PREFIX/bin/claude"
if run_installer 6.6.6 >"$CASE_ROOT/out" 2>&1; then
  fail 'crashing release should fail the installer'
fi
grep -F 'CLAUDE_MOBILE_VERSION=' "$CASE_ROOT/out" >/dev/null || \
  fail 'crashing release did not suggest pinning an older version'
grep -Fx 'working-command' "$TEST_PREFIX/bin/claude" >/dev/null || \
  fail 'crashing release changed the existing command'
[[ ! -e "$TEST_PREFIX/bin/claude.claude-mobile-backup" ]] || \
  fail 'crashing release created a backup'

# A failed replacement restores the command that was moved to the backup path.
new_case rollback
printf '%s\n' '#!/usr/bin/env bash' 'printf rollback-claude' > "$TEST_PREFIX/bin/claude"
chmod +x "$TEST_PREFIX/bin/claude"
MOCK_LN_FAIL_TARGET="$TEST_PREFIX/bin/claude"
export MOCK_LN_FAIL_TARGET
if run_installer >/dev/null 2>&1; then
  fail 'failed symlink creation should fail the installer'
fi
unset MOCK_LN_FAIL_TARGET
[[ -x "$TEST_PREFIX/bin/claude" ]] || fail 'rollback did not restore the command'
[[ ! -L "$TEST_PREFIX/bin/claude" ]] || fail 'rollback left a managed symlink'
[[ ! -e "$TEST_PREFIX/bin/claude.claude-mobile-backup" ]] || \
  fail 'rollback left the backup path occupied'
grep -F 'rollback-claude' "$TEST_PREFIX/bin/claude" >/dev/null || \
  fail 'rollback restored the wrong command'

new_case validation
if HOME="$TEST_HOME" PREFIX="$TEST_PREFIX" CLAUDE_MOBILE_TESTING=1 \
  CLAUDE_MOBILE_ARCH=x86_64 bash "$PROJECT_DIR/install.sh" >/dev/null 2>&1; then
  fail 'unsupported architecture should fail'
fi

if HOME="$TEST_HOME" PREFIX="$TEST_PREFIX" CLAUDE_MOBILE_TESTING=1 \
  node "$PROJECT_DIR/npm-bin/install.js" uninstall --pruge >/dev/null 2>&1; then
  fail 'unknown uninstall option should fail'
fi

printf '%s\n' 'Installer tests passed.'
