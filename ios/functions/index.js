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
const { extractURL: runExtractURL } = require("./urlExtract");
const { extractEventsFromText } = require("./eventExtract");
const { resolveHousehold: resolveInboundHousehold, routeEmail } = require("./emailRouter");
const { generateDailyBriefing } = require("./briefingGenerate");
const { processDocument } = require("./docProcess");
const { buildDocumentCreatedTrigger } = require("./docCreatedTrigger");
const { identifyPlant } = require("./plantIdentify");
const { speciesProfile } = require("./plantSpeciesProfile");
const { troubleshootPlant } = require("./plantTroubleshoot");
const { runAgentTurn } = require("./agentTurn");
const { planMealWeek } = require("./mealPlanWeek");
const { summarizeSpending } = require("./spendingSummarize");
const { memoryMonthSummary } = require("./memoryMonthSummary");
const { reviewUsage } = require("./usageReview");
const { notifyHousehold, memberName } = require("./notifications");
const { awardChoreXP, reverseChoreXP } = require("./choreXP");
const { serve: serveMcp, mintToken: mintMcpToken } = require("./mcpServer");
const { pairAppleTV: runPairAppleTV } = require("./appleTVPairing");

// Act V V2-E — proactive, QUIET notifications (weekly digest + daily "3 things"). Kept in their own
// require block + export block (below) to minimize merge conflict with concurrent index.js edits.
const { onSchedule } = require("firebase-functions/v2/scheduler");
const { generateWeeklyDigest } = require("./digestGenerate");
const { selectDailyNudge } = require("./dailyNudge");
const { readNotificationPrefs, inQuietHours, etWeekday } = require("./familySignals");

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
 * existing household by its invite code, and (P18) **claim an existing managed persona** so the
 * family's profile-only members (Vale/Famfis/Oliver — member docs with data but no login) can be
 * picked up without creating a duplicate.
 *
 * It looks up the household by `inviteCode`, adds the caller's uid to `members` (idempotent via
 * arrayUnion), and points the user doc's `householdId` at it.
 *
 * - **No `claimMemberId`:** joins and returns `{ hid, name, memberCount, unclaimedMembers }` — the
 *   managed personas still available to claim (member docs with no `uid` whose doc id isn't in
 *   `members[]`). The client either offers the "Which family member are you?" picker (then calls
 *   back with a `claimMemberId`) or seeds a fresh member ("I'm new here").
 * - **With `claimMemberId`:** attaches the caller's uid to that member doc **preserving its doc id**
 *   (so every id-keyed reference — chores, `linkedMemberIds`, `memberStats/{id}` — stays valid).
 *   Rejects if the persona is already claimed by someone else or doesn't exist in the household.
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
    const claimMemberId = String(request.data?.claimMemberId || "").trim();

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
    const membersCol = doc.ref.collection("members");

    // --- Claim path: attach this account to an existing managed persona (P18) ---
    if (claimMemberId) {
      const memberRef = membersCol.doc(claimMemberId);
      const memberSnap = await memberRef.get();
      if (!memberSnap.exists) {
        throw new HttpsError("not-found", "That profile is no longer available.");
      }
      const member = memberSnap.data() || {};
      if (member.uid && member.uid !== uid) {
        throw new HttpsError(
          "failed-precondition",
          "Someone already claimed that profile."
        );
      }
      // Preserve the doc id; only attach the linked account. Every id-keyed reference stays valid.
      await memberRef.set({ uid }, { merge: true });
      await doc.ref.update({ members: admin.firestore.FieldValue.arrayUnion(uid) });
      await db.collection("users").doc(uid).set({ householdId: doc.id }, { merge: true });
      return {
        hid: doc.id,
        name: doc.data().name || null,
        claimedMemberId: claimMemberId,
        unclaimedMembers: [],
      };
    }

    // --- Join path: add to members[], then surface the claimable managed personas ---
    await doc.ref.update({
      members: admin.firestore.FieldValue.arrayUnion(uid),
    });
    await db.collection("users").doc(uid).set({ householdId: doc.id }, { merge: true });

    // Idempotent: if the user was already a member, arrayUnion is a no-op.
    const existingMembers = Array.isArray(doc.data().members) ? doc.data().members : [];
    const memberCount = existingMembers.includes(uid)
      ? existingMembers.length
      : existingMembers.length + 1;

    // Managed persona = a member doc with no linked `uid` whose doc id is NOT an account in
    // `members[]` (that gate excludes the owner, whose doc id IS their uid) and isn't the caller.
    const memberDocs = await membersCol.get();
    const unclaimedMembers = memberDocs.docs
      .filter((m) => {
        const data = m.data() || {};
        return !data.uid && !existingMembers.includes(m.id) && m.id !== uid;
      })
      .map((m) => {
        const data = m.data() || {};
        return {
          id: m.id,
          name: data.name || "Member",
          fullName: data.fullName || null,
          color: data.color || "ocean",
          avatarSystemName: data.avatarSystemName || "person.circle.fill",
        };
      });

    return {
      hid: doc.id,
      name: doc.data().name || null,
      memberCount,
      unclaimedMembers,
    };
  }
);

