"use strict";

/**
 * AI **month recap** for the Menere/Bacán `memoryMonthSummary` Cloud Function (P28-C3 — Journal
 * deepening). Given ONE month's Family-Journal memories (already stripped to plain text on the
 * phone), it asks Claude (Sonnet 5, forced tool-use) to weave the month's little moments into a
 * short, warm family-scrapbook narration.
 *
 * Output: { recap: string (2-4 warm, family-voice sentences) }. NO journal logic lives here beyond
 * forwarding a single model call — the timeline grouping + markdown-stripping happen on the phone.
 * Auth-required (checked in index.js); logs only counts (never memory text). Reuses the existing
 * ANTHROPIC_API_KEY. No rate limiting (private app).
 */

const Anthropic = require("@anthropic-ai/sdk");

const MODEL = "claude-sonnet-5"; // matches the app's other reasoning calls; do NOT downgrade

const RECAP_TOOL = {
  name: "write_month_recap",
  description: "Write a warm family-scrapbook recap that weaves the month's memories into a little story.",
  input_schema: {
    type: "object",
    properties: {
      recap: {
        type: "string",
        description:
          "2-4 warm, plain sentences narrating the month's moments as one little story. Family voice, first names, sentence case, at most one exclamation point. Only what's in the memories — never invented.",
      },
    },
    required: ["recap"],
  },
};

const SYSTEM_PROMPT = `You are the warm family-scrapbook narrator for the Place family's private app, "Bacán".

The family: Michael, Valentina ("Vale"), Oliver (3), and baby Francis — called "Famfis" (his own pronunciation). Dogs Fajita & Sprinkle.

Your job: given ONE month's journal memories (each with a title, a plain-text story, an optional milestone, the kid(s) it's about, and a date), weave those moments into a short, warm recap of the month — like the caption a parent would write under a scrapbook spread.

Voice & rules:
- Warm and a little witty; first names; sentence case; at most one exclamation point total.
- 2-4 sentences. Tell it as ONE gentle little story of the month, not a bullet list.
- Name the kids when the memories are about them (use "Famfis" for Francis when it fits the warm tone).
- ONLY use what's in the memories. NEVER invent moments, dates, names, or details that aren't there.
- If there's just one memory, give it a warm single-beat line rather than padding.
- No corporate tone, no emoji, no hashtags.`;

/** Coerce a client-sent memory into a compact, safe shape for the prompt. */
function normalizeMemory(raw) {
  if (!raw || typeof raw !== "object") return null;
  const title = typeof raw.title === "string" ? raw.title.trim().slice(0, 200) : "";
  const text = typeof raw.text === "string" ? raw.text.trim().slice(0, 2000) : "";
  const milestone = typeof raw.milestone === "string" ? raw.milestone.trim().slice(0, 80) : "";
  const date = typeof raw.date === "string" ? raw.date.slice(0, 10) : "";
  const kidNames = Array.isArray(raw.kidNames)
    ? raw.kidNames.filter((n) => typeof n === "string" && n.trim()).map((n) => n.trim().slice(0, 60)).slice(0, 10)
    : [];
  if (!title && !text && !milestone) return null; // nothing to narrate
  return { title, text, milestone, kidNames, date };
}

/** Ask Claude for the structured recap. Returns { recap } or null. */
async function callClaude(apiKey, month, memories) {
  const client = new Anthropic({ apiKey });
  const payload = JSON.stringify({ month, memories }, null, 2);

  const response = await client.messages.create({
    model: MODEL,
    max_tokens: 1024,
    system: SYSTEM_PROMPT,
    tools: [RECAP_TOOL],
    tool_choice: { type: "tool", name: "write_month_recap" },
    messages: [
      {
        role: "user",
        content: `Here are the family's memories from ${month}. Write the month recap.\n\n${payload}`,
      },
    ],
  });

  for (const block of response.content) {
    if (block.type === "tool_use" && block.name === "write_month_recap") {
      const out = block.input || {};
      const recap = typeof out.recap === "string" ? out.recap.trim() : "";
      if (!recap) return null;
      return { recap };
    }
  }
  return null;
}

/**
 * Summarize one month of family memories.
 * @param {{ apiKey: string, month?: string, memories?: any[] }} params
 * @returns {Promise<{ recap: string }>}
 */
async function memoryMonthSummary({ apiKey, month, memories }) {
  const monthLabel = typeof month === "string" && month.trim() ? month.trim() : "this month";
  const clean = (Array.isArray(memories) ? memories : []).map(normalizeMemory).filter(Boolean);
  console.log(`[memories] month recap month=${monthLabel} memories=${clean.length}`);

  if (clean.length === 0) {
    return {
      recap: `A quiet page for ${monthLabel} — no moments captured yet. Snap one and this little story will write itself.`,
    };
  }

  const result = await callClaude(apiKey, monthLabel, clean);
  if (!result) throw new Error("Claude returned no recap");
  return result;
}

module.exports = { memoryMonthSummary };
