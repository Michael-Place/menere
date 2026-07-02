import ComposableArchitecture
import FamilyDomain
import LutronClient
import MenereUI
import PersistenceClient
import SwiftUI

// MARK: - Reducer

/// The Lutron shade pairing state machine (P15-C1). Mirrors `HuePairingReducer`'s shape — discover →
/// physical-button window with a 30s countdown → credential minted → config written → success — but
/// there is no binding step: Lutron's credential is a signed **client certificate** (not an app-key),
/// and shades are controlled directly by zone id, so there are no scenes/sensors to bind here.
///
/// Flow: `discovering → (selectBridge) → linkButton (30s poll) → saving → done | failed`.
@Reducer
public struct LutronPairingReducer {
    @ObservableState
    public struct State: Equatable {
        /// Household id the config is written under.
        public var hid: String
        /// The current Lutron config, present when re-pairing (its bridge is replaced on save). Nil on
        /// the first pairing.
        public var existingConfig: LutronConfig?

        var step: Step = .discovering
        var bridges: [DiscoveredLutronBridge] = []
        var selectedBridge: DiscoveredLutronBridge?
        var countdown: Int = 0
        var errorMessage: String?

        public init(hid: String, existingConfig: LutronConfig? = nil) {
            self.hid = hid
            self.existingConfig = existingConfig
        }

        public enum Step: Equatable {
            case discovering
            case selectBridge
            case linkButton
            case saving
            case done
            case failed
        }
    }

    public enum Action: Equatable {
        case task
        case bridgesDiscovered([DiscoveredLutronBridge])
        case bridgeSelected(DiscoveredLutronBridge)
        case pollPair
        case pollTick
        case paired(LutronPairingResult)
        case pairingFailed(String)
        case retryTapped
        case saved(LutronConfig)
        case cancelTapped
        case delegate(Delegate)

        public enum Delegate: Equatable {
            /// The config that was written — the parent updates its status row from this.
            case finished(LutronConfig)
            case cancelled
        }
    }

    @Dependency(\.lutron) var lutron
    @Dependency(\.persistence) var persistence
    @Dependency(\.continuousClock) var clock

    private enum CancelID { case pairing }

    public init() {}

    public var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case .task:
                state.step = .discovering
                state.errorMessage = nil
                return .run { send in
                    do {
                        let bridges = try await lutron.discoverBridges()
                        await send(.bridgesDiscovered(bridges))
                    } catch {
                        await send(.pairingFailed("Couldn't look for your Lutron bridge. Make sure you're on home Wi-Fi and try again."))
                    }
                }

            case let .bridgesDiscovered(bridges):
                state.bridges = bridges
                if bridges.isEmpty {
                    state.step = .failed
                    state.errorMessage = "No Lutron bridge found on this network. Make sure you're home and on the same Wi-Fi."
                    return .none
                } else if bridges.count == 1 {
                    return .send(.bridgeSelected(bridges[0]))   // auto-advance
                } else {
                    state.step = .selectBridge
                    return .none
                }

            case let .bridgeSelected(bridge):
                state.selectedBridge = bridge
                state.step = .linkButton
                state.countdown = 30
                state.errorMessage = nil
                return .send(.pollPair)

            case .pollPair:
                guard let ip = state.selectedBridge?.ip else { return .none }
                return .run { send in
                    do {
                        let result = try await lutron.pair(ip)
                        await send(.paired(result))
                    } catch let error as LutronError where error == .buttonNotPressed {
                        await send(.pollTick)
                    } catch {
                        await send(.pairingFailed("Couldn't talk to the bridge. Let's try again."))
                    }
                }
                .cancellable(id: CancelID.pairing, cancelInFlight: true)

            case .pollTick:
                state.countdown -= 1
                guard state.countdown > 0 else {
                    state.step = .failed
                    state.errorMessage = "Didn't catch the button in time. Press it again and retry."
                    return .none
                }
                return .run { send in
                    try await clock.sleep(for: .seconds(1))
                    await send(.pollPair)
                }
                .cancellable(id: CancelID.pairing, cancelInFlight: true)

