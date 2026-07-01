import Dependencies
import DependenciesMacros
import FirebaseFunctions
// Weak-linked: the iOS 27 multimodal path references FoundationModels symbols newer than our iOS 26
// deployment target (e.g. the Generable conformance witness for `promptRepresentation`). The macro
// emits those references eagerly, so without weak linking the app fails to launch on iOS 26 with a
// dyld "Symbol not found". Weak linking lets the missing symbols resolve to null at launch; the
// `#available(iOS 27)` guards ensure we never actually call them on iOS 26.
@_weakLinked import FoundationModels
import OSLog
import UIKit
import Vision
import WineDomain

/// Diagnostics for which identify engine ran and how the multimodal model behaved. Capture with:
/// `xcrun simctl spawn <udid> log stream --predicate 'subsystem == "com.copoche.menere"'`.
private let identifyLog = Logger(subsystem: "com.copoche.menere", category: "identify")

/// Errors thrown by the identify pipeline.
public enum IdentifyError: Error, Equatable, Sendable {
    /// The supplied image data could not be decoded into a `CGImage`.
    case imageDecodingFailed
}

/// On-device bottle identification: a layout-aware, deterministic engine built on Vision's
/// `RecognizeDocumentsRequest` (structured document text with per-line bounding boxes). There is
/// **no LLM** in this path — field assignment is driven by line prominence (font height) plus small
/// curated vocabularies, so results are reproducible. No network / catalog resolution happens here —
/// that's M3. Modeled as a `@DependencyClient` so TCA features inject it and tests can swap it.
@DependencyClient
public struct IdentifyClient: Sendable {
    /// Run Vision document recognition on the image, returning recognized lines top-to-bottom.
    /// Falls back to flat `VNRecognizeText` if document recognition fails.
    public var recognizeText: @Sendable (_ imageData: Data) async throws -> [String]
    /// Structure raw OCR lines (strings only, no layout) into a `WineCandidate` (source `.label`).
    /// This text-only entry point is deterministic — see `structure` in `liveValue`.
    public var structure: @Sendable (_ lines: [String]) async throws -> WineCandidate
    /// Cloud-first identify: calls the deployed `identifyLabel` Claude-vision Cloud Function with the
    /// label image and maps the structured response into a `WineCandidate`. On ANY error (offline,
    /// function error, decode failure) it falls back to the version-gated on-device engine (iOS 27
    /// multimodal FM, else the deterministic iOS 26 `VisionDocumentIdentifier`).
    public var identify: @Sendable (_ imageData: Data) async throws -> WineCandidate
    /// Fast path for a scanned barcode. M2 does no catalog lookup, so this just records the payload.
    /// `symbology` is currently unused but documents the scan's intent.
    public var identifyBarcode: @Sendable (_ payload: String, _ symbology: String?) -> WineCandidate = { payload, _ in
        WineCandidate(barcode: payload, source: .barcode)
    }
}

extension IdentifyClient: DependencyKey {
    public static let liveValue: IdentifyClient = {
        IdentifyClient(
            recognizeText: { imageData in
                let (cgImage, orientation) = try decodedImage(from: imageData)
                // Prefer the structured document transcript; fall back to flat OCR so we never hard-fail.
                if let document = try? await recognizeDocument(cgImage, orientation) {
                    let docLines = document.text.lines
                        .map { $0.transcript.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { !$0.isEmpty }
                    if !docLines.isEmpty { return docLines }
                }
                return try recognizeFlatLines(cgImage, orientation)
            },
            structure: { lines in
                // `structure` only receives strings (no per-line layout / font prominence), so it can't
                // run the prominence-based producer/cuvée heuristic the image path uses. We keep it fully
                // deterministic via `heuristicStructure` (the old Foundation Models path is intentionally
                // gone — FM was unreliable at field assignment, which is the whole reason for this
                // re-architecture). The richer layout-aware classification lives in the `identify` path.
                heuristicStructure(lines)
            },
            identify: { imageData in
                // Cloud-first: the deployed Claude-vision `identifyLabel` Cloud Function is the primary
                // path (best field assignment). On ANY failure (offline, function error, decode
                // failure) fall back to the version-gated on-device engine so scanning still works:
                // iOS 27 feeds the image to a multimodal Foundation Model; iOS 26 uses the
                // deterministic document-layout engine. Deployment target stays iOS 26.
                do {
                    return try await CloudVisionIdentifier().identify(imageData)
                } catch {
                    identifyLog.notice("cloud identify failed (\(String(describing: error), privacy: .public)) → on-device fallback")
                    if #available(iOS 27.0, *) {
                        return try await MultimodalFMIdentifier().identify(imageData)
                    }
                    return try await VisionDocumentIdentifier().identify(imageData)
                }
            },
            identifyBarcode: { payload, _ in
                WineCandidate(barcode: payload, confidence: 0.5, source: .barcode)
            }
        )
    }()
}

