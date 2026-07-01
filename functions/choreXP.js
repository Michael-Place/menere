"use strict";

/**
 * Server-authoritative chore XP for Menere (replaces the earlier client-side XP logic so two
 * offline devices can't each award from stale local state). Mirrors the app's XPCalculator:
 * base XP by difficulty + streak bonus (+10%/streak day, cap 50%) + on-time bonus (+25%).
 *
 * All mutations run in a transaction and are idempotent: `awardChoreXP` no-ops if the chore
 * already has an `xpAwarded` value (guards against at-least-once trigger delivery).
 *
 * Streak day-boundaries use UTC (households don't store a timezone).
 */

const admin = require("firebase-admin");

const BASE_XP = { easy: 10, medium: 25, hard: 50 };
const baseXP = (difficulty) => BASE_XP[difficulty] || BASE_XP.easy;

function levelForXP(totalXP) {
  let level = 1;
  while ((50 * (level + 1) * level) / 2 <= totalXP) level += 1;
  return level;
}

function sameUTCDate(a, b) {
  return (
    a.getUTCFullYear() === b.getUTCFullYear() &&
    a.getUTCMonth() === b.getUTCMonth() &&
    a.getUTCDate() === b.getUTCDate()
  );
}

function isYesterdayUTC(prev, now) {
  const y = new Date(now);
  y.setUTCDate(y.getUTCDate() - 1);
  return sameUTCDate(prev, y);
}

/** Award XP for a just-completed chore. Returns the amount awarded (0 if skipped). */
async function awardChoreXP(db, hid, choreID, chore) {
  const creditID = chore.completedByMemberID;
  if (!creditID) return 0;

  const statsRef = db.collection("households").doc(hid).collection("memberStats").doc(creditID);
  const choreRef = db.collection("households").doc(hid).collection("chores").doc(choreID);
  const now = new Date();
  let awarded = 0;

  await db.runTransaction(async (tx) => {
    const choreSnap = await tx.get(choreRef);
    const c = choreSnap.exists ? choreSnap.data() : {};
    if (!c.isCompleted) return;                 // no longer completed
    if (c.xpAwarded && c.xpAwarded > 0) return; // already awarded — idempotent

    const statsSnap = await tx.get(statsRef);
    const s = statsSnap.exists ? statsSnap.data() : {};
    const currentStreak = s.currentStreak || 0;
    const lastCompletedAt = s.lastCompletedAt ? s.lastCompletedAt.toDate() : null;

    let newStreak = 1;
    if (lastCompletedAt) {
      if (sameUTCDate(lastCompletedAt, now)) newStreak = Math.max(1, currentStreak);
      else if (isYesterdayUTC(lastCompletedAt, now)) newStreak = currentStreak + 1;
    }

    const base = baseXP(chore.difficulty);
    const streakBonus = Math.floor(base * Math.min(0.5, newStreak * 0.1));
    let onTime = 0;
    const dueDate = chore.dueDate ? chore.dueDate.toDate() : null;
    if (dueDate && now < dueDate) onTime = Math.floor(base * 0.25);
    awarded = base + streakBonus + onTime;

    const totalXP = (s.totalXP || 0) + awarded;
    tx.set(
      statsRef,
      {
        id: creditID,
        memberID: creditID,
        totalXP,
        level: levelForXP(totalXP),
        choresCompleted: (s.choresCompleted || 0) + 1,
        currentStreak: newStreak,
        longestStreak: Math.max(s.longestStreak || 0, newStreak),
        lastCompletedAt: admin.firestore.Timestamp.fromDate(now),
        updatedAt: admin.firestore.Timestamp.fromDate(now),
      },
      { merge: true }
    );
    // Record the awarded amount on the chore. isCompleted is unchanged, so the resulting
    // document update does NOT re-enter the completion branch of onChoreToggled.
    tx.set(choreRef, { xpAwarded: awarded, streak: newStreak }, { merge: true });
  });

  return awarded;
}

/** Reverse a previously-awarded chore (on uncompletion). Uses the pre-update chore snapshot. */
async function reverseChoreXP(db, hid, choreID, chore) {
  const creditID = chore.completedByMemberID;
  const awarded = chore.xpAwarded || 0;

  // Always clear the award marker so a later re-completion isn't blocked by the idempotency
  // guard. (The client's merge-write can't reliably null a field, so the server owns this.)
  await db
    .collection("households").doc(hid).collection("chores").doc(choreID)
    .set({ xpAwarded: admin.firestore.FieldValue.delete() }, { merge: true });

  if (!creditID || awarded <= 0) return;

  const statsRef = db.collection("households").doc(hid).collection("memberStats").doc(creditID);
  await db.runTransaction(async (tx) => {
    const statsSnap = await tx.get(statsRef);
    if (!statsSnap.exists) return;
    const s = statsSnap.data();
    const totalXP = Math.max(0, (s.totalXP || 0) - awarded);
    tx.set(
      statsRef,
      {
        totalXP,
        level: levelForXP(totalXP),
        choresCompleted: Math.max(0, (s.choresCompleted || 0) - 1),
        updatedAt: admin.firestore.Timestamp.now(),
      },
      { merge: true }
    );
  });
}

module.exports = { awardChoreXP, reverseChoreXP };
