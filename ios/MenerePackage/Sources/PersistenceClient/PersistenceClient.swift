import Dependencies
import DependenciesMacros
import FamilyDomain
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

    public var deleteBottle: @Sendable (_ hid: String, _ bottleId: String) async throws -> Void
    public var deleteTasting: @Sendable (_ hid: String, _ tastingId: String) async throws -> Void

    // MARK: Households
    /// Fetch a household by id. Nil if it doesn't exist.
    public var household: @Sendable (_ hid: String) async throws -> Household?
    /// Ensure the user has a personal household; returns its id. Idempotent.
    public var ensureHousehold: @Sendable (_ uid: String) async throws -> String

    // MARK: Members
    /// All member profiles in a household.
    public var members: @Sendable (_ hid: String) async throws -> [HouseholdMember]
    /// Create or update a member profile.
    public var saveMember: @Sendable (_ hid: String, _ member: HouseholdMember) async throws -> Void
    /// Ensure a member profile exists for `uid`; seeds one (using `name`) if absent.
    /// Idempotent — never overwrites an existing profile's edits. Returns the profile.
    public var ensureMember: @Sendable (_ hid: String, _ uid: String, _ name: String) async throws -> HouseholdMember

    // MARK: Lists
    public var lists: @Sendable (_ hid: String) async throws -> [FamilyList]
    public var saveList: @Sendable (_ hid: String, _ list: FamilyList) async throws -> Void
    public var deleteList: @Sendable (_ hid: String, _ listID: String) async throws -> Void
    public var listItems: @Sendable (_ hid: String, _ listID: String) async throws -> [ListItem]
    public var saveListItem: @Sendable (_ hid: String, _ item: ListItem) async throws -> Void
    public var deleteListItem: @Sendable (_ hid: String, _ listID: String, _ itemID: String) async throws -> Void

    // MARK: Events
    public var events: @Sendable (_ hid: String) async throws -> [FamilyEvent]
    public var saveEvent: @Sendable (_ hid: String, _ event: FamilyEvent) async throws -> Void
    public var deleteEvent: @Sendable (_ hid: String, _ eventID: String) async throws -> Void

    // MARK: Chores + gamification
    public var chores: @Sendable (_ hid: String) async throws -> [Chore]
    public var saveChore: @Sendable (_ hid: String, _ chore: Chore) async throws -> Void
    public var deleteChore: @Sendable (_ hid: String, _ choreID: String) async throws -> Void
    public var memberStats: @Sendable (_ hid: String) async throws -> [MemberStats]
    public var saveMemberStats: @Sendable (_ hid: String, _ stats: MemberStats) async throws -> Void
    /// Live stream of member stats (updates as the server-side XP trigger writes them).
    public var observeMemberStats: @Sendable (_ hid: String) -> AsyncStream<[MemberStats]> = { _ in
        AsyncStream { $0.finish() }
    }
    public var rewards: @Sendable (_ hid: String) async throws -> [Reward]
    public var saveReward: @Sendable (_ hid: String, _ reward: Reward) async throws -> Void
    public var deleteReward: @Sendable (_ hid: String, _ rewardID: String) async throws -> Void
    public var redemptions: @Sendable (_ hid: String) async throws -> [RewardRedemption]
    public var saveRedemption: @Sendable (_ hid: String, _ redemption: RewardRedemption) async throws -> Void

    // MARK: Recipes + meal plan
    public var recipes: @Sendable (_ hid: String) async throws -> [Recipe]
    public var saveRecipe: @Sendable (_ hid: String, _ recipe: Recipe) async throws -> Void
    public var deleteRecipe: @Sendable (_ hid: String, _ recipeID: String) async throws -> Void
    public var mealPlan: @Sendable (_ hid: String) async throws -> [MealPlanEntry]
    public var saveMealPlanEntry: @Sendable (_ hid: String, _ entry: MealPlanEntry) async throws -> Void
    public var deleteMealPlanEntry: @Sendable (_ hid: String, _ entryID: String) async throws -> Void

    // MARK: Family-Brain documents
    /// All documents in a household (order is not guaranteed; callers sort newest-first).
    public var documents: @Sendable (_ hid: String) async throws -> [Document]
    /// Live stream of documents, newest-first (updates as `processDocument` writes back and as
    /// uploads/deletes land). Mirrors `observeMemberStats`; the leaderboard's live-listener twin.
    public var observeDocuments: @Sendable (_ hid: String) -> AsyncThrowingStream<[Document], Error> = { _ in
        AsyncThrowingStream { $0.finish() }
    }
    public var saveDocument: @Sendable (_ hid: String, _ doc: Document) async throws -> Void
    public var deleteDocument: @Sendable (_ hid: String, _ docID: String) async throws -> Void

    // MARK: Home care (P8)
    /// All care items in a household at `households/{hid}/careItems` (order not guaranteed;
    /// callers sort by soonest-due).
    public var careItems: @Sendable (_ hid: String) async throws -> [CareItem]
    public var saveCareItem: @Sendable (_ hid: String, _ item: CareItem) async throws -> Void
    public var deleteCareItem: @Sendable (_ hid: String, _ itemID: String) async throws -> Void

    // MARK: Smart home (Hue) config (P12)
    /// The household's Hue config at `households/{hid}/config/hue`, or nil when the doc is absent
    /// (never paired). Decode-safe: a partial/hand-written doc still resolves. Reading it is the
    /// cheap gate for the Today "house" card — no doc, no card.
    public var hueConfig: @Sendable (_ hid: String) async throws -> HueConfig?
    /// Merge a corrected bridge IP back into the config doc after cloud rediscovery healed an
    /// IP drift (leaves every other field untouched).
    public var updateHueBridgeIP: @Sendable (_ hid: String, _ bridgeIP: String) async throws -> Void
    /// Full-document write of the Hue config (P12-C2 pairing / re-pairing). Not a merge — the whole
    /// `households/{hid}/config/hue` doc is replaced, so fields dropped since a prior write (e.g. a
    /// `mock` flag from the C1 fixture) actually clear.
    public var saveHueConfig: @Sendable (_ hid: String, _ config: HueConfig) async throws -> Void

    // MARK: Activity feed
    /// Recent activity, newest first (capped at 50).
    public var activity: @Sendable (_ hid: String) async throws -> [ActivityItem]
    /// Append an activity-feed entry (fire-and-forget at call sites).
    public var logActivity: @Sendable (_ hid: String, _ item: ActivityItem) async throws -> Void
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
            deleteBottle: { hid, bottleId in
                try await households().document(hid).collection("bottles").document(bottleId).delete()
            },
            deleteTasting: { hid, tastingId in
                try await households().document(hid).collection("tastings").document(tastingId).delete()
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
            },
            members: { hid in
                let snapshot = try await households().document(hid).collection("members").getDocuments()
                return try snapshot.documents.map { try Firestore.Decoder().decode(HouseholdMember.self, from: $0.data()) }
            },
            saveMember: { hid, member in
                try await households().document(hid).collection("members").document(member.id).setData(
                    Firestore.Encoder().encode(member), merge: true
                )
            },
            ensureMember: { hid, uid, name in
                let ref = households().document(hid).collection("members").document(uid)
                let snap = try await ref.getDocument()
                if let data = snap.data(),
                   let existing = try? Firestore.Decoder().decode(HouseholdMember.self, from: data) {
                    return existing
                }
                // Assign the first palette color not already taken by another member.
                let taken = try await households().document(hid).collection("members").getDocuments()
                    .documents.compactMap { $0.data()["color"] as? String }
                let color = MemberColor.allCases.first { !taken.contains($0.rawValue) } ?? .ocean
                let fallbackName = name.trimmingCharacters(in: .whitespacesAndNewlines)
                let member = HouseholdMember(
                    id: uid,
                    name: fallbackName.isEmpty ? "Member" : fallbackName,
                    color: color
                )
                try await ref.setData(Firestore.Encoder().encode(member))
                return member
            },
            lists: { hid in
                let snapshot = try await households().document(hid).collection("lists").getDocuments()
                return try snapshot.documents.map { try Firestore.Decoder().decode(FamilyList.self, from: $0.data()) }
            },
            saveList: { hid, list in
                try await households().document(hid).collection("lists").document(list.id).setData(
                    Firestore.Encoder().encode(list), merge: true
                )
            },
            deleteList: { hid, listID in
                let listRef = households().document(hid).collection("lists").document(listID)
                // Delete child items first, then the list doc.
                let items = try await listRef.collection("items").getDocuments()
                for item in items.documents { try await item.reference.delete() }
                try await listRef.delete()
            },
            listItems: { hid, listID in
                let snapshot = try await households().document(hid).collection("lists")
                    .document(listID).collection("items").getDocuments()
                return try snapshot.documents.map { try Firestore.Decoder().decode(ListItem.self, from: $0.data()) }
            },
            saveListItem: { hid, item in
                try await households().document(hid).collection("lists")
                    .document(item.listID).collection("items").document(item.id).setData(
                        Firestore.Encoder().encode(item), merge: true
                    )
            },
            deleteListItem: { hid, listID, itemID in
                try await households().document(hid).collection("lists")
                    .document(listID).collection("items").document(itemID).delete()
            },
            events: { hid in
                let snapshot = try await households().document(hid).collection("events").getDocuments()
                return try snapshot.documents.map { try Firestore.Decoder().decode(FamilyEvent.self, from: $0.data()) }
            },
            saveEvent: { hid, event in
                try await households().document(hid).collection("events").document(event.id).setData(
                    Firestore.Encoder().encode(event), merge: true
                )
            },
            deleteEvent: { hid, eventID in
                try await households().document(hid).collection("events").document(eventID).delete()
            },
            chores: { hid in
                let snapshot = try await households().document(hid).collection("chores").getDocuments()
                return try snapshot.documents.map { try Firestore.Decoder().decode(Chore.self, from: $0.data()) }
            },
            saveChore: { hid, chore in
                try await households().document(hid).collection("chores").document(chore.id).setData(
                    Firestore.Encoder().encode(chore), merge: true
                )
            },
            deleteChore: { hid, choreID in
                try await households().document(hid).collection("chores").document(choreID).delete()
            },
            memberStats: { hid in
                let snapshot = try await households().document(hid).collection("memberStats").getDocuments()
                return try snapshot.documents.map { try Firestore.Decoder().decode(MemberStats.self, from: $0.data()) }
            },
            saveMemberStats: { hid, stats in
                try await households().document(hid).collection("memberStats").document(stats.id).setData(
                    Firestore.Encoder().encode(stats), merge: true
                )
            },
            observeMemberStats: { hid in
                AsyncStream { continuation in
                    let listener = households().document(hid).collection("memberStats")
                        .addSnapshotListener { snapshot, _ in
                            let stats = snapshot?.documents.compactMap {
                                try? Firestore.Decoder().decode(MemberStats.self, from: $0.data())
                            } ?? []
                            continuation.yield(stats)
                        }
                    continuation.onTermination = { _ in listener.remove() }
                }
            },
            rewards: { hid in
                let snapshot = try await households().document(hid).collection("rewards").getDocuments()
                return try snapshot.documents.map { try Firestore.Decoder().decode(Reward.self, from: $0.data()) }
            },
            saveReward: { hid, reward in
                try await households().document(hid).collection("rewards").document(reward.id).setData(
                    Firestore.Encoder().encode(reward), merge: true
                )
            },
            deleteReward: { hid, rewardID in
                try await households().document(hid).collection("rewards").document(rewardID).delete()
            },
            redemptions: { hid in
                let snapshot = try await households().document(hid).collection("redemptions").getDocuments()
                return try snapshot.documents.map { try Firestore.Decoder().decode(RewardRedemption.self, from: $0.data()) }
            },
            saveRedemption: { hid, redemption in
                try await households().document(hid).collection("redemptions").document(redemption.id).setData(
                    Firestore.Encoder().encode(redemption), merge: true
                )
            },
            recipes: { hid in
                let snapshot = try await households().document(hid).collection("recipes").getDocuments()
                return try snapshot.documents.map { try Firestore.Decoder().decode(Recipe.self, from: $0.data()) }
            },
            saveRecipe: { hid, recipe in
                try await households().document(hid).collection("recipes").document(recipe.id).setData(
                    Firestore.Encoder().encode(recipe), merge: true
                )
            },
            deleteRecipe: { hid, recipeID in
                try await households().document(hid).collection("recipes").document(recipeID).delete()
            },
            mealPlan: { hid in
                let snapshot = try await households().document(hid).collection("mealPlan").getDocuments()
                return try snapshot.documents.map { try Firestore.Decoder().decode(MealPlanEntry.self, from: $0.data()) }
            },
            saveMealPlanEntry: { hid, entry in
                try await households().document(hid).collection("mealPlan").document(entry.id).setData(
                    Firestore.Encoder().encode(entry), merge: true
                )
            },
            deleteMealPlanEntry: { hid, entryID in
                try await households().document(hid).collection("mealPlan").document(entryID).delete()
            },
            documents: { hid in
                let snapshot = try await households().document(hid).collection("documents").getDocuments()
                return try snapshot.documents.map { try Firestore.Decoder().decode(Document.self, from: $0.data()) }
            },
            observeDocuments: { hid in
                AsyncThrowingStream { continuation in
                    let listener = households().document(hid).collection("documents")
                        .order(by: "createdAt", descending: true)
                        .addSnapshotListener { snapshot, error in
                            if let error {
                                continuation.finish(throwing: error)
                                return
                            }
                            let docs = snapshot?.documents.compactMap {
                                try? Firestore.Decoder().decode(Document.self, from: $0.data())
                            } ?? []
                            continuation.yield(docs)
                        }
                    continuation.onTermination = { _ in listener.remove() }
                }
            },
            saveDocument: { hid, doc in
                try await households().document(hid).collection("documents").document(doc.id).setData(
                    Firestore.Encoder().encode(doc), merge: true
                )
            },
            deleteDocument: { hid, docID in
                try await households().document(hid).collection("documents").document(docID).delete()
            },
            careItems: { hid in
                let snapshot = try await households().document(hid).collection("careItems").getDocuments()
                return try snapshot.documents.map { try Firestore.Decoder().decode(CareItem.self, from: $0.data()) }
            },
            saveCareItem: { hid, item in
                try await households().document(hid).collection("careItems").document(item.id).setData(
                    Firestore.Encoder().encode(item), merge: true
                )
            },
            deleteCareItem: { hid, itemID in
                try await households().document(hid).collection("careItems").document(itemID).delete()
            },
            hueConfig: { hid in
                let s = try await households().document(hid).collection("config").document("hue").getDocument()
                guard let d = s.data() else { return nil }
                return try Firestore.Decoder().decode(HueConfig.self, from: d)
            },
            updateHueBridgeIP: { hid, bridgeIP in
                try await households().document(hid).collection("config").document("hue").setData(
                    ["bridgeIP": bridgeIP], merge: true
                )
            },
            saveHueConfig: { hid, config in
                // Full-doc replace (merge: false) so a removed `mock` flag is cleared, not retained.
                try await households().document(hid).collection("config").document("hue").setData(
                    Firestore.Encoder().encode(config)
                )
            },
            activity: { hid in
                let snapshot = try await households().document(hid).collection("activity")
                    .order(by: "createdAt", descending: true)
                    .limit(to: 50)
                    .getDocuments()
                return try snapshot.documents.map { try Firestore.Decoder().decode(ActivityItem.self, from: $0.data()) }
            },
            logActivity: { hid, item in
                try await households().document(hid).collection("activity").document(item.id).setData(
                    Firestore.Encoder().encode(item)
                )
            }
        )
    }()
}

