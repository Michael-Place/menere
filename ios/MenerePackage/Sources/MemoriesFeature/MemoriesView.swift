import ComposableArchitecture
import FamilyDomain
import MenereUI
import SwiftUI
import UIKit

/// The Memories tab (P28-C2): a scrollable **scrapbook timeline** of the family's ``Memory`` pages,
/// newest first, gently grouped by month. Each page renders the photos/stickers as a warm collage
/// (die-cut stickers when present), the rich-text story, the date, a milestone chip, and the kids it's
/// about. A warm empty state holds the space until the first memory. Tapping a page opens it to edit.
public struct MemoriesView: View {
    @Bindable var store: StoreOf<MemoriesReducer>

    public init(store: StoreOf<MemoriesReducer>) {
        self.store = store
    }

    public var body: some View {
        Group {
            if store.memories.isEmpty {
                emptyState
            } else {
                timeline
            }
        }
        .background(Color.familyCanvas)
        .navigationTitle("Memories")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    store.send(.captureMomentTapped)
                } label: {
                    Image(systemName: "plus.circle.fill")
                }
                .accessibilityLabel("Capture a moment")
                .accessibilityIdentifier("memories-capture-toolbar")
            }
        }
        .sheet(item: $store.scope(state: \.editor, action: \.editor)) { editorStore in
            MemoryEditorView(store: editorStore)
        }
        .task { store.send(.task) }
    }

    // MARK: Timeline

    private var timeline: some View {
        VStack(spacing: 0) {
            filterChips
            content
        }
    }

    @ViewBuilder
    private var content: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 26, pinnedViews: [.sectionHeaders]) {
                lastYearSection

                if monthGroups.isEmpty {
                    filteredEmptyState
                } else {
                    ForEach(Array(monthGroups.enumerated()), id: \.element.key) { groupIndex, group in
                        Section {
                            recapCard(for: group.key)
                            // Motion & Delight — Memories' signature: scrapbook pages TUMBLE in with a
                            // slight rotation settle, like photos landing on a page. Index continues
                            // across months so the stagger reads as one falling stack.
                            ForEach(Array(group.memories.enumerated()), id: \.element.id) { pageIndex, memory in
                                pageButton(memory)
                                    .tabEntrance(.tumble, index: groupIndex + pageIndex)
                            }
                        } header: {
                            monthHeader(group)
                        }
                    }
                    captureBanner
                        .padding(.top, 6)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
    }

    private func pageButton(_ memory: Memory) -> some View {
        Button {
            store.send(.memoryTapped(memory))
        } label: {
            MemoryScrapbookPage(memory: memory, store: store)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("memory-page-\(memory.id)")
    }

    // MARK: Per-kid filter chips

    private var filterChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                filterChip(title: "All", id: nil)
                ForEach(store.members) { member in
                    filterChip(title: firstName(member.name), id: member.id, member: member)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .background(Color.familyCanvas)
    }

    private func filterChip(title: String, id: String?, member: HouseholdMember? = nil) -> some View {
        let selected = store.selectedKidId == id
        let tint: Color = member.map {
            let rgb = $0.color.rgb
            return Color(red: rgb.red, green: rgb.green, blue: rgb.blue)
        } ?? Color.bacanGreen
        return Button {
            store.send(.kidFilterSelected(id), animation: .snappy)
        } label: {
            Text(title)
                .font(.system(.subheadline, design: .rounded).weight(.semibold))
                .foregroundStyle(selected ? .white : tint)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(
                    Capsule(style: .continuous)
                        .fill(selected ? tint : tint.opacity(0.14))
                )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("memory-filter-\(id ?? "all")")
    }

    // MARK: This time last year

    @ViewBuilder
    private var lastYearSection: some View {
        let pages = store.thisTimeLastYear
        if !pages.isEmpty {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 6) {
                    Text("This time last year 💛")
                        .font(.system(.headline, design: .rounded).weight(.bold))
                        .foregroundStyle(Color.terracotta)
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 12)
                .background(Capsule(style: .continuous).fill(Color.terracotta.opacity(0.12)))
                .accessibilityIdentifier("memories-this-time-last-year")

                ForEach(pages) { memory in
                    pageButton(memory)
                }
            }
            .padding(.bottom, 6)
        }
    }

    // MARK: Month header + AI recap

    private func monthHeader(_ group: (key: String, title: String, memories: [Memory])) -> some View {
        HStack(spacing: 10) {
            Text(group.title)
                .font(.system(.headline, design: .rounded).weight(.bold))
                .foregroundStyle(Color.bacanGreen)
                .padding(.vertical, 6)
                .padding(.horizontal, 12)
                .background(Capsule(style: .continuous).fill(Color.bacanGreen.opacity(0.12)))

            Spacer(minLength: 0)

            if !recapReady(group.key) {
                Button {
                    store.send(.recapTapped(monthKey: group.key))
                } label: {
                    Label("Recap this month ✨", systemImage: "sparkles")
                        .labelStyle(.titleOnly)
                        .font(.system(.footnote, design: .rounded).weight(.semibold))
                        .foregroundStyle(Color.marigold)
                        .padding(.vertical, 6)
                        .padding(.horizontal, 10)
                        .background(Capsule(style: .continuous).fill(Color.marigold.opacity(0.16)))
                }
                .buttonStyle(.plain)
                .disabled(recapLoading(group.key))
                .accessibilityIdentifier("memory-recap-button-\(group.key)")
            }
        }
        .padding(.top, 4)
        .padding(.bottom, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.familyCanvas)
    }

    private func recapReady(_ key: String) -> Bool {
        if case .ready = store.recaps[key] { return true }
        return false
    }

    private func recapLoading(_ key: String) -> Bool {
        if case .loading = store.recaps[key] { return true }
        return false
    }

    @ViewBuilder
    private func recapCard(for key: String) -> some View {
        switch store.recaps[key] {
        case .loading:
            recapShell {
                Text("Weaving this month into a little story…")
                    .redacted(reason: .placeholder)
                    .shimmering()
            }
        case let .ready(text):
            recapShell {
                Text(text)
                    .font(.system(.subheadline, design: .rounded))
                    .foregroundStyle(Color.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityIdentifier("memory-recap-card-\(key)")
        case .failed:
            Button {
                store.send(.recapTapped(monthKey: key))
            } label: {
                recapShell {
                    Text("That recap didn't come through — tap to try again.")
                        .font(.system(.footnote, design: .rounded))
                        .foregroundStyle(Color.inkSoft)
                }
            }
            .buttonStyle(.plain)
        case .none:
            EmptyView()
        }
    }

    private func recapShell<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "sparkles")
                .font(.subheadline)
                .foregroundStyle(Color.marigold)
            content()
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.marigold.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.marigold.opacity(0.28), lineWidth: 1.5)
        )
    }

    // MARK: Filtered empty state

    private var filteredEmptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "camera.badge.ellipsis")
                .font(.system(size: 40))
                .foregroundStyle(Color.bacanGreen.opacity(0.7))
            Text(filteredEmptyCopy)
                .familyTitle(.subheadline)
                .foregroundStyle(Color.inkSoft)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
        .padding(.horizontal, 24)
        .accessibilityIdentifier("memories-filtered-empty")
    }

    private var filteredEmptyCopy: String {
        let name = store.members.first { $0.id == store.selectedKidId }.map { firstName($0.name) }
        if let name {
            return "No memories tagged with \(name) yet — capture one and it'll land right here."
        }
        return "No memories yet — start your scrapbook with one little moment."
    }

    private func firstName(_ name: String) -> String {
        name.split(separator: " ").first.map(String.init) ?? name
    }

    private var captureBanner: some View {
        Button {
            store.send(.captureMomentTapped)
        } label: {
            Label("Capture a moment", systemImage: "camera.fill")
                .font(.system(.headline, design: .rounded).weight(.semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 15)
                .background(Capsule(style: .continuous).fill(Color.bacanGreen))
        }
        .buttonStyle(.pressable)
        .accessibilityIdentifier("memories-capture-moment")
    }

    /// Memories grouped into month buckets, newest first (the timeline is already sorted newest-first).
    private var monthGroups: [(key: String, title: String, memories: [Memory])] {
        let cal = Calendar.current
        var order: [String] = []
        var buckets: [String: [Memory]] = [:]
        for memory in store.visibleMemories {
            let comps = cal.dateComponents([.year, .month], from: memory.date)
            let key = "\(comps.year ?? 0)-\(comps.month ?? 0)"
            if buckets[key] == nil { order.append(key); buckets[key] = [] }
            buckets[key]?.append(memory)
        }
        let fmt = DateFormatter()
        fmt.dateFormat = "LLLL yyyy"
        return order.map { key in
            let memories = buckets[key] ?? []
            let title = memories.first.map { fmt.string(from: $0.date) } ?? ""
            return (key, title, memories)
        }
    }

    // MARK: Empty state

    private var emptyState: some View {
        ScrollView {
            VStack(spacing: 22) {
                Spacer(minLength: 60)

                Image(systemName: "book.closed.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(Color.bacanGreen)
                    .padding(24)
                    .background(Circle().fill(Color.bacanGreen.opacity(0.12)))
                    .tabEntrance(.tumble, index: 0)

                VStack(spacing: 10) {
                    Text("Your family's memories\nlive here 📖")
                        .familyDisplay()
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)

                    Text("Oliver's first words, Famfis's milestones, the everyday magic — start your scrapbook with one little moment.")
                        .familyTitle(.subheadline)
                        .foregroundStyle(Color.inkSoft)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 24)
                }
                .tabEntrance(.tumble, index: 1)

                Button {
                    store.send(.captureMomentTapped)
                } label: {
                    Label("Capture a moment", systemImage: "camera.fill")
                        .font(.system(.headline, design: .rounded).weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 15)
                        .background(Capsule(style: .continuous).fill(Color.bacanGreen))
                }
                .buttonStyle(.pressable)
                .padding(.horizontal, 32)
                .accessibilityIdentifier("memories-capture-moment")
                .tabEntrance(.tumble, index: 2)

                Spacer(minLength: 40)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal)
            .padding(.vertical, 12)
        }
    }
}

