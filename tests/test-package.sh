#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

PACK_DIR="$TEST_ROOT/package"
INSTALL_PREFIX="$TEST_ROOT/install"
mkdir -p "$PACK_DIR"

package_file="$(cd "$PROJECT_DIR" && npm pack --silent --pack-destination "$PACK_DIR")"
package_path="$PACK_DIR/$package_file"

if [[ ! -f "$package_path" ]]; then
  printf 'FAIL: npm pack did not create %s\n' "$package_path" >&2
  exit 1
fi

for packed_executable in \
  package/npm-bin/install.js \
  package/install.sh \
  package/uninstall.sh \
  package/bin/claude-mobile \
  package/bin/claude-mobile-resume \
  package/bin/claude-mobile-runtime; do
  archive_mode="$(tar -tvzf "$package_path" "$packed_executable" | awk 'NR == 1 {print $1}')"
  if [[ "$archive_mode" != *x* ]]; then
    printf 'FAIL: %s is not executable in the package archive\n' \
      "$packed_executable" >&2
    exit 1
  fi
done

if ! node -e \
  'const pkg = require(process.argv[1]); process.exit(pkg.scripts?.postinstall ? 1 : 0)' \
  "$PROJECT_DIR/package.json"; then
  printf '%s\n' 'FAIL: package installation must not have a postinstall hook' >&2
  exit 1
fi

npm install --global --prefix "$INSTALL_PREFIX" --force \
  "$package_path" >/dev/null

command_path="$INSTALL_PREFIX/bin/claude-mobile-termux"
if [[ ! -x "$command_path" ]]; then
  printf 'FAIL: packaged command is not executable at %s\n' "$command_path" >&2
  exit 1
fi

help_output="$($command_path --help)"
if [[ "$help_output" != *'claude-mobile-termux uninstall [--purge]'* ]]; then
  printf '%s\n' 'FAIL: packaged command did not display the expected help' >&2
  exit 1
fi

printf '%s\n' 'Packaged installation test passed.'
