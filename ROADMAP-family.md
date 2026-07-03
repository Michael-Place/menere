# Menere → Family Hub Roadmap

Menere is pivoting from a dedicated wine tracker into a **private family hub** — a
single app that serves our family's niche needs, leaning toward *never going
public*. Wine tracking becomes one module among several, not the whole app.

This plan ports the family-management feature set from the **Fambo** app
(`../fambo`) into Menere. The two apps share an almost identical stack
(SwiftUI + TCA + `swift-dependencies` + Firebase Auth/Firestore/Storage/Functions),
so this is a **merge, not a rewrite**.

## Decisions locked in

- **Keep the rich member model, drop the kid machinery.** Every family feature needs
  named/colored/roled members ("assign to Dad", "Mom completed this"). We port
  Fambo's `Member` concept in full but **skip** managed members, claim-by-code,
  child dashboard, and experience-levels. `role` stays an enum
  (`admin`/`member`/`child`) so kid logins are a later *additive* change, not a
  rework. Default role for everyone today: `admin`.
- **Strip all go-to-market weight.** No RevenueCat/subscriptions, no free-tier rate
  limits, no marketing screenshots, no onboarding polish, no App Check gating —
  this is a private app for one family.
- **Wine stays a first-class tab.** Scan/Cellar/Journal are preserved intact; they
  just stop being the whole app.
- **iOS 26+ is fine.** Fambo targets iOS 18; porting its code *up* into Menere's
  26+ target only unlocks newer APIs — no downgrades.
- **Keep the `households` Firestore collection name for now.** Renaming to
  `families` touches `firestore.rules`, `PersistenceClient`, and every
  bottle/tasting path. It's cosmetic; defer it. User-facing copy says "Family".
  The `members: [uid]` array on the household doc stays as the security-rule gate;
  rich member *profiles* live in a new `households/{hid}/members/{uid}` subcollection.

## Data model evolution

Today:
```
/households/{hid}         Household { ownerUid, members:[uid], inviteCode }
/households/{hid}/bottles/{id}
/households/{hid}/tastings/{id}
```

After P0 (additive — no breaking change to existing paths):
```
/households/{hid}                    Household  (unchanged; members:[uid] gates rules)
/households/{hid}/members/{uid}      HouseholdMember { name, color, avatar, role, joinedAt }
/households/{hid}/bottles/{id}       (unchanged)
/households/{hid}/tastings/{id}      (unchanged)
```

Each new feature domain adds its own subcollections under `/households/{hid}/…`
(e.g. `lists`, `listItems`, `events`, `chores`, `memberStats`, `recipes`,
`mealPlans`), all gated by the existing member-array rule.

## Status

**All phases integrated and building** (simulator build green). Firestore rules
needed no change — every new subcollection (`members`, `lists`, `events`, `chores`,
`memberStats`, `rewards`, `redemptions`, `recipes`, `mealPlan`) lives under
`households/{hid}/…` and is gated by the existing member-array rule. Remaining:
one manual end-to-end smoke test on device/sim while signed in.

New Swift targets added: `FamilyDomain` (shared models), `ListsFeature`,
`CalendarFeature`, `ChoresFeature`, `RecipesFeature`. Tab shell reframed to
Calendar · Lists · Chores · Family, with Kitchen (Recipes/Meal Plan) + wine
(Cellar/Scan) in the system **More** menu.

Deliberate simplifications vs Fambo (private-app scope): recurrence expanded
client-side (no `dailyRecurrenceExpansion` Cloud Function).

**Chore XP is server-authoritative** (`onChoreToggled` + `choreXP.js`): the client only
records completion + who gets credit; the trigger awards/reverses XP transactionally
(idempotent; clears the award marker on reversal so re-completion re-awards). The app
subscribes to a live `memberStats` snapshot listener, so the leaderboard updates in real
time across devices. This replaced the earlier client-side XP math (which risked stale
multi-device awards). Verified end-to-end on the live backend: complete → +XP, uncomplete →
−XP, re-complete → +XP, all via the server + listener.

### Follow-up round (in progress)
- **Wine collapsed to one tab** — `WineTabView`: Cellar is home, Scan is a full-screen
  modal (camera toolbar button + Cellar empty-state). Original Menere is now one tab.
- **Robust settings** — "My Profile" editor (name / palette color / SF-Symbol avatar)
  ported from Fambo, alongside the member roster, invite, and join.
- **Activity feed** — client-side `ActivityItem` written on chore completion, event
  creation, and list-item checks; shown as "Recent Activity" in the Chores tab.
- **Chore auto-regeneration** — completing a recurring chore spawns its next occurrence.
- **Recipe URL scraping** — `extractRecipe` Cloud Function (JSON-LD fast path + Claude
  fallback, reuses `ANTHROPIC_API_KEY`) **deployed to `menere`**; wired as "Import from
  URL" in the recipe form.

### FCM push notifications — implemented
- **Client:** `PushClient` module (`PushNotifications`) requests permission, registers for
  remote notifications, and saves the FCM token to `users/{uid}.fcmToken`. Wired in `AppDelegate`
  (`start(application:)` + APNs token forwarding). APNs entitlement + `remote-notification`
  background mode were already present (from phone auth).
- **Server:** notify-only triggers `onEventCreated`, `onChoreCompleted` (false→true, excludes the
  completer), `onListItemChecked`. They ONLY push — XP and the activity feed stay client-side.
  Recipients: `households/{hid}.members` → each `users/{uid}.fcmToken`.
- **Verify on a real device** — simulators can't reliably receive remote push.

### AI email→events — code ready; reuses the Postmark *account* (no DNS)
`receiveEmail` + `eventExtract.js` are written and syntax-checked. `receiveEmail` accepts BOTH
addressing styles, so we can reuse the existing Postmark account with zero DNS:
- **Custom domain:** `ABC123@inbox.<your-domain>` (local part = invite code), or
- **Postmark default:** `<serverhash>+ABC123@inbound.postmarkapp.com` (Postmark's `MailboxHash` =
  invite code) — no domain/MX needed.

Note: one Postmark inbound server routes to ONE webhook, and `inbox.fambo.app` is bound to
Fambo's server — so we add a **new inbound server** for Menere in the same account rather than
reusing Fambo's server/domain.

**Status: DEPLOYED and end-to-end VERIFIED** at
`https://us-central1-menere.cloudfunctions.net/receiveEmail`. `POSTMARK_WEBHOOK_SECRET` is set in
Secret Manager (value shared out-of-band; not stored in the repo). Verified by POSTing a simulated
Postmark inbound payload (`MailboxHash` = a real invite code) → 2 events extracted and written to
the correct household's calendar at the correct local times.

