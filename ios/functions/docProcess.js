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
const STORAGE_BUCKET = "menere.firebasestorage.app";

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
    // Member roster (name → uid), so linkedMemberNames can be mapped to ids.
    const membersSnap = await db.collection("households").doc(hid).collection("members").get();
    const idByLowerName = {};
    const memberNames = [];
    membersSnap.forEach((m) => {
      const name = String((m.data() || {}).name || "").trim();
      if (name) {
        idByLowerName[name.toLowerCase()] = m.id;
        memberNames.push(name);
      }
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
    return { processed: true, type };
  } catch (err) {
    // Never leave a document stuck pending.
    console.error(`[docs] failed ${docId}: ${err.message}`);
    await docRef.set({ processingState: "failed" }, { merge: true });
    throw err;
  }
}

module.exports = { processDocument };
