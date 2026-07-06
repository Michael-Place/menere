"use strict";

/**
 * V5-email — full AI-routed email ingestion for Bacán ("the open front door").
 *
 * The `receiveEmail` Postmark webhook (index.js) forwards every inbound email through here. Where the
 * old handler only ever wrote CALENDAR EVENTS, this module turns one email into the RIGHT destination(s):
 *
 *   • a doc/receipt/PDF ATTACHMENT → upload to Storage + create a Family-Brain `documents/{id}` and run
 *     `processDocument` (Claude vision) over it.
 *   • an EVENT-shaped email (school newsletter, appointment, reservation) → `eventExtract.js` → events
 *     (the existing path, preserved), AND if it also carries a doc, file the doc too.
 *   • an ORDER / shipping confirmation → a text Brain doc tagged shipping/order (tracking in the summary).
 *   • general / note → the best module (a list item, a memory, or — when unsure — a Brain doc).
 *
 * Design principles:
 *   1. Never regress the event path. If classification fails, we fall back to event-extraction + a Brain
 *      doc so nothing is ever silently dropped.
 *   2. Be conservative: when the router is unsure, it files a Family-Brain doc (searchable, non-destructive)
 *      rather than guessing a list/memory write.
 *   3. Everything created is stamped `source: "email"` so it is traceable (and cleanly removable).
 *
 * Household addressing (see `resolveHousehold`): a family forwards mail to a stable alias whose code maps
 * to their household — `hub+{code}@<domain>` (plus-addressing), a Postmark `MailboxHash`, or the bare local
 * part. The code resolves against `households/{hid}.inboundEmailCode` first, then the legacy `inviteCode`
 * (backwards-compatible), then a SENDER fallback (a known member's / configured From address). No match →
 * dropped safely by the caller.
 */

const Anthropic = require("@anthropic-ai/sdk");
const admin = require("firebase-admin");
const { extractEventsFromText } = require("./eventExtract");
const { processDocument } = require("./docProcess");

const STORAGE_BUCKET = "menere.firebasestorage.app";
const CLASSIFIER_MODEL = "claude-haiku-4-5-20251001"; // cheap routing decision; extraction stays on Sonnet
const DOC_TYPES = ["receipt", "medical", "school", "pet", "tax", "manual", "other"];

// ---------------------------------------------------------------------------
// Household addressing / resolution
// ---------------------------------------------------------------------------

/**
 * Pull the addressing code out of a Postmark inbound payload's recipient. Supports:
 *   • Postmark default:  <serverhash>+{CODE}@inbound.postmarkapp.com   (payload.MailboxHash = CODE)
 *   • custom + alias:    hub+{CODE}@<your-domain>                       (local part after "+")
 *   • bare custom:       {CODE}@inbox.<your-domain>                     (whole local part)
 * Returns the raw (un-cased) code, or "".
 */
function recipientCode(payload) {
  const toAddress =
    (Array.isArray(payload.ToFull) && payload.ToFull[0] && payload.ToFull[0].Email) ||
    payload.To ||
    payload.OriginalRecipient ||
    "";
  const rawLocal = String(toAddress).split("@")[0] || "";
  const plusHash = rawLocal.includes("+") ? rawLocal.split("+").pop() : "";
  return String(payload.MailboxHash || plusHash || rawLocal).trim();
}

/** The sender's email address (lower-cased) from a Postmark payload, or "". */
function senderEmail(payload) {
  const from =
    (payload.FromFull && payload.FromFull.Email) ||
    payload.From ||
    "";
  // `From` can be "Name <a@b.com>"; grab the address.
  const m = String(from).match(/<([^>]+)>/);
  return String(m ? m[1] : from).trim().toLowerCase();
}

