"use strict";

/**
 * URL ingestion for ¡Bacán!'s `extractURL` Cloud Function (Act V — V5-URL, the "URL front door").
 *
 * Given any pasted/shared link, fetch the page, CLASSIFY it, and return a *routed* result the
 * Smart-Capture sheet can file with one tap:
 *
 *   - `recipe`  → the family Kitchen (reuses `recipeExtract` for the full Menere recipe shape).
 *   - `product` → a wishlist item (title / price / store / image + the link).
 *   - `event`   → a calendar event (title / start / end — reuses the eventExtract date discipline).
 *   - `article` → a Family Brain document (title + summary + link + extracted text). ← safe fallback.
 *
 * One Claude classification call (Haiku, forced tool-use) does the routing + per-type extraction from
 * the page's title/meta/JSON-LD/visible text. Conservative by design: anything ambiguous, or any
 * failure along the way, degrades to a Family Brain doc so a link is NEVER lost. No rate limiting
 * (Bacán is a private family app). Reuses the existing `ANTHROPIC_API_KEY` secret.
 */

const Anthropic = require("@anthropic-ai/sdk");
const { extractRecipe } = require("./recipeExtract");

// --- Page fetch + lightweight scraping --------------------------------------

async function fetchPage(url) {
  const response = await fetch(url, {
    headers: {
      "User-Agent": "Mozilla/5.0 (compatible; BacanBot/1.0; +url-ingestion)",
      Accept: "text/html,application/xhtml+xml",
    },
    redirect: "follow",
  });
  if (!response.ok) throw new Error(`fetch failed (${response.status})`);
  return await response.text();
}

/** Pull a `<meta>` content value by property/name, tolerant of attribute order. */
function metaContent(html, key) {
  const patterns = [
    new RegExp(`<meta[^>]+(?:property|name|itemprop)\\s*=\\s*["']${key}["'][^>]+content\\s*=\\s*["']([^"']*)["']`, "i"),
    new RegExp(`<meta[^>]+content\\s*=\\s*["']([^"']*)["'][^>]+(?:property|name|itemprop)\\s*=\\s*["']${key}["']`, "i"),
  ];
  for (const re of patterns) {
    const m = html.match(re);
    if (m && m[1]) return decodeEntities(m[1].trim());
  }
  return null;
}

function pageTitle(html) {
  const og = metaContent(html, "og:title");
  if (og) return og;
  const m = html.match(/<title[^>]*>([\s\S]*?)<\/title>/i);
  return m ? decodeEntities(m[1].trim()) : null;
}

