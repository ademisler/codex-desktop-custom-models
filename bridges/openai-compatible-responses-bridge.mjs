#!/usr/bin/env node
import http from "node:http";
import { randomUUID } from "node:crypto";
import { appendFileSync } from "node:fs";

const host = process.env.CUSTOM_CODEX_PROXY_HOST || "127.0.0.1";
const port = Number(process.env.CUSTOM_CODEX_PROXY_PORT || "4007");
const apiBase = (process.env.CUSTOM_CODEX_API_BASE || "https://api.openai.com/v1").replace(/\/+$/, "");
const apiKey = process.env.CUSTOM_CODEX_API_KEY || process.env.MINIMAX_API_KEY || process.env.OPENAI_API_KEY;
const providerName = process.env.CUSTOM_CODEX_PROVIDER_NAME || "openai-compatible";
const defaultModel = process.env.CUSTOM_CODEX_MODEL || "MiniMax-M2.7";
const supportedModels = String(process.env.CUSTOM_CODEX_SUPPORTED_MODELS || defaultModel)
  .split(",")
  .map((item) => item.trim())
  .filter(Boolean);
const debugLog = process.env.CUSTOM_CODEX_DEBUG_LOG || "";
const maxTokensField = process.env.CUSTOM_CODEX_MAX_TOKENS_FIELD || "max_completion_tokens";

if (!apiKey) {
  console.error("CUSTOM_CODEX_API_KEY is required");
  process.exit(1);
}

function makeId(prefix) {
  return `${prefix}_${randomUUID().replaceAll("-", "")}`;
}

function debug(event, payload = {}) {
  if (!debugLog) return;
  try {
    appendFileSync(debugLog, `${new Date().toISOString()} ${event} ${JSON.stringify(payload)}\n`);
  } catch {
    // Debug logging must never break model calls.
  }
}

function sendJson(res, status, body) {
  res.writeHead(status, {
    "content-type": "application/json; charset=utf-8",
    "cache-control": "no-store",
  });
  res.end(JSON.stringify(body));
}

function readBody(req) {
  return new Promise((resolve, reject) => {
    let body = "";
    req.setEncoding("utf8");
    req.on("data", (chunk) => {
      body += chunk;
      if (body.length > 64 * 1024 * 1024) {
        reject(new Error("request body too large"));
        req.destroy();
      }
    });
    req.on("end", () => resolve(body));
    req.on("error", reject);
  });
}

function responseText(content) {
  if (content == null) return "";
  if (typeof content === "string") return content;
  if (!Array.isArray(content)) {
    if (typeof content.text === "string") return content.text;
    if (typeof content.output === "string") return content.output;
    return JSON.stringify(content);
  }
  return content
    .map((part) => {
      if (typeof part === "string") return part;
      if (!part || typeof part !== "object") return "";
      if (typeof part.text === "string") return part.text;
      if (typeof part.output === "string") return part.output;
      if (part.type === "input_text") return part.text || "";
      if (part.type === "output_text") return part.text || "";
      if (part.type === "input_image") return "[image input omitted by bridge]";
      if (part.type === "input_audio") return "[audio input omitted by bridge]";
      return "";
    })
    .filter(Boolean)
    .join("\n");
}

function stripThinkBlocks(text) {
  return String(text || "").replace(/<think>[\s\S]*?<\/think>\s*/gi, "").trimStart();
}

function normalizeModel(requested) {
  const raw = typeof requested === "string" ? requested.trim() : "";
  if (supportedModels.includes(raw)) return raw;
  const lower = raw.toLowerCase();
  const fuzzy = supportedModels.find((model) => lower.includes(model.toLowerCase()));
  return fuzzy || defaultModel || supportedModels[0] || raw || "model";
}

function sanitizeToolName(value) {
  const clean = String(value || "tool").replace(/[^A-Za-z0-9_]/g, "_").replace(/_+/g, "_");
  return clean.replace(/^([^A-Za-z_])/, "_$1").slice(0, 64) || "tool";
}

function flatToolName(namespace, name) {
  if (!namespace) return sanitizeToolName(name);
  return sanitizeToolName(`${namespace}__${name || "tool"}`);
}