            case let .paired(result):
                guard let bridge = state.selectedBridge else { return .none }
                state.step = .saving
                let config = LutronConfig(
                    bridgeIP: bridge.ip,
                    bridgeId: result.bridgeId ?? bridge.id,
                    name: result.bridgeName ?? bridge.name ?? "Lutron bridge",
                    clientCertPEM: result.clientCertPEM,
                    clientKeyPEM: result.clientKeyPEM,
                    bridgeCAPEM: result.bridgeCAPEM,
                    areaNames: state.existingConfig?.areaNames,
                    mock: nil
                )
                return .run { [hid = state.hid] send in
                    try await persistence.saveLutronConfig(hid, config)
                    await send(.saved(config))
                } catch: { _, send in
                    await send(.pairingFailed("Couldn't save your setup. Let's try again."))
                }

            case let .saved(config):
                state.step = .done
                return .run { send in
                    try? await clock.sleep(for: .seconds(1.2))
                    await send(.delegate(.finished(config)))
                }

            case let .pairingFailed(message):
                state.step = .failed
                state.errorMessage = message
                return .cancel(id: CancelID.pairing)

            case .retryTapped:
                return .send(.task)

            case .cancelTapped:
                return .merge(
                    .cancel(id: CancelID.pairing),
                    .send(.delegate(.cancelled))
                )

            case .delegate:
                return .none
            }
        }
    }
}

// MARK: - View

public struct LutronPairingView: View {
    @Bindable var store: StoreOf<LutronPairingReducer>

    public init(store: StoreOf<LutronPairingReducer>) {
        self.store = store
    }

    public var body: some View {
        NavigationStack {
            Group {
                switch store.step {
                case .discovering: discovering
                case .selectBridge: bridgeList
                case .linkButton: linkButton
                case .saving: saving
                case .done: done
                case .failed: failed
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.familyCanvas)
            .navigationTitle("Lutron shades")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if store.step != .done {
                        Button("Cancel") { store.send(.cancelTapped) }
                    }
                }
            }
        }
        .task { store.send(.task) }
    }

    // MARK: Steps

    private var discovering: some View {
        centered {
            ProgressView().controlSize(.large)
            Text("Looking for your bridge…")
                .font(.headline).foregroundStyle(Color.ink)
            Text("Sniffing the network for a Lutron bridge.")
                .font(.subheadline).foregroundStyle(Color.inkSoft)
        }
    }

    private var bridgeList: some View {
        List {
            Section {
                ForEach(store.bridges) { bridge in
                    Button { store.send(.bridgeSelected(bridge)) } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "wifi.router")
                                .foregroundStyle(Color.bacanGreen)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(bridge.name ?? "Lutron bridge").foregroundStyle(Color.ink)
                                Text(bridge.ip).font(.caption).foregroundStyle(Color.inkSoft)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityIdentifier("lutron-discovered-\(bridge.id)")
                }
            } header: {
                Text("Pick your bridge")
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.familyCanvas)
    }

    private var linkButton: some View {
        centered {
            Image(systemName: "button.programmable")
                .font(.system(size: 56)).foregroundStyle(Color.bacanGreen)
            Text("Press the button on the bridge")
                .font(.title3.bold()).foregroundStyle(Color.ink)
                .multilineTextAlignment(.center)
            Text("Press the small black button on the back of your Lutron bridge. I'll grab the handshake automatically.")
                .font(.subheadline).foregroundStyle(Color.inkSoft)
                .multilineTextAlignment(.center)
            Text("\(store.countdown)s")
                .font(.system(.title2, design: .rounded).weight(.semibold))
                .foregroundStyle(Color.bacanGreen)
                .contentTransition(.numericText())
                .monospacedDigit()
            ProgressView().padding(.top, 4)
        }
    }

    private var saving: some View {
        centered {
            ProgressView().controlSize(.large)
            Text("Saving your setup…")
                .font(.headline).foregroundStyle(Color.ink)
        }
    }

    private var done: some View {
        centered {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 56)).foregroundStyle(Color.bacanGreen)
            Text("The shades are connected.")
                .font(.title3.bold()).foregroundStyle(Color.ink)
        }
    }

    private var failed: some View {
        centered {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 48)).foregroundStyle(Color.terracotta)
            Text(store.errorMessage ?? "Something went sideways.")
                .font(.subheadline).foregroundStyle(Color.inkSoft)
                .multilineTextAlignment(.center)
            Button {
                store.send(.retryTapped)
            } label: {
                Text("Try again").frame(maxWidth: 220)
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.bacanGreen)
        }
    }

    private func centered<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 12) { content() }
            .padding(32)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
