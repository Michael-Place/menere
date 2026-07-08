import AnalyticsClient
import CellarFeature
import ComposableArchitecture
import DocsFeature
import FamilyDomain
import Foundation
import LocalCache
import MenereUI
import MoneyFeature
import PersistenceClient
import ProjectsFeature
import ScanFeature
import SwiftUI
import UserDomain
import WineDomain

/// Progress + freshness for a single `FamilyList`, computed READ-ONLY from its items for the
/// overview root (checked/total + last-updated). Never written back.
public struct ListProgress: Equatable, Sendable {
    public var done: Int
    public var total: Int
    public var lastUpdated: Date
    public init(done: Int = 0, total: Int = 0, lastUpdated: Date = .distantPast) {
        self.done = done
        self.total = total
        self.lastUpdated = lastUpdated
    }
    /// 0…1 completion, treating an empty list as 0.
    public var fraction: Double { total == 0 ? 0 : Double(done) / Double(total) }
    public var isComplete: Bool { total > 0 && done == total }
}

/// The soonest-dated active project, surfaced on the Projects module card.
public struct NearestProject: Equatable, Sendable {
    public var name: String
    public var date: Date
    public init(name: String, date: Date) {
        self.name = name
        self.date = date
    }
}

/// Live, glanceable preview stats for the four pinned module cards (Cellar / Family Brain / Money /
/// Projects). Loaded READ-ONLY on the Lists root — mirrors the Home hub's per-card preview content.
public struct ModuleOverview: Equatable, Sendable {
    // Wine — bottles on hand + journal entries logged
    public var bottleCount: Int = 0
    public var recentBottle: String?
    public var journalCount: Int = 0
    // Family Brain
    public var docCount: Int = 0
    public var docsNeedAttention: Int = 0
    // Money (current calendar month)
    public var monthTotal: Double = 0
    public var topCategory: ExpenseCategory?
    // Projects
    public var activeProjectCount: Int = 0
    public var nearestProject: NearestProject?
    public init() {}
}

@Reducer
public struct ListsReducer {
    @ObservableState
    public struct State: Equatable {
        var lists: [FamilyList] = []
        var members: [HouseholdMember] = []
        var isLoading = false
        /// Overview-only, READ-ONLY live stats for the pinned module cards (Cellar/Brain/Money/Projects).
        var overview = ModuleOverview()
        /// Overview-only, READ-ONLY per-list progress (checked/total + last-updated), keyed by list id.
        var listProgress: [String: ListProgress] = [:]
        var showAddSheet = false
        var newTitle = ""
        /// Which specialization the about-to-be-created list should take (P30 grocery preset).
        var newListType: ListType = .standard
        @Presents var detail: ListDetailReducer.State?

        // Wine cellar is re-homed here as a pinned "collection" entry. Pushing the Cellar
        // presents the full wine stack; Scan is a full-screen modal over it (as before).
        @Presents var cellar: CellarReducer.State?
        var showScan = false
        var scan = ScanReducer.State()

        // Family Brain (document vault) is a sibling pinned row under Cellar; pushing it presents
        // the DocsFeature library. State lives here, mirroring the Cellar wiring.
        @Presents var docs: DocsReducer.State?

        // Money (expenses & budgets) is the third pinned row, under Family Brain; pushing it presents
        // the MoneyFeature screen. State lives here, mirroring the Cellar / Docs wiring.
        @Presents var money: MoneyReducer.State?

        // Projects (family initiative workspaces) is the fourth pinned row; pushing it presents the
        // ProjectsFeature list. State lives here, mirroring the Cellar / Docs / Money wiring.
        @Presents var projects: ProjectsReducer.State?

        public init() {}
    }

    public enum Action: Equatable, BindableAction {
        case task
        /// `lists == nil` means the Firestore read FAILED (offline) — keep the cache-painted lists and
        /// skip the write-through. A non-nil (even empty) result is authoritative.
        case listsLoaded([FamilyList]?)
        case listsCacheHydrated([FamilyList])   // H2-ext — instant/reactive paint from the SQLite mirror
        case membersLoaded([HouseholdMember])
        /// Overview-only, READ-ONLY module-card stats finished loading.
        case overviewLoaded(ModuleOverview)
        /// Overview-only, READ-ONLY per-list progress finished loading.
        case listProgressLoaded([String: ListProgress])
        case addTapped
        case createList
        case deleteLists(IndexSet)
        case listTapped(FamilyList)
        case detail(PresentationAction<ListDetailReducer.Action>)
        case cellarTapped
        case cellar(PresentationAction<CellarReducer.Action>)
        case docsTapped
        case docs(PresentationAction<DocsReducer.Action>)
        case moneyTapped
        case money(PresentationAction<MoneyReducer.Action>)
        case projectsTapped
        case projects(PresentationAction<ProjectsReducer.Action>)
        case scan(ScanReducer.Action)
        case scanRequested
        case scanDismissed
        case binding(BindingAction<State>)
    }

