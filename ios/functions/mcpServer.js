"use strict";

/**
 * mcpServer — a true MCP (Model Context Protocol) server over the family's Firestore, hosted as a
 * Firebase v2 `onRequest` Cloud Function (P14-C4-C1). It lets Michael point an MCP client
 * (Claude Desktop / Claude Code / claude.ai) at the ¡Bacán! family hub and read the family brain
 * from anywhere. House CONTROL stays app-side (the LAN lives on the phone); this exposes read/query
 * tools (C1) plus write/action tools (C2 — mark_care_done, complete_chore, add_event, add_to_list,
 * check_off_list_item, log_expense, create_memory), each scoped to the authed household and reusing
 * the app's exact Firestore shapes. No smart-home/LAN/lock/garage control is exposed here.
 *
 * ## Transport
 * MCP over **streamable HTTP** (2025-06-18). The server is *stateless*: every request is an
 * independent JSON-RPC 2.0 call carrying its own bearer token, so it maps perfectly onto a Functions
 * v2 request/response with no session state to keep warm. We hand-roll the JSON-RPC dispatch rather
 * than pull in `@modelcontextprotocol/sdk`: the SDK's StreamableHTTP transport is built around a
 * long-lived Node server with SSE session management, which is awkward and fragile on the Functions
 * runtime. A correct minimal implementation of `initialize` / `tools/list` / `tools/call` /
 * `notifications/*` / `ping` is more robust here and adds zero dependencies.
 *
 * ## Auth (per-household bearer token)
 * The server is private. Every request must carry `Authorization: Bearer <token>`. The token embeds
 * the household id — `bcn~<hid>~<48-hex>` — so validation is a single direct doc read (no
 * collection-group index needed): parse the hid, load `households/{hid}/config/mcpToken`, and
 * constant-time-compare the full token. Missing/invalid → 401. All tool results are scoped to the
 * authed household. (Re)generate a token with the `regenerateMcpToken` callable or via Admin SDK —
 * see `scripts/mcpToken.js`.
 */

const crypto = require("crypto");
const admin = require("firebase-admin");

const SERVER_NAME = "bacan-family";
const SERVER_VERSION = "0.1.0";
const DEFAULT_PROTOCOL = "2025-06-18";
const HOUSEHOLD_TZ = "America/New_York"; // the family's default zone (matches receiveEmail/briefings)

// -----------------------------------------------------------------------------
// Token generation + validation
// -----------------------------------------------------------------------------

/** Mint a fresh opaque token that embeds the household id: `bcn~<hid>~<48 hex>`. */
function mintToken(hid) {
  return `bcn~${hid}~${crypto.randomBytes(24).toString("hex")}`;
}

/** Pull the raw token out of an `Authorization: Bearer <token>` header. */
function bearerFrom(header) {
  if (typeof header !== "string") return null;
  const m = /^Bearer\s+(.+)$/i.exec(header.trim());
  return m ? m[1].trim() : null;
}

/**
 * Validate a bearer token and return the household id it belongs to, or `null`. Parses the hid out
 * of the token, reads the stored token doc, and constant-time-compares. Never throws.
 */
async function authenticate(db, token) {
  if (!token) return null;
  const parts = token.split("~");
  if (parts.length !== 3 || parts[0] !== "bcn") return null;
  const hid = parts[1];
  if (!hid) return null;
  let snap;
  try {
    snap = await db.collection("households").doc(hid).collection("config").doc("mcpToken").get();
  } catch (_) {
    return null;
  }
  if (!snap.exists) return null;
  const stored = snap.data() && snap.data().token;
  if (typeof stored !== "string") return null;
  const a = Buffer.from(stored);
  const b = Buffer.from(token);
  if (a.length !== b.length) return null;
  if (!crypto.timingSafeEqual(a, b)) return null;
  return hid;
}

// -----------------------------------------------------------------------------
// Date helpers (mirror the Swift CareTask/Document due-date conventions)
// -----------------------------------------------------------------------------

function tsToDate(v) {
  if (!v) return null;
  if (typeof v.toDate === "function") return v.toDate();
  if (typeof v._seconds === "number") return new Date(v._seconds * 1000);
  if (v instanceof Date) return v;
  if (typeof v === "string") {
    const d = new Date(v);
    return isNaN(d.getTime()) ? null : d;
  }
  return null;
}

/** YYYY-MM-DD for a date in the household's zone. */
function etDateString(d) {
  return new Intl.DateTimeFormat("en-CA", {
    timeZone: HOUSEHOLD_TZ, year: "numeric", month: "2-digit", day: "2-digit",
  }).format(d);
}

/** UTC-ms marker for midnight-in-ET of the given date (for whole-day differences). */
function etDayStart(d) {
  const [y, m, day] = etDateString(d).split("-").map(Number);
  return Date.UTC(y, m - 1, day);
}

/** Whole ET days from `now` to `target` (negative = past). */
function dayDiff(now, target) {
  return Math.round((etDayStart(target) - etDayStart(now)) / 86400000);
}

/** Human ET timestamp for an event ("Fri, Jul 10, 8:00 AM"). */
function whenString(d, isAllDay) {
  if (!d) return null;
  const opts = isAllDay
    ? { weekday: "short", month: "short", day: "numeric", timeZone: HOUSEHOLD_TZ }
    : { weekday: "short", month: "short", day: "numeric", hour: "numeric", minute: "2-digit", timeZone: HOUSEHOLD_TZ };
  return new Intl.DateTimeFormat("en-US", opts).format(d);
}

/**
 * Next-due resolution for a CareTask, matching `CareTask.dueAt`/`daysUntilDue` in Swift:
 *   - manual (no interval) → never auto-due
 *   - done before → lastDoneAt + intervalDays
 *   - never done but anchored (firstDueAt) → firstDueAt
 *   - never done, no anchor → due today
 * `overdue` is only true when a real anchor (a prior completion OR a firstDueAt) is in the past.
 */
function careTaskStatus(task, now) {
  const interval = Number.isFinite(task.intervalDays) ? task.intervalDays : null;
  if (interval == null) return { manual: true };
  const last = tsToDate(task.lastDoneAt);
  const first = tsToDate(task.firstDueAt);
  let due;
  const anchored = !!(last || first);
  if (last) due = new Date(last.getTime() + interval * 86400000);
  else if (first) due = first;
  else due = now; // never done, no anchor → due today
  const days = dayDiff(now, due);
  return {
    manual: false,
    dueDate: etDateString(due),
    daysUntilDue: days,
    overdue: anchored && days < 0,
    due: days <= 0,
  };
}

