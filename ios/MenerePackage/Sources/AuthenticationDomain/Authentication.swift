import Dependencies
import DependenciesMacros
import Firebase
import FirebaseAuth
import Sharing
import UserDomain

public typealias UserId = String

public enum CachedAuthState: Equatable, Sendable {
    case unknown
    case hasCachedUser(UserDomain.User)
    case hasFirebaseSession(userId: String)
    case noSession
}

@DependencyClient
public struct Authentication: Sendable {
    public var didChange: @Sendable () -> any AsyncSequence<AuthenticationState, Never> = { EmptySequence() }
    public var signOut: @Sendable () throws -> Void
    public var cachedAuthState: @Sendable () -> CachedAuthState = { .unknown }
}

public enum AuthenticationState: Equatable {
    case authenticated(UserDomain.User)
    case authenticating(UserId)
    case unauthenticated
}

extension AuthenticationState: CustomStringConvertible {
    public var description: String {
        switch self {
        case .authenticated: "authenticated"
        case .authenticating: "authenticating"
        case .unauthenticated: "unauthenticated"
        }
    }
}

extension Authentication: DependencyKey {
    public static var liveValue: Authentication = {
        let repository = AuthenticationRepository()

        return Authentication(
            didChange: { repository.didChange },
            signOut: {
                do {
                    try Auth.auth().signOut()
                } catch let e {
                    throw AuthenticationError.errorSigningOut(e)
                }

                @Shared(.user) var user
                $user.withLock { $0 = nil }
            },
            cachedAuthState: {
                guard FirebaseApp.app() != nil else {
                    return .unknown
                }

                guard let firebaseUser = Auth.auth().currentUser else {
                    return .noSession
                }

                @Shared(.user) var cachedUser
                if let user = cachedUser, user.id == firebaseUser.uid {
                    return .hasCachedUser(user)
                }

                return .hasFirebaseSession(userId: firebaseUser.uid)
            }
        )
    }()
}

public enum AuthenticationError: Error {
    case errorSigningOut(Error)
}

extension DependencyValues {
    public var authentication: Authentication {
        get { self[Authentication.self] }
        set { self[Authentication.self] = newValue }
    }
}

class AuthenticationRepository {
    var didChange: any AsyncSequence<AuthenticationState, Never> {
        _firebaseUser.map { firebaseUser in
            switch firebaseUser?.uid {
            case nil:
                return .unauthenticated
            case .some(let userId):
                return await withCheckedContinuation { continuation in
                    Task {
                        do {
                            let user = try await User.model(for: userId)
                            @Shared(.user) var cachedUser
                            $cachedUser.withLock { $0 = user }
                            continuation.resume(returning: .authenticated(user))
                        } catch {
                            continuation.resume(returning: .authenticating(userId))
                        }
                    }
                }
            }
        }
    }

    private var _firebaseUser: some AsyncSequence<FirebaseAuth.User?, Never> {
        UserSequence()
    }
}

public struct UserSequence: AsyncSequence {
    public typealias Element = FirebaseAuth.User?

    public func makeAsyncIterator() -> AsyncStream<FirebaseAuth.User?>.Iterator {
        AsyncStream { continuation in
            let handle = Auth.auth().addStateDidChangeListener { _, user in
                continuation.yield(user)
            }

            continuation.onTermination = { @Sendable _ in
                Auth.auth().removeStateDidChangeListener(handle)
            }
        }.makeAsyncIterator()
    }
}

public struct EmptySequence<Element>: AsyncSequence {
    public func makeAsyncIterator() -> AsyncStream<Element>.Iterator {
        AsyncStream<Element> { $0.finish() }.makeAsyncIterator()
    }
}
