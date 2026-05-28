#!/usr/bin/env node
"use strict";

const { spawnSync } = require("node:child_process");
const fs = require("node:fs");
const path = require("node:path");

const exeName = process.platform === "win32" ? "codedb.exe" : "codedb";
const binPath = path.join(__dirname, "..", "vendor", exeName);

if (!fs.existsSync(binPath)) {
  process.stderr.write(
    `codedb: native binary not found at ${binPath}\n` +
      `       the postinstall step may have failed. Re-run:\n` +
      `         npm rebuild codedeebee\n` +
      `       or reinstall:\n` +
      `         npm install -g codedeebee\n`
  );
  process.exit(1);
}

const result = spawnSync(binPath, process.argv.slice(2), {
  stdio: "inherit",
  cwd: process.cwd(),
  env: process.env,
});

if (result.error) {
  process.stderr.write(`codedb: failed to spawn ${binPath}: ${result.error.message}\n`);
  process.exit(1);
}

process.exit(result.status ?? 1);
