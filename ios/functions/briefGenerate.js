"use strict";

/**
 * AI project brief for the Bacán `generateProjectBrief` Cloud Function (Projects PR4).
 *
 * Gathers one project's state server-side — phase, target date, budget, tasks (open vs done),
 * contacts, links, and its linked Family-Brain quote documents (vendor/amount/summary) — and asks
 * Claude (Sonnet 5) for a short, warm, witty BRIEF in the Place family's voice, returned as a
 * STRUCTURED payload the iOS card renders directly:
 *   - summary:    where things stand ("3 quotes, $48k–$71k; 5 of 8 tasks open; permits not started").
 *   - highlights: 2–4 glanceable next-moves / watch-outs.
 *   - decision:   (only when `decisionFocus`) a short pros/cons read — which option stands out + why.
 *
 * Cache: stored as a `brief` map on the project doc (`households/{hid}/projects/{projectId}`) —
 * { summary, highlights, decision, generatedAt, model } — matching `FamilyDomain.ProjectBrief`, so it
 * round-trips through the normal project load (`Project.brief`) with no separate read path. A cached
 * brief is returned unless `force` is true (refresh button) or `decisionFocus` is requested and the
 * cache has no decision yet. Reuses the ANTHROPIC_API_KEY secret. No rate limiting (private app).
 */

const Anthropic = require("@anthropic-ai/sdk");
const admin = require("firebase-admin");

const MODEL = "claude-sonnet-5"; // matches the app's other reasoning calls; do NOT downgrade

/** Firestore Timestamp | Date | ISO string → Date, or null if unparseable. */
function toDate(value) {
  if (!value) return null;
  if (typeof value.toDate === "function") return value.toDate();
  const d = new Date(value);
  return isNaN(d.getTime()) ? null : d;
}

/** A short human date ("Aug 15, 2027") in the household's zone, or null. */
function formatDate(value) {
  const d = toDate(value);
  if (!d) return null;
  return new Intl.DateTimeFormat("en-US", {
    timeZone: "America/New_York",
    year: "numeric",
    month: "short",
    day: "numeric",
  }).format(d);
}

/** Trim + clamp a string field to `max` chars (best-effort tidy for the prompt). */
function clip(value, max) {
  const s = String(value == null ? "" : value).trim();
  return s.length > max ? s.slice(0, max) + "…" : s;
}

/** Human phase label mirroring FamilyDomain.ProjectPhase.displayName. */
const PHASE_LABEL = {
  dreaming: "Dreaming",
  researching: "Researching",
  deciding: "Deciding",
  inProgress: "In progress",
  done: "Done",
};

const BRIEF_TOOL = {
  name: "write_brief",
  description: "Write the family's structured brief for one project.",
  input_schema: {
    type: "object",
    properties: {
      summary: {
        type: "string",
        description:
          "The main paragraph — where things stand right now, in warm first-name voice. Lead with " +
          "concrete numbers when you have them (quote count/range, tasks open vs done, target date). " +
          "A few sentences, no headers, no preamble.",
      },
      highlights: {
        type: "array",
        items: { type: "string" },
        description:
          "2-4 short, glanceable bullets: the suggested next moves and any watch-outs, drawn from the " +
          "open tasks and obvious gaps. One idea each, no leading punctuation or bullet characters.",
      },
      decision: {
        type: "string",
        description:
          "ONLY when the user asked you to weigh the options: a short pros/cons read — which quote/" +
          "option stands out and WHY, the real tradeoffs, and a tentative recommendation (no false " +
          "certainty). Leave empty/omit for a plain brief.",
      },
    },
    required: ["summary", "highlights"],
  },
};

