"use strict";

/**
 * AI weekly usage review for the Menere/Bacán `reviewUsage` Cloud Function (P25-C2 — closing the
 * signal loop). P25-C1 already logs ~19 light behavioral events to `households/{hid}/analytics`
 * ({ event, properties, uid, at }). This callable reads the last N days of those events, aggregates
 * COUNTS server-side (cheap — never ships raw rows to the model), and asks Claude (Sonnet 5, forced
 * tool-use) for a plain-language UX review: what's used, what's ignored, friction, and 3 concrete
 * suggestions — in the family's warm, honest-but-kind product-analyst voice.
 *
 * Secondary signal: the P14 assistant logs its tool names server-side too (event `assistant_tool_used`
 * with `properties.tool` — if present in analytics), so most-asked → most-surfaced insights fall out.
 *
 * Output: { summary, topFeatures:[string], underusedFeatures:[string], frictionSignals:[string],
 *           suggestions:[{title, why}], windowDays, eventCount, isSparse }.
 *
 * The household is derived from the CALLER (`users/{uid}.householdId`) in index.js — a client-passed
 * hid is never trusted. Auth-required. Reuses the existing ANTHROPIC_API_KEY. No rate limiting.
 * Privacy: only event names + light structural properties are read (the analytics collection never
 * stores document contents / message text), and only aggregate COUNTS reach the model.
 */

const Anthropic = require("@anthropic-ai/sdk");

const MODEL = "claude-sonnet-5"; // matches the app's other reasoning calls; do NOT downgrade

const DEFAULT_WINDOW_DAYS = 7;
const MAX_ROWS = 5000; // safety cap; the family's analytics is tiny, but never fan out unbounded.

const REVIEW_TOOL = {
  name: "write_usage_review",
  description:
    "Write a warm, honest, plain-language UX review of how the Place family is actually using their app.",
  input_schema: {
    type: "object",
    properties: {
      summary: {
        type: "string",
        description:
          "2-4 warm, plain sentences on how the family is using Bacán so far. If the data is sparse, say so honestly ('still early — here's what we can see so far') rather than over-reading it. Family voice, first names, sentence case, at most one exclamation point.",
      },
      topFeatures: {
        type: "array",
        items: { type: "string" },
        description:
          "The features/screens getting the most real use, most-used first. Short human labels (e.g. 'Today dashboard', 'Plants'). Only include what the counts actually support; [] if there's not enough signal.",
      },
      underusedFeatures: {
        type: "array",
        items: { type: "string" },
        description:
          "Features that exist but are getting little or no use — candidates to surface better or cut. Short human labels. Be honest but don't manufacture: [] when the data can't tell yet.",
      },
      frictionSignals: {
        type: "array",
        items: { type: "string" },
        description:
          "Plain-language friction/abandonment signals visible in the counts (e.g. 'opened Plants a lot but never opened a plant detail'). [] if none are evident yet.",
      },
      suggestions: {
        type: "array",
        items: {
          type: "object",
          properties: {
            title: { type: "string", description: "A short, concrete UX improvement (imperative)." },
            why: { type: "string", description: "One plain sentence tying it to the observed usage (or lack of it)." },
          },
          required: ["title", "why"],
        },
        description:
          "Up to 3 concrete, actionable suggestions grounded in the data. When data is sparse, suggest what to WATCH next rather than inventing conclusions.",
      },
    },
    required: ["summary", "topFeatures", "underusedFeatures", "frictionSignals", "suggestions"],
  },
};

const SYSTEM_PROMPT = `You are a friendly, sharp product analyst for the Place family's private app, "Bacán" — a family hub (calendar, lists, chores, recipes, plants, pets, smart home, a Family Brain document vault, and an AI assistant).

The family: Michael, Valentina ("Vale"), Oliver (3), and baby Francis — called "Famfis" (his own pronunciation). Dogs Fajita & Sprinkle. There are only ~2 adult users, so this is a tiny, known population — behavioral signal, not statistics.

Your job: given AGGREGATE COUNTS of light usage events over a recent window, write a plain-language review of how the app is actually being used — what's used, what's ignored, where there's friction — plus up to 3 concrete UX suggestions.

Voice & rules:
- Warm and a little witty; first names; sentence case; at most one exclamation point total. Honest but kind — never scolding.
- Only reason from the counts you're given. NEVER invent usage, features, numbers, or friction that the data doesn't show.
- The telemetry is only a day or two old, so data will usually be SPARSE. When it is, SAY SO plainly ("still early — here's what we can see so far") and lean your suggestions toward what to WATCH next, not firm conclusions. Do not over-read a handful of taps.
- Friction insight is the gold: pairs like "opened X a lot but never opened an X detail" or "tab selected often, action never taken" are exactly what to surface — but only if the counts genuinely show it.
- If assistant tool-use counts are present, treat what people ASK for as a signal of UI gaps (most-asked → most-surfaced).
- Keep labels human ("Today dashboard", "Plants", "Family Brain"), not raw event names.
- No corporate analytics-speak, no emoji, no vanity metrics.`;

/**
 * Read the last `windowDays` of analytics rows and aggregate to cheap counts. Returns a compact,
 * model-friendly shape — event counts, per-property breakdowns for the events that carry a dimension
 * (tab, card, kind, tool), the distinct-day count, and the raw total. Never returns raw rows.
 */