/**
 * Resolve an inbound email to a household. Order:
 *   1. addressing code → `inboundEmailCode` (the stable forwarding code)
 *   2. addressing code → `inviteCode` (legacy — the original receiveEmail behavior, preserved)
 *   3. sender fallback → a household whose `config/inbound.senderEmails[]` or a member's `email` matches
 * @returns {Promise<{hid:string, via:string, code:string|null}|null>} null → drop safely (caller logs).
 */
async function resolveHousehold(db, payload) {
  const households = db.collection("households");
  const rawCode = recipientCode(payload);
  const code = rawCode ? rawCode.toUpperCase() : "";

  if (code) {
    let snap = await households.where("inboundEmailCode", "==", code).limit(1).get();
    if (!snap.empty) return { hid: snap.docs[0].id, via: "inboundEmailCode", code };
    snap = await households.where("inviteCode", "==", code).limit(1).get();
    if (!snap.empty) return { hid: snap.docs[0].id, via: "inviteCode", code };
  }

  const from = senderEmail(payload);
  if (from) {
    // Private app: usually one household. Scan them for a configured/known sender address.
    const all = await households.get();
    for (const hh of all.docs) {
      try {
        const inboundSnap = await hh.ref.collection("config").doc("inbound").get();
        const senders = inboundSnap.exists && Array.isArray(inboundSnap.data().senderEmails)
          ? inboundSnap.data().senderEmails.map((s) => String(s).toLowerCase())
          : [];
        if (senders.includes(from)) return { hid: hh.id, via: "sender", code: null };
      } catch (_) { /* keep scanning */ }
      try {
        const membersSnap = await hh.ref.collection("members").get();
        const hit = membersSnap.docs.some((m) => {
          const e = String((m.data() || {}).email || "").toLowerCase();
          return e && e === from;
        });
        if (hit) return { hid: hh.id, via: "sender", code: null };
      } catch (_) { /* keep scanning */ }
    }
  }

  return null;
}

// ---------------------------------------------------------------------------
// Classification (one cheap Claude call)
// ---------------------------------------------------------------------------

const CLASSIFY_TOOL = {
  name: "route_email",
  description: "Classify a forwarded family email and pick where it should be filed.",
  input_schema: {
    type: "object",
    additionalProperties: false,
    properties: {
      category: {
        type: "string",
        enum: ["receipt", "event", "order", "list", "memory", "note"],
        description:
          "The single best primary category. 'receipt' = a purchase/bill/statement/record. " +
          "'event' = an invite/appointment/reservation/school-notice with a date. 'order' = a " +
          "shipping/order/delivery confirmation. 'list' = an explicit shopping/to-do list to add. " +
          "'memory' = a personal keepsake/photo note about the kids/family. 'note' = anything else.",
      },
      isEvent: {
        type: "boolean",
        description:
          "True if the email contains one or more concrete dated events worth putting on the family " +
          "calendar (even if the primary category is receipt/order/note — e.g. a school newsletter " +
          "that is mostly info but names a field-trip date).",
      },
      documentType: {
        type: "string",
        enum: DOC_TYPES,
        description: "If filed as a Brain document, its type. Vet records are 'pet'.",
      },
      title: { type: "string", description: "A short human title for the item." },
      summary: { type: "string", description: "A neutral 1-2 sentence factual summary. No invention." },
      vendor: { type: ["string", "null"], description: "The store/sender/issuer if present, else null." },
      amount: { type: ["number", "null"], description: "A total monetary amount if present, else null." },
      tracking: { type: ["string", "null"], description: "A shipping tracking number/carrier if present, else null." },
      tags: { type: "array", items: { type: "string" }, description: "3-8 short lowercase search tags." },
      listName: { type: ["string", "null"], description: "For category 'list', the target list name if named, else null." },
      listItems: { type: "array", items: { type: "string" }, description: "For category 'list', the individual items to add." },
      confidence: { type: "string", enum: ["low", "medium", "high"], description: "Confidence in the primary category." },
    },
    required: ["category", "isEvent", "documentType", "title", "summary", "tags", "confidence"],
  },
};