const SYSTEM_PROMPT = `You write a warm, witty, CONCISE brief for one family "project" in the Place family's private app, "Bacán".

A project is a big family undertaking (building a pool, Oliver's school search, a reno). You are given its current state — phase, target date, budget, tasks (open vs done), contacts, links, and gathered quote documents (vendor + amount + summary). Write a structured brief that helps Michael see where things stand and what to do next, via the write_brief tool:
- summary: STATE — where things stand right now. Be concrete and lead with numbers when you have them ("3 quotes in, $48k–$71k; 5 of 8 tasks still open; permit research not started").
- highlights: NEXT STEPS + watch-outs — 2-4 concrete moves drawn from the open tasks and the obvious gaps.
- decision: DECISION read — light considerations: which quote/option stands out and WHY, and the real tradeoffs. Populate this ONLY when the user's message asks you to weigh the options; otherwise leave it empty.

Voice & rules:
- Warm and a little witty; use first names; sentence case; at most one exclamation point in the whole brief.
- Keep it tight. No preamble, no "Here's your brief", no fluff, no corporate cheerleading, no emoji.
- Only reason from the data provided. NEVER invent quotes, amounts, tasks, contacts, or dates that aren't there. If a section is thin (e.g. no quotes yet), say so plainly and make the next step "go get them".
- Money: quote amounts are raw numbers — render them as friendly dollars ($48.5k, $71k). Budget is a target to compare quotes against.
- The family: Michael & Valentina, Oliver (3), Francis ("Famfis"), dogs Fajita & Sprinkle. Mention people only when the data does.`;

/**
 * Read one project + its linked documents from Firestore and shape a compact JSON context.
 * Returns { project, notFound } — `notFound` is true when the project doc doesn't exist.
 */
async function gatherContext(db, hid, projectId) {
  const householdRef = db.collection("households").doc(hid);
  const projectRef = householdRef.collection("projects").doc(projectId);

  const [projectSnap, docsSnap] = await Promise.all([
    projectRef.get(),
    householdRef
      .collection("documents")
      .where("projectIds", "array-contains", projectId)
      .get()
      .catch(() => null),
  ]);

  if (!projectSnap.exists) return { notFound: true };
  const p = projectSnap.data() || {};

  const tasks = Array.isArray(p.tasks) ? p.tasks : [];
  const openTasks = tasks.filter((t) => t && !t.isDone).map((t) => clip(t.title, 200)).filter(Boolean);
  const doneCount = tasks.length - tasks.filter((t) => t && !t.isDone).length;

  const contacts = (Array.isArray(p.contacts) ? p.contacts : [])
    .map((c) => ({
      name: clip(c.name, 120),
      role: clip(c.role, 80) || null,
      company: clip(c.company, 120) || null,
    }))
    .filter((c) => c.name);

  const links = (Array.isArray(p.links) ? p.links : [])
    .map((l) => ({ title: clip(l.title, 160) || null, url: clip(l.url, 300) }))
    .filter((l) => l.url);

  const quotes = [];
  if (docsSnap) {
    docsSnap.forEach((doc) => {
      const d = doc.data() || {};
      const amountNum = typeof d.amount === "number" && isFinite(d.amount) ? d.amount : null;
      quotes.push({
        title: clip(d.title, 160) || null,
        type: clip(d.type, 40) || null,
        vendor: clip(d.vendor, 160) || null,
        amount: amountNum,
        summary: clip(d.summary, 600) || null,
      });
    });
  }
  // Docs that carry a dollar amount read first (they anchor the STATE range).
  quotes.sort((a, b) => (b.amount || 0) - (a.amount || 0));

  const project = {
    name: clip(p.name, 200) || "Untitled project",
    phase: PHASE_LABEL[p.status] || "Dreaming",
    summary: clip(p.summary, 600) || null,
    targetDate: formatDate(p.targetDate),
    budgetTarget: typeof p.budgetTarget === "number" && isFinite(p.budgetTarget) ? p.budgetTarget : null,
    tasks: { open: openTasks, openCount: openTasks.length, doneCount, total: tasks.length },
    contacts,
    links,
    quotes: { count: quotes.length, items: quotes },
  };

  return { project };
}

