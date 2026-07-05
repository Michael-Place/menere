import AnalyticsClient
import ComposableArchitecture
import FamilyDomain
import MenereUI
import PersistenceClient
import SwiftUI
import UserDomain

/// P29 — the Home-maintenance surface presented from House care. Two modes:
///   1. **Setup** (no ``HomeProfile`` yet): a short form describing the home, pre-filled with the
///      Place default, that filters the seeded ``MaintenanceKnowledgeBase``.
///   2. **Browse**: the season's suggested maintenance templates (filtered by the profile), grouped
///      by category — tap to **materialize** one into a house ``CareItem`` (or "I already did this",
///      which backdates `lastDoneAt` so it lands caught-up rather than due).
@Reducer
public struct HomeMaintenanceReducer {
    @ObservableState
    public struct State: Equatable {
        /// The saved profile, or nil until first setup completes.
        var profile: HomeProfile?
        /// The working copy edited by the setup form.
        var draft: HomeProfile
        /// nil ⇒ show the setup form; non-nil ⇒ show the suggested list.
        var mode: Mode
        /// The household's care items (passed in) — to hide already-materialized templates + score.
        var careItems: [CareItem]
        /// Template ids materialized during this session (drives the "added" check + local hiding).
        var addedTemplateIDs: Set<String> = []
        let season: Season

        public enum Mode: Equatable { case setup, browse }

        public init(profile: HomeProfile?, careItems: [CareItem], season: Season = .current) {
            self.profile = profile
            self.careItems = careItems
            self.season = season
            self.draft = profile ?? .placeDefault
            self.mode = profile == nil ? .setup : .browse
        }

        /// Template ids already tracked — either materialized this session or present on a loaded
        /// house care item.
        var trackedTemplateIDs: Set<String> {
            var ids = addedTemplateIDs
            for item in careItems {
                for task in item.tasks where task.maintenanceTemplateID != nil {
                    ids.insert(task.maintenanceTemplateID!)
                }
            }
            return ids
        }

        /// The season's suggested templates (filtered by the current profile), minus already-tracked
        /// ones, grouped by category in canonical order — the browse list's data.
        var suggestedByCategory: [(category: MaintenanceCategory, templates: [MaintenanceTemplate])] {
            guard let profile else { return [] }
            let tracked = trackedTemplateIDs
            let suggested = MaintenanceKnowledgeBase.suggestedForSeason(season, profile: profile)
                .filter { !tracked.contains($0.id) }
            var byCat: [MaintenanceCategory: [MaintenanceTemplate]] = [:]
            for t in suggested { byCat[t.category, default: []].append(t) }
            return MaintenanceCategory.allCases.compactMap { cat in
                guard let ts = byCat[cat], !ts.isEmpty else { return nil }
                return (cat, ts)
            }
        }

        /// The live readiness score over the household's house items + this profile.
        var score: HomeHealthScore? {
            guard let profile else { return nil }
            return HomeHealthCalculator.calculate(careItems: careItems, profile: profile)
        }
    }

    public enum Action: Equatable, BindableAction {
        case saveProfileTapped
        case usePlaceDefaultTapped
        case editProfileTapped
        /// Materialize a template into a house care item. `alreadyDone` backdates it to caught-up.
        case materialize(templateID: String, alreadyDone: Bool)
        case delegate(Delegate)
        case binding(BindingAction<State>)

        public enum Delegate: Equatable { case didChange }
    }

    public init() {}

    private func hid() -> String? {
        @Shared(.user) var user
        return user?.householdId
    }

    public var body: some ReducerOf<Self> {
        BindingReducer()
        Reduce { state, action in
            @Dependency(\.analytics) var analytics
            switch action {
            case .usePlaceDefaultTapped:
                state.draft = .placeDefault
                return .none

            case .saveProfileTapped:
                guard let hid = hid() else { return .none }
                var draft = state.draft
                draft.updatedAt = Date()
                state.profile = draft
                state.mode = .browse
                analytics.log("home_maintenance_setup")
                // Capture an immutable copy so the concurrent closure doesn't reference a captured
                // `var` (Swift 6 #SendableClosureCaptures).
                let profile = draft
                return .merge(
                    .run { _ in
                        @Dependency(\.persistence) var persistence
                        try await persistence.saveHomeProfile(hid, profile)
                    },
                    .send(.delegate(.didChange))
                )

            case .editProfileTapped:
                state.draft = state.profile ?? .placeDefault
                state.mode = .setup
                return .none

            case let .materialize(templateID, alreadyDone):
                guard let hid = hid(),
                      let template = MaintenanceKnowledgeBase.allTasks.first(where: { $0.id == templateID })
                else { return .none }
                let item = template.makeCareItem(alreadyDone: alreadyDone)
                state.addedTemplateIDs.insert(templateID)
                state.careItems.append(item)
                analytics.log("maintenance_task_added", ["category": template.category.rawValue])
                return .merge(
                    .run { _ in
                        @Dependency(\.persistence) var persistence
                        try await persistence.saveCareItem(hid, item)
                    },
                    .send(.delegate(.didChange))
                )

            case .delegate, .binding:
                return .none
            }
        }
    }
}

// MARK: - View