**Timezone:** event times are interpreted/emitted in `America/New_York` (hardcoded default in
`receiveEmail` → `eventExtract.js`), since households don't store a timezone. If members ever span
zones, add a per-household `timezone` field and pass it into `extractEventsFromText`.

Remaining (Postmark dashboard, your account):
1. Add a new **inbound server** for Menere; copy its default inbound address
   `<serverhash>@inbound.postmarkapp.com`.
2. Set that server's **inbound webhook URL** to
   `https://us-central1-menere.cloudfunctions.net/receiveEmail?secret=<POSTMARK_WEBHOOK_SECRET>`.
3. Families forward mail to `<serverhash>+<THEIR-INVITE-CODE>@inbound.postmarkapp.com`.
(Attachment/PDF/ICS parsing not included yet — text bodies only.)

---

# Act III — Refinement (Michael's usage feedback, 2026-07-03)

Emerged from Michael actually LIVING in the app. Four items:

### P16 — Home tab as the physical-home HUB (overview cards + drill-in)
Problem: the **Home** tab (renamed Chores tab) is getting very long — House care,
Plants, Yard & garden, Pets, Recent Activity, Leaderboard, Chores, Rewards — and
Michael keeps looking for the **smart home** in the Home tab but it's buried on the
Today/dashboard tab (the "The house" card + House control screen). Vision:
- **Home becomes a hub of OVERVIEW CARDS**, each a glanceable summary that taps into
  a rich full screen: Smart home (lights/shades/climate summary → House control
  screen), Chores & rewards (XP/leaderboard), House care, Plants (N thirsty), Yard &
  garden, Pets. Recent Activity stays inline or its own card.
- **Relocate/surface smart home in the Home tab** — its natural place. The House
  control screen (currently pushed from the Today card header) becomes reachable
  from the Home tab's Smart-home card. Today keeps a slim glance card at most.
- Each card: title + 1-line status + a chevron; tap → the existing detailed screen
  (House care section, plant roster, House control, etc.). This scales as more
  sections land.

### P17 — Today dashboard: time-aware AND actionable (a cockpit, not a bulletin board)
Michael's two dashboard critiques (2026-07-03): (a) it's not time-aware (shows the
whole day incl. past items), and (b) **"almost nothing on the dashboard is
actionable, it's read-only."** Both = make Today a LIVE, INTERACTIVE surface.

**Actionable pass — every card should let you DO, not just read:**
- **Calendar events** → tap a schedule row to open/edit it; inline quick actions
  (reschedule, mark done/attended, "add to Apple calendar" if not synced). Today's
  schedule is currently a dead list.
- **Family cards** → tap a member → their day / profile (currently inert).
- **Briefing highlights** → make the suggestions tappable (the assistant already
  offers these verbally — "want me to pull up the registration doc?"); e.g. a
  highlight mentioning a doc opens it, a dinner suggestion opens the meal plan.
- **Needs attention (docs)** → inline "Add to calendar" / open the doc, not just a
  bounce to the Brain.
- **Dinner** → tap to change/plan inline (partly there via Plan dinner).
- Keep the good inline actions that already exist (chore sticker-slap, care
  mark-done, house rituals) and extend that pattern everywhere.

**Time-aware pass — the dashboard reflects what's AHEAD, not the whole day:**
- **Past calendar events drop off** today's schedule once their endDate < now (or
  move to a de-emphasized "earlier today" collapse). The assistant already reasons
  this way ("café con Mariana at 11am — already passed"); the cards should too.
- **Tonight's dinner clears/changes after dinner** (a dinner cutoff hour, e.g. past
  ~8pm → "Dinner's done" or hide), so it stops showing a stale plan late at night.
- General principle: Today = a live, self-pruning view; time-of-day drives what's
  shown (morning shows the day ahead; evening shows what's left + Bedtime; late =
  quiet). Ties into the existing 18:00 Bedtime-prominence rule.

### P18 — Managed members + "claim your profile" (answers the Valentina-join question)
Act II deferred managed members; P0.1 created profile-only members (Vale/Famfis/
Oliver, no login) so documents link — which now REQUIRES a claim flow:
- **The problem:** when Valentina joins via invite code, `joinHousehold` creates a
  NEW member keyed to her uid — a DUPLICATE of the profile-only "Vale" (which holds
  her linked docs + terracotta color). 
- **Claim flow:** on join, if the household has profile-only members (member docs
  with no uid in the household `members` array), present "Which one are you?" → she
  picks Vale → re-key that persona to her uid: copy fullName/color, migrate every
  `document.linkedMemberIds` (and future links) from the synthetic id → her uid,
  delete the placeholder. Server-side (`joinHousehold` extension) or a client step.
- **Interim (works today):** orchestrator runs an Admin-SDK merge when she joins.
- Oliver/Famfis stay profile-only indefinitely (no logins) — the managed-member
  end state; only Valentina claims. Also unlocks the dormant `.child` role / an
  eventual kid experience.

## 2026-07-03 — TestFlight feedback round (build 11 → 12), all ✅ shipped
Michael's playtest feedback, turned around same-day (commits 9ced9db…39b9571):
- **W1 + W1.1 wine polish:** 9 style/bug fixes (serif inline nav titles restored via
  `wineNavTitle`, wine-tinted Scan chrome, gold glyphs, serif numerals, warm chips,
  scan-success haptic) + `WineSegmentedControl` (custom Bordeaux-pill segmented
  control — appearance-proxy scoping deliberately avoided). Flagged: Margaux
  `type=.other` data gap; Journal form row surfaces in dark mode.
- **P15-C8a reset affordances:** every integration removable in-app w/ confirmation;
  mock configs labeled "(demo data)" + "Clear demo data"; missing delete CRUD added
  (hue/lutron/homekit). **INCIDENT:** Michael's real Hue config was found clobbered
  by an agent mock fixture (attribution unclear, evening of 07-02); restored
  byte-perfect from scratchpad backups. Lesson: orchestrator now verifies config
  restoration post-run instead of trusting agent reports.