public extension PersistenceClient {
    /// Persist a chore-completion ``ChoreCompletion/Outcome``: the updated chore, any freshly-spawned
    /// next occurrence, and the activity-feed entry. Shared by the Chores tab and the Today dashboard
    /// so completing a chore writes identically from either surface. (Activity logging is best-effort,
    /// matching the original Chores behavior.)
    func writeCompletion(hid: String, _ outcome: ChoreCompletion.Outcome) async throws {
        try await saveChore(hid, outcome.updated)
        if let next = outcome.next { try await saveChore(hid, next) }
        if let activity = outcome.activity { try? await logActivity(hid, activity) }
    }

    /// Persist a care-task ``CareCompletion/Outcome``: the updated ``CareItem`` plus a best-effort
    /// "took care of …" activity entry. Shared by the Home tab and the Today dashboard so marking a
    /// care task done writes identically from either surface (activity logging is best-effort,
    /// matching the chore-completion and calendar/list logging conventions).
    func writeCareDone(hid: String, _ outcome: CareCompletion.Outcome) async throws {
        try await saveCareItem(hid, outcome.updated)
        if let activity = outcome.activity { try? await logActivity(hid, activity) }
    }
}

public extension DependencyValues {
    var persistence: PersistenceClient {
        get { self[PersistenceClient.self] }
        set { self[PersistenceClient.self] = newValue }
    }
}
