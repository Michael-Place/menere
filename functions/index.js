"use strict";

/**
 * Menere Cloud Functions.
 *
 * `ttbColaLookup` is a v2 HTTPS callable (us-central1) that wraps the deploy-free
 * `lookupColaClassType` TTB COLA lookup. It returns the approved class/type for a wine
 * so the iOS `TTBColaSource` can map it to an authoritative `WineType`.
 */

const { onCall, HttpsError } = require("firebase-functions/v2/https");
const { setGlobalOptions } = require("firebase-functions/v2");
const admin = require("firebase-admin");
const { lookupColaClassType } = require("./ttbLookup");

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
