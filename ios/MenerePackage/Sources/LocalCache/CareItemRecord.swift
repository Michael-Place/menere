import Foundation
import FamilyDomain
import SQLiteData

/// H2 — the local SQLite mirror of a ``FamilyDomain/CareItem``.
///
/// One row per care item (plant / pet / house zone), scoped by `hid` so a device that ever belonged
/// to more than one household never bleeds rows across families. The rich sub-structures (`tasks`,
/// `speciesProfile`) are stored as JSON `TEXT` columns — they're read/written as whole blobs, never
/// queried column-wise, so denormalizing them keeps the schema flat and the mapping trivial. Dates
/// are stored as epoch seconds (`REAL`).
///
/// The table is defined once in ``LocalCacheDatabase`` migrations and must never be edited in place
/// (only additively, via new migrations) once shipped.
@Table("careItemRecords")
public struct CareItemRecord: Identifiable, Equatable, Sendable {
    /// Primary key — the CareItem's own id (a globally-unique UUID), so it is safe as the sole PK.
    public var id: String
    /// Household scope. Every read filters on this; every write stamps it.
    public var hid: String
    public var kind: String
    public var name: String
    public var iconSymbol: String
    public var location: String?
    /// Epoch seconds.
    public var createdAt: Double
    public var photoPath: String?
    public var stickerPath: String?
    public var species: String?
    public var speciesLatin: String?
    public var careNotes: String?
    public var careContext: String?
    public var familyNotes: String?
    public var lightLevel: String?
    public var breed: String?
    /// Epoch seconds, pet-only.
    public var birthday: Double?
    public var vetName: String?
    public var vetPhone: String?
    /// JSON of `[CareTask]`.
    public var tasksJSON: String
    /// JSON of `SpeciesProfile?` (nil column when absent).
    public var speciesProfileJSON: String?
}

// MARK: - Mapping CareItem <-> CareItemRecord

extension CareItemRecord {
    private static let encoder = JSONEncoder()
    private static let decoder = JSONDecoder()

    /// Build a cache row from a domain ``CareItem`` for a given household.
    public init(_ item: CareItem, hid: String) {
        let tasksData = (try? Self.encoder.encode(item.tasks)) ?? Data("[]".utf8)
        let profileData = item.speciesProfile.flatMap { try? Self.encoder.encode($0) }
        self.init(
            id: item.id,
            hid: hid,
            kind: item.kind.rawValue,
            name: item.name,
            iconSymbol: item.iconSymbol,
            location: item.location,
            createdAt: item.createdAt.timeIntervalSince1970,
            photoPath: item.photoPath,
            stickerPath: item.stickerPath,
            species: item.species,
            speciesLatin: item.speciesLatin,
            careNotes: item.careNotes,
            careContext: item.careContext,
            familyNotes: item.familyNotes,
            lightLevel: item.lightLevel,
            breed: item.breed,
            birthday: item.birthday?.timeIntervalSince1970,
            vetName: item.vetName,
            vetPhone: item.vetPhone,
            tasksJSON: String(decoding: tasksData, as: UTF8.self),
            speciesProfileJSON: profileData.map { String(decoding: $0, as: UTF8.self) }
        )
    }

    /// Rehydrate the domain ``CareItem`` from a cache row.
    public var careItem: CareItem {
        let tasks = (try? Self.decoder.decode([CareTask].self, from: Data(tasksJSON.utf8))) ?? []
        let profile = speciesProfileJSON
            .flatMap { try? Self.decoder.decode(SpeciesProfile.self, from: Data($0.utf8)) }
        return CareItem(
            id: id,
            kind: CareKind(rawValue: kind) ?? .house,
            name: name,
            iconSymbol: iconSymbol,
            location: location,
            tasks: tasks,
            createdAt: Date(timeIntervalSince1970: createdAt),
            photoPath: photoPath,
            stickerPath: stickerPath,
            species: species,
            speciesLatin: speciesLatin,
            careNotes: careNotes,
            careContext: careContext,
            familyNotes: familyNotes,
            lightLevel: lightLevel,
            breed: breed,
            birthday: birthday.map { Date(timeIntervalSince1970: $0) },
            vetName: vetName,
            vetPhone: vetPhone,
            speciesProfile: profile
        )
    }
}
