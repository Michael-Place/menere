import AgentTools
import ComposableArchitecture
import MenereUI
import SwiftUI

/// The assistant chat sheet — sparkles header, streaming bubbles, action-chip receipts, an inline
/// security-confirmation card, and a dictation-friendly composer. Warm, uncluttered, family-voice.
public struct AssistantView: View {
    @Bindable var store: StoreOf<AssistantReducer>
    @FocusState private var inputFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(store: StoreOf<AssistantReducer>) {
        self.store = store
    }

    public var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                conversation
                composer
            }
            .background(Color.familyCanvas)
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if !store.messages.isEmpty {
                        Button { store.send(.newChatTapped) } label: {
                            Image(systemName: "square.and.pencil")
                        }
                        .tint(.bacanGreen)
                        .accessibilityLabel("New chat")
                        .accessibilityIdentifier("assistant-new-chat")
                    }
                }
                ToolbarItem(placement: .principal) {
                    HStack(spacing: 6) {
                        Image(systemName: "sparkles").foregroundStyle(Color.bacanGreen)
                        Text("Bacán").font(.headline).foregroundStyle(Color.ink)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Bacán assistant")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { store.send(.dismissTapped) }
                        .accessibilityIdentifier("assistant-done")
                }
            }
            .task { store.send(.task) }
        }
        .tint(.bacanGreen)
        .presentationDragIndicator(.visible)
    }

    // MARK: Conversation

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if store.messages.isEmpty {
                        emptyState
                    } else {
                        ForEach(store.messages) { message in
                            row(for: message).id(message.id)
                        }
                    }
                    if let pending = store.pendingConfirmation {
                        confirmationCard(pending).id("confirmation")
                    }
                    // Anchor for auto-scroll.
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 18)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: store.messages.count) { _, _ in scrollToBottom(proxy) }
            .onChange(of: store.pendingConfirmation) { _, _ in scrollToBottom(proxy) }
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        let target = store.pendingConfirmation != nil ? "confirmation" : "bottom"
        if reduceMotion {
            proxy.scrollTo(target, anchor: .bottom)
        } else {
            withAnimation(.menereSnappy) { proxy.scrollTo(target, anchor: .bottom) }
        }
    }

    @ViewBuilder
    private func row(for message: ChatMessage) -> some View {
        switch message.kind {
        case let .user(text):
            userBubble(text)
        case let .assistant(text):
            assistantBubble(text)
        case let .receipts(receipts):
            receiptCluster(receipts)
        case let .toolActivity(name):
            activityLine(name)
        case let .error(text):
            errorBubble(text)
        }
    }

    private func userBubble(_ text: String) -> some View {
        HStack {
            Spacer(minLength: 44)
            Text(text)
                .foregroundStyle(Color.white)
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(Color.bacanGreen, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private func assistantBubble(_ text: String) -> some View {
        HStack {
            Text(text)
                .foregroundStyle(Color.ink)
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(Color.familySurface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(Color.ink.opacity(0.06), lineWidth: 1)
                )
            Spacer(minLength: 44)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func errorBubble(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.circle")
                .foregroundStyle(Color.terracotta)
                .padding(.top, 2)
            Text(text).foregroundStyle(Color.ink)
            Spacer(minLength: 44)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(Color.terracotta.opacity(0.10), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func receiptCluster(_ receipts: [AgentReceipt]) -> some View {
        FlowLayout(spacing: 8) {
            ForEach(Array(receipts.enumerated()), id: \.offset) { _, receipt in
                HStack(spacing: 5) {
                    Image(systemName: receipt.icon).font(.caption)
                    Text(receipt.line).font(.caption.weight(.semibold))
                }
                .foregroundStyle(Color.bacanGreen)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(Color.bacanGreen.opacity(0.12), in: Capsule())
                .accessibilityIdentifier("assistant-receipt")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func activityLine(_ name: String) -> some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small).tint(Color.inkSoft)
            Text(AssistantToolLabels.activity(for: name))
                .font(.caption)
                .foregroundStyle(Color.inkSoft)
        }
        .accessibilityIdentifier("assistant-activity")
    }

    // MARK: Confirmation card

    private func confirmationCard(_ pending: PendingConfirmation) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "hand.raised.fill").foregroundStyle(Color.terracotta)
                Text(pending.description)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.ink)
            }
            HStack(spacing: 10) {
                Button {
                    store.send(.confirmationResponded(false))
                } label: {
                    Text("Cancel")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Color.familySurface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .foregroundStyle(Color.ink)
                }
                .buttonStyle(.pressable)
                .accessibilityIdentifier("assistant-confirm-cancel")

                Button {
                    store.send(.confirmationResponded(true))
                } label: {
                    Text("Confirm")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Color.terracotta, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .foregroundStyle(Color.white)
                }
                .buttonStyle(.pressable)
                .accessibilityIdentifier("assistant-confirm-confirm")
            }
        }
        .padding(16)
        .background(Color.terracotta.opacity(0.08), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.terracotta.opacity(0.35), lineWidth: 1)
        )
        .accessibilityIdentifier("assistant-confirmation-card")
    }

    // MARK: Empty state

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: "sparkles")
                    .font(.system(size: 34))
                    .foregroundStyle(Color.bacanGreen)
                Text(greeting)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Color.ink)
                Text("Ask about today, add to a list, or nudge the house along.")
                    .font(.subheadline)
                    .foregroundStyle(Color.inkSoft)
            }
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Self.examplePrompts, id: \.self) { prompt in
                    Button {
                        store.send(.examplePromptTapped(prompt))
                        inputFocused = true
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "arrow.up.forward.app").font(.caption)
                            Text(prompt).font(.subheadline.weight(.medium))
                            Spacer()
                        }
                        .foregroundStyle(Color.bacanGreen)
                        .padding(.horizontal, 14).padding(.vertical, 12)
                        .background(Color.familySurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .strokeBorder(Color.bacanGreen.opacity(0.20), lineWidth: 1)
                        )
                    }
                    .buttonStyle(.pressable)
                    .accessibilityIdentifier("assistant-example-prompt")
                }
            }
        }
        .padding(.top, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var greeting: String {
        if let name = store.firstName, !name.isEmpty {
            return "Hi \(name) — what can I do?"
        }
        return "Hi there — what can I do?"
    }

    static let examplePrompts = [
        "What's on today?",
        "Add milk to the grocery list",
        "Did I water the plants?",
    ]

    // MARK: Composer

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField("Message Bacán", text: $store.input, axis: .vertical)
                .lineLimit(1...5)
                .focused($inputFocused)
                .textInputAutocapitalization(.sentences)
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(Color.familySurface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .strokeBorder(Color.ink.opacity(0.08), lineWidth: 1)
                )
                .disabled(store.pendingConfirmation != nil)
                .accessibilityIdentifier("assistant-input")

            Button {
                inputFocused = false
                store.send(.sendTapped)
            } label: {
                Group {
                    if store.isThinking {
                        ProgressView().tint(.white)
                    } else {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 18, weight: .bold))
                            .foregroundStyle(.white)
                    }
                }
                .frame(width: 38, height: 38)
                .background(store.canSend ? Color.bacanGreen : Color.inkSoft.opacity(0.4), in: Circle())
            }
            .buttonStyle(.pressable)
            .disabled(!store.canSend)
            .accessibilityLabel("Send")
            .accessibilityIdentifier("assistant-send")
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .background(Color.familyCanvas)
        .overlay(alignment: .top) {
            Rectangle().fill(Color.ink.opacity(0.06)).frame(height: 1)
        }
    }
}

// MARK: - FlowLayout (wrapping chip cluster)

/// A minimal wrapping layout so receipt chips flow onto multiple lines instead of truncating.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var rows: [[CGSize]] = [[]]
        var x: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, !rows[rows.count - 1].isEmpty {
                rows.append([])
                x = 0
            }
            rows[rows.count - 1].append(size)
            x += size.width + spacing
        }
        let height = rows.reduce(CGFloat(0)) { acc, row in
            acc + (row.map(\.height).max() ?? 0) + spacing
        } - (rows.isEmpty ? 0 : spacing)
        return CGSize(width: maxWidth == .infinity ? x : maxWidth, height: max(height, 0))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
        let maxWidth = bounds.width
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > bounds.minX + maxWidth, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
