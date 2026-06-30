import BottleCardFeature
import CatalogClient
import ComposableArchitecture
import IdentifyClient
import PhotosUI
import SwiftUI
import UIKit
import VisionKit
import WineDomain

@Reducer
public struct ScanReducer {
    @ObservableState
    public struct State: Equatable {
        public enum Status: Equatable {
            case idle
            case identifying
            case result(WineCandidate)
            case resolving(WineCandidate)
            case resolved(Wine)
            case failed(String)
        }

        public var status: Status = .idle

        /// First-run onboarding: drives the one-screen Scan explainer sheet. Set on `.task` when the
        /// persisted `hasSeenScanIntro` flag is still false; cleared on `.onboardingDismissed`.
        public var showOnboarding = false

        /// The label image bytes captured for the in-flight scan (camera capture, chosen photo, or the
        /// sample bottle). Threaded into the bottle card so it can render the *local* image immediately
        /// (M4 only DISPLAYS it — no Storage upload / `labelImageURL` write; that's a later milestone).
        /// Nil for the barcode path (no image) and cleared on `.scanAgain`.
        public var capturedImageData: Data?

        /// M5: the composed bottle-card child store, built once resolution succeeds. Rendered inline
        /// (not as a sheet) so the journaling buttons + form sheets are properly wired.
        public var bottleCard: BottleCardFeature.State?

        public init() {}

        /// The catalog-resolved `Wine` (with `enrichment` + per-field `provenance`) once resolution has
        /// succeeded, else nil. Lets the view layer / M4 bottle card read the enriched wine and render
        /// provenance badges without re-matching the `Status` enum.
        public var resolvedWine: Wine? {
            guard case let .resolved(wine) = status else { return nil }
            return wine
        }
    }

    public enum Action: Equatable {
        case task
        case onboardingDismissed
        case useSampleTapped
        case imageCaptured(Data)
        case barcodeScanned(String, String?)
        case identifyResponse(WineCandidate)
        case identifyFailed(String)
        case resolveResponse(Wine)
        case resolveFailed(String)
        case scanAgain
        case bottleCard(BottleCardFeature.Action)
    }

    public init() {}

    public var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case .task:
                // First run only: show the Scan explainer until the user dismisses it once.
                @Shared(.appStorage("hasSeenScanIntro")) var hasSeenScanIntro = false
                if !hasSeenScanIntro {
                    state.showOnboarding = true
                }
                return .none

            case .onboardingDismissed:
                @Shared(.appStorage("hasSeenScanIntro")) var hasSeenScanIntro = false
                $hasSeenScanIntro.withLock { $0 = true }
                state.showOnboarding = false
                return .none

            case .useSampleTapped:
                let sampleData = IdentifyFixtures.sampleLabelImageData
                state.capturedImageData = sampleData
                state.status = .identifying
                return .run { send in
                    @Dependency(\.identify) var identify
                    do {
                        let candidate = try await identify.identify(sampleData)
                        await send(.identifyResponse(candidate))
                    } catch {
                        await send(.identifyFailed(error.localizedDescription))
                    }
                }

            case .imageCaptured(let data):
                state.capturedImageData = data
                state.status = .identifying
                return .run { send in
                    @Dependency(\.identify) var identify
                    do {
                        let candidate = try await identify.identify(data)
                        await send(.identifyResponse(candidate))
                    } catch {
                        await send(.identifyFailed(error.localizedDescription))
                    }
                }

            case let .barcodeScanned(payload, symbology):
                // Barcode scans carry no label image.
                state.capturedImageData = nil
                state.status = .identifying
                return .run { send in
                    @Dependency(\.identify) var identify
                    let candidate = identify.identifyBarcode(payload, symbology)
                    await send(.identifyResponse(candidate))
                }

            case .identifyResponse(let candidate):
                // Resolve the confirmed candidate against the shared catalog (cache hit or create).
                state.status = .resolving(candidate)
                return .run { send in
                    @Dependency(\.catalog) var catalog
                    do {
                        let wine = try await catalog.resolve(candidate)
                        await send(.resolveResponse(wine))
                    } catch {
                        await send(.resolveFailed(error.localizedDescription))
                    }
                }

            case .identifyFailed(let message):
                state.status = .failed(message)
                return .none

            case .resolveResponse(let wine):
                state.status = .resolved(wine)
                state.bottleCard = BottleCardFeature.State(
                    wine: wine,
                    imageData: state.capturedImageData,
                    isResolving: false
                )
                return .none

            case .resolveFailed:
                // Graceful fallback: barcode-only / insufficient-identity candidates can't resolve,
                // so keep the candidate visible rather than breaking the scan UX.
                if case let .resolving(candidate) = state.status {
                    state.status = .result(candidate)
                }
                state.bottleCard = nil
                return .none

