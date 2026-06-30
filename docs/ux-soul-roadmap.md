# Menere — UX "Soul" Roadmap

*Derived from the 2026-06-30 delight audit + brand book v1. Worked serially: each phase
plan → implement → green build + reducer tests → driven sim smoke → commit, before the next.*

**Key enabling fact:** deployment target is **iOS 26**, so `symbolEffect`, `sensoryFeedback`,
`scrollTransition`, `phaseAnimator`/`keyframeAnimator`, `MeshGradient`,
`navigationTransition(.zoom)`/`matchedTransitionSource`, `contentTransition(.numericText())`, `Gauge`,
and Swift Charts are **all in-target with no availability guards**. There is **no existing design
system** to fight — the asset catalog has only the app icon, and `.accentColor` is undefined (system
blue). Greenfield.

**Non-negotiable:** every existing `.accessibilityIdentifier` is preserved on its same logical element
through every restyle, so the driven smoke tests keep working (full list in the audit's risk notes).

---

## Phase D0 — Foundation: the `MenereUI` design-system module ⏳
*Nothing visible ships alone here, but it turns every later phase into one-line modifier application.*
New `MenereUI` target in `MenerePackage`, depended on by every feature:
- **Color tokens** (dynamic light+dark, code-defined `UIColor { traits in }` → `Color` to avoid resource
  plumbing): `Color.wine`, `.oxblood`, `.candleGold`, `.parchment`, `.surface`, `.ink`, `.inkSoft`, and
  the drink-window palette `.drinkNow` / `.hold` / `.past`. Replaces the hardcoded dot colors in
  `CellarRowView.dotColor` + `Dashboard`, and fixes `ProvenanceBadge`'s undefined `.accentColor`.
- **Type ramp** — New York serif helpers: `.wineTitle()`, `.cuvee()` (serif italic + tracking),
  `.producerLabel()` (small-caps tracking), numeric styles.
- **Motion constants** — named springs `.menereSnappy`, `.menereBouncy` replacing scattered `.default`.
- **Haptics** — a thin `sensoryFeedback` convention helper.
- **Branded `Shimmer`** — move the bespoke shimmer here; retint highlight gold/wine (from white 0.45).
- (Later) promote `Card`, `ProvenanceBadge`, `ChipFlow`, a `MenereButtonStyle` into the module.

## Phase D1 — Instant brand wins (cross-cutting, low risk, high impact) ⏳
The "whoa, it feels different" pass, applied app-wide:
- `.tint(.wine)` on the root `TabView` → brands every selected tab + every prominent button at once.
- **Serif wine typography** on producer/cuvée: BottleCard hero, Cellar/History rows, forms, details.
- **Haptics pass:** scan-success, add-to-cellar, save-tasting, star tap, segment + tab change,
  copy-invite-code.
- Parchment background + branded `ProvenanceBadge` (`.user` → wine).

## Phase D2 — The marquee: Bottle Card ⏳
- Serif hero (producer/cuvée); `.contentTransition(.numericText())` on vintage/ABV in the reveal.
- **Drink-window `Gauge`** (living arc: hold/now/past) replacing the text row.
- Branded shimmer reveal driven by `.menereBouncy`; provenance "Verified" `checkmark.seal` `.symbolEffect(.bounce)`.
- **Add-to-cellar celebration:** `keyframeAnimator` wax-seal stamp + `.sensoryFeedback(.success)`.
- Type-derived `MeshGradient` hero behind imageless cards (red/white/rosé).

## Phase D3 — Cellar as a shelf ⏳
- **Rolling stat counters** on dashboard tiles (`.numericText()` + `.snappy`) + symbol bounce on change.
- `.scrollTransition` (scale+fade) on dashboard rows + inventory/history rows → shelf depth.
- Window dots → mini gauge consistent with the card; segment-swap haptic + `.snappy` content swap.
- (Optional) a Swift Charts cellar-composition tile (by type/region).

## Phase D4 — Journaling soul ⏳
- **Animated star rating** (TastingForm): `.symbolEffect(.bounce)` + `.bouncy` fill + selection haptic +
  `contentTransition(.symbolEffect(.replace))` on star↔star.fill. Save-success haptic.
- Polaroid photo treatment; `AsyncImage` fade-in.
- Tasting detail as a "postcard"; real star symbols in History rows.

## Phase D5 — Hero zoom continuity ⏳
*Done after the card + cellar are styled (it's the one cross-module change).*
- `.matchedTransitionSource(id:namespace:)` on cellar rows + scan source → `.navigationTransition(.zoom)`
  into the bottle card, so the card grows out of the tap. Thread one `Namespace` source→destination.
- Tasting-detail photo → full-screen zoom viewer.

## Phase D6 — First impressions & edges ⏳
- **Welcome:** animated `MeshGradient` "wine swirl" + serif wordmark + a real tagline (kill
  "Your tagline here"); `phaseAnimator` entrance.
- Onboarding success `.symbolEffect(.bounce)` + success haptic; consider `TipKit` "scan your first bottle."
- Scan idle viewfinder `.pulse`; identifying "scanning sweep"; failed-state `ContentUnavailableView` + wiggle.
- Empty/error symbols `.pulse`/`.bounce`; Settings copy-code `symbolEffect(.replace)`→checkmark + haptic.
- Auth polish (error wiggle + haptics); carry the serif wordmark through.

---

## Ranked quick reference (delight-per-effort, from the audit)
1. Brand accent + `.tint()` at TabView (S, foundational)
2. Serif wine typography app-wide (S–M)
3. `sensoryFeedback` haptics pass (S, cross-cutting)
4. Animated star rating in TastingForm (S)
5. Rolling dashboard stat counters (S)
6. `.scrollTransition` on rows (S)
7. Drink-window `Gauge` on the card (M)
8. Zoom hero transition scan/cellar → card (M)

## Open brand questions (iterate on real pixels)
- Wine red: warmer/earthier vs. more saturated/jewel-toned.
- Serif extent: wine names only, or headlines too.
- Custom app-icon mark (wax-seal / glass on parchment) — the one item needing external design effort.
