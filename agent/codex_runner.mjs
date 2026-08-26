#!/usr/bin/env node

import { readFileSync } from "node:fs";
import { spawn } from "node:child_process";

const [invocationPath, ...configuration] = process.argv.slice(2);

if (invocationPath === "--version") {
  const child = spawn("codex", ["--version"], {
    env: process.env,
    stdio: "inherit",
    shell: false,
  });
  child.on("error", () => process.exit(127));
  child.on("close", (code) => process.exit(code ?? 128));
} else {

if (!invocationPath) {
  process.stderr.write("codex runner requires an invocation path\n");
  process.exit(64);
}

let model;
let reasoningEffort;
let webSearch = false;

for (let index = 0; index < configuration.length; index += 1) {
  const option = configuration[index];

  if (option === "--model") {
    model = configuration[++index];
    if (!model) {
      process.stderr.write("codex runner requires a value for --model\n");
      process.exit(64);
    }
  } else if (option === "--reasoning-effort") {
    reasoningEffort = configuration[++index];
    if (!reasoningEffort) {
      process.stderr.write("codex runner requires a value for --reasoning-effort\n");
      process.exit(64);
    }
  } else if (option === "--web-search") {
    webSearch = true;
  } else {
    process.stderr.write(`codex runner rejected option ${option}\n`);
    process.exit(64);
  }
}

let invocation;
try {
  invocation = JSON.parse(readFileSync(invocationPath, "utf8"));
} catch (_error) {
  process.stderr.write("codex runner could not read invocation JSON\n");
  process.exit(65);
}

const contextValue = invocation?.context ?? null;
const validContext =
  contextValue === null ||
  (typeof contextValue === "object" && !Array.isArray(contextValue));

if (!invocation || typeof invocation.instruction !== "string" || !validContext) {
  process.stderr.write("codex runner rejected invocation JSON\n");
  process.exit(65);
}

const context =
  contextValue === null
    ? ""
    : `\n\nContext:\n${JSON.stringify(contextValue)}`;
const prompt = `${invocation.instruction}${context}`;

// Codex ships its own seatbelt/Landlock sandbox, which cannot create the
// unprivileged user namespace it needs inside the Omashiki container. Docker
// already is the isolation boundary, so Codex runs with its own sandbox off.
const args = [
  "exec",
  "--json",
  "--color",
  "never",
  "--ephemeral",
  "--skip-git-repo-check",
  "--ignore-user-config",
  "--ignore-rules",
  "--dangerously-bypass-approvals-and-sandbox",
  "-c",
  `tools.web_search=${webSearch}`,
];

if (model) {
  args.push("--model", model);
}

// Effort is a config override, not part of the model name: Codex resolves
// `gpt-5.6-luna` and `model_reasoning_effort` independently.
if (reasoningEffort) {
  args.push("-c", `model_reasoning_effort="${reasoningEffort}"`);
}

args.push("-");

const child = spawn("codex", args, {
  env: process.env,
  stdio: ["pipe", "pipe", "inherit"],
  shell: false,
});

let buffer = "";
let assistantText = null;
let usage = null;
let threadId = null;
let failure = null;

const consume = (line) => {
  const trimmed = line.trim();
  if (!trimmed) {
    return;
  }

  let event;
  try {
    event = JSON.parse(trimmed);
  } catch (_error) {
    return;
  }

  if (!event || typeof event !== "object") {
    return;
  }

  if (event.type === "thread.started" && typeof event.thread_id === "string") {
    threadId = event.thread_id;
  } else if (event.type === "item.completed") {
    const item = event.item;
    if (item?.type === "agent_message" && typeof item.text === "string") {
      assistantText = item.text;
    } else if (item?.type === "error" && typeof item.message === "string") {
      failure = failure ?? item.message;
    }
  } else if (event.type === "turn.completed") {
    if (event.usage && typeof event.usage === "object") {
      usage = event.usage;
    }
  } else if (event.type === "turn.failed") {
    failure = event.error?.message ?? "codex turn failed";
  } else if (event.type === "error" && typeof event.message === "string") {
    failure = failure ?? event.message;
  }
};

child.stdout.setEncoding("utf8");
child.stdout.on("data", (chunk) => {
  buffer += chunk;
  let newline = buffer.indexOf("\n");
  while (newline !== -1) {
    consume(buffer.slice(0, newline));
    buffer = buffer.slice(newline + 1);
    newline = buffer.indexOf("\n");
  }
});

child.on("error", (error) => {
  process.stderr.write(`codex runner could not start Codex: ${error.message}\n`);
  process.exit(127);
});

child.on("close", (code) => {
  consume(buffer);

  const failed = code !== 0 || assistantText === null || failure !== null;
  const result = {
    type: "result",
    is_error: failed,
    result: failed ? failure ?? "codex produced no agent message" : assistantText,
    thread_id: threadId,
  };

  // Absent usage stays absent: a missing counter is never reported as zero.
  if (model) {
    result.model = model;
  }
  if (usage) {
    result.usage = usage;
  }

  process.stdout.write(`${JSON.stringify(result)}\n`);
  process.exit(failed && code === 0 ? 1 : code ?? 128);
});

child.stdin.end(prompt);
}
