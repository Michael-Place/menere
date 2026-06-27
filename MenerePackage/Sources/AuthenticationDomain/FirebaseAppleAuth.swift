import AuthenticationServices
import Dependencies
import DependenciesMacros
import FirebaseAuth

@DependencyClient
public struct FirebaseAppleAuth: DependencyKey {
    public var signIn: (_ authorization: ASAuthorization, _ nonce: String) async throws -> AuthDataResult

    public static let liveValue: FirebaseAppleAuth = .init(
        signIn: { authorization, nonce in
            guard let appleIDCredential = authorization.credential as? ASAuthorizationAppleIDCredential,
                  let appleIDToken = appleIDCredential.identityToken
            else {
                throw FirebaseAppleAuthError.unableToFetchIdentityToken
            }

            guard let idTokenString = String(data: appleIDToken, encoding: .utf8) else {
                throw FirebaseAppleAuthError.unableToSerializeTokenStringFromData(appleIDToken)
            }

            let credential = OAuthProvider.appleCredential(
                withIDToken: idTokenString,
                rawNonce: nonce,
                fullName: appleIDCredential.fullName
            )

            return try await Auth.auth().signIn(with: credential)
        }
    )
}

public enum FirebaseAppleAuthError: Error {
    case unableToFetchIdentityToken
    case unableToSerializeTokenStringFromData(_ data: Data)
    case unableToSignIn(_ localizedDescription: String)
}

public extension DependencyValues {
    var firebaseAppleAuth: FirebaseAppleAuth {
        get { self[FirebaseAppleAuth.self] }
        set { self[FirebaseAppleAuth.self] = newValue }
    }
}