// MARK: - MemoryScrapbookPage

/// One page in the scrapbook timeline — the marquee render. A warm paper card holding the photo/sticker
/// collage (die-cut stickers float off the page), an optional milestone ribbon, the rich-text story,
/// the date, and the kids it's about.
struct MemoryScrapbookPage: View {
    let memory: Memory
    let store: StoreOf<MemoriesReducer>

    private var photos: [ScrapbookItem] {
        memory.photoPaths.map { path in
            ScrapbookItem(id: path, image: store.photoCache[path].flatMap { UIImage(data: $0) })
        }
    }

    private var stickers: [UIImage] {
        memory.stickerPaths.compactMap { store.photoCache[$0].flatMap { UIImage(data: $0) } }
    }

    private var kids: [HouseholdMember] {
        memory.kidMemberIds.compactMap { id in store.members.first { $0.id == id } }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let milestone = memory.milestone, !milestone.isEmpty {
                milestoneRibbon(milestone)
            }

            if !photos.isEmpty || !stickers.isEmpty {
                collage
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
            }

            if let title = memory.title, !title.isEmpty {
                Text(title)
                    .font(.system(.title3, design: .rounded).weight(.bold))
                    .foregroundStyle(Color.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !memory.plainStory.isEmpty {
                RichNoteText(markdown: memory.richText)
            }

            footer
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color.familySurface)
                .shadow(color: .black.opacity(0.08), radius: 10, x: 0, y: 4)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(Color.marigold.opacity(0.35), lineWidth: 3)
        )
    }

