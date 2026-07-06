"use strict";

/**
 * mcpServer — a true MCP (Model Context Protocol) server over the family's Firestore, hosted as a
 * Firebase v2 `onRequest` Cloud Function (P14-C4-C1). It lets Michael point an MCP client
 * (Claude Desktop / Claude Code / claude.ai) at the ¡Bacán! family hub and read the family brain
 * from anywhere. House CONTROL stays app-side (the LAN lives on the phone); this exposes read/query
 * tools only for C1. Write/action tools land in C2.
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
          "Read-only access to the ¡Bacán! family hub (household " + ctx.hid + "). Use these tools to " +
          "answer questions about the family's plants, pets, calendar, documents (Family Brain), money, " +
          "care schedule, memories, and lists.",
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
