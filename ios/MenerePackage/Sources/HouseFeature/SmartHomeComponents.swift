import MenereUI
import SwiftUI

// MARK: - Smart-home shared components (Wave 1)
//
// The reusable vocabulary the seven House sections (Hue rooms, Lutron shades, Sonos speakers, Nest
// climate, Hubspace water, garage, HomeKit) now compose on. Before Wave 1 each section hand-copied the
// section scaffold (uppercase caption + `familySurface` RoundedRectangle(18) card + inset dividers) and
// carried its own near-identical capsule builder (`shadeButton` / `stepperButton` / `garageButton` /
// `homekitPill`). These parts collapse those into one on-brand set — same look (familyCanvas/
// familySurface, bacanGreen/terracotta/sky/inkSoft, rounded type, `.pressable`), far less duplication —
// and add the missing STATE vocabulary (a per-section reachability badge, a skeleton, an empty state).
//
// Deliberately kept in HouseFeature (NOT MenereUI): these are smart-home-shaped, not general chrome, and
// a parallel peer owns MenereUI.

/// Per-section (or per-device) reachability, derived by `HouseReducer` from **config presence + fetch
/// success** — never an invented hardware probe. Lets the House surface distinguish the three states that
/// used to be indistinguishable when an empty section silently vanished:
/// - `.ok` — configured and answering (no badge).
/// - `.loading` — configured, first fetch still in flight (spinner badge).
/// - `.unreachable` — configured but the bridge/cloud didn't answer (dimmed "Offline" badge, section stays
///   visible instead of vanishing, so "off" vs "unreachable" vs "never had it" read differently).
/// - `.notConfigured` — never set up (the section hides entirely; the top-level empty state covers it).
public enum DeviceStatus: Equatable, Sendable {
    case ok
    case loading
    case unreachable
    case notConfigured
}

/// A small, dimmed status pill shown at the trailing edge of a section header. Renders nothing for
/// `.ok`/`.notConfigured` (those don't want a badge); a quiet spinner for `.loading`; a "wifi.slash ·
/// Offline" chip for `.unreachable`.
struct DeviceStateBadge: View {
    let status: DeviceStatus

    var body: some View {
        switch status {
        case .ok, .notConfigured:
            EmptyView()
        case .loading:
            HStack(spacing: 5) {
                ProgressView().controlSize(.mini)
                Text("Loading")
            }
            .font(.system(.caption2, design: .rounded).weight(.semibold))
            .foregroundStyle(Color.inkSoft)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(Capsule(style: .continuous).fill(Color.inkSoft.opacity(0.12)))
            .accessibilityIdentifier("house-badge-loading")
        case .unreachable:
            Label("Offline", systemImage: "wifi.slash")
                .labelStyle(.titleAndIcon)
                .font(.system(.caption2, design: .rounded).weight(.semibold))
                .foregroundStyle(Color.inkSoft)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(Capsule(style: .continuous).fill(Color.inkSoft.opacity(0.12)))
                .accessibilityIdentifier("house-badge-offline")
        }
    }
}

/// A loud, warm-tinted alert pill in the same visual family as ``DeviceStateBadge`` (W2a) — the "state"
/// vocabulary for a device that needs attention rather than one that's merely offline: a **jammed** lock,
/// a **stopped**/jammed garage door. Terracotta (vs the ink-soft "Offline" chip) so a physical fault
/// reads as urgent, not just unreachable. Icon + short word ("Jammed" / "Stopped").
struct SmartHomeAlertBadge: View {
    let text: String
    var systemImage: String = "exclamationmark.triangle.fill"
    var accessibilityId: String? = nil

    var body: some View {
        Label(text, systemImage: systemImage)
            .labelStyle(.titleAndIcon)
            .font(.system(.caption2, design: .rounded).weight(.bold))
            .foregroundStyle(Color.terracotta)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(Capsule(style: .continuous).fill(Color.terracotta.opacity(0.16)))
            .axID(accessibilityId)
    }
}

