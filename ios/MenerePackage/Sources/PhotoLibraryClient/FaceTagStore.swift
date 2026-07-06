import Dependencies
import DependenciesMacros
import Foundation

// MARK: - FL4 — device-local face tags
//
// The cluster → family-member mapping is a PRIVATE, on-device fact (which face groups are "Oliver").
// It is stored DEVICE-LOCALLY in a JSON file — NEVER in Firestore / PersistenceClient — so face data
// never leaves the phone. One ``FaceTag`` per member; tagging a second cluster to the same member
// merges the asset ids.

/// A tagged person: a family member plus the library assets whose faces the family said are them.
public struct FaceTag: Sendable, Equatable, Codable, Identifiable {
    /// The `HouseholdMember.id` this face belongs to.
    public let memberID: String
    /// The member's display name at tag time (so the browser can label chips without loading the roster).
    public var memberName: String
    /// The asset `localIdentifier`s the family confirmed are this person (deduped, newest-ish first).
    public var assetIDs: [String]
    /// A cropped sample face JPEG for the "People" chips / roster.
    public var sampleThumbnail: Data?
    public var updatedAt: Date

    public var id: String { memberID }

    public init(
        memberID: String,
        memberName: String,
        assetIDs: [String],
        sampleThumbnail: Data?,
        updatedAt: Date
    ) {
        self.memberID = memberID
        self.memberName = memberName
        self.assetIDs = assetIDs
        self.sampleThumbnail = sampleThumbnail
        self.updatedAt = updatedAt
    }
}

/// Device-local persistence for FL4 face tags. Backed by a JSON file in Application Support; guarded by
/// a lock so the sync closures are safe to call from anywhere. NOT Firestore — this data stays on-device.
@DependencyClient
public struct FaceTagStore: Sendable {
    /// Every tagged person, most-recently-updated first.
    public var all: @Sendable () -> [FaceTag] = { [] }
    /// Tag a discovered cluster to a member (merges asset ids if the member is already tagged).
    public var tag: @Sendable (_ memberID: String, _ memberName: String, _ assetIDs: [String], _ sampleThumbnail: Data?) -> Void
    /// Forget a person's face tag entirely.
    public var untag: @Sendable (_ memberID: String) -> Void
    /// The stored asset ids for one member (empty if untagged).
    public var assetIDs: @Sendable (_ memberID: String) -> [String] = { _ in [] }
}

extension FaceTagStore: DependencyKey {
    public static let liveValue: FaceTagStore = {
        let store = FaceTagFileStore()
        return FaceTagStore(
            all: { store.all() },
            tag: { memberID, name, ids, thumb in store.tag(memberID: memberID, name: name, assetIDs: ids, thumbnail: thumb) },
            untag: { store.untag(memberID: $0) },
            assetIDs: { store.assetIDs(memberID: $0) }
        )
    }()

    /// In-memory (no disk) store for previews/tests.
    public static let previewValue: FaceTagStore = {
        let box = LockedBox<[FaceTag]>([])
        return FaceTagStore(
            all: { box.value.sorted { $0.updatedAt > $1.updatedAt } },
            tag: { memberID, name, ids, thumb in
                box.mutate { tags in
                    var merged = ids
                    if let existing = tags.first(where: { $0.memberID == memberID }) {
                        var s = Set(existing.assetIDs)
                        merged = existing.assetIDs + ids.filter { s.insert($0).inserted }
                    }
                    tags.removeAll { $0.memberID == memberID }
                    tags.append(FaceTag(memberID: memberID, memberName: name, assetIDs: merged, sampleThumbnail: thumb, updatedAt: Date()))
                }
            },
            untag: { id in box.mutate { $0.removeAll { $0.memberID == id } } },
            assetIDs: { id in box.value.first { $0.memberID == id }?.assetIDs ?? [] }
        )
    }()
}

public extension DependencyValues {
    var faceTagStore: FaceTagStore {
        get { self[FaceTagStore.self] }
        set { self[FaceTagStore.self] = newValue }
    }
}

// MARK: - File store

/// The real JSON-file store for face tags. All access is serialized by a lock; reads/writes are
/// best-effort (a corrupt or missing file → an empty list).
private final class FaceTagFileStore: @unchecked Sendable {
    private let lock = NSLock()
    private var cache: [FaceTag]?

    private var url: URL {
        let base = (try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )) ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("FaceTags.json")
    }

    private func load() -> [FaceTag] {
        if let cache { return cache }
        let loaded: [FaceTag]
        if let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode([FaceTag].self, from: data) {
            loaded = decoded
        } else {
            loaded = []
        }
        cache = loaded
        return loaded
    }

    private func persist(_ tags: [FaceTag]) {
        cache = tags
        if let data = try? JSONEncoder().encode(tags) {
            try? data.write(to: url, options: .atomic)
        }
    }

    func all() -> [FaceTag] {
        lock.lock(); defer { lock.unlock() }
        return load().sorted { $0.updatedAt > $1.updatedAt }
    }

    func assetIDs(memberID: String) -> [String] {
        lock.lock(); defer { lock.unlock() }
        return load().first { $0.memberID == memberID }?.assetIDs ?? []
    }

    func tag(memberID: String, name: String, assetIDs: [String], thumbnail: Data?) {
        lock.lock(); defer { lock.unlock() }
        var tags = load()
        var merged = assetIDs
        var thumb = thumbnail
        if let existing = tags.first(where: { $0.memberID == memberID }) {
            var seen = Set(existing.assetIDs)
            merged = existing.assetIDs + assetIDs.filter { seen.insert($0).inserted }
            thumb = thumbnail ?? existing.sampleThumbnail
        }
        tags.removeAll { $0.memberID == memberID }
        tags.append(FaceTag(memberID: memberID, memberName: name, assetIDs: merged, sampleThumbnail: thumb, updatedAt: Date()))
        persist(tags)
    }

    func untag(memberID: String) {
        lock.lock(); defer { lock.unlock() }
        var tags = load()
        tags.removeAll { $0.memberID == memberID }
        persist(tags)
    }
}

/// A tiny lock-guarded box for the preview store.
private final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Value
    init(_ value: Value) { _value = value }
    var value: Value { lock.lock(); defer { lock.unlock() }; return _value }
    func mutate(_ body: (inout Value) -> Void) { lock.lock(); defer { lock.unlock() }; body(&_value) }
}