const CLASSIFY_SYSTEM = `You are the router for a private family app's "open front door" — a family forwards an email and you decide where it belongs.

Pick ONE primary category and set isEvent independently:
- receipt: a purchase receipt, bill, statement, invoice, or record to keep.
- event: an invitation, appointment, reservation, or school notice built around a date/time.
- order: an order/shipping/delivery confirmation (has an order # or tracking).
- list: an explicit shopping list or to-do list the family clearly wants added to a list.
- memory: a personal keepsake — a note/photo about the kids or a family moment.
- note: anything else / general.

Rules:
- Be conservative. Only choose 'list' when the email is plainly a list of things to add, and only choose
  'memory' when it is clearly a personal keepsake. When unsure, choose 'note'.
- documentType MUST be one of: receipt, medical, school, pet, tax, manual, other. Vet/animal records are 'pet'.
- summary: 1-2 short factual sentences, neutral voice, no marketing, no invented facts.
- Extract vendor/amount/tracking ONLY if actually present; otherwise null.
- isEvent is independent: set it true whenever there is a concrete dated event worth calendaring.`;

/**
 * Classify a forwarded email. Returns a normalized decision object. On any failure returns a safe
 * default (`note`, isEvent:true, low confidence) so the caller still extracts events + files a Brain doc.
 */
async function classifyEmail({ apiKey, subject, body, fromName, hasAttachment }) {
  const text =
    `From: ${fromName || "unknown"}\n` +
    `Subject: ${subject || "(no subject)"}\n` +
    `Has file attachment: ${hasAttachment ? "yes" : "no"}\n\n` +
    `${body || ""}`.slice(0, 12000);

  try {
    const client = new Anthropic({ apiKey });
    const response = await client.messages.create({
      model: CLASSIFIER_MODEL,
      max_tokens: 1024,
      system: CLASSIFY_SYSTEM,
      tools: [CLASSIFY_TOOL],
      tool_choice: { type: "tool", name: CLASSIFY_TOOL.name },
      messages: [{ role: "user", content: text }],
    });
    for (const block of response.content) {
      if (block.type === "tool_use" && block.name === CLASSIFY_TOOL.name) {
        return normalizeClassification(block.input || {});
      }
    }
  } catch (err) {
    console.error(`[email] classification failed: ${err.message}`);
  }
  return normalizeClassification({ category: "note", isEvent: true, confidence: "low" });
}

function normalizeClassification(raw) {
  const category = ["receipt", "event", "order", "list", "memory", "note"].includes(raw.category)
    ? raw.category
    : "note";
  const documentType = DOC_TYPES.includes(raw.documentType) ? raw.documentType : "other";
  const confidence = ["low", "medium", "high"].includes(raw.confidence) ? raw.confidence : "low";
  return {
    category,
    isEvent: raw.isEvent !== false, // default true so we never miss an event
    documentType,
    title: String(raw.title || "").trim(),
    summary: String(raw.summary || "").trim(),
    vendor: typeof raw.vendor === "string" && raw.vendor.trim() ? raw.vendor.trim() : null,
    amount: typeof raw.amount === "number" && isFinite(raw.amount) ? raw.amount : null,
    tracking: typeof raw.tracking === "string" && raw.tracking.trim() ? raw.tracking.trim() : null,
    tags: Array.isArray(raw.tags)
      ? raw.tags.map((t) => String(t || "").trim().toLowerCase()).filter(Boolean)
      : [],
    listName: typeof raw.listName === "string" && raw.listName.trim() ? raw.listName.trim() : null,
    listItems: Array.isArray(raw.listItems)
      ? raw.listItems.map((i) => String(i || "").trim()).filter(Boolean)
      : [],
    confidence,
  };
}

// ---------------------------------------------------------------------------
// Destination writers (each returns a decision breadcrumb)
// ---------------------------------------------------------------------------

const now = () => admin.firestore.Timestamp.now();
const newId = () => admin.firestore().collection("_").doc().id;

