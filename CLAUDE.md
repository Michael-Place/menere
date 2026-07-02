# Menere — Private Family Hub

**Menere is a private, family-only iOS app** serving our family's niche needs. It began as a
wine tracker and **pivoted** into a multi-feature family hub; wine is now one module among
several. It leans toward **never going public** (no subscriptions, no marketing, no rate limits,
minimal public-launch hardening).

For the full pivot plan, phase history, and decisions, see **`ROADMAP-family.md`**.

**Act II (in progress — P5 identity ✅ and P6 Today dashboard ✅ shipped):** the app is now **"Bacán"**
(Chilean slang; user-facing only — bundle ID, Firebase project, repo, and package all stay
`menere`). Family surfaces wear the new identity (familyCanvas cream, bacanGreen,
terracotta/marigold/sky, rounded type, playful motion via `.stickerSlap`/`ConfettiBurst`);
the wine stack keeps parchment behind `.wineChrome()`. Remaining Act II roadmap — new visual identity
(replacing parchment/wine on family surfaces), Today dashboard, Family Brain (AI document
vault), care hub (house/plants/pets), kids' memory log, smart home. The family: Michael,
Valentina, Oliver (3), Francis ("**Famfis**" — Oliver's pronunciation, used in copy), dogs
Fajita & Sprinkle. Copy voice everywhere: **warm + witty, first names**. See the Act II
section of `ROADMAP-family.md` before building anything new.

## Repository layout
Monorepo. **Repo root is here** (git remote `git@github.com:Michael-Place/menere.git`, branch
`main`); top-level docs (`CLAUDE.md`, `ROADMAP-family.md`) + `.mcp.json` live at root. The iOS app
is in **`ios/`** (all paths below are relative to it unless prefixed). A future web client would
sit alongside as `web/`. Run `git` from the root; run Firebase/Xcode tooling from `ios/`.

## Stack
- **UI/state:** SwiftUI + TCA (The Composable Architecture) + `swift-dependencies` + `swift-sharing`.
- **Backend:** Firebase — Auth (Phone/OTP; Sign in with Apple ready), Firestore, Storage,
  Cloud Functions (Node 22, Functions v2, `us-central1`).
- **Deployment target:** iOS 26+ (iOS 27 multimodal Foundation Models used with fallback).
- **Project generation:** XcodeGen (`ios/project.yml`) → `ios/Menere.xcodeproj`. Swift package:
  `ios/MenerePackage`. **After editing `project.yml`, run `xcodegen generate`** (from `ios/`).

## App shell (tabs)
`MainTabView` (in `AppCore`) — five primary tabs, no **More** menu:
**Today · Calendar · Lists · Chores · Kitchen** (Today is first and the default).
**Today** (`TodayFeature`) is the dashboard: greeting, AI daily briefing
(`generateDailyBriefing`, per-day cached), today's schedule, tonight's dinner, quick-action
tab deep-links, chores-today card (inline completion via the shared `ChoreCompletion`
helper in `FamilyDomain`), family member grid. **Family** (`SettingsFeature`) is not a tab — it's a
`person.crop.circle` toolbar button (top-leading on every tab) that presents `SettingsView` as a
sheet, driven by `showSettings` in `MainTabReducer`.
Wine is re-homed **under the Lists tab** as a pinned "Cellar" collection row (not a tab): tapping it
pushes `CellarView` (the full wine stack), and Scan is a full-screen modal over it (camera toolbar
button / Cellar empty-state). The wine state (`cellar`/`scan`/`showScan`) now lives in
`ListsReducer`; the wine domain code is otherwise unchanged.

## Feature domains
- **Calendar** (`CalendarFeature`) — month grid + agenda, event form, **client-side** recurrence.
- **Lists** (`ListsFeature`) — shared lists, check-off, assignees, due dates.
- **Chores** (`ChoresFeature`) — chores with assignment, **server-authoritative XP**, leaderboard
  (live listener), rewards/redemption, auto-regeneration of recurring chores.
- **Kitchen** (`RecipesFeature`) — recipes (+ "Import from URL" via `extractRecipe`), weekly meal
  plan, "generate grocery list" (reuses Lists).
- **Family** (`SettingsFeature`) — member roster, "My Profile" editor (name/color/avatar),
  invite code, join-by-code, sign out.
- **Wine** (`ScanFeature`, `CellarFeature`, `BottleCardFeature`, `JournalFeature`,
  `IdentifyClient`, `EnrichmentClient`, `CatalogClient`) — the original app, preserved intact.
- **Activity feed** — client-written `ActivityItem`s on chore/event/list actions; shown in Chores.
- **Push** (`PushClient`) — FCM token registration; wired in `ios/App/MenereApp.swift` `AppDelegate`.

Shared models live in **`FamilyDomain`** (HouseholdMember/MemberColor, FamilyList/ListItem,
FamilyEvent/RecurrenceOption, Chore/MemberStats/Reward/RewardRedemption/XPCalculator, Recipe/
Ingredient/MealPlanEntry, ActivityItem) and **`WineDomain`** (Wine/Bottle/Tasting/Household).

## Data model (Firestore)
- `/wines/{canonicalKey}` — shared wine catalog (all signed-in users read/write).
- `/users/{uid}` — profile `{ displayName, householdId, fcmToken }` (owner only).
- `/households/{hid}` — family container `{ ownerUid, members:[uid], inviteCode }`; the `members`
  array is the security-rule gate. Subcollections (all member-gated): `members/{uid}` (rich
  profiles), `bottles`, `tastings`, `lists/{id}/items`, `events`, `chores`, `memberStats`,
  `rewards`, `redemptions`, `recipes`, `mealPlan`, `activity`.

> Note: the Firestore collection is still named `households` (not `families`) — a deliberate
> non-churn decision; user-facing copy says "Family". `ios/firestore.rules` gates everything under
> `households/{hid}` by the members array.

## Conventions
- **Persistence** (`PersistenceClient`) is one-shot `async` CRUD, **except** `observeMemberStats`
  (a live Firestore snapshot listener, so the leaderboard reflects server XP writes in real time).
- **Members are keyed by uid** (adults-only for now). `HouseholdMember.role` enum keeps a `child`
  case dormant so kid logins are an additive change later.
- **XP is server-authoritative** — the client only records chore completion + who gets credit;
  `onChoreToggled` awards/reverses XP transactionally. Never re-add client-side XP math.
- Recurrence (calendar + chores) is expanded **client-side**; there is no server recurrence job.

## Cloud Functions (`ios/functions/`, all DEPLOYED to project `menere`)
- `ttbColaLookup`, `joinHousehold`, `identifyLabel` — original wine functions.
- `extractRecipe` — recipe URL scrape (JSON-LD + Claude); reuses `ANTHROPIC_API_KEY`.
- `onEventCreated`, `onListItemChecked` — notify-only FCM triggers.
- `onChoreToggled` — server-authoritative chore XP (`choreXP.js`) + completion push.
- `receiveEmail` — Postmark inbound webhook → Claude event extraction (`eventExtract.js`) →
  writes calendar events. See ROADMAP for the Postmark setup; times default to `America/New_York`.
- `generateDailyBriefing` — callable; Claude-written family-voice daily briefing for the Today
  tab (`briefingGenerate.js`), cached per ET day at `households/{hid}/briefings/{YYYY-MM-DD}`,
  `force` regenerates.

Secrets (Secret Manager): `ANTHROPIC_API_KEY`, `POSTMARK_WEBHOOK_SECRET`.
Admin SDK key (gitignored, local): `ios/menere-firebase-adminsdk-fbsvc-*.json`.

## Build / run / deploy
- **iOS:** prefer XcodeBuildMCP. Session defaults are set (scheme `Menere`, iPhone 17 Pro sim);
  `build_sim` / `build_run_sim`. Run `session_show_defaults` before the first build in a session.
- **Functions:** `cd ios/functions && firebase deploy --only functions:<name> --project menere`.
  First-ever Firestore-trigger deploy may need one retry (Eventarc permission propagation).
- **Git:** monorepo at the repo root (this directory); run `git` from here, not `ios/`.