function decodeEntities(s) {
  return s
    .replace(/&amp;/g, "&")
    .replace(/&lt;/g, "<")
    .replace(/&gt;/g, ">")
    .replace(/&quot;/g, '"')
    .replace(/&#39;/g, "'")
    .replace(/&apos;/g, "'")
    .replace(/&nbsp;/g, " ")
    .replace(/&#(\d+);/g, (_, n) => String.fromCharCode(parseInt(n, 10)));
}

/** Strip scripts/styles/tags → a compact, model-friendly text blob. */
function htmlToText(html) {
  return html
    .replace(/<script[\s\S]*?<\/script>/gi, " ")
    .replace(/<style[\s\S]*?<\/style>/gi, " ")
    .replace(/<noscript[\s\S]*?<\/noscript>/gi, " ")
    .replace(/<!--[\s\S]*?-->/g, " ")
    .replace(/<[^>]+>/g, " ")
    .replace(/\s+/g, " ")
    .trim();
}

/** Best-effort price + currency from product/OG meta or JSON-LD offers. */
function scrapePriceSignal(html) {
  const amountRaw =
    metaContent(html, "product:price:amount") ||
    metaContent(html, "og:price:amount") ||
    metaContent(html, "price") ||
    jsonLdPrice(html);
  const currency =
    metaContent(html, "product:price:currency") ||
    metaContent(html, "og:price:currency") ||
    metaContent(html, "priceCurrency") ||
    null;
  let amount = null;
  if (amountRaw != null) {
    const n = parseFloat(String(amountRaw).replace(/[^0-9.]/g, ""));
    if (!isNaN(n)) amount = n;
  }
  return { amount, currency };
}

/** True when any JSON-LD block on the page declares an @type of the given name(s). */
function hasJsonLdType(html, types) {
  const wanted = Array.isArray(types) ? types : [types];
  const re = /<script[^>]*type\s*=\s*["']application\/ld\+json["'][^>]*>([\s\S]*?)<\/script>/gi;
  let match;
  while ((match = re.exec(html)) !== null) {
    try {
      const found = collectTypes(JSON.parse(match[1]));
      if (found.some((t) => wanted.includes(t))) return true;
    } catch {
      continue;
    }
  }
  return false;
}

function collectTypes(json) {
  if (Array.isArray(json)) return json.flatMap(collectTypes);
  if (json && typeof json === "object") {
    let out = [];
    const t = json["@type"];
    if (typeof t === "string") out.push(t);
    else if (Array.isArray(t)) out = out.concat(t.filter((x) => typeof x === "string"));
    if (json["@graph"]) out = out.concat(collectTypes(json["@graph"]));
    return out;
  }
  return [];
}

function jsonLdPrice(html) {
  const re = /<script[^>]*type\s*=\s*["']application\/ld\+json["'][^>]*>([\s\S]*?)<\/script>/gi;
  let match;
  while ((match = re.exec(html)) !== null) {
    try {
      const price = findOfferPrice(JSON.parse(match[1]));
      if (price != null) return price;
    } catch {
      continue;
    }
  }
  return null;
}

function findOfferPrice(json) {
  if (Array.isArray(json)) {
    for (const item of json) {
      const p = findOfferPrice(item);
      if (p != null) return p;
    }
    return null;
  }
  if (json && typeof json === "object") {
    if (json.offers) {
      const offers = Array.isArray(json.offers) ? json.offers : [json.offers];
      for (const o of offers) {
        if (o && o.price != null) return o.price;
        if (o && o.priceSpecification && o.priceSpecification.price != null) return o.priceSpecification.price;
      }
    }
    if (json.price != null && (json["@type"] === "Offer" || json["@type"] === "Product")) return json.price;
    if (json["@graph"]) return findOfferPrice(json["@graph"]);
  }
  return null;
}

// --- Claude classification + per-type extraction -----------------------------

const URL_CLASSIFY_TOOL = {
  name: "classify_url",
  description: "Classify a web page and extract the fields needed to file it for a family.",
  input_schema: {
    type: "object",
    properties: {
      kind: {
        type: "string",
        enum: ["recipe", "product", "event", "article"],
        description:
          "recipe = a cookable recipe with ingredients/steps; product = a specific buyable item " +
          "(store/shop/product page, something to add to a wishlist or gift idea); event = a dated " +
          "happening to put on a calendar (show, class, reservation, ticketed event with a date); " +
          "article = anything else — news, a blog post, a reference page. When unsure, choose article.",
      },
      title: { type: "string", description: "A concise human title for the item (not the site name)." },
      summary: {
        type: ["string", "null"],
        description: "One or two plain sentences describing the page, in a warm, family-friendly voice.",
      },
      product: {
        type: ["object", "null"],
        description: "Only when kind == product. Null otherwise.",
        properties: {
          name: { type: ["string", "null"], description: "The product name." },
          price: { type: ["number", "null"], description: "Numeric price if shown, else null." },
          store: { type: ["string", "null"], description: "Store/brand, e.g. 'Amazon', 'Target', 'IKEA'." },
        },
        required: ["name", "price", "store"],
      },
      event: {
        type: ["object", "null"],
        description: "Only when kind == event. Null otherwise.",
        properties: {
          startDate: { type: ["string", "null"], description: "ISO 8601 datetime with UTC offset, or null if no date." },
          endDate: { type: ["string", "null"], description: "ISO 8601 datetime with UTC offset, or null." },
          isAllDay: { type: "boolean" },
          location: { type: ["string", "null"] },
        },
        required: ["startDate", "endDate", "isAllDay", "location"],
      },
    },
    required: ["kind", "title", "summary", "product", "event"],
  },
};

async function classify({ apiKey, url, title, description, text, priceSignal, timezone }) {
  const tz = timezone || "America/New_York";
  const nowLocal = new Intl.DateTimeFormat("en-US", { timeZone: tz, dateStyle: "full", timeStyle: "long" }).format(new Date());
  const priceHint =
    priceSignal.amount != null ? `Structured price signal on the page: ${priceSignal.amount} ${priceSignal.currency || ""}.` : "";

  const client = new Anthropic({ apiKey });
  const response = await client.messages.create({
    model: "claude-haiku-4-5-20251001",
    max_tokens: 1024,
    tools: [URL_CLASSIFY_TOOL],
    tool_choice: { type: "tool", name: "classify_url" },
    messages: [
      {
        role: "user",
        content:
          `Classify this web page and extract the fields to file it for a family. ` +
          `The family's timezone is ${tz}; the current local time there is ${nowLocal}. ` +
          `For an event, output any date as ISO 8601 WITH the correct UTC offset for ${tz} (accounting ` +
          `for daylight saving). ${priceHint}\n\n` +
          `URL: ${url}\nTITLE: ${title || "(none)"}\nDESCRIPTION: ${description || "(none)"}\n\n` +
          `PAGE TEXT (truncated):\n${text}`,
      },
    ],
  });
  for (const block of response.content) {
    if (block.type === "tool_use" && block.name === "classify_url") return block.input;
  }
  return null;
}

// --- Orchestrator ------------------------------------------------------------

/**
 * Fetch + classify + extract a URL into a routed result:
 *   { destination, title, url, summary, imageURL, extractedText, recipe?, product?, event? }
 * `destination` ∈ "recipe" | "product" | "event" | "brain". Never throws for a normal page —
 * the conservative fallback is always a Brain doc.
 *
 * @param {{ url: string, apiKey: string, timezone?: string }} args
 */
async function extractURL({ url, apiKey, timezone }) {
  let html = "";
  try {
    html = await fetchPage(url);
  } catch (err) {
    // Couldn't even load the page — still file the bare link to the Brain so it's not lost.
    return brainFallback({ url, title: prettyURL(url), summary: null, extractedText: null, imageURL: null });
  }

  const title = pageTitle(html) || prettyURL(url);
  const description = metaContent(html, "og:description") || metaContent(html, "description");
  const imageURL = metaContent(html, "og:image") || metaContent(html, "twitter:image");
  const text = htmlToText(html).slice(0, 9000);
  const priceSignal = scrapePriceSignal(html);

  // Structured signals sharpen the classifier but never override its final call.
  const looksRecipe = hasJsonLdType(html, "Recipe");
  const looksProduct = hasJsonLdType(html, "Product") || (metaContent(html, "og:type") || "").includes("product") || priceSignal.amount != null;
  const looksEvent = hasJsonLdType(html, ["Event", "BusinessEvent", "MusicEvent", "TheaterEvent", "SocialEvent"]);

  let result;
  try {
    result = await classify({ apiKey, url, title, description, text, priceSignal, timezone });
  } catch {
    result = null;
  }

  // No classification at all → conservative Brain doc with whatever metadata we scraped.
  if (!result || !result.kind) {
    return brainFallback({ url, title, summary: description || null, extractedText: text, imageURL });
  }

  let kind = result.kind;
  // Gentle nudges from the structured signals when the model was on the fence toward "article".
  if (kind === "article" && looksRecipe) kind = "recipe";
  if (kind === "article" && looksProduct && !looksEvent) kind = "product";
  if (kind === "article" && looksEvent) kind = "event";

  const outTitle = (result.title && result.title.trim()) || title;
  const summary = (result.summary && result.summary.trim()) || description || null;

  if (kind === "recipe") {
    try {
      const { recipe } = await extractRecipe({ url, apiKey });
      if (recipe && Array.isArray(recipe.ingredients) && recipe.ingredients.length > 0) {
        return { destination: "recipe", title: recipe.title || outTitle, url, summary, imageURL: recipe.imageURL || imageURL || null, recipe };
      }
    } catch {
      // fall through to Brain
    }
    return brainFallback({ url, title: outTitle, summary, extractedText: text, imageURL });
  }

  if (kind === "product") {
    const p = result.product || {};
    const price = p.price != null ? p.price : priceSignal.amount;
    return {
      destination: "product",
      title: (p.name && p.name.trim()) || outTitle,
      url,
      summary,
      imageURL: imageURL || null,
      product: {
        name: (p.name && p.name.trim()) || outTitle,
        price: price != null ? Number(price) : null,
        store: (p.store && p.store.trim()) || null,
      },
    };
  }

  if (kind === "event") {
    const e = result.event || {};
    // No date at all → not really schedulable; keep the link in the Brain instead of a bogus event.
    if (!e.startDate) {
      return brainFallback({ url, title: outTitle, summary, extractedText: text, imageURL });
    }
    return {
      destination: "event",
      title: outTitle,
      url,
      summary,
      imageURL: imageURL || null,
      event: {
        startDate: e.startDate,
        endDate: e.endDate || null,
        isAllDay: e.isAllDay === true,
        location: (e.location && e.location.trim()) || null,
      },
    };
  }

  // article / anything else → the Family Brain.
  return brainFallback({ url, title: outTitle, summary, extractedText: text, imageURL });
}

function brainFallback({ url, title, summary, extractedText, imageURL }) {
  return {
    destination: "brain",
    title: title || prettyURL(url),
    url,
    summary: summary || null,
    imageURL: imageURL || null,
    extractedText: extractedText || null,
  };
}

/** A human-ish fallback title from the URL (host + first path segment). */
function prettyURL(url) {
  try {
    const u = new URL(url);
    const seg = u.pathname.split("/").filter(Boolean)[0];
    return seg ? `${u.hostname} — ${seg.replace(/[-_]/g, " ")}` : u.hostname;
  } catch {
    return url;
  }
}

module.exports = { extractURL };