// -----------------------------------------------------------------------------
// Firestore loaders (scoped to one household)
// -----------------------------------------------------------------------------

function hh(db, hid) { return db.collection("households").doc(hid); }

async function loadMemberNames(db, hid) {
  const snap = await hh(db, hid).collection("members").get();
  const map = {};
  snap.docs.forEach((d) => { map[d.id] = (d.data() && d.data().name) || d.id; });
  return map;
}

function nameList(ids, map) {
  return (Array.isArray(ids) ? ids : []).map((id) => map[id] || id);
}

async function loadCareItems(db, hid, kind) {
  let q = hh(db, hid).collection("careItems");
  if (kind) q = q.where("kind", "==", kind);
  const snap = await q.get();
  return snap.docs.map((d) => d.data());
}

async function loadDocuments(db, hid, cap = 500) {
  const snap = await hh(db, hid).collection("documents").limit(cap).get();
  return snap.docs.map((d) => d.data());
}

async function loadHousehold(db, hid) {
  const snap = await hh(db, hid).get();
  return snap.exists ? (snap.data() || {}) : {};
}

// -----------------------------------------------------------------------------
// Write helpers (C2 action tools) — every write is scoped to the authed household
// and, by default, ACTS AS the household ownerUid. A caller may attribute an action
// to a specific family member by passing a validated `memberId`. Tool-written docs
// are tagged `via: "mcp"` so it's clear they came through the assistant/MCP server
// (the field is additive — the Swift Codable models ignore unknown keys).
// -----------------------------------------------------------------------------

/** A fresh UPPERCASE UUID doc id, matching the app's Swift `UUID().uuidString`. */
function newId() { return crypto.randomUUID().toUpperCase(); }

/**
 * Resolve the acting member for a write. Writes act as the household `ownerUid` by default; a
 * caller may pass a `memberId` to attribute the action to a specific family member (validated
 * against the members roster). Returns `{ uid, name }`. Never fabricates a fake member.
 */
async function resolveActor(db, hid, memberId, nameMap, household) {
  const members = nameMap || (await loadMemberNames(db, hid));
  const hhData = household || (await loadHousehold(db, hid));
  const owner = hhData.ownerUid || (Array.isArray(hhData.members) ? hhData.members[0] : null) || null;
  if (memberId && members[memberId]) return { uid: memberId, name: members[memberId] };
  return { uid: owner, name: owner ? (members[owner] || null) : null };
}

/**
 * Parse a date input: a bare `YYYY-MM-DD` (interpreted at noon UTC so the ET calendar day never
 * slips) or a full ISO timestamp. Returns `{ date, dateOnly }` or `null`.
 */
function parseDateInput(v) {
  if (typeof v !== "string" || !v.trim()) return null;
  const s = v.trim();
  if (/^\d{4}-\d{2}-\d{2}$/.test(s)) {
    const d = new Date(s + "T12:00:00Z");
    return isNaN(d.getTime()) ? null : { date: d, dateOnly: true };
  }
  const d = new Date(s);
  return isNaN(d.getTime()) ? null : { date: d, dateOnly: false };
}

/** Past-tense verb for a care-task completion (mirrors `ActivityItem.careVerb` in Swift). */
function careVerb(task) {
  const t = (task || "").toLowerCase();
  if (!t) return "took care of";
  if (t.includes("water")) return "watered";
  if (t.includes("fertil")) return "fertilized";
  if (t.includes("feed")) return "fed";
  if (t.includes("re-pot") || t.includes("repot")) return "repotted";
  if (t.includes("prune")) return "pruned";
  if (t.includes("rotate")) return "rotated";
  if (t.includes("mist")) return "misted";
  if (t.includes("leaves") || t.includes("wipe")) return "wiped down";
  if (t.includes("pest")) return "checked";
  if (t.includes("groom")) return "groomed";
  if (t.includes("nail")) return "trimmed nails for";
  if (t.includes("walk")) return "walked";
  if (t.includes("bath")) return "bathed";
  return "took care of";
}

/** Build + persist an activity-feed doc (best-effort parity with the app's `logActivity`). */
async function writeActivity(db, hid, { text, systemImage, actorID }) {
  const id = newId();
  await hh(db, hid).collection("activity").doc(id).set({
    id, text, systemImage: systemImage || "sparkles",
    actorID: actorID || null, createdAt: new Date(), via: "mcp",
  });
  return id;
}

/**
 * The next occurrence of a recurring chore (mirrors `ChoreCompletion.nextOccurrence`): a fresh
 * incomplete copy with its due date advanced one interval. `null` for non-recurring chores.
 */
function nextChoreOccurrence(chore) {
  const steps = { daily: ["d", 1], weekly: ["d", 7], biweekly: ["d", 14], monthly: ["m", 1], yearly: ["y", 1] };
  const step = steps[chore.recurrence || "none"];
  if (!step) return null;
  const base = tsToDate(chore.dueDate) || new Date();
  const next = new Date(base);
  if (step[0] === "d") next.setDate(next.getDate() + step[1]);
  else if (step[0] === "m") next.setMonth(next.getMonth() + step[1]);
  else next.setFullYear(next.getFullYear() + step[1]);
  return {
    id: newId(),
    title: chore.title,
    assigneeID: chore.assigneeID || null,
    dueDate: next,
    recurrence: chore.recurrence,
    difficulty: chore.difficulty || "easy",
    isCompleted: false,
    streak: chore.streak || 0,
    createdAt: new Date(),
    via: "mcp",
  };
}

// -----------------------------------------------------------------------------
// Tools — each { name, description, inputSchema, run(db, hid, args) }
// -----------------------------------------------------------------------------

