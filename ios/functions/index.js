"use strict";

/**
 * Menere Cloud Functions.
 *
 * `ttbColaLookup` is a v2 HTTPS callable (us-central1) that wraps the deploy-free
 * `lookupColaClassType` TTB COLA lookup. It returns the approved class/type for a wine
 * so the iOS `TTBColaSource` can map it to an authoritative `WineType`.
 */

const { onCall, HttpsError, onRequest } = require("firebase-functions/v2/https");
const { onDocumentCreated, onDocumentUpdated } = require("firebase-functions/v2/firestore");
const { setGlobalOptions } = require("firebase-functions/v2");
const { defineSecret } = require("firebase-functions/params");
const admin = require("firebase-admin");
const { lookupColaClassType } = require("./ttbLookup");
const { identifyWineLabel } = require("./claudeVision");
const { extractRecipe: runExtractRecipe } = require("./recipeExtract");
const { extractEventsFromText } = require("./eventExtract");
const { generateDailyBriefing } = require("./briefingGenerate");
const { processDocument } = require("./docProcess");
const { identifyPlant } = require("./plantIdentify");
const { troubleshootPlant } = require("./plantTroubleshoot");
const { runAgentTurn } = require("./agentTurn");
const { notifyHousehold, memberName } = require("./notifications");
const { awardChoreXP, reverseChoreXP } = require("./choreXP");

const ANTHROPIC_API_KEY = defineSecret("ANTHROPIC_API_KEY");
const POSTMARK_WEBHOOK_SECRET = defineSecret("POSTMARK_WEBHOOK_SECRET");

setGlobalOptions({ region: "us-central1", maxInstances: 10 });

if (admin.apps.length === 0) {
  admin.initializeApp();
}

exports.ttbColaLookup = onCall(
  { timeoutSeconds: 30, memory: "256MiB" },
  async (request) => {
    // TODO: enforce App Check / auth before public launch (request.app / request.auth).
    const data = request.data || {};
    const productName = typeof data.productName === "string" ? data.productName : "";
    const brand = typeof data.brand === "string" ? data.brand : "";
    return await lookupColaClassType({ productName, brand });
  }
);

/**
 * `joinHousehold` is a v2 HTTPS callable (us-central1) that lets a signed-in user join an
 * existing household by its invite code. It looks up the household by `inviteCode`, adds the
 * caller's uid to `members` (idempotent via arrayUnion), and points the user doc's
 * `householdId` at it. Returns `{ hid, name, memberCount }`.
 */
exports.joinHousehold = onCall(
  { timeoutSeconds: 30, memory: "256MiB" },
  async (request) => {
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "You must be signed in to join a household.");
    }
    const uid = request.auth.uid;
    const code = String(request.data?.code || "").trim().toUpperCase();
    if (!code) {
      throw new HttpsError("invalid-argument", "An invite code is required.");
    }

    const db = admin.firestore();
    const snapshot = await db
      .collection("households")
      .where("inviteCode", "==", code)
      .limit(1)
      .get();

    if (snapshot.empty) {
      throw new HttpsError("not-found", "No household found for that code");
    }

    const doc = snapshot.docs[0];
    await doc.ref.update({
      members: admin.firestore.FieldValue.arrayUnion(uid),
    });
    await db.collection("users").doc(uid).set({ householdId: doc.id }, { merge: true });

    // Idempotent: if the user was already a member, arrayUnion is a no-op.
    const existingMembers = Array.isArray(doc.data().members) ? doc.data().members : [];
    const memberCount = existingMembers.includes(uid)
      ? existingMembers.length
      : existingMembers.length + 1;

    return {
      hid: doc.id,
      name: doc.data().name || null,
      memberCount,
    };
  }
);

/**
 * `identifyLabel` is a v2 HTTPS callable (us-central1) that reads a wine-bottle-label
 * photo with Claude vision and returns label-grounded identity fields
 * (`{ producer, name, vintage, region, grapes, type, confidence }`). The Anthropic API
 * key is injected via the `ANTHROPIC_API_KEY` secret.
 */
