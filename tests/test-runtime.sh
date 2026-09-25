#!/usr/bin/env bash
# Exercise the runtime manager against a local, file:// release mirror.
set -Eeuo pipefail

PROJECT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
RUNTIME="$PROJECT_DIR/bin/claude-mobile-runtime"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

RELEASES="$TEST_ROOT/releases"
LOG="$TEST_ROOT/calls.log"
export LOG
mkdir -p "$RELEASES" "$TEST_ROOT/glibc/bin" "$TEST_ROOT/glibc/lib"

GLIBC_LD="$TEST_ROOT/glibc/lib/ld-linux-aarch64.so.1"
: > "$GLIBC_LD"
cat > "$TEST_ROOT/glibc/bin/patchelf" <<'EOF'
#!/usr/bin/env bash
printf 'patchelf:%s\n' "$*" >> "$LOG"
EOF
chmod +x "$TEST_ROOT/glibc/bin/patchelf"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

# publish VERSION [crash|bad-checksum]
publish() {
  local version="$1" mode="${2:-}" dir="$RELEASES/$1" checksum
  mkdir -p "$dir/linux-arm64"
  if [[ "$mode" == crash ]]; then
    printf '%s\n' '#!/usr/bin/env bash' 'kill -SEGV $$' > "$dir/linux-arm64/claude"
  else
    printf '%s\n' '#!/usr/bin/env bash' "printf '%s\\n' '$version (Claude Code)'" \
      > "$dir/linux-arm64/claude"
  fi
  checksum="$(sha256sum "$dir/linux-arm64/claude" | cut -d' ' -f1)"
  [[ "$mode" == bad-checksum ]] && checksum="$(printf '%064d' 0)"
  printf '{"version":"%s","platforms":{"linux-arm64":{"checksum":"%s","size":1048576}}}\n' \
    "$version" "$checksum" > "$dir/manifest.json"
}

set_channel() { printf '%s\n' "$2" > "$RELEASES/$1"; }

HOME_DIR="$TEST_ROOT/home"
ROOT="$HOME_DIR/.local/claude-termux"
mkdir -p "$HOME_DIR"

runtime() {
  HOME="$HOME_DIR" CLAUDE_MOBILE_RELEASES_URL="file://$RELEASES" \
    CLAUDE_MOBILE_GLIBC_LD="$GLIBC_LD" CLAUDE_MOBILE_PATCHELF="$TEST_ROOT/glibc/bin/patchelf" \
    CLAUDE_MOBILE_SMOKE_TIMEOUT=10 bash "$RUNTIME" "$@"
}

active() { readlink "$ROOT/current" 2>/dev/null || true; }

publish 1.0.0
publish 1.1.0
publish 1.2.0 crash
publish 1.3.0 bad-checksum
publish 1.4.0
set_channel stable 1.0.0
set_channel latest 1.1.0

# Fresh install from the stable channel downloads, patches, and activates.
: > "$LOG"
runtime install 2>/dev/null
[[ "$(active)" == versions/1.0.0 ]] || fail 'stable release not activated'
[[ -x "$ROOT/current" ]] || fail 'active binary is not executable'
grep -F -- "patchelf:--set-interpreter $GLIBC_LD" "$LOG" >/dev/null || \
  fail 'binary was not patched with the glibc loader'
[[ "$(runtime path)" == "$ROOT/current" ]] || fail 'path command is wrong'
runtime status | grep -F 'Active version: 1.0.0' >/dev/null || fail 'status is wrong'
[[ -z "$(find "$ROOT/versions" -name '.download.*')" ]] || fail 'download left temporary files'

# Updating while current is a no-op.
: > "$LOG"
runtime update 2>&1 | grep -F 'up to date' >/dev/null || fail 'up-to-date message missing'
[[ ! -s "$LOG" ]] || fail 'up-to-date update patched a binary'

# The latest channel moves to a newer release and keeps the previous one.
CLAUDE_MOBILE_CHANNEL=latest runtime update 2>/dev/null
[[ "$(active)" == versions/1.1.0 ]] || fail 'latest release not activated'
[[ -f "$ROOT/versions/1.0.0" ]] || fail 'previous version was not kept for rollback'

