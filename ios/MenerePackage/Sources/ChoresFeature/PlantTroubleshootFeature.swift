import AnalyticsClient
import ComposableArchitecture
import FamilyDomain
import MenereUI
import PhotosUI
import SwiftUI
import UIKit

/// P19-C3 — the "plant whisperer" troubleshoot flow. Presented as a sheet from a plant's DETAIL
/// screen: the family describes what's going on (optionally with a photo of the problem), Bacán
/// diagnoses it (via the deployed `troubleshootPlant` Claude-vision callable, fed the plant's species
/// + CONTEXT + current watering cadence), and returns a diagnosis + concrete fixes + an OPTIONAL
/// one-tap watering-cadence adjustment — the context-adaptive payoff. Graceful failure throughout
/// (never crashes; a warm "Couldn't reach Bacán just now").
@Reducer
public struct PlantTroubleshootReducer {
    @ObservableState
    public struct State: Equatable {
        /// The plant being troubleshot — id drives the parent's water-interval edit; the rest is a
        /// snapshot captured at open time (species / context / current watering) sent to the model.
        let plantID: String
        let plantName: String
        let species: String?
        let commonName: String?
        let careContext: String?
        /// The current "Water" task cadence (days), for reference + the accept-suggestion diff.
        let currentWaterIntervalDays: Int?

        var problem: String = ""
        /// A freshly picked problem photo (camera or library), compressed + sent with the ask.
        var pendingPhoto: Data?
        /// The ask is in flight — drives the shimmer skeleton.
        var isThinking: Bool = false
        /// The diagnosis result, once back.
        var result: PlantDiagnosis?
        /// A warm inline note on failure (never an error alert).
        var errorNote: String?
        /// Set once the user accepts the watering suggestion, so the affordance can't fire twice.
        var waterAdjusted: Bool = false

        public init(
            plantID: String,
            plantName: String,
            species: String?,
            commonName: String?,
            careContext: String?,
            currentWaterIntervalDays: Int?
        ) {
            self.plantID = plantID
            self.plantName = plantName
            self.species = species
            self.commonName = commonName
            self.careContext = careContext
            self.currentWaterIntervalDays = currentWaterIntervalDays
        }

        /// The photo to render now, if any.
        var displayPhoto: Data? { pendingPhoto }
        /// Can we submit? Non-empty problem, nothing in flight.
        var canAsk: Bool {
            !problem.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isThinking
        }
        /// The suggested cadence is worth offering only when it's present AND actually differs from the
        /// plant's current Water interval (the context-adaptive payoff — otherwise it's a no-op).
        var suggestedWaterInterval: Int? {
            guard let s = result?.suggestedWaterIntervalDays, s > 0 else { return nil }
            guard s != currentWaterIntervalDays else { return nil }
            return s
        }
    }

    public enum Action: Equatable, BindableAction {
        case photoPicked(Data)
        case askTapped
        case response(PlantDiagnosis?)
        case acceptWaterTapped
        case delegate(Delegate)
        case binding(BindingAction<State>)

        public enum Delegate: Equatable {
            /// The family accepted the AI's watering-cadence suggestion — the parent edits the plant's
            /// Water task interval and persists it.
            case updateWaterInterval(itemID: String, days: Int)
        }
    }

    public init() {}

    public var body: some ReducerOf<Self> {
        BindingReducer()
        Reduce { state, action in
            @Dependency(\.analytics) var analytics
            switch action {
            case let .photoPicked(data):
                state.pendingPhoto = data
                return .none

            case .askTapped:
                guard state.canAsk else { return .none }
                state.isThinking = true
                state.errorNote = nil
                state.result = nil
                state.waterAdjusted = false
                analytics.log("plant_troubleshoot_asked")
                let query = PlantTroubleshootQuery(
                    species: state.species,
                    commonName: state.commonName,
                    careContext: state.careContext,
                    waterIntervalDays: state.currentWaterIntervalDays,
                    problem: state.problem.trimmingCharacters(in: .whitespacesAndNewlines),
                    jpeg: state.pendingPhoto.flatMap { CarePhotoProcessing.compressedJPEG(from: $0) }
                        ?? state.pendingPhoto
                )
                return .run { send in
                    @Dependency(\.plantTroubleshoot) var client
                    do {
                        await send(.response(try await client.troubleshoot(query)))
                    } catch {
                        await send(.response(nil))   // nil ⇒ the call failed
                    }
                }

            case let .response(result):
                state.isThinking = false
                guard let result, !result.diagnosis.isEmpty else {
                    state.errorNote = "Couldn't reach Bacán just now — try again in a moment."
                    return .none
                }
                state.result = result
                return .none

            case .acceptWaterTapped:
                guard let days = state.suggestedWaterInterval else { return .none }
                state.waterAdjusted = true
                analytics.log("plant_water_interval_adjusted")
                return .send(.delegate(.updateWaterInterval(itemID: state.plantID, days: days)))

            case .delegate, .binding:
                return .none
            }
        }
    }
}

public struct PlantTroubleshootView: View {
    @Bindable var store: StoreOf<PlantTroubleshootReducer>
    @Environment(\.dismiss) private var dismiss
    @State private var pickerItem: PhotosPickerItem?
    @State private var showCamera = false

