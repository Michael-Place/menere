import Dependencies
import DependenciesMacros
import FirebaseFirestore
import Foundation
import WineDomain

/// Firestore access for the two-tier data model:
/// - `wines/{canonicalKey}`            — shared catalog (cache + moat, grows from every scan)
/// - `users/{uid}/bottles/{id}`        — private inventory
/// - `users/{uid}/tastings/{id}`       — private tasting history
///
/// Modeled as a `@DependencyClient` so TCA features inject it and tests can swap it.
@DependencyClient
public struct PersistenceClient: Sendable {
    // MARK: Shared wine catalog
    /// Look up a wine in the shared catalog by canonical key. Nil if not yet known.
    public var wine: @Sendable (_ canonicalKey: String) async throws -> Wine?
    /// Batch-fetch wines from the shared catalog by canonical key (chunked to respect Firestore's
    /// ~10-element `in`-query cap). Order is not guaranteed; callers should key by `Wine.id`.
    public var wines: @Sendable (_ keys: [String]) async throws -> [Wine]
    /// Create or update a wine in the shared catalog (merge).
    public var upsertWine: @Sendable (_ wine: Wine) async throws -> Void

    // MARK: Per-user bottles
    public var bottles: @Sendable (_ uid: String) async throws -> [Bottle]
    public var saveBottle: @Sendable (_ uid: String, _ bottle: Bottle) async throws -> Void

    // MARK: Per-user tastings
    public var tastings: @Sendable (_ uid: String) async throws -> [Tasting]
    public var saveTasting: @Sendable (_ uid: String, _ tasting: Tasting) async throws -> Void
}

extension PersistenceClient: DependencyKey {
    public static let liveValue: PersistenceClient = {
        let db = { Firestore.firestore() }

        func wines() -> CollectionReference { db().collection("wines") }
        func userDoc(_ uid: String) -> DocumentReference { db().collection("users").document(uid) }

        return PersistenceClient(
            wine: { key in
                let snapshot = try await wines().document(key).getDocument()
                guard let data = snapshot.data() else { return nil }
                return try Firestore.Decoder().decode(Wine.self, from: data)
            },
            wines: { keys in
                let unique = Array(Set(keys))
                guard !unique.isEmpty else { return [] }
                var result: [Wine] = []
                for chunk in stride(from: 0, to: unique.count, by: 10).map({ Array(unique[$0..<min($0 + 10, unique.count)]) }) {
                    let snapshot = try await wines().whereField(FieldPath.documentID(), in: chunk).getDocuments()
                    result += try snapshot.documents.map { try Firestore.Decoder().decode(Wine.self, from: $0.data()) }
                }
                return result
            },
            upsertWine: { wine in
                try await wines().document(wine.id).setData(
                    Firestore.Encoder().encode(wine), merge: true
                )
            },
            bottles: { uid in
                let snapshot = try await userDoc(uid).collection("bottles").getDocuments()
                return try snapshot.documents.map { try Firestore.Decoder().decode(Bottle.self, from: $0.data()) }
            },
            saveBottle: { uid, bottle in
                try await userDoc(uid).collection("bottles").document(bottle.id).setData(
                    Firestore.Encoder().encode(bottle), merge: true
                )
            },
            tastings: { uid in
                let snapshot = try await userDoc(uid).collection("tastings").getDocuments()
                return try snapshot.documents.map { try Firestore.Decoder().decode(Tasting.self, from: $0.data()) }
            },
            saveTasting: { uid, tasting in
                try await userDoc(uid).collection("tastings").document(tasting.id).setData(
                    Firestore.Encoder().encode(tasting), merge: true
                )
            }
        )
    }()
}

public extension DependencyValues {
    var persistence: PersistenceClient {
        get { self[PersistenceClient.self] }
        set { self[PersistenceClient.self] = newValue }
    }
}