/**
 * `pairAppleTV` (P27-T2-C1) — a signed-in family member confirms a TV pairing code so the
 * living-room tvOS app can sign in via a Firebase custom token. See `appleTVPairing.js`.
 */
exports.pairAppleTV = onCall(
  { timeoutSeconds: 30, memory: "256MiB" },
  async (request) => runPairAppleTV(request)
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
 * `extractURL` is a v2 HTTPS callable (us-central1) for Act V's "URL front door" (V5-URL). Input
 * `{ url }`; it fetches the page, CLASSIFIES it (recipe / product / event / article) and returns a
 * routed result the Smart-Capture sheet files with one tap: `{ destination, title, url, summary,
 * imageURL, extractedText?, recipe?, product?, event? }`. Conservative — anything ambiguous or any
 * failure degrades to a Family Brain doc so a link is never lost. Reuses `ANTHROPIC_API_KEY`.
 */
exports.extractURL = onCall(
  { timeoutSeconds: 60, memory: "512MiB", secrets: [ANTHROPIC_API_KEY] },
  async (request) => {
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "You must be signed in.");
    }
    const url = typeof request.data?.url === "string" ? request.data.url.trim() : "";
    if (!/^https?:\/\//i.test(url)) {
      throw new HttpsError("invalid-argument", "A valid http(s) url is required.");
    }
    try {
      return await runExtractURL({ url, apiKey: ANTHROPIC_API_KEY.value(), timezone: "America/New_York" });
    } catch (err) {
      throw new HttpsError("internal", `URL import failed: ${err.message}`);
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
 * `onDocumentCreated` is a v2 Firestore trigger (us-central1) — the SERVER-SIDE auto-processing path
 * for the Family Brain. When a document is created at `households/{hid}/documents/{docId}` with
 * `processingState:"pending"` AND `needsServerProcessing:true` (the Share Extension's direct-to-cloud
 * path, which does NOT call the `processDocument` callable), it runs the SAME extraction via the
 * shared `processDocument` core, then clears the flag. Docs the in-app callable handles never set the
 * flag, so there is no double-processing. See `docCreatedTrigger.js` for the gate + idempotency guard.
 */
exports.onDocumentCreated = buildDocumentCreatedTrigger(ANTHROPIC_API_KEY);

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
 * `plantSpeciesProfile` is a v2 HTTPS callable (us-central1) for the P19-C4 species profiles. Input
 * `{ species?, commonName? }` (no photo — a knowledge lookup). It runs Claude (Sonnet 5) with a forced
 * tool-use schema and returns a rich houseplant care profile + **pet-toxicity**:
 * `{ lightNeed, humidity, fertilizer, idealTemp, commonProblems:[..], petToxicity:{ isToxicToPets,
 * toxicToDogs, toxicToCats, severity, note } }`. Toxicity is grounded in ASPCA-style knowledge and errs
 * toward caution when unsure. Reuses the existing `ANTHROPIC_API_KEY` secret. No rate limiting.
 */
exports.plantSpeciesProfile = onCall(
  { timeoutSeconds: 60, memory: "512MiB", secrets: [ANTHROPIC_API_KEY] },
  async (request) => {
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "You must be signed in.");
    }
    const data = request.data || {};
    const species = typeof data.species === "string" ? data.species : undefined;
    const commonName = typeof data.commonName === "string" ? data.commonName : undefined;
    if (!(species && species.trim()) && !(commonName && commonName.trim())) {
      throw new HttpsError("invalid-argument", "species or commonName is required.");
    }
    try {
      return await speciesProfile({ species, commonName, apiKey: ANTHROPIC_API_KEY.value() });
    } catch (err) {
      throw new HttpsError("internal", `Species profile failed: ${err.message}`);
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

/**
 * `planMealWeek` is a v2 HTTPS callable (us-central1) — the P23 "meal rhythm" planner. Given the
 * family's recipes (title + ingredient count + servings) and the week's 7 days (each tagged
 * weeknight/weekend), it asks Claude (Sonnet 5, forced tool-use) for a balanced, varied week of
 * DINNERS — quick weeknights, project weekends — picking ONLY from the provided recipe ids and
 * skipping clearly-non-dinner items (cookies, banana bread, etc.). Returns `{ plan: [{date,
 * recipeId, reason}] }`, server-validated to known ids/dates with no repeats. Auth-required; logs
 * only counts (never recipe contents). Reuses the existing ANTHROPIC_API_KEY secret.
 */
exports.planMealWeek = onCall(
  { timeoutSeconds: 60, memory: "512MiB", secrets: [ANTHROPIC_API_KEY] },
  async (request) => {
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "You must be signed in.");
    }
    const data = request.data || {};
    const recipes = Array.isArray(data.recipes)
      ? data.recipes
          .map((r) => ({
            id: typeof r.id === "string" ? r.id : "",
            title: typeof r.title === "string" ? r.title : "",
            ingredientCount: Number(r.ingredientCount) || 0,
            servings: Number(r.servings) || 0,
          }))
          .filter((r) => r.id && r.title)
      : [];
    const days = Array.isArray(data.days)
      ? data.days
          .map((d) => ({
            date: typeof d.date === "string" ? d.date : "",
            weekday: typeof d.weekday === "string" ? d.weekday : "",
            kind: d.kind === "weekend" ? "weekend" : "weeknight",
          }))
          .filter((d) => d.date)
      : [];
    if (recipes.length === 0 || days.length === 0) {
      throw new HttpsError("invalid-argument", "recipes and days are required.");
    }
    try {
      return await planMealWeek({ recipes, days, apiKey: ANTHROPIC_API_KEY.value() });
    } catch (err) {
      throw new HttpsError("internal", `Meal planning failed: ${err.message}`);
    }
  }
);

/**
 * `summarizeSpending` is a v2 HTTPS callable (us-central1) — the P22 "This month, in a nutshell"
 * AI recap. Input `{ month, currency?, lines: [{category, vendor, amount, date}] }` (the featured
 * month's already-categorized line items, computed by the client's SpendingInsights aggregator) →
 * ONE `claude-sonnet-5` forced-tool-use call → `{ summary, insight }` in the family's warm,
 * non-judgmental voice. NO finance logic runs server-side beyond forwarding a single model call —
 * aggregation/dedup/one-time bucketing all happen on the phone. Auth-required; logs only line COUNT
 * (never vendor names or amounts). Reuses the existing ANTHROPIC_API_KEY secret.
 */
exports.summarizeSpending = onCall(
  { timeoutSeconds: 60, memory: "512MiB", secrets: [ANTHROPIC_API_KEY] },
  async (request) => {
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "You must be signed in.");
    }
    const data = request.data || {};
    const month = typeof data.month === "string" ? data.month : undefined;
    const currency = typeof data.currency === "string" ? data.currency : undefined;
    const lines = Array.isArray(data.lines) ? data.lines : [];
    try {
      return await summarizeSpending({
        apiKey: ANTHROPIC_API_KEY.value(),
        month,
        currency,
        lines,
      });
    } catch (err) {
      throw new HttpsError("internal", `Spending summary failed: ${err.message}`);
    }
  }
);