public extension DependencyValues {
    var identify: IdentifyClient {
        get { self[IdentifyClient.self] }
        set { self[IdentifyClient.self] = newValue }
    }
}

// MARK: - Vision plumbing

/// Decode image data into a `CGImage` plus the orientation Vision should apply.
///
/// `UIImage.cgImage` is the RAW pixel buffer with the EXIF/`imageOrientation` dropped — a photo of a
/// bottle lying down (or any portrait camera shot) arrives sideways. We pass the orientation through
/// so Vision rotates internally; without this, recognition reads sideways text and mostly fails.
private func decodedImage(from imageData: Data) throws -> (cgImage: CGImage, orientation: CGImagePropertyOrientation) {
    guard let uiImage = UIImage(data: imageData), let cgImage = uiImage.cgImage else {
        throw IdentifyError.imageDecodingFailed
    }
    return (cgImage, CGImagePropertyOrientation(uiImage.imageOrientation))
}

/// Run `RecognizeDocumentsRequest` and return the top document container (structured text + barcodes
/// with per-line bounding boxes), or `nil` if no document was found.
private func recognizeDocument(
    _ cgImage: CGImage,
    _ orientation: CGImagePropertyOrientation
) async throws -> DocumentObservation.Container? {
    let request = RecognizeDocumentsRequest()
    let observations = try await request.perform(on: cgImage, orientation: orientation)
    return observations.first?.document
}

/// Legacy flat OCR (`VNRecognizeText`) kept purely as the fallback text source so the engine never
/// hard-fails when document recognition is unavailable or returns nothing.
private func recognizeFlatLines(
    _ cgImage: CGImage,
    _ orientation: CGImagePropertyOrientation
) throws -> [String] {
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = true
    let handler = VNImageRequestHandler(cgImage: cgImage, orientation: orientation, options: [:])
    try handler.perform([request])

    let observations = request.results ?? []
    // Vision's coordinate origin is bottom-left, so larger maxY = higher on the label.
    return observations
        .sorted { $0.boundingBox.maxY > $1.boundingBox.maxY }
        .compactMap { $0.topCandidates(1).first?.string }
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
}

private extension CGImagePropertyOrientation {
    /// Map a `UIImage.Orientation` to the matching `CGImagePropertyOrientation` so Vision can apply it.
    init(_ orientation: UIImage.Orientation) {
        switch orientation {
        case .up: self = .up
        case .upMirrored: self = .upMirrored
        case .down: self = .down
        case .downMirrored: self = .downMirrored
        case .left: self = .left
        case .leftMirrored: self = .leftMirrored
        case .right: self = .right
        case .rightMirrored: self = .rightMirrored
        @unknown default: self = .up
        }
    }
}

// MARK: - Layout-aware deterministic engine

/// Abstraction over "image data → a structured `WineCandidate`". Lets the identify path be swapped
/// (e.g. for a future iOS 27 multimodal engine) without touching the `@DependencyClient` surface.
protocol LabelIdentifier: Sendable {
    func identify(_ imageData: Data) async throws -> WineCandidate
}