exports.identifyLabel = onCall(
  { timeoutSeconds: 60, memory: "512MiB", secrets: [ANTHROPIC_API_KEY] },
  async (request) => {
    // TODO: enforce App Check / auth before public launch (consistent with ttbColaLookup).
    const data = request.data || {};
    const imageBase64 = typeof data.imageBase64 === "string" ? data.imageBase64 : "";
    const mimeType = typeof data.mimeType === "string" ? data.mimeType : "image/jpeg";
    if (!imageBase64) {
      throw new HttpsError("invalid-argument", "imageBase64 is required.");
    }
    try {
      const candidate = await identifyWineLabel({
        imageBase64,
        mimeType,
        apiKey: ANTHROPIC_API_KEY.value(),
      });
      return candidate;   // { producer, name, vintage, region, grapes, type, confidence }
    } catch (err) {
      throw new HttpsError("internal", `Label identification failed: ${err.message}`);
    }
  }
);

/**
 * `extractRecipe` is a v2 HTTPS callable (us-central1) that extracts a structured recipe
 * from a URL (JSON-LD fast path, else Claude) or raw text. Returns
 * `{ recipe: { title, servings, ingredients:[{name,quantity,unit}], instructions:[], sourceURL }, source }`.
 * Reuses the existing `ANTHROPIC_API_KEY` secret. No rate limiting (private app).
 */
exports.extractRecipe = onCall(
  { timeoutSeconds: 60, memory: "512MiB", secrets: [ANTHROPIC_API_KEY] },
  async (request) => {
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "You must be signed in.");
    }
    const data = request.data || {};
    const url = typeof data.url === "string" ? data.url.trim() : "";
    const text = typeof data.text === "string" ? data.text : "";
    if (!url && !text) {
      throw new HttpsError("invalid-argument", "url or text is required.");
    }
    try {
      return await runExtractRecipe({ url, text, apiKey: ANTHROPIC_API_KEY.value() });
    } catch (err) {
      throw new HttpsError("internal", `Recipe extraction failed: ${err.message}`);
    }
  }
);

/**
 * `generateDailyBriefing` is a v2 HTTPS callable (us-central1) that returns the family's AI daily
 * briefing for today (America/New_York): `{ summary, highlights:[], date, cached }`. The household
 * is derived from the CALLER (`users/{uid}.householdId`) — a client-passed hid is never trusted.
 * Results are cached per ET-day at `households/{hid}/briefings/{YYYY-MM-DD}`; pass `force: true`
 * (the refresh button) to regenerate and overwrite. Reuses the existing `ANTHROPIC_API_KEY` secret.
 */
exports.generateDailyBriefing = onCall(
  { timeoutSeconds: 60, memory: "512MiB", secrets: [ANTHROPIC_API_KEY] },
  async (request) => {
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "You must be signed in.");
    }
    const uid = request.auth.uid;
    const force = request.data?.force === true;

    const userSnap = await db().collection("users").doc(uid).get();
    const hid = userSnap.exists ? userSnap.data().householdId : null;
    if (!hid) {
      throw new HttpsError("failed-precondition", "No household for this user.");
    }
    try {
      return await generateDailyBriefing({
        db: db(),
        hid,
        apiKey: ANTHROPIC_API_KEY.value(),
        force,
      });
    } catch (err) {
      throw new HttpsError("internal", `Briefing failed: ${err.message}`);
    }
  }
);

/**
 * `processDocument` is a v2 HTTPS callable (us-central1) for the Family Brain document vault. Input
 * `{ docId }`; the household is derived from the CALLER (`users/{uid}.householdId`) — a client-passed
 * hid is never trusted. It downloads the document's uploaded pages from Storage, runs Claude vision
 * (Sonnet 5) over them, and writes back the structured fields (type/tags/summary/vendor/amount/dates/
 * extractedText) + flips `processingState` to `processed` (or `failed` on any error). Reuses the
 * existing `ANTHROPIC_API_KEY` secret. No rate limiting (private app).
 */
