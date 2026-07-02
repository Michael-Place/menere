"use strict";

/**
 * Claude-vision plant identifier for the Bacán/Menere `identifyPlant` Cloud Function (P9 Plants).
 *
 * `identifyPlant` sends a single plant photo to Claude (Sonnet 5 — same accuracy-over-cost choice as
 * the Family-Brain document reader) with a forced tool-use schema and returns a plain JS object of
 * identity + care fields (`{ commonName, latinName, confidence, waterIntervalDays, light, careNotes }`).
 * The care numbers/notes are for the plant grown as a HOUSEPLANT unless it's clearly an outdoor plant.
 *
 * Grounding rules (in the system prompt): identify ONLY from what's visible; if it's genuinely not a
 * plant photo, or the plant can't be identified, return `confidence:"low"` with commonName "Unknown"
 * rather than guessing wildly, and never invent a latin name for an unknown.
 *
 * Self-contained: exports `identifyPlant`. Uses the official Anthropic SDK (Node/CommonJS).
 */

const Anthropic = require("@anthropic-ai/sdk");

const MODEL = "claude-sonnet-5"; // user-chosen for identification accuracy; do NOT downgrade

const CONFIDENCE_VALUES = ["high", "medium", "low"];

const PLANT_TOOL = {
  name: "record_plant",
  description: "Record the identification and basic care of a plant seen in a photo.",
  input_schema: {
    type: "object",
    additionalProperties: false,
    properties: {
      commonName: {
        type: "string",
        description: "The plant's common name (e.g. 'Monstera' / 'Swiss cheese plant'). Use 'Unknown' if it can't be identified or the photo isn't a plant.",
      },
      latinName: {
        anyOf: [{ type: "string" }, { type: "null" }],
        description: "The botanical/latin name (e.g. 'Monstera deliciosa'). MUST be null when commonName is 'Unknown' — never invent one.",
      },
      confidence: {
        type: "string",
        enum: CONFIDENCE_VALUES,
        description: "How sure you are of the identification. Use 'low' whenever the photo isn't clearly a plant or you can't identify it.",
      },
      waterIntervalDays: {
        type: "integer",
        description: "How often to water, in days, sensible for this species grown as a HOUSEPLANT (unless it's clearly an outdoor plant). E.g. 7 for a Monstera.",
      },
      light: {
        type: "string",
        description: "A short light-needs phrase, e.g. 'Bright indirect' or 'Full sun'.",
      },
      careNotes: {
        type: "string",
        description: "1-2 short, practical, warm-but-factual sentences of care advice. No marketing, no speculation.",
      },
    },
    required: ["commonName", "latinName", "confidence", "waterIntervalDays", "light", "careNotes"],
  },
};

const SYSTEM_PROMPT = `You identify a houseplant (or garden plant) from a single photo for a private family plant tracker.

Rules:
- Identify ONLY from what is visible in the photo. Do not guess wildly from thin evidence.
- If the image is genuinely NOT a plant, or you cannot identify the plant, return commonName "Unknown", latinName null, and confidence "low". Never invent a latin name for an unknown plant.
- \`waterIntervalDays\`, \`light\`, and \`careNotes\` describe the plant grown as a HOUSEPLANT unless it is clearly an outdoor plant. Give sensible, species-appropriate numbers.
- \`light\`: a short phrase like "Bright indirect".
- \`careNotes\`: 1-2 short, practical, warm-but-factual sentences. No marketing, no fluff.
- \`confidence\`: "high" only when the plant is clearly recognizable; "medium" when it's a reasonable identification; "low" when unsure or not a plant.`;

/**
 * Identify a plant from a base64 image. Returns the normalized tool input, or throws.
 * @returns {Promise<{commonName,latinName,confidence,waterIntervalDays,light,careNotes}>}
 */
async function identifyPlant({ imageBase64, mediaType, apiKey }) {
  const client = new Anthropic({ apiKey });
  const response = await client.messages.create({
    model: MODEL,
    max_tokens: 1024,
    thinking: { type: "disabled" }, // deterministic single-shot identify with a forced tool
    system: SYSTEM_PROMPT,
    tools: [PLANT_TOOL],
    tool_choice: { type: "tool", name: PLANT_TOOL.name },
    messages: [
      {
        role: "user",
        content: [
          { type: "image", source: { type: "base64", media_type: mediaType || "image/jpeg", data: imageBase64 } },
          { type: "text", text: "Identify the plant in this photo." },
        ],
      },
    ],
  });

  let out = null;
  for (const block of response.content) {
    if (block.type === "tool_use" && block.name === PLANT_TOOL.name) {
      out = block.input || {};
      break;
    }
  }
  if (!out) throw new Error("Claude returned no record_plant tool call");

  // Normalize into a safe, predictable shape for the client.
  const commonName = String(out.commonName || "").trim() || "Unknown";
  const isUnknown = commonName.toLowerCase() === "unknown";
  const confidence = CONFIDENCE_VALUES.includes(out.confidence) ? out.confidence : "low";
  const latinRaw = typeof out.latinName === "string" ? out.latinName.trim() : "";
  const result = {
    commonName,
    // Never surface an invented latin name for an unknown plant.
    latinName: isUnknown || !latinRaw ? null : latinRaw,
    confidence,
    waterIntervalDays:
      Number.isFinite(out.waterIntervalDays) ? Math.round(out.waterIntervalDays) : null,
    light: String(out.light || "").trim(),
    careNotes: String(out.careNotes || "").trim(),
  };

  console.log(`[plants] identified ${result.commonName} confidence=${result.confidence}`);
  return result;
}

module.exports = { identifyPlant };