# A release that crashes on start is rejected, blocklisted, and never activated.
set_channel latest 1.2.0
status=0
CLAUDE_MOBILE_CHANNEL=latest runtime update 2>/dev/null || status=$?
((status == 3)) || fail "crashing release returned status $status instead of 3"
[[ "$(active)" == versions/1.1.0 ]] || fail 'crashing release replaced a working one'
[[ ! -e "$ROOT/versions/1.2.0" ]] || fail 'crashing release was kept'
grep -Fx '1.2.0' "$ROOT/blocklist" >/dev/null || fail 'crashing release not blocklisted'

# Later automatic updates skip the blocklisted release without downloading it.
: > "$LOG"
CLAUDE_MOBILE_CHANNEL=latest runtime update 2>&1 | grep -F 'Skipping' >/dev/null || \
  fail 'blocklisted release was not skipped'
[[ ! -s "$LOG" ]] || fail 'blocklisted release was downloaded again'

# A checksum mismatch is refused and leaves the active version alone.
if runtime install 1.3.0 2>/dev/null; then
  fail 'checksum mismatch should fail'
fi
[[ "$(active)" == versions/1.1.0 ]] || fail 'checksum failure changed the active version'
[[ ! -e "$ROOT/versions/1.3.0" ]] || fail 'checksum failure kept the download'
[[ -z "$(find "$ROOT/versions" -name '.download.*')" ]] || fail 'checksum failure left temporary files'

# Installing an older version reuses the local copy.
: > "$LOG"
runtime install 1.0.0 2>/dev/null
[[ "$(active)" == versions/1.0.0 ]] || fail 'explicit older version not activated'
[[ ! -s "$LOG" ]] || fail 'a kept version was downloaded again'

# Only the active and previously active versions are kept.
runtime install 1.4.0 2>/dev/null
[[ "$(active)" == versions/1.4.0 ]] || fail '1.4.0 not activated'
[[ -f "$ROOT/versions/1.0.0" ]] || fail 'previous version pruned'
[[ ! -e "$ROOT/versions/1.1.0" ]] || fail 'old version not pruned'

# --if-due does nothing until the interval has passed.
set_channel stable 1.1.0
runtime update --if-due 2>/dev/null
[[ "$(active)" == versions/1.4.0 ]] || fail '--if-due updated before the interval'
touch -d '2 days ago' "$ROOT/last-update-check"
runtime update --if-due 2>/dev/null
[[ "$(active)" == versions/1.1.0 ]] || fail '--if-due did not update after the interval'

# Unreachable release servers fail without touching the active version.
if HOME="$HOME_DIR" CLAUDE_MOBILE_RELEASES_URL="file://$TEST_ROOT/missing" \
  CLAUDE_MOBILE_GLIBC_LD="$GLIBC_LD" CLAUDE_MOBILE_PATCHELF="$TEST_ROOT/glibc/bin/patchelf" \
  bash "$RUNTIME" update 2>/dev/null; then
  fail 'unreachable release server should fail the update'
fi
[[ "$(active)" == versions/1.1.0 ]] || fail 'network failure changed the active version'

# Missing glibc-runner is reported before any download.
if HOME="$HOME_DIR" CLAUDE_MOBILE_RELEASES_URL="file://$RELEASES" \
  CLAUDE_MOBILE_GLIBC_LD="$TEST_ROOT/nowhere/ld.so" \
  CLAUDE_MOBILE_PATCHELF="$TEST_ROOT/glibc/bin/patchelf" \
  bash "$RUNTIME" install 1.4.0 2>"$TEST_ROOT/err"; then
  fail 'missing glibc loader should fail'
fi
grep -F 'glibc-runner' "$TEST_ROOT/err" >/dev/null || fail 'missing glibc message is unclear'

# Invalid input is rejected.
if runtime install not-a-version 2>/dev/null; then
  fail 'invalid version should fail'
fi
if runtime frobnicate 2>/dev/null; then
  fail 'unknown command should fail'
fi

printf '%s\n' 'Runtime tests passed.'