exports.processDocument = onCall(
  { timeoutSeconds: 120, memory: "1GiB", secrets: [ANTHROPIC_API_KEY] },
  async (request) => {
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "You must be signed in.");
    }
    const uid = request.auth.uid;
    const docId = String(request.data?.docId || "").trim();
    if (!docId) {
      throw new HttpsError("invalid-argument", "docId is required.");
    }

    const userSnap = await db().collection("users").doc(uid).get();
    const hid = userSnap.exists ? userSnap.data().householdId : null;
    if (!hid) {
      throw new HttpsError("failed-precondition", "No household for this user.");
    }
    try {
      return await processDocument({
        db: db(),
        hid,
        docId,
        apiKey: ANTHROPIC_API_KEY.value(),
      });
    } catch (err) {
      throw new HttpsError("internal", `Document processing failed: ${err.message}`);
    }
  }
);

/**
 * `identifyPlant` is a v2 HTTPS callable (us-central1) for the P9 Plants module. Input
 * `{ imageBase64, mediaType }` (same transport as `identifyLabel`). It runs Claude vision (Sonnet 5)
 * with a forced tool-use schema over a single plant photo and returns identity + care fields
 * `{ commonName, latinName, confidence, waterIntervalDays, light, careNotes }`. Grounded to what's
 * visible: a non-plant / unidentifiable photo comes back as `confidence:"low"`, commonName "Unknown",
 * latinName null. Reuses the existing `ANTHROPIC_API_KEY` secret. No rate limiting (private app).
 */
exports.identifyPlant = onCall(
  { timeoutSeconds: 60, memory: "512MiB", secrets: [ANTHROPIC_API_KEY] },
  async (request) => {
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "You must be signed in.");
    }
    const data = request.data || {};
    const imageBase64 = typeof data.imageBase64 === "string" ? data.imageBase64 : "";
    const mediaType = typeof data.mediaType === "string" ? data.mediaType : "image/jpeg";
    if (!imageBase64) {
      throw new HttpsError("invalid-argument", "imageBase64 is required.");
    }
    try {
      return await identifyPlant({ imageBase64, mediaType, apiKey: ANTHROPIC_API_KEY.value() });
    } catch (err) {
      throw new HttpsError("internal", `Plant identification failed: ${err.message}`);
    }
  }
);

/**
 * `troubleshootPlant` is a v2 HTTPS callable (us-central1) for the P19-C3 "plant whisperer". Input
 * `{ species?, commonName?, careContext?, waterIntervalDays?, problem, imageBase64?, mediaType? }`.
 * It runs Claude vision (Sonnet 5, image optional) with a forced tool-use schema over the plant's
 * identity + CONTEXT + the described problem and returns `{ diagnosis, fixes[], suggestedWaterInterval
 * Days|null, careTip|null }`. The context (pot/soil/indoor-outdoor/light) drives the answer, and a
 * cadence change is proposed ONLY when the problem/context implies it (rot → longer, fast-dry pot →
 * shorter). Reuses the existing `ANTHROPIC_API_KEY` secret. No rate limiting (private app).
 */
exports.troubleshootPlant = onCall(
  { timeoutSeconds: 60, memory: "512MiB", secrets: [ANTHROPIC_API_KEY] },
  async (request) => {
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "You must be signed in.");
    }
    const data = request.data || {};
    const problem = typeof data.problem === "string" ? data.problem.trim() : "";
    if (!problem) {
      throw new HttpsError("invalid-argument", "problem is required.");
    }
    const imageBase64 = typeof data.imageBase64 === "string" ? data.imageBase64 : undefined;
    const mediaType = typeof data.mediaType === "string" ? data.mediaType : "image/jpeg";
    const waterIntervalDays = Number.isFinite(data.waterIntervalDays)
      ? data.waterIntervalDays
      : undefined;
    try {
      return await troubleshootPlant({
        species: typeof data.species === "string" ? data.species : undefined,
        commonName: typeof data.commonName === "string" ? data.commonName : undefined,
        careContext: typeof data.careContext === "string" ? data.careContext : undefined,
        waterIntervalDays,
        problem,
        imageBase64,
        mediaType,
        apiKey: ANTHROPIC_API_KEY.value(),
      });
    } catch (err) {
      throw new HttpsError("internal", `Plant troubleshooting failed: ${err.message}`);
    }
  }
);