    public init(store: StoreOf<PlantTroubleshootReducer>) {
        self.store = store
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    intro
                    problemCard
                    if store.isThinking {
                        thinkingCard
                    } else if let result = store.result {
                        resultCard(result)
                    } else if let note = store.errorNote {
                        errorCard(note)
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 12)
            }
            .scrollContentBackground(.hidden)
            .background(Color.familyCanvas)
            .navigationTitle("Ask Bacán")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("troubleshoot-done")
                }
            }
            .onChange(of: pickerItem) { _, item in
                guard let item else { return }
                Task {
                    if let data = try? await item.loadTransferable(type: Data.self) {
                        store.send(.photoPicked(data))
                    }
                    pickerItem = nil
                }
            }
            .fullScreenCover(isPresented: $showCamera) {
                CarePhotoCamera(
                    onCapture: { data in store.send(.photoPicked(data)); showCamera = false },
                    onCancel: { showCamera = false }
                )
                .ignoresSafeArea()
            }
        }
    }

    // MARK: Intro

    private var intro: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(Color.sky.opacity(0.15))
                Image(systemName: "stethoscope").font(.title3).foregroundStyle(Color.sky)
            }
            .frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 3) {
                Text(store.plantName).familyTitle(.headline)
                Text("Tell Bacán what's going on — it knows this plant's situation.")
                    .font(.caption).foregroundStyle(Color.inkSoft)
            }
            Spacer(minLength: 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Problem input

    private var problemCard: some View {
        card {
            Text("What's going on? (yellow leaves, drooping, brown tips, pests…)")
                .font(.subheadline).foregroundStyle(Color.ink)
            TextField("Describe the problem", text: $store.problem, axis: .vertical)
                .lineLimit(3...6)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("troubleshoot-problem-field")

            photoRow

            Button {
                store.send(.askTapped)
            } label: {
                HStack(spacing: 8) {
                    if store.isThinking {
                        ProgressView().controlSize(.small)
                        Text("Asking…")
                    } else {
                        Label("Ask Bacán", systemImage: "sparkles")
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .tint(.bacanGreen)
            .disabled(!store.canAsk)
            .accessibilityIdentifier("troubleshoot-ask-button")
        }
    }

    @ViewBuilder
    private var photoRow: some View {
        HStack(spacing: 12) {
            if let data = store.displayPhoto, let img = UIImage(data: data) {
                Image(uiImage: img).resizable().scaledToFill()
                    .frame(width: 52, height: 52)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            PhotosPicker(selection: $pickerItem, matching: .images) {
                Label(store.displayPhoto == nil ? "Add a photo" : "Change photo", systemImage: "photo.on.rectangle")
                    .font(.caption)
            }
            .accessibilityIdentifier("troubleshoot-photo-picker")

            // The in-app camera is unreliable on the simulator — same guard as the plant form.
            #if !targetEnvironment(simulator)
            Button {
                showCamera = true
            } label: {
                Label("Take photo", systemImage: "camera").font(.caption)
            }
            .accessibilityIdentifier("troubleshoot-photo-camera")
            #endif
            Spacer(minLength: 0)
        }
    }

    // MARK: Thinking (shimmer)

    private var thinkingCard: some View {
        card {
            Label("Bacán is thinking…", systemImage: "leaf.fill")
                .font(.caption).foregroundStyle(Color.inkSoft)
            VStack(alignment: .leading, spacing: 8) {
                ForEach(0..<4, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.inkSoft.opacity(0.15))
                        .frame(height: 12)
                        .frame(maxWidth: i == 3 ? 160 : .infinity, alignment: .leading)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .shimmering()
        }
        .accessibilityIdentifier("troubleshoot-thinking")
    }

    // MARK: Result

    @ViewBuilder
    private func resultCard(_ result: PlantDiagnosis) -> some View {
        card {
            Label("Here's what Bacán thinks", systemImage: "stethoscope")
                .font(.caption.weight(.medium)).foregroundStyle(Color.sky)
            Text(result.diagnosis)
                .foregroundStyle(Color.ink)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("troubleshoot-diagnosis")

            if !result.fixes.isEmpty {
                Divider().opacity(0.4)
                Text("Try this").font(.subheadline.weight(.semibold)).foregroundStyle(Color.ink)
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(result.fixes.enumerated()), id: \.offset) { _, fix in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "leaf.fill")
                                .font(.caption).foregroundStyle(Color.bacanGreen)
                                .padding(.top, 3)
                            Text(fix).foregroundStyle(Color.ink)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }

            if let tip = result.careTip, !tip.isEmpty {
                Divider().opacity(0.4)
                Label {
                    Text(tip).foregroundStyle(Color.ink).fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "lightbulb.fill").foregroundStyle(Color.marigold)
                }
                .font(.subheadline)
            }

            // The context-adaptive payoff: a one-tap cadence change when the AI's suggestion actually
            // differs from the current Water interval.
            if let days = store.suggestedWaterInterval {
                Divider().opacity(0.4)
                if store.waterAdjusted {
                    Label("Watering updated to every \(days) days", systemImage: "checkmark.circle.fill")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Color.bacanGreen)
                        .accessibilityIdentifier("troubleshoot-water-updated")
                } else {
                    Button {
                        store.send(.acceptWaterTapped)
                    } label: {
                        Label("Update watering to every \(days) days", systemImage: "drop.fill")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 4)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.sky)
                    .accessibilityIdentifier("troubleshoot-update-water")
                }
            }
        }
    }

    private func errorCard(_ note: String) -> some View {
        card {
            Label(note, systemImage: "wifi.exclamationmark")
                .font(.subheadline).foregroundStyle(Color.inkSoft)
        }
        .accessibilityIdentifier("troubleshoot-error")
    }

    // MARK: Card scaffold

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12, content: content)
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.familySurface))
    }
}
