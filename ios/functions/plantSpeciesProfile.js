"use strict";

/**
 * Claude species-profile lookup for the Bacán/Menere `plantSpeciesProfile` Cloud Function (P19-C4).
 *
 * Given a plant's species / common name (NO photo — this is a knowledge lookup, not a vision call),
 * it asks Claude (Sonnet 5 — same accuracy-over-cost choice as identify/troubleshoot) with a forced
 * tool-use schema and returns a rich houseplant SPECIES PROFILE:
 *   { lightNeed, humidity, fertilizer, idealTemp, commonProblems:[..],
 *     petToxicity:{ isToxicToPets, toxicToDogs, toxicToCats, severity, note } }
 *
 * The headline is **pet-toxicity**: the Place family has two dogs (Fajita, Sprinkle) and a cat
 * (Fireball) roaming among 32 plants, so "is this safe if a dog chews it?" is a real question. The
 * system prompt grounds toxicity in reliable ASPCA-style horticultural knowledge, names WHO it's toxic
 * to + severity + a short plain-language note, says so clearly when a plant is genuinely pet-safe, and
 * errs toward caution (verify) when unsure rather than guessing.
 *
 * Self-contained: exports `speciesProfile`. Uses the official Anthropic SDK (Node/CommonJS).
 */

const Anthropic = require("@anthropic-ai/sdk");

const MODEL = "claude-sonnet-5"; // user-chosen for accuracy; do NOT downgrade

const PROFILE_TOOL = {
  name: "record_species_profile",
  description:
    "Record a houseplant's care profile and, most importantly, whether it's toxic to pets (dogs/cats).",
  input_schema: {
    type: "object",
    additionalProperties: false,
    properties: {
      lightNeed: {
        type: "string",
        description:
          "Light needs as a short specific phrase, e.g. 'Bright, indirect light; tolerates medium.'",
      },
      humidity: {
        type: "string",
        description:
          "Humidity preference, short and specific, e.g. 'Loves high humidity — mist or group with others.'",
      },
      fertilizer: {
        type: "string",
        description:
          "Fertilizer cadence, e.g. 'Feed monthly with a balanced fertilizer in spring/summer; none in winter.'",
      },
      idealTemp: {
        type: "string",
        description: "Ideal temperature range, e.g. '65–80°F (18–27°C); keep above 55°F.'",
      },
      commonProblems: {
        type: "array",
        items: { type: "string" },
        description:
          "2-4 common problems to watch for as short phrases, e.g. 'Brown leaf tips from dry air', 'Root rot if overwatered', 'Spider mites in dry warmth'.",
      },
      petToxicity: {
        type: "object",
        additionalProperties: false,
        properties: {
          isToxicToPets: {
            type: "boolean",
            description: "True if this plant is toxic to dogs OR cats if chewed/ingested.",
          },
          toxicToDogs: { type: "boolean", description: "True if toxic to dogs." },
          toxicToCats: { type: "boolean", description: "True if toxic to cats." },
          severity: {
            anyOf: [{ type: "string" }, { type: "null" }],
            description:
              "Severity when toxic: 'mild', 'moderate', or 'severe'. Null when genuinely pet-safe or unknown.",
          },
          note: {
            type: "string",
            description:
              "One short, plain-language sentence. If toxic: say to whom + what happens ('Mildly toxic to dogs and cats — can cause drooling and vomiting if chewed'). If genuinely safe: say so clearly ('Pet-safe — non-toxic to dogs and cats'). If unsure: say to verify with your vet/ASPCA.",
          },
        },
        required: ["isToxicToPets", "toxicToDogs", "toxicToCats", "severity", "note"],
      },
    },
    required: ["lightNeed", "humidity", "fertilizer", "idealTemp", "commonProblems", "petToxicity"],
  },
};