const TOOLS = [
  {
    name: "get_plants",
    description:
      "List the family's houseplants & garden plants (name, species, location, light, and next " +
      "watering/care due). Use to answer 'what needs water?' or 'where is the monstera?'. Results " +
      "are summarized when large.",
    inputSchema: {
      type: "object",
      properties: {
        onlyThirsty: { type: "boolean", description: "Only plants that are due or overdue for care." },
        location: { type: "string", description: "Filter to a room/area (case-insensitive substring)." },
        limit: { type: "integer", description: "Max plants to return (default 60).", minimum: 1, maximum: 200 },
      },
      additionalProperties: false,
    },
    async run(db, hid, args) {
      const now = new Date();
      const nameMap = await loadMemberNames(db, hid);
      let items = await loadCareItems(db, hid, "plant");
      const loc = (args.location || "").trim().toLowerCase();
      if (loc) items = items.filter((p) => (p.location || "").toLowerCase().includes(loc));
      const rows = items.map((p) => {
        const statuses = (p.tasks || []).map((t) => ({ title: t.title, ...careTaskStatus(t, now), by: nameMap[t.lastDoneBy] }));
        const active = statuses.filter((s) => !s.manual);
        const soonest = active.slice().sort((a, b) => a.daysUntilDue - b.daysUntilDue)[0] || null;
        return {
          name: p.name,
          species: p.species || null,
          speciesLatin: p.speciesLatin || null,
          location: p.location || null,
          light: p.lightLevel || null,
          thirsty: soonest ? soonest.due : false,
          nextCare: soonest ? { task: soonest.title, dueDate: soonest.dueDate, daysUntilDue: soonest.daysUntilDue, overdue: soonest.overdue } : null,
          petToxic: p.speciesProfile && p.speciesProfile.petToxicity ? !!p.speciesProfile.petToxicity.isToxicToPets : null,
        };
      });
      const thirsty = rows.filter((r) => r.thirsty);
      let out = args.onlyThirsty ? thirsty : rows;
      out = out.slice().sort((a, b) => {
        const da = a.nextCare ? a.nextCare.daysUntilDue : 9999;
        const db2 = b.nextCare ? b.nextCare.daysUntilDue : 9999;
        return da - db2;
      });
      const limit = Math.min(Math.max(parseInt(args.limit, 10) || 60, 1), 200);
      return {
        totalPlants: rows.length,
        thirstyCount: thirsty.length,
        returned: Math.min(out.length, limit),
        plants: out.slice(0, limit),
      };
    },
  },

  {
    name: "get_pets",
    description:
      "List the family pets (dogs Fajita & Sprinkle, cat Fireball): name, breed, age, the soonest " +
      "care task (heartworm/flea/grooming), and any vaccine/record expiry status from the Family Brain.",
    inputSchema: { type: "object", properties: {}, additionalProperties: false },
    async run(db, hid) {
      const now = new Date();
      const nameMap = await loadMemberNames(db, hid);
      const pets = await loadCareItems(db, hid, "pet");
      const docs = await loadDocuments(db, hid);
      // Map petId -> expiring/expired records (documents linked to this pet with an expiryDate).
      const recordsByPet = {};
      for (const d of docs) {
        const exp = tsToDate(d.expiryDate);
        if (!exp) continue;
        for (const petId of d.linkedPetIds || []) {
          (recordsByPet[petId] = recordsByPet[petId] || []).push({
            title: d.title, vendor: d.vendor || null, expiryDate: etDateString(exp),
            daysUntilExpiry: dayDiff(now, exp), expired: dayDiff(now, exp) < 0,
          });
        }
      }
      const rows = pets.map((p) => {
        const statuses = (p.tasks || []).map((t) => ({ title: t.title, ...careTaskStatus(t, now), by: nameMap[t.lastDoneBy] }));
        const active = statuses.filter((s) => !s.manual).sort((a, b) => a.daysUntilDue - b.daysUntilDue);
        const soonest = active[0] || null;
        const bday = tsToDate(p.birthday);
        let ageYears = null;
        if (bday) ageYears = Math.floor((now - bday) / (365.25 * 86400000));
        const recs = (recordsByPet[p.id] || []).sort((a, b) => a.daysUntilExpiry - b.daysUntilExpiry);
        return {
          name: p.name,
          breed: p.breed || null,
          ageYears,
          vet: p.vetName || null,
          soonestCare: soonest ? { task: soonest.title, dueDate: soonest.dueDate, daysUntilDue: soonest.daysUntilDue, overdue: soonest.overdue } : null,
          records: recs,
          hasExpiredRecord: recs.some((r) => r.expired),
        };
      });
      return { totalPets: rows.length, pets: rows };
    },
  },

  {
    name: "search_documents",
    description:
      "Search the Family Brain document vault (receipts, medical, school, tax, manuals) by free text, " +
      "vendor, and/or type. Returns matching docs with title, type, vendor, amount, and dates.",
    inputSchema: {
      type: "object",
      properties: {
        query: { type: "string", description: "Free text matched against title/summary/vendor/tags/extracted text." },
        vendor: { type: "string", description: "Filter by vendor/issuer (case-insensitive substring)." },
        type: { type: "string", description: "Document type.", enum: ["receipt", "medical", "school", "pet", "tax", "manual", "other"] },
        limit: { type: "integer", description: "Max results (default 20).", minimum: 1, maximum: 50 },
      },
      additionalProperties: false,
    },
    async run(db, hid, args) {
      const nameMap = await loadMemberNames(db, hid);
      const docs = await loadDocuments(db, hid);
      const q = (args.query || "").trim().toLowerCase();
      const vendorFilter = (args.vendor || "").trim().toLowerCase();
      const typeFilter = (args.type || "").trim().toLowerCase();
      let matches = docs.filter((d) => {
        if (typeFilter && (d.type || "other").toLowerCase() !== typeFilter) return false;
        if (vendorFilter && !((d.vendor || "").toLowerCase().includes(vendorFilter))) return false;
        if (q) {
          const hay = [d.title, d.summary, d.vendor, (d.tags || []).join(" "), d.extractedText, (d.type || "")]
            .filter(Boolean).join(" ").toLowerCase();
          if (!hay.includes(q)) return false;
        }
        return true;
      });
      const limit = Math.min(Math.max(parseInt(args.limit, 10) || 20, 1), 50);
      const total = matches.length;
      matches = matches
        .sort((a, b) => (tsToDate(b.createdAt) || 0) - (tsToDate(a.createdAt) || 0))
        .slice(0, limit)
        .map((d) => ({
          title: d.title,
          type: d.type || "other",
          vendor: d.vendor || null,
          amount: typeof d.amount === "number" ? d.amount : null,
          docDate: tsToDate(d.docDate) ? etDateString(tsToDate(d.docDate)) : null,
          dueDate: tsToDate(d.dueDate) ? etDateString(tsToDate(d.dueDate)) : null,
          expiryDate: tsToDate(d.expiryDate) ? etDateString(tsToDate(d.expiryDate)) : null,
          tags: d.tags || [],
          summary: d.summary || null,
          linkedMembers: nameList(d.linkedMemberIds, nameMap),
        }));
      return { totalMatches: total, returned: matches.length, documents: matches };
    },
  },

  {
    name: "get_events",
    description:
      "Upcoming family calendar events, soonest first. Answers 'what's on the calendar?' / 'what " +
      "time is Oliver's KinderCare thing?'.",
    inputSchema: {
      type: "object",
      properties: {
        daysAhead: { type: "integer", description: "Only events within this many days (default: no limit).", minimum: 1, maximum: 730 },
        limit: { type: "integer", description: "Max events (default 20).", minimum: 1, maximum: 100 },
      },
      additionalProperties: false,
    },
    async run(db, hid, args) {
      const now = new Date();
      const nameMap = await loadMemberNames(db, hid);
      const snap = await hh(db, hid).collection("events").get();
      let events = snap.docs.map((d) => d.data()).filter((e) => {
        const start = tsToDate(e.startDate);
        return start && start >= new Date(now.getTime() - 12 * 3600 * 1000); // keep today's earlier-today events
      });
      const daysAhead = parseInt(args.daysAhead, 10);
      if (Number.isFinite(daysAhead)) {
        events = events.filter((e) => dayDiff(now, tsToDate(e.startDate)) <= daysAhead);
      }
      events.sort((a, b) => tsToDate(a.startDate) - tsToDate(b.startDate));
      const limit = Math.min(Math.max(parseInt(args.limit, 10) || 20, 1), 100);
      const total = events.length;
      const rows = events.slice(0, limit).map((e) => {
        const start = tsToDate(e.startDate);
        const end = tsToDate(e.endDate);
        return {
          title: e.title,
          when: whenString(start, e.isAllDay),
          startDate: start ? start.toISOString() : null,
          endDate: end ? end.toISOString() : null,
          isAllDay: !!e.isAllDay,
          location: e.location || null,
          recurrence: e.recurrence || "none",
          assignees: nameList(e.assigneeIDs, nameMap),
        };
      });
      return { totalUpcoming: total, returned: rows.length, events: rows };
    },
  },

  {
    name: "get_money_summary",
    description:
      "This-month (or a given month's) spending summary: total, by-category breakdown vs budgets, " +
      "top vendors, and recurring vendors (2+ charges this month). Mirrors the in-app Money view.",
    inputSchema: {
      type: "object",
      properties: {
        month: { type: "string", description: "Month as YYYY-MM (default: current month in ET)." },
      },
      additionalProperties: false,
    },
    async run(db, hid, args) {
      const now = new Date();
      const month = /^\d{4}-\d{2}$/.test(args.month || "") ? args.month : etDateString(now).slice(0, 7);
      const snap = await hh(db, hid).collection("expenses").get();
      const inMonth = snap.docs.map((d) => d.data()).filter((e) => {
        const dt = tsToDate(e.date);
        return dt && etDateString(dt).slice(0, 7) === month;
      });
      let total = 0;
      const byCategory = {};
      const vendorAgg = {};
      for (const e of inMonth) {
        const amt = typeof e.amount === "number" ? e.amount : 0;
        total += amt;
        const cat = e.category || "other";
        byCategory[cat] = (byCategory[cat] || 0) + amt;
        const v = (e.vendor || "Unknown").trim();
        vendorAgg[v] = vendorAgg[v] || { vendor: v, count: 0, total: 0 };
        vendorAgg[v].count += 1;
        vendorAgg[v].total += amt;
      }
      // Budgets (config/budgets: { limits: { category: dollars } }).
      let limits = {};
      try {
        const b = await hh(db, hid).collection("config").doc("budgets").get();
        if (b.exists && b.data() && b.data().limits) limits = b.data().limits;
      } catch (_) { /* no budgets */ }
      const round2 = (n) => Math.round(n * 100) / 100;
      const categories = Object.keys(byCategory).sort((a, b) => byCategory[b] - byCategory[a]).map((c) => ({
        category: c,
        spent: round2(byCategory[c]),
        budget: typeof limits[c] === "number" && limits[c] > 0 ? limits[c] : null,
        remaining: typeof limits[c] === "number" && limits[c] > 0 ? round2(limits[c] - byCategory[c]) : null,
      }));
      const vendors = Object.values(vendorAgg).map((v) => ({ ...v, total: round2(v.total) }));
      const recurringVendors = vendors.filter((v) => v.count >= 2).sort((a, b) => b.count - a.count);
      const topVendors = vendors.slice().sort((a, b) => b.total - a.total).slice(0, 8);
      return {
        month,
        currency: "USD",
        total: round2(total),
        transactionCount: inMonth.length,
        byCategory: categories,
        topVendors,
        recurringVendors,
      };
    },
  },

  {
    name: "get_care_due",
    description:
      "Everything due or overdue right now across house, plant, and pet care — plus expiring/expired " +
      "Family-Brain records (vaccines, warranties). Overdue items first.",
    inputSchema: {
      type: "object",
      properties: {
        withinDays: { type: "integer", description: "Horizon in days (default 14). Overdue is always included.", minimum: 0, maximum: 365 },
      },
      additionalProperties: false,
    },
    async run(db, hid, args) {
      const now = new Date();
      const nameMap = await loadMemberNames(db, hid);
      const horizon = Number.isFinite(parseInt(args.withinDays, 10)) ? parseInt(args.withinDays, 10) : 14;
      const items = await loadCareItems(db, hid); // all kinds
      const due = [];
      for (const item of items) {
        for (const task of item.tasks || []) {
          const s = careTaskStatus(task, now);
          if (s.manual) continue;
          if (s.daysUntilDue > horizon) continue;
          due.push({
            item: item.name,
            kind: item.kind || "house",
            location: item.location || null,
            task: task.title,
            dueDate: s.dueDate,
            daysUntilDue: s.daysUntilDue,
            overdue: s.overdue,
            lastDoneBy: nameMap[task.lastDoneBy] || null,
          });
        }
      }
      due.sort((a, b) => a.daysUntilDue - b.daysUntilDue);
      // Expiring/expired Family-Brain records.
      const docs = await loadDocuments(db, hid);
      const petMap = {};
      (await loadCareItems(db, hid, "pet")).forEach((p) => { petMap[p.id] = p.name; });
      const records = docs.map((d) => {
        const exp = tsToDate(d.expiryDate);
        if (!exp) return null;
        const days = dayDiff(now, exp);
        if (days > horizon) return null;
        return {
          title: d.title, type: d.type || "other", vendor: d.vendor || null,
          expiryDate: etDateString(exp), daysUntilExpiry: days, expired: days < 0,
          linkedPets: nameList(d.linkedPetIds, petMap),
          linkedMembers: nameList(d.linkedMemberIds, nameMap),
        };
      }).filter(Boolean).sort((a, b) => a.daysUntilExpiry - b.daysUntilExpiry);
      return {
        horizonDays: horizon,
        overdueCount: due.filter((d) => d.overdue).length,
        dueCount: due.length,
        careDue: due,
        expiringRecordsCount: records.length,
        expiringRecords: records,
      };
    },
  },

  {
    name: "get_memories",
    description:
      "Recent entries from the family memory journal (scrapbook): title, date, which kid(s), " +
      "milestone tag, and a short excerpt of the story.",
    inputSchema: {
      type: "object",
      properties: {
        limit: { type: "integer", description: "Max memories (default 10).", minimum: 1, maximum: 50 },
      },
      additionalProperties: false,
    },
    async run(db, hid, args) {
      const nameMap = await loadMemberNames(db, hid);
      const snap = await hh(db, hid).collection("memories").get();
      const limit = Math.min(Math.max(parseInt(args.limit, 10) || 10, 1), 50);
      const rows = snap.docs.map((d) => d.data())
        .sort((a, b) => (tsToDate(b.date) || 0) - (tsToDate(a.date) || 0))
        .slice(0, limit)
        .map((m) => {
          const story = (m.richText || "").replace(/[*_#>`]/g, "").trim();
          return {
            title: m.title || null,
            date: tsToDate(m.date) ? etDateString(tsToDate(m.date)) : null,
            kids: nameList(m.kidMemberIds, nameMap),
            milestone: m.milestone || null,
            excerpt: story.length > 240 ? story.slice(0, 240) + "…" : story,
            photoCount: (m.photoPaths || []).length,
          };
        });
      return { totalReturned: rows.length, memories: rows };
    },
  },

  {
    name: "get_lists",
    description:
      "The family's shared lists (grocery, packing, gift, project, wishlist, standard) with their " +
      "items and check-off status.",
    inputSchema: {
      type: "object",
      properties: {
        includeCompleted: { type: "boolean", description: "Include already-checked items (default true)." },
        maxItemsPerList: { type: "integer", description: "Cap items returned per list (default 50).", minimum: 1, maximum: 200 },
      },
      additionalProperties: false,
    },
    async run(db, hid, args) {
      const nameMap = await loadMemberNames(db, hid);
      const includeCompleted = args.includeCompleted !== false;
      const cap = Math.min(Math.max(parseInt(args.maxItemsPerList, 10) || 50, 1), 200);
      const listsSnap = await hh(db, hid).collection("lists").get();
      const lists = [];
      for (const listDoc of listsSnap.docs) {
        const l = listDoc.data();
        const itemsSnap = await listDoc.ref.collection("items").get();
        const allItems = itemsSnap.docs.map((d) => d.data());
        const completed = allItems.filter((i) => i.isCompleted).length;
        let items = includeCompleted ? allItems : allItems.filter((i) => !i.isCompleted);
        items = items.sort((a, b) => (a.sortOrder || 0) - (b.sortOrder || 0)).slice(0, cap).map((i) => ({
          title: i.title,
          done: !!i.isCompleted,
          assignee: i.assigneeID ? (nameMap[i.assigneeID] || i.assigneeID) : null,
          dueDate: tsToDate(i.dueDate) ? etDateString(tsToDate(i.dueDate)) : null,
          quantity: typeof i.quantity === "number" ? i.quantity : null,
          unit: i.unit || null,
          note: i.note || null,
        }));
        lists.push({
          title: l.title,
          type: l.listType || "standard",
          itemCount: allItems.length,
          completedCount: completed,
          items,
        });
      }
      lists.sort((a, b) => a.title.localeCompare(b.title));
      return { totalLists: lists.length, lists };
    },
  },

  // ---------------------------------------------------------------------------
  // WRITE / ACTION tools (C2). Each MODIFIES family data. No smart-home / LAN /
  // lock / garage control lives here — that stays app-side (the LAN is on the phone).
  // ---------------------------------------------------------------------------

  {
    name: "mark_care_done",
    description:
      "⚠️ MODIFIES DATA. Mark a care task done for a plant, pet, or house-care item — stamps the " +
      "task's last-done date/actor (exactly like tapping 'Done' in the app) and logs a family " +
      "activity entry (e.g. \"watered \\\"Monstera\\\"\"). Pass the careItemId (from get_plants/get_pets/" +
      "get_care_due); omit taskId to complete the soonest-due task. Acts as the household owner unless " +
      "a memberId is given.",
    inputSchema: {
      type: "object",
      properties: {
        careItemId: { type: "string", description: "The care item's id (plant/pet/house item)." },
        taskId: { type: "string", description: "Which task to mark done. Default: the soonest-due task." },
        memberId: { type: "string", description: "Attribute to this family member (uid). Default: household owner." },
      },
      required: ["careItemId"],
      additionalProperties: false,
    },
    async run(db, hid, args) {
      const now = new Date();
      const nameMap = await loadMemberNames(db, hid);
      const ref = hh(db, hid).collection("careItems").doc(String(args.careItemId));
      const snap = await ref.get();
      if (!snap.exists) throw new Error(`No care item ${args.careItemId}`);
      const item = snap.data();
      const tasks = Array.isArray(item.tasks) ? item.tasks : [];
      if (tasks.length === 0) throw new Error(`Care item "${item.name}" has no tasks`);
      let idx;
      if (args.taskId) {
        idx = tasks.findIndex((t) => t.id === args.taskId);
        if (idx < 0) throw new Error(`No task ${args.taskId} on "${item.name}"`);
      } else {
        // Soonest-due (mirrors CareItem.soonestDueTask: manual tasks sort to the back).
        idx = 0; let best = Infinity;
        tasks.forEach((t, i) => {
          const s = careTaskStatus(t, now);
          const key = s.manual ? Infinity : s.daysUntilDue;
          if (key < best) { best = key; idx = i; }
        });
      }
      const actor = await resolveActor(db, hid, args.memberId, nameMap);
      const newTasks = tasks.map((t, i) =>
        i === idx ? { ...t, lastDoneAt: now, lastDoneBy: actor.uid } : t);
      await ref.set({ tasks: newTasks }, { merge: true });
      const verb = careVerb(tasks[idx].title);
      const who = actor.name ? `${actor.name} ` : "";
      const text = `${who}${verb} "${item.name}"`;
      const activityId = await writeActivity(db, hid, {
        text, systemImage: item.iconSymbol || "leaf.fill", actorID: actor.uid,
      });
      return {
        ok: true, careItemId: item.id, item: item.name,
        task: tasks[idx].title, markedDoneBy: actor.name || actor.uid,
        lastDoneAt: now.toISOString(), activityLogged: !!activityId, activityText: text,
      };
    },
  },

  {
    name: "complete_chore",
    description:
      "⚠️ MODIFIES DATA. Complete a family chore — writes the completion toggle so the server awards " +
      "XP (the client never computes XP). Recurring chores spawn their next occurrence, just like the " +
      "app. Credit goes to the chore's assignee, or the passed memberId, or the household owner. " +
      "No-ops if the chore is already complete.",
    inputSchema: {
      type: "object",
      properties: {
        choreId: { type: "string", description: "The chore's id (from get_care_due is NOT it — chores aren't there; use the app/AgentTools chore list)." },
        memberId: { type: "string", description: "Who gets credit (uid). Default: the chore's assignee, else the household owner." },
      },
      required: ["choreId"],
      additionalProperties: false,
    },
    async run(db, hid, args) {
      const nameMap = await loadMemberNames(db, hid);
      const ref = hh(db, hid).collection("chores").doc(String(args.choreId));
      const snap = await ref.get();
      if (!snap.exists) throw new Error(`No chore ${args.choreId}`);
      const chore = snap.data();
      if (chore.isCompleted) {
        return { ok: true, alreadyComplete: true, choreId: chore.id, title: chore.title };
      }
      // creditID: explicit memberId → chore assignee → household owner (mirrors ChoreCompletion.complete).
      const owner = await resolveActor(db, hid, null, nameMap);
      let creditID = (args.memberId && nameMap[args.memberId]) ? args.memberId
        : (chore.assigneeID || owner.uid);
      const now = new Date();
      // Set completion fields ONLY — never xpAwarded (onChoreToggled awards it transactionally).
      await ref.set({ isCompleted: true, completedAt: now, completedByMemberID: creditID }, { merge: true });
      // Spawn next occurrence for recurring chores (client parity), tagged via:"mcp".
      const next = nextChoreOccurrence(chore);
      if (next) await hh(db, hid).collection("chores").doc(next.id).set(next);
      const who = nameMap[creditID] ? `${nameMap[creditID]} ` : "";
      const text = `${who}completed "${chore.title}"`;
      const activityId = await writeActivity(db, hid, {
        text, systemImage: "checkmark.seal.fill", actorID: creditID,
      });
      return {
        ok: true, choreId: chore.id, title: chore.title,
        creditedTo: nameMap[creditID] || creditID,
        spawnedNextOccurrence: next ? next.id : null,
        note: "XP is awarded server-side by onChoreToggled.",
        activityLogged: !!activityId,
      };
    },
  },

  {
    name: "add_event",
    description:
      "⚠️ MODIFIES DATA. Add a family calendar event. `date` is YYYY-MM-DD (all-day) or a full ISO " +
      "timestamp (timed). Optional `notes` go on the family notes. The event is app-origin (source " +
      "\"manual\"), so it syncs into the family's Apple Calendar and the calendar-import circuit breaker " +
      "never touches it.",
    inputSchema: {
      type: "object",
      properties: {
        title: { type: "string", description: "Event title." },
        date: { type: "string", description: "YYYY-MM-DD (all-day) or ISO 8601 timestamp (timed)." },
        notes: { type: "string", description: "Optional family notes for the event." },
        memberId: { type: "string", description: "Assign to a family member (uid). Optional." },
      },
      required: ["title", "date"],
      additionalProperties: false,
    },
    async run(db, hid, args) {
      const title = String(args.title || "").trim();
      if (!title) throw new Error("title is required");
      const parsed = parseDateInput(args.date);
      if (!parsed) throw new Error(`Could not parse date "${args.date}" (use YYYY-MM-DD or ISO 8601)`);
      const nameMap = await loadMemberNames(db, hid);
      const assignees = (args.memberId && nameMap[args.memberId]) ? [args.memberId] : [];
      const id = newId();
      const now = new Date();
      const doc = {
        id, title,
        startDate: parsed.date,
        isAllDay: parsed.dateOnly,
        recurrence: "none",
        assigneeIDs: assignees,
        source: "manual", // app-origin — pushed to Apple Calendar, never a calendar_import
        createdAt: now, updatedAt: now,
        via: "mcp",
      };
      if (typeof args.notes === "string" && args.notes.trim()) doc.familyNotes = args.notes.trim();
      await hh(db, hid).collection("events").doc(id).set(doc);
      await writeActivity(db, hid, {
        text: `New event: "${title}"`, systemImage: "calendar.badge.plus", actorID: null,
      });
      return {
        ok: true, eventId: id, title,
        when: whenString(parsed.date, parsed.dateOnly), isAllDay: parsed.dateOnly,
        startDate: parsed.date.toISOString(),
      };
    },
  },

  {
    name: "add_to_list",
    description:
      "⚠️ MODIFIES DATA. Add an item to a shared family list (grocery, packing, etc.). Pass a listId, " +
      "or a listName resolved case-insensitively (must be unambiguous). `quantity`/`unit` are optional " +
      "(grocery). Does NOT create new lists.",
    inputSchema: {
      type: "object",
      properties: {
        listId: { type: "string", description: "The list's id (preferred)." },
        listName: { type: "string", description: "The list's title (used only if listId is omitted; must match exactly one list)." },
        item: { type: "string", description: "The item to add." },
        quantity: { type: "number", description: "Amount to buy (grocery). Optional." },
        unit: { type: "string", description: "Unit for quantity, e.g. 'lb', 'bunch'. Optional." },
      },
      required: ["item"],
      additionalProperties: false,
    },
    async run(db, hid, args) {
      const item = String(args.item || "").trim();
      if (!item) throw new Error("item is required");
      let listDoc;
      if (args.listId) {
        const s = await hh(db, hid).collection("lists").doc(String(args.listId)).get();
        if (!s.exists) throw new Error(`No list ${args.listId}`);
        listDoc = s;
      } else if (args.listName) {
        const want = String(args.listName).trim().toLowerCase();
        const all = await hh(db, hid).collection("lists").get();
        const hits = all.docs.filter((d) => (d.data().title || "").trim().toLowerCase() === want);
        if (hits.length === 0) throw new Error(`No list named "${args.listName}"`);
        if (hits.length > 1) throw new Error(`"${args.listName}" is ambiguous (${hits.length} lists) — pass listId`);
        listDoc = hits[0];
      } else {
        throw new Error("Pass a listId or listName");
      }
      const list = listDoc.data();
      const itemsRef = listDoc.ref.collection("items");
      const existing = await itemsRef.get();
      const maxSort = existing.docs.reduce((m, d) => Math.max(m, d.data().sortOrder || 0), 0);
      const id = newId();
      const rec = {
        id, title: item, isCompleted: false,
        listID: listDoc.id, sortOrder: maxSort + 1,
        createdAt: new Date(), via: "mcp",
      };
      if (typeof args.quantity === "number") rec.quantity = args.quantity;
      if (typeof args.unit === "string" && args.unit.trim()) rec.unit = args.unit.trim();
      await itemsRef.doc(id).set(rec);
      return {
        ok: true, listId: listDoc.id, listTitle: list.title, itemId: id, item,
        quantity: rec.quantity ?? null, unit: rec.unit ?? null,
      };
    },
  },

  {
    name: "check_off_list_item",
    description:
      "⚠️ MODIFIES DATA. Check a list item off (mark it completed). Notifies the household via the " +
      "existing list-checked trigger and logs an activity entry.",
    inputSchema: {
      type: "object",
      properties: {
        listId: { type: "string", description: "The list's id." },
        itemId: { type: "string", description: "The item's id within the list." },
      },
      required: ["listId", "itemId"],
      additionalProperties: false,
    },
    async run(db, hid, args) {
      const listRef = hh(db, hid).collection("lists").doc(String(args.listId));
      const itemRef = listRef.collection("items").doc(String(args.itemId));
      const [listSnap, itemSnap] = await Promise.all([listRef.get(), itemRef.get()]);
      if (!itemSnap.exists) throw new Error(`No item ${args.itemId} in list ${args.listId}`);
      const it = itemSnap.data();
      if (it.isCompleted) {
        return { ok: true, alreadyChecked: true, itemId: it.id, item: it.title };
      }
      await itemRef.set({ isCompleted: true }, { merge: true });
      const listTitle = (listSnap.exists && listSnap.data().title) || "a list";
      await writeActivity(db, hid, {
        text: `Checked "${it.title}" off ${listTitle}`, systemImage: "checklist.checked",
        actorID: it.assigneeID || null,
      });
      return { ok: true, listId: args.listId, itemId: it.id, item: it.title, list: listTitle };
    },
  },

  {
    name: "log_expense",
    description:
      "⚠️ MODIFIES DATA. Record a spend in the family money ledger. `amount` (USD) and `vendor` are " +
      "the core fields; `category` is one of groceries/dining/kids/house/garden/pets/fun/other " +
      "(defaults to other); `date` is YYYY-MM-DD or ISO (defaults to now). Logged as a manual entry " +
      "via the assistant.",
    inputSchema: {
      type: "object",
      properties: {
        amount: { type: "number", description: "Amount in USD." },
        vendor: { type: "string", description: "Who was paid." },
        category: {
          type: "string", description: "Spending category.",
          enum: ["groceries", "dining", "kids", "house", "garden", "pets", "fun", "other"],
        },
        date: { type: "string", description: "YYYY-MM-DD or ISO 8601. Default: now." },
      },
      required: ["amount", "vendor"],
      additionalProperties: false,
    },
    async run(db, hid, args) {
      const amount = Number(args.amount);
      if (!Number.isFinite(amount)) throw new Error("amount must be a number");
      const CATS = ["groceries", "dining", "kids", "house", "garden", "pets", "fun", "other"];
      const category = CATS.includes(args.category) ? args.category : "other";
      const parsed = args.date ? parseDateInput(args.date) : { date: new Date() };
      if (!parsed) throw new Error(`Could not parse date "${args.date}"`);
      const id = newId();
      const now = new Date();
      await hh(db, hid).collection("expenses").doc(id).set({
        id, amount, vendor: String(args.vendor || "").trim() || null,
        category, date: parsed.date, source: "manual",
        notes: "Logged via ¡Bacán! assistant (MCP)",
        createdAt: now, via: "mcp",
      });
      return {
        ok: true, expenseId: id, amount, currency: "USD",
        vendor: String(args.vendor || "").trim() || null, category,
        date: etDateString(parsed.date),
      };
    },
  },

  {
    name: "create_memory",
    description:
      "⚠️ MODIFIES DATA. Add a page to the family memory scrapbook. `story` is the body (Markdown ok). " +
      "`date` is YYYY-MM-DD or ISO (defaults to today); `kidMemberIds` are the family member uids the " +
      "memory is about. Photos are optional and not added here. Authored as the household owner unless " +
      "a memberId is given.",
    inputSchema: {
      type: "object",
      properties: {
        title: { type: "string", description: "Short headline for the memory." },
        story: { type: "string", description: "The story text (portable Markdown)." },
        date: { type: "string", description: "YYYY-MM-DD or ISO 8601. Default: today." },
        kidMemberIds: { type: "array", items: { type: "string" }, description: "Family member uids the memory is about." },
        memberId: { type: "string", description: "Who is capturing it (uid). Default: household owner." },
      },
      required: ["title", "story"],
      additionalProperties: false,
    },
    async run(db, hid, args) {
      const title = String(args.title || "").trim();
      const story = String(args.story || "").trim();
      if (!title && !story) throw new Error("A memory needs a title or a story");
      const nameMap = await loadMemberNames(db, hid);
      const actor = await resolveActor(db, hid, args.memberId, nameMap);
      const parsed = args.date ? parseDateInput(args.date) : { date: new Date() };
      if (!parsed) throw new Error(`Could not parse date "${args.date}"`);
      const kidIds = Array.isArray(args.kidMemberIds)
        ? args.kidMemberIds.filter((k) => typeof k === "string") : [];
      const id = newId();
      const now = new Date();
      await hh(db, hid).collection("memories").doc(id).set({
        id, title: title || null, richText: story,
        photoPaths: [], stickerPaths: [], kidMemberIds: kidIds,
        date: parsed.date, createdBy: actor.uid,
        createdAt: now, updatedAt: now, via: "mcp",
      });
      return {
        ok: true, memoryId: id, title: title || null,
        date: etDateString(parsed.date),
        kids: nameList(kidIds, nameMap), createdBy: actor.name || actor.uid,
      };
    },
  },
];

const TOOL_MAP = Object.fromEntries(TOOLS.map((t) => [t.name, t]));

// -----------------------------------------------------------------------------
// JSON-RPC / MCP dispatch
// -----------------------------------------------------------------------------

function rpcResult(id, result) { return { jsonrpc: "2.0", id, result }; }
function rpcError(id, code, message) { return { jsonrpc: "2.0", id, error: { code, message } }; }

/** Handle a single JSON-RPC message. Returns a response object, or null for notifications. */
async function handleMessage(msg, ctx) {
  if (!msg || msg.jsonrpc !== "2.0" || typeof msg.method !== "string") {
    return rpcError(msg && msg.id != null ? msg.id : null, -32600, "Invalid Request");
  }
  const { id, method, params } = msg;
  const isNotification = id === undefined || id === null;

  switch (method) {
    case "initialize": {
      const protocolVersion =
        params && typeof params.protocolVersion === "string" ? params.protocolVersion : DEFAULT_PROTOCOL;
      return rpcResult(id, {
        protocolVersion,
        capabilities: { tools: { listChanged: false } },
        serverInfo: { name: SERVER_NAME, version: SERVER_VERSION },
        instructions:
          "Access to the ¡Bacán! family hub (household " + ctx.hid + "). READ tools answer questions " +
          "about the family's plants, pets, calendar, documents (Family Brain), money, care schedule, " +
          "memories, and lists. WRITE tools (marked ⚠️ MODIFIES DATA — mark_care_done, complete_chore, " +
          "add_event, add_to_list, check_off_list_item, log_expense, create_memory) change data; they " +
          "act as the household owner unless a memberId is given. Smart-home / lock / garage control is " +
          "NOT available here — that stays in the app (the LAN lives on the phone).",
      });
    }
    case "ping":
      return rpcResult(id, {});
    case "notifications/initialized":
    case "notifications/cancelled":
      return null; // notifications get no response
    case "tools/list":
      return rpcResult(id, {
        tools: TOOLS.map((t) => ({ name: t.name, description: t.description, inputSchema: t.inputSchema })),
      });
    case "tools/call": {
      const name = params && params.name;
      const tool = TOOL_MAP[name];
      if (!tool) return rpcError(id, -32602, `Unknown tool: ${name}`);
      const args = (params && params.arguments) || {};
      try {
        const data = await tool.run(ctx.db, ctx.hid, args);
        return rpcResult(id, {
          content: [{ type: "text", text: JSON.stringify(data, null, 2) }],
          structuredContent: data,
          isError: false,
        });
      } catch (err) {
        return rpcResult(id, {
          content: [{ type: "text", text: `Tool "${name}" failed: ${err.message}` }],
          isError: true,
        });
      }
    }
    default:
      if (isNotification) return null;
      return rpcError(id, -32601, `Method not found: ${method}`);
  }
}

/**
 * The onRequest handler body (exported so index.js can wrap it in `onRequest`). Streamable-HTTP,
 * stateless, bearer-auth'd. POST a JSON-RPC request (or batch); GET/other → not supported.
 */
async function serve(req, res) {
  // CORS (harmless for server-side clients; enables browser-based MCP inspectors).
  res.set("Access-Control-Allow-Origin", "*");
  res.set("Access-Control-Allow-Headers", "Authorization, Content-Type, MCP-Protocol-Version, Mcp-Session-Id");
  res.set("Access-Control-Allow-Methods", "POST, GET, OPTIONS");
  if (req.method === "OPTIONS") { res.status(204).send(""); return; }
  if (req.method === "GET") {
    // We don't offer a server→client SSE stream (stateless server). Spec allows 405 here.
    res.status(405).json(rpcError(null, -32000, "GET not supported; POST JSON-RPC to this endpoint."));
    return;
  }
  if (req.method !== "POST") { res.status(405).send("Method Not Allowed"); return; }

  const db = admin.firestore();
  const hid = await authenticate(db, bearerFrom(req.get("authorization")));
  if (!hid) {
    res.set("WWW-Authenticate", 'Bearer realm="bacan-mcp"');
    res.status(401).json(rpcError(null, -32001, "Unauthorized: missing or invalid bearer token."));
    return;
  }

  let body = req.body;
  if (typeof body === "string") {
    try { body = JSON.parse(body); } catch (_) {
      res.status(400).json(rpcError(null, -32700, "Parse error"));
      return;
    }
  }
  const ctx = { db, hid };
  try {
    if (Array.isArray(body)) {
      const responses = [];
      for (const m of body) {
        const r = await handleMessage(m, ctx);
        if (r) responses.push(r);
      }
      if (responses.length === 0) { res.status(202).send(""); return; }
      res.status(200).json(responses);
    } else {
      const r = await handleMessage(body, ctx);
      if (!r) { res.status(202).send(""); return; }
      res.status(200).json(r);
    }
  } catch (err) {
    res.status(200).json(rpcError(body && body.id != null ? body.id : null, -32603, `Internal error: ${err.message}`));
  }
}

module.exports = { serve, mintToken, authenticate, TOOLS };
