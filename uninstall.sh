#!/data/data/com.termux/files/usr/bin/bash
set -Eeuo pipefail

if [[ -z "${PREFIX:-}" ]]; then
  printf '%s\n' 'PREFIX is not set; run this script inside Termux.' >&2
  exit 1
fi

CLAUDE_COMMAND="$PREFIX/bin/claude"
CLAUDE_COMMAND_BACKUP="$PREFIX/bin/claude.claude-mobile-backup"

if [[ -L "$CLAUDE_COMMAND" ]] && \
   [[ "$(readlink "$CLAUDE_COMMAND")" == "claude-mobile" ]]; then
  rm -f "$CLAUDE_COMMAND"
fi

if [[ ! -e "$CLAUDE_COMMAND" && ! -L "$CLAUDE_COMMAND" ]] && \
   [[ -e "$CLAUDE_COMMAND_BACKUP" || -L "$CLAUDE_COMMAND_BACKUP" ]]; then
  mv "$CLAUDE_COMMAND_BACKUP" "$CLAUDE_COMMAND"
  printf '%s\n' 'The previous claude command was restored.'
fi

rm -f \
  "$PREFIX/bin/claude-mobile" \
  "$PREFIX/bin/claude-mobile-resume" \
  "$PREFIX/bin/claude-mobile-runtime" \
  "$HOME/.shortcuts/Claude Mobile" \
  "$HOME/.shortcuts/Claude Mobile Resume"

if [[ "${1:-}" == "--purge" ]]; then
  rm -rf "$HOME/.local/claude-termux"
  printf '%s\n' 'Launchers, shortcuts, and the patched Claude Code binaries were removed.'
else
  printf '%s\n' 'Launchers and shortcuts were removed.'
  printf '%s\n' 'The runtime remains in ~/.local/claude-termux; use --purge to remove it too.'
fi

printf '%s\n' 'Your Claude Code settings and credentials (~/.claude and ~/.claude.json) were not removed.'
printf '%s\n' 'The glibc-runner and patchelf-glibc Termux packages were left installed.'