function responsesInputToMessages(input) {
  const source = typeof input === "string"
    ? [{ type: "message", role: "user", content: [{ type: "input_text", text: input }] }]
    : Array.isArray(input) ? input : [];
  const messages = [];

  for (const item of source) {
    if (!item || typeof item !== "object") continue;

    if (item.type === "message") {
      let role = item.role || "user";
      if (role === "developer") role = "system";
      if (!["system", "user", "assistant", "tool"].includes(role)) role = "user";
      const content = responseText(item.content);
      if (content || role !== "assistant") messages.push({ role, content });
      continue;
    }

    if (item.type === "function_call") {
      messages.push({
        role: "assistant",
        content: "",
        tool_calls: [{
          id: item.call_id || item.id || makeId("call"),
          type: "function",
          function: {
            name: flatToolName(item.namespace, item.name),
            arguments: typeof item.arguments === "string"
              ? item.arguments
              : JSON.stringify(item.arguments ?? {}),
          },
        }],
      });
      continue;
    }

    if (item.type === "function_call_output") {
      messages.push({
        role: "tool",
        tool_call_id: item.call_id || item.id || makeId("call"),
        content: responseText(item.output),
      });
      continue;
    }

    if (item.type === "custom_tool_call_output") {
      messages.push({ role: "user", content: `Tool output:\n${responseText(item.output)}` });
    }
  }

  return messages.length ? messages : [{ role: "user", content: "" }];
}

function makeChatTool(tool, name, descriptionPrefix = "") {
  return {
    type: "function",
    function: {
      name,
      description: `${descriptionPrefix}${tool.description || ""}`.trim(),
      parameters: tool.parameters || tool.input_schema || {
        type: "object",
        properties: {},
        additionalProperties: true,
      },
    },
  };
}

function responsesToolsToChatTools(tools) {
  if (!Array.isArray(tools)) return { tools: undefined, namespaceMap: new Map() };

  const converted = [];
  const namespaceMap = new Map();
  const simpleCounts = new Map();

  for (const tool of tools) {
    if (!tool || typeof tool !== "object") continue;

    if (tool.type === "function" && tool.name) {
      const name = sanitizeToolName(tool.name);
      converted.push(makeChatTool(tool, name));
      namespaceMap.set(name, { name: tool.name });
      continue;
    }

    if (tool.type === "namespace" && tool.name && Array.isArray(tool.tools)) {
      const namespace = String(tool.name);
      const prefix = tool.description ? `${tool.description}\n` : "";
      for (const nested of tool.tools) {
        if (!nested || nested.type !== "function" || !nested.name) continue;
        const flat = flatToolName(namespace, nested.name);
        converted.push(makeChatTool(nested, flat, prefix));
        namespaceMap.set(flat, { namespace, name: nested.name });
        simpleCounts.set(nested.name, (simpleCounts.get(nested.name) || 0) + 1);
      }
    }
  }

  for (const tool of tools) {
    if (!tool || tool.type !== "namespace" || !tool.name || !Array.isArray(tool.tools)) continue;
    for (const nested of tool.tools) {
      if (!nested || nested.type !== "function" || !nested.name) continue;
      if (simpleCounts.get(nested.name) === 1) {
        namespaceMap.set(sanitizeToolName(nested.name), { namespace: String(tool.name), name: nested.name });
      }
    }
  }

  return { tools: converted.length ? converted : undefined, namespaceMap };
}

function toolChoiceToChat(choice, namespaceMap) {
  if (!choice || choice === "auto" || choice === "none" || choice === "required") return choice;
  if (typeof choice === "object" && choice.type === "function" && choice.name) {
    const name = choice.namespace ? flatToolName(choice.namespace, choice.name) : sanitizeToolName(choice.name);
    const mapped = namespaceMap.has(name) ? name : sanitizeToolName(choice.name);
    return { type: "function", function: { name: mapped } };
  }
  return undefined;
}

function clampMaxTokens(value) {
  const numeric = Number(value);
  if (!Number.isFinite(numeric) || numeric <= 0) return 2048;
  return Math.max(1, Math.min(8192, Math.floor(numeric)));
}

function normalizeTemperature(value) {
  if (value == null) return undefined;
  const numeric = Number(value);
  if (!Number.isFinite(numeric)) return undefined;
  return Math.min(2, Math.max(0, numeric));
}

function buildChatRequest(body) {
  const messages = responsesInputToMessages(body.input);
  if (body.instructions) messages.unshift({ role: "system", content: String(body.instructions) });

  const chat = {
    model: normalizeModel(body.model),
    messages,
    stream: false,
  };

  chat[maxTokensField] = clampMaxTokens(body.max_output_tokens || body.max_completion_tokens || body.max_tokens);

  const { tools, namespaceMap } = responsesToolsToChatTools(body.tools);
  if (tools) {
    chat.tools = tools;
    const toolChoice = toolChoiceToChat(body.tool_choice, namespaceMap);
    if (toolChoice) chat.tool_choice = toolChoice;
  }

  const temp = normalizeTemperature(body.temperature);
  if (temp != null) chat.temperature = temp;
  if (body.top_p != null) chat.top_p = Math.min(1, Math.max(0, Number(body.top_p)));

  return { chat, namespaceMap };
}