            case .scanAgain:
                // Return to a clean idle state, dropping the captured image.
                state.capturedImageData = nil
                state.status = .idle
                state.bottleCard = nil
                return .none

            case .bottleCard:
                return .none
            }
        }
        .ifLet(\.bottleCard, action: \.bottleCard) {
            BottleCardFeature()
        }
    }
}

public struct ScanView: View {
    let store: StoreOf<ScanReducer>
    @State private var pickedItem: PhotosPickerItem?
    @State private var isShowingBarcodeScanner = false
    @State private var isShowingCameraCapture = false

    private var isBarcodeScanningAvailable: Bool {
        DataScannerViewController.isSupported && DataScannerViewController.isAvailable
    }

    private var isCameraCaptureAvailable: Bool {
        UIImagePickerController.isSourceTypeAvailable(.camera)
    }

    public init(store: StoreOf<ScanReducer>) {
        self.store = store
    }

    public var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(.default, value: store.status)
            .navigationTitle("Scan")
            .task { store.send(.task) }
            .sheet(
                isPresented: Binding(
                    get: { store.showOnboarding },
                    set: { isPresented in
                        if !isPresented { store.send(.onboardingDismissed) }
                    }
                )
            ) {
                ScanOnboardingView { store.send(.onboardingDismissed) }
            }
    }

    @ViewBuilder
    private var content: some View {
        switch store.status {
        case .idle:
            idleView
        case .identifying:
            ProgressView("Identifying…")
        case .result(let candidate):
            CandidateResultView(candidate: candidate) {
                store.send(.scanAgain)
            }
        case .resolving(let candidate):
            // M4 Phase 2 progressive reveal: render the card the instant we have identity, with
            // enrichment-derived rows shown as shimmer placeholders while catalog resolution runs.
            // Same view type + stable `.id` as the `.resolved` branch ⇒ the shimmer fills in rather
            // than the view swapping.
            bottleCard(resolvingCardState(candidate))
        case .resolved:
            // M4/M5: the enriched, provenance-badged bottle card backed by a REAL composed child
            // store so the journaling buttons + form sheets are wired. Same `.id` as the resolving
            // path so identity is preserved across the resolving→resolved transition.
            if let cardStore = store.scope(state: \.bottleCard, action: \.bottleCard) {
                BottleCardView(store: cardStore)
                    .id("bottle-card")
                    .toolbar { ToolbarItem(placement: .topBarTrailing) { scanAgainToolbarButton } }
            }
        case .failed(let message):
            failedView(message)
        }
    }

    /// The shared bottle-card presentation used for both `.resolving` and `.resolved`. A stable `.id`
    /// keeps SwiftUI identity across the two states so the progressive reveal animates in place.
    private func bottleCard(_ state: BottleCardFeature.State) -> some View {
        BottleCardView(state: state)
            .id("bottle-card")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { scanAgainToolbarButton } }
    }

    /// "Scan again" affordance in the nav bar (top-trailing) so it doesn't overlap the card's own
    /// in-content "Add to cellar" / "Log a tasting" CTAs — it previously sat as a pinned bottom
    /// `.thinMaterial` bar over them, intercepting taps on the bottom action.
    private var scanAgainToolbarButton: some View {
        Button("Scan again") {
            store.send(.scanAgain)
        }
        .accessibilityIdentifier("scan-again-button")
    }

    /// Build the resolving-state card from the candidate's *identity* (known the instant the scan
    /// completes). Uses `provisionalWine` when the candidate has enough identity to form one, else a
    /// minimal identity `Wine` from the candidate fields. Enrichment is still in flight, so the card
    /// renders those rows as shimmer.
    private func resolvingCardState(_ candidate: WineCandidate) -> BottleCardFeature.State {
        let wine = candidate.provisionalWine ?? Wine(
            producer: candidate.producer ?? "Identifying…",
            name: candidate.name,
            vintage: candidate.vintage,
            region: candidate.region,
            grapes: candidate.grapes
        )
        return BottleCardFeature.State(
            wine: wine,
            candidate: candidate,
            imageData: store.capturedImageData,
            isResolving: true
        )
    }

    private var idleView: some View {
        VStack(spacing: 20) {
            Image(systemName: "camera.viewfinder")
                .font(.system(size: 60))
                .foregroundStyle(.secondary)

            Text("Scan a bottle")
                .font(.largeTitle.bold())

            Text("Identify a wine from its label.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            VStack(spacing: 12) {
                if isBarcodeScanningAvailable {
                    Button {
                        isShowingBarcodeScanner = true
                    } label: {
                        Label("Scan barcode", systemImage: "barcode.viewfinder")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("scan-barcode-button")
                }

                if isCameraCaptureAvailable {
                    Button {
                        isShowingCameraCapture = true
                    } label: {
                        Label("Photograph label", systemImage: "camera")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("camera-capture-button")
                }

                Button {
                    store.send(.useSampleTapped)
                } label: {
                    Label("Use sample bottle", systemImage: "wineglass")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("use-sample-button")

                PhotosPicker(selection: $pickedItem, matching: .images) {
                    Label("Choose photo", systemImage: "photo")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("choose-photo-button")
            }
            .padding(.horizontal, 40)
            .padding(.top, 8)

            if isBarcodeScanningAvailable || isCameraCaptureAvailable {
                Text("Point your phone at a bottle.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding()
        .onChange(of: pickedItem) { _, newItem in
            guard let newItem else { return }
            Task {
                if let data = try? await newItem.loadTransferable(type: Data.self) {
                    store.send(.imageCaptured(data))
                }
            }
        }
        .fullScreenCover(isPresented: $isShowingBarcodeScanner) {
            BarcodeScannerView { payload, symbology in
                isShowingBarcodeScanner = false
                store.send(.barcodeScanned(payload, symbology))
            } onCancel: {
                isShowingBarcodeScanner = false
            }
            .ignoresSafeArea()
        }
        .fullScreenCover(isPresented: $isShowingCameraCapture) {
            LabelCameraView { data in
                isShowingCameraCapture = false
                store.send(.imageCaptured(data))
            } onCancel: {
                isShowingCameraCapture = false
            }
            .ignoresSafeArea()
        }
    }

    private func failedView(_ message: String) -> some View {
        VStack(spacing: 20) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 60))
                .foregroundStyle(.orange)

            Text("Couldn't identify")
                .font(.title2.bold())

            Text(message)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button("Try again") {
                store.send(.scanAgain)
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("try-again-button")
        }
        .padding()
    }
}

// MARK: - First-run onboarding

/// A friendly one-screen explainer shown the first time the Scan tab is opened. Explains what
/// scanning does and the three ways to capture a bottle, then persists `hasSeenScanIntro` on dismiss.
private struct ScanOnboardingView: View {
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 24) {
                    VStack(spacing: 12) {
                        Image(systemName: "camera.viewfinder")
                            .font(.system(size: 56))
                            .foregroundStyle(.tint)
                        Text("Scan any bottle")
                            .font(.largeTitle.bold())
                            .multilineTextAlignment(.center)
                        Text("Point at a wine and Menere identifies it from the label, then builds a bottle card you can save or rate.")
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(.top, 32)

                    VStack(alignment: .leading, spacing: 20) {
                        OnboardingRow(
                            systemImage: "barcode.viewfinder",
                            title: "Scan a barcode",
                            detail: "Fastest when the back label has one."
                        )
                        OnboardingRow(
                            systemImage: "camera",
                            title: "Photograph the label",
                            detail: "Hold steady so the text is sharp."
                        )
                        OnboardingRow(
                            systemImage: "wineglass",
                            title: "Try a sample",
                            detail: "Not near a bottle? Use the sample to see how it works."
                        )
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
                }
                .padding(.horizontal, 24)
            }

            Button {
                onDismiss()
            } label: {
                Text("Got it")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
            .accessibilityIdentifier("scan-onboarding-dismiss")
        }
        .accessibilityIdentifier("scan-onboarding")
        .interactiveDismissDisabled()
    }
}

private struct OnboardingRow: View {
    let systemImage: String
    let title: String
    let detail: String

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: systemImage)
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Result view

private struct CandidateResultView: View {
    let candidate: WineCandidate
    let onScanAgain: () -> Void

    var body: some View {
        Form {
            Section {
                LabeledContent("Producer") {
                    Text(candidate.producer ?? "Unknown producer")
                        .accessibilityIdentifier("candidate-producer")
                }
                if let name = candidate.name, !name.isEmpty {
                    LabeledContent("Cuvée", value: name)
                }
                LabeledContent("Vintage", value: vintageText)
                if let region = regionSummary {
                    LabeledContent("Region", value: region)
                }
                if !candidate.grapes.isEmpty {
                    LabeledContent("Grapes", value: candidate.grapes.joined(separator: ", "))
                }
                if let barcode = candidate.barcode, !barcode.isEmpty {
                    LabeledContent("Barcode", value: barcode)
                }
            }

            Section {
                Label(confidenceTitle, systemImage: confidenceSymbol)
                    .foregroundStyle(.secondary)
                Label(sourceTitle, systemImage: sourceSymbol)
                    .foregroundStyle(.secondary)
            }

            if !candidate.rawText.isEmpty {
                Section {
                    DisclosureGroup("Raw text") {
                        ForEach(Array(candidate.rawText.enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.footnote.monospaced())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Section {
                Button("Scan again") {
                    onScanAgain()
                }
                .accessibilityIdentifier("scan-again-button")
            }
        }
    }

    private var vintageText: String {
        if let vintage = candidate.vintage {
            return String(vintage)
        }
        return "NV"
    }

    private var regionSummary: String? {
        guard let region = candidate.region else { return nil }
        let parts = [region.country, region.region, region.subregion, region.appellation]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var confidenceTitle: String {
        candidate.confidence < 0.6 ? "AI estimate" : "Identified"
    }

    private var confidenceSymbol: String {
        candidate.confidence < 0.6 ? "sparkles" : "checkmark.seal"
    }

    private var sourceTitle: String {
        switch candidate.source {
        case .barcode: "From barcode"
        case .label: "From label"
        }
    }

    private var sourceSymbol: String {
        switch candidate.source {
        case .barcode: "barcode.viewfinder"
        case .label: "text.viewfinder"
        }
    }
}

// MARK: - Barcode scanner

/// Wraps VisionKit's `DataScannerViewController` for live barcode scanning. On the first recognized
/// barcode it extracts the payload string + symbology and invokes `onScan`, then the SwiftUI layer
/// dismisses. UIKit/VisionKit types stay confined to the View layer.
private struct BarcodeScannerView: UIViewControllerRepresentable {
    let onScan: (_ payload: String, _ symbology: String?) -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onScan: onScan, onCancel: onCancel)
    }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(
            recognizedDataTypes: [.barcode()],
            qualityLevel: .balanced,
            isHighFrameRateTrackingEnabled: false,
            isHighlightingEnabled: true
        )
        scanner.delegate = context.coordinator

        // Cancel affordance overlaid on the scanner.
        let cancelButton = UIButton(type: .system)
        cancelButton.setTitle("Cancel", for: .normal)
        cancelButton.titleLabel?.font = .preferredFont(forTextStyle: .headline)
        cancelButton.translatesAutoresizingMaskIntoConstraints = false
        cancelButton.addTarget(
            context.coordinator,
            action: #selector(Coordinator.cancelTapped),
            for: .touchUpInside
        )
        scanner.view.addSubview(cancelButton)
        NSLayoutConstraint.activate([
            cancelButton.leadingAnchor.constraint(
                equalTo: scanner.view.safeAreaLayoutGuide.leadingAnchor,
                constant: 16
            ),
            cancelButton.topAnchor.constraint(
                equalTo: scanner.view.safeAreaLayoutGuide.topAnchor,
                constant: 16
            ),
        ])

        return scanner
    }

    func updateUIViewController(_ uiViewController: DataScannerViewController, context: Context) {
        try? uiViewController.startScanning()
    }

    static func dismantleUIViewController(
        _ uiViewController: DataScannerViewController,
        coordinator: Coordinator
    ) {
        uiViewController.stopScanning()
    }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        private let onScan: (_ payload: String, _ symbology: String?) -> Void
        private let onCancel: () -> Void
        private var didScan = false

        init(
            onScan: @escaping (_ payload: String, _ symbology: String?) -> Void,
            onCancel: @escaping () -> Void
        ) {
            self.onScan = onScan
            self.onCancel = onCancel
        }

        @objc func cancelTapped() {
            onCancel()
        }

        func dataScanner(
            _ dataScanner: DataScannerViewController,
            didAdd addedItems: [RecognizedItem],
            allItems: [RecognizedItem]
        ) {
            handle(addedItems, in: dataScanner)
        }

        private func handle(_ items: [RecognizedItem], in scanner: DataScannerViewController) {
            guard !didScan else { return }
            for item in items {
                guard case let .barcode(barcode) = item,
                      let payload = barcode.payloadStringValue, !payload.isEmpty
                else { continue }
                didScan = true
                scanner.stopScanning()
                onScan(payload, barcode.observation.symbology.rawValue)
                return
            }
        }
    }
}

// MARK: - Label camera capture

/// Wraps `UIImagePickerController` (`.camera`) to photograph a bottle label. The captured image is
/// encoded to JPEG `Data` and handed to `onCapture`, reusing the existing OCR + Foundation Models
/// identify flow. A pragmatic MVP capture; a custom `AVCaptureSession` is out of scope.
private struct LabelCameraView: UIViewControllerRepresentable {
    let onCapture: (Data) -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onCapture: onCapture, onCancel: onCancel)
    }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    final class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        private let onCapture: (Data) -> Void
        private let onCancel: () -> Void

        init(onCapture: @escaping (Data) -> Void, onCancel: @escaping () -> Void) {
            self.onCapture = onCapture
            self.onCancel = onCancel
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            guard let image = info[.originalImage] as? UIImage,
                  let data = image.jpegData(compressionQuality: 0.9)
            else {
                onCancel()
                return
            }
            onCapture(data)
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            onCancel()
        }
    }
}
