# Menere — MVP Roadmap

A wine app centered on **the bottle in your hand**: point your phone at a bottle → get everything
we can find about it on the fly → when you buy or drink it, journal it beautifully.

**Principles**
- **Free to start.** v1 uses on-device intelligence + free data sources only. Paid/higher-fidelity
  tooling (Claude vision, paid catalog/recognition APIs) layers in later behind a provider abstraction.
- **iOS-only, iOS 26+.** TCA v1 + PointFree tooling (swift-dependencies, swift-sharing). Firebase backend.
- **Server-side secrets.** Any keyed/paid API call runs in Cloud Functions, never in the app. (v1 free
  sources are mostly keyless, so much of v1 can stay client-side; we move to Functions when we add keys.)
- **Two-tier data.** A shared global `wines` catalog (cache + moat, grows from every scan) +
  private per-user `bottles` and `tastings`.

The core loop:
`[bottle in hand] → IDENTIFY → RESOLVE → ENRICH → PRESENT (bottle card) → JOURNAL (on Buy/Drink) → RECALL`

---

## Module plan

Existing (from template): `AppCore`, `AuthenticationDomain`, `AuthenticationFeature`,
`OnboardingFeature`, `HomeFeature`, `SettingsFeature`, `UserDomain`.

New for MVP:
- `WineDomain` — `Wine`, `Bottle`, `Tasting` models; canonical key; provenance/confidence types.
- `PersistenceClient` — Firestore reads/writes for the two-tier collections (swift-dependencies client).
- `ScanFeature` — camera, barcode, label capture + on-device identification.
- `IdentifyClient` — image/barcode → candidate wine identity (Apple Vision OCR + Foundation Models).
- `CatalogClient` — resolve canonical key against shared catalog; on miss, run enrichment; write back.
- `EnrichmentClient` — fan-out to free data sources, merge with provenance.
- `BottleCardFeature` — the "present" screen (the wow moment).
- `JournalFeature` — log tastings + add bottles; tasting note schema.
- `CellarFeature` — inventory + history + recall/search.

---

## Milestones

### M0 — Prove out auth ✅ COMPLETE (2026-06-27)
Goal: sign in works end-to-end; user persists; app lands on the tab shell.
- [x] Run on simulator; verify 3-state auth (unauthenticated → authenticating → authenticated)
- [x] **Phone/OTP** verified end-to-end on simulator via Firebase test number → onboarding → Firestore `users` doc ("Vale") → Home tab
- [x] Fixed recurring Firebase phone-auth gotchas (URL scheme, OTP dismiss, SMS region policy, test-number setting)
- [x] APNs key uploaded by user (for real-device SMS later)
- [ ] (Later, on device) Verify Apple sign-in + real-SMS phone on a physical device
- **DoD:** ✅ phone sign-in → onboarding → authenticated tab shell, user persisted to Firestore.

> **Scaffold follow-up:** propagate the four phone-auth fixes back into the `firebase-auth-app`
> template + bootstrap so new projects don't hit them (URL scheme from App ID, SMS region policy,
> OTP-destination dismiss, debug test-number setting).

### M1 — Data model + Firestore foundation 🟡 foundation built
Goal: the spine everything hangs off.
- [x] `WineDomain`: `Wine`, `Bottle`, `Tasting`, `Region`, `WineType`, `BottleStatus`, `Enrichment`/`Provenance`, `SATNote`, canonical-key helper
- [x] `PersistenceClient`: swift-dependencies client — CRUD for `/wines/{key}`, `/users/{uid}/bottles`, `/users/{uid}/tastings`
- [x] Firestore security rules deployed (per-user private docs; shared catalog readable by signed-in users, writes controlled)
- [x] Compiles + integrated into AppCore
- [ ] Runtime round-trip verification (will be exercised organically by M2 scan→resolve and M5 journaling, or via a quick debug screen)
- **DoD:** data layer in place; write/read verified once features land.

### M2 — Capture & Identify (the scan) ✅ COMPLETE (2026-06-28)
Goal: point at a bottle → structured candidate identity. **On-device, free.**
- [x] `ScanFeature`: Scan tab; `DataScannerViewController` (barcode) + camera label capture +
      photo-picker + a bundled "sample bottle" path; identify flow → result card (verified on simulator)
