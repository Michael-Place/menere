"use strict";

/**
 * AI daily briefing for the Menere/Bacán `generateDailyBriefing` Cloud Function.
 *
 * Gathers "today" (America/New_York) family context server-side — member names, today's events,
 * incomplete chores, tonight's dinner — and asks Claude (Haiku) for a short, warm, witty briefing
 * in the Place family's voice. Structured tool-use output → { summary, highlights[] }.
 *
 * Per-day cache: the result is stored at households/{hid}/briefings/{YYYY-MM-DD} (ET date). The
 * cached doc is returned unless `force` is true (the refresh button), in which case it regenerates
 * and overwrites. Reuses the existing ANTHROPIC_API_KEY secret. No rate limiting (private app).
 */

const Anthropic = require("@anthropic-ai/sdk");
const admin = require("firebase-admin");

const TZ = "America/New_York";

/** YYYY-MM-DD for a Date in the household's zone (en-CA yields ISO-ordered date parts). */
function etDateString(date) {
  return new Intl.DateTimeFormat("en-CA", {
    timeZone: TZ,
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
  }).format(date);
}

/** Firestore Timestamp | Date | ISO string → Date, or null if unparseable. */
function toDate(value) {
  if (!value) return null;
  if (typeof value.toDate === "function") return value.toDate();
  const d = new Date(value);
  return isNaN(d.getTime()) ? null : d;
}

const BRIEFING_TOOL = {
  name: "write_briefing",
  description: "Write today's family daily briefing.",
  input_schema: {
    type: "object",
    properties: {
      summary: {
        type: "string",
        description: "2-3 warm, witty, concise sentences summarizing the family's day.",
      },
      highlights: {
        type: "array",
        items: { type: "string" },
        description: "0 to 3 short, actionable fragments (e.g. 'Take out the recycling').",
      },
    },
    required: ["summary", "highlights"],
  },
};

const SYSTEM_PROMPT = `You write a warm, witty, CONCISE daily briefing for the Place family's private app, "Bacán".

Voice & rules:
- Warm and a little witty; use first names; sentence case; at most one exclamation point in the whole briefing.
- summary: 2-3 sentences MAX. highlights: 0-3 short actionable fragments (not full sentences).
- Only mention what's actually in the data. NEVER invent events, chores, or dinner plans that aren't provided.
- The family's little one Francis is called "Famfis" (his own pronunciation); the dogs are Fajita & Sprinkle. You may reference Famfis or the dogs ONLY when the data actually mentions them by name — otherwise don't.
- No exclamation spam, no corporate cheerleading, no emoji.
- A quiet day (nothing scheduled, few or no chores, no dinner planned) is not a failure — give it a genuinely nice, unhurried quiet-day line rather than manufacturing urgency.`;

/**
 * Read today's family context from Firestore. All scoped to the ET "today" string.
 *
 * LIMITATION: recurrence is expanded client-side in the app; there is no server recurrence job.
 * We therefore include only NON-recurring events whose start date is today. Recurring occurrences
 * that would land today are omitted from the briefing (acceptable for a short summary).
 */
