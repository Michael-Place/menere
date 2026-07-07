"use strict";

/**
 * AI document processing for the Bacán/Menere `processDocument` Cloud Function ("the Family Brain").
 *
 * Given a `households/{hid}/documents/{docId}` in `processingState: 'pending'`, this downloads the
 * document's uploaded pages from Storage (JPEG images, or a single native PDF), sends them to Claude
 * (Sonnet 5 — extraction accuracy matters more than cost here) with a tool-use schema, and writes the
 * structured fields back + flips `processingState` to `'processed'`. Any failure flips it to
 * `'failed'` (never left stuck pending) and logs why. Reuses the existing `ANTHROPIC_API_KEY` secret.
 *
 * Title policy: the AI title overwrites the stored one ONLY when the current title starts with the
 * C1 default prefix "Scanned " — user-typed titles win.
 *
 * Dates are interpreted in America/New_York and stored at noon UTC so the calendar day is preserved
 * across US timezones.
 */

const Anthropic = require("@anthropic-ai/sdk");
const admin = require("firebase-admin");

const TZ = "America/New_York";
const MODEL = "claude-sonnet-5"; // user-chosen for extraction accuracy; do NOT downgrade
// Cheap secondary pass that guesses which family Project a freshly-extracted doc belongs to.
// Extraction stays on Sonnet; this routing decision matches the app's other lightweight classifiers.
const PROJECT_MATCH_MODEL = "claude-haiku-4-5-20251001";
const STORAGE_BUCKET = "menere.firebasestorage.app";

/** Project phases that are still "active" (worth suggesting docs into). Only `done` is excluded. */
const ACTIVE_PROJECT_PHASES = new Set(["dreaming", "researching", "deciding", "inProgress"]);

/** The 7 Document.type raw values (must mirror FamilyDomain.DocumentType). */
const DOC_TYPES = ["receipt", "medical", "school", "pet", "tax", "manual", "other"];

const DOCUMENT_TOOL = {
  name: "record_document",
  description: "Record the structured breakdown of a scanned family document.",
  input_schema: {
    type: "object",
    additionalProperties: false,
    properties: {
      title: {
        type: "string",
        description: "A short, human title for the document (e.g. 'Green Thumb Garden Center receipt').",
      },
      type: {
        type: "string",
        enum: DOC_TYPES,
        description: "The single best-fitting document type from the allowed values.",
      },
      tags: {
        type: "array",
        items: { type: "string" },
        description: "3-8 short lowercase tags for search (e.g. 'garden', 'plants', 'receipt').",
      },
      summary: {
        type: "string",
        description: "A factual 1-2 sentence summary in a neutral voice. No invented details.",
      },
      vendor: {
        type: "string",
        description: "The store / clinic / school / issuer as printed, if present.",
      },
      amount: {
        type: "number",
        description: "The total monetary amount (a single number, no currency symbol), if present.",
      },
      docDate: {
        type: "string",
        description: "The date printed on the document (ISO YYYY-MM-DD, America/New_York), if explicit.",
      },
      dueDate: {
        type: "string",
        description: "An actionable due date (ISO YYYY-MM-DD), only if explicitly present.",
      },
      expiryDate: {
        type: "string",
        description: "An expiry date, e.g. a warranty or vaccination cert (ISO YYYY-MM-DD), if present.",
      },
      linkedMemberNames: {
        type: "array",
        items: { type: "string" },
        description: "Household member names that LITERALLY appear in the document. Empty if none.",
      },
      linkedPetNames: {
        type: "array",
        items: { type: "string" },
        description: "Household pet names that LITERALLY appear in the document (e.g. a patient name on a vet record). Empty if none.",
      },
      extractedText: {
        type: "string",
        description: "A faithful full-text transcription of the document in natural reading order.",
      },
    },
    required: ["title", "type", "tags", "summary", "extractedText"],
  },
};

const SYSTEM_PROMPT = `You break down a scanned family document into structured fields for a private family app's "second brain".

Rules:
- NEVER invent fields that are not actually present in the document. If something isn't there, omit it.
- \`type\` MUST be exactly one of: receipt, medical, school, pet, tax, manual, other. Vet / veterinary / animal-hospital records (vaccination certificates, pet exam paperwork) are type 'pet'.
- \`tags\`: 3-8 short lowercase tags useful for later search.
- \`summary\`: 1-2 short, factual sentences in a neutral voice — no marketing, no speculation.
- Dates only when explicit or unambiguous; format as ISO YYYY-MM-DD interpreted in America/New_York. Do not guess a year.
- \`amount\` is a single number (the total) with no currency symbol.
- \`linkedMemberNames\`: include a household member's name ONLY if it literally appears in the document text. The household's member names are provided to you; do not add names that aren't printed on the document.
- \`linkedPetNames\`: include a household pet's name ONLY if it literally appears in the document (e.g. a "Patient" name on a vet record). The household's pet names are provided to you; do not add names that aren't printed on the document.
- \`extractedText\`: transcribe the document faithfully in reading order — this powers full-text search.`;

