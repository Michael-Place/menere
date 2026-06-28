# Identify Engine — design & toolchain (iOS 26 / iOS 27)

How Menere turns a photo of a bottle into a structured `WineCandidate` (producer, cuvée, vintage,
region, grapes). This is the engine behind `IdentifyClient` (M2 = capture & identify). On-device, free.

## The problem we hit (M2 v1)

v1 pipeline: `VNRecognizeTextRequest` (flat OCR, **layout discarded**) → join lines → ask the on-device
**text** Foundation Model to *both parse and assign fields* via a `@Generable` struct.

That last step is unreliable. A text-only model with no spatial/typographic cues can't tell the large
brand word from the small winery name, so field assignment is near-random and **nondeterministic
run-to-run**. Observed on a real bottle (Emiliana "Natura" Carmenère, Chile, V.2023):
- producer returned `NATURA` one run, `EMILIANA` the next, `Unknown` a third;
- every label line ("ORGANIC% VINEYARDS", "CHILE / V.2023", "SUSTAINABLY FARMED", "NATURA", "EMILIANA")
  dumped into `grapes[]`;
- vintage left empty even though "V.2023" was read.

Root cause: **flat OCR loses the layout the model needs, and a small text LLM is the wrong tool for
field assignment.** The fix is to give the model *structure* (iOS 26) or the *image itself* (iOS 27) —
not to pile deterministic guards on a bad foundation.

## Decision

A **version-forked engine** behind one internal protocol, selected at runtime, deployment target stays
**iOS 26.0**, iOS 27 paths `#available`-gated. `IdentifyClient`'s public surface is unchanged, so
`ScanFeature` doesn't change.

```swift
protocol LabelIdentifier: Sendable {
    func identify(_ imageData: Data) async throws -> WineCandidate
}
// IdentifyClient.liveValue:
//   if #available(iOS 27, *) { MultimodalFMIdentifier() } else { VisionDocumentIdentifier() }
```

### iOS 26 path — `VisionDocumentIdentifier` (build now)

Replace flat OCR with Vision **`RecognizeDocumentsRequest` → `DocumentObservation`** (on-device, 26
languages, WWDC25). It returns a hierarchy, not a flat blob:
`document.text` (`.transcript` / `.lines` / `.paragraphs` in reading order / `.words`), `document.tables`,
`document.lists`, `document.barcodes`, `.detectedData` (DataDetection: currency, measurements, URLs…),
and a **bounding region** per container (position + size ⇒ prominence).

Use that structure for **deterministic, layout-aware field assignment**:
- **vintage** = line/word matching a year regex (1900–2035), incl. the "V.2023" form;
- **grapes** = lines matching a grape-variety vocabulary;
- **producer / cuvée** = use text-block prominence (largest region ≈ brand/cuvée; a line adjacent to
  "winery/vineyards/estate/bodega/château" ≈ producer); reserve the LLM for *only* the narrow
  producer-vs-cuvée disambiguation, fed the top few prominent blocks — never the whole text dump.
- Keep the **deterministic grounding guards** (grape vocabulary, year-not-in-region, ≥2-char match).
  On iOS 26 these are load-bearing.

### iOS 27 path — `MultimodalFMIdentifier` (next pass)

Feed the **label image** directly to Foundation Models as an `Attachment` in the prompt and get
`@Generable` structured output in **one pass** — the model sees typography/size/color/position and
distinguishes brand from winery natively (the exact failure above). Optionally attach the built-in
`OCRTool` + `BarcodeReaderTool`. Escalate hard cases to `PrivateCloudComputeLanguageModel` (keyless,
free, private, 32K). Keep grounding guards **light** (defense-in-depth; far less load-bearing).
Requires AFM 3 Core Advanced (iPhone 15 Pro+); needs an iOS 27 runtime to test (none available yet).

## Toolchain reference (sourced)

