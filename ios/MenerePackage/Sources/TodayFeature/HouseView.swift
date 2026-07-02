import ComposableArchitecture
import FamilyDomain
import HueClient
import MenereUI
import SwiftUI

/// The granular House control surface (P12-C4), pushed from Today's "The house ›" card. A utility
/// screen — familyCanvas/familySurface + rounded type, `.pressable` where natural, but no celebration
/// motion. Owns its own `HouseReducer` store (seeded from the already-loaded snapshot) so it's fully
/// decoupled from `TodayReducer`.
public struct HouseView: View {
    @Bindable private var store: StoreOf<HouseReducer>

    /// Seed from Today's live snapshot so the screen renders instantly, then refresh on appear.
    public init(config: HueConfig, members: [HouseholdMember], bridges: [BridgeSnapshot]) {
        _store = Bindable(
            wrappedValue: Store(
                initialState: HouseReducer.State(config: config, members: members, bridges: bridges)
            ) { HouseReducer() }
        )
    }

    /// Test/preview seam — inject a store directly.
    public init(store: StoreOf<HouseReducer>) {
        _store = Bindable(wrappedValue: store)
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                ForEach(store.bridges) { snap in
                    bridgeSection(snap)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 12)
        }
        .background(Color.familyCanvas)
        .navigationTitle("The house")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    store.send(.refresh)
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .accessibilityIdentifier("house-refresh")
            }
        }
        .task { store.send(.task) }
        .refreshable { await store.send(.refresh).finish() }
    }

    // MARK: Bridge section (rooms then zones)

    @ViewBuilder
    private func bridgeSection(_ snap: BridgeSnapshot) -> some View {
        let rooms = snap.rooms.filter { $0.type == "Room" }.sorted { $0.name < $1.name }
        let zones = snap.rooms.filter { $0.type == "Zone" }.sorted { $0.name < $1.name }
        VStack(alignment: .leading, spacing: 12) {
            if store.isMultiBridge {
                Text(snap.bridge.displayName)
                    .familyTitle(.headline)
                    .foregroundStyle(Color.ink)
                    .accessibilityIdentifier("house-bridge-\(snap.bridge.bridgeId)")
            }
            if !rooms.isEmpty {
                subsection("Rooms", rooms: rooms, bridgeId: snap.bridge.bridgeId)
            }
            if !zones.isEmpty {
                subsection("Zones", rooms: zones, bridgeId: snap.bridge.bridgeId)
            }
        }
    }

    private func subsection(_ title: String, rooms: [HueRoom], bridgeId: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title.uppercased())
                .font(.system(.caption, design: .rounded).weight(.semibold))
                .foregroundStyle(Color.inkSoft)
                .padding(.bottom, 6)
            VStack(spacing: 0) {
                ForEach(Array(rooms.enumerated()), id: \.element.id) { idx, room in
                    roomRow(room, bridgeId: bridgeId)
                    if idx < rooms.count - 1 {
                        Divider().overlay(Color.inkSoft.opacity(0.15)).padding(.leading, 16)
                    }
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.familySurface)
            )
        }
    }

    // MARK: Room row

    private func lightsInRoom(_ roomId: String, bridgeId: String) -> [HueLight] {
        guard let snap = store.bridges.first(where: { $0.bridge.bridgeId == bridgeId }),
              let room = snap.rooms.first(where: { $0.id == roomId }) else { return [] }
        let ids = Set(room.lightIds)
        return snap.lights.filter { ids.contains($0.id) }
    }

    private func owner(ofRoom roomId: String) -> HouseholdMember? {
        guard let uid = store.config.roomOwners?[roomId] else { return nil }
        return store.members.first { $0.id == uid }
    }

    private func roomRow(_ room: HueRoom, bridgeId: String) -> some View {
        let lights = lightsInRoom(room.id, bridgeId: bridgeId)
        let onCount = lights.filter(\.isOn).count
        return HStack(spacing: 12) {
            NavigationLink {
                RoomDetailView(store: store, bridgeId: bridgeId, roomId: room.id)
            } label: {
                HStack(spacing: 10) {
                    if let owner = owner(ofRoom: room.id) {
                        Circle()
                            .fill(memberColor(owner))
                            .frame(width: 10, height: 10)
                            .accessibilityIdentifier("house-room-owner-\(room.id)")
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(room.name)
                            .font(.system(.body, design: .rounded).weight(.medium))
                            .foregroundStyle(Color.ink)
                        Text("\(onCount) of \(lights.count) on")
                            .font(.system(.caption, design: .rounded))
                            .foregroundStyle(Color.inkSoft)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.inkSoft.opacity(0.6))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Toggle("", isOn: Binding(
                get: { room.anyOn },
                set: { _ in store.send(.toggleRoom(bridgeId: bridgeId, roomId: room.id)) }
            ))
            .labelsHidden()
            .tint(Color.bacanGreen)
            .accessibilityIdentifier("house-room-toggle-\(room.id)")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .accessibilityIdentifier("house-room-\(room.id)")
    }

    private func memberColor(_ member: HouseholdMember) -> Color {
        let rgb = member.color.rgb
        return Color(red: rgb.red, green: rgb.green, blue: rgb.blue)
    }
}

// MARK: - Room detail

/// One room's full controls: a group brightness slider, a scene menu, then the member lights (each
/// with a power toggle + brightness slider; unreachable lights dim and disable). Reads live state from
/// the shared `HouseReducer` store by (bridgeId, roomId) so every optimistic edit reflects instantly.
struct RoomDetailView: View {
    @Bindable var store: StoreOf<HouseReducer>
    let bridgeId: String
    let roomId: String

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let room = currentRoom {
                    groupCard(room)
                    let scenes = scenesForRoom
                    if !scenes.isEmpty { sceneCard(scenes) }
                    lightsCard
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 12)
        }
        .background(Color.familyCanvas)
        .navigationTitle(currentRoom?.name ?? "Room")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: Live lookups (read observed `store.bridges`)

    private var currentSnapshot: BridgeSnapshot? {
        store.bridges.first { $0.bridge.bridgeId == bridgeId }
    }

    private var currentRoom: HueRoom? {
        currentSnapshot?.rooms.first { $0.id == roomId }
    }

    private var lightsInRoom: [HueLight] {
        guard let snap = currentSnapshot, let room = snap.rooms.first(where: { $0.id == roomId }) else { return [] }
        let ids = Set(room.lightIds)
        return snap.lights.filter { ids.contains($0.id) }
    }

    private var scenesForRoom: [HueScene] {
        (currentSnapshot?.scenes ?? [])
            .filter { $0.groupId == roomId }
            .sorted { $0.name < $1.name }
    }

    // MARK: Group brightness

    private func groupCard(_ room: HueRoom) -> some View {
        card {
            HStack {
                Text("Brightness")
                    .font(.system(.subheadline, design: .rounded).weight(.semibold))
                    .foregroundStyle(Color.ink)
                Spacer()
                Toggle("", isOn: Binding(
                    get: { room.anyOn },
                    set: { _ in store.send(.toggleRoom(bridgeId: bridgeId, roomId: roomId)) }
                ))
                .labelsHidden()
                .tint(Color.bacanGreen)
                .accessibilityIdentifier("house-detail-room-toggle")
            }
            Slider(
                value: Binding(
                    get: { HueBrightness.percent(fromBri: room.brightness) ?? 0 },
                    set: { store.send(.roomBrightnessChanged(bridgeId: bridgeId, roomId: roomId, percent: $0)) }
                ),
                in: 0...100
            )
            .tint(Color.bacanGreen)
            .accessibilityIdentifier("house-detail-room-slider")
        }
    }

    // MARK: Scenes

    private func sceneCard(_ scenes: [HueScene]) -> some View {
        card {
            Text("Scenes")
                .font(.system(.subheadline, design: .rounded).weight(.semibold))
                .foregroundStyle(Color.ink)
            FlowRow {
                ForEach(scenes) { scene in
                    Button {
                        store.send(.recallScene(bridgeId: bridgeId, groupId: roomId, sceneId: scene.id))
                    } label: {
                        Text(scene.name)
                            .font(.system(.subheadline, design: .rounded).weight(.semibold))
                            .foregroundStyle(Color.bacanGreen)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 9)
                            .background(Capsule(style: .continuous).fill(Color.bacanGreen.opacity(0.14)))
                    }
                    .buttonStyle(.pressable)
                    .accessibilityIdentifier("house-scene-\(scene.id)")
                }
            }
        }
        .successHaptic(store.recalledScene)
    }

    // MARK: Lights

    private var lightsCard: some View {
        let lights = lightsInRoom
        return card {
            Text("Lights")
                .font(.system(.subheadline, design: .rounded).weight(.semibold))
                .foregroundStyle(Color.ink)
            ForEach(Array(lights.enumerated()), id: \.element.id) { idx, light in
                lightRow(light)
                if idx < lights.count - 1 {
                    Divider().overlay(Color.inkSoft.opacity(0.15))
                }
            }
        }
    }

    private func lightRow(_ light: HueLight) -> some View {
        VStack(spacing: 8) {
            HStack {
                Text(light.name)
                    .font(.system(.body, design: .rounded))
                    .foregroundStyle(light.reachable ? Color.ink : Color.inkSoft)
                if !light.reachable {
                    Text("Unreachable")
                        .font(.system(.caption2, design: .rounded))
                        .foregroundStyle(Color.inkSoft)
                }
                Spacer()
                Toggle("", isOn: Binding(
                    get: { light.isOn },
                    set: { _ in store.send(.toggleLight(bridgeId: bridgeId, lightId: light.id)) }
                ))
                .labelsHidden()
                .tint(Color.bacanGreen)
                .disabled(!light.reachable)
                .accessibilityIdentifier("house-light-toggle-\(light.id)")
            }
            Slider(
                value: Binding(
                    get: { HueBrightness.percent(fromBri: light.brightness) ?? 0 },
                    set: { store.send(.lightBrightnessChanged(bridgeId: bridgeId, lightId: light.id, percent: $0)) }
                ),
                in: 0...100
            )
            .tint(Color.bacanGreen)
            .disabled(!light.reachable)
            .accessibilityIdentifier("house-light-slider-\(light.id)")
        }
        .opacity(light.reachable ? 1 : 0.5)
        .padding(.vertical, 4)
        .accessibilityIdentifier("house-light-\(light.id)")
    }

    // MARK: Card scaffold (mirrors TodayView's card)

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12, content: content)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.familySurface)
            )
    }
}

/// A minimal wrapping row for scene capsules (avoids a horizontal-scroll clip when a room has several
/// scenes). Lays children left-to-right, wrapping to the next line on overflow.
private struct FlowRow: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: maxWidth == .infinity ? x : maxWidth, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
