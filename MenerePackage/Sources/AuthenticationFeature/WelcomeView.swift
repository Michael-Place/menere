import ComposableArchitecture
import MenereUI
import SwiftUI

@Reducer
public struct WelcomeReducer {
    @ObservableState
    public struct State: Equatable {
        @Presents var destination: Destination.State?

        public init() {}
    }

    public enum Action: Equatable {
        case getStartedTapped
        case logInTapped
        case destination(PresentationAction<Destination.Action>)
    }

    public init() {}

    @Reducer(state: .equatable, action: .equatable)
    public enum Destination {
        case login(LoginReducer)
    }

    public var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case .getStartedTapped:
                return .none
            case .logInTapped:
                state.destination = .login(.init())
                return .none
            case .destination:
                return .none
            }
        }
        .ifLet(\.$destination, action: \.destination)
    }
}

public struct WelcomeView: View {
    @Bindable public var store: StoreOf<WelcomeReducer>

    /// Drives the entrance fade/rise of the wordmark, tagline, and buttons on first appear.
    @State private var appeared = false
    /// View-local tap counter so the primary CTA can fire an impact haptic without reducer state.
    @State private var getStartedTick = 0

    public init(store: StoreOf<WelcomeReducer>) {
        self.store = store
    }

    public var body: some View {
        ZStack {
            WineMeshBackground()
                .ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()

                VStack(spacing: 24) {
                    Image(systemName: "wineglass")
                        .font(.system(size: 52))
                        .foregroundStyle(Color.candleGold)
                        .shadow(color: .black.opacity(0.35), radius: 10, y: 4)

                    VStack(spacing: 14) {
                        Text("Menere")
                            .font(.system(size: 44, design: .serif))
                            .tracking(6)
                            .foregroundStyle(Color.parchment)
                            .shadow(color: .black.opacity(0.4), radius: 8, y: 2)

                        Text("Every bottle, remembered.")
                            .font(.system(.title3, design: .serif).italic())
                            .foregroundStyle(Color.parchment.opacity(0.85))
                            .multilineTextAlignment(.center)
                            .shadow(color: .black.opacity(0.3), radius: 6, y: 1)
                    }
                }
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared ? 0 : 24)

                Spacer()

                VStack(spacing: 16) {
                    Button(action: {
                        getStartedTick += 1
                        store.send(.getStartedTapped)
                    }) {
                        VStack(spacing: 4) {
                            Text("Get Started")
                                .font(.headline)
                            Text("Create your free account")
                                .font(.caption)
                                .opacity(0.8)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.candleGold)
                    .controlSize(.large)

                    Button(action: { store.send(.logInTapped) }) {
                        Text("Already have an account? Sign In")
                            .font(.subheadline)
                            .foregroundStyle(Color.parchment.opacity(0.75))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.bottom, 48)
                .padding(.horizontal, 24)
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared ? 0 : 24)
            }
        }
        .impactHaptic(getStartedTick)
        .onAppear {
            withAnimation(.easeOut(duration: 0.8)) { appeared = true }
        }
        .navigationDestination(
            item: $store.scope(state: \.destination?.login, action: \.destination.login)
        ) { store in
            LoginView(store: store)
        }
    }
}

/// A slowly drifting 3×3 `MeshGradient` in brand wine tones — the "wine swirling in the glass"
/// backdrop for the Welcome screen. A `TimelineView(.animation)` recomputes the inner mesh control
/// points each frame from layered sine waves, so the surface undulates without ever resetting. Kept
/// in deep oxblood/wine with a single muted gold glow so cream/parchment text stays legible.
private struct WineMeshBackground: View {
    private let colors: [Color] = [
        .oxblood, .wine, .oxblood,
        .wine, Color.candleGold.opacity(0.35), .wine,
        .wine, .oxblood, .wine,
    ]

    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            MeshGradient(width: 3, height: 3, points: points(t), colors: colors)
                .background(Color.wine)
                .ignoresSafeArea()
        }
    }

    /// Corners pinned; the four edge-midpoints and the center drift on slow, out-of-phase sines.
    private func points(_ t: TimeInterval) -> [SIMD2<Float>] {
        func wob(_ base: Float, _ amp: Float, _ speed: Double, _ phase: Double) -> Float {
            base + amp * Float(sin(t * speed + phase))
        }
        return [
            SIMD2(0, 0), SIMD2(wob(0.5, 0.06, 0.21, 0), 0), SIMD2(1, 0),
            SIMD2(0, wob(0.5, 0.06, 0.18, 1.3)),
            SIMD2(wob(0.5, 0.09, 0.16, 2.1), wob(0.5, 0.09, 0.14, 3.4)),
            SIMD2(1, wob(0.5, 0.06, 0.19, 4.2)),
            SIMD2(0, 1), SIMD2(wob(0.5, 0.06, 0.17, 5.1), 1), SIMD2(1, 1),
        ]
    }
}

#Preview {
    NavigationStack {
        WelcomeView(
            store: Store(initialState: WelcomeReducer.State()) {
                WelcomeReducer()
            }
        )
    }
}