    public init() {}

    private enum CancelID { case observeListsCache }

    private func hid() -> String? {
        @Shared(.user) var user
        return user?.householdId
    }

    // MARK: - Overview loaders (READ-ONLY)

    /// Best-effort live stats for the four module cards. Every read is `try?`-guarded so one failure
    /// only drops that card to its defaults; nothing is written back.
    static func loadOverview(hid: String) async -> ModuleOverview {
        @Dependency(\.persistence) var persistence
        var overview = ModuleOverview()

        // Wine — bottles on hand + the most-recently-added bottle's wine name.
        if let bottles = try? await persistence.bottles(hid) {
            let cellared = bottles.filter { $0.status == .cellared }
            overview.bottleCount = cellared.reduce(0) { $0 + max($1.quantity, 1) }
            if let newest = cellared.max(by: { $0.createdAt < $1.createdAt }),
               let wine = try? await persistence.wines([newest.wineId]).first {
                var parts: [String] = []
                if let v = wine.vintage { parts.append(String(v)) }
                parts.append(wine.producer)
                if let name = wine.name, !name.isEmpty { parts.append(name) }
                overview.recentBottle = parts.joined(separator: " ")
            }
        }
        // Wine journal — how many tastings have been logged.
        if let tastings = try? await persistence.tastings(hid) {
            overview.journalCount = tastings.count
        }

        // Family Brain — document count + how many need attention (due/expiry soon).
        if let docs = try? await persistence.documents(hid) {
            let now = Date()
            overview.docCount = docs.count
            overview.docsNeedAttention = docs.filter { $0.needsAttention(now: now) }.count
        }

        // Money — this calendar month's spend total + the top-spend category.
        if let expenses = try? await persistence.expenses(hid) {
            let cal = Calendar.current
            let now = Date()
            let thisMonth = expenses.filter {
                cal.isDate($0.date, equalTo: now, toGranularity: .month)
            }
            overview.monthTotal = thisMonth.reduce(0) { $0 + $1.amount }
            let byCategory = Dictionary(grouping: thisMonth, by: \.category)
                .mapValues { $0.reduce(0) { $0 + $1.amount } }
            overview.topCategory = byCategory.max(by: { $0.value < $1.value })?.key
        }

        // Projects — active (not-done) count + the soonest target date among them.
        if let projects = try? await persistence.projects(hid) {
            let active = projects.filter { $0.status != .done }
            overview.activeProjectCount = active.count
            if let soonest = active.compactMap({ p -> NearestProject? in
                guard let date = p.targetDate else { return nil }
                return NearestProject(name: p.name, date: date)
            }).min(by: { $0.date < $1.date }) {
                overview.nearestProject = soonest
            }
        }

        return overview
    }

    /// Best-effort per-list progress (checked/total) + last-updated. Reads each list's items once;
    /// any failure just omits that list's bar. READ-ONLY.
    static func loadListProgress(hid: String) async -> [String: ListProgress] {
        @Dependency(\.persistence) var persistence
        guard let lists = try? await persistence.lists(hid) else { return [:] }
        var result: [String: ListProgress] = [:]
        await withTaskGroup(of: (String, ListProgress)?.self) { group in
            for list in lists {
                group.addTask {
                    guard let items = try? await persistence.listItems(hid, list.id) else { return nil }
                    let done = items.filter(\.isCompleted).count
                    let lastUpdated = items.map(\.createdAt).max() ?? list.updatedAt
                    return (list.id, ListProgress(done: done, total: items.count, lastUpdated: lastUpdated))
                }
            }
            for await pair in group {
                if let (id, progress) = pair { result[id] = progress }
            }
        }
        return result
    }

