"use strict";

/**
 * Notify-only FCM triggers for Menere's family features.
 *
 * IMPORTANT: these are *notification only*. XP/stats and the activity feed are written
 * client-side, so these triggers deliberately do NOT touch memberStats or activity — they
 * only fan a push message out to the household's other devices.
 *
 * Recipient discovery: the `households/{hid}` doc holds `members: [uid]`; each `users/{uid}`
 * doc holds an optional `fcmToken`. We collect tokens and multicast.
 */

const admin = require("firebase-admin");

/** Fetch FCM tokens for every member of a household, optionally excluding one uid (the actor). */
async function householdTokens(db, hid, excludeUid) {
  const householdSnap = await db.collection("households").doc(hid).get();
  const members = householdSnap.exists && Array.isArray(householdSnap.data().members)
    ? householdSnap.data().members
    : [];
  const tokens = [];
  for (const uid of members) {
    if (excludeUid && uid === excludeUid) continue;
    const userSnap = await db.collection("users").doc(uid).get();
    const token = userSnap.exists ? userSnap.data().fcmToken : null;
    if (typeof token === "string" && token.length > 0) tokens.push(token);
  }
  return tokens;
}

/** Multicast a title/body to a household's members. No-op when there are no tokens. */
async function notifyHousehold(db, hid, { title, body }, excludeUid) {
  const tokens = await householdTokens(db, hid, excludeUid);
  if (tokens.length === 0) return;
  await admin.messaging().sendEachForMulticast({
    tokens,
    notification: { title, body },
  });
}

module.exports = { notifyHousehold };