/**
 * Ask Claude for the structured brief. Returns { summary, highlights, decision } or null on empty.
 * `decisionFocus` asks the model to weigh the options (populates `decision`).
 */
async function callClaude(apiKey, project, decisionFocus) {
  const client = new Anthropic({ apiKey });
  const payload = JSON.stringify(project, null, 2);
  const focus = decisionFocus
    ? "\n\nThe family is trying to DECIDE — weigh the gathered options and fill in the `decision` field " +
      "with a pros/cons read and a tentative recommendation."
    : "";

  const response = await client.messages.create({
    model: MODEL,
    max_tokens: 1200,
    system: SYSTEM_PROMPT,
    tools: [BRIEF_TOOL],
    tool_choice: { type: "tool", name: BRIEF_TOOL.name },
    messages: [
      {
        role: "user",
        content: `Here is the project's current state (money amounts are raw USD numbers). Write the brief.${focus}\n\n${payload}`,
      },
    ],
  });

  for (const block of response.content) {
    if (block.type === "tool_use" && block.name === BRIEF_TOOL.name) {
      const input = block.input || {};
      const summary = typeof input.summary === "string" ? input.summary.trim() : "";
      if (!summary) return null;
      const highlights = Array.isArray(input.highlights)
        ? input.highlights.map((h) => String(h || "").trim()).filter(Boolean)
        : [];
      const decisionRaw = typeof input.decision === "string" ? input.decision.trim() : "";
      return { summary, highlights, decision: decisionRaw || null };
    }
  }
  return null;
}

/**
 * Generate (or return the cached) structured brief for one project.
 * Cache lives as a `brief` map on the project doc; `force` regenerates, and a `decisionFocus`
 * request regenerates when the cache has no decision yet.
 * @returns {Promise<{ summary, highlights, decision, generatedAt, model, cached }>}
 */
async function generateProjectBrief({ db, hid, projectId, apiKey, force, decisionFocus }) {
  const projectRef = db.collection("households").doc(hid).collection("projects").doc(projectId);

  if (!force) {
    const snap = await projectRef.get();
    if (!snap.exists) throw new Error("Project not found");
    const existing = (snap.data() || {}).brief;
    const hasSummary = existing && typeof existing.summary === "string" && existing.summary.trim();
    const decisionSatisfied = !decisionFocus || (existing && typeof existing.decision === "string" && existing.decision.trim());
    if (hasSummary && decisionSatisfied) {
      console.log(`[projectBrief] cache hit hid=${hid} project=${projectId}`);
      const gen = toDate(existing.generatedAt);
      return {
        summary: existing.summary,
        highlights: Array.isArray(existing.highlights) ? existing.highlights : [],
        decision: typeof existing.decision === "string" && existing.decision.trim() ? existing.decision : null,
        generatedAt: gen ? gen.toISOString() : null,
        model: String(existing.model || MODEL),
        cached: true,
      };
    }
  }

  const { project, notFound } = await gatherContext(db, hid, projectId);
  if (notFound) throw new Error("Project not found");

  const brief = await callClaude(apiKey, project, decisionFocus);
  if (!brief) throw new Error("Claude returned no brief");

  await projectRef.set(
    {
      brief: {
        summary: brief.summary,
        highlights: brief.highlights,
        decision: brief.decision || null,
        model: MODEL,
        generatedAt: admin.firestore.FieldValue.serverTimestamp(),
      },
    },
    { merge: true }
  );
  console.log(`[projectBrief] generated hid=${hid} project=${projectId} force=${!!force} decision=${!!decisionFocus}`);

  return {
    summary: brief.summary,
    highlights: brief.highlights,
    decision: brief.decision || null,
    generatedAt: new Date().toISOString(),
    model: MODEL,
    cached: false,
  };
}

module.exports = { generateProjectBrief };
