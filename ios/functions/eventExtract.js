"use strict";

/**
 * Claude event extraction for Menere's email→events intake.
 *
 * `extractEventsFromText` sends free-form text (an email subject + body) to Claude and returns
 * an array of structured events. Ported/trimmed from Fambo's extraction logic. Reuses the
 * existing ANTHROPIC_API_KEY secret.
 */

const Anthropic = require("@anthropic-ai/sdk");

const EVENT_EXTRACTION_TOOL = {
  name: "extract_events",
  description: "Extract calendar events from the provided text.",
  input_schema: {
    type: "object",
    properties: {
      events: {
        type: "array",
        items: {
          type: "object",
          properties: {
            title: { type: "string" },
            startDate: { type: "string", description: "ISO 8601 datetime (with timezone offset if known)" },
            endDate: { type: ["string", "null"], description: "ISO 8601 datetime or null" },
            isAllDay: { type: "boolean" },
            location: { type: ["string", "null"] },
            notes: { type: ["string", "null"] },
          },
          required: ["title", "startDate", "endDate", "isAllDay", "location", "notes"],
        },
      },
    },
    required: ["events"],
  },
};

/**
 * @param {string} apiKey   Anthropic API key
 * @param {string} text     Text to extract events from
 * @param {string} timezone IANA timezone the family lives in (e.g. "America/New_York"). Times in
 *                          the text are interpreted as wall-clock time in this zone, and the model
 *                          emits ISO 8601 WITH the matching UTC offset so absolute instants are right.
 * @returns {Promise<Array>} events, possibly empty
 */
async function extractEventsFromText(apiKey, text, timezone) {
  const tz = timezone || "America/New_York";
  const nowLocal = new Intl.DateTimeFormat("en-US", {
    timeZone: tz,
    dateStyle: "full",
    timeStyle: "long",
  }).format(new Date());

  const client = new Anthropic({ apiKey });
  const response = await client.messages.create({
    model: "claude-haiku-4-5-20251001",
    max_tokens: 2048,
    tools: [EVENT_EXTRACTION_TOOL],
    tool_choice: { type: "tool", name: "extract_events" },
    messages: [
      {
        role: "user",
        content:
          `The family's timezone is ${tz}. The current local date/time there is ${nowLocal}. ` +
          `Interpret all times in the text as local wall-clock time in ${tz}, and resolve relative ` +
          `dates ("this Saturday") against the current local date. Output every startDate/endDate as ` +
          `ISO 8601 WITH the correct UTC offset for ${tz} on that date (accounting for daylight saving, ` +
          `e.g. "2026-07-04T10:00:00-04:00"). If no events are present, return an empty list.\n\n${text}`,
      },
    ],
  });
  for (const block of response.content) {
    if (block.type === "tool_use" && block.name === "extract_events") {
      return Array.isArray(block.input.events) ? block.input.events : [];
    }
  }
  return [];
}

module.exports = { extractEventsFromText };
