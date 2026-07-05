import ComposableArchitecture
import MenereUI
import SwiftUI

/// The Memories tab's SHELL view (P28-C1): a warm, on-brand empty state that tells the family what's
/// coming, plus a *disabled* "Capture a moment" button. C2 replaces the placeholder with the real
/// scrapbook timeline + editor and enables the button.
public struct MemoriesView: View {
    @Bindable var store: StoreOf<MemoriesReducer>

    public init(store: StoreOf<MemoriesReducer>) {
        self.store = store
    }

    public var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                Spacer(minLength: 40)

                Image(systemName: "book.closed.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(Color.bacanGreen)
                    .padding(24)
                    .background(
                        Circle().fill(Color.bacanGreen.opacity(0.12))
                    )

                VStack(spacing: 10) {
                    Text("Your family's memories\nwill live here 📖")
                        .familyDisplay()
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)

                    Text("Oliver's first words, Famfis's milestones, the everyday magic — a warm little scrapbook, coming soon.")
                        .familyTitle(.subheadline)
                        .foregroundStyle(Color.inkSoft)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 24)
                }

                Button {
                    store.send(.captureMomentTapped)
                } label: {
                    Label("Capture a moment", systemImage: "camera.fill")
                        .font(.system(.headline, design: .rounded).weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 15)
                        .background(
                            Capsule(style: .continuous).fill(Color.bacanGreen)
                        )
                }
                .buttonStyle(.pressable)
                .disabled(true)   // C2 wires up the capture flow.
                .opacity(0.55)
                .padding(.horizontal, 32)
                .accessibilityIdentifier("memories-capture-moment")

                Text("Coming soon")
                    .font(.system(.caption, design: .rounded).weight(.semibold))
                    .foregroundStyle(Color.inkSoft)

                Spacer(minLength: 40)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal)
            .padding(.vertical, 12)
        }
        .background(Color.familyCanvas)
        .navigationTitle("Memories")
        .navigationBarTitleDisplayMode(.inline)
        .task { store.send(.task) }
    }
}