- [x] `IdentifyClient`: barcode fast-path + a **deterministic, layout-aware engine** —
      `VisionDocumentIdentifier` on Vision **`RecognizeDocumentsRequest`** (per-line transcript + bounding
      box). Field assignment by **font prominence + winery-keyword adjacency** (fuzzy, OCR-tolerant) plus
      curated grape/place vocabularies → `{producer, cuvée, vintage, region, grapes}`. **No LLM in the
      identify path** (the OCR→Foundation-Models approach was nondeterministic at field assignment; see
      `docs/identify-engine.md`). Per-field grounding guards retained.
- [x] Verified on a **real bottle** (Emiliana "Natura" Carmenère, Chile, 2023) end-to-end on device:
      producer/cuvée/vintage/region/grape all correct and **reproducible**.
- **DoD:** ✅ scan a real bottle → structured candidate identity (no enrichment yet).

> **M2.5 (iOS 27 multimodal engine) 🟡 implemented, output unvalidated:** `MultimodalFMIdentifier`
> behind `@available(iOS 27)` on the same `IdentifyClient` seam feeds the label **image** to Foundation
> Models → `@Generable` in one pass, grounded, with fallback to the deterministic engine. Deployment
> target stays iOS 26 (`@_weakLinked` FoundationModels to back-deploy cleanly). Runtime-validated on the
> iOS 27 sim: path fires, FM available, graceful fallback — but the multimodal **model isn't provisioned
> on the sim** (`ModelManagerError 1001`), so output quality awaits a real iPhone on the iOS 27 beta.
> Builds require **Xcode 27**. Full design + sourced toolchain comparison in `docs/identify-engine.md`.

