# Menere — Brand Book

*v1 — 2026-06-30. A living document. Direction first; we iterate.*

---

## 1. The idea

**Menere** — from Latin *manēre*, "to remain, to abide, to dwell."

A wine lives twice: once in the glass, once in memory. Menere is the app for **the bottle in your
hand** — point your phone at it, fall for it, and let it *abide* in your cellar and your memory.

It is not a database. It's a keepsake — the feeling of a worn leather cellar book and a candlelit
table, rebuilt as a fast, modern iOS tool. Old-world soul, modern hand.

## 2. Brand pillars

1. **The bottle in your hand.** Tactile, present, immediate. Every screen centers on one real bottle.
2. **Abide / memory.** A cellar is a memory palace; a tasting note is a postcard from a night.
3. **Warm ritual, unhurried.** Wine is slow and shared. The app can be quick, but never cold or clinical.
4. **Knowledge without snobbery.** A sommelier friend across the table, not a gatekeeper.

## 3. Voice & tone

Warm, fluent, a little romantic; plainspoken; never stuffy or jargon-stuffed. Confident and generous.

| Moment | Instead of (system) | Menere voice |
|---|---|---|
| Empty cellar | "No items" | "Your cellar is waiting." → *Scan your first bottle* |
| Saved a bottle | "Success!" | "Tucked into your cellar." |
| Saved a tasting | "Saved" | "Noted." |
| Drink window | (raw dates) | "Drink soon" · "In its window" · "Hold a while" · "Past its best" |
| Error | "Error 400" | "We lost the thread — try again." |

Avoid: exclamation spam, "items," "No results found," raw error codes, ALL-CAPS shouting (one
exception: small-caps producer labels as a *type* treatment, not as tone).

## 4. Color — "Cellar & Candlelight"

Move off pure iOS system black/white. A **warm-neutral foundation**, **wine accents**, a
**candle-gold highlight**. Every token ships a light + dark variant in the asset catalog.

### Brand
| Token | Light | Role |
|---|---|---|
| **Wine / Bordeaux** | `#5A1E2B` | Primary brand, primary actions, app accent |
| **Oxblood** | `#7B2D3A` | Secondary red, pressed/active states |
| **Candle Gold** | `#C8A24B` | Accent, "verified," sparkle, highlights |

### Neutrals (replace system background/label)
| Token | Light | Dark | Role |
|---|---|---|---|
| **Parchment** | `#F5EFE6` | `#1A1614` | App background |
| **Surface** | `#FFFFFF` | `#241F1C` | Cards, raised surfaces |
| **Ink** | `#2A2422` | `#F2EBE2` | Primary text |
| **Ink-soft** | `#6B5F58` | `#B7AAA0` | Secondary text |

### Functional — the drink window (semantic, color-coded everywhere)
| Token | Light | Meaning |
|---|---|---|
| **Drink Now / Sage** | `#6E8B6A` | In its window |
| **Hold / Slate-blue** | `#5C6F86` | Hold a while |
| **Past / Faded Rose** | `#A98C8C` | Past its best |

> Provenance badges keep their semantic meaning but adopt brand hues: **Verified** = Candle Gold,
> **AI estimate** = Slate-blue, **Scanned** = Ink-soft, **You** = Bordeaux.

## 5. Typography — serif soul, sans clarity

- **Display / wine names / numerals — New York** (the system serif): `.font(.system(.title, design: .serif))`.
  Free, native, elegant; evokes wine lists and labels. Big and confident for producer + cuvée.
- **UI / body / controls — SF Pro** (system): clean, legible, the native hand for everything functional.
- **Numerals (stats, ratings, prices) — `.monospacedDigit()` + `.contentTransition(.numericText())`** so
  they *roll* when they change.
- Cuvée names in **serif italic**; producer in **small caps** tracking. Generous line spacing.

## 6. Motion — "pour, settle, remember"

Three principles, applied with restraint — **one signature moment per screen, not confetti everywhere.**

1. **Pour & settle.** Content arrives like wine settling into a glass — springs (`.bouncy`, `.snappy`),
   never linear easing. Enrichment rows pour in.
2. **Hero continuity.** The bottle you tap is the bottle you land on — `matchedTransitionSource` +
   `.navigationTransition(.zoom)` from scan-card and cellar row → detail.
3. **Living facts.** Numbers roll (`.numericText()`), symbols breathe (`.symbolEffect`), the drink
   window reads as a **gauge**, not a label.

**Earned haptics** (`.sensoryFeedback`): a soft *success* when a bottle is cellared or a tasting saved;
a *selection* tick on segment + star-rating changes; an *impact* on scan-success.

## 7. Materials & texture

- Subtle **parchment grain** on key surfaces; `.ultraThinMaterial` for floating chrome (toolbars, the
  scan-again control we already moved to the nav bar).
- **Wine-in-glass gradients** (Bordeaux → Oxblood) on the bottle-card hero and splash; `MeshGradient`
  (iOS 18) for an ambient backdrop behind the card.
- Soft, large **continuous corner radii**; warm, low shadows (never the default hard gray).

## 8. Iconography & marks

- SF Symbols, custom-rendered (hierarchical / palette in brand colors).
- Motif candidates: a simple **wine glass**, a **cellar arch**, a **bottle silhouette**, a **wax-seal
  dot** for "verified / abide."
- App accent color = Bordeaux. App icon explores the wax-seal / glass motif on parchment.

## 9. Signature moments (where the soul shows)

1. **Scan → reveal.** The captured label settles into the bottle card; enrichment rows pour in (we
   already shimmer — make the shimmer *brand*: gold sweep on parchment).
2. **Add to cellar.** A wax-seal stamp + success haptic — "Tucked into your cellar."
3. **Drink-window gauge.** A living, color-coded arc instead of a text line.
4. **Cellar as a shelf.** Rows feel like bottles on a shelf (`.scrollTransition` scale/fade); hero-zoom
   into detail.
5. **Tasting as memory.** The note reads like a postcard; photos as polaroids; stars that fill with a
   spring.
6. **Stats that breathe.** Dashboard counters roll with `.numericText()`; the "drink soon" tile pulses.

## 10. How this gets built (foundation first)

Before per-screen polish, stand up a shared **`MenereUI` / DesignSystem** module:

- **Color tokens** — asset-catalog color sets (light+dark) for every token above, surfaced as
  `Color.wine`, `Color.candleGold`, `Color.parchment`, `Color.drinkNow`, etc.
- **Type ramp** — `Font` helpers: `.menereDisplay`, `.menereTitle` (New York serif), `.menereBody` (SF),
  numeric styles.
- **Components** — `WineCard`, `ProvenanceBadge`, `DrinkWindowGauge`, brand `ButtonStyle`s, `StatTile`,
  `SealStamp`.
- **Motion + haptics** — shared spring constants and a `Haptics` helper so feedback is consistent.
- **Accessibility** — all existing accessibility identifiers (`home-stat-*`, `cellar-empty`,
  `edit-bottle-button`, …) are preserved through every refactor so the driven smoke tests keep working.

Then the per-screen audit (separate doc/plan) is applied phase by phase — **plan → implement → green
build + reducer tests → driven sim smoke** before each next phase, same discipline as the UX series.

---

*Open questions to iterate on:* exact palette tuning (warmer vs. more saturated wine), how far to push
serif (wine names only, or headlines too), whether to commission a custom app-icon mark, and how
much texture (grain) reads as "premium" vs. "busy" on small screens.
