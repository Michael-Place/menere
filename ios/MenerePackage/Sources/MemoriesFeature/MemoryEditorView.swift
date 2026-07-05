import ComposableArchitecture
import FamilyDomain
import MenereUI
import SwiftUI
import UIKit

/// The warm create/edit sheet for a **memory** (P28-C2): the story (``RichNoteEditor``), one or more
/// photos (``PhotoCaptureField`` + "Make it a sticker ✂️" subject-lift), a date, kid tagging, and an
/// optional milestone. Save uploads photos/stickers and writes the ``Memory``.
public struct MemoryEditorView: View {
    @Bindable var store: StoreOf<MemoryEditorReducer>

    public init(store: StoreOf<MemoryEditorReducer>) {
        self.store = store
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    titleField
                    storyField
                    photosSection
                    dateField
                    kidsSection
                    milestoneSection
                    if store.isEditing { deleteButton }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 16)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Color.familyCanvas)
            .navigationTitle(store.isEditing ? "Edit memory" : "New memory")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { store.send(.cancelTapped) }
                        .accessibilityIdentifier("memory-cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { store.send(.saveTapped) }
                        .fontWeight(.semibold)
                        .disabled(!store.canSave || store.isSaving)
                        .accessibilityIdentifier("memory-save")
                }
            }
            .task { store.send(.task) }
        }
    }

    // MARK: Title

    private var titleField: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("A little headline", symbol: "sparkle")
            TextField(
                "Oliver's first word!",
                text: Binding(get: { store.memory.title ?? "" }, set: { store.memory.title = $0 })
            )
            .font(.system(.title3, design: .rounded).weight(.semibold))
            .foregroundStyle(Color.ink)
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.familySurface))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.inkSoft.opacity(0.16), lineWidth: 1))
            .accessibilityIdentifier("memory-title-field")
        }
    }

    // MARK: Story (rich text)

    private var storyField: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("What happened?", symbol: "text.alignleft")
            RichNoteEditor(
                markdown: $store.memory.richText,
                placeholder: "Oliver said his first word today — “agua!” — pointing right at the sink…",
                minHeight: 130
            )
        }
    }

    // MARK: Photos + stickers

    private var photosSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel("Photos", symbol: "photo.stack")

            if !store.slots.isEmpty {
                VStack(spacing: 14) {
                    ForEach(store.slots) { slot in
                        photoSlotCard(slot)
                    }
                }
            }

            // Add another photo — the reusable capture control (PhotosPicker + camera + crop + compress).
            PhotoCaptureField(
                image: nil,
                fallbackSymbol: "photo.badge.plus",
                tint: .terracotta
            ) { processed in
                store.send(.photoAdded(processed.jpeg))
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.familySurface))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.inkSoft.opacity(0.16), lineWidth: 1))
        }
    }

    // Bytes to render for a slot's photo/sticker: a fresh pick wins over the loaded existing one.
    private func photoData(for slot: MemoryPhotoSlot) -> Data? {
        if let d = slot.photoData { return d }
        if let p = slot.existingPhotoPath { return store.loadedImages[p] }
        return nil
    }

    private func stickerData(for slot: MemoryPhotoSlot) -> Data? {
        if let d = slot.stickerData { return d }
        if let p = slot.existingStickerPath { return store.loadedImages[p] }
        return nil
    }

    @ViewBuilder
    private func photoSlotCard(_ slot: MemoryPhotoSlot) -> some View {
        let photo = photoData(for: slot).flatMap { UIImage(data: $0) }
        let sticker = stickerData(for: slot).flatMap { UIImage(data: $0) }
        VStack(spacing: 10) {
            HStack(spacing: 14) {
                if let sticker {
                    StickerImage(image: sticker, slapOnAppear: false)
                        .frame(width: 78, height: 78)
                } else if let photo {
                    Image(uiImage: photo)
                        .resizable().scaledToFill()
                        .frame(width: 78, height: 78)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                } else {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.terracotta.opacity(0.15))
                        .frame(width: 78, height: 78)
                        .overlay(ProgressView())
                }

                VStack(alignment: .leading, spacing: 8) {
                    stickerAffordance(slot)
                    Button(role: .destructive) {
                        store.send(.removeSlot(id: slot.id))
                    } label: {
                        Label("Remove", systemImage: "trash")
                            .font(.system(.subheadline, design: .rounded))
                    }
                    .buttonStyle(.pressable)
                    .accessibilityIdentifier("memory-remove-photo")
                }
                Spacer()
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.familySurface))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.inkSoft.opacity(0.12), lineWidth: 1))
    }

    @ViewBuilder
    private func stickerAffordance(_ slot: MemoryPhotoSlot) -> some View {
        if slot.hasSticker {
            Label("Sticker ready ✂️", systemImage: "checkmark.seal.fill")
                .font(.system(.subheadline, design: .rounded).weight(.semibold))
                .foregroundStyle(Color.bacanGreen)
        } else if slot.isLifting {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Lifting the subject…").font(.subheadline).foregroundStyle(Color.inkSoft)
            }
        } else {
            VStack(alignment: .leading, spacing: 2) {
                Button {
                    store.send(.makeStickerTapped(id: slot.id))
                } label: {
                    Label("Make it a sticker ✂️", systemImage: "scissors")
                        .font(.system(.subheadline, design: .rounded).weight(.semibold))
                }
                .buttonStyle(.pressable)
                .accessibilityIdentifier("memory-make-sticker")
                if slot.stickerFailed {
                    Text("Couldn't lift a clean subject — the photo's lovely as-is.")
                        .font(.caption2).foregroundStyle(Color.inkSoft)
                }
            }
        }
    }

    // MARK: Date

    private var dateField: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("When was this?", symbol: "calendar")
            DatePicker(
                "",
                selection: $store.memory.date,
                in: ...Date(),
                displayedComponents: .date
            )
            .labelsHidden()
            .datePickerStyle(.compact)
            .tint(Color.bacanGreen)
            .accessibilityIdentifier("memory-date-picker")
        }
    }

    // MARK: Kid tagging

    private var kidsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel("Who's this about?", symbol: "person.2.fill")
            FlowChips(items: store.taggableMembers.map(\.id)) { id in
                if let member = store.taggableMembers.first(where: { $0.id == id }) {
                    let selected = store.memory.kidMemberIds.contains(id)
                    let color = memberColor(member)
                    Button {
                        store.send(.toggleKid(id))
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: member.avatarSystemName)
                            Text(firstName(member.name))
                        }
                        .font(.system(.subheadline, design: .rounded).weight(.semibold))
                        .foregroundStyle(selected ? .white : color)
                        .padding(.horizontal, 14).padding(.vertical, 9)
                        .background(
                            Capsule(style: .continuous)
                                .fill(selected ? color : color.opacity(0.14))
                        )
                    }
                    .buttonStyle(.pressable)
                    .accessibilityIdentifier("memory-kid-\(id)")
                }
            }
        }
    }

    // MARK: Milestone

    private var milestoneSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel("Milestone", symbol: "star.fill")
            FlowChips(items: Milestone.suggestions) { tag in
                let selected = store.memory.milestone == tag
                Button {
                    store.send(.milestoneChipTapped(tag))
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: Milestone.symbol(for: tag))
                        Text(tag)
                    }
                    .font(.system(.subheadline, design: .rounded).weight(.semibold))
                    .foregroundStyle(Color.ink)
                    .padding(.horizontal, 13).padding(.vertical, 8)
                    .background(
                        Capsule(style: .continuous)
                            .fill(selected ? Color.marigold : Color.marigold.opacity(0.16))
                    )
                }
                .buttonStyle(.pressable)
                .accessibilityIdentifier("memory-milestone-\(tag)")
            }
            // Free text — anything goes.
            TextField(
                "…or write your own",
                text: Binding(get: { store.memory.milestone ?? "" }, set: { store.memory.milestone = $0 })
            )
            .font(.system(.subheadline, design: .rounded))
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.familySurface))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.inkSoft.opacity(0.14), lineWidth: 1))
            .accessibilityIdentifier("memory-milestone-field")
        }
    }

    private var deleteButton: some View {
        Button(role: .destructive) {
            store.send(.deleteTapped)
        } label: {
            Label("Delete memory", systemImage: "trash")
                .font(.system(.headline, design: .rounded))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
        }
        .buttonStyle(.pressable)
        .accessibilityIdentifier("memory-delete")
        .padding(.top, 8)
    }

    // MARK: Helpers

    private func sectionLabel(_ text: String, symbol: String) -> some View {
        Label(text, systemImage: symbol)
            .font(.system(.subheadline, design: .rounded).weight(.bold))
            .foregroundStyle(Color.inkSoft)
    }

    private func memberColor(_ member: HouseholdMember) -> Color {
        let rgb = member.color.rgb
        return Color(red: rgb.red, green: rgb.green, blue: rgb.blue)
    }

    private func firstName(_ name: String) -> String {
        name.split(separator: " ").first.map(String.init) ?? name
    }
}

// MARK: - FlowChips

/// A simple wrapping chip row (a lightweight flow layout) for the kid + milestone chips.
struct FlowChips<Content: View>: View {
    let items: [String]
    @ViewBuilder let content: (String) -> Content

    var body: some View {
        FlowLayout(spacing: 8) {
            ForEach(items, id: \.self) { content($0) }
        }
    }
}

/// A minimal flow layout that wraps its subviews to the next line when they'd overflow the width.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
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
        let maxWidth = bounds.width
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            view.place(at: CGPoint(x: bounds.minX + x, y: bounds.minY + y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