    public var body: some ReducerOf<Self> {
        BindingReducer()
        Scope(state: \.scan, action: \.scan, child: ScanReducer.init)
        Reduce { state, action in
            switch action {
            case .task:
                guard let hid = hid() else { return .none }
                state.isLoading = true
                // H2-ext — OFFLINE-FIRST INSTANT PAINT: seed the list rows from the SQLite mirror THIS
                // FRAME (no await), keep them live via the observation stream, and refresh + write through
                // from the one-shot Firestore read below. Guarded so fresh in-memory data isn't clobbered.
                @Dependency(\.localCache) var localCache
                localCache.bootstrap()
                if state.lists.isEmpty {
                    let cached = localCache.lists(hid)
                    if !cached.isEmpty { state.lists = cached.sorted { $0.createdAt < $1.createdAt } }
                }
                return .merge(
                    .run { send in
                        @Dependency(\.localCache) var localCache
                        for await lists in localCache.observeLists(hid) {
                            await send(.listsCacheHydrated(lists))
                        }
                    }
                    .cancellable(id: CancelID.observeListsCache, cancelInFlight: true),
                    .run { send in
                        @Dependency(\.persistence) var persistence
                        // nil = the Firestore read FAILED (offline): keep the cache, skip write-through.
                        async let lists = try? await persistence.lists(hid)
                        async let members = persistence.members(hid)
                        await send(.listsLoaded(await lists))
                        await send(.membersLoaded((try? await members) ?? []))
                    },
                    // OVERVIEW-ONLY, READ-ONLY: live preview stats for the four module cards. Each read is
                    // best-effort (`try?`) so any one failure just leaves that card's defaults — nothing
                    // is written back. Mirrors the Home hub's per-card preview content.
                    .run { send in
                        await send(.overviewLoaded(Self.loadOverview(hid: hid)))
                    },
                    // OVERVIEW-ONLY, READ-ONLY: per-list progress (checked/total + last-updated).
                    .run { send in
                        await send(.listProgressLoaded(Self.loadListProgress(hid: hid)))
                    }
                )

            case let .listsCacheHydrated(lists):
                // H2-ext — instant/reactive paint from the SQLite mirror (oldest-first, matching the
                // screen's order). Idempotent after the Firestore write-through re-emits the same rows.
                state.lists = lists.sorted { $0.createdAt < $1.createdAt }
                return .none

            case let .listsLoaded(lists):
                state.isLoading = false
                // H2-ext — Firestore is authoritative only when it answered (lists != nil). When nil
                // (offline) the observation stream keeps driving the cache-painted rows.
                guard let lists else { return .none }
                state.lists = lists.sorted { $0.createdAt < $1.createdAt }
                guard let hid = hid() else { return .none }
                return .run { [lists] _ in
                    @Dependency(\.localCache) var localCache
                    localCache.upsertLists(hid, lists)
                }

            case let .membersLoaded(members):
                state.members = members
                return .none

            case let .overviewLoaded(overview):
                state.overview = overview
                return .none

            case let .listProgressLoaded(progress):
                state.listProgress = progress
                return .none

            case .addTapped:
                state.newTitle = ""
                state.newListType = .standard
                state.showAddSheet = true
                return .none

            case .createList:
                let title = state.newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !title.isEmpty, let hid = hid() else { return .none }
                // Each preset flips the list into its specialized detail experience + a fitting icon.
                let list: FamilyList
                switch state.newListType {
                case .grocery:
                    list = FamilyList(title: title, icon: "cart", color: .sage, listType: .grocery)
                case .packing:
                    list = FamilyList(title: title, icon: "suitcase", color: .sky, listType: .packing)
                case .gift:
                    list = FamilyList(title: title, icon: "gift", color: .terracotta, listType: .gift)
                case .project:
                    list = FamilyList(title: title, icon: "hammer.fill", color: .marigold, listType: .project)
                case .wishlist:
                    list = FamilyList(title: title, icon: "star.fill", color: .sky, listType: .wishlist)
                case .standard:
                    list = FamilyList(title: title)
                }
                @Dependency(\.analytics) var analytics
                switch state.newListType {
                case .packing: analytics.log("packing_list_created")
                case .gift: analytics.log("gift_list_created")
                case .project: analytics.log("project_list_created")
                case .wishlist: analytics.log("wishlist_created")
                default: break
                }
                state.lists.append(list)
                state.showAddSheet = false
                state.newTitle = ""
                state.newListType = .standard
                return .run { _ in
                    @Dependency(\.persistence) var persistence
                    try await persistence.saveList(hid, list)
                }

            case let .deleteLists(offsets):
                guard let hid = hid() else { return .none }
                let toDelete = offsets.map { state.lists[$0] }
                state.lists.remove(atOffsets: offsets)
                return .run { _ in
                    @Dependency(\.persistence) var persistence
                    for list in toDelete { try await persistence.deleteList(hid, list.id) }
                }

            case let .listTapped(list):
                state.detail = ListDetailReducer.State(list: list, members: state.members)
                return .none

            case .detail:
                return .none

            case .cellarTapped:
                state.cellar = CellarReducer.State()
                return .none

            case .cellar(.presented(.delegate(.requestScan))), .scanRequested:
                state.showScan = true
                return .none

            case .cellar:
                return .none

            case .docsTapped:
                @Dependency(\.analytics) var analytics
                analytics.log("family_brain_opened")   // P25 telemetry (fire-and-forget)
                state.docs = DocsReducer.State()
                return .none

            case .docs:
                return .none

            case .moneyTapped:
                state.money = MoneyReducer.State()
                return .none

            case .money:
                return .none

            case .projectsTapped:
                @Dependency(\.analytics) var analytics
                analytics.log("projects_opened")
                state.projects = ProjectsReducer.State()
                return .none

            case .projects:
                return .none

            case .scanDismissed:
                state.showScan = false
                // Refresh the cellar so a just-scanned bottle appears.
                return .send(.cellar(.presented(.task)))

            case .scan:
                return .none

            case .binding:
                return .none
            }
        }
        .ifLet(\.$detail, action: \.detail) {
            ListDetailReducer()
        }
        .ifLet(\.$cellar, action: \.cellar) {
            CellarReducer()
        }
        .ifLet(\.$docs, action: \.docs) {
            DocsReducer()
        }
        .ifLet(\.$money, action: \.money) {
            MoneyReducer()
        }
        .ifLet(\.$projects, action: \.projects) {
            ProjectsReducer()
        }
    }
}

