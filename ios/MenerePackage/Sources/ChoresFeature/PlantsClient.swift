import Dependencies
import DependenciesMacros
import FamilyDomain
import FirebaseFunctions
import Foundation

/// The structured result of the `identifyPlant` Claude-vision callable (P9 Plants). Care fields are
/// for the plant grown as a houseplant unless it's clearly outdoor. `latinName` is `nil` for an
/// unknown plant (the server never invents one).
public struct PlantIdentification: Equatable, Sendable {
    public var commonName: String
    public var latinName: String?
    public var confidence: String       // "high" / "medium" / "low"
    public var waterIntervalDays: Int?
    public var light: String?
    public var careNotes: String?

    public init(
        commonName: String,
        latinName: String? = nil,
        confidence: String,
        waterIntervalDays: Int? = nil,
        light: String? = nil,
        careNotes: String? = nil
    ) {
        self.commonName = commonName
        self.latinName = latinName
        self.confidence = confidence
        self.waterIntervalDays = waterIntervalDays
        self.light = light
        self.careNotes = careNotes
    }

    /// Low confidence — the caller fills nothing and shows a warm "try again" note.
    public var isLowConfidence: Bool { confidence.lowercased() == "low" }
    /// The server couldn't identify the plant (common name "Unknown").
    public var isUnknown: Bool {
        commonName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "unknown"
    }
}

/// Wraps the `identifyPlant` HTTPS callable — AI plant identify for the plant form. Same transport as
/// the wine `identifyLabel` path (base64 JPEG + media type). Mirrors `DocsClient`'s shape.
@DependencyClient
public struct PlantsClient: Sendable {
    /// Identify a plant from a compressed JPEG. Throws on network/server failure; a low-confidence
    /// result comes back as a normal `PlantIdentification` (`isLowConfidence == true`).
    public var identify: @Sendable (_ jpeg: Data) async throws -> PlantIdentification
    /// Fetch the rich species profile (light/humidity/fertilizer/temp/problems + pet-toxicity) for a
    /// plant by its species / common name (P19-C4). No photo — a knowledge lookup. Throws on failure.
    public var profile: @Sendable (_ species: String?, _ commonName: String?) async throws -> SpeciesProfile
}

enum PlantsClientError: Error { case invalidResponse }

extension PlantsClient: DependencyKey {
    public static let liveValue = PlantsClient(
        identify: { jpeg in
            let base64 = jpeg.base64EncodedString()
            let callable = Functions.functions(region: "us-central1").httpsCallable("identifyPlant")
            let result = try await callable.call(["imageBase64": base64, "mediaType": "image/jpeg"])
            guard let dict = result.data as? [String: Any] else {
                throw PlantsClientError.invalidResponse
            }
            return plantIdentification(fromCallableResponse: dict)
        },
        profile: { species, commonName in
            var payload: [String: Any] = [:]
            if let s = species, !s.isEmpty { payload["species"] = s }
            if let c = commonName, !c.isEmpty { payload["commonName"] = c }
            let callable = Functions.functions(region: "us-central1").httpsCallable("plantSpeciesProfile")
            let result = try await callable.call(payload)
            guard let dict = result.data as? [String: Any] else {
                throw PlantsClientError.invalidResponse
            }
            return speciesProfile(fromCallableResponse: dict)
        }
    )
}

/// Pure mapping from the `plantSpeciesProfile` callable payload to a ``SpeciesProfile``. Tolerant of
/// JSON nulls, missing keys, and the nested `petToxicity` map.
func speciesProfile(fromCallableResponse dict: [String: Any]) -> SpeciesProfile {
    func str(_ d: [String: Any], _ key: String) -> String? {
        guard let s = d[key] as? String,
              !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return s
    }
    func bool(_ d: [String: Any], _ key: String) -> Bool {
        (d[key] as? Bool) ?? ((d[key] as? NSNumber)?.boolValue ?? false)
    }
    let problems = (dict["commonProblems"] as? [Any])?.compactMap { entry -> String? in
        guard let s = entry as? String,
              !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return s
    } ?? []
    var toxicity: PetToxicity?
    if let t = dict["petToxicity"] as? [String: Any] {
        let dogs = bool(t, "toxicToDogs")
        let cats = bool(t, "toxicToCats")
        toxicity = PetToxicity(
            isToxicToPets: bool(t, "isToxicToPets") || dogs || cats,
            toxicToDogs: dogs,
            toxicToCats: cats,
            severity: str(t, "severity"),
            note: str(t, "note")
        )
    }
    return SpeciesProfile(
        lightNeed: str(dict, "lightNeed"),
        humidity: str(dict, "humidity"),
        fertilizer: str(dict, "fertilizer"),
        idealTemp: str(dict, "idealTemp"),
        commonProblems: problems,
        petToxicity: toxicity
    )
}

/// Pure mapping from the `identifyPlant` callable payload to a `PlantIdentification`. Tolerant of JSON
/// nulls, missing keys, and numbers surfaced as `Int` or `NSNumber`.
func plantIdentification(fromCallableResponse dict: [String: Any]) -> PlantIdentification {
    func str(_ key: String) -> String? {
        guard let s = dict[key] as? String,
              !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return s
    }
    let water = (dict["waterIntervalDays"] as? Int) ?? (dict["waterIntervalDays"] as? NSNumber)?.intValue
    return PlantIdentification(
        commonName: str("commonName") ?? "Unknown",
        latinName: str("latinName"),
        confidence: str("confidence") ?? "low",
        waterIntervalDays: water,
        light: str("light"),
        careNotes: str("careNotes")
    )
}

extension DependencyValues {
    public var plants: PlantsClient {
        get { self[PlantsClient.self] }
        set { self[PlantsClient.self] = newValue }
    }
}
