import Foundation

/// The lifecycle stage of a home project / honey-do item (P30.5). Mirrors the `PackingCategory`
/// pattern: `sortOrder` groups the project detail sections (in-progress first, done last),
/// `displayName`/`icon` drive the status chip. Color is chosen in the view layer (FamilyDomain
/// stays UI-free), keyed off the case.
///
/// Decode-safe on `ListItem.projectStatus` (an optional). A `nil`/unknown value renders under
/// `.planning` via `ListItem.effectiveProjectStatus`.
public enum ProjectStatus: String, Codable, CaseIterable, Sendable, Equatable {
    case planning
    case inProgress
    case done

    public var displayName: String {
        switch self {
        case .planning: "Planning"
        case .inProgress: "In progress"
        case .done: "Done"
        }
    }

    public var icon: String {
        switch self {
        case .planning: "pencil.and.list.clipboard"
        case .inProgress: "hammer.fill"
        case .done: "checkmark.seal.fill"
        }
    }

    /// Order the project sections appear in (active work first, finished last).
    public var sortOrder: Int {
        switch self {
        case .inProgress: 0
        case .planning: 1
        case .done: 2
        }
    }
}
