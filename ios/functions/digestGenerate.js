"use strict";

/**
 * Weekly family digest (Act V V2-E) for the `weeklyFamilyDigest` scheduled Cloud Function.
 *
 * Gathers the week ahead for a household — overdue/upcoming CARE, expired/upcoming document
 * RENEWALS (pet vaccines, registrations), upcoming EVENTS, BIRTHDAYS, child CHECKUPS, and a MONEY
 * glance — via `familySignals.gatherSignals`, then asks Claude (Haiku, same warm family voice as the
 * daily briefing) for a short digest: `{ headline, body }`. Persists it at
 * `households/{hid}/digests/{YYYY-Www}` (ET ISO week) so it's viewable, and returns a push-ready
 * `{ title, body }` for the scheduler to deliver. Compose is separate from delivery so a harness can
 * exercise it without sending FCM. Reuses the existing ANTHROPIC_API_KEY. No rate limiting.
 */

const Anthropic = require("@anthropic-ai/sdk");
const admin = require("firebase-admin");
const { TZ, isoWeekKey, gatherSignals, dayLabel } = require("./familySignals");

const DIGEST_TOOL = {
  name: "write_digest",
  description: "Write this week's warm family digest.",
  input_schema: {
    type: "object",
    properties: {
      headline: {
        type: "string",
        description: "One short, warm push-title line (≤ 6 words), e.g. 'Your week at a glance'.",
      },
      body: {
        type: "string",
        description: "3-5 warm, witty sentences summarizing the week ahead: what needs care, what's coming up, birthdays, money glance. First names, sentence case, at most one exclamation.",
      },
    },
    required: ["headline", "body"],
  },
};

const SYSTEM_PROMPT = `You write a warm, witty, CONCISE WEEKLY digest for the Place family's private app, "Bacán".

Voice & rules:
- Warm and a little witty; use first names; sentence case; at most one exclamation point in the whole digest.
- body: 3-5 sentences MAX — a Sunday "here's the week ahead" note, not a report.
- Only mention what's actually in the data. NEVER invent care, events, birthdays, renewals, or spend that isn't provided.
- ALWAYS call out any EXPIRED pet vaccine or registration when present — an expired rabies is a real health/legal gap and the single loudest thing to surface; never let routine watering crowd it out.
- Lead with what needs attention (overdue care, expired pet vaccines/renewals), then the week's events + birthdays (nudge to plan/shop when one's coming up), then a light money glance if present.
- Plant watering is high-volume — summarize it in a few words ("the plants need their weekly water"), don't enumerate species.
- The little one Francis is "Famfis" (his own pronunciation); the dogs are Fajita & Sprinkle; the cat is Fireball. Only name them when the data does.
- No corporate cheerleading, no emoji, no bullet lists — flowing sentences.
- A calm week (nothing overdue, little on the calendar) is a GOOD thing — say so warmly instead of manufacturing urgency.`;

/** Compact the gathered signals into the small JSON the model reasons over (labels + day offsets). */
function summarizeForModel(signals) {
  const money = signals.money.hasData
    ? {
        thisMonthTotal: signals.money.total,
        topCategory: signals.money.topCategory
          ? `${signals.money.topCategory.category} ($${signals.money.topCategory.amount})`
          : null,
      }
    : null;
  // Plant watering is high-volume (the house has 30+ plants) — summarize it as a count so it can't
  // crowd out the important, low-volume signals (expired vaccines, pet care) in the model's view.
  const plantCare = signals.upcomingCare.filter((c) => c.category === "plant");
  const otherCare = signals.upcomingCare.filter((c) => c.category !== "plant");
  return {
    overdueCare: signals.overdueCare.map((c) => ({ what: c.label, daysOverdue: c.daysOver })),
    careDueThisWeek: {
      plantsNeedingWater: plantCare.length || undefined,
      otherCare: otherCare.slice(0, 8).map((c) => ({ what: c.label, inDays: c.days })),
    },
    expiredRenewals: signals.expiredRenewals.map((r) => ({ what: r.label, expiredDaysAgo: -r.days })),
    upcomingRenewals: signals.upcomingRenewals.map((r) => ({
      what: r.label, inDays: r.days, amount: r.amount ?? undefined, when: dayLabel(r.date),
    })),
    eventsThisWeek: signals.events.map((e) => ({ what: e.title, when: dayLabel(e.start), inDays: e.days })),
    birthdays: signals.birthdays.map((b) => ({ who: b.who, when: dayLabel(b.date), inDays: b.days })),
    checkups: signals.checkups.map((c) => ({ who: c.name, when: dayLabel(c.date), inDays: c.days })),
    money,
  };
}

/** Ask Claude for the structured digest. Returns { headline, body } or null. */
async function callClaude(apiKey, model, compact) {
  const client = new Anthropic({ apiKey });
  const payload = JSON.stringify({ timezone: TZ, ...compact }, null, 2);
  const response = await client.messages.create({
    model,
    max_tokens: 1024,
    system: SYSTEM_PROMPT,
    tools: [DIGEST_TOOL],
    tool_choice: { type: "tool", name: "write_digest" },
    messages: [{ role: "user", content: `Here's the week ahead for the family (times are ${TZ}). Write this week's digest.\n\n${payload}` }],
  });
  for (const block of response.content) {
    if (block.type === "tool_use" && block.name === "write_digest") {
      const out = block.input || {};
      const headline = typeof out.headline === "string" ? out.headline.trim() : "";
      const body = typeof out.body === "string" ? out.body.trim() : "";
      if (!body) return null;
      return { headline: headline || "Your week at a glance", body };
    }
  }
  return null;
}

/**
 * Generate the weekly digest for a household.
 *
 * @param {object} args
 * @param {FirebaseFirestore.Firestore} args.db
 * @param {string} args.hid
 * @param {string} args.apiKey
 * @param {Date} [args.now]
 * @param {boolean} [args.persist=true]  write the digest doc
 * @param {string} [args.model="claude-haiku-4-5"]
 * @returns {Promise<null | { weekKey, title, body, headline, signals, compact }>}
 *   null when the week is genuinely empty (nothing worth a digest) — the scheduler then skips.
 */
async function generateWeeklyDigest({ db, hid, apiKey, now = new Date(), persist = true, model = "claude-haiku-4-5" }) {
  const signals = await gatherSignals(db, hid, { now, eventDays: 7, careDays: 7, horizonDays: 90 });

  const hasAnything =
    signals.overdueCare.length || signals.upcomingCare.length ||
    signals.expiredRenewals.length || signals.upcomingRenewals.length ||
    signals.events.length || signals.birthdays.length ||
    signals.checkups.length || signals.money.hasData;
  if (!hasAnything) {
    console.log(`[digest] nothing to say hid=${hid} week=${isoWeekKey(now)}`);
    return null;
  }

  const compact = summarizeForModel(signals);
  const result = await callClaude(apiKey, model, compact);
  if (!result) throw new Error("Claude returned no digest");

  const weekKey = isoWeekKey(now);
  const title = result.headline;
  const body = result.body;

  if (persist) {
    await db.collection("households").doc(hid).collection("digests").doc(weekKey).set({
      weekKey,
      title,
      headline: result.headline,
      body,
      // A compact, viewable snapshot of what fed the digest (for a Today "this week" surface later).
      signals: compact,
      createdAt: admin.firestore.FieldValue.serverTimestamp(),
    });
  }
  console.log(`[digest] generated hid=${hid} week=${weekKey}`);
  return { weekKey, title, body, headline: result.headline, signals, compact };
}

module.exports = { generateWeeklyDigest };