/// The section caption row: an uppercase rounded-caption title plus an optional trailing ``DeviceStateBadge``.
/// Collapses the hand-copied `Text(title.uppercased())…` header that opened all seven sections.
struct SmartHomeSectionHeader: View {
    let title: String
    var badge: DeviceStatus = .ok

    var body: some View {
        HStack(spacing: 8) {
            Text(title.uppercased())
                .font(.system(.caption, design: .rounded).weight(.semibold))
                .foregroundStyle(Color.inkSoft)
            Spacer(minLength: 0)
            DeviceStateBadge(status: badge)
        }
    }
}

/// The inset hairline divider used between rows inside every card (was hand-written ~7×).
struct SmartHomeDivider: View {
    var body: some View {
        Divider().overlay(Color.inkSoft.opacity(0.15)).padding(.leading, 16)
    }
}

/// The `familySurface` RoundedRectangle(18) card scaffold — wrap any content. Was hand-copied in every
/// section's `.background(RoundedRectangle(cornerRadius: 18…).fill(Color.familySurface))`.
struct SmartHomeCard<Content: View>: View {
    var dimmed: Bool = false
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) { content }
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.familySurface)
            )
            .opacity(dimmed ? 0.55 : 1)
    }
}

/// A card of identifiable rows with inset dividers between them — the single most-copied pattern (rooms,
/// shades, speakers, climate, garage all did exactly this). Feed it a collection + a row builder.
struct DeviceCard<Data: RandomAccessCollection, Row: View>: View where Data.Element: Identifiable {
    let data: Data
    var dimmed: Bool = false
    @ViewBuilder let row: (Data.Element) -> Row

    var body: some View {
        SmartHomeCard(dimmed: dimmed) {
            ForEach(Array(data.enumerated()), id: \.element.id) { idx, element in
                row(element)
                if idx < data.count - 1 { SmartHomeDivider() }
            }
        }
    }
}

/// The whole common section: header (with badge) + a divided card of rows. The straightforward sections
/// (shades / speakers / climate / garage) migrate onto this wholesale.
struct SmartHomeSection<Data: RandomAccessCollection, Row: View>: View where Data.Element: Identifiable {
    let title: String
    var badge: DeviceStatus = .ok
    let data: Data
    var accessibilityId: String? = nil
    @ViewBuilder let row: (Data.Element) -> Row

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SmartHomeSectionHeader(title: title, badge: badge)
            DeviceCard(data: data, dimmed: badge == .unreachable, row: row)
        }
        .axID(accessibilityId)
    }
}

/// The canonical device row: an optional leading tinted icon, a title + status line, and a trailing
/// control slot. Collapses the near-identical row bodies the HomeKit lock/plug/sensor rows, the garage
/// row, the water outlet row, and the speaker header all hand-wrote — and lets the HomeKit rows drop
/// their `AnyView` erasure (they return `DeviceRow`, a concrete type).
struct DeviceRow<Trailing: View>: View {
    var icon: String? = nil
    var iconTint: Color = .inkSoft
    var iconSize: CGFloat = 16
    let title: String
    var titleTint: Color = .ink
    var status: String? = nil
    var statusTint: Color = .inkSoft
    var statusAccessibilityId: String? = nil
    var accessibilityId: String? = nil
    /// When false, the caller supplies its own padding — used by composite rows (a shade/speaker row that
    /// stacks a slider underneath the ``DeviceRow`` inside one padded container).
    var padded: Bool = true
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 12) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: iconSize, weight: .semibold))
                    .foregroundStyle(iconTint)
                    .frame(width: 26)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(.body, design: .rounded).weight(.medium))
                    .foregroundStyle(titleTint)
                    .lineLimit(1)
                if let status {
                    Text(status)
                        .font(.system(.caption, design: .rounded))
                        .foregroundStyle(statusTint)
                        .contentTransition(.opacity)
                        .axID(statusAccessibilityId)
                }
            }
            Spacer(minLength: 0)
            trailing()
        }
        .padding(.horizontal, padded ? 16 : 0)
        .padding(.vertical, padded ? 12 : 0)
        .axID(accessibilityId)
    }
}

