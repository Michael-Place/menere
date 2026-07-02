import ComposableArchitecture
import FamilyDomain
import HueClient
import MenereUI
import PersistenceClient
import SwiftUI

// MARK: - Reducer

/// The bridge-pairing / re-pairing state machine (P12-C2). Ported from NowSpinning's pairing flow
/// and extended with the in-sheet *binding* step that gives the new bridge's scenes/sensors their
/// family meanings. First pairing writes a config from scratch; re-pairing carries the old config's
/// ritual labels + sensor labels forward, re-binding them to the new bridge's IDs by name.
///
/// Flow: `discovering → (selectBridge) → linkButton (30s poll) → binding → saving → done`.
@Reducer
public struct HuePairingReducer {
    @ObservableState
    public struct State: Equatable {
        /// Household id the config is written under.
        public var hid: String
        /// The current config, present whenever the household already has ≥1 paired bridge. Supplies
        /// the other bridges to preserve, ritual labels + sensorNames to carry forward, and
        /// `roomOwners`. Nil only on the very first pairing.
        public var existingConfig: HueConfig?
        /// The bridge being **re-paired** (its old entry + rituals + sensors are replaced on save).
        /// Nil when *adding* a brand-new bridge (append) or first-pairing.
        public var repairingBridgeId: String?

        var step: Step = .discovering
        var bridges: [DiscoveredBridge] = []
        var selectedBridge: DiscoveredBridge?
        var applicationKey: String?
        var bridgeId: String?
        /// The freshly-paired bridge's friendly name (from `/config`), stored in the config.
        var bridgeName: String?
        var countdown: Int = 0
        var errorMessage: String?

        // Binding step
        var scenes: [HueScene] = []
        var ritualBindings: [RitualBinding] = []
        var sensorDrafts: [SensorDraft] = []
        /// Ritual key whose scene picker is open (nil = closed).
        var pickingSceneFor: String?

        public init(hid: String, existingConfig: HueConfig? = nil, repairingBridgeId: String? = nil) {
            self.hid = hid
            self.existingConfig = existingConfig
            self.repairingBridgeId = repairingBridgeId
        }

        /// Bridge ids the discovery list must hide — every already-paired bridge EXCEPT the one being
        /// re-paired (you can't pair the same bridge twice, but you can re-pair it).
        var excludedBridgeIds: Set<String> {
            Set((existingConfig?.bridges ?? []).map(\.bridgeId)).subtracting(repairingBridgeId.map { [$0] } ?? [])
        }

        public enum Step: Equatable {
            case discovering
            case selectBridge
            case linkButton
            case connecting     // key minted → fetching bridge id + scenes/sensors
            case binding
            case saving
            case done
            case failed
        }
    }

    /// One ritual's binding as the user shapes it in the sheet.
    public struct RitualBinding: Equatable, Identifiable, Sendable {
        public var key: String
        public var label: String
        public var sceneId: String?
        public var groupId: String?
        /// True when the current scene came from auto-match (vs. a manual pick) — drives the
        /// "auto-matched, tap to change" affordance.
        public var autoMatched: Bool
        public var id: String { key }
    }

    /// One temperature sensor's labeling draft.
    public struct SensorDraft: Equatable, Identifiable, Sendable {
        public var id: String
        public var bridgeName: String
        public var label: String
    }

    public enum Action: Equatable {
        case task
        case bridgesDiscovered([DiscoveredBridge])
        case bridgeSelected(DiscoveredBridge)
        case pollAuthenticate
        case pollTick
        case keyMinted(String)
        case bindingDataLoaded(bridgeId: String, bridgeName: String, scenes: [HueScene], sensors: [HueSensorInfo])
        case pairingFailed(String)
        case retryTapped
        case sceneSelected(ritualKey: String, scene: HueScene)
        case pickSceneTapped(ritualKey: String?)
        case sensorLabelChanged(id: String, text: String)
        case saveTapped
        case saved(HueConfig)
        case cancelTapped
        case delegate(Delegate)

        public enum Delegate: Equatable {
            /// The full config that was written — the parent updates its status row from this.
            case finished(HueConfig)
            case cancelled
        }
    }

