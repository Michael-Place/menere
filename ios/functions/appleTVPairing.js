"use strict";

/**
 * Apple TV device-pairing (P27-T2-C1).
 *
 * The living-room tvOS app can't do phone-OTP auth (no reCAPTCHA / push on tvOS). Instead it
 * uses a **device-pairing** handshake:
 *
 *   1. The TV, unauthenticated, generates a short 6-char CODE and writes a pending doc at the
 *      top-level `tvPairing/{code}` = `{ status: "pending", createdAt }` (Firestore rules allow
 *      an unauthenticated client to create/read exactly this shape — see `firestore.rules`).
 *   2. The TV shows the code and polls `tvPairing/{code}` for a `customToken`.
 *   3. A signed-in family member opens Bacan on their phone → Settings → Link Apple TV, types the
 *      code, and calls this `pairAppleTV` callable.
 *   4. This function resolves the caller's household, mints a Firebase **custom token** for a
 *      per-household TV identity (`tv-{hid}`), writes it onto the pairing doc (status → "paired"),
 *      and arrayUnions `tv-{hid}` into `households/{hid}.members` so the TV passes the security
 *      rules once it signs in.
 *   5. The TV picks up the `customToken`, calls `signInWithCustomToken`, and is now a read-only
 *      member of the family household.
 *
 * The custom token is only as secret as the 6-char code + its short pending window; acceptable for
 * a private family app. The pairing doc is written only by this function (Admin SDK bypasses
 * rules), so clients can never forge a `customToken`.
 */

const { onCall, HttpsError } = require("firebase-functions/v2/https");
const admin = require("firebase-admin");

async function pairAppleTV(request) {
  if (!request.auth) {
    throw new HttpsError("unauthenticated", "You must be signed in to link an Apple TV.");
  }
  const uid = request.auth.uid;
  const code = String(request.data?.code || "").trim().toUpperCase();
  if (!code || code.length < 4) {
    throw new HttpsError("invalid-argument", "A pairing code is required.");
  }

  const db = admin.firestore();

  // The TV must have registered this code (pending) before the phone confirms it.
  const pairingRef = db.collection("tvPairing").doc(code);
  const pairingSnap = await pairingRef.get();
  if (!pairingSnap.exists) {
    throw new HttpsError(
      "not-found",
      "We couldn't find that code. Make sure it matches what's on the TV."
    );
  }

  // Resolve the caller's household.
  const userSnap = await db.collection("users").doc(uid).get();
  const hid = userSnap.exists ? userSnap.data()?.householdId : null;
  if (!hid) {
    throw new HttpsError(
      "failed-precondition",
      "Your account isn't part of a family yet, so there's nothing to show on the TV."
    );
  }

  // One stable TV identity per household. Re-pairing the same household reuses this uid.
  const tvUid = `tv-${hid}`;
  const customToken = await admin.auth().createCustomToken(tvUid, { householdId: hid, tv: true });

  // Hand the token to the TV and let it into the household's members gate.
  await pairingRef.set(
    {
      status: "paired",
      customToken,
      householdId: hid,
      tvUid,
      pairedByUid: uid,
      pairedAt: admin.firestore.FieldValue.serverTimestamp(),
    },
    { merge: true }
  );
  await db
    .collection("households")
    .doc(hid)
    .update({ members: admin.firestore.FieldValue.arrayUnion(tvUid) });

  return { ok: true, hid, tvUid };
}

module.exports = { pairAppleTV };