### M3 — Resolve & Enrich (free sources) 🟢 implemented; one manual e2e scan pending
Goal: turn a candidate into a rich, cached `Wine`.
- [x] `CatalogClient`: canonical-key lookup in shared `/wines`; cache hit → instant return; miss → enrich → upsert → return (stable `resolve(WineCandidate)→Wine` seam)
- [x] `EnrichmentClient` (on miss): concurrent, resilient fan-out — **Open Food Facts** (barcode→product, client-side keyless), **Wikidata** (grape→wine-color→`WineType`, client-side SPARQL), **TTB COLA** (US class/type via a deployed Cloud Function `ttbColaLookup`), **Foundation Models** second-pass gap-fill for descriptive fields (on-device, iOS 26 `SystemLanguageModel` / iOS 27 PCC, `@_weakLinked` back-deploy)
- [x] `MergeEngine`: per-field **provenance + confidence**; authority `user > authoritative {OFF/TTB/Wikidata/Kroger} > ocr > llm`; `user` never overwritten; **hard facts (`abv`) rejected from `llm`**; `.llm` fills only still-empty descriptive fields (world-knowledge fill returns here, identity-grounded)
- [x] Write resolved `Wine` back to shared catalog (`upsertWine`); wired into `ScanFeature` (`.identifyResponse → .resolving → catalog.resolve → .resolved(Wine)`, graceful fallback to `.result(candidate)`)
- [x] **Decision:** on-device for all free/keyless sources (CORS is moot for native `URLSession`; `/wines` is the shared cache); Cloud Functions reserved for messy/keyed sources — TTB COLA proxied via a deployed `onCall` fn (project on Blaze), tested live end-to-end
- [x] Verified: full unit coverage (merge authority/guards, cache hit/miss) + **live** OFF/Wikidata/TTB round-trips + a **live e2e enrichment test** (real fan-out → multi-source provenance map) all green on the iOS 27 sim
- [ ] **Pending:** one manual signed-in scan on sim/device → confirm the real `/wines/{key}` doc via the admin read-back (UI automation broken under the Xcode 27 beta, so this can't be driven headlessly)
- **DoD:** scan → enriched `Wine` with provenance, persisted to the shared catalog.

> **M3 toolchain/infra notes:** TTB Cloud Function deployed at
> `https://us-central1-menere.cloudfunctions.net/ttbColaLookup` (Node 22, firebase-functions v2 `onCall`,
> region us-central1; scrapes the TTB COLA public registry — handles its missing TLS intermediate cert +
> 15-year date-window cap; `// TODO` enforce App Check/auth before public launch). On-device AI-fill is
> validated for code-path + graceful fallback only; generated-text **quality** awaits a real device with
> Apple Intelligence (AFM model isn't provisioned on the sim → `ModelManagerError 1001` → degrade-to-nil).

### M4 — Present (the bottle card) 🟢 implemented; visual confirmation pending
Goal: the moment that makes someone point their phone at a shelf.
- [x] `BottleCardFeature`: progressive card — identity + captured label image render instantly, enrichment-derived rows (style/ABV/drink-window/summary/pairings/producer-note) **shimmer** (`.redacted` + sweep) while `catalog.resolve` runs, then fill in. Same view + stable `.id` across `.resolving(candidate)`→`.resolved(wine)` so it animates rather than swaps
- [x] **Provenance badges** per derived fact: Verified (OFF/Wikidata/TTB) · AI estimate (`.llm`) · Scanned (`.ocr`) · You (`.user`); + a legend. Label image (in-memory captured `Data`; Storage upload/`labelImageURL` deferred). Region/grape(chips)/style/ABV/drink-window all rendered, nil rows skipped
- [x] Wired into `ScanFeature` (renders for `.resolving`+`.resolved`; `capturedImageData` threaded through state, cleared on `.scanAgain`); polished `.failed` + barcode-only `.result` fallback
- [x] Verified: `BottleCardFeature` badge-mapping unit tests + `ScanFeature` `TestStore` tests (image thread-through, progressive states, barcode fallback, scan-again reset) all green; 5 `#Preview`s incl. resolving-shimmer + enriched-with-image
- [ ] **Pending:** human visual eyeball on sim/device (UI automation broken under the Xcode 27 beta) — same manual scan also closes M3's `/wines` write check
- **DoD:** a beautiful bottle card rendered from a live scan.

### M5 — Journal (buy/drink) — the retention core 🟢 implemented; one manual e2e pending
Goal: best-in-class logging.
- [x] From the card: **Add to cellar** — `JournalFeature.BottleFormReducer` (price, qty, currency, store, location, drink-from/by, status picker); `persistence.saveBottle(uid, Bottle)` with `wineId = wine.id`
- [x] **Log a tasting** — `JournalFeature.TastingFormReducer` (★ `ratingStars` + optional 100-pt, free-text note, free-text SAT sections, who/occasion, optional link to a cellared `Bottle` of this wine); `persistence.saveTasting(uid, Tasting)`
- [x] **Photos:** stood up Firebase **Storage** (previously absent) — owner-only `storage.rules` deployed; `StorageClient.uploadTastingPhoto(uid, tastingId, Data)→URL` (bucket `menere.firebasestorage.app`); tasting form `PhotosPicker` → upload → `Tasting.photoURLs`
- [x] **Wiring:** `BottleCardFeature` gains `@Presents destination` (Add-to-cellar / Log-tasting) + buttons; reads the signed-in uid via `@Shared(.user)` and injects it so the forms stay pure; `ScanReducer` now hosts the card as a real composed child (set on `.resolveResponse`). SAT kept **free text** (WSET trademark — no verbatim enums)
- [x] Verified: `JournalFeature` reducer tests (bottle 3 / tasting 6 — incl. photo-upload, no-photo-no-Storage-call, upload-failure, SAT→nil, bottle-link filter), `BottleCardFeature` destination tests, updated `ScanFeature` `TestStore` tests, full-app build — all green on the sim; Storage admin upload/download round-trip PASS
- [ ] **Pending:** one manual signed-in scan on sim → Add bottle + Log tasting → admin read-back of `/users/{uid}/bottles` + `/tastings` + linked `/wines/{key}` + Storage object (UI automation broken under the Xcode 27 beta, so this can't be driven headlessly)
- **DoD:** can add a bottle and log a tasting; both persist per-user and link to the `Wine`.

### M6 — Recall & Cellar 🟢 implemented; covered by the end-of-roadmap manual smoke test
Goal: "what do we have?" and "what did we love?"
- [x] `CellarFeature` (new Cellar tab): inventory list joining `bottles(uid)` → `wines` (new batch `PersistenceClient.wines(keys:)`); `.searchable` (producer/region/grape) + sort (recently-added/producer/vintage/drink-window) + status/type filters; **drink-window surfacing** (hold/drink-now/past classified at load from `bottle.drinkFrom/drinkBy` vs current year)
- [x] History/recall: Cellar tab **Cellar/History segment**; tasting history joined to wines; shared search + min-rating (3/4/4.5★+), grape, and date/rating sort. **Home dashboard** (`HomeFeature`): cellared/wines/tastings/wishlist stat tiles, "drink soon" list, recent tastings
- [x] Verified: `CellarFeature` reducer tests (10 — load+join, drink-window classify, search/status/type/sort, tasting join+orphan-drop, min-rating, grape, history sort) + `HomeFeature` reducer tests (4 — stats, drink-soon sort/cap, recent-tastings sort/cap, no-uid) + full-app build, all green on sim
- **DoD:** browse & search the full cellar + tasting history fluidly.

### M7 — Household sharing 🟢 implemented; live invite/join exercised in the end-of-roadmap smoke test
Goal: both of you on one shared cellar/history.
- [x] Shared `/households/{hid}/{bottles,tastings}` space + member-gated Firestore rules (deployed). `Household{members[],ownerUid,inviteCode}` + `User.householdId`; a personal household is auto-created on auth (`ensureHousehold`) and the hid stored in `@Shared(.user)`. All journal/cellar/home reads+writes key on the household. (Tasting photos stay under the uploader's `/users/{uid}` Storage path — shared via download-URL tokens.)
- [x] Invite/join: `joinHousehold(code)` **Cloud Function** (deployed us-central1; finds household by invite code, `arrayUnion`s the caller into members, sets their `householdId`) + Settings "Household" section (shows your invite code, Join-by-code via `HouseholdClient`).
- [x] Verified: admin data round-trips (household path + the join mutation) PASS; reducer tests — Settings 3, plus the uid→household migration kept BottleCard 12 / Journal 9 / Cellar 10 / Home 4 green; full-app build green on sim. (Two-device live invite/join is part of the final manual smoke test.)
- **DoD:** both accounts read/contribute to the same cellar.

### M8 — Polish + TestFlight 🟢 shipped — TestFlight build live, verified on device
- [x] Empty/error/offline states: error + "Try again" retry across Cellar/Home; explicit Firestore offline cache (`PersistentCacheSettings`); empty states across Home/Cellar/History
- [x] Scan **first-run onboarding** explainer (persisted via `@Shared(.appStorage)`)
- [x] **App icon** — 1024 asset catalog wired via XcodeGen (`ASSETCATALOG_COMPILER_APPICON_NAME`). NOTE: `xcodegen generate` deletes the manual `container:MenerePackage` test xcschemes — restore them with `git checkout -- Menere.xcodeproj/xcshareddata/xcschemes/` after any regen
- [x] **TestFlight upload** — archived (Release) + exported `app-store-connect` (automatic Apple Distribution signing) + uploaded via the ASC API key. **v1.0.0 (1)** processed and **verified working on device via TestFlight** (2026-06-30). This run also served as the end-to-end smoke test (sign-in → scan → cellar/journal).
- _Perf: not a dedicated pass — current loads are simple list joins; revisit if a real cellar gets large._
- **DoD:** ✅ installable via TestFlight for the two of us.

---

## 🎉 MVP complete (M0–M8). Next = Post-MVP backlog below.

---

## Post-MVP (layer in once it earns it)
- [x] **Higher-fidelity identification — Claude vision** 🟢 shipped. `identifyLabel` Cloud Function (deployed us-central1) reads the label image with `claude-opus-4-8` vision + structured-output extraction (label-grounded: only what's printed, no world knowledge). iOS `CloudVisionIdentifier` is the **primary** scan engine behind the existing `IdentifyClient`/`LabelIdentifier` seam, with automatic fallback to the on-device engine (iOS 27 multimodal FM / iOS 26 Vision) when offline or on error. Anthropic key in Secret Manager. Verified: live function test (real label → producer/name/vintage @ 0.97) + `IdentifyClientTests` (6) + `ScanFeatureTests` (5) + full build green.
  - Still open: label-image-match recognition service (visual similarity); enforce App Check/auth on the function before any public launch.
- **Recommendations:** content-based "you'd like this" (works without a user base; no cold-start).
- **Richer catalog:** paid partner API (InVintory / Wine-Searcher) if we go public.
- **Pricing/where-to-buy:** Kroger / LCBO integrations.

## UX / IA Enhancements (post-launch polish — worked serially) ✅ COMPLETE (2026-06-30)
Driven by the 2026-06-30 navigation/IA audit. Two root problems: (1) the rich `BottleCardView` is only reachable via a fresh scan; (2) Home and Cellar are passive, overlapping dead-ends (every tile/row is a static `VStack` — 0 navigation transitions in either screen). Each phase: plan → implement → green build + reducer tests + clean sim launch before the next. **All four phases shipped + driven-smoke-verified on the sim; merged to main.**

### UX1 — Universal detail screens (the keystone) ✅
Goal: kill the 5 tap-dead-ends; make the collection browsable.
- [ ] Tap a Cellar inventory row / Home "drink soon" row → push a wine/bottle detail (reuse `BottleCardView`; it already has `init(wine:)` and every row carries the full `Wine`+`Bottle`).
- [ ] BottleCard **"owned" mode**: for a wine already in the cellar, show the bottle's cellar facts (qty/status/drink-window/store) and **suppress "Add to cellar"**; keep "Log a tasting".
- [ ] Tap a Cellar history row / Home recent-tasting row → a **tasting detail** (★/100-pt, full SAT note, photos, who/occasion, wine identity).
- **DoD:** every row in Home + Cellar leads somewhere; no dead-ends.

### UX2 — Edit & delete ✅
Goal: close the creation loop (today records are permanent + uneditable).
- [ ] `PersistenceClient.deleteBottle/deleteTasting`; `BottleFormReducer`/`TastingFormReducer` gain an **edit** init (prefill + update-in-place vs create).
- [ ] Swipe-to-delete on Cellar rows; "Edit" from the detail screen; reload after.
- **DoD:** can edit/delete any bottle or tasting.

### UX3 — Empty-state CTAs + cross-tab nav ✅
Goal: no text-only dead-end empty states; tiles that go somewhere.
- [ ] The 5 empty states become real buttons → jump to the Scan tab (needs programmatic tab switch: child → `MainTabReducer` delegate).
- [ ] Home stat tiles deep-link into a filtered Cellar (e.g. "Wishlist" → Cellar filtered to wishlist).
- **DoD:** empty states + tiles are actionable.

### UX4 — Tab IA restructure ✅
Goal: resolve Home/Cellar overlap; right-size the tab bar.
- [x] **Decision (B): merged Home into the top of Cellar → 3 tabs (Cellar · Scan · Profile).** The Home tab is gone; its dashboard (stat tiles, drink-soon, recent-tastings) is the first List section of the Cellar tab, with tiles re-filtering the inventory in-tab. **Settings → Profile** renamed.
- **DoD:** ✅ tabs each earn their keep; 3-tab shape shipped + smoke-verified.

> Audit verdict: tab *count* isn't the core issue — Home/Cellar redundancy + dead-ends are. UX1 is the highest-leverage single change (turns a data-entry tool into a browsable app). UX4 is the only phase with an open product decision.

## Visual design system — brand "soul" ✅ COMPLETE (2026-06-30)
Driven by the 2026-06-30 delight audit + brand book (`docs/brand-book.md`); phased plan in `docs/ux-soul-roadmap.md`. Goal: replace all-standard iOS chrome with a "Cellar & Candlelight" identity (warm parchment + Bordeaux + candle gold, New York serif for wine names, springs/haptics/symbol-effects, a wine-type mesh hero, drink-window gauge, Swift Charts composition, hero zoom transitions). All seven phases shipped serially (plan → implement → green build + reducer tests → driven sim smoke → commit):
- [x] **D0+D1** — `MenereUI` module (color tokens, serif ramp, motion springs, haptics, branded shimmer) + instant brand wins (`.tint(.wine)`, serif wine names, haptics, branded `ProvenanceBadge`).
- [x] **D2** — bottle card: drink-window `Gauge`, numericText reveal, wax-seal "Tucked into your cellar" celebration, wine-type `MeshGradient` hero.
- [x] **D3** — Cellar as a shelf: rolling stat counters, `.scrollTransition` depth, branded drink-window indicator, Swift Charts "By type" composition tile.
- [x] **D4** — journaling soul: animated candle-gold star rating, save-success haptics, polaroid photos, postcard tasting detail, real stars in history.
- [x] **D5** — hero zoom continuity: cellar/history row → detail `.navigationTransition(.zoom)`; full-screen tasting-photo viewer.
- [x] **D6** — first impressions & edges: Welcome wine-swirl `MeshGradient` + serif wordmark + "Every bottle, remembered.", living scan/empty/error states, Settings copy-code payoff, auth haptics.
- **DoD:** ✅ the app reads like a wine keepsake, not standard chrome. (Open: signed-out screens — Welcome/onboarding/auth — are build-verified but await a live look; on-device pass for haptics/animation feel.)

## Key risks / dependencies
- **APNs key** (M0) is a manual Apple Developer portal step required for Phone auth on device.
- **WSET tasting schema** (M5) is trademarked — get WSET's (usually free) written permission before
  shipping it verbatim in a public build.
- **TTB / Kroger** may need a thin Cloud Function proxy (OAuth / CORS / rate limits).
- **Dedup/identity** is the recurring hard problem — commit to the canonical key early (M1).
