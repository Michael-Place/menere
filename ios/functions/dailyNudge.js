"use strict";

/**
 * Daily "your 3 things" nudge (Act V V2-E) for the `dailyThreeThings` scheduled Cloud Function.
 *
 * A TUNED, quiet push: at most ~3 of the most-actionable items for today — overdue care, a
 * time-boxed renewal (a registration due soon, a $ bill), a birthday to shop for, a child checkup,
 * an imminent event — reusing Radar-style prioritization via `familySignals.gatherSignals`. Returns
 * `null` when there's nothing worth saying, so the scheduler NEVER pushes on an empty day. Selection
 * is deterministic (no model call) so it's cheap and predictable; delivery is the scheduler's job so
 * a harness can exercise it without sending FCM.
 */

const admin = require("firebase-admin");
const { etDateString, gatherSignals, dayLabel } = require("./familySignals");

const BIRTHDAY_STRIP_RX = /\b(birthday|cumplea\w*|bday)\b|🎂|['’]s\b/gi;

/** Clean a birthday label down to the person — "Oliver Birthday 🎂" → "Oliver". */
function birthdayWho(who) {
  const cleaned = String(who || "").replace(BIRTHDAY_STRIP_RX, "").replace(/\s+/g, " ").replace(/[-–]\s*$/,"").trim();
  return cleaned || String(who || "").trim();
}

/**
 * Build the prioritized candidate list. Higher `priority` = more important. `category` drives the
 * "at most 2 per category" diversity rule so the 3 things read as a varied, glanceable set.
 */
function candidates(signals) {
  const out = [];

  // Overdue care — the most actionable (do it now). Japanese maple needs water, HVAC filter, etc.
  for (const c of signals.overdueCare) {
    const text = c.count > 1 ? c.label
      : /needs water|:/.test(c.label) ? c.label
      : `${c.label} is overdue`;
    out.push({ category: "care", priority: 100 + Math.min(c.daysOver, 30), text, meta: { daysOverdue: c.daysOver } });
  }

  // Time-boxed renewals (a registration/bill due soon, with the amount when known).
  for (const r of signals.upcomingRenewals) {
    if (r.days > 14) continue;
    const amt = r.amount != null ? ` — $${Math.round(r.amount)}` : "";
    const when = r.days === 0 ? "today" : r.days === 1 ? "tomorrow" : `by ${dayLabel(r.date)}`;
    out.push({ category: "renewal", priority: 90 + (14 - r.days), text: `${r.label}${amt} due ${when}`, meta: { inDays: r.days, amount: r.amount } });
  }

  // Birthdays to shop for.
  for (const b of signals.birthdays) {
    if (b.days > 10) continue;
    const who = birthdayWho(b.who);
    const when = b.days === 0 ? "today" : b.days === 1 ? "tomorrow" : dayLabel(b.date);
    const text = b.days <= 3 ? `${who}'s birthday is ${when} — time to shop` : `${who}'s birthday is coming (${when})`;
    out.push({ category: "birthday", priority: 85 + (10 - b.days), text, meta: { inDays: b.days } });
  }

  // Child well-visit checkups.
  for (const c of signals.checkups) {
    if (c.days > 14) continue;
    const when = c.days === 0 ? "today" : c.days === 1 ? "tomorrow" : dayLabel(c.date);
    out.push({ category: "checkup", priority: 80 + (14 - c.days), text: `${c.name}'s checkup is ${when}`, meta: { inDays: c.days } });
  }

  // Expired renewals (pet rabies, registrations). Important but often chronic → below time-boxed items.
  for (const r of signals.expiredRenewals) {
    out.push({ category: "expired", priority: 60, text: `${r.label} is expired`, meta: { expiredDaysAgo: -r.days } });
  }

  // An imminent event (next couple of days), lowest of the actionable set.
  for (const e of signals.events) {
    if (e.days > 2) continue;
    const when = e.days === 0 ? "today" : e.days === 1 ? "tomorrow" : dayLabel(e.start);
    out.push({ category: "event", priority: 50 + (2 - e.days), text: `${e.title} — ${when}`, meta: { inDays: e.days } });
  }

  return out.sort((a, b) => b.priority - a.priority);
}

/** Pick the top ≤ limit items, at most 2 per category, preserving priority order. */
function selectTop(cands, limit = 3) {
  const picked = [];
  const perCat = {};
  for (const c of cands) {
    if (picked.length >= limit) break;
    if ((perCat[c.category] || 0) >= 2) continue;
    perCat[c.category] = (perCat[c.category] || 0) + 1;
    picked.push(c);
  }
  return picked;
}

/**
 * Select today's daily nudge for a household.
 *
 * @returns {Promise<null | { title, body, items }>} null on an empty day (nothing worth a push).
 */
async function selectDailyNudge({ db, hid, now = new Date(), persist = true, limit = 3 }) {
  const signals = await gatherSignals(db, hid, { now, eventDays: 10, careDays: 3, horizonDays: 30 });
  const items = selectTop(candidates(signals), limit);
  if (items.length === 0) {
    console.log(`[nudge] empty day — suppressing hid=${hid} date=${etDateString(now)}`);
    return null;
  }

  const n = items.length;
  const title = n === 1 ? "One thing for today" : `Your ${n} things today`;
  const body = items.map((i) => i.text).join("\n");

  if (persist) {
    const dateKey = etDateString(now);
    await db.collection("households").doc(hid).collection("nudges").doc(dateKey).set({
      date: dateKey,
      title,
      body,
      items: items.map((i) => ({ category: i.category, text: i.text })),
      createdAt: admin.firestore.FieldValue.serverTimestamp(),
    });
  }
  console.log(`[nudge] hid=${hid} date=${etDateString(now)} picked=${n}`);
  return { title, body, items };
}

module.exports = { selectDailyNudge };