public struct ListsView: View {
    @Bindable var store: StoreOf<ListsReducer>

    public init(store: StoreOf<ListsReducer>) {
        self.store = store
    }

    public var body: some View {
        // OVERVIEW-FOCUSED ROOT (mirrors Today / the Home hub): rich MODULE cards with live preview
        // content on top, then the family's lists grouped by type with progress + last-updated. Every
        // destination is preserved — the cards send the same actions the old plain rows did.
        ScrollView {
            VStack(spacing: 14) {
                // Rich module cards for the pinned surfaces. Whole-card taps open the exact same
                // destinations as before (Cellar → CellarView, etc.); previews are read-only stats.
                moduleCard(icon: "wineglass", tint: .terracotta, title: "Wine",
                           status: cellarStatus, id: "cellar", index: 0,
                           action: { store.send(.cellarTapped) }) { cellarPreview }
                moduleCard(icon: "brain", tint: .sky, title: "Family Brain",
                           status: brainStatus, id: "docs", index: 1,
                           action: { store.send(.docsTapped) }) { brainPreview }
                moduleCard(icon: "dollarsign.circle", tint: .sage, title: "Money",
                           status: moneyStatus, id: "money", index: 2,
                           action: { store.send(.moneyTapped) }) { moneyPreview }
                moduleCard(icon: "square.stack.3d.up.fill", tint: .marigold, title: "Projects",
                           status: projectsStatus, id: "projects", index: 3,
                           action: { store.send(.projectsTapped) }) { projectsPreview }

                listsOverview
            }
            .padding(.horizontal)
            .padding(.vertical, 12)
        }
        .scrollContentBackground(.hidden)
        .background(Color.familyCanvas)
        .navigationTitle("Lists")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { store.send(.addTapped) } label: { Image(systemName: "plus").appearBounce() }
                    .buttonStyle(.pressable)
                    .accessibilityIdentifier("add-list-button")
            }
        }
        .task { store.send(.task) }
        .navigationDestination(
            item: $store.scope(state: \.detail, action: \.detail)
        ) { detailStore in
            ListDetailView(store: detailStore)
        }
        .navigationDestination(
            item: $store.scope(state: \.cellar, action: \.cellar)
        ) { cellarStore in
            // The wine stack now shares the Bacán family chrome via `.wineChrome()` (familyCanvas +
            // bacanGreen), so the Cellar reads as the same app as the rest of Lists rather than a
            // separate parchment world.
            CellarView(store: cellarStore)
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button { store.send(.scanRequested) } label: {
                            Image(systemName: "camera.viewfinder")
                        }
                        .accessibilityIdentifier("scan-wine-button")
                    }
                }
                .wineChrome()
        }
        .navigationDestination(
            item: $store.scope(state: \.docs, action: \.docs)
        ) { docsStore in
            DocsLibraryView(store: docsStore)
        }
        .navigationDestination(
            item: $store.scope(state: \.money, action: \.money)
        ) { moneyStore in
            MoneyView(store: moneyStore)
        }
        .navigationDestination(
            item: $store.scope(state: \.projects, action: \.projects)
        ) { projectsStore in
            ProjectsView(store: projectsStore)
        }
        .fullScreenCover(
            isPresented: Binding(
                get: { store.showScan },
                set: { if !$0 { store.send(.scanDismissed) } }
            )
        ) {
            NavigationStack {
                ScanView(store: store.scope(state: \.scan, action: \.scan))
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Done") { store.send(.scanDismissed) }
                        }
                    }
            }
            // The Scan modal is part of the wine stack: pin the family tint so the "Done" button
            // (added here, outside ScanView's own `.wineChrome()` tint scope) matches bacanGreen.
            .tint(.bacanGreen)
        }
        .sheet(isPresented: $store.showAddSheet) {
            NewListSheet(store: store)
                .presentationDetents([.medium])
        }
    }
}

