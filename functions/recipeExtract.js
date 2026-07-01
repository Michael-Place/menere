"use strict";

/**
 * Recipe extraction for the Menere `extractRecipe` Cloud Function.
 *
 * Ported/trimmed from Fambo's recipe.ts. Two paths:
 *   1. JSON-LD fast path — parse schema.org/Recipe from the page (free, instant, no AI).
 *   2. Claude fallback — structured tool-use extraction when no JSON-LD is present.
 *
 * No rate limiting (Menere is a private family app). Returns Menere-shaped recipe fields:
 * { title, servings, ingredients: [{name, quantity, unit}], instructions: [string], sourceURL }.
 */

const Anthropic = require("@anthropic-ai/sdk");

const RECIPE_EXTRACTION_TOOL = {
  name: "extract_recipe",
  description: "Extract a recipe from the provided content.",
  input_schema: {
    type: "object",
    properties: {
      recipe: {
        type: "object",
        properties: {
          title: { type: "string" },
          servings: { type: "number" },
          ingredients: {
            type: "array",
            items: {
              type: "object",
              properties: {
                name: { type: "string" },
                quantity: { type: ["number", "null"] },
                unit: { type: ["string", "null"] },
              },
              required: ["name", "quantity", "unit"],
            },
          },
          instructions: { type: "array", items: { type: "string" } },
        },
        required: ["title", "servings", "ingredients", "instructions"],
      },
    },
    required: ["recipe"],
  },
};

// --- JSON-LD fast path -------------------------------------------------------

function extractFromJsonLD(html) {
  const re = /<script[^>]*type\s*=\s*["']application\/ld\+json["'][^>]*>([\s\S]*?)<\/script>/gi;
  let match;
  while ((match = re.exec(html)) !== null) {
    try {
      const json = JSON.parse(match[1]);
      const recipes = findRecipeInJsonLD(json);
      if (recipes.length > 0) return parseSchemaRecipe(recipes[0]);
    } catch {
      continue;
    }
  }
  return null;
}

function findRecipeInJsonLD(json) {
  if (Array.isArray(json)) return json.flatMap(findRecipeInJsonLD);
  if (json && typeof json === "object") {
    const t = json["@type"];
    if (t === "Recipe" || (Array.isArray(t) && t.includes("Recipe"))) return [json];
    if (json["@graph"]) return findRecipeInJsonLD(json["@graph"]);
  }
  return [];
}

function parseSchemaRecipe(schema) {
  return {
    title: schema.name || "Untitled Recipe",
    servings: parseServings(schema.recipeYield),
    ingredients: (schema.recipeIngredient || []).map(parseIngredientString),
    instructions: parseInstructions(schema.recipeInstructions),
  };
}

function parseServings(y) {
  if (typeof y === "number") return y;
  if (typeof y === "string") {
    const n = parseInt(y, 10);
    return isNaN(n) ? 4 : n;
  }
  if (Array.isArray(y) && y.length > 0) return parseServings(y[0]);
  return 4;
}

function parseIngredientString(text) {
  const m = text.match(
    /^([\d\/\.\s]+)?\s*(cups?|tbsps?|tsps?|tablespoons?|teaspoons?|oz|ounces?|lbs?|pounds?|grams?|g|kg|ml|liters?|L|cloves?|cans?|packages?|pkg|bunche?s?|slices?|pieces?|pinch|dash|sprigs?)?\s*(?:of\s+)?(.+)/i
  );
  if (m) {
    const qtyStr = m[1] && m[1].trim();
    let quantity = null;
    if (qtyStr) {
      if (qtyStr.includes("/")) {
        const p = qtyStr.split("/");
        quantity = parseFloat(p[0]) / parseFloat(p[1]);
      } else {
        quantity = parseFloat(qtyStr);
      }
      if (isNaN(quantity)) quantity = null;
    }
    const name = (m[3] && m[3].trim()) || text.trim();
    return { name, quantity, unit: (m[2] && m[2].trim()) || null };
  }
  return { name: text.trim(), quantity: null, unit: null };
}

function parseInstructions(instructions) {
  if (!instructions) return [];
  if (typeof instructions === "string") {
    return instructions.split(/\n+/).map((s) => s.trim()).filter(Boolean);
  }
  if (Array.isArray(instructions)) {
    return instructions.flatMap((item) => {
      if (typeof item === "string") return [item.trim()];
      if (item.text) return [item.text.trim()];
      if (item["@type"] === "HowToStep" && item.text) return [item.text.trim()];
      if (item["@type"] === "HowToSection" && Array.isArray(item.itemListElement)) {
        return item.itemListElement.map((s) => (typeof s === "string" ? s.trim() : (s.text || "").trim()));
      }
      return [];
    }).filter(Boolean);
  }
  return [];
}

// --- Claude fallback ---------------------------------------------------------

async function callClaudeForRecipeExtraction(apiKey, content) {
  const client = new Anthropic({ apiKey });
  const response = await client.messages.create({
    model: "claude-haiku-4-5-20251001",
    max_tokens: 4096,
    tools: [RECIPE_EXTRACTION_TOOL],
    tool_choice: { type: "tool", name: "extract_recipe" },
    messages: [
      {
        role: "user",
        content: `Extract the recipe from the following content. Parse all ingredients with quantities and units. List all instruction steps.\n\n${content}`,
      },
    ],
  });
  for (const block of response.content) {
    if (block.type === "tool_use" && block.name === "extract_recipe") {
      return block.input.recipe;
    }
  }
  return null;
}

/**
 * Extract a recipe from a URL or raw text. Returns { recipe, source } or throws.
 */
async function extractRecipe({ url, text, apiKey }) {
  let content = text || "";
  if (url) {
    const response = await fetch(url, {
      headers: { "User-Agent": "Mozilla/5.0 (compatible; MenereBot/1.0; recipe-extraction)" },
    });
    content = await response.text();
    const jsonLd = extractFromJsonLD(content);
    if (jsonLd) return { recipe: { ...jsonLd, sourceURL: url }, source: "json-ld" };
  }
  if (!content.trim()) {
    throw new Error("No content to extract from");
  }
  const extracted = await callClaudeForRecipeExtraction(apiKey, content.substring(0, 12000));
  if (!extracted) throw new Error("Could not extract a recipe from the content");
  return { recipe: { ...extracted, sourceURL: url || null }, source: "claude" };
}

module.exports = { extractRecipe };
