"use strict";

/**
 * Server-side auto-processing trigger for the Bacán/Menere Family Brain (DC2).
 *
 * Most documents are processed by the in-app `processDocument` callable (scanner / URL import /
 * in-app add). But a NEW source — the Share Extension going **direct-to-cloud** — creates a
 * `households/{hid}/documents/{docId}` doc (with the uploaded file already in Storage) WITHOUT
 * calling the callable. Such docs are marked `processingState: "pending"` + `needsServerProcessing:
 * true`. This `onDocumentCreated` trigger runs the SAME extraction the callable runs (via the shared
 * `processDocument` core in `docProcess.js` — no duplication of the Claude/vision logic) and then
 * clears the flag.
 *
 * Scoping / no double-processing:
 *   - Fires ONLY when `needsServerProcessing === true` AND `processingState === "pending"`. The
 *     in-app callable path never sets `needsServerProcessing`, so those docs are ignored here.
 *
 * Idempotency / re-entrancy:
 *   - It's `onDocumentCreated` (not `onUpdated`), so the writebacks — `processDocument`'s field
 *     merge that flips state to "processed", plus our flag-clear below — are UPDATES and never
 *     re-fire this trigger.
 *   - Eventarc is at-least-once: on a duplicate delivery `event.data` still shows the create-time
 *     snapshot, so we re-read the LIVE doc and bail if it's no longer pending/flagged.
 *   - On completion we delete `needsServerProcessing` and stamp `serverProcessedAt`, so a manual
 *     re-write can't silently reprocess.
 */

const { onDocumentCreated } = require("firebase-functions/v2/firestore");
const admin = require("firebase-admin");
const { processDocument } = require("./docProcess");

/**
 * Build the configured trigger. Takes the ANTHROPIC_API_KEY secret param (defined in index.js) so
 * the secret is bound at deploy time exactly like the `processDocument` callable.
 */
function buildDocumentCreatedTrigger(apiKeySecret) {
  return onDocumentCreated(
    {
      document: "households/{hid}/documents/{docId}",
      region: "us-central1",
      secrets: [apiKeySecret],
      timeoutSeconds: 120,
      memory: "1GiB",
    },
    async (event) => {
      const snap = event.data;
      if (!snap) return;
      const created = snap.data() || {};

      // Gate on the create-time snapshot: only server-processing candidates continue.
      if (created.needsServerProcessing !== true) return;
      if (created.processingState !== "pending") return;

      const hid = event.params.hid;
      const docId = event.params.docId;
      const db = admin.firestore();
      const docRef = db.collection("households").doc(hid).collection("documents").doc(docId);

      // Re-read the LIVE doc to survive at-least-once duplicate deliveries: if it's already been
      // handled (state moved off "pending" or the flag was cleared), do nothing.
      const liveSnap = await docRef.get();
      if (!liveSnap.exists) return;
      const live = liveSnap.data() || {};
      if (live.needsServerProcessing !== true || live.processingState !== "pending") return;

      try {
        await processDocument({ db, hid, docId, apiKey: apiKeySecret.value() });
      } catch (err) {
        // processDocument already flipped processingState to "failed"; log and still clear the flag
        // so a failed doc doesn't sit flagged forever.
        console.error(`[docs] server-trigger failed ${docId}: ${err.message}`);
      } finally {
        await docRef.set(
          {
            needsServerProcessing: admin.firestore.FieldValue.delete(),
            serverProcessedAt: admin.firestore.Timestamp.now(),
          },
          { merge: true }
        );
      }
    }
  );
}

module.exports = { buildDocumentCreatedTrigger };