- **P15-C8b:** Smart-home Settings split — "Philips Hue" card (bridges + RITUALS
  subsection + actions) / "More devices" card (Michael's screenshot feedback).
- **P9.1 plant Save bug + Planta wizard:** root cause — identify-without-typed-name
  left `name` blank and save silently no-op'd; fixed w/ species fallback +
  regression test. New 6-step capture wizard (photo → AI reveal → nickname →
  location+lightLevel (new decode-safe field) → watering anchor → "Welcome home,
  {name}" LeafUnfurl). Edit form unchanged.
- **P2.1 two-way Apple Calendar sync** (Fambo port, 3 flaws fixed): per-occurrence
  import dedup (`ekID#occurrenceISO`), edit propagation, RecurrenceOption→
  EKRecurrenceRule single-event pushes into a dedicated "Bacán" calendar (id stored
  in prefs at `users/{uid}/settings/calendarSync`); email-extracted events push
  automatically (decode-default source=manual); imported-event deletion in-app does
  NOT delete the Apple original (mirror safety). Sim quirks: calaccessd XPC blocks
  SwiftPM EventKit tests; recurring-import E2E is unit-tested only.
- Also: Hubspace mock cleared via Admin SDK (unblocked login); `idb` works again.

# Act II — Make it *ours* (the personal era)

Act I built a working family hub. Act II makes it unmistakably the **Place family's**
app: Michael, Valentina, Oliver (3), Francis — known as **"Famfis"** (Oliver's
pronunciation; use it in copy) — plus dogs **Fajita & Sprinkle**.

Planned 2026-07-01 with Michael. Direction locked in conversation:

- **Identity: something new entirely.** Do NOT extend "Cellar & Candlelight"
  (parchment/wine/serif) to family surfaces — it was designed for wine and stays in
  the Cellar stack. New identity is designed from the family's character: music/vinyl,
  plants & landscaping, cooking, two small boys.
- **Motion: playful throughout.** Springy transitions, character everywhere, haptics
  on everything. Oliver watches chore check-offs — celebrations are for him too.
- **Voice: warm + witty, first names.** "Valentina checked off milk", "Famfis
  approves this dinner", "The monstera is thirsty — it's been 3 days."
- **Priority modules** (Michael's picks): Plants & garden · Home & cleaning ops ·
  Kids' milestones & memory log · Smart home · **Family Brain** (AI document vault) ·
  **Pets** (Fajita & Sprinkle). Record collection explicitly parked (the Cellar
  pattern maps 1:1 onto Discogs whenever wanted).

## Resolved questions (answered by Michael, 2026-07-01)

1. **Smart home = hyper-specific per-product integrations**, not a generic
   abstraction layer — take full advantage of each product. **Philips Hue is the
   main ecosystem the whole house relies on** → P12 is designed Hue-first.
2. **The app is renamed "Bacán"** (Chilean slang ≈ "cool/awesome"); "Menere" was a
   wine holdover. User-facing rename at P5 (display name, wordmark, app icon).
   **Internal identifiers stay `menere`** (bundle ID, Firebase project, repo,
   Swift package) — zero-churn, same policy as the `households` collection name.
   The Chilean thread is an identity ingredient for P5 (voice accents, warmth).

## Architectural spine (decide once, reuse everywhere)

Three Act I assets carry most of Act II — new phases should *reuse*, not reinvent:

1. **The scan pipeline** (VisionKit capture → Claude/FM vision → structured card
   with provenance) generalizes from wine labels to **documents** (P7) and
   **plant ID** (P9).
2. **The recurrence engine** (client-side `occurrences(from:to:)`) generalizes from
   events/chores to **care schedules** (P8–P10).
3. **The Postmark email pipeline** (`receiveEmail` → Claude extraction) generalizes
   from calendar events to **document intake via forwarded attachments** (P7.3).

One NEW shared primitive, introduced at P8 and reused by P9/P10:

- **`CareItem` / `CareTask`** (in `FamilyDomain`): a *thing that needs recurring
  care* — a plant, a pet, an HVAC filter, a room. `CareItem { id, kind (plant/pet/
  house/zone), name, photo, location, schedule: [CareTask] }`;
  `CareTask { title, interval, lastDoneAt, lastDoneBy, dueAt }`. Distinct from kid
  chores (no XP by default; an XP bridge is a possible later add-on). "What's due"
  queries power the Today dashboard. Firestore: `households/{hid}/careItems/{id}`.

And one connective-tissue rule: **Family Brain documents link to entities.** A
`Document` can reference member(s), pet(s), or care items. A vaccination record
*is* a document linked to Sprinkle with an `expiryDate` → the reminder falls out
for free. Doctor paperwork links to Famfis → appears on his timeline (P11).

## IA evolution

- **P6:** add **Today** as the first tab → Today · Calendar · Lists · Chores · Kitchen.
- **P8:** Chores tab becomes **Home** — sections: Chores & XP (unchanged), House ops,
  and later Plants (P9) and Pets (P10). Recent Activity stays here.
- **Family Brain** is not a tab: a **search icon in the top-right toolbar on every
  tab** (search *is* the product) + a "Documents" library row pinned in Lists,
  sibling to Cellar.
- Wine stays where it is (pinned Cellar row under Lists, parchment interior).

## Act II phases

### P5 — Identity: the reskin + voice pass  ✅ done (2026-07-01, commits a937c2d…87e19a8)
Shipped in six chunks, each build-green + sim-smoke-tested: (C1) FamilyTheme tokens +
chrome swap with the Cellar parchment seam (`.wineChrome()`); (C2) family-four
MemberColors — botanical/terracotta/marigold/sky, additive cases, first in the picker
(Michael already saved botanical); (C3) warm+witty voice pass on all family surfaces;
(C4) motion kit in MenereUI — `.stickerSlap`, `ConfettiBurst` (member-color level-up,
wired to the stats stream), `.pressable`, `.appearBounce`, Reduce-Motion aware;
(C5) Bacán rename — `CFBundleDisplayName` in Info.plist (INFOPLIST_KEY_* is a no-op
with an explicit plist), record-label "B" icon, rebranded Welcome/auth on the family
mesh; (C6) family-voice push copy in all four notify functions, deployed + live
smoke-tested via Admin SDK (XP-neutral, artifacts cleaned). Leftovers: confetti worth
one glance on a real device; `familyHero()` type helper if more hero wordmarks appear;
`support@menere.app` userAgent strings if ever user-visible.
The highest-leverage phase; transforms every existing screen before anything new
is added.
- **New theme layer** alongside the wine tokens (they stay for Cellar):
  `FamilyTheme` — warm daylight cream base (not antique parchment), core palette of
  **botanical green / terracotta / marigold**; code-defined dynamic light/dark
  `UIColor` tokens, same pattern as today. Concept: *record-sleeve boldness meets
  sunroom botanicals* — chunky rounded display type for headers (record-label
  energy), SF Rounded for UI, sticker/patch-styled icons and badges.
- **Four owned member colors.** Michael, Valentina, Oliver, Famfis each own a fixed
  color used everywhere (avatars, calendar dots, chore rows, leaderboard, confetti).
  Implementation: keep the `MemberColor` enum/palette (guests, future members);
  seed/lock the four members' choices; design the four to be maximally
  distinguishable and semantically "theirs" (pick with Michael & Valentina in P5).
- **Voice pass:** a copy sweep of every empty state, notification body (functions:
  `onEventCreated`/`onChoreToggled`/`onListItemChecked`/`receiveEmail`), alert, and
  celebration into warm+witty first-name voice. Centralize strings worth reusing.
- **Signature motion** (playful throughout): sticker-slap chore check-off, member-
  color confetti level-up, springy tab/nav transitions, generous haptics. Named
  springs pattern (`.menereSnappy`/`.menereBouncy`) already exists — extend it.
- **Rename to "Bacán":** new wordmark (mind the accent — test rendering in the
  chosen display face), new app icon, `CFBundleDisplayName` in `project.yml`
  (then `xcodegen generate`). Internals stay `menere`. The Chilean thread can
  flavor the voice pass — occasional Spanish warmth where it lands naturally
  ("¡Bacán!" as a celebration exclamation is free brand equity).
- Cellar interior keeps parchment; the seam is the push from the Lists row.

### P6 — Today dashboard (the family's front door)  ✅ done (2026-07-02, commits 509065d…7ee7b48)
Shipped in three chunks, each build-green + sim-smoke-tested: (C1) `TodayFeature`
target + Today as first/default tab — hero greeting (time-of-day + first name +
"at the Place house"), today's-schedule card (recurrence-aware), tonight's-dinner
card, quick-action deep links; (C2) chores-today card with inline sticker-slap
completion (shared `ChoreCompletion` helper in FamilyDomain — Chores tab behavior
unchanged, XP verified 12→24→12 round-trip live) + family member grid (color,
level, today counts); (C3) **AI daily briefing** — `generateDailyBriefing` callable
(claude-haiku-4-5, family-voice prompt, per-day cache at
`households/{hid}/briefings/{YYYY-MM-DD}`, force-refresh) DEPLOYED + verified,
shimmer-skeleton card that hides silently on failure; bonus: "Plan dinner" lands on
Kitchen's Meal Plan segment (public `showMealPlan`). Display name is now **¡Bacán!**.
Leftover ideas: live listeners for dashboard data (currently one-shot + re-select
refresh); weather on the greeting (WeatherKit, pairs with P9 yard care).
**P6.1 + P6.2 (2026-07-02, commits 54b1e6f + 557385c, Michael's requests):** meal-plan
entries support **eating out** — MKLocalSearchCompleter place sheet (name/address/
coords, decode-safe on MealPlanEntry), optional reservationAt, grocery generation
skips restaurant nights; Today's dinner card shows "Out tonight — {name} · 7:30",
address, traffic-aware MKDirections drive line ("≈25 min drive — leave by 6:58",
5-min buffer, terracotta "time to go" when past), and idempotent "Add to calendar"
(FamilyEvent at the reservation with the address). New `LocationClient` module
(when-in-use, graceful denial). Known deprecation: MKPlacemark path (iOS 26) —
functional, migrate someday.
New first tab. Time-of-day greeting ("Tuesday morning at the Place house"), then
stacked cards, each tappable through to its module:
- **Today's events** (calendar, member color dots) · **Dinner tonight** (meal plan)
  · **Chores due today** grouped by member · **Care due** (plants/pets/house —
  appears as P8–P10 land) · **This week glance**.
- Quick-add row: event / list item / memory (P11) / scan a document (P7).
- Empty day: "Nothing scheduled — a rare quiet day."
- Pure aggregation over existing observers/fetches; no new backend.

### P7 — Family Brain v1 (documents)  ✅ done (2026-07-02, commits b661e19…1b2eee7)
Shipped in three chunks, each build-green + sim-smoke-tested: (C1) `Document` model +
`DocsFeature` vault — VisionKit scan (device; compile-time sim degradation) /
PhotosPicker / PDF intake, Storage pages under `households/{hid}/documents/{docId}/`,
"Family Brain" row pinned under Cellar in Lists; storage.rules deployed — NOTE:
next-gen bucket can't do cross-service (Firestore) rule reads, so file BYTES are
auth-gated while doc metadata stays member-gated (revisit-if-public comment in rules).
(C2) `processDocument` callable (claude-sonnet-5 vision, never-invent prompt, member-name
matching, title overwritten only if it starts with "Scanned ") DEPLOYED — live extraction
verified field-by-field; failed states retryable, never stuck pending. (C3) search
everywhere (toolbar magnifyingglass on all five tabs → ranked local full-text with
match-context snippets + type chips), document detail (async page rendering via new
`StorageClient.downloadData`, title/type editing, full-text disclosure), idempotent
dueDate→"Add to calendar", expiry countdown chips, "Needs attention" card on Today.
P10 hooks ready: `DocumentType.pet`, `linkedPetIds`, `needsAttention`/`DocumentDateChip`.
The upload→auto-process handoff was verified on a REAL device 2026-07-02 (Michael's
KinderCare scan: processed in 18s, type school, dueDate surfacing on Today).
**P7.4 (same day, commit b05561e):** the library + detail are now LIVE-listener
powered (`observeDocuments`, mirrors observeMemberStats; edit-stomp guard on detail;
delete-elsewhere dismisses gracefully) — direct response to Michael's on-device
feedback. Search + Today stay one-shot by design. Not yet built: email-forward +
share-extension intake (P7.3 spec) — natural follow-on chunk.
Upload anything — receipt, doctor paperwork, school form, appliance manual — AI
breaks it down, tags it, makes it searchable. **The family's second brain.**
- **Model** (`FamilyDomain`): `Document { id, title, type (receipt/medical/school/
  pet/tax/manual/other), tags[], linkedMemberIds[], linkedPetIds[], docDate,
  dueDate?, expiryDate?, amount?, vendor?, summary, extractedText, storagePath,
  thumbnailPath, uploadedBy, createdAt }`. Firestore `households/{hid}/documents`;
  files in Storage under `households/{hid}/documents/` (member-gated rules — extend
  `storage.rules` the same way Firestore rules gate by the members array).
- **Intake, in build order:** (1) **VisionKit document scanner** in-app (the
  kitchen-counter flow — same muscle as the wine label scan) + PhotosPicker/Files
  picker; (2) **share extension** (PDF/image/screenshot from Mail, Safari, Messages);
  (3) **email attachments** — extend `receiveEmail` to ingest Postmark attachments.
- **Processing:** `processDocument` Cloud Function (callable, reuses
  `ANTHROPIC_API_KEY`): Claude vision over page images / PDF → the structured
  fields above + a one-line summary + suggested tags. Provenance-badge the AI
  fields, same as wine enrichment.
- **Search:** at family scale, no vector DB — load the doc index (title, tags,
  summary, extractedText) into the client and full-text search locally; filter by
  type/tag/person/pet/date. Search lives in the toolbar on every tab.
- **Actions from documents:** detected `dueDate`/appointment → suggest a calendar
  event (one tap to accept); `expiryDate` → scheduled reminder push (small
  scheduled function or client-side check on the Today view — start client-side).

### P8 — Home care hub (Chores tab → "Home")  ✅ done (2026-07-02, commits 7a9173d…7b6603a)
Shipped in two chunks: (C1) `CareItem`/`CareTask` primitive in FamilyDomain (kinds
house/zone active, plant/pet dormant for P9/P10; computed dueAt = lastDoneAt +
intervalDays; never-done = due today), persistence at `households/{hid}/careItems`,
Chores tab renamed **Home** (display-only, `house` icon), House care section with
sticker-slap mark-done (lastDoneBy tracked, NO XP/confetti — care is the adults'
ledger), add/edit form, one-tap starter suggestions (HVAC 90d, gutters, deep-clean
rotations, bedding 14d, water heater). (C2) `HouseHealth` rollup banner
(overdue-terracotta / due-this-week-marigold / **"The house is happy."** bacanGreen),
`careDone` activity items, "Home care" card on Today with inline mark-done (shared
`CareCompletion` helper, mirrors ChoreCompletion). Rollup + card are kind-agnostic —
P9 plants and P10 pets flow in automatically; revisit the "Home care" card label +
house-flavored icon/interval option sets when they land.
Michael's cleaning penchant + house maintenance, distinct from kid chores.
- Introduce the **`CareItem`/`CareTask` primitive** (see spine) with `kind: house/zone`.
- Seed templates: HVAC filters (90d), gutters (seasonal), deep-clean rotation by
  room, laundry cycles (Valentina's domain, her color on it).
- **House health view:** what's overdue / due this week / all caught-up state worth
  celebrating ("The house is happy.").
- Tab rename Chores → **Home**; chores/XP/rewards/leaderboard unchanged within it.

### P9 — Plants & garden  ✅ done (2026-07-02, commits 1b81222…d662662)
Shipped in three chunks: (C1) plant roster in Home — CareItem gains photoPath/species/
speciesLatin/careNotes + `CareTask.firstDueAt` anchor (due-math handles future/past
anchors); photo-thumb rows, plant form (photo → Storage `care/{itemId}/photo.jpg`),
**LeafUnfurl** motion for watering (plants' own signature, not the sticker slap),
verb-aware activity ("Migueluh watered \"Monstera\""), Today card retitled **"Care
due"** with per-kind icons. (C2) **`identifyPlant` callable DEPLOYED** (claude-sonnet-5
vision → common/latin name, confidence, water interval, light, care notes; "Identify
from photo" fills form provenance-captioned; won't stomp customized intervals; low
confidence = warm no-fill). (C3) **Yard & garden section** — zone icon/interval sets,
seasonal starters anchored via firstDueAt to next month occurrence (mulch Mar 15,
prune Feb 15, aerate Sep 15, fall cleanup Oct 15, leaves Nov 15; yearly repeat),
"Due Sep 15" wording for future anchors, persistent-filtered starters card
(multi-add). Rollup surfaces needed ZERO changes for zones — confirmed the same will
hold for P10 pets (form is kind-parametrized; add pet option sets + a Pets section).
- `CareItem(kind: plant)`: photo, species, indoor location or yard zone, water/feed
  intervals, "last watered by Michael, Tuesday."
- **Plant ID via the scan pipeline:** photograph a plant → FM/Claude → species +
  suggested care schedule, provenance-badged, editable.
- **Seasonal yard templates** (spring mulch, fall cleanup, pruning windows) via the
  recurrence engine.
- Thirsty plants surface on Today; watering gets a leaf-unfurl moment.

### P10 — Pets: Fajita & Sprinkle  ✅ done (2026-07-02, commits 2720309 + f18ae6d)
(C1) Pet profiles on the care rails: `CareItem(kind:.pet)` + breed/birthday/vetName/
vetPhone (decode-safe), pet icon/interval sets, Pets section in Home (sky accent),
**"The pack"** starter card — one-tap "Add Fajita"/"Add Sprinkle" pre-filled with the
dog-care schedule (heartworm 30d, flea&tick 30d, grooming 60d, nails 30d),
kind-parametrized form (shared photo section; AI-identify stays plant-only),
natural activity verbs (groomed / trimmed nails for / walked / bathed — "bath" only,
"wash" would misfire on laundry). (C2) **Vet records = Family Brain**: `processDocument`
now matches household PET names → `linkedPetIds` (deployed; literal-match rule;
verified E2E — a seeded rabies cert auto-typed `pet`, auto-linked to Sprinkle, expiry
extracted); document detail gains a Pets link/unlink menu; pet profile shows a
"Vet records" timeline pushing the real DocumentDetail (ChoresFeature→DocsFeature,
cycle-free) with expiry chips; pet rows show terracotta expiry chips ≤30d; Today's
Needs-attention covers pet certs automatically. Note: docs naming an unlisted pet tag
the name instead — manual link or reprocess after adding the pet.
- **Pet profiles** (`CareItem(kind: pet)` + pet-specific fields): photo, birthday,
  breed, vet contact, weight log.
- **Care schedules:** meds, heartworm/flea-tick, grooming, nail trims — CareTasks.
- **Vet & vaccination records = Family Brain documents** linked to the pet:
  scan the vet paperwork → typed `pet` + linked to Fajita → `expiryDate` on the
  rabies cert → "Sprinkle's rabies vaccine expires in 30 days" falls out of P7
  machinery. Pet profile shows its document timeline.

### P11 — Kids' memory log (Oliver & Famfis)
The module that appreciates every year. "Famfis" itself is the proof: the kind of
thing that vanishes if nobody writes it down.
- `Memory { kidIds, kind (quote/milestone/photo/note), text, photoPaths, date }`;
  Storage + polaroid UI (`PolaroidFrame` exists), timeline per kid, quick-capture
  from Today. Linked Brain documents (scanned artwork!) appear on the timeline.

### P12 — Smart home: Philips Hue, hyper-specific  ✅ done (2026-07-02, commits 04dccd6…41667a6)
**C3 (ad7a3db): multi-bridge** — bridges array w/ lossless legacy migration (Michael's
live paired doc protected + left legacy, migrates on next save), rituals/sensors
scoped per-bridge (nested maps), Settings bridge list + Add-a-bridge (appends,
excludes paired ids, binds standard rituals against the new bridge — Bedtime binds
upstairs), per-bridge degrade (dead bridge hides only ITS rituals). **C4 (41667a6):
granular House control surface** (Michael's correction #3) — "The house ›" from the
Today card: bridge-grouped rooms/zones, owner dots, optimistic toggles, per-room +
per-light debounced brightness (150ms trailing, unit-tested — the >10req/s bridge
limit NowSpinning ignored), scene capsules, unreachable lights disabled ink-soft;
stateful mock store for bridge-less verification; `// SEAM (P14)` on
setGroupState/setLightState — the agent tools wrap these same verbs.
Shipped: (C1) `HueClient` target (V1 REST ported/trimmed from NowSpinning + NEW
scenes/sensors/rediscover; private-IP cert trust; mock mode for bridge-less
verification) + `HueConfig` contract at `households/{hid}/config/hue` + Today's
**"The house" card** — sensor temps ("Famfis's room 72°"), lights summary, ritual
buttons (Bedtime evening-prominent ≥18:00 unit-tested, Dinner's-ready meal-plan
aware); config absent/unreachable → card hides silently. (C2) **bridge lifecycle
in Settings** — Smart home section (status + reachability dot, ritual binding rows,
Re-pair), pairing sheet (discover → link-button 30s auto-poll → key → binding step),
name-based auto-match (scene name contains ritual key/label word; sensor labels
carry forward via `sensorNames`), unbound rituals simply don't render. TestStore-
verified state machine; discovery from the sim found Michael's 3 real bridges
(deliberately did not authenticate). **REMAINING HUMAN STEP: Michael pairs on his
phone** — Settings → Smart home → Set up Philips Hue → press bridge button →
confirm bindings → save. Pre-existing `SettingsReducerTests` crash (environmental,
predates P12) noted for later.

**Design (as refined with Michael 2026-07-02):**
- **Not another Hue client** — no device browser, no per-light controls, no generic
  settings. BUT (Michael's correction #2, 2026-07-02): **bridge lifecycle DOES belong
  in the app** — bridges die/get repurposed, and re-pairing must not require a dev
  session. A minimal flow in the Settings sheet: bridge status, discover → link-button
  30s countdown → key → config doc written (NowSpinning's pairing state machine ports
  directly). **Re-pair preserves meaning:** rituals/sensor labels live in Firestore and
  survive bridge death; scene/sensor IDs are re-bound BY NAME on the new bridge, with
  a simple per-ritual scene picker for anything unmatched. First pairing happens
  in-app on Michael's phone (already on the LAN) — the C0 chat-pairing session is
  obsolete.
- **Hybrid config/live split (Michael's correction to the original all-hardcoded
  pitch):** the Firestore config doc `households/{hid}/config/hue` holds IDENTITY —
  bridge address, app key, family mappings (room↔member, which scene is "Bedtime"/
  "Dinner") — while the app pulls LIVE inventory + state from the bridge (rooms,
  scenes, light states, sensor temps). Config-as-conversation for the mappings.
- **Rituals chosen:** Bedtime button (evening-prominent on Today), Dinner's-ready
  scene (meal-plan aware), room temps on Today (motion sensors as nursery
  thermometers). Chore→member-color-blink CUT (not selected).
- **Boilerplate source:** NowSpinning (`~/repo/nowspinning`) has a working Hue
  integration — port its client patterns rather than rewriting.
- Local-network-first; bridge unreachable → the card simply hides. Remote OAuth
  maybe later. Pairing (C0) deferred until Michael is near the bridge — C1 builds
  against the config contract with previews/mocks and goes live the moment the
  config doc exists.

Original notes (still apply): one `HueClient` dependency, local-first:
- **Bridge pairing:** mDNS/Bonjour discovery → link-button press → app key,
  stored per-device (Keychain). Local **CLIP v2 API** (HTTPS REST) for control.
- **Live state:** CLIP v2 **Server-Sent Events** stream → rooms/zones, light and
  scene state, and crucially the **sensor data Hue gives for free**: motion
  sensors report presence, *temperature*, and light level → per-room temperature
  on the Today dashboard costs nothing.
- **Family-flavored automations** (the reason to go deep rather than generic):
  - Chore completed → a light blinks once in *that member's color* (Oliver will
    complete chores just to see it).
  - Bedtime scene for the boys' rooms, one tap from Today.
  - Dinner scene tied to the meal plan ("Dinner's ready" moment).
  - Plant grow-lights on schedules driven by P9 care items.
- **Away-from-home control** via the Hue cloud Remote API (OAuth) — later
  sub-phase; local-first ships the value.
- Later Hue-adjacent products (buttons, dials, smart plugs) and any other
  ecosystems in the house each get their own deliberate integration when wanted —
  same hyper-specific philosophy.
- **Michael's correction #3 (2026-07-02): granular control IS wanted** — the
  rituals-only stance was too pure. P12-C4 builds a full House control surface
  (rooms/zones/lights with on-off/brightness/scenes, drill-down, multi-bridge,
  roomOwners avatars) as the SUBSTRATE that future family-centric experiences
  compose on as more smart-home signals layer in. Whimsy suggestions (vinyl night,
  December button, darkness-aware bedtime, pantry awareness) explicitly parked —
  "none of that blows me away yet"; revisit when layered signals produce real use
  cases. C5 candidate: CLIP v2 SSE live state.

### P13 — Money: expense tracking + budgets (Michael's request, 2026-07-02)
**C1 ✅ shipped 2026-07-02 (commit 2f13ff4, built in a PARALLEL WORKTREE while P15
ran on main):** Expense/BudgetConfig models, Money pinned row in Lists, month view
(total, category bars vs budgets, terracotta over-budget), "New from the Brain"
inbox (one-tap File-it, tag-based category auto-suggest — verified live: the real
Kindercare doc → $175 Kids), manual add, budget editor. Remaining: Today "This
month" card (C2), email/statement ingestion, optional Plaid.
Ordering flexible (can jump ahead of P11/P12). **Key insight: the Family Brain
already extracts vendor/amount/docDate from receipts — Phase 1 is a lens, not a
pipeline.**
- **Model:** `Expense { amount, vendor, category, date, memberId?, source
  (receipt-scan/email/statement/manual), documentId? (Brain link), notes }` +
  `Budget { category, monthlyLimit }` under `households/{hid}`.
- **Ingestion ladder (build in this order):**
  1. Promote Brain receipts → expenses (auto-suggest category via the existing
     extraction; one-tap confirm or silent with review).
  2. Manual quick-add from Today's quick actions (amount/vendor/category, 3 sec).
  3. Email receipts via the Postmark pipeline (extend receiveEmail/eventExtract
     with an expense path — order confirmations, utilities).
  4. Statement import (CSV/OFX via file/share-sheet; OFX deterministic, messy
     PDFs via Claude) — the share-extension intake doubles for the Brain.
  5. Automatic bank sync — researched 2026-07-02, three viable single-family paths:
     - **Plaid free Trial plan** (teams created ≥2026-04-15): real production data,
       up to 10 Items (institution connections) at $0, INCLUDING Chase/BofA/Wells
       OAuth. 10 institutions is plenty for one family → likely winner. Pay-as-you-go
       (~$0.30–0.60/Transactions call) only if we ever outgrow it. Has a
       recurring-transactions endpoint (repeat-expense detection for free).
     - **SimpleFIN Bridge**: $15/yr read-only, daily refresh, purpose-built for
       personal tools (Actual Budget ecosystem) — the simple fallback.
     - **Apple FinanceKit**: Apple Card/Cash/Savings transactions ON-DEVICE,
       real-time, free — needs a per-bundle-ID entitlement request to Apple
       (case-by-case approval). Perfect complement if the family runs Apple Card.
     Recurring-expense detection: Plaid's recurring endpoint when synced; otherwise
     cluster vendor+amount+cadence over normalized transactions (Claude does this
     well over a few months of data).
- **Display:** "This month" card on Today (spent vs typical month, quiet until
  notable); Money view — category bars vs budgets (family palette), month picker,
  vendor patterns ("3rd Costco run this month"); briefing may mention spend
  gently. Budgets = per-category monthly limits, warm copy, no shame mechanics.
- Category taxonomy: start small (groceries/dining/kids/house/garden/pets/fun),
  Claude auto-categorizes, family can re-file.

### P14 — The assistant: an agent harness over the whole app (Michael's request, 2026-07-02)
**C1 ✅ (fca070d) + C2 ✅ (f79d8ee) shipped 2026-07-03.** C1: `AgentTools` target —
24 tools wrapping every app verb (queries + family actions + fleet controls), fuzzy
name resolution (species/breed aliases → "the monstera" finds Monty), `AgentLoop`
actor with confirmation-pause/resume, `agentTurn` callable (claude-sonnet-5) DEPLOYED.
C2: sparkles button on Today → chat sheet over AgentLoop, streaming family-voice
answers, action-chip receipts, inline terracotta confirmation cards for garage/lock,
keyboard dictation. LIVE-verified against the deployed proxy with real data + tools.
Remaining: C3 multi-turn memory + Today "ask" affordance; C4 the true MCP server.
Goal: "I just finished watering the monstera, leaving the house, what time is
Oliver's KinderCare event?" → the app marks the watering done, answers from
calendar/Brain, and preps the house — one utterance, many tools.
**Architecture (decided in planning): tools on the phone, model behind a proxy.**
The phone is the only place Firestore auth, member identity, AND the LAN (Hue)
coexist — so the agentic loop runs client-side; a dumb `agentTurn` callable holds
the ANTHROPIC_API_KEY and does single model calls.
- **C1 — Tool registry:** Swift `AgentTool` protocol + registry wrapping EXISTING
  verbs (ChoreCompletion, CareCompletion, PersistenceClient CRUD, Brain search,
  HueClient) with JSON schemas: mark_care_done, complete_chore, query_calendar,
  add_event, search_brain, get_today_snapshot, check_off_list_item, add_to_list,
  get_meal_plan, set_room_lights, recall_scene, get_house_status. The registry is
  the "MCP-type interface" — future devices (Roomba etc.) join as new tools.
- **C2 — `agentTurn` proxy function:** {messages, tools} → one Claude call →
  response; client executes tool_use locally and loops. No family logic serverside.
- **C3 — Assistant UI:** sparkles button on Today → chat sheet, dictation, streaming
  text, ACTION CHIPS as receipts ("✓ Watered Monstera · 💡 Downstairs dimmed").
  System prompt = family context + Today snapshot. Family voice.
- **C4 (later) — true MCP server** over the family Firestore (data/query tools) so
  Claude.ai / Claude Code can talk to the family brain from anywhere; house control
  stays app-side (LAN).
- Roomba/other devices: integrate when wanted; they arrive as tools in C1's registry.

### P15 — The fleet: rest of the smart home (researched 2026-07-02)
Same hyper-specific philosophy as Hue; each device = a client module + P14 agent
tools. **Recommended order (Michael to confirm):**
1. **Lutron shades** — LEAP protocol: LOCAL, button-press pairing (the Hue playbook
   again); port from pylutron-caseta / lutron-leap-js / HA's integration. Works on
   standard + Pro Caseta bridges and RadioRA3. Payoff: Bedtime ritual closes the
   boys' shades + dims lights in one tap. OPEN QUESTION: which Lutron line (Caseta
   vs RadioRA3)?
2. **Sonos** — local UPnP (stable, LAN-first) or official cloud Control API.
   Turntable-room / NowSpinning adjacency; Dinner's-ready gains a soundtrack.
3. **Nest thermostat (+ camera EVENTS later)** — official Google SDM API, Device
   Access program ($5 one-time individual), OAuth + Pub/Sub. Thermostat on the
   house card ("set to 70"); camera streams are out of scope, motion/person/package
   events are future signals.
4. **Hubspace / Husky hose spigot** — NO official API; unofficial cloud
   (aiohubspace / jdeath HA integration, username-password, ~30s polling,
   rate-limited). Killer tie-in: P9 yard-care "water the beds" mark-done actually
   opens the spigot.
5. **Garage — RESOLVED: Refoss (2026-07-02)** = rebadged Meross → **LOCAL LAN
   control**, no ratgdo needed. Meross-protocol HTTP on LAN (reference:
   krahabb/meross_lan; HA also has a native `refoss` integration w/ LAN socket
   discovery). Messages signed with a device key (recoverable from the
   Refoss/Meross account pairing). Garage = cover device: state + open/close.
   Slots in as P15-C5. ✅ **SHIPPED P15-C5** — `MerossClient` (envelope +
   `MD5(messageId+key+timestamp)` sign, `Appliance.System.All` / `.GarageDoor.State`
   GET/SET), manual-IP setup (UDP-broadcast discovery avoided — needs the restricted
   iOS multicast entitlement), House "Garage" section with **open confirmation-gated**
   (security surface) + ~20s "Opening…" settling re-read.
6. **Ford F-150 Lightning + Charge Station Pro (researched 2026-07-02) → P15-C6.**
   Truck: FordPass API (reverse-engineered; marq24/ha-fordpass fork is EV-optimized
   with cloud-PUSH websocket — no polling) — battery %, range, charge state,
   plugged-in, charge logs; one-time token setup with Michael's FordPass account.
   Charger: the Charge Station Pro is a REBADGED SIEMENS VersiCharge running
   embedded Linux with a LOCAL Django REST API (ericpullen/fcsp-api +
   aminorjourney/local-fcsp are the references; needs a developer key, community-
   documented; OCPP 1.6J fallback). House-card line: "Truck · 82% · ~230 mi ·
   charging — full by 6:20am". Composes with P6.2 drive-times + P14 ("charged
   enough for the weekend trip?").
7. **Apple HomeKit bridge (Path B, 2026-07-02) → P15-C7.** ✅ **SHIPPED** — Michael's Refoss
   garage turned out HomeKit-paired + never cloud-registered (Meross LAN key locked; `MerossClient`
   stays as the alternate path). Integrated **Apple HomeKit directly** (`HomeKitClient` wraps
   `HMHomeManager`; entitlement `com.apple.developer.homekit` + `NSHomeKitUsageDescription`): local,
   keyless, and it absorbs EVERY HomeKit accessory. Async `inventory()` returns a Sendable snapshot
   (`HKInventory`→`HKAccessory`→`HKService`→`HKCharacteristicSnapshot`); `setCharacteristic` writes
   garage/lock/power/brightness. House "Garage" section is **HomeKit-sourced when the Home has a
   garage opener, else Meross fallback** (precedence documented in `HouseReducer`); a new **HomeKit**
   section adds door locks (unlock confirmation-gated), plugs/switches (toggle), and temp/contact
   sensors (read-only) — **lights excluded** (Hue owns them). An "All HomeKit devices" inventory
   surface reveals the rest of the Home. Settings "Smart home" gains a HomeKit row (Connect / denied
   deep-link / Connected · {home} · N). **Shipped snapshot+refresh** (no delegate `changes()` stream
   this chunk). Mock via `config/homekit {mock:true}`.
These are the "layered signals" Michael predicted (2026-07-02) — real automations
(shades+lights+thermostat+presence+truck) emerge once several are in.

### Side quest (anytime after P5) — Oliver mode
Activate the dormant `.child` role: picture-based chore board, huge tap targets,
maximum celebration. He's 3½ — exactly the age it lands. Additive by design (P0
kept the enum for this).

## Small-wins backlog (dormant bits, slot into any phase)
List icon/color picker UI · list-item due dates in UI · reward icon picker ·
redemption history screen · `longestStreak` on leaderboard · ingredient qty/unit
manual entry · breakfast/lunch meal slots · show `appVersion` in Settings.

---

## Act I phases (complete)

### P0 — Foundation (member profiles)  ✅ done
Evolve the thin `Household` (members = bare UIDs) into a real roster.
- [ ] `HouseholdMember` model + `MemberColor` palette (ported/simplified from Fambo).
- [ ] `PersistenceClient`: `members(hid)`, `saveMember(hid,member)`, `ensureMember(hid,uid,name)`.
- [ ] Seed the creator's member profile on household creation; seed the joiner's on join.
- [ ] `SettingsFeature`: show the family roster (color dot, name, role); edit own name/color.
Unblocks every later phase.

### P0.5 — Reframe the app shell
3 tabs (Cellar/Scan/Settings) → a family hub. Proposed:
**Home (dashboard) · Calendar · Lists · Chores · More** — with Wine, Recipes/Meal,
and Settings under **More** (iOS shows 5 tabs before collapsing to a More menu).
`MainTabReducer`/`TabItem` grow; each new feature scopes in as a child reducer.

### P1 — Lists
Smallest, most self-contained, highest daily payoff. Shared shopping/task lists
with assignees + due dates. Port `ListsFeature` + `List`/`ListItem` models against
`/households/{hid}/lists` + `/listItems`. Proves the port pattern.

### P2 — Calendar
Day/week/month shared calendar, recurring events, EventKit sync. Port
`CalendarFeature` + `Event` model + the `dailyRecurrenceExpansion` Cloud Function.
**Defer** the AI email→events extraction as an optional later add-on.

### P3 — Chores + XP / Rewards
Largest domain. Chore assignment, completion, XP/streaks/levels, parent rewards +
redemption. Requires two reusable cross-cutting pieces introduced here:
- **FCM push notifications** (Menere has none today; Fambo's is rich).
- **Activity feed** (`/households/{hid}/activity`).
Port `ChoresFeature`, `MemberStats`/`Chore`/`Reward`/`Redemption` models, and the
`onChoreToggled` XP-award Cloud Function.

### P4 — Recipes + Meal Planning
Recipe storage/URL import, weekly meal planner, auto-generate grocery list.
Comes last because meal-plan → grocery-list generation **reuses P1 Lists**. Port
`RecipesFeature` + `MealPlanFeature` + `extractRecipe` Cloud Function.

## Cross-cutting ports (introduced when first needed)
- **Push (FCM)** — at P3.
- **Activity feed** — at P3.
- **MenereUI vs Fambo design system** — reuse Menere's brand chrome (parchment,
  wine palette, serif type, haptics); bring Fambo's 8-color *member* palette along
  with the `Member` model for per-person color coding.

## Explicitly out of scope (private app)
Subscriptions/RevenueCat · free-tier rate limits · managed members / child
claim-by-code · child-safe dashboard · marketing assets · App Store onboarding ·
public-launch App Check hardening. (Any of these can be revisited if the app ever
goes public.)

## Working style
Per dev-workflow: pre-customer MVP — commit frequently, push freely, one manual
smoke test at the end of each phase. Data is greenfield, so no migrations needed.
