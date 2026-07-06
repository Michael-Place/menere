"use strict";

/**
 * Shared family-signal gathering for the Act V V2-E proactive notifications (weekly digest +
 * daily "3 things" nudge). A server-side port of the pieces of `FamilyRadar` (FamilyDomain) that
 * matter for a push: overdue/upcoming CARE, expired/upcoming document RENEWALS, upcoming EVENTS,
 * BIRTHDAYS, child CHECKUPS, and a MONEY glance. Both `digestGenerate.js` and `dailyNudge.js` read
 * from here so they always agree on what's urgent, how it's labeled, and how it's ordered.
 *
 * Everything is READ-ONLY on Firestore and pure otherwise. Times reason in America/New_York (the
 * household default, matching briefingGenerate/receiveEmail). No secrets needed to gather.
 */

const TZ = "America/New_York";

// ---------------------------------------------------------------------------
// Date helpers (ET day-granular, mirroring Document.dayCount / CareTask.daysUntilDue)
// ---------------------------------------------------------------------------

/** YYYY-MM-DD for a Date in ET (en-CA → ISO-ordered parts). */
function etDateString(date) {
  return new Intl.DateTimeFormat("en-CA", {
    timeZone: TZ, year: "numeric", month: "2-digit", day: "2-digit",
  }).format(date);
}

/** Whole ET-calendar-day index for a Date (days since epoch at ET midnight). */
function etDayNumber(date) {
  const [y, m, d] = etDateString(date).split("-").map(Number);
  return Math.floor(Date.UTC(y, m - 1, d) / 86_400_000);
}

/** Whole ET days from `now` to `date` (negative = past). Day-granular, so "today" is 0. */
function dayCount(now, date) {
  return etDayNumber(date) - etDayNumber(now);
}

/** Apple `Calendar.weekday` (1=Sunday … 7=Saturday) for a Date in ET — matches the iOS day picker. */
function etWeekday(date) {
  const [y, m, d] = etDateString(date).split("-").map(Number);
  return new Date(Date.UTC(y, m - 1, d)).getUTCDay() + 1;
}

/** Hour-of-day (0–23) in ET. */
function etHour(date) {
  return Number(
    new Intl.DateTimeFormat("en-US", { timeZone: TZ, hour: "2-digit", hour12: false }).format(date)
  ) % 24;
}

/** ISO-8601 week key `YYYY-Www` for the ET date of `date` (used to key the persisted digest). */
function isoWeekKey(date) {
  const [y, m, d] = etDateString(date).split("-").map(Number);
  const dt = new Date(Date.UTC(y, m - 1, d));
  const day = dt.getUTCDay() || 7;
  dt.setUTCDate(dt.getUTCDate() + 4 - day); // nearest Thursday
  const yearStart = new Date(Date.UTC(dt.getUTCFullYear(), 0, 1));
  const week = Math.ceil(((dt - yearStart) / 86_400_000 + 1) / 7);
  return `${dt.getUTCFullYear()}-W${String(week).padStart(2, "0")}`;
}

/** Firestore Timestamp | Date | ISO string → Date, or null if unparseable. */
function toDate(value) {
  if (!value) return null;
  if (typeof value.toDate === "function") return value.toDate();
  const d = new Date(value);
  return isNaN(d.getTime()) ? null : d;
}

/** First whitespace token of a name — "Sprinkle Fajardo" → "Sprinkle". */
function firstName(full) {
  return String(full || "").trim().split(/\s+/)[0] || String(full || "");
}

/** A short human day label in ET — "Fri, Jul 10". */
function dayLabel(date) {
  return new Intl.DateTimeFormat("en-US", {
    timeZone: TZ, weekday: "short", month: "short", day: "numeric",
  }).format(date);
}

// ---------------------------------------------------------------------------
// Document renewable/historical classification (port of FamilyRadar.classify)
// ---------------------------------------------------------------------------

