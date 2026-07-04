import Dependencies
import DependenciesMacros
import FirebaseFunctions
import Foundation

/// The structured result of the `troubleshootPlant` Claude-vision callable (P19-C3 — the "plant
/// whisperer"). `suggestedWaterIntervalDays` is non-nil ONLY when the problem/context implies the
/// watering cadence should change (rot → longer, fast-dry pot → shorter); `careTip` is an optional
/// forward-looking prevention tip.
public struct PlantDiagnosis: Equatable, Sendable {
    public var diagnosis: String
    public var fixes: [String]
    public var suggestedWaterIntervalDays: Int?
    public var careTip: String?

    public init(
        diagnosis: String,
        fixes: [String] = [],
        suggestedWaterIntervalDays: Int? = nil,
        careTip: String? = nil
    ) {
        self.diagnosis = diagnosis
        self.fixes = fixes
        self.suggestedWaterIntervalDays = suggestedWaterIntervalDays
        self.careTip = careTip
    }
}

/// The input to a troubleshoot call — the plant's identity + situation + the described problem, plus
/// an optional already-compressed JPEG of the problem.
public struct PlantTroubleshootQuery: Equatable, Sendable {
    public var species: String?
    public var commonName: String?
    public var careContext: String?
    public var waterIntervalDays: Int?
    public var problem: String
    public var jpeg: Data?

    public init(
        species: String? = nil,
        commonName: String? = nil,
        careContext: String? = nil,
        waterIntervalDays: Int? = nil,
        problem: String,
        jpeg: Data? = nil
    ) {
        self.species = species
        self.commonName = commonName
        self.careContext = careContext
        self.waterIntervalDays = waterIntervalDays
        self.problem = problem
        self.jpeg = jpeg
    }
}

/// Wraps the `troubleshootPlant` HTTPS callable — AI plant troubleshooting for the plant detail
/// screen. Mirrors ``PlantsClient``'s shape (same transport: base64 JPEG + media type when a photo is
/// attached).
@DependencyClient
public struct PlantTroubleshootClient: Sendable {
    /// Ask Bacán about a plant problem. Throws on network/server failure.
    public var troubleshoot: @Sendable (_ query: PlantTroubleshootQuery) async throws -> PlantDiagnosis
}

enum PlantTroubleshootClientError: Error { case invalidResponse }

extension PlantTroubleshootClient: DependencyKey {
    public static let liveValue = PlantTroubleshootClient(
        troubleshoot: { query in
            var payload: [String: Any] = ["problem": query.problem]
            if let s = query.species, !s.isEmpty { payload["species"] = s }
            if let c = query.commonName, !c.isEmpty { payload["commonName"] = c }
            if let ctx = query.careContext, !ctx.isEmpty { payload["careContext"] = ctx }
            if let days = query.waterIntervalDays { payload["waterIntervalDays"] = days }
            if let jpeg = query.jpeg {
                payload["imageBase64"] = jpeg.base64EncodedString()
                payload["mediaType"] = "image/jpeg"
            }
            let callable = Functions.functions(region: "us-central1").httpsCallable("troubleshootPlant")
            let result = try await callable.call(payload)
            guard let dict = result.data as? [String: Any] else {
                throw PlantTroubleshootClientError.invalidResponse
            }
            return plantDiagnosis(fromCallableResponse: dict)
        }
    )
}

/// Pure mapping from the `troubleshootPlant` callable payload to a ``PlantDiagnosis``. Tolerant of JSON
/// nulls, missing keys, and numbers surfaced as `Int` or `NSNumber`.
func plantDiagnosis(fromCallableResponse dict: [String: Any]) -> PlantDiagnosis {
    func str(_ key: String) -> String? {
        guard let s = dict[key] as? String,
              !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return s
    }
    let fixes = (dict["fixes"] as? [Any])?.compactMap { entry -> String? in
        guard let s = entry as? String,
              !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return s
    } ?? []
    let suggested = (dict["suggestedWaterIntervalDays"] as? Int)
        ?? (dict["suggestedWaterIntervalDays"] as? NSNumber)?.intValue
    return PlantDiagnosis(
        diagnosis: str("diagnosis") ?? "",
        fixes: fixes,
        suggestedWaterIntervalDays: (suggested ?? 0) > 0 ? suggested : nil,
        careTip: str("careTip")
    )
}

extension DependencyValues {
    public var plantTroubleshoot: PlantTroubleshootClient {
        get { self[PlantTroubleshootClient.self] }
        set { self[PlantTroubleshootClient.self] = newValue }
    }
}