function extraHeaders() {
  if (!process.env.CUSTOM_CODEX_UPSTREAM_HEADERS_JSON) return {};
  try {
    const parsed = JSON.parse(process.env.CUSTOM_CODEX_UPSTREAM_HEADERS_JSON);
    return parsed && typeof parsed === "object" && !Array.isArray(parsed) ? parsed : {};
  } catch {
    return {};
  }
}

async function callUpstream(chatRequest) {
  const response = await fetch(`${apiBase}/chat/completions`, {
    method: "POST",
    headers: {
      authorization: `Bearer ${apiKey}`,
      "content-type": "application/json",
      accept: "application/json",
      ...extraHeaders(),
    },
    body: JSON.stringify(chatRequest),
  });

  const text = await response.text();
  let parsed;
  try {
    parsed = text ? JSON.parse(text) : {};
  } catch {
    parsed = { raw: text };
  }

  if (!response.ok) {
    const error = new Error(parsed?.error?.message || parsed?.base_resp?.status_msg || text || response.statusText);
    error.status = response.status;
    error.payload = parsed;
    throw error;
  }

  return parsed;
}

function usageFromChat(usage) {
  if (!usage) return null;
  const inputTokens = usage.prompt_tokens ?? usage.input_tokens ?? 0;
  const outputTokens = usage.completion_tokens ?? usage.output_tokens ?? 0;
  return {
    input_tokens: inputTokens,
    output_tokens: outputTokens,
    total_tokens: usage.total_tokens ?? inputTokens + outputTokens,
    input_tokens_details: { cached_tokens: usage.cached_tokens ?? 0 },
    output_tokens_details: {
      reasoning_tokens: usage.completion_tokens_details?.reasoning_tokens ?? 0,
    },
  };
}

function baseResponse(responseId, model, status = "in_progress", output = [], usage = null) {
  return {
    id: responseId,
    object: "response",
    created_at: Math.floor(Date.now() / 1000),
    status,
    background: false,
    error: null,
    incomplete_details: null,
    instructions: null,
    max_output_tokens: null,
    model,
    output,
    parallel_tool_calls: true,
    previous_response_id: null,
    reasoning: null,
    store: false,
    temperature: null,
    text: { format: { type: "text" } },
    tool_choice: "auto",
    tools: [],
    top_p: null,
    truncation: "disabled",
    usage,
  };
}

function messageOutput(text) {
  const clean = stripThinkBlocks(text);
  return {
    id: makeId("msg"),
    type: "message",
    status: "completed",
    role: "assistant",
    content: [{ type: "output_text", text: clean, annotations: [] }],
  };
}

function toolCallOutput(toolCall, namespaceMap) {
  const rawName = toolCall.function?.name || "unknown_tool";
  const mapped = namespaceMap.get(rawName) || namespaceMap.get(sanitizeToolName(rawName)) || {};
  const args = typeof toolCall.function?.arguments === "string"
    ? toolCall.function.arguments
    : JSON.stringify(toolCall.function?.arguments ?? {});
  return {
    id: makeId("fc"),
    type: "function_call",
    status: "completed",
    call_id: toolCall.id || makeId("call"),
    ...(mapped.namespace ? { namespace: mapped.namespace } : {}),
    name: mapped.name || rawName,
    arguments: args,
  };
}

function outputsFromChat(chatResponse, namespaceMap) {
  const message = chatResponse.choices?.[0]?.message || {};
  const toolCalls = Array.isArray(message.tool_calls) ? message.tool_calls : [];
  if (toolCalls.length) return toolCalls.map((call) => toolCallOutput(call, namespaceMap));
  return [messageOutput(message.content || "")];
}

function sseHeaders(res) {
  res.writeHead(200, {
    "content-type": "text/event-stream; charset=utf-8",
    "cache-control": "no-cache, no-transform",
    connection: "keep-alive",
    "x-accel-buffering": "no",
  });
}

function sse(res, event, payload) {
  res.write(`event: ${event}\n`);
  res.write(`data: ${JSON.stringify({ type: event, ...payload })}\n\n`);
}

