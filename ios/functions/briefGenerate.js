"use strict";

/**
 * AI project brief for the Bacán `generateProjectBrief` Cloud Function (Projects PR4).
 *
 * Gathers one project's state server-side — phase, target date, budget, tasks (open vs done),
 * contacts, links, and its linked Family-Brain quote documents (vendor/amount/summary) — and asks
 * Claude (Sonnet 5) for a short, warm, witty BRIEF in the Place family's voice covering:
 *   (a) current STATE ("3 quotes, $48k–$71k; 5 of 8 tasks open; permit research still open"),
 *   (b) suggested NEXT STEPS,
 *   (c) light DECISION considerations (which option stands out + why, tradeoffs).
 *
 * Cache: the brief is stored as a `brief` map on the project doc
 * (`households/{hid}/projects/{projectId}`) — { text, generatedAt, model } — matching the schema the
 * roadmap anticipates ("the schema can grow … AI brief in later PRs"). The cached brief is returned
 * unless `force` is true (the refresh button), in which case it regenerates and overwrites. Reuses
 * the existing ANTHROPIC_API_KEY secret. No rate limiting (private app).
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
  description: "Write the family's brief for one project.",
  input_schema: {
    type: "object",
    properties: {
      text: {
        type: "string",
        description:
          "The full brief: a few SHORT paragraphs or tight bullets covering the project's current " +
          "state, suggested next steps, and light decision considerations. Warm, witty, concrete.",
      },
    },
    required: ["text"],
  },
};

const SYSTEM_PROMPT = `You write a warm, witty, CONCISE brief for one family "project" in the Place family's private app, "Bacán".

A project is a big family undertaking (building a pool, Oliver's school search, a reno). You are given its current state — phase, target date, budget, tasks (open vs done), contacts, links, and gathered quote documents (vendor + amount + summary). Write a brief that helps Michael see where things stand and what to do next.

Structure the brief in three light beats (no rigid headers required, but cover all three):
1. STATE — where things stand right now. Be concrete and lead with numbers when you have them ("3 quotes in, $48k–$71k; 5 of 8 tasks still open; permit research not started").
2. NEXT STEPS — 2-4 suggested concrete moves, drawn from the open tasks and the obvious gaps.
3. DECISION — light considerations: which quote/option stands out and WHY, and the real tradeoffs. Never pretend certainty you don't have.

Voice & rules:
- Warm and a little witty; use first names; sentence case; at most one exclamation point in the whole brief.
- Keep it tight — a few short paragraphs or bullets. No preamble, no "Here's your brief", no fluff, no corporate cheerleading, no emoji.
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

/** Ask Claude for the brief text. Returns a trimmed string, or null on empty output. */
async function callClaude(apiKey, project) {
  const client = new Anthropic({ apiKey });
  const payload = JSON.stringify(project, null, 2);

  const response = await client.messages.create({
    model: MODEL,
    max_tokens: 1200,
    system: SYSTEM_PROMPT,
    tools: [BRIEF_TOOL],
    tool_choice: { type: "tool", name: BRIEF_TOOL.name },
    messages: [
      {
        role: "user",
        content: `Here is the project's current state (money amounts are raw USD numbers). Write the brief.\n\n${payload}`,
      },
    ],
  });

  for (const block of response.content) {
    if (block.type === "tool_use" && block.name === BRIEF_TOOL.name) {
      const text = typeof (block.input || {}).text === "string" ? block.input.text.trim() : "";
      return text || null;
    }
  }
  return null;
}

/**
 * Generate (or return the cached) brief for one project.
 * Cache lives as a `brief` map on the project doc; `force` regenerates and overwrites.
 * @returns {Promise<{ text: string, generatedAt: string|null, model: string, cached: boolean }>}
 */
async function generateProjectBrief({ db, hid, projectId, apiKey, force }) {
  const projectRef = db.collection("households").doc(hid).collection("projects").doc(projectId);

  if (!force) {
    const snap = await projectRef.get();
    if (!snap.exists) throw new Error("Project not found");
    const existing = (snap.data() || {}).brief;
    if (existing && typeof existing.text === "string" && existing.text.trim()) {
      console.log(`[projectBrief] cache hit hid=${hid} project=${projectId}`);
      const gen = toDate(existing.generatedAt);
      return {
        text: existing.text,
        generatedAt: gen ? gen.toISOString() : null,
        model: String(existing.model || MODEL),
        cached: true,
      };
    }
  }

  const { project, notFound } = await gatherContext(db, hid, projectId);
  if (notFound) throw new Error("Project not found");

  const text = await callClaude(apiKey, project);
  if (!text) throw new Error("Claude returned no brief");

  await projectRef.set(
    {
      brief: {
        text,
        model: MODEL,
        generatedAt: admin.firestore.FieldValue.serverTimestamp(),
      },
    },
    { merge: true }
  );
  console.log(`[projectBrief] generated hid=${hid} project=${projectId} force=${!!force}`);

  return { text, generatedAt: new Date().toISOString(), model: MODEL, cached: false };
}

module.exports = { generateProjectBrief };