/**
 * `memoryMonthSummary` is a v2 HTTPS callable (us-central1) — the P28-C3 Family-Journal month recap.
 * The phone groups its `memories` timeline by month, strips each story's markdown to plain text, and
 * forwards ONE month's `[{ title, text, milestone, kidNames, date }]`; this asks `claude-sonnet-5`
 * (forced tool-use) to weave those moments into `{ recap: string }` (2-4 warm family-voice
 * sentences). Auth-required; reuses the existing `ANTHROPIC_API_KEY`; logs only counts (never memory
 * text). No rate limiting (private app).
 */
exports.memoryMonthSummary = onCall(
  { timeoutSeconds: 60, memory: "512MiB", secrets: [ANTHROPIC_API_KEY] },
  async (request) => {
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "You must be signed in.");
    }
    const data = request.data || {};
    const month = typeof data.month === "string" ? data.month : undefined;
    const memories = Array.isArray(data.memories) ? data.memories : [];
    try {
      return await memoryMonthSummary({
        apiKey: ANTHROPIC_API_KEY.value(),
        month,
        memories,
      });
    } catch (err) {
      throw new HttpsError("internal", `Memory month recap failed: ${err.message}`);
    }
  }
);

/**
 * `reviewUsage` is a v2 HTTPS callable (us-central1) — the P25-C2 weekly usage review that closes
 * the signal loop. P25-C1 logs light behavioral events to `households/{hid}/analytics`; this reads
 * the last N days (default 7), aggregates COUNTS server-side (never ships raw rows to the model),
 * and asks `claude-sonnet-5` (forced tool-use) for a plain-language UX review →
 * `{ summary, topFeatures, underusedFeatures, frictionSignals, suggestions:[{title,why}],
 *    windowDays, eventCount, isSparse }`. The household is derived from the CALLER
 * (`users/{uid}.householdId`) — a client-passed hid is never trusted. Input `{ windowDays? }`.
 * Sparse data (the telemetry is only days old) is handled honestly, not fabricated. Auth-required;
 * reuses the existing `ANTHROPIC_API_KEY`; logs only counts. No rate limiting (private app).
 */