/** Firestore Timestamp at noon UTC for an ISO YYYY-MM-DD string, or null if unparseable. */
function toTimestamp(value) {
  if (typeof value !== "string") return null;
  const m = value.trim().match(/^(\d{4})-(\d{2})-(\d{2})$/);
  if (!m) return null;
  const d = new Date(`${m[1]}-${m[2]}-${m[3]}T12:00:00Z`);
  if (isNaN(d.getTime())) return null;
  return admin.firestore.Timestamp.fromDate(d);
}

/** Build Claude content blocks by downloading each page from Storage. */
async function buildContentBlocks(bucket, pagePaths) {
  const blocks = [];
  for (const path of pagePaths) {
    if (!path) continue;
    const [buf] = await bucket.file(path).download();
    const data = buf.toString("base64");
    if (path.toLowerCase().endsWith(".pdf")) {
      // The API natively accepts a PDF as a `document` content block.
      blocks.push({
        type: "document",
        source: { type: "base64", media_type: "application/pdf", data },
      });
    } else {
      blocks.push({
        type: "image",
        source: { type: "base64", media_type: "image/jpeg", data },
      });
    }
  }
  return blocks;
}

/** Ask Claude for the structured document breakdown. Returns the tool input object, or throws. */
async function callClaude(apiKey, contentBlocks, memberNames, petNames) {
  const client = new Anthropic({ apiKey });
  const roster = memberNames.length
    ? `Household member names (for linkedMemberNames matching): ${memberNames.join(", ")}.`
    : "There are no household member names to match.";
  const pets = petNames.length
    ? `Household pet names (for linkedPetNames matching): ${petNames.join(", ")}.`
    : "There are no household pet names to match.";

  const response = await client.messages.create({
    model: MODEL,
    max_tokens: 8192,
    thinking: { type: "disabled" }, // deterministic single-shot extraction with a forced tool
    system: SYSTEM_PROMPT,
    tools: [DOCUMENT_TOOL],
    tool_choice: { type: "tool", name: DOCUMENT_TOOL.name },
    messages: [
      {
        role: "user",
        content: [
          ...contentBlocks,
          {
            type: "text",
            text: `Break down this document. Times/dates are ${TZ}. ${roster} ${pets}`,
          },
        ],
      },
    ],
  });

  for (const block of response.content) {
    if (block.type === "tool_use" && block.name === DOCUMENT_TOOL.name) {
      return block.input || {};
    }
  }
  throw new Error("Claude returned no record_document tool call");
}

// ---------------------------------------------------------------------------
// Project auto-tagging (PR2-A): suggest which active Project a doc belongs to.
// ---------------------------------------------------------------------------

const PROJECT_MATCH_TOOL = {
  name: "match_project",
  description: "Pick which family project (if any) a scanned document most likely belongs to.",
  input_schema: {
    type: "object",
    additionalProperties: false,
    properties: {
      projectId: {
        type: ["string", "null"],
        description:
          "The id of the SINGLE best-matching project, copied exactly from the provided list. " +
          "Use null when no project is a clear, confident match — most documents belong to no project.",
      },
      confidence: {
        type: "string",
        enum: ["low", "medium", "high"],
        description: "How confident you are that this document belongs to the chosen project.",
      },
    },
    required: ["projectId", "confidence"],
  },
};

const PROJECT_MATCH_SYSTEM = `You file a scanned family document against the family's ongoing "projects" (big undertakings like building a pool or moving a kid to a new school).

You are given a numbered list of active projects (id, name, summary) and a summary of one document (title, type, vendor, tags, summary, and some text). Decide which ONE project the document most likely belongs to, if any.

Rules:
- Return projectId ONLY when the document clearly relates to that project (e.g. a pool-builder quote → the "Pool" project). Copy the id EXACTLY from the list.
- Most documents belong to NO project. When there is no obvious, confident fit, return projectId=null.
- Never guess to be helpful. A generic grocery receipt, a routine medical bill, or an unrelated manual belongs to no project.
- Match on real signal: vendor/company, subject matter, and named things — not superficial word overlap.`;

/**
 * Truncate a string to a byte-ish budget of characters (defensive, keeps the match prompt small).
 */
function clip(value, max) {
  const s = String(value || "").trim();
  return s.length > max ? s.slice(0, max) : s;
}