/** Doc-like Postmark attachments: PDFs and non-inline images (skip tiny inline signature images). */
function documentAttachments(payload) {
  const list = Array.isArray(payload.Attachments) ? payload.Attachments : [];
  return list.filter((a) => {
    const ct = String(a.ContentType || "").toLowerCase();
    const len = Number(a.ContentLength) || (a.Content ? Buffer.byteLength(a.Content, "base64") : 0);
    if (ct.startsWith("application/pdf")) return true;
    // Images: keep only non-inline (no ContentID) or reasonably large ones (real receipts, not signatures).
    if (ct.startsWith("image/")) return !a.ContentID || len > 8000;
    return false;
  });
}

/**
 * Upload each attachment to Storage, create a pending `documents/{id}`, and run `processDocument`
 * (Claude vision) over it. Returns one breadcrumb per document created.
 */
async function fileAttachments({ db, hid, apiKey, attachments, uploadedBy }) {
  const bucket = admin.storage().bucket(STORAGE_BUCKET);
  const docsCol = db.collection("households").doc(hid).collection("documents");
  const results = [];

  for (const att of attachments) {
    const id = newId();
    const isPdf = String(att.ContentType || "").toLowerCase().startsWith("application/pdf");
    const ext = isPdf ? "pdf" : "jpg";
    const objectPath = `households/${hid}/documents/${id}/${isPdf ? "document.pdf" : "page-0.jpg"}`;
    const buf = Buffer.from(String(att.Content || ""), "base64");

    await bucket.file(objectPath).save(buf, {
      contentType: isPdf ? "application/pdf" : "image/jpeg",
      resumable: false,
    });

    const name = String(att.Name || `attachment.${ext}`);
    await docsCol.doc(id).set({
      id,
      title: `Scanned ${name}`, // "Scanned " prefix → processDocument may overwrite with an AI title
      type: "other",
      tags: [],
      summary: "",
      extractedText: "",
      linkedMemberIds: [],
      linkedPetIds: [],
      pagePaths: [objectPath],
      processingState: "pending",
      uploadedBy: uploadedBy || null,
      source: "email",
      createdAt: now(),
    });

    let processedType = "other";
    let processed = false;
    try {
      const out = await processDocument({ db, hid, docId: id, apiKey });
      processedType = out.type || "other";
      processed = true;
    } catch (err) {
      console.error(`[email] processDocument failed for ${id}: ${err.message}`);
      // Document remains (marked 'failed' by processDocument) — still filed in the Brain.
    }
    results.push({
      destination: "brain-doc",
      via: "attachment",
      docId: id,
      name,
      processed,
      type: processedType,
    });
  }
  return results;
}

/** Create a text-only Family-Brain document straight from the classifier (no vision needed). */
async function fileTextDocument({ db, hid, classification, subject, body, uploadedBy, extraTags }) {
  const id = newId();
  const tags = [...new Set([...(classification.tags || []), ...(extraTags || [])].map((t) => String(t).toLowerCase()).filter(Boolean))];
  let summary = classification.summary || subject || "Forwarded email";
  if (classification.tracking) summary = `${summary} Tracking: ${classification.tracking}.`;

  const doc = {
    id,
    title: classification.title || subject || "Forwarded email",
    type: classification.documentType || "other",
    tags,
    summary,
    extractedText: `${subject || ""}\n\n${body || ""}`.trim(),
    linkedMemberIds: [],
    linkedPetIds: [],
    pagePaths: [],
    processingState: "processed",
    uploadedBy: uploadedBy || null,
    source: "email",
    createdAt: now(),
  };
  if (classification.vendor) doc.vendor = classification.vendor;
  if (typeof classification.amount === "number") doc.amount = classification.amount;

  await db.collection("households").doc(hid).collection("documents").doc(id).set(doc);
  return { destination: "brain-doc", via: "text", docId: id, type: doc.type };
}

