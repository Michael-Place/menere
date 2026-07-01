import Foundation

public struct Household: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public var name: String?
    public var ownerUid: String
    public var members: [String]
    public var inviteCode: String
    public var createdAt: Date
    public init(id: String = UUID().uuidString, name: String? = nil, ownerUid: String, members: [String], inviteCode: String, createdAt: Date = Date()) {
        self.id = id; self.name = name; self.ownerUid = ownerUid; self.members = members; self.inviteCode = inviteCode; self.createdAt = createdAt
    }
}
