import FamilyDomain
import MenereUI
import SwiftUI

// MARK: - Servings scaler math (pure, non-destructive)

/// Proportional servings scaling + pretty fraction formatting for ingredient quantities.
///
/// Everything here is a pure computation over a `Recipe`/`Ingredient` — it never mutates the
/// stored recipe. The detail screen and Cook Mode both display *scaled* lines; the underlying
/// recipe (its `servings` and ingredient quantities) is untouched.
enum ServingsMath {
    /// The multiplier to go from a recipe's own servings to a target. Guards a zero/absent original.
    static func scale(target: Int, original: Int) -> Double {
        guard original > 0 else { return 1 }
        return Double(target) / Double(original)
    }

    /// The common cooking fractions we snap to, as (value, unicode glyph). Eighths + thirds cover
    /// essentially every kitchen measure; the empty-glyph entries mark "no fraction" boundaries.
    private static let fractionGlyphs: [(value: Double, glyph: String)] = [
        (0, ""), (1.0 / 8, "⅛"), (1.0 / 4, "¼"), (1.0 / 3, "⅓"), (3.0 / 8, "⅜"),
        (1.0 / 2, "½"), (5.0 / 8, "⅝"), (2.0 / 3, "⅔"), (3.0 / 4, "¾"), (7.0 / 8, "⅞"), (1, ""),
    ]

    /// Format a quantity as "1½", "¾", "2", "⅓" — snapping the fractional part to the nearest
    /// common cooking fraction when it lands close (within tolerance), else a trimmed decimal.
    static func pretty(_ value: Double) -> String {
        guard value > 0 else { return "0" }
        let whole = Int(value.rounded(.down))
        let frac = value - Double(whole)

        var best = fractionGlyphs[0]
        var bestDist = Double.greatestFiniteMagnitude
        for f in fractionGlyphs where abs(frac - f.value) < bestDist {
            bestDist = abs(frac - f.value)
            best = f
        }

        let tolerance = 0.06
        if bestDist <= tolerance {
            if best.value >= 1.0 { return String(whole + 1) }      // frac rounded up to a whole
            if best.glyph.isEmpty {                                // snapped to a clean whole
                return whole >= 1 ? String(whole) : decimalString(value)
            }
            return whole == 0 ? best.glyph : "\(whole)\(best.glyph)"
        }
        return decimalString(value)
    }

    /// A trimmed 2-decimal fallback ("0.4", "1.75", "3") for quantities that don't snap cleanly.
    private static func decimalString(_ value: Double) -> String {
        let rounded = (value * 100).rounded() / 100
        if rounded == rounded.rounded() { return String(Int(rounded)) }
        var s = String(format: "%.2f", rounded)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s
    }

    /// A scaled "1½ cups flour" line for one ingredient. Ingredients with no quantity
    /// ("salt to taste") pass through with their unit/name unchanged — nothing to scale.
    static func scaledLine(_ ing: Ingredient, scale: Double) -> String {
        var parts: [String] = []
        if let q = ing.quantity { parts.append(pretty(q * scale)) }
        if let unit = ing.unit, !unit.isEmpty { parts.append(unit) }
        parts.append(ing.name)
        return parts.joined(separator: " ")
    }
}

// MARK: - Cook Mode

/// A full-screen, distraction-free cooking view: big rounded type, one instruction at a time,
/// tap to advance, an accessible scaled-ingredients sheet, and the screen kept awake throughout.
///
/// Read-only over the recipe — servings scaling here (like on the detail) is display-only.
struct CookModeView: View {
    let recipe: Recipe
    /// Seeds the in-cook servings scaler (carried over from the detail screen's choice).
    let initialServings: Int

    @Environment(\.dismiss) private var dismiss
    @State private var step = 0
    @State private var targetServings: Int
    @State private var showIngredients = false

    init(recipe: Recipe, initialServings: Int) {
        self.recipe = recipe
        self.initialServings = initialServings
        _targetServings = State(initialValue: max(1, initialServings))
    }

    private var steps: [String] { recipe.instructions }
    private var scale: Double { ServingsMath.scale(target: targetServings, original: recipe.servings) }
    private var isLastStep: Bool { step >= steps.count - 1 }

    var body: some View {
        ZStack {
            Color.familyCanvas.ignoresSafeArea()

            if steps.isEmpty {
                emptyState
            } else {
                content
            }
        }
        .sheet(isPresented: $showIngredients) { ingredientsSheet }
        .sensoryFeedback(.selection, trigger: step)
        // Keep the screen awake while cooking — reset on the way out.
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
    }

    // MARK: Main content

