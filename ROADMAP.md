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

> **Follow-up — M2.5 (iOS 27 multimodal engine):** behind the same `IdentifyClient` seam, add
> `MultimodalFMIdentifier` (`#available(iOS 27)`) that feeds the label **image** to Foundation Models →
> `@Generable` in one pass (handles brand-vs-winery, multi-column, obscure varietals the iOS 26
> deterministic rules can't). Deployment target stays iOS 26. Blocked on the iOS 27 toolchain/runtime.
> Full design + sourced toolchain comparison in `docs/identify-engine.md`.

### M3 — Resolve & Enrich (free sources)
Goal: turn a candidate into a rich, cached `Wine`.
- [ ] `CatalogClient`: look up canonical key in shared `/wines`; cache hit → instant return
- [ ] `EnrichmentClient` (on miss): fan out to **Open Food Facts** (barcode), **TTB COLA** (US label
      image + class/type), **Wikidata** (grape/region taxonomy); optional Foundation Models for gaps
- [ ] Merge with per-field **provenance + confidence**; authoritative sources override AI; never fabricate
      verifiable facts (scores/ABV)
- [ ] Write resolved `Wine` back to shared catalog
- **DoD:** scan → enriched `Wine` with provenance, persisted to the shared catalog.

### M4 — Present (the bottle card)
Goal: the moment that makes someone point their phone at a shelf.
- [ ] `BottleCardFeature`: progressive/streaming card (fast fields first, authoritative fill-in)
- [ ] Provenance badges (verified vs AI estimate); label image; region/grape/style/drink-window
- **DoD:** a beautiful bottle card rendered from a live scan.

### M5 — Journal (buy/drink) — the retention core
Goal: best-in-class logging.
- [ ] From the card: **Add to cellar** (`Bottle`: price, qty, store, location, drink-from/by)
- [ ] **Log a tasting** (`Tasting`: ★ + optional 100-pt, free text, optional WSET-structured note,
      photos, who/occasion)
- **DoD:** can add a bottle and log a tasting; both persist per-user and link to the `Wine`.

### M6 — Recall & Cellar
Goal: "what do we have?" and "what did we love?"
- [ ] `CellarFeature`: inventory list, filter/sort, drink-window surfacing
- [ ] History/recall: search by rating ("4★+"), region, grape, date; Home becomes a dashboard
- **DoD:** browse & search the full cellar + tasting history fluidly.

### M7 — Household sharing
Goal: both of you on one shared cellar/history.
- [ ] Shared "household" space in Firestore; invite/join; shared bottles + tastings
- **DoD:** both accounts read/contribute to the same cellar.

### M8 — Polish + TestFlight
- [ ] Empty/error/offline states, app icon, scan onboarding, perf pass
- **DoD:** installable via TestFlight for the two of us.

---

## Post-MVP (layer in once it earns it)
- **Higher-fidelity identification:** Claude vision LLM for label reading (behind the IdentifyClient
  abstraction), label-image-match recognition service.
- **Recommendations:** content-based "you'd like this" (works without a user base; no cold-start).
- **Richer catalog:** paid partner API (InVintory / Wine-Searcher) if we go public.
- **Pricing/where-to-buy:** Kroger / LCBO integrations.

## Key risks / dependencies
- **APNs key** (M0) is a manual Apple Developer portal step required for Phone auth on device.
- **WSET tasting schema** (M5) is trademarked — get WSET's (usually free) written permission before
  shipping it verbatim in a public build.
- **TTB / Kroger** may need a thin Cloud Function proxy (OAuth / CORS / rate limits).
- **Dedup/identity** is the recurring hard problem — commit to the canonical key early (M1).