exports.reviewUsage = onCall(
  { timeoutSeconds: 60, memory: "512MiB", secrets: [ANTHROPIC_API_KEY] },
  async (request) => {
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "You must be signed in.");
    }
    const uid = request.auth.uid;
    const windowDays = Number(request.data?.windowDays);

    const userSnap = await db().collection("users").doc(uid).get();
    const hid = userSnap.exists ? userSnap.data().householdId : null;
    if (!hid) {
      throw new HttpsError("failed-precondition", "No household for this user.");
    }
    try {
      return await reviewUsage({
        db: db(),
        hid,
        apiKey: ANTHROPIC_API_KEY.value(),
        windowDays: Number.isFinite(windowDays) ? windowDays : undefined,
      });
    } catch (err) {
      throw new HttpsError("internal", `Usage review failed: ${err.message}`);
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
 * `receiveEmail` is a Postmark inbound webhook (onRequest) — Bacán's "open front door" (V5-email).
 * A family forwards (or sends) an email to their stable alias and it is AI-ROUTED into the right
 * module: attachments → Family Brain (Storage + `processDocument`), event-shaped mail → calendar
 * events (the original behavior, preserved), order/shipping confirmations → a Brain doc tagged
 * shipping/order, general notes → the best module (list / memory / Brain doc, Brain when unsure).
 * See `emailRouter.js` for the addressing scheme + classify-and-route core.
 *
 * Addressing (`resolveHousehold`): the recipient carries a code — `hub+{code}@<domain>`, a Postmark
 * `MailboxHash`, or the bare local part — resolved against `households/{hid}.inboundEmailCode` (the
 * stable forwarding code), then the legacy `inviteCode`, then a sender-address fallback.
 *
 * SETUP REQUIRED (see ROADMAP-family.md): a Postmark account with an inbound mail domain, an
 * MX record pointing at Postmark, the inbound webhook URL configured as this function's URL with
 * `?secret=<POSTMARK_WEBHOOK_SECRET>`, and the `POSTMARK_WEBHOOK_SECRET` secret set.
 */
exports.receiveEmail = onRequest(
  { timeoutSeconds: 300, memory: "1GiB", secrets: [ANTHROPIC_API_KEY, POSTMARK_WEBHOOK_SECRET] },
  async (req, res) => {
    if (req.query.secret !== POSTMARK_WEBHOOK_SECRET.value()) {
      res.status(401).send("unauthorized");
      return;
    }
    const payload = req.body || {};

    const resolved = await resolveInboundHousehold(db(), payload);
    if (!resolved) {
      // Drop safely (log) — no household could be resolved from the recipient code or sender.
      console.log(`[email] dropped: no household for to=${payload.To || ""} from=${payload.From || ""}`);
      res.status(200).send("no household");
      return;
    }
    const hid = resolved.hid;

    const hasContent =
      `${payload.Subject || ""}${payload.TextBody || ""}${payload.StrippedTextReply || ""}`.trim() ||
      (Array.isArray(payload.Attachments) && payload.Attachments.length > 0);
    if (!hasContent) {
      res.status(200).send("no content");
      return;
    }

    let result;
    try {
      result = await routeEmail({
        db: db(),
        apiKey: ANTHROPIC_API_KEY.value(),
        hid,
        payload,
        timezone: "America/New_York",
      });
    } catch (err) {
      console.error(`[email] routing failed for hid=${hid}: ${err.message}`);
      res.status(200).send(`routing failed: ${err.message}`);
      return;
    }

    // Confirmation push so the family sees it landed ("Filed your email → Family Brain: {vendor}").
    try {
      await notifyHousehold(db(), hid, { title: "Straight from your inbox", body: result.summary });
    } catch (err) {
      console.error(`[email] confirmation push failed for hid=${hid}: ${err.message}`);
    }

    const destinations = result.decisions.map((d) => d.destination).join(",");
    console.log(`[email] hid=${hid} via=${resolved.via} → [${destinations}] :: ${result.summary}`);
    res.status(200).send(`ok: routed via ${resolved.via} → ${destinations || "none"}`);
  }
);

// -----------------------------------------------------------------------------
// P14-C4 — MCP server over the family Firestore (read/query tools).
// -----------------------------------------------------------------------------

/**
 * `bacanMcp` is a v2 HTTPS `onRequest` function (us-central1) — a true **MCP server** over the
 * family's Firestore, spoken via streamable HTTP + JSON-RPC 2.0 (`mcpServer.js`). Point an MCP
 * client (Claude Desktop / Claude Code / claude.ai) at its URL with a per-household bearer token
 * (`Authorization: Bearer bcn~<hid>~<secret>`) and it exposes read/query tools — plants, pets,
 * documents, events, money, care-due, memories, lists — all scoped to the token's household.
 * Missing/invalid token → 401. No secrets needed (Firestore only); no rate limiting (private app).
 */
exports.bacanMcp = onRequest(
  { timeoutSeconds: 60, memory: "512MiB" },
  async (req, res) => {
    await serveMcp(req, res);
  }
);

/**
 * `regenerateMcpToken` is a v2 HTTPS callable (us-central1) — (re)mints the household's MCP bearer
 * token. The household is derived from the CALLER (`users/{uid}.householdId`); a client-passed hid is
 * never trusted. Overwrites `households/{hid}/config/mcpToken = { token, createdAt }` and returns
 * `{ token, endpoint }`. Any prior token is immediately invalidated. Auth-required.
 */
exports.regenerateMcpToken = onCall(
  { timeoutSeconds: 30, memory: "256MiB" },
  async (request) => {
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "You must be signed in.");
    }
    const uid = request.auth.uid;
    const userSnap = await db().collection("users").doc(uid).get();
    const hid = userSnap.exists ? userSnap.data().householdId : null;
    if (!hid) {
      throw new HttpsError("failed-precondition", "No household for this user.");
    }
    const token = mintMcpToken(hid);
    await db()
      .collection("households").doc(hid)
      .collection("config").doc("mcpToken")
      .set({ token, createdAt: admin.firestore.Timestamp.now() });
    return {
      token,
      endpoint: "https://us-central1-menere.cloudfunctions.net/bacanMcp",
    };
  }
);