function emitSseResponse(res, responseId, model, outputs, usage) {
  sse(res, "response.created", { response: baseResponse(responseId, model) });
  outputs.forEach((item, outputIndex) => {
    const inProgress = { ...item, status: "in_progress" };
    sse(res, "response.output_item.added", { output_index: outputIndex, item: inProgress });

    if (item.type === "message") {
      const part = item.content[0] || { type: "output_text", text: "", annotations: [] };
      sse(res, "response.content_part.added", {
        item_id: item.id,
        output_index: outputIndex,
        content_index: 0,
        part: { ...part, text: "" },
      });
      const text = part.text || "";
      for (let i = 0; i < text.length; i += 120) {
        sse(res, "response.output_text.delta", {
          item_id: item.id,
          output_index: outputIndex,
          content_index: 0,
          delta: text.slice(i, i + 120),
        });
      }
      sse(res, "response.output_text.done", {
        item_id: item.id,
        output_index: outputIndex,
        content_index: 0,
        text,
      });
      sse(res, "response.content_part.done", {
        item_id: item.id,
        output_index: outputIndex,
        content_index: 0,
        part,
      });
    }

    if (item.type === "function_call") {
      if (item.arguments) {
        sse(res, "response.function_call_arguments.delta", {
          item_id: item.id,
          output_index: outputIndex,
          delta: item.arguments,
        });
      }
      sse(res, "response.function_call_arguments.done", {
        item_id: item.id,
        output_index: outputIndex,
        arguments: item.arguments || "{}",
      });
    }

    sse(res, "response.output_item.done", { output_index: outputIndex, item });
  });
  sse(res, "response.completed", { response: baseResponse(responseId, model, "completed", outputs, usage) });
  res.write("data: [DONE]\n\n");
  res.end();
}

function emitSseError(res, responseId, model, error) {
  sse(res, "response.failed", {
    response: {
      ...baseResponse(responseId, model, "failed"),
      error: {
        code: String(error?.status || "bridge_error"),
        message: error?.message || "bridge error",
      },
    },
  });
  res.end();
}

async function handleResponses(req, res) {
  const responseId = makeId("resp");
  let body;
  try {
    body = JSON.parse(await readBody(req) || "{}");
  } catch (error) {
    sendJson(res, 400, { error: { message: error.message, type: "invalid_request_error" } });
    return;
  }

  const model = normalizeModel(body.model);
  const wantsStream = body.stream !== false;
  if (wantsStream) sseHeaders(res);

  try {
    const { chat, namespaceMap } = buildChatRequest(body);
    debug("request", {
      model,
      chat_model: chat.model,
      messages: chat.messages.map((message) => ({
        role: message.role,
        chars: String(message.content || "").length,
        tool_calls: Array.isArray(message.tool_calls) ? message.tool_calls.length : 0,
      })),
      tools: Array.isArray(chat.tools) ? chat.tools.map((tool) => tool.function?.name).filter(Boolean) : [],
    });

    const chatResponse = await callUpstream(chat);
    const usage = usageFromChat(chatResponse.usage);
    const outputs = outputsFromChat(chatResponse, namespaceMap);

    if (wantsStream) {
      emitSseResponse(res, responseId, model, outputs, usage);
    } else {
      sendJson(res, 200, baseResponse(responseId, model, "completed", outputs, usage));
    }
  } catch (error) {
    debug("error", { status: error.status, message: error.message, payload: error.payload });
    if (wantsStream) emitSseError(res, responseId, model, error);
    else sendJson(res, error.status || 500, { error: { message: error.message || "bridge error" } });
  }
}

const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, `http://${req.headers.host || `${host}:${port}`}`);

  if (req.method === "GET" && url.pathname === "/health") {
    sendJson(res, 200, {
      ok: true,
      provider: providerName,
      api_base: apiBase,
      default_model: defaultModel,
      models: supportedModels,
    });
    return;
  }

  if (req.method === "GET" && url.pathname === "/v1/models") {
    sendJson(res, 200, {
      object: "list",
      data: supportedModels.map((model) => ({
        id: model,
        object: "model",
        created: 0,
        owned_by: providerName,
      })),
    });
    return;
  }

  if (req.method === "POST" && url.pathname === "/v1/responses") {
    await handleResponses(req, res);
    return;
  }

  sendJson(res, 404, { error: { message: "not found", type: "not_found" } });
});

server.listen(port, host, () => {
  console.error(`custom Codex Responses bridge listening on http://${host}:${port}`);
});
