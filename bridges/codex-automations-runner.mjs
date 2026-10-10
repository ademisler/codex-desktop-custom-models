#!/usr/bin/env node
import { appendFileSync, existsSync, mkdirSync, readFileSync, readdirSync, renameSync, rmSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { spawnSync } from "node:child_process";
import { randomUUID } from "node:crypto";
import { homedir } from "node:os";

const codexHome = process.env.CODEX_AUTOMATIONS_HOME || process.env.CODEX_HOME || join(homedir(), ".codex-custom-models");
const automationsDir = join(codexHome, "automations");
const sqlitePath = join(codexHome, "sqlite", "codex-dev.db");
const runnerStatePath = join(automationsDir, ".runner-state.json");
const runnerLogPath = join(automationsDir, "runner.log");
const lockDir = join(automationsDir, ".runner.lock");
const codexBin = process.env.CODEX_CUSTOM_BIN || process.env.CODEX_AUTOMATIONS_CODEX_BIN || "codex";
const pollMs = Math.max(5000, Number(process.env.CODEX_AUTOMATIONS_POLL_MS || 10000));
const maxRuntimeMs = Math.max(60000, Number(process.env.CODEX_AUTOMATIONS_MAX_RUNTIME_MS || 20 * 60 * 1000));
const defaultCwd = process.env.CODEX_AUTOMATIONS_DEFAULT_CWD || homedir();

const args = new Set(process.argv.slice(2));
const once = args.has("--once");
const force = args.has("--force");
const onlyId = valueAfter("--id");

function valueAfter(flag) {
  const index = process.argv.indexOf(flag);
  return index >= 0 ? process.argv[index + 1] : "";
}

function nowMs() {
  return Date.now();
}

function log(message, extra = {}) {
  mkdirSync(automationsDir, { recursive: true });
  appendFileSync(runnerLogPath, `${new Date().toISOString()} ${message} ${JSON.stringify(extra)}\n`);
}

function sqlString(value) {
  return `'${String(value ?? "").replaceAll("'", "''")}'`;
}

function runSql(sql) {
  mkdirSync(dirname(sqlitePath), { recursive: true });
  const result = spawnSync("sqlite3", [sqlitePath], { input: sql, encoding: "utf8", maxBuffer: 2 * 1024 * 1024 });
  if (result.status !== 0) throw new Error(result.stderr || result.stdout || "sqlite3 failed");
  return result.stdout;
}

function queryJson(dbPath, sql) {
  if (!existsSync(dbPath)) return [];
  const result = spawnSync("sqlite3", ["-json", dbPath, sql], { encoding: "utf8", maxBuffer: 4 * 1024 * 1024 });
  if (result.status !== 0) throw new Error(result.stderr || result.stdout || "sqlite3 query failed");
  return result.stdout.trim() ? JSON.parse(result.stdout) : [];
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

function findStateDb() {
  if (!existsSync(codexHome)) return join(codexHome, "state_5.sqlite");
  const names = readdirSync(codexHome).filter((name) => /^state_\d+\.sqlite$/.test(name)).sort().reverse();
  return names.length ? join(codexHome, names[0]) : join(codexHome, "state_5.sqlite");
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

function parseAutomationToml(file) {
  const item = {};
  for (const line of readFileSync(file, "utf8").split(/\r?\n/)) {
    const match = /^([A-Za-z0-9_]+)\s*=\s*(.+)$/.exec(line.trim());
    if (match) item[match[1]] = parseTomlValue(match[2]);
  }
  item.file = file;
  item.dir = dirname(file);
  item.kind = String(item.kind || "cron").toLowerCase();
  item.destination = String(item.destination || (item.kind === "heartbeat" ? "thread" : "inbox")).toLowerCase();
  item.cwds = Array.isArray(item.cwds) ? item.cwds.map(String).filter(Boolean) : [];
  item.status = String(item.status || "ACTIVE").toUpperCase();
  item.model = String(item.model || process.env.CUSTOM_CODEX_MODEL || "MiniMax-M2.7");
  item.reasoning_effort = String(item.reasoning_effort || "none");
  return item;
}

function loadAutomations() {
  if (!existsSync(automationsDir)) return [];
  return readdirSync(automationsDir, { withFileTypes: true })
    .filter((entry) => entry.isDirectory() && !entry.name.startsWith("."))
    .map((entry) => join(automationsDir, entry.name, "automation.toml"))
    .filter((file) => existsSync(file))
    .map(parseAutomationToml)
    .filter((item) => !onlyId || item.id === onlyId);
}

function loadRunnerState() {
  if (!existsSync(runnerStatePath)) return {};
  try {
    return JSON.parse(readFileSync(runnerStatePath, "utf8"));
  } catch {
    return {};
  }
}

function saveRunnerState(state) {
  mkdirSync(automationsDir, { recursive: true });
  const tmp = `${runnerStatePath}.${process.pid}.tmp`;
  writeFileSync(tmp, JSON.stringify(state, null, 2));
  renameSync(tmp, runnerStatePath);
}

function computeNextAfter(rrule, afterMs) {
  const rule = String(rrule || "RRULE:FREQ=HOURLY;INTERVAL=1").replace(/^RRULE:/i, "");
  const frequency = /FREQ=([^;]+)/i.exec(rule)?.[1]?.toUpperCase() || "HOURLY";
  const interval = Math.max(1, Number(/INTERVAL=(\d+)/i.exec(rule)?.[1] || 1));
  if (frequency === "MINUTELY") return afterMs + interval * 60_000;
  if (frequency === "HOURLY" && !/BYMINUTE=/i.test(rule)) return afterMs + interval * 60 * 60_000;
  const byMinute = /BYMINUTE=(\d+)/i.exec(rule)?.[1];
  if (frequency === "HOURLY" && byMinute != null) {
    const next = new Date(afterMs);
    next.setSeconds(0, 0);
    next.setMinutes(Number(byMinute));
    while (next.getTime() <= afterMs) next.setHours(next.getHours() + interval);
    return next.getTime();
  }
  const byHour = /BYHOUR=(\d+)/i.exec(rule)?.[1];
  if (frequency === "DAILY" && byHour != null) {
    const next = new Date(afterMs);
    next.setSeconds(0, 0);
    next.setMinutes(Number(byMinute || 0));
    next.setHours(Number(byHour));
    while (next.getTime() <= afterMs) next.setDate(next.getDate() + interval);
    return next.getTime();
  }
  return afterMs + 60 * 60_000;
}

function latestThread() {
  try {
    return queryJson(
      findStateDb(),
      "SELECT id, cwd, title FROM threads WHERE archived = 0 ORDER BY updated_at_ms DESC, updated_at DESC LIMIT 1;",
    )[0] || null;
  } catch {
    return null;
  }
}

function threadById(id) {
  if (!id) return null;
  try {
    return queryJson(findStateDb(), `SELECT id, cwd, title FROM threads WHERE id = ${sqlString(id)} LIMIT 1;`)[0] || null;
  } catch {
    return null;
  }
}

function dbAutomation(id) {
  try {
    return queryJson(sqlitePath, `SELECT * FROM automations WHERE id = ${sqlString(id)} LIMIT 1;`)[0] || null;
  } catch {
    return null;
  }
}

function ensureDueState(item, dbRow, state) {
  const entry = state[item.id] || {};
  if (force) {
    entry.next_run_at = nowMs();
  } else if (!entry.next_run_at) {
    entry.next_run_at = Number(dbRow?.next_run_at || 0) || computeNextAfter(item.rrule, Number(item.created_at || nowMs()));
    if (entry.next_run_at < nowMs() - 5 * 60_000) entry.next_run_at = computeNextAfter(item.rrule, nowMs());
  }
  state[item.id] = entry;
  return entry;
}

function automationPrompt(item, lastRunAt, currentRunAt) {
  const memoryPath = `$CODEX_HOME/automations/${item.id}/memory.md`;
  const delivery = item.destination === "thread"
    ? "This automation is being delivered to the target Codex chat thread. Answer normally in the chat. Do not emit an inbox directive."
    : "This automation is running as a background job. If useful, emit one ::inbox-item{title=\"...\" summary=\"...\"} directive in the final response.";
  const lastRun = lastRunAt ? `${new Date(lastRunAt).toISOString()} (${lastRunAt})` : "never";
  const currentRun = `${new Date(currentRunAt).toISOString()} (${currentRunAt})`;
  return `${delivery}

Automation: ${item.name}
Automation ID: ${item.id}
Automation memory: ${memoryPath}
Last successful runner execution: ${lastRun}
Current runner execution started: ${currentRun}

If the memory file exists, read it first. At the end of the run, update that memory file with a short summary.

${item.prompt}`;
}

function writableRoots(item, cwd) {
  const roots = new Set([item.dir, join(codexHome, "memories")]);
  if (cwd) roots.add(cwd);
  return Array.from(roots).filter(Boolean);
}

function extractSessionId(output) {
  return /session id:\s*([0-9a-f-]{36})/i.exec(output || "")?.[1] || "";
}

function parseInboxDirective(text, fallbackTitle) {
  const match = /::inbox-item\{([^}]*)\}/.exec(text || "");
  const attrs = {};
  if (match) {
    for (const attr of match[1].matchAll(/([A-Za-z_][A-Za-z0-9_]*)="([^"]*)"/g)) attrs[attr[1]] = attr[2];
  }
  const clean = String(text || "").replace(/::inbox-item\{[^}]*\}/g, "").trim();
  return {
    title: attrs.title || fallbackTitle || "Automation run",
    summary: attrs.summary || clean.split(/\r?\n/).find(Boolean)?.slice(0, 180) || "Automation completed",
  };
}

function upsertRunRecord({ item, status, threadId, cwd, output, startedAt, completedAt }) {
  if (!threadId) return;
  const inbox = parseInboxDirective(output, item.name);
  runSql(`
INSERT INTO automation_runs (thread_id, automation_id, status, read_at, thread_title, source_cwd, inbox_title, inbox_summary, created_at, updated_at)
VALUES (${sqlString(threadId)}, ${sqlString(item.id)}, ${sqlString(status)}, NULL, ${sqlString(item.name)}, ${sqlString(cwd || "")}, ${sqlString(inbox.title)}, ${sqlString(inbox.summary)}, ${startedAt}, ${completedAt})
ON CONFLICT(thread_id) DO UPDATE SET
  automation_id=excluded.automation_id,
  status=excluded.status,
  thread_title=excluded.thread_title,
  source_cwd=excluded.source_cwd,
  inbox_title=excluded.inbox_title,
  inbox_summary=excluded.inbox_summary,
  updated_at=excluded.updated_at;
`);
  if (item.destination !== "thread") {
    const inboxId = `${item.id}-${completedAt}`;
    runSql(`
INSERT OR REPLACE INTO inbox_items (id, title, description, thread_id, read_at, created_at)
VALUES (${sqlString(inboxId)}, ${sqlString(inbox.title)}, ${sqlString(inbox.summary)}, ${sqlString(threadId)}, NULL, ${completedAt});
`);
  }
}

function updateDbSchedule(item, lastRunAt, nextRunAt) {
  const createdAt = Number(item.created_at || lastRunAt || nowMs());
  runSql(`
INSERT INTO automations (id, name, prompt, status, next_run_at, last_run_at, cwds, rrule, model, reasoning_effort, created_at, updated_at)
VALUES (${sqlString(item.id)}, ${sqlString(item.name || item.id)}, ${sqlString(item.prompt || "")}, ${sqlString(item.status || "ACTIVE")}, ${nextRunAt}, ${lastRunAt}, ${sqlString(JSON.stringify(item.cwds || []))}, ${sqlString(item.rrule || "RRULE:FREQ=HOURLY;INTERVAL=1")}, ${sqlString(item.model || "")}, ${sqlString(item.reasoning_effort || "none")}, ${createdAt}, ${nowMs()})
ON CONFLICT(id) DO UPDATE SET
  name=excluded.name,
  prompt=excluded.prompt,
  status=excluded.status,
  next_run_at=excluded.next_run_at,
  last_run_at=excluded.last_run_at,
  cwds=excluded.cwds,
  rrule=excluded.rrule,
  model=excluded.model,
  reasoning_effort=excluded.reasoning_effort,
  updated_at=excluded.updated_at;
`);
}

function runAutomation(item, state) {
  const dbRow = dbAutomation(item.id);
  const status = String(dbRow?.status || item.status || "ACTIVE").toUpperCase();
  if (status !== "ACTIVE") return;

  const entry = ensureDueState(item, dbRow, state);
  const dueAt = Number(entry.next_run_at || 0);
  if (!force && dueAt > nowMs()) return;

  const latest = latestThread();
  const targetThreadId = item.target_thread_id || (item.destination === "thread" ? latest?.id || "" : "");
  const thread = threadById(targetThreadId);
  const cwd = item.cwds[0] || thread?.cwd || latest?.cwd || defaultCwd;
  const startedAt = nowMs();
  const outputFile = join(item.dir, `last-output-${startedAt}.txt`);
  const prompt = automationPrompt(item, entry.last_successful_run_at || Number(dbRow?.last_run_at || 0), startedAt);
  const roots = writableRoots(item, cwd);
  const rootConfig = `sandbox_workspace_write.writable_roots=${JSON.stringify(roots)}`;
  const common = ["--skip-git-repo-check", "-m", item.model, "-c", rootConfig, "-o", outputFile, "-"];
  const commandArgs = item.destination === "thread" && targetThreadId
    ? ["exec", "resume", targetThreadId, ...common]
    : ["exec", "-C", cwd, ...common];

  log("run_start", { id: item.id, destination: item.destination, targetThreadId, cwd, dueAt });
  const result = spawnSync(codexBin, commandArgs, {
    input: prompt,
    cwd,
    env: { ...process.env, CODEX_HOME: codexHome, CODEX_AUTOMATIONS_HOME: codexHome },
    encoding: "utf8",
    timeout: maxRuntimeMs,
    maxBuffer: 80 * 1024 * 1024,
  });

  const completedAt = nowMs();
  const output = existsSync(outputFile) ? readFileSync(outputFile, "utf8") : "";
  const stdout = result.stdout || "";
  const stderr = result.stderr || "";
  const exitStatus = result.error ? "failed" : result.status === 0 ? "completed" : "failed";
  const threadId = targetThreadId || extractSessionId(stdout) || extractSessionId(stderr) || randomUUID();

  entry.last_started_at = startedAt;
  entry.last_completed_at = completedAt;
  entry.last_status = exitStatus;
  if (exitStatus === "completed") entry.last_successful_run_at = completedAt;
  entry.next_run_at = computeNextAfter(item.rrule, completedAt);
  state[item.id] = entry;
  updateDbSchedule(item, completedAt, entry.next_run_at);
  upsertRunRecord({ item, status: exitStatus, threadId, cwd, output, startedAt, completedAt });
  log("run_complete", {
    id: item.id,
    status: exitStatus,
    threadId,
    exitCode: result.status,
    signal: result.signal,
    error: result.error?.message || null,
    nextRunAt: entry.next_run_at,
    stdoutTail: stdout.slice(-1000),
    stderrTail: stderr.slice(-1000),
  });
}

function withLock(fn) {
  try {
    mkdirSync(lockDir, { recursive: false });
    writeFileSync(join(lockDir, "pid"), String(process.pid));
  } catch {
    log("lock_busy");
    return;
  }
  try {
    fn();
  } finally {
    rmSync(lockDir, { recursive: true, force: true });
  }
}

function tick() {
  withLock(() => {
    ensureStore();
    const state = loadRunnerState();
    for (const item of loadAutomations()) {
      try {
        runAutomation(item, state);
      } catch (error) {
        log("run_error", { id: item.id, error: error.message || String(error) });
      }
    }
    saveRunnerState(state);
  });
}

mkdirSync(automationsDir, { recursive: true });
if (once) {
  tick();
} else {
  log("runner_started", { pollMs, codexBin });
  tick();
  setInterval(tick, pollMs);
}