/**
 * `agentTurn` is a v2 HTTPS callable (us-central1) — the dumb model proxy for the P14 on-phone
 * agent. Input `{ messages, tools, system }` (Anthropic Messages-API shapes, built by the client's
 * AgentLoop) → ONE `claude-sonnet-5` call → `{ content, stopReason }` (raw content blocks +
 * stop_reason). NO family logic runs here: tools live on the phone, the client runs the loop, this
 * only forwards a single model call. Auth-required; logs only the stop reason + tool NAMES (never
 * arguments). Reuses the existing ANTHROPIC_API_KEY secret.
 */
exports.agentTurn = onCall(
  { timeoutSeconds: 60, memory: "512MiB", secrets: [ANTHROPIC_API_KEY] },
  async (request) => {
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "You must be signed in.");
    }
    const data = request.data || {};
    const messages = Array.isArray(data.messages) ? data.messages : null;
    if (!messages || messages.length === 0) {
      throw new HttpsError("invalid-argument", "messages is required.");
    }
    const system = typeof data.system === "string" ? data.system : undefined;
    const tools = Array.isArray(data.tools) ? data.tools : undefined;
    try {
      return await runAgentTurn({
        apiKey: ANTHROPIC_API_KEY.value(),
        system,
        messages,
        tools,
      });
    } catch (err) {
      throw new HttpsError("internal", `Agent turn failed: ${err.message}`);
    }
  }
);

// -----------------------------------------------------------------------------
// Notify-only FCM triggers (XP + activity are written client-side; these only push).
// -----------------------------------------------------------------------------

const db = () => admin.firestore();

/**
 * Human "when" for a calendar event, in the household's default zone (America/New_York, matching
 * receiveEmail). All-day events show just the date; timed events add the time. Returns null when
 * the timestamp is missing/unparseable so callers can drop the "— {when}" clause gracefully.
 */
function formatWhen(startTs, isAllDay) {
  const date = startTs && typeof startTs.toDate === "function" ? startTs.toDate() : null;
  if (!date || isNaN(date.getTime())) return null;
  const opts = isAllDay
    ? { weekday: "short", month: "short", day: "numeric", timeZone: "America/New_York" }
    : { weekday: "short", month: "short", day: "numeric", hour: "numeric", minute: "2-digit", timeZone: "America/New_York" };
  return new Intl.DateTimeFormat("en-US", opts).format(date);
}

/** New calendar event → tell the household. */
exports.onEventCreated = onDocumentCreated(
  "households/{hid}/events/{eventID}",
  async (event) => {
    const data = event.data && event.data.data();
    if (!data || !data.title) return;
    // FamilyEvent has no creator field, so lead with the event itself and add the "when".
    const when = formatWhen(data.startDate, data.isAllDay);
    const title = String(data.title);
    await notifyHousehold(db(), event.params.hid, {
      title: "New on the calendar",
      body: when ? `"${title}" — ${when}` : `"${title}"`,
    });
  }
);

/**
 * Chore completion toggled. Server-authoritative XP: on completion, award XP (transactional,
 * idempotent) to the credited member and notify the household; on uncompletion, reverse the
 * award. Early-returns when `isCompleted` didn't change (e.g. the trigger's own `xpAwarded`
 * write-back), so it never loops.
 */
exports.onChoreToggled = onDocumentUpdated(
  "households/{hid}/chores/{choreID}",
  async (event) => {
    const before = event.data.before.data() || {};
    const after = event.data.after.data() || {};
    const wasCompleted = !!before.isCompleted;
    const isCompleted = !!after.isCompleted;
    if (wasCompleted === isCompleted) return;

    const hid = event.params.hid;
    if (isCompleted) {
      // awardChoreXP runs before the push and returns the exact XP granted, so we can name it.
      const awarded = await awardChoreXP(db(), hid, event.params.choreID, after);
      const name = await memberName(db(), hid, after.completedByMemberID);
      const title = String(after.title);
      const xp = awarded > 0 ? ` (+${awarded} XP)` : "";
      const body = name
        ? `${name} took care of "${title}"${xp}`
        : `"${title}" is done${xp}`;
      await notifyHousehold(
        db(),
        hid,
        { title: "One less thing", body },
        after.completedByMemberID
      );
    } else {
      await reverseChoreXP(db(), hid, event.params.choreID, before);
    }
  }
);