    @Dependency(\.hue) var hue
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
                        let bridges = try await hue.discoverBridges()
                        await send(.bridgesDiscovered(bridges))
                    } catch {
                        await send(.pairingFailed("Couldn't reach Hue to find your bridge. Make sure you're on home Wi-Fi and try again."))
                    }
                }

            case let .bridgesDiscovered(discovered):
                // Hide bridges already paired (can't pair the same bridge twice); a re-pair keeps its
                // own bridge visible.
                let excluded = state.excludedBridgeIds
                let bridges = discovered.filter { !excluded.contains($0.id) }
                state.bridges = bridges
                if bridges.isEmpty {
                    state.step = .failed
                    state.errorMessage = discovered.isEmpty
                        ? "No Hue bridge found on this network. Make sure you're home and on the same Wi-Fi."
                        : "Every bridge on this network is already paired."
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
                return .send(.pollAuthenticate)

            case .pollAuthenticate:
                guard let ip = state.selectedBridge?.ip else { return .none }
                return .run { send in
                    do {
                        let key = try await hue.authenticate(ip)
                        await send(.keyMinted(key))
                    } catch let error as HueError where error == .linkButtonNotPressed {
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
                    await send(.pollAuthenticate)
                }
                .cancellable(id: CancelID.pairing, cancelInFlight: true)

            case let .keyMinted(key):
                state.applicationKey = key
                state.step = .connecting
                guard let ip = state.selectedBridge?.ip else { return .none }
                return .run { send in
                    do {
                        let info = try await hue.bridgeInfo(ip, key)
                        let probe = HueBridgeConfig(bridgeId: info.id, bridgeIP: ip, applicationKey: key)
                        async let scenes = hue.scenes(probe)
                        async let sensors = hue.sensors(probe)
                        await send(.bindingDataLoaded(
                            bridgeId: info.id,
                            bridgeName: info.name,
                            scenes: (try? await scenes) ?? [],
                            sensors: (try? await sensors) ?? []
                        ))
                    } catch {
                        await send(.pairingFailed("Paired, but couldn't read the bridge. Let's try again."))
                    }
                }
                .cancellable(id: CancelID.pairing, cancelInFlight: true)

            case let .bindingDataLoaded(bridgeId, bridgeName, scenes, sensors):
                state.bridgeId = bridgeId
                state.bridgeName = bridgeName
                state.scenes = scenes
                state.ritualBindings = Self.initialBindings(
                    existing: state.existingConfig, repairingBridgeId: state.repairingBridgeId, scenes: scenes
                )
                state.sensorDrafts = Self.initialSensorDrafts(sensors: sensors, existing: state.existingConfig)
                state.step = .binding
                return .none

            case let .pairingFailed(message):
                state.step = .failed
                state.errorMessage = message
                return .cancel(id: CancelID.pairing)

            case .retryTapped:
                return .send(.task)

            case let .sceneSelected(ritualKey, scene):
                if let i = state.ritualBindings.firstIndex(where: { $0.key == ritualKey }) {
                    state.ritualBindings[i].sceneId = scene.id
                    state.ritualBindings[i].groupId = scene.groupId
                    state.ritualBindings[i].autoMatched = false
                }
                state.pickingSceneFor = nil
                return .none

            case let .pickSceneTapped(ritualKey):
                state.pickingSceneFor = ritualKey
                return .none

            case let .sensorLabelChanged(id, text):
                if let i = state.sensorDrafts.firstIndex(where: { $0.id == id }) {
                    state.sensorDrafts[i].label = text
                }
                return .none

            case .saveTapped:
                guard let config = Self.buildConfig(state) else { return .none }
                state.step = .saving
                return .run { [hid = state.hid] send in
                    try await persistence.saveHueConfig(hid, config)
                    await send(.saved(config))
                } catch: { _, send in
                    await send(.pairingFailed("Couldn't save your setup. Let's try again."))
                }

            case let .saved(config):
                state.step = .done
                return .run { send in
                    try? await clock.sleep(for: .seconds(1.2))   // let the "connected" beat land
                    await send(.delegate(.finished(config)))
                }

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

    // MARK: - Pure binding helpers

    /// The rituals to offer at binding time for the bridge being paired, auto-matched against its
    /// scenes. Multi-bridge rules (P12-C3):
    ///  • **Re-pair** carries forward the re-paired bridge's own rituals (label = meaning survives;
    ///    scene/group IDs are re-bound by name).
    ///  • A **standard** ritual (bedtime/dinner) is offered only when it isn't already bound on
    ///    *another* bridge — so adding a second bridge offers the still-unbound standards (exactly
    ///    Michael's flow: Bedtime, unbound downstairs, gets offered against the upstairs bridge).
    static func initialBindings(existing: HueConfig?, repairingBridgeId: String?, scenes: [HueScene]) -> [RitualBinding] {
        let allRituals = existing?.rituals ?? []
        // Standard rituals owned by a bridge we're NOT re-pairing are off-limits here.
        let ownedElsewhere = Set(allRituals.filter { $0.bridgeId != repairingBridgeId }.map(\.key))

        var offered: [(key: String, label: String)] = allRituals
            .filter { repairingBridgeId != nil && $0.bridgeId == repairingBridgeId }
            .map { ($0.key, $0.label) }
        for standard in HueBindingMatch.standardRituals
        where !offered.contains(where: { $0.key == standard.key }) && !ownedElsewhere.contains(standard.key) {
            offered.append(standard)
        }

        return offered.map { ritual in
            let match = HueBindingMatch.matchScene(key: ritual.key, label: ritual.label, in: scenes)
            return RitualBinding(
                key: ritual.key,
                label: ritual.label,
                sceneId: match?.id,
                groupId: match?.groupId,
                autoMatched: match != nil
            )
        }
    }

    /// A labeling draft per temperature sensor, prefilled from the old config when re-pairing.
    static func initialSensorDrafts(sensors: [HueSensorInfo], existing: HueConfig?) -> [SensorDraft] {
        sensors.map { sensor in
            SensorDraft(
                id: sensor.id,
                bridgeName: sensor.name,
                label: HueBindingMatch.prefillSensorLabel(for: sensor.name, from: existing)
            )
        }
    }

    /// Assemble the config doc to write — **appending** this bridge to any existing config (or
    /// replacing it on a re-pair), never clobbering the OTHER bridges' entries. Only fully-bound
    /// rituals become `HueRitual`s (an unbound ritual simply won't render on Today), each scoped to
    /// this bridge's id. `sensorNames`/`sensorLabels` are nested under the bridge id. Other bridges'
    /// rituals + sensor maps + `roomOwners` are preserved verbatim.
    static func buildConfig(_ state: State) -> HueConfig? {
        guard let bridgeId = state.bridgeId,
              let ip = state.selectedBridge?.ip,
              let key = state.applicationKey else { return nil }

        // Ids whose old entries this pairing supersedes: the freshly-paired id (re-pair, same id) and
        // the explicitly re-paired id (re-pair, new id).
        let supersededIds: Set<String> = Set([bridgeId, state.repairingBridgeId].compactMap { $0 })

        let newBridge = HueBridgeConfig(bridgeId: bridgeId, bridgeIP: ip, applicationKey: key, name: state.bridgeName, mock: nil)
        var bridges = (state.existingConfig?.bridges ?? []).filter { !supersededIds.contains($0.bridgeId) }
        bridges.append(newBridge)

        // Preserve other bridges' rituals; add this bridge's newly-bound ones (scoped to its id).
        var rituals = (state.existingConfig?.rituals ?? []).filter { !supersededIds.contains($0.bridgeId) }
        rituals += state.ritualBindings.compactMap { binding in
            guard let sceneId = binding.sceneId, let groupId = binding.groupId else { return nil }
            return HueRitual(key: binding.key, label: binding.label, sceneId: sceneId, groupId: groupId, bridgeId: bridgeId)
        }

        // Sensor maps: keep other bridges' entries; (re)write this bridge's under its id.
        var sensorLabels = state.existingConfig?.sensorLabels ?? [:]
        var sensorNames = state.existingConfig?.sensorNames ?? [:]
        for id in supersededIds { sensorLabels.removeValue(forKey: id); sensorNames.removeValue(forKey: id) }

        var thisLabels: [String: String] = [:]
        var thisNames: [String: String] = [:]
        for draft in state.sensorDrafts {
            thisNames[draft.id] = draft.bridgeName
            let trimmed = draft.label.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { thisLabels[draft.id] = trimmed }
        }
        if !thisLabels.isEmpty { sensorLabels[bridgeId] = thisLabels }
        if !thisNames.isEmpty { sensorNames[bridgeId] = thisNames }

        return HueConfig(
            bridges: bridges,
            rituals: rituals,
            roomOwners: state.existingConfig?.roomOwners,
            sensorLabels: sensorLabels,
            sensorNames: sensorNames.isEmpty ? nil : sensorNames
        )
    }
}

// MARK: - View

public struct HuePairingView: View {
    @Bindable var store: StoreOf<HuePairingReducer>

    public init(store: StoreOf<HuePairingReducer>) {
        self.store = store
    }

    public var body: some View {
        NavigationStack {
            Group {
                switch store.step {
                case .discovering: discovering
                case .selectBridge: bridgeList
                case .linkButton: linkButton
                case .connecting: connecting
                case .binding: binding
                case .saving: connecting
                case .done: done
                case .failed: failed
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.familyCanvas)
            .navigationTitle("Philips Hue")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if store.step != .done {
                        Button("Cancel") { store.send(.cancelTapped) }
                    }
                }
            }
            .sheet(isPresented: Binding(
                get: { store.pickingSceneFor != nil },
                set: { if !$0 { store.send(.pickSceneTapped(ritualKey: nil)) } }
            )) {
                scenePicker
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
            Text("Sniffing the network for a Hue bridge.")
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
                                Text("Hue bridge").foregroundStyle(Color.ink)
                                Text(bridge.ip).font(.caption).foregroundStyle(Color.inkSoft)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                        }
                    }
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
            Text("Tap the big round button on top of your Hue bridge. I'll grab the handshake automatically.")
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

    private var connecting: some View {
        centered {
            ProgressView().controlSize(.large)
            Text(store.step == .saving ? "Saving your setup…" : "Getting the lay of the house…")
                .font(.headline).foregroundStyle(Color.ink)
        }
    }

    private var binding: some View {
        List {
            Section {
                ForEach(store.ritualBindings) { ritualRow($0) }
            } header: {
                Text("Rituals")
            } footer: {
                Text("Pick which scene each button runs. Leave one unset and it just won't show on Today.")
            }

            if !store.sensorDrafts.isEmpty {
                Section {
                    ForEach(store.sensorDrafts) { sensorRow($0) }
                } header: {
                    Text("Room thermometers")
                } footer: {
                    Text("Name a sensor to show its temperature on Today. Leave it blank to hide it.")
                }
            }

            Section {
                Button {
                    store.send(.saveTapped)
                } label: {
                    Text("Save").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.bacanGreen)
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.familyCanvas)
    }

    private func ritualRow(_ binding: HuePairingReducer.RitualBinding) -> some View {
        Button {
            store.send(.pickSceneTapped(ritualKey: binding.key))
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(binding.label).foregroundStyle(Color.ink)
                    if let sceneId = binding.sceneId,
                       let scene = store.scenes.first(where: { $0.id == sceneId }) {
                        Text(binding.autoMatched ? "\(scene.name) · auto-matched" : scene.name)
                            .font(.caption).foregroundStyle(Color.inkSoft)
                    } else {
                        Text("needs a scene")
                            .font(.caption).foregroundStyle(Color.terracotta)
                    }
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func sensorRow(_ draft: HuePairingReducer.SensorDraft) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(draft.bridgeName).font(.caption).foregroundStyle(Color.inkSoft)
            TextField("Label (e.g. Oliver's room)", text: Binding(
                get: { draft.label },
                set: { store.send(.sensorLabelChanged(id: draft.id, text: $0)) }
            ))
            .foregroundStyle(Color.ink)
        }
    }

    private var scenePicker: some View {
        NavigationStack {
            List {
                ForEach(store.scenes) { scene in
                    Button {
                        if let key = store.pickingSceneFor {
                            store.send(.sceneSelected(ritualKey: key, scene: scene))
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(scene.name).foregroundStyle(Color.ink)
                            if let groupId = scene.groupId {
                                Text("Room \(groupId)").font(.caption).foregroundStyle(Color.inkSoft)
                            }
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.familyCanvas)
            .navigationTitle("Choose a scene")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { store.send(.pickSceneTapped(ritualKey: nil)) }
                }
            }
        }
    }

    private var done: some View {
        centered {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 56)).foregroundStyle(Color.bacanGreen)
            Text("The house is connected.")
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