    // The photo collage with any die-cut stickers floating on top.
    private var collage: some View {
        ZStack {
            if !photos.isEmpty {
                ScrapbookCollage(items: photos, baseWidth: photos.count == 1 ? 210 : 170) { _ in
                    fallbackTile
                }
            } else if let hero = stickers.first {
                // Sticker-only page: the die-cut cut-out is the hero.
                StickerImage(image: hero)
                    .frame(width: 200, height: 200)
            }
        }
        .overlay(alignment: .topTrailing) {
            // The classic "cut-out of the boy popping off the page" — float stickers over the photos.
            if !photos.isEmpty, let first = stickers.first {
                StickerImage(image: first)
                    .frame(width: 92, height: 92)
                    .rotationEffect(.degrees(Scrapbook.tilt(for: memory.id + "s0", max: 8)))
                    .offset(x: 10, y: -6)
            }
        }
        .overlay(alignment: .bottomLeading) {
            if !photos.isEmpty, stickers.count > 1 {
                StickerImage(image: stickers[1])
                    .frame(width: 78, height: 78)
                    .rotationEffect(.degrees(Scrapbook.tilt(for: memory.id + "s1", max: 8)))
                    .offset(x: -6, y: 8)
            }
        }
    }

    private var fallbackTile: some View {
        ZStack {
            LinearGradient(
                colors: [Color.terracotta.opacity(0.3), Color.marigold.opacity(0.18)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
            Image(systemName: "photo").font(.system(size: 30)).foregroundStyle(Color.terracotta.opacity(0.6))
        }
    }

    private func milestoneRibbon(_ milestone: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: Milestone.symbol(for: milestone))
            Text(milestone)
        }
        .font(.system(.subheadline, design: .rounded).weight(.bold))
        .foregroundStyle(Color.ink)
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(Capsule(style: .continuous).fill(Color.marigold.opacity(0.9)))
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Text(memory.date, format: .dateTime.weekday(.abbreviated).month(.abbreviated).day().year())
                .font(.system(.caption, design: .rounded).weight(.semibold))
                .foregroundStyle(Color.inkSoft)
            Spacer()
            HStack(spacing: -8) {
                ForEach(kids) { kid in
                    let rgb = kid.color.rgb
                    let color = Color(red: rgb.red, green: rgb.green, blue: rgb.blue)
                    Image(systemName: kid.avatarSystemName)
                        .font(.footnote)
                        .foregroundStyle(color)
                        .frame(width: 30, height: 30)
                        .background(Circle().fill(color.opacity(0.16)))
                        .overlay(Circle().stroke(Color.familySurface, lineWidth: 2))
                }
            }
            if let name = kids.first.map({ firstName($0.name) }) {
                Text(kids.count == 1 ? name : "\(name) +\(kids.count - 1)")
                    .font(.system(.caption, design: .rounded).weight(.semibold))
                    .foregroundStyle(Color.inkSoft)
            }
        }
    }

    private func firstName(_ name: String) -> String {
        name.split(separator: " ").first.map(String.init) ?? name
    }
}
