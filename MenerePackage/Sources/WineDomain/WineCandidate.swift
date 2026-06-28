import Foundation

/// Where a scanned candidate originated.
public enum CandidateSource: String, Codable, Equatable, Sendable {
    case barcode, label
}

/// The structured-but-unresolved identity produced by scanning a bottle — *before* any enrichment or
/// catalog resolution (that's M3). OCR/AI may not find every field, so all structured fields are
/// optional. Convert a user-confirmed candidate into a catalog `Wine` via `provisionalWine`.
public struct WineCandidate: Codable, Equatable, Sendable {
    public var producer: String?
    /// Cuvée / bottling name.
    public var name: String?
    public var vintage: Int?
    public var region: Region?
    public var grapes: [String]
    /// Raw barcode payload, when scanned via the barcode path.
    public var barcode: String?
    /// Raw OCR lines, top-to-bottom. Empty for barcode-only candidates.
    public var rawText: [String]
    /// Overall confidence of the structuring, 0...1.
    public var confidence: Double
    public var source: CandidateSource

    public init(
        producer: String? = nil,
        name: String? = nil,
        vintage: Int? = nil,
        region: Region? = nil,
        grapes: [String] = [],
        barcode: String? = nil,
        rawText: [String] = [],
        confidence: Double = 0,
        source: CandidateSource = .label
    ) {
        self.producer = producer
        self.name = name
        self.vintage = vintage
        self.region = region
        self.grapes = grapes
        self.barcode = barcode
        self.rawText = rawText
        self.confidence = confidence
        self.source = source
    }
}

public extension WineCandidate {
    /// A provisional catalog `Wine` built from this candidate (canonical id derived from
    /// producer/name/vintage). Nil unless `producer` is non-empty. Used by later milestones to turn a
    /// confirmed candidate into a `Wine`.
    var provisionalWine: Wine? {
        guard let producer, !producer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return Wine(
            producer: producer,
            name: name,
            vintage: vintage,
            region: region,
            grapes: grapes,
            type: .other
        )
    }
}