/// Deterministic, LLM-free identifier built on `RecognizeDocumentsRequest`.
///
/// Strategy: structured document recognition gives us, per line, the transcript **and** a normalized
/// bounding box whose `height` tracks font prominence. Wine labels are laid out by prominence — the
/// stylized cuvée name is the biggest text, the producer sits next to a winery keyword
/// ("…VINEYARDS", "BODEGA…"), vintage/grape/origin are small print. We classify each line into a
/// category (vintage / grape / place / marketing) and treat whatever's left as a *name candidate*,
/// then pick producer & cuvée from those using prominence + adjacency to a winery keyword.
///
/// Everything we emit is grounded: it is copied from text that literally appears on the label.
struct VisionDocumentIdentifier: LabelIdentifier {
    /// One recognized line: its transcript plus prominence (`height`) and vertical position (`y`,
    /// normalized, origin bottom-left) used for adjacency.
    private struct Line: Sendable, Equatable {
        let text: String
        let height: Double
        let y: Double
    }

    func identify(_ imageData: Data) async throws -> WineCandidate {
        identifyLog.notice("engine=deterministic(RecognizeDocumentsRequest)")
        let (cgImage, orientation) = try decodedImage(from: imageData)

        // Primary path: structured document recognition with per-line layout.
        if let document = try? await recognizeDocument(cgImage, orientation) {
            let lines: [Line] = document.text.lines.compactMap { observation in
                let text = observation.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return nil }
                let box = observation.boundingRegion.boundingBox
                return Line(text: text, height: Double(box.height), y: Double(box.origin.y))
            }
            if !lines.isEmpty {
                return Self.assign(lines)
            }
        }

        // Fallback: flat OCR + heuristic parser so identify never hard-fails.
        let flat = (try? recognizeFlatLines(cgImage, orientation)) ?? []
        return heuristicStructure(flat)
    }

    /// Deterministic field assignment over the recognized lines.
    private static func assign(_ lines: [Line]) -> WineCandidate {
        // vintage: first 4-digit year in 1900...2035 in any line (handles "CHILE / V.2023" → 2023).
        let vintage = lines.lazy.compactMap { firstYear(in: $0.text) }.first

        // grapes: tokens/spans across every line that match the known-varietal vocabulary.
        let grapes = grapeVarieties(in: lines.map(\.text))

        // country / region: first line whose text contains a curated place name. Canonical display
        // (so "USA" → "United States"); never a value containing a year.
        let country = lines.lazy.compactMap { matchPlace($0.text, knownWineCountries) }.first
        let region = lines.lazy.compactMap { matchPlace($0.text, knownWineRegions) }.first

        // name candidates: lines NOT already explained as vintage / grape / place / marketing.
        // A non-marketing line carrying a winery keyword is ALWAYS a producer candidate even if it also
        // names a place — e.g. "CHÂTEAU MARGAUX" is both the producer and the appellation, and must not
        // be consumed purely as a region.
        let nameCandidates = lines.filter { line in
            if isMarketing(line.text) { return false }
            if hasWineryKeyword(line.text) { return true }
            return !hasYear(line.text)
                && matchPlace(line.text, knownWineCountries) == nil
                && matchPlace(line.text, knownWineRegions) == nil
                && !lineHasGrape(line.text)
        }

        // producer: (a) a name candidate that itself carries a winery keyword; else (b) the name
        // candidate nearest (by y) to ANY line carrying a winery keyword (e.g. "EMILIANA" next to
        // "ORGANIC VINEYARDS"); else (c) the most prominent name candidate.
        let producer: Line? = {
            if let direct = nameCandidates.first(where: { hasWineryKeyword($0.text) }) {
                return direct
            }
            if let keywordLine = lines.first(where: { hasWineryKeyword($0.text) }) {
                return nameCandidates.min { abs($0.y - keywordLine.y) < abs($1.y - keywordLine.y) }
            }
            return nameCandidates.max { $0.height < $1.height }
        }()

        // cuvée: the most prominent name candidate that is NOT the producer line (nil if none distinct).
        let cuvee: Line? = nameCandidates
            .filter { line in producer.map { line != $0 } ?? true }
            .max { $0.height < $1.height }

        // Grounding guard: place fields must never carry a 4-digit year. (Canonical vocab values
        // never do, but keep the guard so the contract is explicit.)
        let groundedCountry = sansYear(country)
        let groundedRegion = sansYear(region)
        let regionValue: Region? = (groundedCountry != nil || groundedRegion != nil)
            ? Region(country: groundedCountry, region: groundedRegion)
            : nil

        return WineCandidate(
            producer: producer?.text,
            name: cuvee?.text,
            vintage: vintage,
            region: regionValue,
            grapes: grapes,
            rawText: lines.map(\.text),
            // Deterministic engine: not the old 0.8 "Foundation Models" tier.
            confidence: producer != nil ? 0.7 : 0.5,
            source: .label
        )
    }
}

