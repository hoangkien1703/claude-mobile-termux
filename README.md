# Claude Mobile for Termux

Run [Claude Code](https://code.claude.com/docs/en/overview) on an ARM64 Android
phone in a persistent `tmux` session. The launcher keeps the phone awake when
Termux:API is available and lets you reconnect after you switch apps or close
Termux.

> [!IMPORTANT]
> This is an **unofficial community project**. Anthropic does not support
> Claude Code on Android or Termux, and this project is not maintained or
> endorsed by Anthropic. It downloads Anthropic's **official** `linux-arm64`
> Claude Code binary from `downloads.claude.ai` and adapts it on your phone. No
> third-party build of Claude Code is involved.

## How it works

Claude Code is a glibc Linux program, but Android uses a different C library
(Bionic), so the official binary cannot start in Termux as-is. The installer:

1. installs Termux's `glibc-runner` and `patchelf-glibc` packages;
2. downloads the official `linux-arm64` binary and checks its SHA-256 against
   Anthropic's published release manifest;
3. points the binary at Termux's glibc loader with `patchelf`;
4. runs a start-up test before the version is used. A release that crashes on
   your device is rejected, and your previous working version stays active.

The launcher also works around a known DNS problem: Claude Code hangs on
"checking connectivity" in Termux because Termux has no `/etc/resolv.conf`.

The glibc patching method and the DNS workaround follow the approach documented
by [`ferrumclaudepilgrim/claude-code-android`](https://github.com/ferrumclaudepilgrim/claude-code-android).

## Requirements

- An ARM64 (`aarch64`) Android phone, with about 600 MB free storage (each
  Claude Code version is about 220 MB, and one previous version is kept)
- [Termux](https://github.com/termux/termux-app) from F-Droid or GitHub (the old
  Google Play build is not supported)
- Internet access
- A Claude Pro, Max, Team, or Enterprise plan, or an Anthropic Console (API)
  account

Optional integrations:

- [Termux:API](https://github.com/termux/termux-api) keeps the phone awake while
  Claude works and opens sign-in links in your browser. Install its Android
  companion app as well as the Termux package.
- [Termux:Widget](https://github.com/termux/termux-widget) adds the two
  launchers as home-screen shortcuts.

## Install

In Termux, install Node.js and Git, install this package with npm, then run its
installer:

```bash
pkg update
pkg install -y nodejs-lts git
npm install --global github:hoangkien1703/claude-mobile-termux
claude-mobile-termux
```

`npm install` only adds the `claude-mobile-termux` command. Running that command
does the real setup, which downloads about 270 MB (Claude Code plus the glibc
packages) and shows its progress. It is a separate step on purpose: npm hides
the output of install hooks, so a long download inside `npm install` would look
frozen.

To do both steps at once without keeping the command installed:

```bash
npx --yes github:hoangkien1703/claude-mobile-termux
```

You can also clone the repository and run the shell installer directly:

```bash
git clone https://github.com/hoangkien1703/claude-mobile-termux.git
cd claude-mobile-termux
./install.sh
```

The installer:

- installs `tmux`, `termux-api`, `curl`, `jq`, `glibc-runner`, and
  `patchelf-glibc`;
- downloads, verifies, patches, and tests Claude Code under
  `~/.local/claude-termux`;
- makes `claude` open the mobile launcher, and adds the `claude-mobile`,
  `claude-mobile-resume`, and `claude-mobile-runtime` commands;
- adds optional Termux:Widget launchers under `~/.shortcuts`.

If a `claude` command already exists (for example, from another Termux guide),
the installer keeps it as `$PREFIX/bin/claude.claude-mobile-backup`. The
uninstaller restores it.

The installer uses the **stable** release channel. To install the newest
release, or a specific version, run:

```bash
CLAUDE_MOBILE_VERSION=latest ./install.sh
CLAUDE_MOBILE_VERSION=2.1.112 ./install.sh
```

Running the installer again safely refreshes the launchers.

## Sign in

Start Claude Code and follow the sign-in prompts:

```bash
claude
```

Choose your Claude account (Pro, Max, Team, or Enterprise) or an Anthropic
Console account. When Termux:API is installed, the sign-in page opens in your
browser. Otherwise, copy the link Claude shows into your browser. If Claude asks
for a code afterwards, paste it into Termux.

To use an API key instead, add it to your shell profile so every session sees
it:

```bash
echo "export ANTHROPIC_API_KEY='your-api-key'" >> ~/.bashrc
chmod 600 ~/.bashrc
```

Claude Code stores its settings in `~/.claude.json` and your sign-in in
`~/.claude/.credentials.json`. Treat these like passwords: never commit, share,
or post them in an issue.

## Use

Start a Claude Code session in a project:

```bash
cd ~/your-project
claude
```

If the `claude` tmux session is already running, the command reconnects to it.
To leave Claude running in the background, press `Ctrl-b`, then `d`.

Continue the most recent conversation in the current folder:

```bash
claude-mobile-resume
```

You can pass normal Claude Code options when starting a new session:

```bash
claude --model sonnet
claude "Explain this repository"
claude --resume          # choose from earlier conversations
```

If a `claude` tmux session is already running, extra options are ignored,
because the launcher reconnects to the running session. End that session first
to start with different options:

```bash
tmux kill-session -t claude
```

Commands that print a result and exit run straight in your terminal, without
tmux: for example `claude -p "question"`, `claude --version`, `claude mcp list`,
and `claude doctor`. To run an interactive session without tmux, use
`CLAUDE_MOBILE_NO_TMUX=1 claude`.

### Termux:Widget

After installing the Termux:Widget Android app, add its widget to the home
screen. It shows:

- **Claude Mobile**
- **Claude Mobile Resume**

Android may stop Termux during long sessions. If that happens, turn off battery
optimization for Termux in Android settings.

## Updates

Once a day, starting Claude checks the stable channel for a new release. When
one is available, it is downloaded (about 220 MB), verified, patched, and tested
before Claude starts. If the check fails or times out, the installed version
starts as usual.

Claude Code's built-in updater is turned off, because it would install an
unpatched build that cannot run in Termux. Use these commands instead:

```bash
claude update                       # check for a new release now
claude install 2.1.112              # switch to a specific version
claude install latest               # switch to the newest release
claude-mobile-runtime status        # show the active version
```

Settings for updates:

```bash
CLAUDE_MOBILE_SKIP_UPDATE=1 claude       # skip the check this time
CLAUDE_MOBILE_CHANNEL=latest claude      # follow the newest releases
CLAUDE_MOBILE_UPDATE_HOURS=168 claude    # check once a week
```

To keep a setting, add an `export` line for it to `~/.bashrc`. On mobile data,
the stable channel and a longer check interval use the least data.

To update the launcher scripts themselves, reinstall the package and run the
installer again:

```bash
npm install --global github:hoangkien1703/claude-mobile-termux
claude-mobile-termux
```

For a Git clone:

```bash
cd ~/claude-mobile-termux
git pull --ff-only
./install.sh
```

## Uninstall

Remove the commands and Widget shortcuts, but keep the downloaded Claude Code
binaries:

```bash
claude-mobile-termux uninstall
```

Remove the commands, shortcuts, and downloaded binaries, then the npm package:

```bash
claude-mobile-termux uninstall --purge
npm uninstall --global claude-mobile-termux
```

From a Git clone, use `./uninstall.sh` or `./uninstall.sh --purge`.

Neither command removes `~/.claude` or `~/.claude.json`, so your settings,
conversations, and sign-in remain. The `glibc-runner` and `patchelf-glibc`
packages also remain. Remove them with `pkg uninstall` if nothing else uses
them.

## Troubleshooting

### A new version crashes on my phone

Some Claude Code releases crash on some Android versions (Android 10 is a known
example). The start-up test catches this: the crashing version is skipped, and
your working version stays active. On a fresh install, choose an older version:

```bash
CLAUDE_MOBILE_VERSION=2.1.112 ./install.sh
```

Then stop automatic updates by adding this line to `~/.bashrc`:

```bash
export CLAUDE_MOBILE_SKIP_UPDATE=1
```

### Claude hangs on "checking connectivity"

The launcher sends Claude Code's own DNS lookups to Google's public resolvers
(`8.8.8.8` and `8.8.4.4`). If your network blocks them, choose other resolvers:

```bash
export CLAUDE_MOBILE_DNS=1.1.1.1,1.0.0.1
```

This setting overrides a VPN or Pi-hole resolver for Claude's own lookups. To
turn the workaround off, set `CLAUDE_MOBILE_DNS=off`.

### A script fails with "No such file or directory"

Termux normally uses a helper library to run scripts whose first line is
`#!/usr/bin/env ...`, but that library crashes glibc programs, so the launcher
turns it off for Claude. Ask Claude to run such scripts through their
interpreter instead, for example `bash script.sh` or `python script.py`.

### Claude Code binary not found

Install it again:

```bash
claude install
```

To test a binary that is stored somewhere else:

```bash
CLAUDE_MOBILE_NATIVE=/path/to/claude claude
```

### An old tmux session opens

List and remove the old session, then start again:

```bash
tmux list-sessions
tmux kill-session -t claude
claude
```

### The sign-in page does not open

Install Termux:API (the Android app and `pkg install termux-api`), or copy the
link that Claude prints into your browser.

### The phone does not stay awake

Install the Termux:API Android companion app from the same source as Termux,
then run:

```bash
pkg install -y termux-api
```

The launcher continues normally if the wake lock is unavailable.

## Development

Run the complete validation on Linux or macOS. Node.js, ShellCheck, `jq`, and
`curl` are required:

```bash
npm ci --force
npm run validate
```

The tests use a local release mirror and a mock `patchelf`, so they never
download Claude Code.

## License

[MIT](LICENSE)
