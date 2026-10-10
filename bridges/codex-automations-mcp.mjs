#!/usr/bin/env node
import { existsSync, mkdirSync, readFileSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { spawnSync } from "node:child_process";
import { homedir } from "node:os";

const codexHome = process.env.CODEX_AUTOMATIONS_HOME || process.env.CODEX_HOME || join(homedir(), ".codex-custom-models");
const automationsDir = join(codexHome, "automations");
const sqlitePath = join(codexHome, "sqlite", "codex-dev.db");
const defaultModel = process.env.CODEX_AUTOMATIONS_MODEL || process.env.CUSTOM_CODEX_MODEL || "MiniMax-M2.7";

function nowMs() {
  return Date.now();
}

function slug(value) {
  return String(value || "automation")
    .toLowerCase()
    .normalize("NFKD")
    .replace(/[^\w\s-]/g, "")
    .trim()
    .replace(/[-\s]+/g, "-")
    .slice(0, 64) || "automation";
}

function tomlString(value) {
  return JSON.stringify(String(value ?? ""));
}

function sqlString(value) {
  return `'${String(value ?? "").replaceAll("'", "''")}'`;
}

function runSql(sql) {
  const result = spawnSync("sqlite3", [sqlitePath], {
    input: sql,
    encoding: "utf8",
    maxBuffer: 2 * 1024 * 1024,
  });
  if (result.status !== 0) throw new Error(result.stderr || result.stdout || "sqlite3 failed");
  return result.stdout;
}

function queryJson(dbPath, sql) {
  if (!existsSync(dbPath)) return [];
  const result = spawnSync("sqlite3", ["-json", dbPath, sql], {
    encoding: "utf8",
    maxBuffer: 4 * 1024 * 1024,
  });
  if (result.status !== 0) throw new Error(result.stderr || result.stdout || "sqlite3 query failed");
  return result.stdout.trim() ? JSON.parse(result.stdout) : [];
}

function findStateDb() {
  if (!existsSync(codexHome)) return join(codexHome, "state_5.sqlite");
  const names = readdirSync(codexHome)
    .filter((name) => /^state_\d+\.sqlite$/.test(name))
    .sort()
    .reverse();
  return names.length ? join(codexHome, names[0]) : join(codexHome, "state_5.sqlite");
}

function latestThreadContext() {
  const statePath = findStateDb();
  try {
    return queryJson(
      statePath,
      "SELECT id, cwd, title, updated_at_ms FROM threads WHERE archived = 0 ORDER BY updated_at_ms DESC, updated_at DESC LIMIT 1;",
    )[0] || null;
  } catch {
    return null;
  }
}

function ensureStore() {
  mkdirSync(automationsDir, { recursive: true });
  mkdirSync(dirname(sqlitePath), { recursive: true });
  runSql(`
CREATE TABLE IF NOT EXISTS automations (
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  prompt TEXT NOT NULL,
  status TEXT NOT NULL DEFAULT 'ACTIVE',
  next_run_at INTEGER,
  last_run_at INTEGER,
  cwds TEXT NOT NULL DEFAULT '[]',
  rrule TEXT NOT NULL,
  model TEXT,
  reasoning_effort TEXT,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS automation_runs (
  thread_id TEXT PRIMARY KEY,
  automation_id TEXT NOT NULL,
  status TEXT NOT NULL,
  read_at INTEGER,
  thread_title TEXT,
  source_cwd TEXT,
  inbox_title TEXT,
  inbox_summary TEXT,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  archived_user_message TEXT,
  archived_assistant_message TEXT,
  archived_reason TEXT
);
CREATE TABLE IF NOT EXISTS inbox_items (
  id TEXT PRIMARY KEY,
  title TEXT,
  description TEXT,
  thread_id TEXT,
  read_at INTEGER,
  created_at INTEGER
);
`);
}

function normalizeRrule(rrule, runAfterMinutes) {
  if (rrule && String(rrule).trim()) {
    const raw = String(rrule).trim();
    return raw.startsWith("RRULE:") ? raw : `RRULE:${raw}`;
  }
  if (runAfterMinutes != null) {
    return `RRULE:FREQ=MINUTELY;INTERVAL=${Math.max(1, Number(runAfterMinutes) || 1)}`;
  }
  return "RRULE:FREQ=HOURLY;INTERVAL=1;BYMINUTE=0";
}

function nextRunAt(rrule, runAfterMinutes) {
  if (runAfterMinutes != null) return nowMs() + Math.max(1, Number(runAfterMinutes) || 1) * 60_000;
  const rule = String(rrule || "").replace(/^RRULE:/i, "");
  const frequency = /FREQ=([^;]+)/i.exec(rule)?.[1]?.toUpperCase() || "HOURLY";
  const interval = Math.max(1, Number(/INTERVAL=(\d+)/i.exec(rule)?.[1] || 1));
  if (frequency === "MINUTELY") return nowMs() + interval * 60_000;
  if (frequency === "HOURLY" && !/BYMINUTE=/i.test(rule)) return nowMs() + interval * 60 * 60_000;
  const byMinute = /BYMINUTE=(\d+)/i.exec(rule)?.[1];
  if (frequency === "HOURLY" && byMinute != null) {
    const next = new Date();
    next.setSeconds(0, 0);
    next.setMinutes(Number(byMinute));
    while (next.getTime() <= nowMs()) next.setHours(next.getHours() + interval);
    return next.getTime();
  }
  return nowMs() + 60 * 60_000;
}

function normalizeCwds(cwds) {
  if (Array.isArray(cwds)) return cwds.map(String).filter(Boolean);
  if (typeof cwds === "string" && cwds.trim()) return [cwds.trim()];
  return [];
}

function parseTomlValue(raw) {
  const value = raw.trim();
  if (value.startsWith("\"")) return JSON.parse(value);
  if (value.startsWith("[")) return JSON.parse(value);
  if (/^-?\d+$/.test(value)) return Number(value);
  if (value === "true") return true;
  if (value === "false") return false;
  return value;
}

function readAutomationToml(id) {
  const file = join(automationsDir, slug(id), "automation.toml");
  if (!existsSync(file)) return {};
  const item = {};
  for (const line of readFileSync(file, "utf8").split(/\r?\n/)) {
    const match = /^([A-Za-z0-9_]+)\s*=\s*(.+)$/.exec(line.trim());
    if (match) item[match[1]] = parseTomlValue(match[2]);
  }
  return item;
}

function writeAutomationToml(item) {
  const dir = join(automationsDir, item.id);
  mkdirSync(dir, { recursive: true });
  const file = join(dir, "automation.toml");
  const lines = [
    "version = 1",
    `id = ${tomlString(item.id)}`,
    `kind = ${tomlString(item.kind)}`,
    `destination = ${tomlString(item.destination)}`,
    item.target_thread_id ? `target_thread_id = ${tomlString(item.target_thread_id)}` : null,
    `name = ${tomlString(item.name)}`,
    `prompt = ${tomlString(item.prompt)}`,
    `status = ${tomlString(item.status)}`,
    `rrule = ${tomlString(item.rrule)}`,
    `model = ${tomlString(item.model)}`,
    `reasoning_effort = ${tomlString(item.reasoning_effort)}`,
    `execution_environment = ${tomlString(item.execution_environment)}`,
    item.local_environment_config_path ? `local_environment_config_path = ${tomlString(item.local_environment_config_path)}` : null,
    `cwds = [${item.cwds.map(tomlString).join(", ")}]`,
    `created_at = ${item.created_at}`,
    `updated_at = ${item.updated_at}`,
    "runner_managed = true",
    "",
  ].filter((line) => line != null);
  writeFileSync(file, lines.join("\n"), { mode: 0o600 });
  return file;
}

function listAutomations() {
  ensureStore();
  return queryJson(sqlitePath, "SELECT * FROM automations ORDER BY updated_at DESC;");
}

function viewAutomation(id) {
  ensureStore();
  const item = queryJson(sqlitePath, `SELECT * FROM automations WHERE id = ${sqlString(slug(id))} LIMIT 1;`)[0];
  if (!item) throw new Error(`automation not found: ${id}`);
  return item;
}

function deleteAutomation(id) {
  ensureStore();
  const safeId = slug(id);
  runSql(`
DELETE FROM automations WHERE id = ${sqlString(safeId)};
DELETE FROM automation_runs WHERE automation_id = ${sqlString(safeId)};
`);
  rmSync(join(automationsDir, safeId), { recursive: true, force: true });
  return { action: "deleted", id: safeId };
}

function upsertAutomation(args) {
  ensureStore();
  const now = nowMs();
  const id = args.id ? slug(args.id) : `${slug(args.name)}-${now}`;
  const existing = queryJson(sqlitePath, `SELECT * FROM automations WHERE id = ${sqlString(id)} LIMIT 1;`)[0];
  const existingToml = readAutomationToml(id);
  const context = latestThreadContext();
  const kindRaw = String(args.kind || existingToml.kind || "").toLowerCase();
  const destinationRaw = String(args.destination || existingToml.destination || "").toLowerCase();
  const kind = kindRaw === "heartbeat" || destinationRaw === "thread" || args.targetThreadId || args.target_thread_id
    ? "heartbeat"
    : "cron";
  const destination = destinationRaw === "thread" || kind === "heartbeat" ? "thread" : "inbox";
  const targetThreadId = String(
    args.targetThreadId ||
    args.target_thread_id ||
    existingToml.target_thread_id ||
    (destination === "thread" ? context?.id || "" : ""),
  );
  const cwds = normalizeCwds(args.cwds ?? (existing ? JSON.parse(existing.cwds || "[]") : []));
  const rrule = normalizeRrule(args.rrule || existing?.rrule, args.run_after_minutes ?? args.runAfterMinutes);
  const item = {
    id,
    kind,
    destination,
    target_thread_id: targetThreadId,
    name: String(args.name || existing?.name || id),
    prompt: String(args.prompt || existing?.prompt || ""),
    status: String(args.status || existing?.status || "ACTIVE").toUpperCase(),
    rrule,
    cwds: cwds.length ? cwds : (context?.cwd ? [context.cwd] : []),
    model: String(args.model || existing?.model || defaultModel),
    reasoning_effort: String(args.reasoning_effort || args.reasoningEffort || existing?.reasoning_effort || "none"),
    execution_environment: String(args.executionEnvironment || args.execution_environment || existingToml.execution_environment || "local"),
    local_environment_config_path: args.localEnvironmentConfigPath || args.local_environment_config_path || existingToml.local_environment_config_path || "",
    created_at: existing?.created_at || now,
    updated_at: now,
  };
  if (!item.prompt.trim()) throw new Error("prompt is required");
  const next = nextRunAt(item.rrule, args.run_after_minutes ?? args.runAfterMinutes);
  const file = writeAutomationToml(item);
  runSql(`
INSERT INTO automations (id, name, prompt, status, next_run_at, last_run_at, cwds, rrule, model, reasoning_effort, created_at, updated_at)
VALUES (${sqlString(item.id)}, ${sqlString(item.name)}, ${sqlString(item.prompt)}, ${sqlString(item.status)}, ${next}, NULL, ${sqlString(JSON.stringify(item.cwds))}, ${sqlString(item.rrule)}, ${sqlString(item.model)}, ${sqlString(item.reasoning_effort)}, ${item.created_at}, ${item.updated_at})
ON CONFLICT(id) DO UPDATE SET
  name=excluded.name,
  prompt=excluded.prompt,
  status=excluded.status,
  next_run_at=excluded.next_run_at,
  cwds=excluded.cwds,
  rrule=excluded.rrule,
  model=excluded.model,
  reasoning_effort=excluded.reasoning_effort,
  updated_at=excluded.updated_at;
`);
  return { action: existing ? "updated" : "created", id: item.id, file, next_run_at: new Date(next).toISOString(), item };
}

const tools = [{
  name: "automation_update",
  description: "Create, update, view, list, or delete local Codex App automations for this isolated custom profile. Use for reminders, recurring tasks, monitors, and same-thread follow-ups.",
  inputSchema: {
    type: "object",
    additionalProperties: false,
    properties: {
      mode: { type: "string", enum: ["create", "update", "view", "list", "delete"] },
      id: { type: "string" },
      kind: { type: "string", enum: ["cron", "heartbeat"] },
      destination: { type: "string", enum: ["thread", "inbox"] },
      targetThreadId: { type: "string" },
      name: { type: "string" },
      prompt: { type: "string" },
      status: { type: "string", enum: ["ACTIVE", "PAUSED"] },
      rrule: { type: "string" },
      run_after_minutes: { type: "number" },
      cwds: { oneOf: [{ type: "string" }, { type: "array", items: { type: "string" } }] },
      model: { type: "string" },
      reasoning_effort: { type: "string" },
      reasoningEffort: { type: "string" },
      executionEnvironment: { type: "string", enum: ["local", "worktree"] },
      localEnvironmentConfigPath: { type: ["string", "null"] },
    },
    required: ["mode"],
  },
}];

async function handle(method, params = {}) {
  if (method === "initialize") {
    return {
      protocolVersion: params.protocolVersion || "2024-11-05",
      capabilities: { tools: { listChanged: false }, resources: { listChanged: false }, prompts: { listChanged: false } },
      serverInfo: { name: "codex-custom-models-automations", version: "0.1.0" },
    };
  }
  if (method === "tools/list") return { tools };
  if (method === "resources/list") return { resources: [] };
  if (method === "resources/templates/list") return { resourceTemplates: [] };
  if (method === "prompts/list") return { prompts: [] };
  if (method === "tools/call") {
    if (params.name !== "automation_update") throw new Error(`unknown tool: ${params.name}`);
    const args = params.arguments || params.args || {};
    let result;
    if (args.mode === "list") result = listAutomations();
    else if (args.mode === "view") result = viewAutomation(args.id);
    else if (args.mode === "delete") result = deleteAutomation(args.id);
    else if (args.mode === "create" || args.mode === "update") result = upsertAutomation(args);
    else throw new Error(`unsupported mode: ${args.mode}`);
    return { content: [{ type: "text", text: JSON.stringify(result, null, 2) }] };
  }
  return {};
}

let buffer = Buffer.alloc(0);

process.stdin.on("data", (chunk) => {
  buffer = Buffer.concat([buffer, chunk]);
  drain();
});

function drain() {
  while (buffer.length) {
    let separator = Buffer.from("\r\n\r\n");
    let headerEnd = buffer.indexOf(separator);
    if (headerEnd === -1) {
      separator = Buffer.from("\n\n");
      headerEnd = buffer.indexOf(separator);
    }
    if (headerEnd === -1) {
      const newline = buffer.indexOf("\n");
      if (newline === -1) return;
      const line = buffer.slice(0, newline).toString("utf8").trim();
      buffer = buffer.slice(newline + 1);
      if (!line.startsWith("{")) continue;
      processMessage(line).catch((error) => send({ jsonrpc: "2.0", id: null, error: { code: -32603, message: error.message } }));
      continue;
    }

    const header = buffer.slice(0, headerEnd).toString("utf8");
    const match = /content-length:\s*(\d+)/i.exec(header);
    if (!match) {
      buffer = Buffer.alloc(0);
      return;
    }
    const length = Number(match[1]);
    const bodyStart = headerEnd + separator.length;
    const bodyEnd = bodyStart + length;
    if (buffer.length < bodyEnd) return;
    const raw = buffer.slice(bodyStart, bodyEnd).toString("utf8");
    buffer = buffer.slice(bodyEnd);
    processMessage(raw).catch((error) => send({ jsonrpc: "2.0", id: null, error: { code: -32603, message: error.message } }));
  }
}

async function processMessage(raw) {
  const message = JSON.parse(raw);
  if (!("id" in message)) return;
  try {
    const result = await handle(message.method, message.params);
    send({ jsonrpc: "2.0", id: message.id, result });
  } catch (error) {
    send({ jsonrpc: "2.0", id: message.id, error: { code: -32000, message: error.message } });
  }
}

function send(message) {
  process.stdout.write(`${JSON.stringify(message)}\n`);
}