// MARK: - Overview root building blocks

private extension ListsView {

    // MARK: Module card scaffold

    /// A rich, tappable module card: leading tinted icon + title + live one-line status + chevron,
    /// with a preview body beneath — modelled on the Home hub's P16-C2 cards. The whole card is a
    /// Button so a tap opens the same destination the old plain row did.
    func moduleCard<Preview: View>(
        icon: String, tint: Color, title: String, status: String, id: String, index: Int,
        action: @escaping () -> Void, @ViewBuilder preview: () -> Preview
    ) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 12) {
                cardHeaderRow(icon: icon, tint: tint, title: title, status: status)
                preview()
            }
            .padding(16)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.familySurface)
            )
        }
        .buttonStyle(.pressable)
        .accessibilityIdentifier("lists-card-\(id)")
        // Motion & Delight — Lists' signature: cards SLIDE in from the leading edge, staggered,
        // like a checklist writing itself. Replays on every (re)selection.
        .tabEntrance(.slideLeading, index: index)
    }

    /// The header row shared by every card: leading tinted circle icon, title, one-line status, chevron.
    func cardHeaderRow(icon: String, tint: Color, title: String, status: String) -> some View {
        HStack(spacing: 14) {
            ZStack {
                Circle().fill(tint.opacity(0.15))
                Image(systemName: icon).font(.title3).foregroundStyle(tint)
            }
            .frame(width: 44, height: 44)

            VStack(alignment: .leading, spacing: 3) {
                Text(title).familyTitle(.headline).foregroundStyle(Color.ink)
                Text(status)
                    .font(.system(.subheadline, design: .rounded))
                    .foregroundStyle(Color.inkSoft)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Color.inkSoft.opacity(0.5))
        }
        .contentShape(Rectangle())
    }

    /// A small pill used inside a card preview (e.g. "3 need attention", "Top: Groceries").
    func previewChip(_ text: String, icon: String? = nil, tint: Color) -> some View {
        HStack(spacing: 5) {
            if let icon { Image(systemName: icon).font(.caption2) }
            Text(text)
        }
        .font(.system(.caption, design: .rounded).weight(.medium))
        .foregroundStyle(tint)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Capsule(style: .continuous).fill(tint.opacity(0.14)))
    }

    // MARK: Wine card

    var cellarStatus: String {
        let n = store.overview.bottleCount
        return n == 0 ? "Your wine journal" : "\(n) on hand"
    }

    @ViewBuilder var cellarPreview: some View {
        let journalCount = store.overview.journalCount
        if let recent = store.overview.recentBottle, !recent.isEmpty {
            HStack(spacing: 8) {
                previewChip(recent, icon: "wineglass", tint: .terracotta)
                if journalCount > 0 {
                    previewChip("\(journalCount) journaled", icon: "book", tint: .marigold)
                }
                Spacer(minLength: 0)
            }
        } else if journalCount > 0 {
            HStack(spacing: 8) {
                previewChip("\(journalCount) \(journalCount == 1 ? "wine" : "wines") journaled",
                            icon: "book", tint: .marigold)
                Spacer(minLength: 0)
            }
        } else {
            previewLine("Scan a label and start your journal.")
        }
    }

    // MARK: Family Brain card

    var brainStatus: String {
        let n = store.overview.docCount
        return n == 0 ? "Documents & paperwork" : "\(n) \(n == 1 ? "document" : "documents")"
    }

    @ViewBuilder var brainPreview: some View {
        if store.overview.docsNeedAttention > 0 {
            let n = store.overview.docsNeedAttention
            HStack(spacing: 8) {
                previewChip("\(n) need\(n == 1 ? "s" : "") attention", icon: "exclamationmark.circle.fill",
                            tint: .marigold)
                Spacer(minLength: 0)
            }
        } else {
            previewLine("Scans, receipts & records — searchable.")
        }
    }

    // MARK: Money card

    var moneyStatus: String {
        store.overview.monthTotal > 0
            ? "\(Self.currency(store.overview.monthTotal)) this month"
            : "Spending & budgets"
    }

    @ViewBuilder var moneyPreview: some View {
        if let top = store.overview.topCategory {
            HStack(spacing: 8) {
                previewChip("Top: \(top.displayName)", icon: top.symbolName, tint: .sage)
                Spacer(minLength: 0)
            }
        } else {
            previewLine("Track spending, set budgets.")
        }
    }

    // MARK: Projects card

    var projectsStatus: String {
        let n = store.overview.activeProjectCount
        return n == 0 ? "Pool, school & big undertakings" : "\(n) active \(n == 1 ? "project" : "projects")"
    }

    @ViewBuilder var projectsPreview: some View {
        if let next = store.overview.nearestProject {
            HStack(spacing: 8) {
                previewChip("\(next.name) · \(Self.shortDate(next.date))", icon: "calendar", tint: .marigold)
                Spacer(minLength: 0)
            }
        } else {
            previewLine("Gather everything around one goal.")
        }
    }

    /// A muted one-line hint used when a card has no live stat yet.
    func previewLine(_ text: String) -> some View {
        Text(text)
            .font(.system(.footnote, design: .rounded))
            .foregroundStyle(Color.inkSoft)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Lists overview (grouped by type)

    /// The family's lists grouped by `ListType`, each list showing progress + last-updated, with a
    /// prominent quick-add affordance. Empty groups are dropped; within a group the most-recently
    /// touched surfaces first (so "what's active" reads at a glance).
    @ViewBuilder var listsOverview: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Lists").familyTitle(.title3).foregroundStyle(Color.ink)
                Spacer()
                Button { store.send(.addTapped) } label: {
                    Label("New list", systemImage: "plus.circle.fill")
                        .font(.system(.subheadline, design: .rounded).weight(.semibold))
                        .foregroundStyle(Color.bacanGreen)
                }
                .buttonStyle(.pressable)
                .accessibilityIdentifier("lists-quick-add")
            }
            .tabEntrance(.slideLeading, index: 4)

            if store.lists.isEmpty {
                if store.isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 24)
                } else {
                    quickAddCard
                        .tabEntrance(.slideLeading, index: 5)
                }
            } else {
                ForEach(Array(groupedLists.enumerated()), id: \.element.title) { groupIndex, group in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(group.title.uppercased())
                            .font(.system(.caption, design: .rounded).weight(.semibold))
                            .foregroundStyle(Color.inkSoft)
                            .padding(.leading, 4)
                        VStack(spacing: 0) {
                            ForEach(Array(group.lists.enumerated()), id: \.element.id) { rowIndex, list in
                                if rowIndex > 0 {
                                    Divider().padding(.leading, 52)
                                }
                                listRow(list)
                            }
                        }
                        .background(
                            RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.familySurface)
                        )
                    }
                    .tabEntrance(.slideLeading, index: 5 + groupIndex)
                }
            }
        }
    }

    /// A single list row: colored icon, title, an inline progress bar + "3/8", and relative last-updated.
    func listRow(_ list: FamilyList) -> some View {
        let rgb = list.color.rgb
        let color = Color(red: rgb.red, green: rgb.green, blue: rgb.blue)
        let progress = store.listProgress[list.id]
        return Button {
            store.send(.listTapped(list))
        } label: {
            HStack(spacing: 14) {
                ZStack {
                    Circle().fill(color.opacity(0.15))
                    Image(systemName: list.icon).font(.subheadline).foregroundStyle(color)
                }
                .frame(width: 38, height: 38)

                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text(list.title).font(.system(.body, design: .rounded).weight(.medium))
                            .foregroundStyle(Color.ink)
                        Spacer(minLength: 4)
                        if let progress, progress.total > 0 {
                            Text(progress.isComplete ? "Done" : "\(progress.done)/\(progress.total)")
                                .font(.system(.caption, design: .rounded).weight(.semibold))
                                .foregroundStyle(progress.isComplete ? Color.bacanGreen : Color.inkSoft)
                        }
                    }
                    if let progress, progress.total > 0 {
                        ProgressBar(fraction: progress.fraction, tint: color)
                    }
                    if let updated = lastUpdated(for: list) {
                        Text("Updated \(Self.relative(updated))")
                            .font(.system(.caption2, design: .rounded))
                            .foregroundStyle(Color.inkSoft.opacity(0.8))
                    }
                }
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.inkSoft.opacity(0.4))
            }
            .padding(14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
        .accessibilityIdentifier("list-row-\(list.id)")
        // Deleting a whole list moves from swipe (List-only) to a long-press context menu here — the
        // same `deleteLists` path, so functionality is preserved in the card layout.
        .contextMenu {
            Button(role: .destructive) {
                if let idx = store.lists.firstIndex(where: { $0.id == list.id }) {
                    store.send(.deleteLists(IndexSet(integer: idx)))
                }
            } label: { Label("Delete list", systemImage: "trash") }
        }
    }

    /// The empty-state / no-lists quick-add card.
    var quickAddCard: some View {
        Button { store.send(.addTapped) } label: {
            VStack(spacing: 8) {
                Image(systemName: "plus.circle.fill").font(.largeTitle).foregroundStyle(Color.bacanGreen)
                Text("Start a list")
                    .font(.system(.headline, design: .rounded)).foregroundStyle(Color.ink)
                Text("Groceries, Costco, house projects — tap and share the load.")
                    .font(.system(.footnote, design: .rounded)).foregroundStyle(Color.inkSoft)
                    .multilineTextAlignment(.center)
            }
            .padding(24)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.familySurface)
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .strokeBorder(Color.bacanGreen.opacity(0.25), style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
                    )
            )
        }
        .buttonStyle(.pressable)
        .accessibilityIdentifier("lists-empty-quick-add")
    }

    // MARK: Grouping + formatting

    /// A named group of lists, ordered for display.
    struct ListGroup: Equatable { var title: String; var lists: [FamilyList] }

    /// Group the family's lists by type in a fixed, sensible order, dropping empty groups. Within each
    /// group the most-recently-updated surfaces first.
    var groupedLists: [ListGroup] {
        func bucket(_ list: FamilyList) -> String {
            if list.isGrocery { return "Groceries" }
            if list.isPacking { return "Packing" }
            if list.isGift { return "Gifts" }
            if list.isProject { return "Home projects" }
            if list.isWishlist { return "Wishlist" }
            return "Other"
        }
        let order = ["Groceries", "Packing", "Gifts", "Home projects", "Wishlist", "Other"]
        let grouped = Dictionary(grouping: store.lists, by: bucket)
        return order.compactMap { title in
            guard let lists = grouped[title], !lists.isEmpty else { return nil }
            let sorted = lists.sorted { (lastUpdated(for: $0) ?? .distantPast) > (lastUpdated(for: $1) ?? .distantPast) }
            return ListGroup(title: title, lists: sorted)
        }
    }

    /// The freshest signal for a list: the newest item timestamp if we loaded items, else the list's own
    /// `updatedAt`.
    func lastUpdated(for list: FamilyList) -> Date? {
        if let p = store.listProgress[list.id], p.lastUpdated > .distantPast { return p.lastUpdated }
        return list.updatedAt
    }

    static func currency(_ value: Double) -> String {
        value.formatted(.currency(code: "USD").precision(.fractionLength(value.rounded() == value ? 0 : 2)))
    }

    static func shortDate(_ date: Date) -> String {
        date.formatted(.dateTime.month(.abbreviated).day())
    }

    static func relative(_ date: Date) -> String {
        date.formatted(.relative(presentation: .named))
    }
}