struct HomeMaintenanceView: View {
    @Bindable var store: StoreOf<HomeMaintenanceReducer>
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                switch store.mode {
                case .setup: setupForm
                case .browse: browseList
                }
            }
            .background(Color.familyCanvas)
            .navigationTitle("Home maintenance")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    // MARK: Setup form

    private var setupForm: some View {
        Form {
            Section {
                Text("Tell us about the house and we'll suggest the upkeep that actually applies — no pool tasks if there's no pool.")
                    .font(.subheadline).foregroundStyle(Color.inkSoft)
                Button {
                    store.send(.usePlaceDefaultTapped)
                } label: {
                    Label("Use the Place house defaults", systemImage: "wand.and.stars")
                }
                .accessibilityIdentifier("use-place-default-button")
            }
            .listRowBackground(Color.familySurface)

            Section("Home") {
                Picker("Type", selection: $store.draft.homeType) {
                    ForEach(HomeType.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                Picker("Climate", selection: $store.draft.climateZone) {
                    ForEach(ClimateZone.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                Picker("HVAC", selection: hvacBinding) {
                    Text("None").tag(HVACType.none)
                    ForEach(HVACType.allCases.filter { $0 != .none }, id: \.self) {
                        Text($0.displayName).tag($0)
                    }
                }
            }
            .listRowBackground(Color.familySurface)

            Section("What it has") {
                Toggle("Yard", isOn: $store.draft.hasYard).accessibilityIdentifier("toggle-yard")
                Toggle("Garage", isOn: $store.draft.hasGarage).accessibilityIdentifier("toggle-garage")
                Toggle("Septic system", isOn: $store.draft.hasSepticSystem).accessibilityIdentifier("toggle-septic")
                Toggle("Basement", isOn: $store.draft.hasBasement).accessibilityIdentifier("toggle-basement")
                Toggle("Pool", isOn: $store.draft.hasPool).accessibilityIdentifier("toggle-pool")
            }
            .listRowBackground(Color.familySurface)
            .tint(.bacanGreen)

            Section {
                Button {
                    store.send(.saveProfileTapped)
                } label: {
                    Text("See suggested maintenance")
                        .frame(maxWidth: .infinity)
                        .fontWeight(.semibold)
                }
                .buttonStyle(.borderedProminent)
                .tint(.bacanGreen)
                .accessibilityIdentifier("save-home-profile-button")
            }
            .listRowBackground(Color.clear)
        }
        .scrollContentBackground(.hidden)
        .background(Color.familyCanvas)
    }

    /// HVAC picker maps a nil profile to `.none` so the picker always has a selection.
    private var hvacBinding: Binding<HVACType> {
        Binding(
            get: { store.draft.hvacType ?? .none },
            set: { store.draft.hvacType = $0 == .none ? HVACType.none : $0 }
        )
    }

    // MARK: Browse list

    private var browseList: some View {
        List {
            if let score = store.score {
                Section {
                    HomeHealthScoreCard(score: score, season: store.season)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }
            }

            let groups = store.suggestedByCategory
            if groups.isEmpty {
                Section {
                    Text("Everything for \(store.season.displayName.lowercased()) is already on your list. Nice.")
                        .foregroundStyle(Color.inkSoft)
                }
                .listRowBackground(Color.familySurface)
            }

            ForEach(groups, id: \.category) { group in
                Section {
                    ForEach(group.templates) { template in
                        templateRow(template)
                    }
                } header: {
                    Label(group.category.displayName, systemImage: group.category.icon)
                        .foregroundStyle(Color.ink)
                }
                .listRowBackground(Color.familySurface)
            }

            Section {
                Button {
                    store.send(.editProfileTapped)
                } label: {
                    Label("Edit home profile", systemImage: "slider.horizontal.3")
                }
                .accessibilityIdentifier("edit-home-profile-button")
            }
            .listRowBackground(Color.familySurface)
        }
        .scrollContentBackground(.hidden)
        .background(Color.familyCanvas)
    }

    private func templateRow(_ template: MaintenanceTemplate) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(template.title).foregroundStyle(Color.ink)
                Text(template.description)
                    .font(.caption).foregroundStyle(Color.inkSoft)
                    .lineLimit(2)
                HStack(spacing: 6) {
                    Text(template.frequency.displayName)
                    if let season = template.season {
                        Text("· \(season.displayName)")
                    }
                    Text("· ~\(template.estimatedMinutes) min")
                }
                .font(.caption2).foregroundStyle(Color.inkSoft)
            }
            Spacer()
            // "I already did this" — materialize backdated so it lands caught-up.
            Button {
                store.send(.materialize(templateID: template.id, alreadyDone: true))
            } label: {
                Image(systemName: "checkmark.circle").foregroundStyle(Color.bacanGreen)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("materialize-done-\(template.id)")
            // Add to house care as due.
            Button {
                store.send(.materialize(templateID: template.id, alreadyDone: false))
            } label: {
                Image(systemName: "plus.circle.fill").foregroundStyle(Color.bacanGreen)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("materialize-\(template.id)")
        }
        .padding(.vertical, 2)
    }
}

/// The readiness ring + line shown atop the browse list and (compact) in House care.
struct HomeHealthScoreCard: View {
    let score: HomeHealthScore
    var season: Season = .current

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .stroke(Color.inkSoft.opacity(0.18), lineWidth: 8)
                Circle()
                    .trim(from: 0, to: CGFloat(score.overall) / 100)
                    .stroke(ringColor, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text("\(score.overall)")
                    .font(.title3.weight(.bold)).foregroundStyle(Color.ink)
            }
            .frame(width: 56, height: 56)
            VStack(alignment: .leading, spacing: 2) {
                Text("Home maintenance")
                    .font(.subheadline.weight(.semibold)).foregroundStyle(Color.ink)
                Text("\(score.completedMaintenanceCount) of \(score.totalMaintenanceCount) recommended tasks on track")
                    .font(.caption).foregroundStyle(Color.inkSoft)
            }
            Spacer()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.familySurface)
        )
        .padding(.vertical, 2)
        .accessibilityIdentifier("home-health-score-card")
    }

    private var ringColor: Color {
        switch score.overall {
        case 80...: .bacanGreen
        case 40..<80: .marigold
        default: .terracotta
        }
    }
}
