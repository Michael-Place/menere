"use strict";

/**
 * `agentTurn` — the dumb model proxy for the P14 on-phone agent (Bacán assistant).
 *
 * ARCHITECTURE (decided in P14 planning): the tools live ON THE PHONE — that's the only place
 * Firestore auth, member identity, and the LAN (Hue/Lutron/Sonos/…) coexist — and the CLIENT runs
 * the agentic loop. This function is deliberately dumb: it holds the ANTHROPIC_API_KEY and makes a
 * SINGLE Claude call per invocation. It has NO family logic, reads NO Firestore, and knows nothing
 * about tools beyond forwarding the definitions the client sends.
 *
 * Input  `{ messages, tools, system }` — the Anthropic Messages-API shapes, verbatim, built by the
 *          client's AgentLoop (system prompt + running conversation + the curated tool schemas).
 * Output `{ content, stopReason }` — the raw response content blocks and stop_reason, forwarded
 *          untouched so the client can execute tool_use blocks locally and loop.
 *
 * Auth is required (a signed-in family member). We log ONLY the stop reason and the NAMES of any
 * tools the model asked for — never their arguments (privacy: arguments can contain addresses,
 * amounts, schedules, etc.).
 *
 * Reuses the existing ANTHROPIC_API_KEY secret and the same @anthropic-ai/sdk + Sonnet-5 choice as
 * the other Claude functions (docProcess / plantIdentify).
 */

const Anthropic = require("@anthropic-ai/sdk");

const MODEL = "claude-sonnet-5"; // matches the app's other agentic/vision calls; do NOT downgrade
const MAX_TOKENS = 1500;         // one turn: a little text + a few tool_use blocks

/**
 * Run a single Claude turn on behalf of the on-phone agent loop.
 * @param {{ apiKey: string, system?: string, messages: any[], tools?: any[] }} args
 * @returns {Promise<{ content: any[], stopReason: string|null }>}
 */
async function runAgentTurn({ apiKey, system, messages, tools }) {
  const client = new Anthropic({ apiKey });

  const params = {
    model: MODEL,
    max_tokens: MAX_TOKENS,
    messages: Array.isArray(messages) ? messages : [],
  };
  if (typeof system === "string" && system.trim()) params.system = system;
  if (Array.isArray(tools) && tools.length > 0) params.tools = tools;

  const response = await client.messages.create(params);

  // Names only — never arguments.
  const toolsUsed = (response.content || [])
    .filter((b) => b && b.type === "tool_use" && typeof b.name === "string")
    .map((b) => b.name);
  console.log(`[agent] turn stop=${response.stop_reason} tools_used=${toolsUsed.join(",") || "none"}`);

  return { content: response.content || [], stopReason: response.stop_reason || null };
}

module.exports = { runAgentTurn };
