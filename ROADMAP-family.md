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

## Phases

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
