#!/usr/bin/env node

const { spawnSync } = require("node:child_process");
const path = require("node:path");

const usage = `Usage:
  claude-mobile-termux
  claude-mobile-termux uninstall [--purge]`;
const args = process.argv.slice(2);

if (args.length === 1 && ["--help", "-h", "help"].includes(args[0])) {
  console.log(usage);
  process.exit(0);
}

const isInstall = args.length === 0;
const isUninstall =
  args[0] === "uninstall" &&
  (args.length === 1 || (args.length === 2 && args[1] === "--purge"));

if (!isInstall && !isUninstall) {
  console.error(`Invalid command.\n\n${usage}`);
  process.exit(1);
}

if (
  process.env.CLAUDE_MOBILE_TESTING !== "1" &&
  (process.platform !== "android" || process.arch !== "arm64")
) {
  console.error("claude-mobile-termux requires Termux on an ARM64 Android device.");
  process.exit(1);
}

const script = path.resolve(
  __dirname,
  "..",
  isUninstall ? "uninstall.sh" : "install.sh"
);
const scriptArgs = isUninstall ? args.slice(1) : args;

const result = spawnSync("bash", [script, ...scriptArgs], {
  stdio: "inherit",
  env: process.env
});

if (result.error) {
  console.error(`Unable to start the command: ${result.error.message}`);
  process.exit(1);
}

process.exit(result.status ?? 1);