// MARK: - iOS 27 multimodal engine

/// Structured wine identity the multimodal model fills in directly from the label image.
/// Gated to iOS 27: the `@Generable` macro (built against the iOS 27 SDK) references iOS 27-only
/// `Generable` symbols, so leaving this ungated hard-links them and crashes at launch on iOS 26.
@available(iOS 27.0, *)
@Generable
struct WineLabelDraft {
    @Guide(description: "The producer — the winery, estate, or company that made the wine, as printed on the label. This is NOT the large stylized brand/range name.")
    var producer: String?
    @Guide(description: "The cuvée / bottling / brand name (often the largest, most stylized text), if distinct from the producer.")
    var cuvee: String?
    @Guide(description: "The vintage year printed on the label, e.g. 2023. Nil if non-vintage.")
    var vintage: Int?
    @Guide(description: "Country of origin, only if printed on the label.")
    var country: String?
    @Guide(description: "Wine region or appellation, only if printed on the label.")
    var region: String?
    @Guide(description: "Grape varieties, only if printed on the label. Empty if none are printed.")
    var grapes: [String]
}

/// iOS 27+ identifier: feeds the label **image** straight to a multimodal Foundation Model and gets a
/// `@Generable` candidate in one pass. Because the model sees typography and layout, it distinguishes
/// the producer (winery) from the large brand/cuvée wordmark natively — the field-assignment problem
/// the deterministic iOS 26 engine can only approximate. We still ground every field against the
/// label's own OCR text so the model can't fabricate, and fall back to `VisionDocumentIdentifier`
/// whenever the on-device model is unavailable (no Apple Intelligence / older silicon) or the call
/// fails. Requires the iOS 27 SDK (image `Attachment` API).
@available(iOS 27.0, *)
struct MultimodalFMIdentifier: LabelIdentifier {
    private static let instructions = """
    You identify a wine from a photo of its bottle label. Read ONLY what is printed on the label — do \
    not use outside or world knowledge. Use the label's layout and typography to tell the producer \
    (the winery/estate, often smaller text near words like "winery" or "vineyards") apart from the \
    cuvée/brand name (often the largest, most stylized text). Leave any field nil if it is not printed \
    on the label. Never guess or invent values.
    """

    func identify(_ imageData: Data) async throws -> WineCandidate {
        let (cgImage, orientation) = try decodedImage(from: imageData)

        let model = SystemLanguageModel.default
        identifyLog.notice("engine=multimodal(iOS27) FM.availability=\(String(describing: model.availability), privacy: .public)")
        guard case .available = model.availability else {
            // No on-device model here (e.g. Apple Intelligence off) — use the deterministic engine.
            identifyLog.notice("multimodal: FM unavailable → deterministic fallback")
            return try await VisionDocumentIdentifier().identify(imageData)
        }

        do {
            let session = LanguageModelSession(instructions: Self.instructions)
            let response = try await session.respond(generating: WineLabelDraft.self) {
                "Identify the wine from this bottle label."
                Attachment(cgImage, orientation: orientation)
            }
            let candidate = await Self.candidate(from: response.content, cgImage: cgImage, orientation: orientation)
            identifyLog.notice("multimodal: succeeded producer=\(candidate.producer ?? "nil", privacy: .public) cuvee=\(candidate.name ?? "nil", privacy: .public) vintage=\(candidate.vintage.map(String.init) ?? "nil", privacy: .public)")
            return candidate
        } catch {
            // Any model error (unsupported image input, resource limits, refusal) → deterministic engine.
            identifyLog.error("multimodal: failed (\(String(describing: error), privacy: .public)) → deterministic fallback")
            return try await VisionDocumentIdentifier().identify(imageData)
        }
    }

