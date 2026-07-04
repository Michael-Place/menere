"use strict";

/**
 * Claude weekly-dinner planner for the Bacán/Menere `planMealWeek` Cloud Function (P23-C1 — the
 * "meal rhythm").
 *
 * Given the family's recipe corpus (title + ingredient count + servings) and the 7 days of the week
 * (each tagged weeknight vs weekend), it asks Claude (Sonnet 5) with a forced tool-use schema for a
 * BALANCED week of DINNERS: quicker/simpler recipes on weeknights, the project bakes/roasts on
 * weekends, with variety (no pasta twice, rotate cuisines). It uses ingredient counts + titles to
 * judge effort — it never sees full recipes, and it NEVER invents: it may only pick from the recipe
 * ids provided. Clearly-not-dinner items (cookies, banana bread, lactation cookies) are skipped.
 *
 * Input  `{ recipes: [{id, title, ingredientCount, servings}], days: [{date, weekday,
 *           kind:"weeknight"|"weekend"}] }`
 * Output `{ plan: [{ date, recipeId, reason }] }` — one entry per planned day (a day may be left
 *         out if there aren't enough dinner-worthy recipes). `date` echoes the input day string and
 *         `recipeId` is always one of the provided ids.
 *
 * Self-contained: exports `planMealWeek`. Reuses the existing ANTHROPIC_API_KEY secret.
 */

const Anthropic = require("@anthropic-ai/sdk");

const MODEL = "claude-sonnet-5"; // user-chosen for reasoning quality; do NOT downgrade

const PLAN_TOOL = {
  name: "record_week_plan",
  description:
    "Record a balanced week of family DINNERS, picking from the provided recipes only.",
  input_schema: {
    type: "object",
    additionalProperties: false,
    properties: {
      plan: {
        type: "array",
        description:
          "One entry per day you're assigning a dinner to. Leave a day out entirely if there isn't a good dinner-worthy recipe left — do NOT repeat a recipe to fill a gap and do NOT invent one.",
        items: {
          type: "object",
          additionalProperties: false,
          properties: {
            date: {
              type: "string",
              description: "The day this dinner is for — copy the `date` string exactly from the provided days.",
            },
            recipeId: {
              type: "string",
              description: "The id of the chosen recipe — MUST be one of the provided recipe ids.",
            },
            reason: {
              type: "string",
              description:
                "One short, warm sentence (family voice, first names welcome) on why this recipe fits this day — e.g. quick weeknight, weekend project, or variety.",
            },
          },
          required: ["date", "recipeId", "reason"],
        },
      },
    },
    required: ["plan"],
  },
};

const SYSTEM_PROMPT = `You are the warm, practical family meal-planner for the Place family's private app (Bacán). You plan a week of DINNERS from the family's own recipe collection.

Voice: warm, first-name-family energy, never clinical. Keep each reason to one short sentence.

Rules:
- Plan DINNERS only. SKIP anything that clearly isn't a dinner main — cookies, banana bread, lactation cookies, muffins, cakes, baby-food purees, jams, drinks. Don't put dessert or a bake on a dinner night.
- Match effort to the day. WEEKNIGHT days get quicker, simpler recipes (fewer ingredients). WEEKEND days get the project cooks — roasts, bakes, higher-ingredient dishes. Use the ingredient counts and titles to judge effort; you never see the full recipe.
- VARIETY across the week: no repeats, don't do pasta (or any one cuisine) twice, rotate cuisines and proteins so the week feels varied.
- NEVER invent a recipe. Only pick from the recipe ids provided. Every recipeId you return MUST be one of them, and each recipe at most once.
- Copy each day's \`date\` string EXACTLY from the provided days.
- It's fine to leave a day unplanned if there aren't enough good dinner recipes — a partial week beats a repeat or a bad fit.`;

/**
 * Plan a week of dinners. Returns `{ plan: [{date, recipeId, reason}] }`, filtered to valid
 * (known-id, known-date, no-duplicate) entries, or throws.
 * @param {object} args
 * @param {Array<{id:string,title:string,ingredientCount:number,servings:number}>} args.recipes
 * @param {Array<{date:string,weekday:string,kind:string}>} args.days
 * @param {string} args.apiKey
 * @returns {Promise<{plan: Array<{date:string,recipeId:string,reason:string}>}>}
 */
async function planMealWeek({ recipes, days, apiKey }) {
  const client = new Anthropic({ apiKey });

  const recipeLines = recipes
    .map(
      (r) =>
        `- id:${r.id} | "${r.title}" | ${Number(r.ingredientCount) || 0} ingredients | serves ${Number(r.servings) || 0}`
    )
    .join("\n");
  const dayLines = days
    .map((d) => `- date:${d.date} | ${d.weekday} | ${d.kind}`)
    .join("\n");

  const userText = `Here are our recipes:\n${recipeLines}\n\nPlan dinners for these days (weeknight = quicker, weekend = project):\n${dayLines}\n\nGive us a balanced, varied week of dinners.`;

  const response = await client.messages.create({
    model: MODEL,
    max_tokens: 1536,
    thinking: { type: "disabled" }, // single-shot forced tool
    system: SYSTEM_PROMPT,
    tools: [PLAN_TOOL],
    tool_choice: { type: "tool", name: PLAN_TOOL.name },
    messages: [{ role: "user", content: [{ type: "text", text: userText }] }],
  });

  let out = null;
  for (const block of response.content) {
    if (block.type === "tool_use" && block.name === PLAN_TOOL.name) {
      out = block.input || {};
      break;
    }
  }
  if (!out) throw new Error("Claude returned no record_week_plan tool call");

  // Normalize + validate: only known recipe ids, only known dates, at most one dinner per day,
  // each recipe used at most once. Protects the client from hallucinated ids/dates.
  const validIds = new Set(recipes.map((r) => String(r.id)));
  const validDates = new Set(days.map((d) => String(d.date)));
  const usedDates = new Set();
  const usedRecipes = new Set();
  const plan = [];
  for (const entry of Array.isArray(out.plan) ? out.plan : []) {
    const date = String(entry.date || "").trim();
    const recipeId = String(entry.recipeId || "").trim();
    const reason = String(entry.reason || "").trim();
    if (!validDates.has(date) || !validIds.has(recipeId)) continue;
    if (usedDates.has(date) || usedRecipes.has(recipeId)) continue;
    usedDates.add(date);
    usedRecipes.add(recipeId);
    plan.push({ date, recipeId, reason });
  }

  console.log(
    `[meals] planMealWeek → ${plan.length}/${days.length} days filled from ${recipes.length} recipes`
  );
  return { plan };
}

module.exports = { planMealWeek };