/// The single capsule control that replaces `shadeButton` / `stepperButton` / `garageButton` /
/// `homekitPill`. Pass a `title` for a labeled pill ("Open", "Unlock"); omit it for an icon-only button
/// (the old shade up/stop/down + thermostat −/+). Every tap fires the light confirmation haptic
/// (`MenereHaptics.softTap`) and animates via `.pressable`, so all seven dialects feel identically
/// finished. `IconButton` is just the title-less form.
struct ControlPill: View {
    var title: String? = nil
    let systemImage: String
    var tint: Color = .bacanGreen
    var fill: Double = 0.14
    let id: String
    let action: () -> Void

    var body: some View {
        Button {
            MenereHaptics.softTap()
            action()
        } label: {
            Group {
                if let title {
                    HStack(spacing: 4) {
                        Image(systemName: systemImage)
                        Text(title)
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 32)
                } else {
                    Image(systemName: systemImage)
                        .frame(width: 36, height: 32)
                }
            }
            .font(.system(size: 14, weight: .semibold, design: .rounded))
            .foregroundStyle(tint)
            .background(Capsule(style: .continuous).fill(tint.opacity(fill)))
        }
        .buttonStyle(.pressable)
        .accessibilityIdentifier(id)
    }
}

/// The title-less ``ControlPill`` — an icon-only capsule button (shade raise/stop/lower, thermostat −/+).
func IconButton(_ systemImage: String, tint: Color = .bacanGreen, id: String, action: @escaping () -> Void) -> ControlPill {
    ControlPill(systemImage: systemImage, tint: tint, id: id, action: action)
}

// MARK: - Whole-screen states

/// First-paint loading skeleton — a couple of dimmed placeholder section cards + a quiet "Loading the
/// house…" line. Shown while the very first fetch is in flight and there's no seeded snapshot yet, so the
/// screen never opens blank. Reduce-Motion friendly: a gentle looping opacity that's disabled when the
/// user asks for reduced motion (falls back to a static placeholder).
struct SmartHomeSkeleton: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            ForEach(0..<3, id: \.self) { _ in
                VStack(alignment: .leading, spacing: 6) {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color.inkSoft.opacity(0.18))
                        .frame(width: 90, height: 10)
                    SmartHomeCard {
                        ForEach(0..<2, id: \.self) { idx in
                            HStack(spacing: 12) {
                                Circle().fill(Color.inkSoft.opacity(0.14)).frame(width: 26, height: 26)
                                VStack(alignment: .leading, spacing: 6) {
                                    RoundedRectangle(cornerRadius: 4).fill(Color.inkSoft.opacity(0.16)).frame(width: 120, height: 11)
                                    RoundedRectangle(cornerRadius: 4).fill(Color.inkSoft.opacity(0.10)).frame(width: 70, height: 9)
                                }
                                Spacer(minLength: 0)
                                Capsule().fill(Color.inkSoft.opacity(0.12)).frame(width: 54, height: 30)
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                            if idx == 0 { SmartHomeDivider() }
                        }
                    }
                }
            }
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Loading the house…")
                    .font(.system(.subheadline, design: .rounded))
                    .foregroundStyle(Color.inkSoft)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 4)
        }
        .opacity(reduceMotion ? 1 : (pulse ? 0.55 : 1))
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: pulse)
        .onAppear { if !reduceMotion { pulse = true } }
        .accessibilityIdentifier("house-loading")
    }
}