async function gatherContext(db, hid, today) {
  const householdRef = db.collection("households").doc(hid);

  const [membersSnap, eventsSnap, choresSnap, planSnap] = await Promise.all([
    householdRef.collection("members").get(),
    householdRef.collection("events").get(),
    householdRef.collection("chores").get(),
    householdRef.collection("mealPlan").get(),
  ]);

  const nameByID = {};
  const memberNames = [];
  membersSnap.forEach((doc) => {
    const name = String((doc.data() || {}).name || "").trim();
    if (name) {
      nameByID[doc.id] = name;
      memberNames.push(name);
    }
  });

  const timeFmt = new Intl.DateTimeFormat("en-US", {
    timeZone: TZ,
    hour: "numeric",
    minute: "2-digit",
  });

  const events = [];
  eventsSnap.forEach((doc) => {
    const d = doc.data() || {};
    const start = toDate(d.startDate);
    if (!start) return;
    if ((d.recurrence || "none") !== "none") return; // see LIMITATION above
    if (etDateString(start) !== today) return;
    events.push({
      title: String(d.title || "Untitled"),
      time: d.isAllDay ? "all day" : timeFmt.format(start),
      who: (Array.isArray(d.assigneeIDs) ? d.assigneeIDs : [])
        .map((id) => nameByID[id])
        .filter(Boolean),
    });
  });

  const chores = [];
  choresSnap.forEach((doc) => {
    const d = doc.data() || {};
    if (d.isCompleted) return;
    const due = toDate(d.dueDate);
    let status;
    if (!due) {
      status = "undated";
    } else {
      const dueStr = etDateString(due);
      if (dueStr > today) return; // future-dated — not on today's board
      status = dueStr < today ? "overdue" : "today";
    }
    chores.push({
      title: String(d.title || "Untitled"),
      status,
      who: d.assigneeID ? nameByID[d.assigneeID] || null : null,
    });
  });

  let dinner = null;
  planSnap.forEach((doc) => {
    const d = doc.data() || {};
    const date = toDate(d.date);
    if (date && etDateString(date) === today) {
      const title = String(d.recipeTitle || "").trim();
      if (title) dinner = title;
    }
  });

  return { memberNames, events, chores, dinner };
}

/** Ask Claude for the structured briefing. Returns { summary, highlights } or null. */
async function callClaude(apiKey, context, today) {
  const client = new Anthropic({ apiKey });
  const payload = JSON.stringify(
    {
      date: today,
      timezone: TZ,
      family: context.memberNames,
      eventsToday: context.events,
      openChores: context.chores,
      dinnerTonight: context.dinner,
    },
    null,
    2
  );

  const response = await client.messages.create({
    model: "claude-haiku-4-5",
    max_tokens: 1024,
    system: SYSTEM_PROMPT,
    tools: [BRIEFING_TOOL],
    tool_choice: { type: "tool", name: "write_briefing" },
    messages: [
      {
        role: "user",
        content: `Here is today's family data (times are ${TZ}). Write today's briefing.\n\n${payload}`,
      },
    ],
  });

  for (const block of response.content) {
    if (block.type === "tool_use" && block.name === "write_briefing") {
      const out = block.input || {};
      const summary = typeof out.summary === "string" ? out.summary.trim() : "";
      const highlights = Array.isArray(out.highlights)
        ? out.highlights.filter((h) => typeof h === "string" && h.trim()).map((h) => h.trim()).slice(0, 3)
        : [];
      if (!summary) return null;
      return { summary, highlights };
    }
  }
  return null;
}

/**
 * Generate (or return the cached) daily briefing for a household.
 * @returns {Promise<{ summary: string, highlights: string[], date: string, cached: boolean }>}
 */
async function generateDailyBriefing({ db, hid, apiKey, force }) {
  const today = etDateString(new Date());
  const ref = db.collection("households").doc(hid).collection("briefings").doc(today);

  if (!force) {
    const snap = await ref.get();
    if (snap.exists) {
      const d = snap.data() || {};
      console.log(`[briefing] cache hit hid=${hid} date=${today}`);
      return {
        summary: String(d.summary || ""),
        highlights: Array.isArray(d.highlights) ? d.highlights : [],
        date: today,
        cached: true,
      };
    }
  }

  const context = await gatherContext(db, hid, today);
  const result = await callClaude(apiKey, context, today);
  if (!result) throw new Error("Claude returned no briefing");

  await ref.set({
    summary: result.summary,
    highlights: result.highlights,
    date: today,
    createdAt: admin.firestore.FieldValue.serverTimestamp(),
  });
  console.log(`[briefing] generated hid=${hid} date=${today} force=${!!force}`);

  return { ...result, date: today, cached: false };
}

module.exports = { generateDailyBriefing };