/** Extract + write calendar events (the original path). Returns a breadcrumb with the count. */
async function fileEvents({ db, hid, apiKey, subject, body, timezone }) {
  const text = `${subject || ""}\n\n${body || ""}`.trim();
  let events = [];
  try {
    events = await extractEventsFromText(apiKey, text, timezone || "America/New_York");
  } catch (err) {
    console.error(`[email] event extraction failed: ${err.message}`);
    return { destination: "events", written: 0, ids: [] };
  }
  const eventsCol = db.collection("households").doc(hid).collection("events");
  const ids = [];
  for (const ev of events) {
    const start = new Date(ev.startDate);
    if (isNaN(start.getTime())) continue;
    const end = ev.endDate ? new Date(ev.endDate) : null;
    const id = eventsCol.doc().id;
    await eventsCol.doc(id).set({
      id,
      title: String(ev.title || "Untitled"),
      startDate: admin.firestore.Timestamp.fromDate(start),
      endDate: end && !isNaN(end.getTime()) ? admin.firestore.Timestamp.fromDate(end) : null,
      isAllDay: !!ev.isAllDay,
      location: ev.location || null,
      notes: ev.notes || null,
      recurrence: "none",
      assigneeIDs: [],
      source: "email",
      createdAt: now(),
      updatedAt: now(),
    });
    ids.push(id);
  }
  return { destination: "events", written: ids.length, ids };
}

/** Add items to a list (matching an existing one by name, else creating it). */
async function fileListItems({ db, hid, classification, uploadedBy }) {
  const listsCol = db.collection("households").doc(hid).collection("lists");
  const wanted = (classification.listName || classification.title || "From email").trim();

  // Match an existing list by title (case-insensitive), else create one.
  const all = await listsCol.get();
  let listDoc = all.docs.find((l) => String((l.data() || {}).title || "").toLowerCase() === wanted.toLowerCase());
  let listId;
  let listTitle;
  if (listDoc) {
    listId = listDoc.id;
    listTitle = listDoc.data().title;
  } else {
    listId = newId();
    listTitle = wanted;
    await listsCol.doc(listId).set({
      id: listId,
      title: listTitle,
      listType: "standard",
      color: "sky",
      icon: "checklist",
      source: "email",
      createdAt: now(),
      updatedAt: now(),
    });
  }

  const itemsRef = listsCol.doc(listId).collection("items");
  const existing = await itemsRef.get();
  let sort = existing.docs.reduce((m, d) => Math.max(m, (d.data() || {}).sortOrder || 0), 0);
  const itemIds = [];
  for (const title of classification.listItems) {
    const id = newId();
    sort += 1;
    await itemsRef.doc(id).set({
      id,
      title,
      isCompleted: false,
      listID: listId,
      sortOrder: sort,
      source: "email",
      createdAt: now(),
    });
    itemIds.push(id);
  }
  return { destination: "list", listId, listTitle, itemIds, count: itemIds.length, created: !listDoc };
}

/** Create a family memory (scrapbook) page. */
async function fileMemory({ db, hid, classification, subject, body, createdBy }) {
  const id = newId();
  await db.collection("households").doc(hid).collection("memories").doc(id).set({
    id,
    title: classification.title || subject || "A moment",
    richText: (classification.summary || body || "").trim(),
    photoPaths: [],
    stickerPaths: [],
    kidMemberIds: [],
    date: now(),
    createdBy: createdBy || null,
    source: "email",
    createdAt: now(),
    updatedAt: now(),
  });
  return { destination: "memory", memoryId: id };
}

// ---------------------------------------------------------------------------
// The router
// ---------------------------------------------------------------------------

/**
 * Route one inbound email to its destination(s). Pure of HTTP — callable directly by the harness.
 * @returns {Promise<{ classification, decisions:[], summary:string }>}
 */
