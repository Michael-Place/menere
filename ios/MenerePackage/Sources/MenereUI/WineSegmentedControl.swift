import SwiftUI

/// A wine-stack segmented control that sits naturally on parchment. The default system
/// `UISegmentedControl` renders a white/gray pill that glares on the "Cellar & Candlelight"
/// parchment; this replaces it with a warm inkSoft-tinted track and a sliding Bordeaux selection
/// pill under a fixed-cream label — legible in both light and dark.
///
/// Deliberately a bespoke SwiftUI view rather than a `UISegmentedControl.appearance(...)` override:
/// appearance-proxy scoping is fragile in SwiftUI and would risk leaking into the family screens'
/// stock segmented controls (e.g. Kitchen's Recipes / Meal-plan picker). Because this is an ordinary
/// view, its styling is contained to wherever it is used — zero family impact by construction. Use it
/// only inside the wine stack; pair with `.wineChrome()`. Attach `.selectionHaptic(_:)` at the call
/// site for the brand "selection tick" (as the old `Picker` did).
public struct WineSegmentedControl<Value: Hashable>: View {
    @Binding private var selection: Value
    private let options: [(value: Value, label: String)]
    @Namespace private var pill

    /// A fixed warm cream for the selected label. `Color.parchment` is dynamic (near-black in dark
    /// mode) and would vanish on the fixed Bordeaux pill, so the on-pill text is pinned light in both
    /// appearances — the same relationship as a bordered-prominent wine button.
    private static var selectedLabel: Color { Color(uiColor: UIColor(hex: 0xF7F1E8)) }

    public init(selection: Binding<Value>, options: [(value: Value, label: String)]) {
        self._selection = selection
        self.options = options
    }

    public var body: some View {
        HStack(spacing: 4) {
            ForEach(options, id: \.value) { option in
                segment(option)
            }
        }
        .padding(4)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.inkSoft.opacity(0.14))
        )
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func segment(_ option: (value: Value, label: String)) -> some View {
        let isSelected = option.value == selection
        Button {
            withAnimation(.menereSnappy) { selection = option.value }
        } label: {
            Text(option.label)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(isSelected ? Self.selectedLabel : Color.inkSoft)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
                .background {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(Color.wine)
                            .shadow(color: Color.wine.opacity(0.25), radius: 3, y: 1)
                            .matchedGeometryEffect(id: "wineSegmentPill", in: pill)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

#if DEBUG
private struct WineSegmentedControlDemo: View {
    enum Tab: String, CaseIterable { case cellar = "Cellar", history = "History" }
    @State private var tab: Tab = .cellar
    var body: some View {
        ZStack {
            Color.parchment.ignoresSafeArea()
            WineSegmentedControl(
                selection: $tab,
                options: Tab.allCases.map { ($0, $0.rawValue) }
            )
            .padding()
        }
    }
}

#Preview("Wine segmented control") { WineSegmentedControlDemo() }
#endif