    /// Map the model's draft into a grounded `WineCandidate`. We OCR the label once for a grounding
    /// haystack: a field is kept only if it actually appears in the label text (so the multimodal
    /// model can structure but not fabricate). If OCR yields nothing we trust the model's read.
    private static func candidate(
        from draft: WineLabelDraft,
        cgImage: CGImage,
        orientation: CGImagePropertyOrientation
    ) async -> WineCandidate {
        let lines: [String] = (try? await recognizeDocument(cgImage, orientation))?
            .text.lines
            .map { $0.transcript.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty } ?? []
        let haystack = normalizeForGrounding(lines.joined(separator: " "))

        func grounded(_ value: String?) -> String? {
            guard let value, !value.isEmpty else { return nil }
            if haystack.isEmpty { return value }   // no OCR to check against → trust the multimodal read
            let needle = normalizeForGrounding(value)
            return (needle.count >= 2 && haystack.contains(needle)) ? value : nil
        }
        func groundedPlace(_ value: String?) -> String? { sansYear(grounded(value)) }

        let country = groundedPlace(draft.country)
        let region = groundedPlace(draft.region)
        let hasRegion = country != nil || region != nil
        let grapes = draft.grapes.filter { isKnownGrapeVariety($0) && grounded($0) != nil }
        let vintage = draft.vintage ?? (haystack.isEmpty ? nil : firstYear(in: haystack))

        return WineCandidate(
            producer: grounded(draft.producer),
            name: grounded(draft.cuvee),
            vintage: vintage,
            region: hasRegion ? Region(country: country, region: region) : nil,
            grapes: grapes,
            rawText: lines,
            // Multimodal read of the actual image — higher than the deterministic engine's 0.7.
            confidence: 0.85,
            source: .label
        )
    }
}

// MARK: - Cloud Claude-vision engine

/// Errors thrown by the cloud identify path.
enum CloudVisionError: Error { case invalidResponse }

/// Primary identifier: sends the label image to the deployed `identifyLabel` (Claude-vision) Cloud
/// Function and maps the structured response into a `WineCandidate`. Any failure is propagated to the
/// caller, which falls back to the on-device engine.
struct CloudVisionIdentifier: LabelIdentifier {
    func identify(_ imageData: Data) async throws -> WineCandidate {
        let base64 = imageData.base64EncodedString()
        let callable = Functions.functions(region: "us-central1").httpsCallable("identifyLabel")
        let result = try await callable.call(["imageBase64": base64, "mimeType": "image/jpeg"])
        guard let dict = result.data as? [String: Any] else {
            throw CloudVisionError.invalidResponse
        }
        return wineCandidate(fromIdentifyResponse: dict)
    }
}

/// Pure mapping from the `identifyLabel` callable result payload to a `WineCandidate`. Internal so the
/// test target can exercise it directly. Tolerant of JSON nulls (`NSNull`), missing keys, and numbers
/// decoded as either `Int`/`Double` or `NSNumber` (as FirebaseFunctions may surface them).
func wineCandidate(fromIdentifyResponse dict: [String: Any]) -> WineCandidate {
    func str(_ k: String) -> String? {
        guard let s = dict[k] as? String, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return s
    }
    // vintage may arrive as Int or NSNumber
    let vintage = (dict["vintage"] as? Int) ?? (dict["vintage"] as? NSNumber)?.intValue
    // region: build Region from sub-fields; nil if all sub-fields are absent/empty
    var region: Region?
    if let r = dict["region"] as? [String: Any] {
        func rstr(_ k: String) -> String? {
            guard let s = r[k] as? String, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return s
        }
        let country = rstr("country"), reg = rstr("region"), sub = rstr("subregion"), app = rstr("appellation")
        if country != nil || reg != nil || sub != nil || app != nil {
            region = Region(country: country, region: reg, subregion: sub, appellation: app)
        }
    }
    let grapes = (dict["grapes"] as? [String])?.compactMap { s -> String? in
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines); return t.isEmpty ? nil : t
    } ?? []
    let type = WineType(rawValue: (dict["type"] as? String) ?? "") ?? .other   // "unknown"/missing -> .other
    _ = type   // WineCandidate has no type field; mapped/validated above for forward use.
    let confidence = (dict["confidence"] as? Double) ?? (dict["confidence"] as? NSNumber)?.doubleValue ?? 0.9
    return WineCandidate(
        producer: str("producer"), name: str("name"), vintage: vintage,
        region: region, grapes: grapes, rawText: [], confidence: confidence, source: .label
    )
}

