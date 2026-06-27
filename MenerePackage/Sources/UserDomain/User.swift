import FirebaseFirestore
import Sharing

public struct User: Codable, Equatable, Sendable {
    public let id: String
    public var displayName: String
    public var createdAt: Date

    public init(
        id: String,
        displayName: String = "",
        createdAt: Date = Date()
    ) {
        self.id = id
        self.displayName = displayName
        self.createdAt = createdAt
    }
}

// MARK: - Firestore

public extension User {
    static var collection: CollectionReference {
        Firestore.firestore().collection("users")
    }

    static func model(for userId: String) async throws -> User {
        let snapshot = try await collection.document(userId).getDocument()
        guard let data = snapshot.data() else {
            throw UserError.notFound(userId)
        }
        return try Firestore.Decoder().decode(User.self, from: data)
    }

    func save() async throws {
        try await Self.collection.document(id).setData(
            Firestore.Encoder().encode(self),
            merge: true
        )
    }
}

public enum UserError: Error {
    case notFound(String)
}

// MARK: - Shared Key

extension SharedKey where Self == FileStorageKey<User?>.Default {
    public static var user: Self {
        Self[.fileStorage(.documentsDirectory.appending(component: "user.json")), default: nil]
    }
}