const RENEWABLE_KEYWORDS = new Set([
  "rabies", "vaccine", "vaccination", "vaccinated", "registration", "license", "licence",
  "permit", "insurance", "policy", "passport", "visa", "membership", "subscription",
  "warranty", "inspection", "renewal", "renew", "certification", "credential",
]);

const HISTORICAL_KEYWORDS = new Set([
  "card", "history", "clinical", "summary", "photo", "statement", "receipt", "invoice",
  "result", "results", "lab", "labs", "discharge", "visit", "note", "notes", "closed",
  "disclosure", "transcript", "diagnosis", "test",
]);

function tokenize(s) {
  return new Set(
    String(s || "").toLowerCase().split(/[^a-z0-9]+/).filter(Boolean)
  );
}

function intersects(setA, setB) {
  for (const x of setA) if (setB.has(x)) return true;
  return false;
}

/** renewable (loud, act-on-it) vs historical (a calm past record). Mirrors FamilyRadar.classify. */
function classifyDoc(doc) {
  if ((doc.type || "other") === "receipt") return "historical";
  const titleTokens = tokenize(doc.title);
  let tagTokens = new Set();
  for (const t of (Array.isArray(doc.tags) ? doc.tags : [])) {
    for (const w of tokenize(t)) tagTokens.add(w);
  }
  if (intersects(titleTokens, HISTORICAL_KEYWORDS) || intersects(tagTokens, HISTORICAL_KEYWORDS)) {
    return "historical";
  }
  if (intersects(titleTokens, RENEWABLE_KEYWORDS)) return "renewable";
  return "historical"; // ambiguous → don't cry wolf
}

/** Strip the pet's name + paperwork nouns → "Sprinkle's Rabies Vaccination Certificate" → "rabies". */
function docLabel(doc, petName) {
  const petFirst = firstName(petName).toLowerCase();
  const drop = new Set([
    "certificate", "certificates", "record", "records", "vaccine", "vaccines",
    "vaccination", "vaccinations", "shot", "shots", "doc", "document", "report", "proof", "the",
  ]);
  const words = String(doc.title || "").split(/\s+/).map((raw) => {
    let w = raw.toLowerCase();
    if (w.endsWith("'s")) w = w.slice(0, -2);
    w = w.replace(/^[^\w]+|[^\w]+$/g, "");
    if (!w || w === petFirst || drop.has(w)) return null;
    return w;
  }).filter(Boolean);
  const label = words.join(" ");
  return label || doc.title;
}

/** A humanized renewal headline — pet-linked → "Sprinkle's rabies", else the doc title. */
function renewalLabel(doc, petName) {
  if (!petName) return String(doc.title || "Document");
  return `${firstName(petName)}'s ${docLabel(doc, petName)}`;
}

function isDismissed(doc, now) {
  const until = toDate(doc.radarDismissedUntil);
  return until != null && until > now;
}

// ---------------------------------------------------------------------------
// Care (port of FamilyRadar.computeCare + CareItem.dueTasks)
// ---------------------------------------------------------------------------

function taskDueDate(task) {
  if (task.intervalDays == null) return null; // manual: never auto-due
  const last = toDate(task.lastDoneAt);
  if (last) return new Date(last.getTime() + task.intervalDays * 86_400_000);
  return toDate(task.firstDueAt); // never done → anchor, or null ⇒ "due today"
}

/** Whole ET days until a task is due; `null` for manual. Un-anchored never-done → 0 (due today). */
function taskDaysUntilDue(task, now) {
  if (task.intervalDays == null) return null;
  const due = taskDueDate(task);
  if (!due) return 0;
  return dayCount(now, due);
}

/** Overdue only when a real anchor (a prior completion OR a firstDueAt) has already passed. */
function taskIsOverdue(task, now) {
  if (task.lastDoneAt == null && task.firstDueAt == null) return null; // no anchor
  const days = taskDaysUntilDue(task, now);
  return days != null && days < 0;
}

const isWateringTask = (task) => String(task.title || "").toLowerCase().includes("water");

