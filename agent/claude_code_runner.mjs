#!/usr/bin/env node

import { readFileSync } from "node:fs";
import { spawn } from "node:child_process";

const [invocationPath, ...configuration] = process.argv.slice(2);

if (invocationPath === "--version") {
  const child = spawn("claude", ["--version"], {
    env: process.env,
    stdio: "inherit",
    shell: false,
  });
  child.on("error", () => process.exit(127));
  child.on("close", (code) => process.exit(code ?? 128));
} else {

if (!invocationPath) {
  process.stderr.write("claude runner requires an invocation path\n");
  process.exit(64);
}

const allowedTools = [];
let model;

for (let index = 0; index < configuration.length; index += 1) {
  const option = configuration[index];

  if (option === "--allowed-tool") {
    const tool = configuration[++index];
    if (!tool) {
      process.stderr.write("claude runner requires a value for --allowed-tool\n");
      process.exit(64);
    }
    allowedTools.push(tool);
  } else if (option === "--model") {
    model = configuration[++index];
    if (!model) {
      process.stderr.write("claude runner requires a value for --model\n");
      process.exit(64);
    }
  } else {
    process.stderr.write(`claude runner rejected option ${option}\n`);
    process.exit(64);
  }
}

let invocation;
try {
  invocation = JSON.parse(readFileSync(invocationPath, "utf8"));
} catch (_error) {
  process.stderr.write("claude runner could not read invocation JSON\n");
  process.exit(65);
}

const contextValue = invocation?.context ?? null;
const validContext =
  contextValue === null ||
  (typeof contextValue === "object" && !Array.isArray(contextValue));

if (!invocation || typeof invocation.instruction !== "string" || !validContext) {
  process.stderr.write("claude runner rejected invocation JSON\n");
  process.exit(65);
}

const context =
  contextValue === null
    ? ""
    : `\n\nContext:\n${JSON.stringify(contextValue)}`;
const prompt = `${invocation.instruction}${context}`;
const args = [
  "--print",
  "--output-format",
  "json",
  "--no-session-persistence",
  "--permission-mode",
  "acceptEdits",
  "--safe-mode",
  "--no-chrome",
  "--strict-mcp-config",
  "--setting-sources",
  "",
  "--tools",
  "Read,Edit,Write,Glob,Grep,Bash",
  "--allowedTools",
  ...allowedTools,
];

if (model) {
  args.push("--model", model);
}

const child = spawn("claude", args, {
  env: process.env,
  stdio: ["pipe", "pipe", "inherit"],
  shell: false,
});

let stdout = "";
child.stdout.setEncoding("utf8");
child.stdout.on("data", (chunk) => {
  stdout += chunk;
});
child.on("error", (error) => {
  process.stderr.write(`claude runner could not start Claude Code: ${error.message}\n`);
  process.exit(127);
});
child.on("close", (code, signal) => {
  process.stdout.write(stdout);
  process.exit(code ?? 128);
});

child.stdin.end(prompt);
}