const SYSTEM_PROMPT = `You are an expert houseplant reference AND a pet-safety authority for the Place family's private plant app (Bacán). The family has TWO DOGS (Fajita, Sprinkle) and a CAT (Fireball) that roam among their plants, so pet-toxicity is the most important field you fill.

Given a plant's species / common name, return an accurate, specific care profile grown as a HOUSEPLANT.

Rules:
- Be accurate and SPECIFIC to the named species — not generic filler. Short, warm, practical phrases.
- PET TOXICITY is the headline. Use reliable horticultural / ASPCA-style knowledge:
  • If the plant is toxic, set isToxicToPets true, set toxicToDogs / toxicToCats correctly, give a severity ('mild'/'moderate'/'severe'), and a short plain-language note naming WHO it's toxic to and what happens ("Toxic to dogs and cats — the calcium-oxalate crystals cause mouth pain, drooling and vomiting if chewed").
  • If the plant is genuinely PET-SAFE (non-toxic to dogs and cats), say so clearly: isToxicToPets false, both false, severity null, note like "Pet-safe — non-toxic to dogs and cats."
  • NEVER guess wildly. If you are genuinely unsure about toxicity, err toward CAUTION: treat it as potentially unsafe and say to verify with a vet or the ASPCA list.
- commonProblems: 2-4 real, species-appropriate issues.
- Keep every field concise; this is a glanceable card, not an essay.`;

/**
 * Fetch a species profile for a plant. Returns the normalized tool input, or throws.
 * @param {object} args
 * @param {string} [args.species]    - Botanical / typed species name.
 * @param {string} [args.commonName] - Common name (either species or commonName must be present).
 * @param {string} args.apiKey
 * @returns {Promise<{lightNeed,humidity,fertilizer,idealTemp,commonProblems,petToxicity}>}
 */
async function speciesProfile({ species, commonName, apiKey }) {
  const name = String(commonName || species || "").trim();
  if (!name) throw new Error("species or commonName is required");

  const client = new Anthropic({ apiKey });

  const lines = [`Plant: ${name}`];
  if (species && commonName && species.trim() && species.trim() !== commonName.trim()) {
    lines.push(`(botanical: ${species.trim()})`);
  }
  const userText = `${lines.join("\n")}\n\nGive the care profile and pet-toxicity for this houseplant.`;

  const response = await client.messages.create({
    model: MODEL,
    max_tokens: 1024,
    thinking: { type: "disabled" }, // single-shot forced tool
    system: SYSTEM_PROMPT,
    tools: [PROFILE_TOOL],
    tool_choice: { type: "tool", name: PROFILE_TOOL.name },
    messages: [{ role: "user", content: [{ type: "text", text: userText }] }],
  });

  let out = null;
  for (const block of response.content) {
    if (block.type === "tool_use" && block.name === PROFILE_TOOL.name) {
      out = block.input || {};
      break;
    }
  }
  if (!out) throw new Error("Claude returned no record_species_profile tool call");

  // Normalize into a safe, predictable shape for the client.
  const str = (v) => (typeof v === "string" && v.trim() ? v.trim() : null);
  const commonProblems = Array.isArray(out.commonProblems)
    ? out.commonProblems.map((p) => String(p || "").trim()).filter(Boolean)
    : [];

  const t = out.petToxicity || {};
  const toxicToDogs = !!t.toxicToDogs;
  const toxicToCats = !!t.toxicToCats;
  // Trust the flags: if either species is flagged, it's toxic to pets (belt-and-suspenders).
  const isToxicToPets = !!t.isToxicToPets || toxicToDogs || toxicToCats;
  const petToxicity = {
    isToxicToPets,
    toxicToDogs,
    toxicToCats,
    severity: str(t.severity),
    note: str(t.note),
  };

  const result = {
    lightNeed: str(out.lightNeed),
    humidity: str(out.humidity),
    fertilizer: str(out.fertilizer),
    idealTemp: str(out.idealTemp),
    commonProblems,
    petToxicity,
  };

  console.log(
    `[plants] species profile ${name} → toxicToPets=${isToxicToPets} dogs=${toxicToDogs} cats=${toxicToCats}`
  );
  return result;
}

module.exports = { speciesProfile };
