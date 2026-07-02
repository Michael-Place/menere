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
Known gap: upload→auto-process handoff is code-reviewed but first exercised on a real
device (sim's PhotosPicker is unreachable by automation). Not yet built: email-forward
+ share-extension intake (P7.3 spec) — natural follow-on chunk.
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

### P8 — Home care hub (Chores tab → "Home")
Michael's cleaning penchant + house maintenance, distinct from kid chores.
- Introduce the **`CareItem`/`CareTask` primitive** (see spine) with `kind: house/zone`.
- Seed templates: HVAC filters (90d), gutters (seasonal), deep-clean rotation by
  room, laundry cycles (Valentina's domain, her color on it).
- **House health view:** what's overdue / due this week / all caught-up state worth
  celebrating ("The house is happy.").
- Tab rename Chores → **Home**; chores/XP/rewards/leaderboard unchanged within it.

### P9 — Plants & garden
- `CareItem(kind: plant)`: photo, species, indoor location or yard zone, water/feed
  intervals, "last watered by Michael, Tuesday."
- **Plant ID via the scan pipeline:** photograph a plant → FM/Claude → species +
  suggested care schedule, provenance-badged, editable.
- **Seasonal yard templates** (spring mulch, fall cleanup, pruning windows) via the
  recurrence engine.
- Thirsty plants surface on Today; watering gets a leaf-unfurl moment.

### P10 — Pets: Fajita & Sprinkle
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

### P12 — Smart home: Philips Hue, hyper-specific
Decision: per-product deep integrations (no generic abstraction); **Hue first**
because the whole house runs on it. One `HueClient` dependency, local-first:
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