async function aggregate(db, hid, windowDays) {
  const cutoff = new Date(Date.now() - windowDays * 24 * 60 * 60 * 1000);
  const snap = await db
    .collection("households")
    .doc(hid)
    .collection("analytics")
    .where("at", ">=", cutoff)
    .orderBy("at", "desc")
    .limit(MAX_ROWS)
    .get();

  const eventCounts = {}; // event -> count
  const propertyBreakdowns = {}; // event -> { propKey: { propValue: count } }
  const dayKeys = new Set();
  let total = 0;

  snap.forEach((doc) => {
    const d = doc.data() || {};
    const event = typeof d.event === "string" ? d.event : null;
    if (!event) return;
    total += 1;
    eventCounts[event] = (eventCounts[event] || 0) + 1;

    const props = d.properties && typeof d.properties === "object" ? d.properties : null;
    if (props) {
      for (const [k, v] of Object.entries(props)) {
        if (v == null) continue;
        const key = String(v).slice(0, 40);
        propertyBreakdowns[event] = propertyBreakdowns[event] || {};
        propertyBreakdowns[event][k] = propertyBreakdowns[event][k] || {};
        propertyBreakdowns[event][k][key] = (propertyBreakdowns[event][k][key] || 0) + 1;
      }
    }

    const at = d.at && typeof d.at.toDate === "function" ? d.at.toDate() : null;
    if (at) dayKeys.add(at.toISOString().slice(0, 10));
  });

  return {
    eventCounts,
    propertyBreakdowns,
    total,
    distinctDays: dayKeys.size,
    windowDays,
  };
}

/** Ask Claude for the structured review. Returns the tool input or null. */
async function callClaude(apiKey, agg) {
  const client = new Anthropic({ apiKey });

  // Sort the counts descending so the model reads them in salience order.
  const sortedEvents = Object.entries(agg.eventCounts).sort((a, b) => b[1] - a[1]);
  const payload = JSON.stringify(
    {
      windowDays: agg.windowDays,
      totalEvents: agg.total,
      distinctActiveDays: agg.distinctDays,
      eventCounts: Object.fromEntries(sortedEvents),
      propertyBreakdowns: agg.propertyBreakdowns,
    },
    null,
    2
  );

  const response = await client.messages.create({
    model: MODEL,
    max_tokens: 1500,
    system: SYSTEM_PROMPT,
    tools: [REVIEW_TOOL],
    tool_choice: { type: "tool", name: "write_usage_review" },
    messages: [
      {
        role: "user",
        content: `Here are the aggregate usage counts for the last ${agg.windowDays} days. Remember the telemetry is brand new, so treat sparse data honestly. Write the review.\n\n${payload}`,
      },
    ],
  });

  for (const block of response.content) {
    if (block.type === "tool_use" && block.name === "write_usage_review") {
      return block.input || null;
    }
  }
  return null;
}

/**
 * Scrub a model string. Sonnet occasionally leaks its tool-call scaffolding into a field value
 * (e.g. a summary that ends `…this early.</summary><parameter name="topFeatures">[…]`). Cut the value
 * at the first such marker and strip any residual XML-ish tags so the UI never shows raw markup.
 */
function cleanText(raw) {
  if (typeof raw !== "string") return "";
  let s = raw.split(/<\/?(?:summary|parameter|invoke|function_calls|tool_use)\b/i)[0];
  s = s.replace(/<[^>]*>/g, ""); // any stray tags
  // Decode literal escape sequences the model sometimes emits as text (e.g. "—" → "—").
  s = s.replace(/\\u([0-9a-fA-F]{4})/g, (_, hex) => String.fromCharCode(parseInt(hex, 16)));
  s = s.trim();
  s = s.replace(/^["']+|["']+$/g, "").trim(); // strip stray wrapping quotes from JSON leakage
  return s;
}

/** Coerce Claude's tool input into the exact wire shape, defensively. */
function shape(input) {
  const strArray = (a) =>
    Array.isArray(a) ? a.map(cleanText).filter(Boolean).slice(0, 8) : [];
  const suggestions = Array.isArray(input.suggestions)
    ? input.suggestions
        .map((s) => ({ title: cleanText(s?.title), why: cleanText(s?.why) }))
        .filter((s) => s.title)
        .slice(0, 3)
    : [];
  return {
    summary: cleanText(input.summary),
    topFeatures: strArray(input.topFeatures),
    underusedFeatures: strArray(input.underusedFeatures),
    frictionSignals: strArray(input.frictionSignals),
    suggestions,
  };
}

/**
 * Produce the weekly usage review.
 * @param {{ db: FirebaseFirestore.Firestore, hid: string, apiKey: string, windowDays?: number }} params
 * @returns {Promise<object>} the review payload
 */
async function reviewUsage({ db, hid, apiKey, windowDays }) {
  const days = Number.isFinite(windowDays) && windowDays > 0 ? Math.min(Math.floor(windowDays), 90) : DEFAULT_WINDOW_DAYS;
  const agg = await aggregate(db, hid, days);
  console.log(`[usage] review hid=${hid} window=${days}d events=${agg.total} activeDays=${agg.distinctDays}`);

  // Sparse-but-nonzero data still gets a real (honest) review; truly empty gets a warm placeholder.
  const isSparse = agg.total < 40 || agg.distinctDays <= 2;

  if (agg.total === 0) {
    return {
      summary:
        "Nothing logged in Bacán just yet — the usage sensor is on, but it's waiting for the family to poke around. Give it a few days and this fills in on its own.",
      topFeatures: [],
      underusedFeatures: [],
      frictionSignals: [],
      suggestions: [
        { title: "Just use the app normally", why: "Every tap quietly teaches this review what's worth surfacing." },
      ],
      windowDays: days,
      eventCount: 0,
      isSparse: true,
    };
  }

  const raw = await callClaude(apiKey, agg);
  if (!raw) throw new Error("Claude returned no review");
  const out = shape(raw);
  if (!out.summary) throw new Error("Claude returned an empty summary");

  return { ...out, windowDays: days, eventCount: agg.total, isSparse };
}

module.exports = { reviewUsage };