/** List item checked off (false → true) → tell the household. */
exports.onListItemChecked = onDocumentUpdated(
  "households/{hid}/lists/{listID}/items/{itemID}",
  async (event) => {
    const before = event.data.before.data() || {};
    const after = event.data.after.data() || {};
    if (before.isCompleted || !after.isCompleted) return;

    const hid = event.params.hid;
    const item = String(after.title);
    // ListItem stores no "checked by" field; assigneeID is the best-available proxy for the actor.
    const name = await memberName(db(), hid, after.assigneeID);
    // The parent list's title makes a nice notification title; fall back if it's not readable.
    let listTitle = "List update";
    try {
      const listSnap = await db()
        .collection("households").doc(hid).collection("lists").doc(event.params.listID).get();
      if (listSnap.exists && typeof listSnap.data().title === "string" && listSnap.data().title.trim()) {
        listTitle = listSnap.data().title.trim();
      }
    } catch (_) { /* keep fallback */ }

    await notifyHousehold(db(), hid, {
      title: listTitle,
      body: name ? `${name} checked off "${item}"` : `Checked off "${item}"`,
    });
  }
);

/**
 * `receiveEmail` is a Postmark inbound webhook (onRequest). A family forwards an email to
 * `{inviteCode}@inbox.<your-domain>`; we resolve the household by that invite code, run Claude
 * event extraction over the subject + body, and write the events to the calendar.
 *
 * SETUP REQUIRED (see ROADMAP-family.md): a Postmark account with an inbound mail domain, an
 * MX record pointing at Postmark, the inbound webhook URL configured as this function's URL with
 * `?secret=<POSTMARK_WEBHOOK_SECRET>`, and the `POSTMARK_WEBHOOK_SECRET` secret set.
 */
exports.receiveEmail = onRequest(
  { timeoutSeconds: 120, memory: "512MiB", secrets: [ANTHROPIC_API_KEY, POSTMARK_WEBHOOK_SECRET] },
  async (req, res) => {
    if (req.query.secret !== POSTMARK_WEBHOOK_SECRET.value()) {
      res.status(401).send("unauthorized");
      return;
    }
    const payload = req.body || {};
    // Resolve the household by its invite code, taken from the recipient address. Supports both:
    //   • custom domain:   ABC123@inbox.<your-domain>           (local part = invite code)
    //   • Postmark default: <serverhash>+ABC123@inbound.postmarkapp.com  (MailboxHash = invite code)
    // The latter lets us reuse a Postmark account with zero DNS setup.
    const toAddress =
      (Array.isArray(payload.ToFull) && payload.ToFull[0] && payload.ToFull[0].Email) ||
      payload.To ||
      "";
    const rawLocal = String(toAddress).split("@")[0];
    const plusHash = rawLocal.includes("+") ? rawLocal.split("+").pop() : "";
    const key = String(payload.MailboxHash || plusHash || rawLocal).trim().toUpperCase();
    if (!key) {
      res.status(200).send("no recipient");
      return;
    }

    const householdSnap = await db()
      .collection("households")
      .where("inviteCode", "==", key)
      .limit(1)
      .get();
    if (householdSnap.empty) {
      res.status(200).send("no household");
      return;
    }
    const hid = householdSnap.docs[0].id;

    const text = `${payload.Subject || ""}\n\n${payload.TextBody || payload.StrippedTextReply || ""}`.trim();
    if (!text) {
      res.status(200).send("no content");
      return;
    }

    let events = [];
    try {
      events = await extractEventsFromText(ANTHROPIC_API_KEY.value(), text, "America/New_York");
    } catch (err) {
      res.status(200).send(`extraction failed: ${err.message}`);
      return;
    }

    const eventsCol = db().collection("households").doc(hid).collection("events");
    let written = 0;
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
        createdAt: admin.firestore.Timestamp.now(),
        updatedAt: admin.firestore.Timestamp.now(),
      });
      written += 1;
    }

    if (written > 0) {
      await notifyHousehold(db(), hid, {
        title: "Straight from your inbox",
        body: `${written} event${written === 1 ? "" : "s"} added from your forwarded email`,
      });
    }
    res.status(200).send(`ok: ${written} events`);
  }
);
