"use strict";

/**
 * AI monthly spending summary for the Menere/Bacán `summarizeSpending` Cloud Function (P22 — Spending
 * intelligence). Given the featured month's already-categorised line items ({category, vendor,
 * amount, date}) — computed client-side by the SpendingInsights aggregator — it asks Claude
 * (Sonnet 5, forced tool-use) for a short, warm, NON-JUDGMENTAL "here's where the money went" note.
 *
 * Output: { summary: string (2-3 warm family-voice sentences), insight: string (one useful pattern
 * or gentle nudge) }. NO family finance logic lives here beyond forwarding a single model call — the
 * aggregation, dedup, and one-time bucketing all happen on the phone. Auth-required (checked in
 * index.js); logs only counts (never vendor names or amounts). Reuses the existing ANTHROPIC_API_KEY.
 * No rate limiting (private app).
 */

const Anthropic = require("@anthropic-ai/sdk");

const MODEL = "claude-sonnet-5"; // matches the app's other reasoning calls; do NOT downgrade

const SUMMARY_TOOL = {
  name: "write_spending_summary",
  description: "Write a warm, non-judgmental monthly spending note for the family.",
  input_schema: {
    type: "object",
    properties: {
      summary: {
        type: "string",
        description:
          "2-3 warm, plain sentences on where the money went this month. Family voice, first names, sentence case, at most one exclamation point.",
      },
      insight: {
        type: "string",
        description:
          "ONE useful, non-judgmental observation or gentle nudge (a pattern, a category that stood out, a recurring charge). Never shaming.",
      },
    },
    required: ["summary", "insight"],
  },
};

const SYSTEM_PROMPT = `You are a warm, non-judgmental family finance helper for the Place family's private app, "Bacán".

The family: Michael, Valentina ("Vale"), Oliver (3), and baby Francis — called "Famfis" (his own pronunciation). Dogs Fajita & Sprinkle.

Your job: given ONE month's categorized spending line items, write a short, friendly recap of where the money went, plus one useful observation.

Voice & rules:
- Warm and a little witty; first names; sentence case; at most one exclamation point total.
- summary: 2-3 sentences MAX. Name the biggest category or two and roughly how much, in plain language.
- insight: ONE genuinely useful, NON-JUDGMENTAL note — a pattern, a standout category, a recurring vendor, or a gentle heads-up. NEVER shame, scold, or moralize about spending. No "you should cut back" energy.
- Only mention what's in the data. NEVER invent vendors, amounts, or categories.
- Round to whole dollars in prose; don't recite every line item.
- Sparse data (one item, or nothing) is fine — give a light, genuine one-liner rather than manufacturing analysis. If there's truly no spend, say so warmly.
- No corporate finance-speak, no emoji, no shame mechanics.`;

/** Coerce a client-sent line item into a compact, safe shape for the prompt. */
function normalizeLine(raw) {
  if (!raw || typeof raw !== "object") return null;
  const amount = Number(raw.amount);
  if (!Number.isFinite(amount)) return null;
  const category = typeof raw.category === "string" ? raw.category.slice(0, 40) : "other";
  const vendor = typeof raw.vendor === "string" && raw.vendor.trim() ? raw.vendor.trim().slice(0, 80) : null;
  const date = typeof raw.date === "string" ? raw.date.slice(0, 10) : null;
  return { category, vendor, amount: Math.round(amount * 100) / 100, date };
}

/** Ask Claude for the structured summary. Returns { summary, insight } or null. */
async function callClaude(apiKey, month, lines, currency) {
  const client = new Anthropic({ apiKey });
  const total = lines.reduce((s, l) => s + l.amount, 0);
  const payload = JSON.stringify(
    { month, currency: currency || "USD", total: Math.round(total * 100) / 100, lineItems: lines },
    null,
    2
  );

  const response = await client.messages.create({
    model: MODEL,
    max_tokens: 1024,
    system: SYSTEM_PROMPT,
    tools: [SUMMARY_TOOL],
    tool_choice: { type: "tool", name: "write_spending_summary" },
    messages: [
      {
        role: "user",
        content: `Here is ${month}'s categorized spending. Write the recap.\n\n${payload}`,
      },
    ],
  });

  for (const block of response.content) {
    if (block.type === "tool_use" && block.name === "write_spending_summary") {
      const out = block.input || {};
      const summary = typeof out.summary === "string" ? out.summary.trim() : "";
      const insight = typeof out.insight === "string" ? out.insight.trim() : "";
      if (!summary) return null;
      return { summary, insight };
    }
  }
  return null;
}

/**
 * Summarize a month's spending.
 * @param {{ apiKey: string, month?: string, currency?: string, lines?: any[] }} params
 * @returns {Promise<{ summary: string, insight: string }>}
 */
async function summarizeSpending({ apiKey, month, currency, lines }) {
  const monthLabel = typeof month === "string" && month.trim() ? month.trim() : "this month";
  const clean = (Array.isArray(lines) ? lines : []).map(normalizeLine).filter(Boolean);
  console.log(`[spending] summarize month=${monthLabel} lines=${clean.length}`);

  if (clean.length === 0) {
    return {
      summary: `Nice and quiet on the money front for ${monthLabel} — nothing logged yet.`,
      insight: "When receipts land in the Family Brain, they'll show up here automatically.",
    };
  }

  const result = await callClaude(apiKey, monthLabel, clean, currency);
  if (!result) throw new Error("Claude returned no summary");
  return result;
}

module.exports = { summarizeSpending };