async function routeEmail({ db, apiKey, hid, payload, timezone }) {
  const subject = String(payload.Subject || "");
  const body = String(payload.TextBody || payload.StrippedTextReply || "");
  const fromName = (payload.FromFull && payload.FromFull.Name) || payload.From || "";

  const ownerSnap = await db.collection("households").doc(hid).get();
  const uploadedBy = ownerSnap.exists ? ownerSnap.data().ownerUid || null : null;

  const attachments = documentAttachments(payload);
  const classification = await classifyEmail({
    apiKey,
    subject,
    body,
    fromName,
    hasAttachment: attachments.length > 0,
  });

  const decisions = [];

  // 1. Attachments → Family-Brain document(s) via Storage + processDocument.
  if (attachments.length > 0) {
    const filed = await fileAttachments({ db, hid, apiKey, attachments, uploadedBy });
    decisions.push(...filed);
  }

  // 2. Events — independent of the primary category (a receipt/newsletter can still carry a date).
  if (classification.isEvent) {
    const ev = await fileEvents({ db, hid, apiKey, subject, body, timezone });
    if (ev.written > 0) decisions.push(ev);
  }

  // 3. Primary text route — only when no attachment already captured the email as a Brain doc.
  //    (An attachment IS the document; we don't also mint a redundant text doc.)
  if (attachments.length === 0) {
    const c = classification;
    if (c.category === "order") {
      decisions.push(await fileTextDocument({
        db, hid, classification: c, subject, body, uploadedBy,
        extraTags: ["order", "shipping"],
      }));
    } else if (c.category === "list" && c.listItems.length > 0 && c.confidence !== "low") {
      decisions.push(await fileListItems({ db, hid, classification: c, uploadedBy }));
    } else if (c.category === "memory" && c.confidence === "high") {
      decisions.push(await fileMemory({ db, hid, classification: c, subject, body, createdBy: uploadedBy }));
    } else if (c.category === "receipt") {
      decisions.push(await fileTextDocument({ db, hid, classification: c, subject, body, uploadedBy }));
    } else if (c.category === "event") {
      // Pure event email: the events (if any) are the destination; only fall back to a doc if none landed.
      if (!decisions.some((d) => d.destination === "events")) {
        decisions.push(await fileTextDocument({ db, hid, classification: c, subject, body, uploadedBy }));
      }
    } else {
      // note / anything unsure → conservative Family-Brain doc.
      decisions.push(await fileTextDocument({ db, hid, classification: c, subject, body, uploadedBy }));
    }
  }

  // Final safety net: something must always land.
  if (decisions.length === 0) {
    decisions.push(await fileTextDocument({ db, hid, classification, subject, body, uploadedBy }));
  }

  return { classification, decisions, summary: confirmationCopy(classification, decisions) };
}

/** Warm, first-name-voice confirmation line for the push. */
function confirmationCopy(classification, decisions) {
  const eventDec = decisions.find((d) => d.destination === "events");
  const brainDec = decisions.find((d) => d.destination === "brain-doc");
  const listDec = decisions.find((d) => d.destination === "list");
  const memDec = decisions.find((d) => d.destination === "memory");
  const label = classification.vendor || classification.title || "your email";

  if (brainDec && eventDec) {
    return `Filed "${label}" → Family Brain, and added ${eventDec.written} to the calendar`;
  }
  if (brainDec) return `Filed "${label}" → Family Brain`;
  if (eventDec) return `Added ${eventDec.written} event${eventDec.written === 1 ? "" : "s"} from your email`;
  if (listDec) return `Added ${listDec.count} item${listDec.count === 1 ? "" : "s"} to ${listDec.listTitle}`;
  if (memDec) return `Saved "${label}" to your memories`;
  return "Filed your forwarded email";
}

module.exports = {
  resolveHousehold,
  classifyEmail,
  routeEmail,
  confirmationCopy,
  // exported for tests / reuse
  recipientCode,
  senderEmail,
  documentAttachments,
};
