"use strict";

/**
 * Claude-vision wine-label reader for the Menere `identifyLabel` Cloud Function.
 *
 * `identifyWineLabel` sends a single bottle-label photo to Claude with a structured
 * output schema (`IDENTITY_SCHEMA`) and returns a plain JS object of *label-grounded*
 * identity fields. The prompt is deliberately constrained to what is visibly printed
 * on the label — no world-knowledge fill (that is a later milestone).
 *
 * Self-contained: exports `identifyWineLabel` and `IDENTITY_SCHEMA`. Uses the official
 * Anthropic SDK (Node/CommonJS).
 */

const Anthropic = require("@anthropic-ai/sdk");

const IDENTITY_SCHEMA = {
  type: "object",
  additionalProperties: false,
  properties: {
    producer:  { anyOf: [{ type: "string" }, { type: "null" }] },
    name:      { anyOf: [{ type: "string" }, { type: "null" }] },   // cuvée / bottling name
    vintage:   { anyOf: [{ type: "integer" }, { type: "null" }] },  // 4-digit year printed on the label, else null
    region: {
      anyOf: [
        { type: "null" },
        {
          type: "object",
          additionalProperties: false,
          properties: {
            country:    { anyOf: [{ type: "string" }, { type: "null" }] },
            region:     { anyOf: [{ type: "string" }, { type: "null" }] },
            subregion:  { anyOf: [{ type: "string" }, { type: "null" }] },
            appellation:{ anyOf: [{ type: "string" }, { type: "null" }] },
          },
          required: ["country", "region", "subregion", "appellation"],
        },
      ],
    },
    grapes: { type: "array", items: { type: "string" } },           // only if printed on the label
    type:   { type: "string", enum: ["red","white","rose","sparkling","dessert","fortified","other","unknown"] },
    confidence: { type: "number" },                                 // 0..1, legibility-based confidence
  },
  required: ["producer","name","vintage","region","grapes","type","confidence"],
};

const PROMPT =
  "You are reading a photo of a wine bottle label. Extract ONLY information that is " +
  "visibly printed on the label in this image. Do NOT use outside/world knowledge to " +
  "infer or complete fields — if a field is not legible or not printed on the label, " +
  "return null (or [] for grapes). Specifically: `producer` = the winery/brand as " +
  "printed; `name` = the cuvée or bottling name if distinct from the producer, else " +
  "null; `vintage` = the 4-digit year printed on the label, else null; `region` = only " +
  "sub-fields actually printed (e.g. an appellation like 'Barolo' or a country); " +
  "`grapes` = grape varieties only if printed on the label; `type` = the wine style only " +
  "if stated or unambiguous from the label, else 'unknown'; `confidence` = 0..1 reflecting " +
  "how legible/certain the label text is. Return only the structured fields.";

async function identifyWineLabel({ imageBase64, mimeType, apiKey }) {
  const client = new Anthropic({ apiKey });
  const response = await client.messages.create({
    model: "claude-opus-4-8",            // chosen by the user; do NOT change the model id
    max_tokens: 1024,
    output_config: { format: { type: "json_schema", schema: IDENTITY_SCHEMA } },
    messages: [
      {
        role: "user",
        content: [
          { type: "image", source: { type: "base64", media_type: mimeType || "image/jpeg", data: imageBase64 } },
          { type: "text", text: PROMPT },
        ],
      },
    ],
  });
  const textBlock = response.content.find((b) => b.type === "text");
  if (!textBlock) throw new Error("No text block in Claude response");
  return JSON.parse(textBlock.text);   // output_config.format guarantees valid JSON matching the schema
}

module.exports = { identifyWineLabel, IDENTITY_SCHEMA };
