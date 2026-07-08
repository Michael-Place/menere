import ComposableArchitecture
import FamilyDomain
import HomeKitClient
import HubspaceClient
import HueClient
import LutronClient
import MenereUI
import MerossClient
import NestClient
import SonosClient
import SwiftUI

/// The granular House control surface (P12-C4), pushed from Today's "The house ›" card. A utility
/// screen — familyCanvas/familySurface + rounded type, `.pressable` where natural, but no celebration
/// motion. Owns its own `HouseReducer` store (seeded from the already-loaded snapshot) so it's fully
/// decoupled from `TodayReducer`.
public struct HouseView: View {
    @Bindable private var store: StoreOf<HouseReducer>
    /// Drives the transient "couldn't reach the device" toast — flipped on for a beat whenever an
    /// optimistic write reverts (`store.writeErrorTick` bumps), so a failed tap isn't an invisible no-op.
    @State private var toastVisible = false

    /// Seed from Today's live snapshot so the screen renders instantly, then refresh on appear. Lutron
    /// shades load on appear from `lutronConfig` (P15-C1) — no need to pre-fetch them on Today.
    public init(
        config: HueConfig, members: [HouseholdMember], bridges: [BridgeSnapshot],
        lutronConfig: LutronConfig? = nil, shades: [LutronShade] = [],
        sonosConfig: SonosConfig? = nil, nestConfig: NestConfig? = nil,
        hubspaceConfig: HubspaceConfig? = nil, merossConfig: MerossConfig? = nil,
        homekitConfig: HomeKitConfig? = nil
    ) {
        _store = Bindable(
            wrappedValue: Store(
                initialState: HouseReducer.State(
                    config: config, members: members, bridges: bridges,
                    lutronConfig: lutronConfig, shades: shades,
                    sonosConfig: sonosConfig,
                    nestConfig: nestConfig,
                    hubspaceConfig: hubspaceConfig,
                    merossConfig: merossConfig,
                    homekitConfig: homekitConfig
                )
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
                if store.isInitialLoading {
                    // First paint with no seeded snapshot — a skeleton so the screen never opens blank.
                    SmartHomeSkeleton()
                } else if !store.isAnythingConfigured {
                    // Nothing set up across any subsystem — point at Settings.
                    SmartHomeEmptyState(
                        systemImage: "house",
                        title: "Nothing set up yet",
                        message: "Add a device in Settings → Smart home and it'll show up right here.",
                        accessibilityId: "house-empty"
                    )
                } else {
                    // House at a glance — temps, lights-on, master actions, scene chips.
                    houseGlanceHeader()
                    // Seeded-away: Hue is configured but no bridge answered.
                    if store.isAwayFromHome { awayBanner() }

                    houseSections()
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 12)
        }
        .background(Color.familyCanvas)
        // Every reverted optimistic write buzzes an error + drops the toast (subtle, non-blocking).
        .errorHaptic(store.writeErrorTick)
        // A scene recall anywhere (glance chip / room detail) lands the finished success buzz.
        .successHaptic(store.recalledScene)
        .overlay(alignment: .bottom) { writeToast }
        .onChange(of: store.writeErrorTick) { _, _ in
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { toastVisible = true }
            Task {
                try? await Task.sleep(for: .seconds(2.2))
                withAnimation(.easeOut(duration: 0.25)) { toastVisible = false }
            }
        }
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
        // ~30s water poll, ONLY while this screen is visible — SwiftUI cancels this `.task` on
        // disappear, so there's no background polling. Each tick is a single single-flighted re-read.
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled else { break }
                store.send(.waterPoll)
            }
        }
        .refreshable { await store.send(.refresh).finish() }
        // Opening the garage is a security action → always confirm. Closing does not (handled inline).
        .confirmationDialog(
            "Open the garage?",
            isPresented: Binding(
                get: { store.confirmingGarageOpen != nil },
                set: { if !$0 { store.send(.cancelGarageOpen) } }
            ),
            titleVisibility: .visible
        ) {
            Button("Open the garage", role: .destructive) { store.send(.confirmGarageOpen) }
            Button("Cancel", role: .cancel) { store.send(.cancelGarageOpen) }
        } message: {
            Text("This opens the garage door.")
        }
        // Unlocking a HomeKit door is a security action → always confirm (mirrors garage open). Locking is
        // safe and commits directly.
        .confirmationDialog(
            "Unlock the door?",
            isPresented: Binding(
                get: { store.confirmingHomeKitUnlock != nil },
                set: { if !$0 { store.send(.cancelHomeKitUnlock) } }
            ),
            titleVisibility: .visible
        ) {
            Button("Unlock", role: .destructive) { store.send(.confirmHomeKitUnlock) }
            Button("Cancel", role: .cancel) { store.send(.cancelHomeKitUnlock) }
        } message: {
            Text("This unlocks the door.")
        }
    }

    // MARK: Section orchestration (Wave 1)

    /// The ordered stack of device sections. Each subsystem renders its rich section when reachable, a
    /// dimmed OFFLINE placeholder when configured-but-unreachable (so it no longer silently vanishes), a
    /// LOADING placeholder while its first fetch is still in flight, and nothing when not configured.
    @ViewBuilder
    private func houseSections() -> some View {
        // Lights (Hue) — rooms/zones per bridge.
        switch store.hueStatus {
        case .ok: ForEach(store.bridges) { bridgeSection($0) }
        case .unreachable, .loading: statusSection("Lights", id: "house-lights", status: store.hueStatus)
        case .notConfigured: EmptyView()
        }

        // Shades (Lutron) — one section per area.
        switch store.lutronStatus {
        case .ok:
            ForEach(store.shadesByArea, id: \.area) { group in
                shadesSection(area: group.area, shades: group.shades)
            }
        case .unreachable, .loading: statusSection("Shades", id: "house-shades", status: store.lutronStatus)
        case .notConfigured: EmptyView()
        }

        // Speakers (Sonos).
        switch store.sonosStatus {
        case .ok: speakersSection(store.sonosGroups)
        case .unreachable, .loading: statusSection("Speakers", id: "house-speakers", status: store.sonosStatus)
        case .notConfigured: EmptyView()
        }

        // Climate (Nest).
        switch store.nestStatus {
        case .ok: climateSection(store.thermostats)
        case .unreachable, .loading: statusSection("Climate", id: "house-climate", status: store.nestStatus)
        case .notConfigured: EmptyView()
        }

        // Water (Hubspace).
        switch store.hubspaceStatus {
        case .ok: waterSection(store.spigots)
        case .unreachable, .loading: statusSection("Water", id: "house-water", status: store.hubspaceStatus)
        case .notConfigured: EmptyView()
        }

        // Garage (HomeKit-first, Meross fallback).
        switch store.garageStatus {
        case .ok: garageSection(store.garageDoors)
        case .unreachable, .loading: statusSection("Garage", id: "house-garage", status: store.garageStatus)
        case .notConfigured: EmptyView()
        }

        // HomeKit (locks / plugs / sensors).
        switch store.homekitStatus {
        case .ok: if let inventory = store.homekitInventory { homekitSection(inventory) }
        case .unreachable, .loading: statusSection("HomeKit", id: "house-homekit", status: store.homekitStatus)
        case .notConfigured: EmptyView()
        }
    }

    /// A visible placeholder for a section that is configured-but-unreachable (dimmed "Offline" badge) or
    /// still loading (spinner badge) — the fix for sections that used to silently disappear.
    private func statusSection(_ title: String, id: String, status: DeviceStatus) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            SmartHomeSectionHeader(title: title, badge: status)
            SmartHomeCard(dimmed: status == .unreachable) {
                HStack(spacing: 10) {
                    Image(systemName: status == .loading ? "arrow.triangle.2.circlepath" : "wifi.slash")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Color.inkSoft)
                        .frame(width: 26)
                    Text(status == .loading ? "Checking…" : "Not reachable right now — try again in a moment.")
                        .font(.system(.subheadline, design: .rounded))
                        .foregroundStyle(Color.inkSoft)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
            }
        }
        .accessibilityIdentifier(id)
    }

    // MARK: House at a glance (Wave 1)

    /// The calm, glanceable header: a lights-on headline, a temperature roll-up (labeled Hue thermometers
    /// + Nest ambient), master actions ("All lights off" / "Goodnight"), and the scene/ritual chips
    /// (previously buried in room detail) surfaced at the top.
    private func houseGlanceHeader() -> some View {
        let temps = store.glanceTemperatures
        let scenes = store.glanceScenes
        return VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
                Text(store.lightsOnCount == 0 ? "All lights off" : "\(store.lightsOnCount) light\(store.lightsOnCount == 1 ? "" : "s") on")
                    .font(.system(.title3, design: .rounded).weight(.semibold))
                    .foregroundStyle(Color.ink)
                    .contentTransition(.numericText())
                    .accessibilityIdentifier("house-glance-lights")
                if !temps.isEmpty {
                    FlowRow(spacing: 8) {
                        ForEach(Array(temps.enumerated()), id: \.offset) { _, t in
                            tempChip(label: t.label, tempF: t.tempF)
                        }
                    }
                }
            }
            HStack(spacing: 10) {
                ControlPill(title: "All lights off", systemImage: "lightbulb.slash.fill", tint: .bacanGreen,
                            id: "house-all-lights-off") { store.send(.allLightsOff) }
                    .disabled(!store.hasReachableLights)
                    .opacity(store.hasReachableLights ? 1 : 0.5)
                ControlPill(title: "Goodnight", systemImage: "moon.stars.fill", tint: .sky, fill: 0.18,
                            id: "house-goodnight") { store.send(.goodnight) }
                    .disabled(!store.hasReachableLights)
                    .opacity(store.hasReachableLights ? 1 : 0.5)
                Spacer(minLength: 0)
            }
            if !scenes.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("SCENES")
                        .font(.system(.caption2, design: .rounded).weight(.semibold))
                        .foregroundStyle(Color.inkSoft)
                    FlowRow(spacing: 8) {
                        ForEach(scenes) { scene in
                            Button {
                                MenereHaptics.softTap()
                                store.send(.recallScene(bridgeId: scene.bridgeId, groupId: scene.groupId, sceneId: scene.sceneId))
                            } label: {
                                HStack(spacing: 5) {
                                    Image(systemName: "sparkles")
                                    Text(scene.name)
                                }
                                .font(.system(.subheadline, design: .rounded).weight(.semibold))
                                .foregroundStyle(Color.marigold)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 9)
                                .background(Capsule(style: .continuous).fill(Color.marigold.opacity(0.18)))
                            }
                            .buttonStyle(.pressable)
                            .accessibilityIdentifier("house-glance-scene-\(scene.id)")
                        }
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color.familySurface)
        )
        .accessibilityIdentifier("house-glance")
    }

    private func tempChip(label: String, tempF: Double) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "thermometer.medium").font(.caption2)
            Text("\(label) \(Int(tempF.rounded()))°")
                .contentTransition(.numericText())
        }
        .font(.system(.caption, design: .rounded).weight(.medium))
        .foregroundStyle(Color.inkSoft)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Capsule(style: .continuous).fill(Color.inkSoft.opacity(0.10)))
    }

    private func awayBanner() -> some View {
        HStack(spacing: 10) {
            Image(systemName: "moon.zzz.fill").foregroundStyle(Color.inkSoft)
            Text("Not home — showing last known.")
                .font(.system(.subheadline, design: .rounded).weight(.medium))
                .foregroundStyle(Color.inkSoft)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.inkSoft.opacity(0.10)))
        .accessibilityIdentifier("house-away")
    }

    @ViewBuilder
    private var writeToast: some View {
        if toastVisible {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                Text("Couldn't reach the device")
            }
            .font(.system(.subheadline, design: .rounded).weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
            .background(Capsule(style: .continuous).fill(Color.terracotta))
            .shadow(color: .black.opacity(0.15), radius: 8, y: 3)
            .padding(.bottom, 24)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .accessibilityIdentifier("house-write-error-toast")
        }
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
                SmartHomeSection(title: "Rooms", data: rooms) { room in
                    roomRow(room, bridgeId: snap.bridge.bridgeId)
                }
            }
            if !zones.isEmpty {
                SmartHomeSection(title: "Zones", data: zones) { room in
                    roomRow(room, bridgeId: snap.bridge.bridgeId)
                }
            }
        }
    }

    // MARK: Shades section (P15-C1)

    private func shadesSection(area: String, shades: [LutronShade]) -> some View {
        SmartHomeSection(title: "\(area) · Shades", data: shades, accessibilityId: "house-shades-\(area)") { shade in
            shadeRow(shade)
        }
    }

    private func shadeRow(_ shade: LutronShade) -> some View {
        VStack(spacing: 8) {
            // Top row via the shared DeviceRow (unpadded — this composite adds its own padding + slider).
            DeviceRow(
                title: shade.name,
                status: LutronLevel.label(shade.level),
                statusAccessibilityId: "house-shade-level-\(shade.zoneId)",
                padded: false
            ) {
                // Up · Stop · Down — the icon-only ``ControlPill`` (was `shadeButton`).
                HStack(spacing: 6) {
                    IconButton("chevron.up", id: "house-shade-raise-\(shade.zoneId)") {
                        store.send(.raiseShade(zoneId: shade.zoneId))
                    }
                    IconButton("stop.fill", id: "house-shade-stop-\(shade.zoneId)") {
                        store.send(.stopShade(zoneId: shade.zoneId))
                    }
                    IconButton("chevron.down", id: "house-shade-lower-\(shade.zoneId)") {
                        store.send(.lowerShade(zoneId: shade.zoneId))
                    }
                }
            }
            Slider(
                value: Binding(
                    get: { Double(shade.level) },
                    set: { store.send(.shadeLevelChanged(zoneId: shade.zoneId, level: Int($0.rounded()))) }
                ),
                in: 0...100
            )
            .tint(Color.bacanGreen)
            .accessibilityIdentifier("house-shade-slider-\(shade.zoneId)")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .accessibilityIdentifier("house-shade-\(shade.zoneId)")
    }

    // MARK: Speakers section (P15-C2)

    private func speakersSection(_ groups: [SonosGroup]) -> some View {
        SmartHomeSection(title: "Speakers", data: groups, accessibilityId: "house-speakers") { group in
            speakerRow(group)
        }
    }

    private func speakerRow(_ group: SonosGroup) -> some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                albumArt(group.nowPlaying)
                VStack(alignment: .leading, spacing: 2) {
                    Text(group.roomName)
                        .font(.system(.body, design: .rounded).weight(.medium))
                        .foregroundStyle(Color.ink)
                        .lineLimit(1)
                    Text(group.nowPlaying.line)
                        .font(.system(.caption, design: .rounded))
                        .foregroundStyle(Color.inkSoft)
                        .lineLimit(1)
                        .accessibilityIdentifier("house-speaker-nowplaying-\(group.id)")
                }
                Spacer(minLength: 0)
                // Play / pause via the shared icon-only ``ControlPill``.
                IconButton(group.nowPlaying.isPlaying ? "pause.fill" : "play.fill",
                           id: "house-speaker-playpause-\(group.id)") {
                    store.send(.toggleSonosPlayback(groupId: group.id))
                }
            }
            HStack(spacing: 10) {
                Image(systemName: "speaker.fill")
                    .font(.caption2)
                    .foregroundStyle(Color.inkSoft)
                Slider(
                    value: Binding(
                        get: { Double(group.volume) },
                        set: { store.send(.sonosVolumeChanged(groupId: group.id, volume: Int($0.rounded()))) }
                    ),
                    in: 0...100
                )
                .tint(Color.bacanGreen)
                .accessibilityIdentifier("house-speaker-slider-\(group.id)")
                Image(systemName: "speaker.wave.3.fill")
                    .font(.caption2)
                    .foregroundStyle(Color.inkSoft)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .accessibilityIdentifier("house-speaker-\(group.id)")
    }

    /// A small album-art thumbnail: the real art when a URL is present (async, URLCache-backed), a warm
    /// color block for a playing group with no art (a record has no cover), and an ink-soft music note
    /// when idle. Always 44×44 rounded.
    @ViewBuilder
    private func albumArt(_ nowPlaying: SonosNowPlaying) -> some View {
        let side: CGFloat = 44
        RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(nowPlaying.isPlaying ? Color.bacanGreen.opacity(0.18) : Color.inkSoft.opacity(0.12))
            .frame(width: side, height: side)
            .overlay {
                if let url = nowPlaying.albumArtURL {
                    BacanImage(url: url, targetSize: CGSize(width: side, height: side), contentMode: .fill) {
                        musicNote(playing: nowPlaying.isPlaying)
                    }
                } else {
                    musicNote(playing: nowPlaying.isPlaying)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .accessibilityHidden(true)
    }

    private func musicNote(playing: Bool) -> some View {
        Image(systemName: "music.note")
            .font(.system(size: 18, weight: .semibold))
            .foregroundStyle(playing ? Color.bacanGreen : Color.inkSoft)
    }

    // MARK: Climate section (P15-C3)

    private func climateSection(_ thermostats: [NestThermostat]) -> some View {
        SmartHomeSection(title: "Climate", data: thermostats, accessibilityId: "house-climate") { thermostat in
            thermostatRow(thermostat)
        }
    }

    private func thermostatRow(_ thermostat: NestThermostat) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(thermostat.roomName)
                        .font(.system(.body, design: .rounded).weight(.medium))
                        .foregroundStyle(Color.ink)
                        .lineLimit(1)
                    HStack(spacing: 8) {
                        modeChip(thermostat.mode)
                        if let humidity = thermostat.humidityInt {
                            Label("\(humidity)%", systemImage: "humidity")
                                .font(.system(.caption, design: .rounded))
                                .foregroundStyle(Color.inkSoft)
                                .labelStyle(.titleAndIcon)
                                .accessibilityIdentifier("house-thermostat-humidity-\(thermostat.deviceId)")
                        }
                    }
                }
                Spacer(minLength: 0)
                // Big ambient temperature.
                if let ambientF = thermostat.ambientF {
                    Text(ambientLabel(ambientF))
                        .font(.system(size: 34, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.ink)
                        .contentTransition(.numericText())
                        .accessibilityIdentifier("house-thermostat-ambient-\(thermostat.deviceId)")
                }
            }
            // Setpoint stepper(s): heat/cool → one; Heat·Cool → two; Off → a quiet note.
            switch thermostat.mode {
            case .heat:
                setpointStepper(thermostat, kind: .heat, label: "Set to")
            case .cool:
                setpointStepper(thermostat, kind: .cool, label: "Set to")
            case .heatCool:
                setpointStepper(thermostat, kind: .heat, label: "Heat to")
                setpointStepper(thermostat, kind: .cool, label: "Cool to")
            case .off:
                Text("Off — no setpoint")
                    .font(.system(.caption, design: .rounded))
                    .foregroundStyle(Color.inkSoft)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .accessibilityIdentifier("house-thermostat-\(thermostat.deviceId)")
    }

    /// The mode chip — heat=terracotta / cool=sky / auto=bacanGreen / off=ink-soft.
    private func modeChip(_ mode: NestMode) -> some View {
        let color: Color = {
            switch mode {
            case .heat: return .terracotta
            case .cool: return .sky
            case .heatCool: return .bacanGreen
            case .off: return .inkSoft
            }
        }()
        return Text(mode.label.uppercased())
            .font(.system(.caption2, design: .rounded).weight(.bold))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule(style: .continuous).fill(color.opacity(0.16)))
            .accessibilityIdentifier("house-thermostat-mode-\(mode.rawValue)")
    }

    /// A labeled −/+ stepper for one setpoint (1 °F steps, optimistic; the reducer debounces the commit).
    private func setpointStepper(_ thermostat: NestThermostat, kind: NestSetpointKind, label: String) -> some View {
        let value = thermostat.setpointF(kind)
        let tint: Color = kind == .heat ? .terracotta : .sky
        return HStack(spacing: 12) {
            Text(label)
                .font(.system(.subheadline, design: .rounded))
                .foregroundStyle(Color.inkSoft)
            Spacer(minLength: 0)
            IconButton("minus", tint: tint, id: "house-thermostat-\(thermostat.deviceId)-\(kind.rawValue)-minus") {
                store.send(.nestSetpointStepped(deviceName: thermostat.id, kind: kind, deltaF: -1))
            }
            Text(value.map { "\($0)°" } ?? "—")
                .font(.system(.title3, design: .rounded).weight(.semibold))
                .foregroundStyle(Color.ink)
                .contentTransition(.numericText())
                .monospacedDigit()
                .frame(minWidth: 44)
                .accessibilityIdentifier("house-thermostat-\(thermostat.deviceId)-\(kind.rawValue)-value")
            IconButton("plus", tint: tint, id: "house-thermostat-\(thermostat.deviceId)-\(kind.rawValue)-plus") {
                store.send(.nestSetpointStepped(deviceName: thermostat.id, kind: kind, deltaF: 1))
            }
        }
    }

    /// Ambient label: whole degrees when it lands on one, else one decimal (e.g. "71.6°").
    private func ambientLabel(_ f: Double) -> String {
        let rounded = (f * 10).rounded() / 10
        if rounded == rounded.rounded() {
            return "\(Int(rounded))°"
        }
        return String(format: "%.1f°", rounded)
    }

    // MARK: Water section (P15-C4)

    private func waterSection(_ spigots: [HubspaceSpigot]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            SmartHomeSectionHeader(title: "Water")
            VStack(spacing: 14) {
                ForEach(spigots) { spigot in
                    spigotCard(spigot, showHeader: spigots.count > 1)
                }
            }
        }
        .accessibilityIdentifier("house-water")
    }

    /// One spigot device: an optional name+battery header (shown when there are multiple devices) and a
    /// rounded card of per-outlet rows.
    private func spigotCard(_ spigot: HubspaceSpigot, showHeader: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if showHeader {
                HStack(spacing: 8) {
                    Text(spigot.name)
                        .font(.system(.subheadline, design: .rounded).weight(.semibold))
                        .foregroundStyle(Color.ink)
                    Spacer(minLength: 0)
                    batteryLabel(spigot.batteryPercent)
                }
                .padding(.horizontal, 4)
            }
            DeviceCard(data: spigot.outlets) { outlet in
                outletRow(
                    spigot: spigot, outlet: outlet,
                    showBattery: !showHeader && outlet.id == spigot.outlets.first?.id ? spigot.batteryPercent : nil
                )
            }
        }
        .accessibilityIdentifier("house-spigot-\(spigot.id)")
    }

    private func outletRow(spigot: HubspaceSpigot, outlet: SpigotOutlet, showBattery: Int?) -> some View {
        let status = showBattery.map { "\(outlet.statusLine) · 🔋\($0)%" } ?? outlet.statusLine
        return DeviceRow(
            icon: outlet.isOpen ? "drop.fill" : "drop",
            iconTint: outlet.isOpen ? Color.bacanGreen : Color.inkSoft,
            title: outlet.name,
            status: status,
            statusTint: outlet.isOpen ? Color.bacanGreen : Color.inkSoft,
            statusAccessibilityId: "house-spigot-status-\(spigot.id)-\(outlet.instance)",
            accessibilityId: "house-spigot-outlet-\(spigot.id)-\(outlet.instance)"
        ) {
            // When opening, offer a duration menu; when open, a plain "close" toggle.
            if outlet.isOpen {
                Toggle("", isOn: Binding(
                    get: { true },
                    set: { _ in
                        MenereHaptics.softTap()
                        store.send(.toggleSpigot(deviceId: spigot.id, instance: outlet.instance, open: false, durationMinutes: nil))
                    }
                ))
                .labelsHidden()
                .tint(Color.bacanGreen)
                .accessibilityIdentifier("house-spigot-toggle-\(spigot.id)-\(outlet.instance)")
            } else {
                durationMenu(spigot: spigot, outlet: outlet)
            }
        }
    }

    /// The "open for how long" menu — the timed-run options plus "Until turned off". Tapping any option
    /// opens the outlet (optimistically) with that duration.
    private func durationMenu(spigot: HubspaceSpigot, outlet: SpigotOutlet) -> some View {
        Menu {
            ForEach(SpigotDuration.options, id: \.self) { minutes in
                Button("Open for \(minutes) min") {
                    store.send(.toggleSpigot(deviceId: spigot.id, instance: outlet.instance, open: true, durationMinutes: minutes))
                }
            }
            Button("Open until turned off") {
                store.send(.toggleSpigot(deviceId: spigot.id, instance: outlet.instance, open: true, durationMinutes: nil))
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "drop")
                Text("Open")
            }
            .font(.system(size: 14, weight: .semibold, design: .rounded))
            .foregroundStyle(Color.bacanGreen)
            .padding(.horizontal, 12)
            .frame(height: 32)
            .background(Capsule(style: .continuous).fill(Color.bacanGreen.opacity(0.14)))
        }
        .accessibilityIdentifier("house-spigot-open-\(spigot.id)-\(outlet.instance)")
    }

    private func batteryLabel(_ percent: Int?) -> some View {
        Group {
            if let percent {
                Text("🔋 \(percent)%")
                    .font(.system(.caption, design: .rounded))
                    .foregroundStyle(Color.inkSoft)
            }
        }
    }

    // MARK: Garage section (P15-C5)

    private func garageSection(_ doors: [GarageDoor]) -> some View {
        SmartHomeSection(title: "Garage", data: doors, accessibilityId: "house-garage") { door in
            garageRow(door)
        }
    }

    /// One garage door row. It's a security surface, so state reads plainly (a bacanGreen shield when
    /// closed / terracotta when open), the transitional "Opening…" / "Closing…" shows while it travels,
    /// and the action button is Open (→ confirmation) or Close (direct).
    private func garageRow(_ door: GarageDoor) -> some View {
        let settling = store.garageSettling[door.channel]
        return DeviceRow(
            icon: door.isOpen ? "door.garage.open" : "door.garage.closed",
            iconTint: door.isOpen ? Color.terracotta : Color.bacanGreen,
            iconSize: 18,
            title: door.displayName,
            status: garageStatusText(door: door, settling: settling),
            statusTint: garageStatusColor(door: door, settling: settling),
            statusAccessibilityId: "house-garage-status-\(door.channel)",
            accessibilityId: "house-garage-\(door.channel)"
        ) {
            garageActionButton(door: door, settling: settling)
        }
    }

    @ViewBuilder
    private func garageActionButton(door: GarageDoor, settling: HouseReducer.State.GarageTransition?) -> some View {
        if let settling {
            // While travelling, show a quiet pending pill (no action — the door is mid-move).
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(settling == .opening ? "Opening…" : "Closing…")
            }
            .font(.system(size: 14, weight: .semibold, design: .rounded))
            .foregroundStyle(Color.inkSoft)
            .padding(.horizontal, 12)
            .frame(height: 32)
            .background(Capsule(style: .continuous).fill(Color.inkSoft.opacity(0.12)))
            .accessibilityIdentifier("house-garage-settling-\(door.channel)")
        } else if door.isOpen {
            ControlPill(title: "Close", systemImage: "door.garage.closed", tint: .bacanGreen,
                        id: "house-garage-close-\(door.channel)") {
                store.send(.garageCloseRequested(channel: door.channel))
            }
        } else {
            ControlPill(title: "Open", systemImage: "door.garage.open", tint: .terracotta,
                        id: "house-garage-open-\(door.channel)") {
                store.send(.garageOpenRequested(channel: door.channel))
            }
        }
    }

    private func garageStatusText(door: GarageDoor, settling: HouseReducer.State.GarageTransition?) -> String {
        switch settling {
        case .opening: return "Opening…"
        case .closing: return "Closing…"
        case nil: return door.statusLine
        }
    }

    private func garageStatusColor(door: GarageDoor, settling: HouseReducer.State.GarageTransition?) -> Color {
        if settling != nil { return Color.inkSoft }
        return door.isOpen ? Color.terracotta : Color.bacanGreen
    }

    // MARK: HomeKit section (P15-C7)

    @ViewBuilder
    private func homekitSection(_ inventory: HKInventory) -> some View {
        let locks = inventory.lockAccessories
        let plugs = inventory.powerAccessories
        let sensors = inventory.sensorAccessories
        VStack(alignment: .leading, spacing: 12) {
            SmartHomeSectionHeader(title: "HomeKit")
            // Each sub-group is a homogeneous DeviceCard — no more AnyView erasure (the rows return
            // concrete DeviceRow types).
            if !locks.isEmpty { DeviceCard(data: locks) { lockRow($0) } }
            if !plugs.isEmpty { DeviceCard(data: plugs) { plugRow($0) } }
            if !sensors.isEmpty { DeviceCard(data: sensors) { sensorRow($0) } }
            // "All HomeKit devices" — the superpower-discovery surface (read-only, every accessory).
            SmartHomeCard { inventoryLinkRow(count: inventory.accessories.count) }
        }
        .accessibilityIdentifier("house-homekit")
    }

    /// A door-lock row: state (green shield when locked / terracotta when unlocked) + a Lock/Unlock button.
    /// Unlock routes through the confirmation dialog; Lock commits directly.
    private func lockRow(_ accessory: HKAccessory) -> some View {
        let locked = accessory.lockIsLocked ?? true
        return DeviceRow(
            icon: locked ? "lock.fill" : "lock.open.fill",
            iconTint: locked ? Color.bacanGreen : Color.terracotta,
            iconSize: 18,
            title: accessory.name,
            status: locked ? "Locked" : "Unlocked",
            statusTint: locked ? Color.bacanGreen : Color.terracotta,
            statusAccessibilityId: "house-homekit-lock-status-\(accessory.id)",
            accessibilityId: "house-homekit-lock-\(accessory.id)-row"
        ) {
            if locked {
                ControlPill(title: "Unlock", systemImage: "lock.open", tint: .terracotta,
                            id: "house-homekit-unlock-\(accessory.id)") {
                    store.send(.homekitUnlockRequested(accessoryId: accessory.id))
                }
            } else {
                ControlPill(title: "Lock", systemImage: "lock", tint: .bacanGreen,
                            id: "house-homekit-lock-\(accessory.id)") {
                    store.send(.homekitLockRequested(accessoryId: accessory.id))
                }
            }
        }
    }

    /// A smart-plug / switch row: name + on/off status + a power toggle.
    private func plugRow(_ accessory: HKAccessory) -> some View {
        let on = accessory.powerIsOn ?? false
        return DeviceRow(
            icon: "powerplug.fill",
            iconTint: on ? Color.bacanGreen : Color.inkSoft,
            title: accessory.name,
            status: on ? "On" : "Off",
            statusTint: on ? Color.bacanGreen : Color.inkSoft,
            statusAccessibilityId: "house-homekit-plug-status-\(accessory.id)",
            accessibilityId: "house-homekit-plug-\(accessory.id)-row"
        ) {
            Toggle("", isOn: Binding(
                get: { on },
                set: { _ in
                    MenereHaptics.softTap()
                    store.send(.homekitToggleOutlet(accessoryId: accessory.id))
                }
            ))
            .labelsHidden()
            .tint(Color.bacanGreen)
            .accessibilityIdentifier("house-homekit-plug-toggle-\(accessory.id)")
        }
    }

    /// A read-only sensor row: temperature (°F) or contact (open/closed).
    private func sensorRow(_ accessory: HKAccessory) -> some View {
        DeviceRow(
            icon: accessory.hasService(.contactSensor) ? "sensor.fill" : "thermometer.medium",
            title: accessory.name,
            status: accessory.room ?? "HomeKit",
            accessibilityId: "house-homekit-sensor-\(accessory.id)-row"
        ) {
            Text(sensorReading(accessory))
                .font(.system(.title3, design: .rounded).weight(.semibold))
                .foregroundStyle(Color.ink)
                .monospacedDigit()
                .accessibilityIdentifier("house-homekit-sensor-value-\(accessory.id)")
        }
    }

    private func sensorReading(_ accessory: HKAccessory) -> String {
        if let f = accessory.temperatureF {
            return "\(Int(f.rounded()))°"
        }
        if let closed = accessory.contactIsClosed {
            return closed ? "Closed" : "Open"
        }
        return "—"
    }

    private func inventoryLinkRow(count: Int) -> some View {
        NavigationLink {
            HomeKitInventoryView(store: store)
        } label: {
            DeviceRow(
                icon: "square.grid.2x2.fill",
                iconTint: .bacanGreen,
                title: "All HomeKit devices",
                status: "\(count) accessor\(count == 1 ? "y" : "ies")"
            ) {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.inkSoft.opacity(0.6))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("house-homekit-all-devices")
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
                set: { _ in
                    MenereHaptics.softTap()
                    store.send(.toggleRoom(bridgeId: bridgeId, roomId: room.id))
                }
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
                    set: { _ in
                        MenereHaptics.softTap()
                        store.send(.toggleRoom(bridgeId: bridgeId, roomId: roomId))
                    }
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
                    set: { _ in
                        MenereHaptics.softTap()
                        store.send(.toggleLight(bridgeId: bridgeId, lightId: light.id))
                    }
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

// MARK: - HomeKit inventory (P15-C7)

/// The read-only "All HomeKit devices" list — EVERY accessory in the Home (name, room, category,
/// reachability), no controls. This is the superpower-discovery surface: on Michael's real phone it
/// reveals whatever HomeKit accessories the Home app has paired (the app can't know until it looks).
struct HomeKitInventoryView: View {
    let store: StoreOf<HouseReducer>

    private var accessories: [HKAccessory] {
        (store.homekitInventory?.accessories ?? []).sorted {
            ($0.room ?? "~", $0.name) < ($1.room ?? "~", $1.name)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if accessories.isEmpty {
                    Text("No HomeKit accessories found.")
                        .font(.system(.subheadline, design: .rounded))
                        .foregroundStyle(Color.inkSoft)
                        .padding()
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(accessories.enumerated()), id: \.element.id) { idx, accessory in
                            row(accessory)
                            if idx < accessories.count - 1 {
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
            .padding(.horizontal)
            .padding(.vertical, 12)
        }
        .background(Color.familyCanvas)
        .navigationTitle(store.homekitInventory?.homeName ?? "All devices")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func row(_ accessory: HKAccessory) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(accessory.name)
                    .font(.system(.body, design: .rounded).weight(.medium))
                    .foregroundStyle(Color.ink)
                    .lineLimit(1)
                Text([accessory.room, accessory.category.displayName].compactMap { $0 }.joined(separator: " · "))
                    .font(.system(.caption, design: .rounded))
                    .foregroundStyle(Color.inkSoft)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            HStack(spacing: 6) {
                Circle()
                    .fill(accessory.isReachable ? Color.bacanGreen : Color.inkSoft)
                    .frame(width: 8, height: 8)
                Text(accessory.isReachable ? "Reachable" : "Unreachable")
                    .font(.system(.caption, design: .rounded))
                    .foregroundStyle(Color.inkSoft)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .accessibilityIdentifier("house-homekit-inventory-\(accessory.id)")
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
