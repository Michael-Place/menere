import Dependencies
import DependenciesMacros
import FirebaseFirestore
import Foundation
import WineDomain

/// Firestore access for the two-tier data model:
/// - `wines/{canonicalKey}`            — shared catalog (cache + moat, grows from every scan)
/// - `households/{hid}`                 — shared household space (members read/write)
/// - `households/{hid}/bottles/{id}`    — shared inventory
/// - `households/{hid}/tastings/{id}`   — shared tasting history
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

    // MARK: Household bottles
    public var bottles: @Sendable (_ hid: String) async throws -> [Bottle]
    public var saveBottle: @Sendable (_ hid: String, _ bottle: Bottle) async throws -> Void

    // MARK: Household tastings
    public var tastings: @Sendable (_ hid: String) async throws -> [Tasting]
    public var saveTasting: @Sendable (_ hid: String, _ tasting: Tasting) async throws -> Void

    // MARK: Households
    /// Fetch a household by id. Nil if it doesn't exist.
    public var household: @Sendable (_ hid: String) async throws -> Household?
    /// Ensure the user has a personal household; returns its id. Idempotent.
    public var ensureHousehold: @Sendable (_ uid: String) async throws -> String
}

extension PersistenceClient: DependencyKey {
    public static let liveValue: PersistenceClient = {
        let db = { Firestore.firestore() }

        func wines() -> CollectionReference { db().collection("wines") }
        func households() -> CollectionReference { db().collection("households") }

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
            bottles: { hid in
                let snapshot = try await households().document(hid).collection("bottles").getDocuments()
                return try snapshot.documents.map { try Firestore.Decoder().decode(Bottle.self, from: $0.data()) }
            },
            saveBottle: { hid, bottle in
                try await households().document(hid).collection("bottles").document(bottle.id).setData(
                    Firestore.Encoder().encode(bottle), merge: true
                )
            },
            tastings: { hid in
                let snapshot = try await households().document(hid).collection("tastings").getDocuments()
                return try snapshot.documents.map { try Firestore.Decoder().decode(Tasting.self, from: $0.data()) }
            },
            saveTasting: { hid, tasting in
                try await households().document(hid).collection("tastings").document(tasting.id).setData(
                    Firestore.Encoder().encode(tasting), merge: true
                )
            },
            household: { hid in
                let s = try await households().document(hid).getDocument()
                guard let d = s.data() else { return nil }
                return try Firestore.Decoder().decode(Household.self, from: d)
            },
            ensureHousehold: { uid in
                let userRef = db().collection("users").document(uid)
                let snap = try await userRef.getDocument()
                if let existing = snap.data()?["householdId"] as? String, !existing.isEmpty {
                    let hs = try await households().document(existing).getDocument()
                    if hs.exists { return existing }
                }
                let hid = UUID().uuidString
                // invite code: 6 chars from an unambiguous alphabet
                let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
                let code = String((0..<6).map { _ in alphabet.randomElement()! })
                let household = Household(id: hid, ownerUid: uid, members: [uid], inviteCode: code)
                try await households().document(hid).setData(Firestore.Encoder().encode(household))
                try await userRef.setData(["householdId": hid], merge: true)
                return hid
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