/**
 * Best-effort project suggestion. Reads active projects, asks Claude (haiku) for the single best
 * confident match, and sets `document.suggestedProjectId` when there is one. NEVER throws — a failure
 * here must not fail the (already-succeeded) extraction, and NEVER writes `projectIds` (that is the
 * user's in-app confirm). Idempotent: skips entirely if the doc already has confirmed `projectIds`.
 *
 * @returns {Promise<string|null>} the suggested project id that was written, or null if none.
 */
async function suggestProjectForDocument({ db, hid, docRef, existing, fields, apiKey }) {
  try {
    // Never touch a user-confirmed doc: if it's already filed into a project, leave it alone.
    if (Array.isArray(existing.projectIds) && existing.projectIds.length > 0) return null;

    const projectsSnap = await db.collection("households").doc(hid).collection("projects").get();
    const projects = [];
    projectsSnap.forEach((p) => {
      const data = p.data() || {};
      const name = String(data.name || "").trim();
      if (!name) return;
      const phase = String(data.status || "dreaming");
      if (!ACTIVE_PROJECT_PHASES.has(phase)) return; // skip finished projects
      projects.push({ id: p.id, name, summary: String(data.summary || "").trim() });
    });
    if (projects.length === 0) return null; // nothing to match against

    // Compose a compact document signal from the just-extracted fields (+ the stored title).
    const title = clip(fields.title || existing.title, 200);
    const docText =
      `Title: ${title || "(none)"}\n` +
      `Type: ${fields.type || "other"}\n` +
      `Vendor: ${clip(fields.vendor, 200) || "(none)"}\n` +
      `Tags: ${(Array.isArray(fields.tags) ? fields.tags : []).join(", ") || "(none)"}\n` +
      `Summary: ${clip(fields.summary, 800) || "(none)"}\n` +
      `Text: ${clip(fields.extractedText, 2000) || "(none)"}`;

    const projectList = projects
      .map((p, i) => `${i + 1}. id="${p.id}" name="${p.name}"${p.summary ? ` — ${p.summary}` : ""}`)
      .join("\n");

    const client = new Anthropic({ apiKey });
    const response = await client.messages.create({
      model: PROJECT_MATCH_MODEL,
      max_tokens: 256,
      system: PROJECT_MATCH_SYSTEM,
      tools: [PROJECT_MATCH_TOOL],
      tool_choice: { type: "tool", name: PROJECT_MATCH_TOOL.name },
      messages: [
        {
          role: "user",
          content: [
            {
              type: "text",
              text: `Active projects:\n${projectList}\n\nDocument:\n${docText}\n\nWhich project (if any) does this document belong to?`,
            },
          ],
        },
      ],
    });

    let out = null;
    for (const block of response.content) {
      if (block.type === "tool_use" && block.name === PROJECT_MATCH_TOOL.name) {
        out = block.input || {};
        break;
      }
    }
    if (!out) return null;

    const matchedId = typeof out.projectId === "string" ? out.projectId.trim() : "";
    const confidence = String(out.confidence || "low");
    const isActiveMatch = projects.some((p) => p.id === matchedId);
    // Confidence gate: only a medium/high match to a real active project is written.
    if (!matchedId || !isActiveMatch || confidence === "low") return null;

    await docRef.set({ suggestedProjectId: matchedId }, { merge: true });
    console.log(`[docs] suggested project ${matchedId} for ${docRef.id} (confidence=${confidence})`);
    return matchedId;
  } catch (err) {
    // Best-effort only: never fail the document over a suggestion miss.
    console.error(`[docs] project-match skipped for ${docRef.id}: ${err.message}`);
    return null;
  }
}

/**
 * Process one document: download pages → Claude → write fields + processingState.
 * @returns {Promise<{ processed: true, type: string }>}
 */