// MARK: - Field classification helpers

/// First 4-digit year in `1900...2035` in `text` (regex; copes with "V.2023", "CHILE / V.2023").
private func firstYear(in text: String) -> Int? {
    for match in text.matches(of: #/\d{4}/#) {
        if let year = Int(match.output), (1900...2035).contains(year) { return year }
    }
    return nil
}

/// Whether `text` contains any plausible vintage year (used to exclude such lines from name candidates).
private func hasYear(_ text: String) -> Bool { firstYear(in: text) != nil }

/// Drop a place value that contains a 4-digit year (e.g. a misfiled "V.2023" fragment).
private func sansYear(_ value: String?) -> String? {
    guard let value else { return nil }
    return value.range(of: #"\d{4}"#, options: .regularExpression) == nil ? value : nil
}

/// Strong, label-style separators between varietals on one line ("Cabernet Sauvignon / Merlot").
private let grapeSeparators = CharacterSet(charactersIn: "/,·\n")

/// Extract grape varieties from `lines`. Within each separator-delimited span we greedily match the
/// longest known varietal across 1–3 word windows, so multi-word names ("Cabernet Sauvignon",
/// "Sauvignon Blanc") survive while single tokens ("Carmenère", "Merlot") still match. Label casing
/// is preserved; matching is diacritic/case-insensitive via `isKnownGrapeVariety`. Deduped.
private func grapeVarieties(in lines: [String]) -> [String] {
    var result: [String] = []
    var seen = Set<String>()
    for line in lines {
        for span in line.components(separatedBy: grapeSeparators) {
            let words = span
                .split { $0 == " " || $0 == "\t" || $0 == "-" }
                .map(String.init)
            var i = 0
            while i < words.count {
                var matched = false
                let maxWindow = min(3, words.count - i)
                for windowSize in stride(from: maxWindow, through: 1, by: -1) {
                    let candidate = words[i..<(i + windowSize)].joined(separator: " ")
                    if isKnownGrapeVariety(candidate) {
                        let key = normalizeForGrounding(candidate)
                        if seen.insert(key).inserted { result.append(candidate) }
                        i += windowSize
                        matched = true
                        break
                    }
                }
                if !matched { i += 1 }
            }
        }
    }
    return result
}

/// Whether a whole line reads as grape content (so it's not mistaken for a producer/cuvée name).
private func lineHasGrape(_ text: String) -> Bool { !grapeVarieties(in: [text]).isEmpty }

/// Winery / producer keywords (normalized). Diacritics are folded by `normalizeForGrounding`, so
/// "viñedos" → "vinedos", "viña" → "vina", "château" → "chateau". Matched whole-word.
private let wineryKeywords: Set<String> = Set([
    "winery", "vineyard", "vineyards", "vinedos", "vina", "estate", "bodega", "bodegas",
    "cantina", "chateau", "domaine", "weingut", "cellars", "cellar", "wines", "family",
].map(normalizeForGrounding))

/// True if `text` contains a winery keyword as a whole word — tolerant of single-character OCR slips
/// (e.g. document recognition reads "VINEYARDS" as "VINEYAROS"). For keywords of length ≥6 a token
/// within edit distance 1 counts; shorter keywords require an exact whole-word match.
private func hasWineryKeyword(_ text: String) -> Bool {
    let tokens = normalizeForGrounding(text).split(separator: " ").map(String.init)
    for token in tokens {
        for keyword in wineryKeywords {
            if token == keyword { return true }
            if keyword.count >= 6, abs(token.count - keyword.count) <= 1,
               editDistanceWithinOne(token, keyword) {
                return true
            }
        }
    }
    return false
}

/// Whether `a` and `b` are within Levenshtein distance 1 (one insertion, deletion, or substitution).
/// Cheap specialization — bails as soon as a second edit is needed.
private func editDistanceWithinOne(_ a: String, _ b: String) -> Bool {
    if a == b { return true }
    let x = Array(a), y = Array(b)
    if abs(x.count - y.count) > 1 { return false }
    if x.count == y.count {
        var diffs = 0
        for i in 0..<x.count where x[i] != y[i] {
            diffs += 1
            if diffs > 1 { return false }
        }
        return true
    }
    // Lengths differ by exactly 1: check the shorter is the longer with one char removed.
    let (short, long) = x.count < y.count ? (x, y) : (y, x)
    var i = 0, j = 0, skipped = false
    while i < short.count, j < long.count {
        if short[i] == long[j] {
            i += 1; j += 1
        } else if skipped {
            return false
        } else {
            skipped = true; j += 1
        }
    }
    return true
}

/// Distinctive marketing/legal phrases (normalized) that mark a line as NOT a name. Matched as
/// substrings since they're long enough to be unambiguous. Deliberately CONSERVATIVE — we do NOT
/// stoplist words that are often legitimate cuvée names ("reserva", "grand vin", "gran reserva").
private let marketingPhrases: [String] = [
    "made with", "organic", "sustainably", "farmed", "product of",
    "contains", "sulfites", "vegan", "imported", "estate bottled",
].map(normalizeForGrounding)

/// Short, ambiguous volume/alcohol tokens. Matched only as WHOLE words (not substrings) so we don't
/// nuke real names — e.g. substring "cl" would otherwise hit "Clos", "vol" would hit "Volnay".
private let marketingTokens: Set<String> = ["alc", "vol", "ml", "cl", "hand"]

/// True if `text` looks like marketing / legal small print rather than a producer or cuvée name.
private func isMarketing(_ text: String) -> Bool {
    if text.contains("%") { return true }                  // "13% vol", "ALC 14%"
    let normalized = normalizeForGrounding(text)
    if marketingPhrases.contains(where: { normalized.contains($0) }) { return true }
    let tokens = Set(normalized.split(separator: " ").map(String.init))
    return !tokens.isDisjoint(with: marketingTokens)
}

// MARK: - Place vocabulary

/// Curated wine-country vocabulary: normalized key (incl. synonyms) → canonical display name. Only
/// values that literally appear on the label get assigned (the key is matched against the line);
/// canonical capitalization is used for display so "USA"/"ESPAÑA" surface as "United States"/"Spain".
/// Ordered (array, not dict) for deterministic first-match precedence.
private let knownWineCountries: [(key: String, display: String)] = [
    ("united states of america", "United States"),
    ("united states", "United States"),
    ("usa", "United States"),
    ("france", "France"),
    ("italy", "Italy"),
    ("italia", "Italy"),
    ("spain", "Spain"),
    ("espana", "Spain"),
    ("chile", "Chile"),
    ("argentina", "Argentina"),
    ("australia", "Australia"),
    ("new zealand", "New Zealand"),
    ("portugal", "Portugal"),
    ("germany", "Germany"),
    ("deutschland", "Germany"),
    ("austria", "Austria"),
    ("osterreich", "Austria"),
    ("south africa", "South Africa"),
    ("greece", "Greece"),
    ("hungary", "Hungary"),
].map { (normalizeForGrounding($0.0), $0.1) }

/// Curated wine-region vocabulary (same shape/semantics as `knownWineCountries`). Not exhaustive —
/// M3 enrichment can expand this from a real taxonomy.
private let knownWineRegions: [(key: String, display: String)] = [
    ("bordeaux", "Bordeaux"),
    ("burgundy", "Burgundy"),
    ("bourgogne", "Burgundy"),
    ("champagne", "Champagne"),
    ("rhone", "Rhône"),
    ("margaux", "Margaux"),
    ("rioja", "Rioja"),
    ("ribera del duero", "Ribera del Duero"),
    ("tuscany", "Tuscany"),
    ("toscana", "Tuscany"),
    ("piedmont", "Piedmont"),
    ("piemonte", "Piedmont"),
    ("douro", "Douro"),
    ("mosel", "Mosel"),
    ("napa valley", "Napa Valley"),
    ("napa", "Napa Valley"),
    ("sonoma", "Sonoma"),
    ("barossa valley", "Barossa Valley"),
    ("barossa", "Barossa Valley"),
    ("marlborough", "Marlborough"),
    ("mendoza", "Mendoza"),
    ("maipo", "Maipo Valley"),
    ("colchagua", "Colchagua Valley"),
    ("stellenbosch", "Stellenbosch"),
].map { (normalizeForGrounding($0.0), $0.1) }

/// Return the canonical display value if any vocabulary key appears as a whole word/phrase in `text`.
private func matchPlace(_ text: String, _ vocabulary: [(key: String, display: String)]) -> String? {
    let padded = " " + normalizeForGrounding(text) + " "
    for entry in vocabulary where padded.contains(" \(entry.key) ") {
        return entry.display
    }
    return nil
}

// MARK: - Grounding / normalization

/// Fold text for substring grounding checks: diacritic- and case-insensitive, with runs of
/// non-alphanumerics collapsed to single spaces. Lets "Château Margaux" match "CHATEAU  MARGAUX".
func normalizeForGrounding(_ string: String) -> String {
    let folded = string.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
    let collapsed = folded
        .components(separatedBy: CharacterSet.alphanumerics.inverted)
        .filter { !$0.isEmpty }
        .joined(separator: " ")
    return collapsed
}

// MARK: - Grape variety vocabulary

/// Curated set of common grape varieties (normalized), used to keep producer names / marketing lines
/// out of `grapes`. Not exhaustive — M3 enrichment can expand this via a real taxonomy (e.g.
/// Wikidata). Conservative on purpose: better to drop a rare varietal than to surface
/// "Organic Vineyards" as a grape.
private let knownGrapeVarieties: Set<String> = Set([
    "cabernet sauvignon", "cabernet franc", "merlot", "malbec", "petit verdot", "carmenere",
    "syrah", "shiraz", "grenache", "garnacha", "mourvedre", "monastrell", "cinsault", "carignan",
    "pinot noir", "pinot meunier", "gamay", "tempranillo", "garnacha tinta", "sangiovese", "nebbiolo",
    "barbera", "dolcetto", "montepulciano", "primitivo", "zinfandel", "nero d avola", "aglianico",
    "corvina", "tannat", "pinotage", "touriga nacional", "bonarda", "mencia", "blaufrankisch",
    "chardonnay", "sauvignon blanc", "semillon", "riesling", "pinot gris", "pinot grigio",
    "gewurztraminer", "viognier", "chenin blanc", "marsanne", "roussanne", "muscat", "moscato",
    "vermentino", "fiano", "greco", "verdejo", "albarino", "godello", "macabeo", "viura", "xarel lo",
    "parellada", "gruner veltliner", "torrontes", "petite sirah", "petit manseng", "trebbiano",
    "glera", "cortese", "verdicchio",
].map { normalizeForGrounding($0) })

/// True if `value` reads as an actual grape variety (exact normalized match against the vocabulary).
func isKnownGrapeVariety(_ value: String) -> Bool {
    knownGrapeVarieties.contains(normalizeForGrounding(value))
}

// MARK: - Heuristic fallback

/// Deterministic, no-AI structuring from strings only (no layout). Conservative: fills producer /
/// cuvée / vintage by order. Used as the fallback when document recognition is unavailable and as the
/// text-only `structure` entry point.
func heuristicStructure(_ lines: [String]) -> WineCandidate {
    let trimmed = lines
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }

    func isVintageLine(_ line: String) -> Bool {
        line.range(of: #"^\d{4}$"#, options: .regularExpression) != nil
    }

    func isVolumeOrAlcohol(_ line: String) -> Bool {
        let lower = line.lowercased()
        return ["ml", "cl", "%", "vol", "alc"].contains { lower.contains($0) }
    }

    // vintage = first four-digit number in 1900...2035 found anywhere.
    var vintage: Int?
    for line in trimmed {
        if let year = firstYear(in: line) {
            vintage = year
            break
        }
    }

    // producer = first qualifying line; name = next qualifying line.
    var producer: String?
    var name: String?
    for line in trimmed where !isVintageLine(line) && !isVolumeOrAlcohol(line) {
        if producer == nil {
            producer = line
        } else if name == nil {
            name = line
            break
        }
    }

    return WineCandidate(
        producer: producer,
        name: name,
        vintage: vintage,
        rawText: lines,
        confidence: 0.4,
        source: .label
    )
}
