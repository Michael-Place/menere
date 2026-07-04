"use strict";

/**
 * Claude-vision plant troubleshooter for the Bacán/Menere `troubleshootPlant` Cloud Function
 * (P19-C3 — the "plant whisperer").
 *
 * Given a plant's identity + its CONTEXT (pot type, soil, indoor/outdoor, light, drafts) + a
 * described problem (and OPTIONALLY a photo of the problem), it asks Claude (Sonnet 5 — the same
 * accuracy-over-cost choice as identify/document reading) with a forced tool-use schema and returns
 * a structured diagnosis + concrete fixes + an OPTIONAL suggested watering-interval change and a care
 * tip. The context is the whole point: "outside in a terracotta pot" should push the diagnosis toward
 * fast-drying, and rot-type problems should suggest a LONGER watering interval.
 *
 * Grounding rules (in the system prompt): warm, expert, family voice; use the species + context; read
 * the photo when given; NEVER invent — if genuinely unsure, say so and suggest what to check. Only
 * return `suggestedWaterIntervalDays` when the problem/context actually implies the cadence should
 * change (rot → longer; fast-drying pot + wilting → shorter); otherwise null.
 *
 * Self-contained: exports `troubleshootPlant`. Uses the official Anthropic SDK (Node/CommonJS).
 */

const Anthropic = require("@anthropic-ai/sdk");

const MODEL = "claude-sonnet-5"; // user-chosen for reasoning quality; do NOT downgrade

const TROUBLESHOOT_TOOL = {
  name: "record_diagnosis",
  description: "Record a warm, practical diagnosis and fix for a family's houseplant problem.",
  input_schema: {
    type: "object",
    additionalProperties: false,
    properties: {
      diagnosis: {
        type: "string",
        description:
          "What's most likely wrong, in 1-2 warm-but-practical sentences. Ground it in the species, the plant's context, and the photo if one was given. If genuinely unsure, say so plainly and suggest what to check.",
      },
      fixes: {
        type: "array",
        items: { type: "string" },
        description:
          "2-5 concrete, do-this-now steps to fix or confirm the problem. Short imperative phrases, no fluff.",
      },
      suggestedWaterIntervalDays: {
        anyOf: [{ type: "integer" }, { type: "null" }],
        description:
          "A NEW watering interval in days, ONLY if the problem or context implies the current cadence should change (e.g. root rot / overwatering → a LONGER interval; a fast-drying pot or wilting-between-waterings → a SHORTER interval). Null when watering cadence isn't the issue.",
      },
      careTip: {
        anyOf: [{ type: "string" }, { type: "null" }],
        description:
          "One short, optional forward-looking care tip to prevent a recurrence. Null if nothing worth adding.",
      },
    },
    required: ["diagnosis", "fixes", "suggestedWaterIntervalDays", "careTip"],
  },
};

const SYSTEM_PROMPT = `You are a warm, expert houseplant helper for the Place family's private plant app (Bacán). A family member describes a problem with one of their plants — sometimes with a photo — and you diagnose it and tell them how to fix it.

Voice: warm, encouraging, and practical, like a knowledgeable friend. First-name-family energy, never clinical or preachy. Keep it tight.

Rules:
- USE the species and the plant's CONTEXT (pot type, soil, indoor/outdoor, light, drafts) — it changes the answer. An outdoor terracotta pot dries out fast; pure potting soil holds moisture; a cold-draft window stresses tropicals.
- If a PHOTO is given, read it and let what you actually see drive the diagnosis.
- NEVER invent. If you genuinely can't tell, say so plainly and suggest what to check (roots, soil moisture, underside of leaves).
- \`fixes\`: 2-5 concrete steps they can do now.
- \`suggestedWaterIntervalDays\`: propose a new watering cadence ONLY when the problem/context implies the current one is wrong — root rot / soggy soil / overwatering → LENGTHEN; a fast-drying pot or wilting between waterings → SHORTEN. Otherwise null. Don't nudge the cadence for problems unrelated to watering (pests, low light, low humidity).
- \`careTip\`: one optional prevention tip, or null.`;

/**
 * Troubleshoot a plant problem. Returns the normalized tool input, or throws.
 * @param {object} args
 * @param {string} [args.species] - Common/species name typed by the user.
 * @param {string} [args.commonName] - AI-identified common name, if any.
 * @param {string} [args.careContext] - The plant's situation (pot/soil/indoor-outdoor/light).
 * @param {number} [args.waterIntervalDays] - The plant's CURRENT watering cadence, for reference.
 * @param {string} args.problem - The described problem (required).
 * @param {string} [args.imageBase64] - Optional base64 photo of the problem.
 * @param {string} [args.mediaType] - Image media type (default image/jpeg).
 * @param {string} args.apiKey
 * @returns {Promise<{diagnosis,fixes,suggestedWaterIntervalDays,careTip}>}
 */
async function troubleshootPlant({
  species,
  commonName,
  careContext,
  waterIntervalDays,
  problem,
  imageBase64,
  mediaType,
  apiKey,
}) {
  const client = new Anthropic({ apiKey });

  // Build a compact context block; omit anything blank so the model isn't fed empty fields.
  const lines = [];
  const name = (commonName || species || "").trim();
  if (name) lines.push(`Plant: ${name}`);
  if (species && commonName && species.trim() && species.trim() !== commonName.trim()) {
    lines.push(`(also called: ${species.trim()})`);
  }
  if (careContext && careContext.trim()) lines.push(`Its situation: ${careContext.trim()}`);
  if (Number.isFinite(waterIntervalDays)) {
    lines.push(`Current watering: every ${Math.round(waterIntervalDays)} days`);
  }
  lines.push(`Problem: ${String(problem || "").trim()}`);
  const contextText = lines.join("\n");

  const content = [];
  if (imageBase64) {
    content.push({
      type: "image",
      source: { type: "base64", media_type: mediaType || "image/jpeg", data: imageBase64 },
    });
  }
  content.push({
    type: "text",
    text: `${contextText}\n\nWhat's likely wrong, and how do we fix it?`,
  });

  const response = await client.messages.create({
    model: MODEL,
    max_tokens: 1024,
    thinking: { type: "disabled" }, // single-shot forced tool
    system: SYSTEM_PROMPT,
    tools: [TROUBLESHOOT_TOOL],
    tool_choice: { type: "tool", name: TROUBLESHOOT_TOOL.name },
    messages: [{ role: "user", content }],
  });

  let out = null;
  for (const block of response.content) {
    if (block.type === "tool_use" && block.name === TROUBLESHOOT_TOOL.name) {
      out = block.input || {};
      break;
    }
  }
  if (!out) throw new Error("Claude returned no record_diagnosis tool call");

  // Normalize into a safe, predictable shape for the client.
  const fixes = Array.isArray(out.fixes)
    ? out.fixes.map((f) => String(f || "").trim()).filter(Boolean)
    : [];
  const suggested = Number.isFinite(out.suggestedWaterIntervalDays)
    ? Math.round(out.suggestedWaterIntervalDays)
    : null;
  const careTip = typeof out.careTip === "string" && out.careTip.trim() ? out.careTip.trim() : null;
  const result = {
    diagnosis: String(out.diagnosis || "").trim(),
    fixes,
    // Guard against a nonsensical or zero/negative cadence.
    suggestedWaterIntervalDays: suggested && suggested > 0 ? suggested : null,
    careTip,
  };

  console.log(
    `[plants] troubleshoot ${name || "plant"} → suggestedWater=${result.suggestedWaterIntervalDays} fixes=${result.fixes.length}`
  );
  return result;
}

module.exports = { troubleshootPlant };
