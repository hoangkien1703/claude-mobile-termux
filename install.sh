#!/data/data/com.termux/files/usr/bin/bash
set -Eeuo pipefail

PROJECT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
CLAUDE_MOBILE_VERSION="${CLAUDE_MOBILE_VERSION:-stable}"
ARCH="${CLAUDE_MOBILE_ARCH:-$(uname -m)}"
LAUNCHERS=(claude-mobile claude-mobile-resume claude-mobile-runtime)

if [[ "${CLAUDE_MOBILE_TESTING:-0}" != "1" ]]; then
  if [[ -z "${PREFIX:-}" ]] || ! command -v pkg >/dev/null 2>&1; then
    printf '%s\n' 'This installer must be run inside Termux.' >&2
    exit 1
  fi
fi

if [[ -z "${PREFIX:-}" ]]; then
  printf '%s\n' 'PREFIX is not set; run this script inside Termux.' >&2
  exit 1
fi

CLAUDE_COMMAND="$PREFIX/bin/claude"
CLAUDE_COMMAND_BACKUP="$PREFIX/bin/claude.claude-mobile-backup"

case "$ARCH" in
  aarch64|arm64) ;;
  *)
    printf 'Unsupported architecture: %s (ARM64/aarch64 is required).\n' "$ARCH" >&2
    exit 1
    ;;
esac

for launcher in "${LAUNCHERS[@]}"; do
  if [[ ! -f "$PROJECT_DIR/bin/$launcher" ]]; then
    printf '%s\n' 'Launcher files are missing. Clone the complete repository and try again.' >&2
    exit 1
  fi
done

backup_claude_command=0
if [[ -e "$CLAUDE_COMMAND" || -L "$CLAUDE_COMMAND" ]]; then
  if [[ ! -L "$CLAUDE_COMMAND" ]] || \
     [[ "$(readlink "$CLAUDE_COMMAND")" != "claude-mobile" ]]; then
    if [[ -e "$CLAUDE_COMMAND_BACKUP" || -L "$CLAUDE_COMMAND_BACKUP" ]]; then
      printf 'Cannot install %s because both it and backup %s already exist.\n' \
        "$CLAUDE_COMMAND" "$CLAUDE_COMMAND_BACKUP" >&2
      exit 1
    fi
    backup_claude_command=1
  fi
fi

printf '%s\n' 'Installing Termux dependencies...'
pkg install -y tmux termux-api curl jq glibc-repo
# glibc-repo adds a package source, so refresh the index before using it.
pkg update
pkg install -y glibc-runner patchelf-glibc

for launcher in "${LAUNCHERS[@]}"; do
  install -m 755 "$PROJECT_DIR/bin/$launcher" "$PREFIX/bin/$launcher"
done

printf 'Installing Claude Code (%s)...\n' "$CLAUDE_MOBILE_VERSION"
runtime_status=0
"$BASH" "$PREFIX/bin/claude-mobile-runtime" install "$CLAUDE_MOBILE_VERSION" || \
  runtime_status=$?
if ((runtime_status != 0)); then
  printf '\n%s\n' 'Claude Code could not be installed, so the claude command was not changed.' >&2
  if ((runtime_status == 3)); then
    printf '%s\n' 'This release crashes on this device. Install an older release, for example:' >&2
    printf '%s\n' '  CLAUDE_MOBILE_VERSION=2.1.112 ./install.sh' >&2
  fi
  exit 1
fi

if ((backup_claude_command)); then
  mv "$CLAUDE_COMMAND" "$CLAUDE_COMMAND_BACKUP"
  printf 'Backed up the existing claude command to %s.\n' "$CLAUDE_COMMAND_BACKUP"
fi

if ! ln -sfn claude-mobile "$CLAUDE_COMMAND"; then
  printf 'Unable to install the claude command at %s.\n' "$CLAUDE_COMMAND" >&2
  if ((backup_claude_command)); then
    rm -f "$CLAUDE_COMMAND"
    if mv "$CLAUDE_COMMAND_BACKUP" "$CLAUDE_COMMAND"; then
      printf '%s\n' 'The previous claude command was restored.' >&2
    else
      printf 'Restore failed; the previous command remains at %s.\n' \
        "$CLAUDE_COMMAND_BACKUP" >&2
    fi
  fi
  exit 1
fi

mkdir -p "$HOME/.shortcuts"
# Keep PREFIX and positional arguments literal for evaluation by the Widget.
# shellcheck disable=SC2016
printf '%s\n' \
  '#!/data/data/com.termux/files/usr/bin/bash' \
  'exec "${PREFIX:-/data/data/com.termux/files/usr}/bin/claude-mobile" "$@"' \
  > "$HOME/.shortcuts/Claude Mobile"
# shellcheck disable=SC2016
printf '%s\n' \
  '#!/data/data/com.termux/files/usr/bin/bash' \
  'exec "${PREFIX:-/data/data/com.termux/files/usr}/bin/claude-mobile-resume" "$@"' \
  > "$HOME/.shortcuts/Claude Mobile Resume"
chmod 700 "$HOME/.shortcuts/Claude Mobile" "$HOME/.shortcuts/Claude Mobile Resume"

printf '\n%s\n' 'Installation complete.'
printf '%s\n' 'Start Claude:  claude        (sign in on first launch)'
printf '%s\n' 'Resume last:   claude-mobile-resume'
printf '%s\n' 'Update now:    claude update'
printf '%s\n' 'Widget shortcuts were added under ~/.shortcuts (Termux:Widget app required).'