/// A slim rounded progress bar for a list's completion.
private struct ProgressBar: View {
    let fraction: Double
    let tint: Color
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(tint.opacity(0.15))
                Capsule().fill(tint)
                    .frame(width: max(0, min(1, fraction)) * geo.size.width)
            }
        }
        .frame(height: 5)
    }
}

/// The "New list" form. Offers a grocery preset (P30) that flips the new list into the
/// aisle-grouped grocery experience with a cart icon.
private struct NewListSheet: View {
    @Bindable var store: StoreOf<ListsReducer>

    /// The sensible default title we'd suggest for a given preset (empty for a plain checklist).
    private func defaultTitle(for type: ListType) -> String {
        switch type {
        case .standard: ""
        case .grocery: "Groceries"
        case .packing: "Packing list"
        case .gift: "Gift ideas"
        case .project: "Home projects"
        case .wishlist: "Wishlist"
        }
    }

    /// The set of all preset default titles — used to know when a title is still "untouched".
    private let presetTitles: Set<String> = ["Groceries", "Packing list", "Gift ideas", "Home projects", "Wishlist"]

    @ViewBuilder
    private func presetHint(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(Color.inkSoft)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Groceries, Costco, projects…", text: $store.newTitle)
                        .accessibilityIdentifier("new-list-title-field")
                }
                .listRowBackground(Color.familySurface)