/** A short care headline, de-duplicating overlapping name/task (mirrors FamilyRadar.careLabel). */
function careLabel(item, task) {
  const name = String(item.name || "").trim();
  const title = String(task.title || "").trim();
  const n = name.toLowerCase(), t = title.toLowerCase();
  if (t.includes(n)) return title;
  if (n.includes(t)) return name;
  return `${name}: ${title.toLowerCase()}`;
}

/**
 * Overdue care rows (house/pet/plant), most-overdue first. Plant *watering* is summarized: 1 overdue
 * plant → its own row, 2+ → a single "N plants need water" row (32 plants must never be 32 rows).
 */
function computeOverdueCare(careItems, now) {
  const rows = [];
  const overdueWatering = [];
  for (const item of careItems) {
    for (const task of (item.tasks || [])) {
      if (taskIsOverdue(task, now) !== true) continue;
      const daysOver = -(taskDaysUntilDue(task, now) || 0);
      const kind = item.kind || "house";
      if (kind === "plant" && isWateringTask(task)) {
        overdueWatering.push({ item, task, daysOver });
      } else if (kind === "plant") {
        rows.push({ label: careLabel(item, task), category: "plant", daysOver, count: 1 });
      } else if (kind === "pet") {
        rows.push({ label: `${firstName(item.name)}: ${String(task.title).toLowerCase()}`, category: "pet", daysOver, count: 1 });
      } else {
        rows.push({ label: careLabel(item, task), category: "house", daysOver, count: 1 });
      }
    }
  }
  if (overdueWatering.length === 1) {
    const only = overdueWatering[0];
    rows.push({ label: `${only.item.name}: needs water`, category: "plant", daysOver: only.daysOver, count: 1 });
  } else if (overdueWatering.length > 1) {
    const worst = Math.max(...overdueWatering.map((o) => o.daysOver));
    rows.push({ label: `${overdueWatering.length} plants need water`, category: "plant", daysOver: worst, count: overdueWatering.length });
  }
  return rows.sort((a, b) => b.daysOver - a.daysOver);
}

/** Care coming due (not yet overdue) within `withinDays`, soonest first — for the week-ahead digest. */
function computeUpcomingCare(careItems, now, withinDays) {
  const rows = [];
  for (const item of careItems) {
    for (const task of (item.tasks || [])) {
      const days = taskDaysUntilDue(task, now);
      if (days == null || days < 0 || days > withinDays) continue;
      if (taskIsOverdue(task, now) === true) continue;
      rows.push({ label: careLabel(item, task), category: item.kind || "house", days });
    }
  }
  return rows.sort((a, b) => a.days - b.days);
}

// ---------------------------------------------------------------------------
// Child well-visit checkups (light AAP-style schedule; only fires when a birthdate is set)
// ---------------------------------------------------------------------------

// AAP well-child visit ages, in months. After 36mo the schedule is yearly.
const WELL_VISIT_MONTHS = [1, 2, 4, 6, 9, 12, 15, 18, 24, 30, 36, 48, 60, 72, 84, 96, 108, 120];

function upcomingCheckups(members, now, horizonDays) {
  const out = [];
  for (const m of members) {
    const birth = toDate(m.birthdate);
    if (!birth) continue;
    const ageMonths = Math.max(0,
      (now.getFullYear() - birth.getFullYear()) * 12 + (now.getMonth() - birth.getMonth()));
    const next = WELL_VISIT_MONTHS.find((mo) => mo >= ageMonths);
    if (next == null) continue;
    const due = new Date(birth.getTime());
    due.setMonth(due.getMonth() + next);
    const days = dayCount(now, due);
    if (days < 0 || days > horizonDays) continue;
    out.push({ name: firstName(m.name), months: next, date: due, days });
  }
  return out.sort((a, b) => a.days - b.days);
}

// ---------------------------------------------------------------------------
// Birthdays (member birthdates + calendar events that name a birthday)
// ---------------------------------------------------------------------------

const BIRTHDAY_RX = /birthday|cumplea|bday|🎂/i;