/// The top-level empty / away state. Two flavors:
/// - Nothing configured: "Nothing set up yet" + the Settings pointer.
/// - Configured but away/unreachable: "Not home" + "showing last known".
struct SmartHomeEmptyState: View {
    let systemImage: String
    let title: String
    let message: String
    var accessibilityId: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 40, weight: .semibold))
                .foregroundStyle(Color.bacanGreen.opacity(0.85))
            Text(title)
                .font(.system(.title3, design: .rounded).weight(.semibold))
                .foregroundStyle(Color.ink)
                .multilineTextAlignment(.center)
            Text(message)
                .font(.system(.subheadline, design: .rounded))
                .foregroundStyle(Color.inkSoft)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
        .padding(.horizontal, 24)
        .accessibilityIdentifier(accessibilityId)
    }
}

// MARK: - HVAC live glow (W2a)

/// The active-HVAC tint for a Nest thermostat card: a gentle warm wash while **heating**, a cool wash
/// while **cooling**, nothing when idle/off. Surfaces `NestThermostat.hvacStatus` — captured "for the
/// UI's live glow" but previously invisible. Reduce-Motion friendly: a static tint (no pulse) when the
/// user asks for reduced motion; otherwise a slow, gentle breathing opacity.
struct HVACGlow: ViewModifier {
    /// The tint to wash the card with, or nil when the thermostat isn't actively running.
    let tint: Color?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    func body(content: Content) -> some View {
        content
            .background {
                if let tint {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(tint.opacity(reduceMotion ? 0.16 : (pulse ? 0.22 : 0.10)))
                        .animation(
                            reduceMotion ? nil : .easeInOut(duration: 1.6).repeatForever(autoreverses: true),
                            value: pulse
                        )
                        .onAppear { if !reduceMotion { pulse = true } }
                        .allowsHitTesting(false)
                }
            }
    }
}

extension View {
    /// Wash a thermostat card with its live-HVAC glow (see ``HVACGlow``). Pass nil for idle/off.
    func hvacGlow(_ tint: Color?) -> some View { modifier(HVACGlow(tint: tint)) }
}

// MARK: - Helpers

extension View {
    /// Apply an `accessibilityIdentifier` only when one is provided — lets the shared rows keep every
    /// existing id while staying optional for callers that don't need one.
    @ViewBuilder
    func axID(_ id: String?) -> some View {
        if let id { accessibilityIdentifier(id) } else { self }
    }
}

// MARK: - Previews

#Preview("Components gallery") {
    ScrollView {
        VStack(alignment: .leading, spacing: 20) {
            // Badges
            VStack(alignment: .leading, spacing: 6) {
                SmartHomeSectionHeader(title: "Loading", badge: .loading)
                SmartHomeSectionHeader(title: "Offline", badge: .unreachable)
            }
            // DeviceRow + ControlPill dialects
            VStack(alignment: .leading, spacing: 6) {
                SmartHomeSectionHeader(title: "Device rows")
                SmartHomeCard {
                    DeviceRow(icon: "lock.fill", iconTint: .bacanGreen, iconSize: 18,
                              title: "Front Door", status: "Locked", statusTint: .bacanGreen) {
                        ControlPill(title: "Unlock", systemImage: "lock.open", tint: .terracotta, id: "u") {}
                    }
                    SmartHomeDivider()
                    DeviceRow(icon: "powerplug.fill", iconTint: .bacanGreen, title: "Lamp Plug", status: "On",
                              statusTint: .bacanGreen) {
                        HStack(spacing: 6) {
                            IconButton("minus", id: "m") {}
                            IconButton("plus", id: "p") {}
                        }
                    }
                    SmartHomeDivider()
                    DeviceRow(icon: "door.garage.open", iconTint: .terracotta, iconSize: 18,
                              title: "Garage", status: "Open", statusTint: .terracotta) {
                        ControlPill(title: "Close", systemImage: "door.garage.closed", tint: .bacanGreen, id: "c") {}
                    }
                }
            }
            SmartHomeEmptyState(systemImage: "house", title: "Nothing set up yet",
                                message: "Add a device in Settings → Smart home.", accessibilityId: "empty")
        }
        .padding()
    }
    .background(Color.familyCanvas)
}

#Preview("Loading skeleton") {
    ScrollView { SmartHomeSkeleton().padding() }
        .background(Color.familyCanvas)
}