                Section("Type") {
                    Picker("List type", selection: $store.newListType) {
                        Label("Checklist", systemImage: "checklist").tag(ListType.standard)
                        Label("Grocery List", systemImage: "cart").tag(ListType.grocery)
                        Label("Packing List", systemImage: "suitcase").tag(ListType.packing)
                        Label("Gift List", systemImage: "gift").tag(ListType.gift)
                        Label("Home Projects", systemImage: "hammer.fill").tag(ListType.project)
                        Label("Wishlist", systemImage: "star.fill").tag(ListType.wishlist)
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                    switch store.newListType {
                    case .grocery:
                        presetHint("We'll sort items by aisle and auto-tag categories as you type.")
                    case .packing:
                        presetHint("Group by person and category — and seed it from a beach / weekend / flight-with-baby template.")
                    case .gift:
                        presetHint("Track ideas per recipient with price, link, and a bought toggle — hidden from whoever it's for.")
                    case .project:
                        presetHint("Honey-do & home projects: status (planning → in-progress → done), budget, notes, and linked Brain docs — grouped by status.")
                    case .wishlist:
                        presetHint("Non-grocery wants: price, store, priority, and a link — with a bought toggle and running totals.")
                    case .standard:
                        EmptyView()
                    }
                }
                .listRowBackground(Color.familySurface)
            }
            .scrollContentBackground(.hidden)
            .background(Color.familyCanvas)
            .onChange(of: store.newListType) { _, newType in
                // Auto-suggest a title when the field is still empty or holding another preset's
                // default, so picking "Packing List" fills "Packing list" — but never clobber a
                // title the user actually typed.
                let current = store.newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                if current.isEmpty || presetTitles.contains(current) {
                    store.newTitle = defaultTitle(for: newType)
                }
            }
            .navigationTitle("New list")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { store.showAddSheet = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") { store.send(.createList) }
                        .disabled(store.newTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("create-list-button")
                }
            }
        }
    }
}