function upcomingBirthdays(members, events, now, horizonDays) {
  const out = [];
  // From member birthdates → next anniversary within the horizon.
  for (const m of members) {
    const birth = toDate(m.birthdate);
    if (!birth) continue;
    const [ny] = etDateString(now).split("-").map(Number);
    for (const year of [ny, ny + 1]) {
      const anniv = new Date(Date.UTC(year, birth.getMonth(), birth.getDate()));
      const days = dayCount(now, anniv);
      if (days >= 0 && days <= horizonDays) {
        out.push({ who: firstName(m.name), date: anniv, days });
        break;
      }
    }
  }
  // From calendar events that name a birthday (covers people without a stored birthdate).
  for (const e of events) {
    if (!BIRTHDAY_RX.test(String(e.title || ""))) continue;
    out.push({ who: String(e.title).trim(), date: e.start, days: e.days, fromEvent: true });
  }
  return out.sort((a, b) => a.days - b.days);
}

// ---------------------------------------------------------------------------
// The big gather
// ---------------------------------------------------------------------------

/**
 * Gather every proactive signal for a household. Read-only. `horizonDays` bounds the "upcoming"
 * windows (default 90 for renewals; events/care/checkups use their own tighter windows).
 *
 * @returns {Promise<object>} { overdueCare, upcomingCare, expiredRenewals, upcomingRenewals,
 *   events, birthdays, checkups, money, memberNames }
 */
async function gatherSignals(db, hid, { now = new Date(), eventDays = 7, careDays = 7, horizonDays = 90 } = {}) {
  const householdRef = db.collection("households").doc(hid);
  const [membersSnap, careSnap, docsSnap, eventsSnap, expensesSnap] = await Promise.all([
    householdRef.collection("members").get(),
    householdRef.collection("careItems").get(),
    householdRef.collection("documents").get(),
    householdRef.collection("events").get(),
    householdRef.collection("expenses").get(),
  ]);

  const members = membersSnap.docs.map((d) => ({ id: d.id, ...(d.data() || {}) }));
  const memberNames = members.map((m) => firstName(m.name)).filter(Boolean);
  const careItems = careSnap.docs.map((d) => ({ id: d.id, ...(d.data() || {}) }));
  const pets = careItems.filter((c) => (c.kind || "") === "pet");

  // ---- Care ----
  const overdueCare = computeOverdueCare(careItems, now);
  const upcomingCare = computeUpcomingCare(careItems, now, careDays);

  // ---- Documents → renewals ----
  const expiredRenewals = [];
  const upcomingRenewals = [];
  for (const dd of docsSnap.docs) {
    const doc = { id: dd.id, ...(dd.data() || {}) };
    const petName = (pets.find((p) => (doc.linkedPetIds || []).includes(p.id)) || {}).name || null;
    const kind = classifyDoc(doc);
    const expiry = toDate(doc.expiryDate);
    const due = toDate(doc.dueDate);

    if (expiry) {
      const days = dayCount(now, expiry);
      if (days < 0) {
        if (kind === "renewable" && !isDismissed(doc, now)) {
          expiredRenewals.push({ label: renewalLabel(doc, petName), petName, days, date: expiry, title: doc.title, amount: doc.amount ?? null });
        }
        continue; // past expiry claims the doc
      }
    }
    if (kind !== "renewable" || isDismissed(doc, now)) continue;

    const cands = [];
    if (due) cands.push({ date: due, kind: "due" });
    if (expiry) cands.push({ date: expiry, kind: "expiry" });
    const soonest = cands
      .map((c) => ({ ...c, days: dayCount(now, c.date) }))
      .filter((c) => c.days >= 0 && c.days <= horizonDays)
      .sort((a, b) => a.days - b.days)[0];
    if (soonest) {
      upcomingRenewals.push({
        label: renewalLabel(doc, petName), petName, days: soonest.days, date: soonest.date,
        dateKind: soonest.kind, title: doc.title, amount: doc.amount ?? null, vendor: doc.vendor ?? null,
      });
    }
  }
  expiredRenewals.sort((a, b) => a.days - b.days);   // most overdue first
  upcomingRenewals.sort((a, b) => a.days - b.days);  // soonest first

  // ---- Events (upcoming, non-recurring, within eventDays) ----
  const eventsAll = [];
  for (const e of eventsSnap.docs) {
    const data = e.data() || {};
    const start = toDate(data.startDate);
    if (!start) continue;
    if ((data.recurrence || "none") !== "none") continue; // no server recurrence expansion
    const days = dayCount(now, start);
    if (days < 0 || days > eventDays) continue;
    eventsAll.push({ title: String(data.title || "Untitled"), start, days, isAllDay: !!data.isAllDay });
  }
  eventsAll.sort((a, b) => a.days - b.days);
  const birthdays = upcomingBirthdays(members, eventsAll, now, eventDays);
  // Plain events exclude the birthday-flagged ones (surfaced separately).
  const events = eventsAll.filter((e) => !BIRTHDAY_RX.test(e.title));

  // ---- Checkups ----
  const checkups = upcomingCheckups(members, now, horizonDays);

  // ---- Money glance (this ET month) ----
  const thisMonth = etDateString(now).slice(0, 7);
  const byCat = {};
  let monthTotal = 0, monthCount = 0;
  for (const x of expensesSnap.docs) {
    const data = x.data() || {};
    const date = toDate(data.date);
    if (!date || etDateString(date).slice(0, 7) !== thisMonth) continue;
    const amt = Number(data.amount) || 0;
    monthTotal += amt; monthCount += 1;
    const cat = data.category || "other";
    byCat[cat] = (byCat[cat] || 0) + amt;
  }
  const topCategory = Object.entries(byCat).sort((a, b) => b[1] - a[1])[0] || null;
  const money = {
    hasData: monthCount > 0,
    month: thisMonth,
    total: Math.round(monthTotal * 100) / 100,
    count: monthCount,
    topCategory: topCategory ? { category: topCategory[0], amount: Math.round(topCategory[1] * 100) / 100 } : null,
  };

  return {
    overdueCare, upcomingCare, expiredRenewals, upcomingRenewals,
    events, birthdays, checkups, money, memberNames,
  };
}