// -----------------------------------------------------------------------------
// Act V V2-E — proactive, QUIET notifications (weekly digest + daily "3 things").
// Both are v2 `onSchedule` (Cloud Scheduler) jobs that run once each ET morning and iterate every
// household, RESPECTING each household's `config/notificationPrefs` (on/off, weekly day, quiet
// hours). They compose via the pure helpers in digestGenerate.js / dailyNudge.js and deliver through
// the existing notify-only FCM path (`notifyHousehold`). The daily nudge NEVER pushes on an empty day.
// -----------------------------------------------------------------------------

/** Every household id (private app — usually one). */
async function allHouseholdIds() {
  const snap = await db().collection("households").get();
  return snap.docs.map((d) => d.id);
}

/**
 * `weeklyFamilyDigest` — daily 08:00 ET tick; for each household whose prefs say "weekly on" AND whose
 * chosen weekday is today (and not in quiet hours), composes the warm week-ahead digest (Claude), saves
 * it to `households/{hid}/digests/{YYYY-Www}`, and pushes `{ title, body }` to the family.
 */
exports.weeklyFamilyDigest = onSchedule(
  {
    schedule: "0 8 * * *",
    timeZone: "America/New_York",
    memory: "512MiB",
    timeoutSeconds: 180,
    secrets: [ANTHROPIC_API_KEY],
  },
  async () => {
    const now = new Date();
    const today = etWeekday(now); // 1=Sun … 7=Sat (Apple weekday)
    for (const hid of await allHouseholdIds()) {
      try {
        const prefs = await readNotificationPrefs(db(), hid);
        if (!prefs.weeklyDigestEnabled) continue;
        if (prefs.weeklyDigestWeekday !== today) continue;
        if (inQuietHours(now, prefs)) continue;
        const digest = await generateWeeklyDigest({
          db: db(), hid, apiKey: ANTHROPIC_API_KEY.value(), now,
        });
        if (!digest) continue;
        await notifyHousehold(db(), hid, { title: digest.title, body: digest.body });
      } catch (err) {
        console.error(`[weeklyFamilyDigest] hid=${hid} failed: ${err.message}`);
      }
    }
  }
);