// MARK: - Previews

#Preview("Lists — overview root") {
    var state = ListsReducer.State()
    // Seed the family's lists across several types so the grouped overview + progress bars render.
    let groceries = FamilyList(title: "Groceries", icon: "cart", color: .sage, listType: .grocery)
    let costco = FamilyList(title: "Costco run", listType: .standard)
    let chile = FamilyList(title: "Chile trip", icon: "suitcase", color: .sky, listType: .packing)
    let gifts = FamilyList(title: "Oliver's birthday", icon: "gift", color: .terracotta, listType: .gift)
    let honeydo = FamilyList(title: "Honey-do", icon: "hammer.fill", color: .marigold, listType: .project)
    let wishlist = FamilyList(title: "Someday wants", icon: "star.fill", color: .sky, listType: .wishlist)
    state.lists = [groceries, costco, chile, gifts, honeydo, wishlist]
    state.listProgress = [
        groceries.id: ListProgress(done: 3, total: 8, lastUpdated: Date().addingTimeInterval(-3600)),
        costco.id: ListProgress(done: 0, total: 5, lastUpdated: Date().addingTimeInterval(-86_400)),
        chile.id: ListProgress(done: 12, total: 12, lastUpdated: Date().addingTimeInterval(-7200)),
        gifts.id: ListProgress(done: 1, total: 4, lastUpdated: Date().addingTimeInterval(-172_800)),
        honeydo.id: ListProgress(done: 2, total: 6, lastUpdated: Date().addingTimeInterval(-259_200)),
        wishlist.id: ListProgress(done: 0, total: 3, lastUpdated: Date().addingTimeInterval(-604_800)),
    ]
    // Live module-card preview stats.
    var overview = ModuleOverview()
    overview.bottleCount = 42
    overview.recentBottle = "2019 Ridge Monte Bello"
    overview.docCount = 87
    overview.docsNeedAttention = 3
    overview.monthTotal = 2_480
    overview.topCategory = .groceries
    overview.activeProjectCount = 4
    overview.nearestProject = NearestProject(
        name: "Backyard pool", date: Calendar.current.date(byAdding: .day, value: 21, to: Date()) ?? Date())
    state.overview = overview

    return NavigationStack {
        ListsView(store: Store(initialState: state) { ListsReducer() })
    }
}

#Preview("Lists — empty (quick-add)") {
    NavigationStack {
        ListsView(store: Store(initialState: ListsReducer.State()) { ListsReducer() })
    }
}
