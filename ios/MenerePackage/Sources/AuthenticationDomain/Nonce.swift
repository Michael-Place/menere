import CryptoKit
import Dependencies
import DependenciesMacros
import Foundation

@DependencyClient
public struct NonceGenerator {
    public var nonce: () -> Nonce = { .empty }

    public struct Nonce: Equatable {
        public let raw: String
        public let encrypted: String

        public init(_ raw: String) {
            self.raw = raw
            self.encrypted = raw.sha256
        }

        public static let empty = Nonce("nonce")
    }
}

public extension DependencyValues {
    var nonceGenerator: NonceGenerator {
        get { self[NonceGenerator.self] }
        set { self[NonceGenerator.self] = newValue }
    }
}

extension NonceGenerator: DependencyKey {
    public static let liveValue = NonceGenerator(nonce: {
        var randomBytes = [UInt8](repeating: 0, count: 32)

        let errorCode = SecRandomCopyBytes(kSecRandomDefault, randomBytes.count, &randomBytes)
        if errorCode != errSecSuccess {
            fatalError("Unable to generate nonce. SecRandomCopyBytes failed with OSStatus \(errorCode)")
        }

        let charset: [Character] =
            Array("0123456789ABCDEFGHIJKLMNOPQRSTUVXYZabcdefghijklmnopqrstuvwxyz-._")

        return Nonce(String(randomBytes.map { byte in
            charset[Int(byte) % charset.count]
        }))
    })
}

extension String {
    var sha256: String {
        SHA256.hash(data: Data(self.utf8))
            .compactMap { String(format: "%02x", $0) }
            .joined()
    }
}