// ---------------------------------------------------------------------------
// Notification preferences (households/{hid}/config/notificationPrefs) + gates
// ---------------------------------------------------------------------------

/** Read the household's notification prefs (decode-safe; defaults match the Swift `NotificationPrefs`). */
async function readNotificationPrefs(db, hid) {
  const snap = await db.collection("households").doc(hid).collection("config").doc("notificationPrefs").get();
  const d = snap.exists ? (snap.data() || {}) : {};
  const int = (v, dflt) => (Number.isInteger(v) ? v : dflt);
  return {
    weeklyDigestEnabled: d.weeklyDigestEnabled !== false,        // default ON
    weeklyDigestWeekday: int(d.weeklyDigestWeekday, 1),          // default Sunday (Apple weekday 1)
    dailyNudgeEnabled: d.dailyNudgeEnabled !== false,            // default ON
    quietHoursEnabled: d.quietHoursEnabled === true,             // default OFF (8am delivery is safe anyway)
    quietHoursStart: int(d.quietHoursStart, 21),                 // default 21:00
    quietHoursEnd: int(d.quietHoursEnd, 7),                      // default 07:00
  };
}

/** Whether `now` (ET) falls inside the prefs' quiet-hours window. Handles overnight windows. */
function inQuietHours(now, prefs) {
  if (!prefs.quietHoursEnabled) return false;
  const h = etHour(now);
  const { quietHoursStart: s, quietHoursEnd: e } = prefs;
  if (s === e) return false;
  return s < e ? (h >= s && h < e) : (h >= s || h < e);
}

module.exports = {
  TZ, etDateString, etWeekday, etHour, isoWeekKey, dayCount, toDate, firstName, dayLabel,
  classifyDoc, renewalLabel, gatherSignals, readNotificationPrefs, inQuietHours,
};
