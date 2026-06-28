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
            case failed(String)
        }

        public var status: Status = .idle

        public init() {}
    }

    public enum Action: Equatable {
        case task
        case useSampleTapped
        case imageCaptured(Data)
        case barcodeScanned(String, String?)
        case identifyResponse(WineCandidate)
        case identifyFailed(String)
        case scanAgain
    }

    public init() {}

    public var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case .task:
                return .none

            case .useSampleTapped:
                state.status = .identifying
                return .run { send in
                    @Dependency(\.identify) var identify
                    do {
                        let candidate = try await identify.identify(IdentifyFixtures.sampleLabelImageData)
                        await send(.identifyResponse(candidate))
                    } catch {
                        await send(.identifyFailed(error.localizedDescription))
                    }
                }

            case .imageCaptured(let data):
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
                state.status = .identifying
                return .run { send in
                    @Dependency(\.identify) var identify
                    let candidate = identify.identifyBarcode(payload, symbology)
                    await send(.identifyResponse(candidate))
                }

            case .identifyResponse(let candidate):
                state.status = .result(candidate)
                return .none

            case .identifyFailed(let message):
                state.status = .failed(message)
                return .none

            case .scanAgain:
                state.status = .idle
                return .none
            }
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
            .navigationTitle("Scan")
            .task { store.send(.task) }
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
        case .failed(let message):
            failedView(message)
        }
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