async function processDocument({ db, hid, docId, apiKey }) {
  const docRef = db.collection("households").doc(hid).collection("documents").doc(docId);
  const snap = await docRef.get();
  if (!snap.exists) throw new Error(`document ${docId} not found under household ${hid}`);
  const existing = snap.data() || {};
  const pagePaths = Array.isArray(existing.pagePaths) ? existing.pagePaths : [];
  if (pagePaths.length === 0) throw new Error(`document ${docId} has no pages to process`);

  try {
    // Member roster (name → uid), so linkedMemberNames can be mapped to ids. Each member may carry
    // BOTH an everyday display `name` (often a nickname, e.g. "Migueluh") and a real/legal
    // `fullName` (e.g. "Michael"). We index BOTH under the member's id so a document that names
    // either one links to that member, and we surface both to Claude for literal matching.
    const membersSnap = await db.collection("households").doc(hid).collection("members").get();
    const idByLowerName = {};
    const memberNames = [];
    membersSnap.forEach((m) => {
      const data = m.data() || {};
      [data.name, data.fullName].forEach((raw) => {
        const n = String(raw || "").trim();
        if (!n) return;
        idByLowerName[n.toLowerCase()] = m.id;
        if (!memberNames.includes(n)) memberNames.push(n);
      });
    });

    // Pet roster (name → careItem id) — pets are CareItems with kind == "pet". Their names go to
    // Claude for linkedPetNames matching, mirroring members; matched names map to careItem ids.
    const careSnap = await db.collection("households").doc(hid).collection("careItems").get();
    const petIdByLowerName = {};
    const petNames = [];
    careSnap.forEach((c) => {
      const data = c.data() || {};
      if (data.kind !== "pet") return;
      const name = String(data.name || "").trim();
      if (name) {
        petIdByLowerName[name.toLowerCase()] = c.id;
        petNames.push(name);
      }
    });

    const bucket = admin.storage().bucket(STORAGE_BUCKET);
    const contentBlocks = await buildContentBlocks(bucket, pagePaths);
    const out = await callClaude(apiKey, contentBlocks, memberNames, petNames);

    // Normalize type.
    const type = DOC_TYPES.includes(out.type) ? out.type : "other";

    // Tags: lowercased, trimmed, deduped.
    const tags = [];
    const seenTags = new Set();
    const addTag = (t) => {
      const tag = String(t || "").trim().toLowerCase();
      if (tag && !seenTags.has(tag)) {
        seenTags.add(tag);
        tags.push(tag);
      }
    };
    (Array.isArray(out.tags) ? out.tags : []).forEach(addTag);

    // Map linkedMemberNames → ids; unmatched names fall into tags instead.
    const linkedMemberIds = [];
    (Array.isArray(out.linkedMemberNames) ? out.linkedMemberNames : []).forEach((rawName) => {
      const name = String(rawName || "").trim();
      if (!name) return;
      const uid = idByLowerName[name.toLowerCase()];
      if (uid) {
        if (!linkedMemberIds.includes(uid)) linkedMemberIds.push(uid);
      } else {
        addTag(name);
      }
    });

    // Map linkedPetNames → careItem ids; unmatched pet names fall into tags (mirroring members).
    const linkedPetIds = [];
    (Array.isArray(out.linkedPetNames) ? out.linkedPetNames : []).forEach((rawName) => {
      const name = String(rawName || "").trim();
      if (!name) return;
      const petId = petIdByLowerName[name.toLowerCase()];
      if (petId) {
        if (!linkedPetIds.includes(petId)) linkedPetIds.push(petId);
      } else {
        addTag(name);
      }
    });

    const update = {
      type,
      tags,
      linkedMemberIds,
      linkedPetIds,
      summary: String(out.summary || "").trim(),
      extractedText: String(out.extractedText || "").trim(),
      processingState: "processed",
    };

    // Title policy: overwrite ONLY the C1 default ("Scanned …"). User-typed titles win.
    const aiTitle = String(out.title || "").trim();
    const currentTitle = String(existing.title || "");
    if (aiTitle && currentTitle.startsWith("Scanned ")) {
      update.title = aiTitle;
    }

    if (typeof out.vendor === "string" && out.vendor.trim()) update.vendor = out.vendor.trim();
    if (typeof out.amount === "number" && isFinite(out.amount)) update.amount = out.amount;

    const docDate = toTimestamp(out.docDate);
    if (docDate) update.docDate = docDate;
    const dueDate = toTimestamp(out.dueDate);
    if (dueDate) update.dueDate = dueDate;
    const expiryDate = toTimestamp(out.expiryDate);
    if (expiryDate) update.expiryDate = expiryDate;

    await docRef.set(update, { merge: true });
    console.log(`[docs] processed ${docId} type=${type} pets=${linkedPetIds.length}`);

    // Additive PR2-A step: after extraction, suggest which active Project this doc belongs to.
    // Best-effort + non-throwing — a suggestion miss never affects the (already-written) extraction.
    // Only sets `suggestedProjectId`; never `projectIds` (the user's in-app confirm).
    await suggestProjectForDocument({ db, hid, docRef, existing, fields: update, apiKey });

    return { processed: true, type };
  } catch (err) {
    // Never leave a document stuck pending.
    console.error(`[docs] failed ${docId}: ${err.message}`);
    await docRef.set({ processingState: "failed" }, { merge: true });
    throw err;
  }
}

module.exports = { processDocument, suggestProjectForDocument };