**iOS 26 (now, on-device, free)**
- Vision `RecognizeDocumentsRequest` / `DocumentObservation` — structured doc understanding.
  [WWDC25 §272](https://developer.apple.com/videos/play/wwdc2025/272/),
  [docs](https://developer.apple.com/documentation/vision/recognizedocumentsrequest)
- Vision `RecognizeTextRequest` / `VNRecognizeTextRequest` — flat OCR (fallback/grounding only).
- VisionKit `DataScannerViewController` — live text + barcode capture.
- Foundation Models — text `@Generable`/`@Guide` guided generation, tool calling. Unreliable at field
  assignment; use narrowly.

**iOS 27 (Xcode 27 beta; ships fall 2026)**
- Foundation Models **multimodal** — image `Attachment` (UIImage/CGImage/CIImage/CVPixelBuffer/URL) +
  guided generation in one call. AFM 3 Core Advanced (~20B sparse), iPhone 15 Pro+.
  [WWDC26 §241](https://developer.apple.com/videos/play/wwdc2026/241/),
  [Blake Crosley](https://blakecrosley.com/blog/foundation-models-image-input-ios-27)
- Built-in **`OCRTool`** (→ String) + **`BarcodeReaderTool`** (→ `[Barcode]` content+symbology), on-device,
  `LanguageModelSession(tools: [OCRTool(), BarcodeReaderTool()])`.
  [Blake Crosley](https://blakecrosley.com/blog/foundation-models-tool-calling-ios-27)
- **`LanguageModel` provider protocol** — `SystemLanguageModel`, `PrivateCloudComputeLanguageModel`
  (keyless/free/private/32K), `CoreAILanguageModel`, `MLXLanguageModel`, + first-party Anthropic/Google
  SPM packages. Same `LanguageModelSession(model:)`. This is our roadmap "provider abstraction" and lets
  some M3 enrichment run on PCC instead of a Cloud Functions proxy.
  [pdpspectra](https://pdpspectra.com/blog/apple-foundation-models-languagemodel-protocol-2026/)
- **`Core AI`** — run custom/open VLMs (3B–70B, MLX) on Apple Silicon, `.aimodel`, no server cost.
  [WWDC26 §326](https://developer.apple.com/videos/play/wwdc2026/326/),
  [InfoQ](https://www.infoq.com/news/2026/06/apple-core-ai-wwdc/)
- **`Evaluations`** framework — measure extraction accuracy (hill-climbing); use to A/B the two engines.

**Barcode → wine reality:** no free, authoritative barcode→wine DB. Open Food Facts is keyless/free but
wine coverage is thin, and wine back-label barcodes often encode the distributor/GTIN, not producer or
vintage. **Treat barcode as a secondary hint; the label image is the primary identity path.**

## Confidence / to verify in SDK
- High: RecognizeDocumentsRequest structure & on-device; OCRTool/BarcodeReaderTool config+returns;
  LanguageModel provider list; multimodal image-attachment capability.
- Verify in SDK: exact `Attachment` initializer; exact min-OS labels; AFM-3 device list.
- Flagged: one secondary source garbled Core AI's version ("iOS 20" — it's iOS 27). No iOS 27 runtime
  available here yet (compile/gate only).

## Confirmed API (spiked on the iOS 26.5 SDK against a real label)
```swift
let request = RecognizeDocumentsRequest()
let observations = try await request.perform(on: cgImage, orientation: cgOrientation) // [DocumentObservation]
guard let doc = observations.first?.document else { … }
for line in doc.text.lines {                 // DocumentObservation.Container.Text.lines
    let s = line.transcript                   // String
    let box = line.boundingRegion.boundingBox // .height (≈ prominence), .width, .origin.y
}
let full = doc.text.transcript                // String
let data = doc.text.detectedData              // DataDetection matches
for b in doc.barcodes { let p = b.payloadString } // Optional<String>
```
On the Natura label, line `height` ranks: NATURA 0.042 > MADE-WITH-ORGANIC-GRAPES 0.025 > EMILIANA 0.023
> CARMENERE 0.021 ≈ SUSTAINABLY-FARMED 0.021 > CHILE/V.2023 0.019 > ORGANIC-VINEYARDS 0.018. Prominence +
keyword adjacency (EMILIANA next to "…VINEYARDS") cleanly separates cuvée (NATURA) from producer (EMILIANA).
(`DocumentObservation.Container.Text` has no `.paragraphs`; use `.lines`.)

## Status
- [x] Research + decision documented (this file).
- [x] `RecognizeDocumentsRequest` API confirmed via SDK spike (above).
- [x] **iOS 26 re-architecture shipped** — `VisionDocumentIdentifier`: `RecognizeDocumentsRequest` +
      deterministic prominence/keyword field assignment, **no LLM in the identify path**. Producer/cuvée
      disambiguation uses two rules learned from real labels: (1) a non-marketing **winery-keyword line
      wins over a place match** (so "Château Margaux" isn't consumed as just the appellation); (2)
      **fuzzy (edit-distance ≤1) winery-keyword matching** so OCR slips like "VINEYARDS"→"VINEYAROS" still
      anchor the producer. Verified correct + reproducible on Château Margaux (sample) and a real Emiliana
      "Natura" Carmenère (producer=Emiliana, cuvée=Natura, vintage=2023, region=Chile, grape=Carmenère).
- [ ] **iOS 27 `MultimodalFMIdentifier` behind `#available` (next pass)** — blocked on the iOS 27
      toolchain/runtime (macOS update in progress). Known iOS 26 limits it should fix: producer/cuvée with
      no winery keyword; multi-column / rotated layouts; varietal-named cuvées; vocab gaps (obscure
      regions/grapes silently dropped).
