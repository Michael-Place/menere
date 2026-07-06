import ComposableArchitecture
import MenereUI
import PhotosUI
import SwiftUI
import UIKit

/// The smart-capture sheet: type or dictate a note, and/or add a photo, then let Bacán propose where
/// it goes. The user always confirms (or overrides) the destination before anything is filed.
public struct CaptureView: View {
    @Bindable var store: StoreOf<CaptureReducer>
    @State private var pickerItem: PhotosPickerItem?
    @State private var showCamera = false
    @FocusState private var noteFocused: Bool

    public init(store: StoreOf<CaptureReducer>) {
        self.store = store
    }

    public var body: some View {
        NavigationStack {
            ZStack {
                Color.familyCanvas.ignoresSafeArea()
                content
                if store.stage == .done {
                    ConfettiBurst(color: store.routedTo?.tint ?? .bacanGreen, trigger: store.confettiTrigger)
                        .ignoresSafeArea()
                }
            }
            .navigationTitle("Capture")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { store.send(.doneTapped) }
                        .accessibilityIdentifier("capture-close")
                }
            }
            .task { store.send(.task) }
            .onChange(of: pickerItem) { _, item in
                guard let item else { return }
                Task {
                    if let data = try? await item.loadTransferable(type: Data.self),
                       let ui = UIImage(data: data),
                       let jpeg = CaptureImageProcessing.downscaledJPEG(from: ui, maxEdge: 2000, quality: 0.75),
                       let thumb = CaptureImageProcessing.thumbnailJPEG(from: ui) {
                        store.send(.photoProcessed(jpeg: jpeg, thumbnail: thumb))
                    }
                    pickerItem = nil
                }
            }
            .fullScreenCover(isPresented: $showCamera) {
                CameraPicker(
                    onCapture: { ui in
                        showCamera = false
                        if let jpeg = CaptureImageProcessing.downscaledJPEG(from: ui, maxEdge: 2000, quality: 0.75),
                           let thumb = CaptureImageProcessing.thumbnailJPEG(from: ui) {
                            store.send(.photoProcessed(jpeg: jpeg, thumbnail: thumb))
                        }
                    },
                    onCancel: { showCamera = false }
                )
                .ignoresSafeArea()
            }
        }
        .tint(.bacanGreen)
    }

    @ViewBuilder
    private var content: some View {
        switch store.stage {
        case .compose: composeStage
        case .classifying: classifyingStage
        case .confirm: confirmStage
        case .filing: filingStage
        case .done: doneStage
        }
    }

    // MARK: - Compose

    private var composeStage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Capture anything")
                        .familyDisplay()
                    Text("A photo, a note — Bacán figures out where it goes.")
                        .familyTitle(.subheadline)
                        .foregroundStyle(Color.inkSoft)
                }

                photoWell

                VStack(alignment: .leading, spacing: 8) {
                    Text("Add a note")
                        .familyTitle(.headline)
                        .foregroundStyle(Color.ink)
                    ZStack(alignment: .topLeading) {
                        if store.text.isEmpty {
                            Text("“Buy batteries” · “Oliver walked today!” · “Dentist Tuesday at 3”")
                                .foregroundStyle(Color.inkSoft.opacity(0.7))
                                .padding(.top, 8)
                                .padding(.leading, 5)
                        }
                        TextEditor(text: $store.text)
                            .focused($noteFocused)
                            .frame(minHeight: 96)
                            .scrollContentBackground(.hidden)
                            .accessibilityIdentifier("capture-note-field")
                    }
                    .padding(10)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color.familySurface)
                    )
                    Label("Tap the mic on the keyboard to dictate.", systemImage: "mic.fill")
                        .font(.caption)
                        .foregroundStyle(Color.inkSoft)
                }

                Button { noteFocused = false; store.send(.classifyTapped) } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "sparkles")
                        Text("Route it")
                            .font(.system(.headline, design: .rounded).weight(.semibold))
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 15)
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(store.hasInput ? Color.bacanGreen : Color.inkSoft.opacity(0.4))
                    )
                }
                .buttonStyle(.pressable)
                .disabled(!store.hasInput)
                .accessibilityIdentifier("capture-route-button")
            }
            .padding(20)
        }
    }

    private var photoWell: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Add a photo")
                .familyTitle(.headline)
                .foregroundStyle(Color.ink)
            if let thumb = store.thumbnail, let ui = UIImage(data: thumb) {
                ZStack(alignment: .topTrailing) {
                    Image(uiImage: ui)
                        .resizable()
                        .scaledToFill()
                        .frame(height: 180)
                        .frame(maxWidth: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    Button { store.send(.clearPhoto) } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title2)
                            .foregroundStyle(.white, .black.opacity(0.4))
                            .padding(8)
                    }
                    .accessibilityIdentifier("capture-clear-photo")
                }
            } else {
                HStack(spacing: 12) {
                    PhotosPicker(selection: $pickerItem, matching: .images) {
                        pickerTile(symbol: "photo.on.rectangle", label: "Library")
                    }
                    .accessibilityIdentifier("capture-photo-library")
                    if CameraPicker.isCameraAvailable {
                        Button { showCamera = true } label: {
                            pickerTile(symbol: "camera.fill", label: "Camera")
                        }
                        .buttonStyle(.pressable)
                        .accessibilityIdentifier("capture-photo-camera")
                    }
                }
            }
        }
    }

    private func pickerTile(symbol: String, label: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: symbol).font(.title2)
            Text(label).font(.system(.subheadline, design: .rounded).weight(.semibold))
        }
        .foregroundStyle(Color.bacanGreen)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 22)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.bacanGreen.opacity(0.12))
        )
    }

    // MARK: - Classifying

    private var classifyingStage: some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.3)
            Text("Figuring out where this goes…")
                .familyTitle(.headline)
                .foregroundStyle(Color.ink)
            Text("Bacán is looking at your photo.")
                .font(.subheadline)
                .foregroundStyle(Color.inkSoft)
        }
        .padding(40)
    }

    // MARK: - Confirm

    private var confirmStage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Where should this go?")
                    .familyDisplay()

                capturePreview

                if let hint = store.plantHint, hint.isConfident {
                    Label("Looks like \(hint.commonName) 🌿", systemImage: "leaf.fill")
                        .font(.system(.subheadline, design: .rounded).weight(.semibold))
                        .foregroundStyle(Color.bacanGreen)
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(Capsule().fill(Color.bacanGreen.opacity(0.12)))
                }

                if let error = store.errorMessage {
                    Text(error)
                        .font(.subheadline)
                        .foregroundStyle(Color.terracotta)
                }

                VStack(spacing: 10) {
                    ForEach(Array(store.suggestions.enumerated()), id: \.element) { index, dest in
                        destinationRow(dest, isTop: index == 0)
                    }
                }

                Button { store.send(.fileTapped) } label: {
                    HStack(spacing: 8) {
                        Image(systemName: store.selected?.symbol ?? "tray.and.arrow.down.fill")
                        Text("File it")
                            .font(.system(.headline, design: .rounded).weight(.semibold))
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 15)
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(store.selected?.tint ?? Color.bacanGreen)
                    )
                }
                .buttonStyle(.pressable)
                .disabled(store.selected == nil)
                .accessibilityIdentifier("capture-file-button")

                Button("Edit capture") { store.send(.editTapped) }
                    .font(.subheadline)
                    .foregroundStyle(Color.inkSoft)
                    .frame(maxWidth: .infinity)
            }
            .padding(20)
        }
    }

    private func destinationRow(_ dest: CaptureDestination, isTop: Bool) -> some View {
        let isSelected = store.selected == dest
        return Button { store.send(.selectDestination(dest)) } label: {
            HStack(spacing: 14) {
                ZStack {
                    Circle().fill(dest.tint.opacity(0.15)).frame(width: 44, height: 44)
                    Image(systemName: dest.symbol).foregroundStyle(dest.tint)
                }
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(dest.title)
                            .font(.system(.headline, design: .rounded).weight(.semibold))
                            .foregroundStyle(Color.ink)
                        if isTop {
                            Text("Suggested")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(dest.tint)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Capsule().fill(dest.tint.opacity(0.15)))
                        }
                    }
                    Text(dest.blurb)
                        .font(.caption)
                        .foregroundStyle(Color.inkSoft)
                }
                Spacer()
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? dest.tint : Color.inkSoft.opacity(0.4))
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.familySurface)
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(isSelected ? dest.tint : .clear, lineWidth: 2)
                    )
            )
        }
        .buttonStyle(.pressable)
        .accessibilityIdentifier("capture-dest-\(dest.rawValue)")
    }

    @ViewBuilder
    private var capturePreview: some View {
        HStack(spacing: 14) {
            if let thumb = store.thumbnail, let ui = UIImage(data: thumb) {
                Image(uiImage: ui)
                    .resizable().scaledToFill()
                    .frame(width: 60, height: 60)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            if !store.trimmedText.isEmpty {
                Text(store.trimmedText)
                    .font(.subheadline)
                    .foregroundStyle(Color.ink)
                    .lineLimit(3)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - Filing

    private var filingStage: some View {
        VStack(spacing: 16) {
            ProgressView().scaleEffect(1.3)
            Text("Filing it…")
                .familyTitle(.headline)
                .foregroundStyle(Color.ink)
        }
        .padding(40)
    }

    // MARK: - Done

    private var doneStage: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 64))
                .foregroundStyle(store.routedTo?.tint ?? .bacanGreen)
            Text(store.receipt ?? "Filed ✓")
                .familyTitle(.title3)
                .foregroundStyle(Color.ink)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            Spacer()
            VStack(spacing: 10) {
                Button { store.send(.captureAnotherTapped) } label: {
                    Text("Capture another")
                        .font(.system(.headline, design: .rounded).weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 15)
                        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.bacanGreen))
                }
                .buttonStyle(.pressable)
                .accessibilityIdentifier("capture-another-button")
                Button("Done") { store.send(.doneTapped) }
                    .font(.headline)
                    .foregroundStyle(Color.inkSoft)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .accessibilityIdentifier("capture-done-button")
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 12)
        }
        .successHaptic(store.confettiTrigger)
    }
}