    private var content: some View {
        VStack(spacing: 0) {
            header

            // Big step card — tap anywhere to advance.
            Button {
                advance()
            } label: {
                VStack(spacing: 20) {
                    Spacer(minLength: 0)
                    Text("Step \(step + 1) of \(steps.count)")
                        .font(.system(.headline, design: .rounded).weight(.bold))
                        .foregroundStyle(Color.bacanGreen)
                        .textCase(.uppercase)
                        .tracking(1.2)

                    Text(steps[step])
                        .font(.system(size: 30, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.ink)
                        .multilineTextAlignment(.center)
                        .lineSpacing(6)
                        .minimumScaleFactor(0.6)
                        .padding(.horizontal, 28)
                        .id(step) // re-triggers the transition on change
                        .transition(.asymmetric(
                            insertion: .move(edge: .trailing).combined(with: .opacity),
                            removal: .move(edge: .leading).combined(with: .opacity)
                        ))
                    Spacer(minLength: 0)

                    Label(isLastStep ? "Tap for the finish" : "Tap to continue",
                          systemImage: isLastStep ? "checkmark.circle" : "hand.tap")
                        .font(.system(.subheadline, design: .rounded))
                        .foregroundStyle(Color.inkSoft)
                        .padding(.bottom, 8)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            footer
        }
    }

    private var header: some View {
        VStack(spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(recipe.title)
                    .familyTitle(.title2)
                    .lineLimit(2)
                Spacer(minLength: 12)
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(Color.inkSoft)
                        .symbolRenderingMode(.hierarchical)
                }
                .accessibilityLabel("Close cook mode")
            }

            // Step progress bar.
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.bacanGreen.opacity(0.15))
                    Capsule().fill(Color.bacanGreen)
                        .frame(width: geo.size.width * progressFraction)
                }
            }
            .frame(height: 6)
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
    }

    private var progressFraction: CGFloat {
        guard steps.count > 1 else { return 1 }
        return CGFloat(step + 1) / CGFloat(steps.count)
    }

    private var footer: some View {
        HStack(spacing: 14) {
            Button { back() } label: {
                Image(systemName: "chevron.left")
                    .font(.system(.title3, design: .rounded).weight(.bold))
                    .frame(width: 54, height: 54)
                    .background(Color.bacanGreen.opacity(step == 0 ? 0.08 : 0.16))
                    .foregroundStyle(step == 0 ? Color.inkSoft : Color.bacanGreen)
                    .clipShape(Circle())
            }
            .disabled(step == 0)

            Button { showIngredients = true } label: {
                Label("Ingredients", systemImage: "list.bullet")
                    .font(.system(.headline, design: .rounded).weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .frame(height: 54)
                    .background(Color.bacanGreen.opacity(0.16))
                    .foregroundStyle(Color.bacanGreen)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }

            Button { advance() } label: {
                Image(systemName: isLastStep ? "checkmark" : "chevron.right")
                    .font(.system(.title3, design: .rounded).weight(.bold))
                    .frame(width: 54, height: 54)
                    .background(Color.bacanGreen)
                    .foregroundStyle(.white)
                    .clipShape(Circle())
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "text.badge.xmark")
                .font(.system(size: 44))
                .foregroundStyle(Color.inkSoft)
            Text("No steps to cook yet")
                .familyTitle()
            Text("Add a few instructions to \(recipe.title) and they'll show up here, one at a time.")
                .font(.system(.subheadline, design: .rounded))
                .foregroundStyle(Color.inkSoft)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Button("Done") { dismiss() }
                .font(.system(.headline, design: .rounded).weight(.semibold))
                .foregroundStyle(Color.bacanGreen)
                .padding(.top, 8)
        }
    }

    // MARK: Ingredients sheet (scaler lives here so it's reachable mid-cook)

    private var ingredientsSheet: some View {
        NavigationStack {
            List {
                Section {
                    Stepper(value: $targetServings, in: 1...48) {
                        HStack {
                            Text("Serves").foregroundStyle(Color.ink)
                            Spacer()
                            Text("\(targetServings)")
                                .font(.system(.body, design: .rounded).weight(.bold))
                                .foregroundStyle(Color.bacanGreen)
                            if targetServings != recipe.servings {
                                Text("(was \(recipe.servings))")
                                    .font(.caption).foregroundStyle(Color.inkSoft)
                            }
                        }
                    }
                    .listRowBackground(Color.familySurface)
                }

                Section("Ingredients") {
                    if recipe.ingredients.isEmpty {
                        Text("No ingredients listed.").foregroundStyle(Color.inkSoft)
                            .listRowBackground(Color.familySurface)
                    } else {
                        ForEach(recipe.ingredients) { ing in
                            Text(ServingsMath.scaledLine(ing, scale: scale))
                                .font(.system(.body, design: .rounded))
                                .foregroundStyle(Color.ink)
                                .listRowBackground(Color.familySurface)
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.familyCanvas)
            .navigationTitle("Ingredients")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { showIngredients = false }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    // MARK: Step navigation

    private func advance() {
        guard !steps.isEmpty else { return }
        if isLastStep {
            dismiss()
            return
        }
        withAnimation(.snappy) { step += 1 }
    }

    private func back() {
        guard step > 0 else { return }
        withAnimation(.snappy) { step -= 1 }
    }
}