/**
 * `dailyThreeThings` — daily 08:00 ET tick; for each household whose prefs say "daily nudge on" (and not
 * in quiet hours), selects at most 3 of today's most-actionable items and pushes them — but only when
 * there's something worth saying (a genuinely calm day gets NO push). Persists to
 * `households/{hid}/nudges/{YYYY-MM-DD}`. No AI, no secrets — deterministic Radar-style prioritization.
 */
exports.dailyThreeThings = onSchedule(
  {
    schedule: "0 8 * * *",
    timeZone: "America/New_York",
    memory: "256MiB",
    timeoutSeconds: 120,
  },
  async () => {
    const now = new Date();
    for (const hid of await allHouseholdIds()) {
      try {
        const prefs = await readNotificationPrefs(db(), hid);
        if (!prefs.dailyNudgeEnabled) continue;
        if (inQuietHours(now, prefs)) continue;
        const nudge = await selectDailyNudge({ db: db(), hid, now });
        if (!nudge) continue; // empty day — stay quiet
        await notifyHousehold(db(), hid, { title: nudge.title, body: nudge.body });
      } catch (err) {
        console.error(`[dailyThreeThings] hid=${hid} failed: ${err.message}`);
      }
    }
  }
);

// ── Plaid bank-sync scaffold (Act V V4 — Money) ────────────────────────────────────────────────
// Structure only; LIVE needs Michael's Plaid account + the two secrets below (not set yet). One
// callable routes the whole Link → exchange → sync lifecycle by `action`, so the diff to index.js is
// a single export (see plaid.js for the SDK-lazy, credential-guarded implementation).
const plaidScaffold = require("./plaid");
const PLAID_CLIENT_ID = defineSecret("PLAID_CLIENT_ID");
const PLAID_SECRET = defineSecret("PLAID_SECRET");

/**
 * `plaidBankSync` is a v2 HTTPS callable (us-central1) — the Plaid entry point. `action` picks the
 * verb: "createLinkToken" | "exchange" | "sync". Until PLAID_CLIENT_ID/PLAID_SECRET are populated
 * (and the `plaid` npm dep installed) every action returns a flagged `{ configured:false, … }`
 * payload so the app shows "coming soon / needs setup" rather than erroring. Auth-required; the
 * household is derived from the caller, never trusted from the client.
 */
exports.plaidBankSync = onCall(
  { timeoutSeconds: 60, memory: "256MiB", secrets: [PLAID_CLIENT_ID, PLAID_SECRET] },
  async (request) => {
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "You must be signed in.");
    }
    const uid = request.auth.uid;
    const userSnap = await db().collection("users").doc(uid).get();
    const hid = userSnap.exists ? userSnap.data().householdId : null;
    if (!hid) {
      throw new HttpsError("failed-precondition", "No household for this user.");
    }

    const data = request.data || {};
    const action = typeof data.action === "string" ? data.action : "createLinkToken";
    const env = typeof data.env === "string" ? data.env : "sandbox";
    const clientId = PLAID_CLIENT_ID.value();
    const secret = PLAID_SECRET.value();
    const common = { clientId, secret, env };

    try {
      switch (action) {
        case "createLinkToken":
          return await plaidScaffold.createLinkToken(Object.assign({ userId: uid }, common));
        case "exchange":
          return await plaidScaffold.exchangePublicToken(
            Object.assign({ publicToken: data.publicToken }, common)
          );
        case "sync":
          return await plaidScaffold.syncTransactions(
            Object.assign({ accessToken: data.accessToken, cursor: data.cursor }, common)
          );
        default:
          throw new HttpsError("invalid-argument", `Unknown Plaid action: ${action}`);
      }
    } catch (err) {
      if (err instanceof HttpsError) throw err;
      throw new HttpsError("internal", `Plaid ${action} failed: ${err.message}`);
    }
  }
);
