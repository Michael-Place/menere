import ComposableArchitecture
import FamilyDomain
import MenereUI
import PhotoLibraryClient
import SwiftUI
import UIKit

/// FL4 — the "People" sheet: run an on-device face scan, then tag each discovered face group as a
/// family member. Warm, honest copy ("we group faces right on your device — tag them once"). Tapping
/// a face opens a "Who is this?" picker; the mapping is saved device-locally so "Photos of {name}"
/// works in the photo browser.
public struct FaceTaggingView: View {
    @Bindable var store: StoreOf<FaceTaggingReducer>

    public init(store: StoreOf<FaceTaggingReducer>) {
        self.store = store
    }

    @Environment(\.dismiss) private var dismiss

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 12), count: 3)

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    header

                    if store.photoAuth == .denied {
                        deniedGate
                    } else if store.photoAuth != .ready {
                        connectGate
                    } else {
                        if !store.tagged.isEmpty { taggedSection }
                        scanSection
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 16)
            }
            .background(Color.familyCanvas)
            .navigationTitle("People")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("face-tagging-done")
                }
            }
            .task { store.send(.task) }
            .confirmationDialog(
                "Who is this?",
                isPresented: Binding(
                    get: { store.pickerCluster != nil },
                    set: { if !$0 { store.send(.pickerDismissed) } }
                ),
                titleVisibility: .visible,
                presenting: store.pickerCluster
            ) { _ in
                ForEach(store.untaggedMembers) { member in
                    Button(firstName(member.name)) {
                        store.send(.assignTapped(memberID: member.id))
                    }
                }
                Button("Skip", role: .cancel) { store.send(.pickerDismissed) }
            } message: { _ in
                Text("Tag this face as a family member — we'll remember it, right on this device.")
            }
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Find your people 💛")
                .font(.system(.title2, design: .rounded).weight(.bold))
                .foregroundStyle(Color.ink)
            Text("We group faces right on your device — nothing leaves your phone. Tag a face once, then you can pull up \u{201C}Photos of Oliver\u{201D} in a tap.")
                .font(.system(.subheadline, design: .rounded))
                .foregroundStyle(Color.inkSoft)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Tagged people

    private var taggedSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Tagged")
                .font(.system(.headline, design: .rounded).weight(.bold))
                .foregroundStyle(Color.bacanGreen)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    ForEach(store.tagged) { tag in
                        taggedChip(tag)
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    private func taggedChip(_ tag: FaceTag) -> some View {
        VStack(spacing: 6) {
            ZStack(alignment: .topTrailing) {
                faceThumb(tag.sampleThumbnail, side: 68)
                Button {
                    store.send(.untagTapped(memberID: tag.memberID))
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(.white, Color.terracotta)
                        .background(Circle().fill(.white).padding(3))
                }
                .offset(x: 6, y: -6)
                .accessibilityIdentifier("face-untag-\(tag.memberID)")
            }
            Text(firstName(tag.memberName))
                .font(.system(.footnote, design: .rounded).weight(.semibold))
                .foregroundStyle(Color.ink)
            Text("\(tag.assetIDs.count) photo\(tag.assetIDs.count == 1 ? "" : "s")")
                .font(.system(.caption2, design: .rounded))
                .foregroundStyle(Color.inkSoft)
        }
        .accessibilityIdentifier("face-tagged-\(tag.memberID)")
    }

    // MARK: Scan + discovered clusters

    @ViewBuilder
    private var scanSection: some View {
        switch store.scanPhase {
        case .idle:
            scanCallToAction
        case .scanning:
            scanningState
        case .done:
            if store.clusters.isEmpty {
                emptyClusters
            } else {
                clusterGrid
            }
        }
    }

    private var scanCallToAction: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(store.tagged.isEmpty ? "Scan your photos" : "Find more faces")
                .font(.system(.headline, design: .rounded).weight(.bold))
                .foregroundStyle(Color.ink)
            Text("We'll look through your favorites and recent photos (a couple hundred) and group the faces we find. It's a first pass — approximate, but a lovely start.")
                .font(.system(.subheadline, design: .rounded))
                .foregroundStyle(Color.inkSoft)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                store.send(.scanTapped)
            } label: {
                Label("Scan for faces", systemImage: "person.crop.rectangle.stack.fill")
                    .font(.system(.headline, design: .rounded).weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Capsule(style: .continuous).fill(Color.bacanGreen))
            }
            .buttonStyle(.pressable)
            .accessibilityIdentifier("face-scan-button")
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.familySurface))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.bacanGreen.opacity(0.2), lineWidth: 1))
    }

    private var scanningState: some View {
        VStack(spacing: 14) {
            ProgressView().controlSize(.large).tint(Color.bacanGreen)
            Text("Grouping faces on your device…")
                .font(.system(.subheadline, design: .rounded).weight(.semibold))
                .foregroundStyle(Color.ink)
            Text("This stays private — no photos are uploaded.")
                .font(.system(.caption, design: .rounded))
                .foregroundStyle(Color.inkSoft)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
        .accessibilityIdentifier("face-scanning")
    }

    private var clusterGrid: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Who's who?")
                .font(.system(.headline, design: .rounded).weight(.bold))
                .foregroundStyle(Color.bacanGreen)
            Text("Tap a face to tag it — or leave it be.")
                .font(.system(.subheadline, design: .rounded))
                .foregroundStyle(Color.inkSoft)
            LazyVGrid(columns: columns, spacing: 14) {
                ForEach(store.clusters) { cluster in
                    Button {
                        store.send(.clusterTapped(cluster))
                    } label: {
                        VStack(spacing: 5) {
                            faceThumb(cluster.sampleFaceThumbnail, side: 96)
                            Text("\(cluster.faceCount) photo\(cluster.faceCount == 1 ? "" : "s")")
                                .font(.system(.caption2, design: .rounded))
                                .foregroundStyle(Color.inkSoft)
                        }
                    }
                    .buttonStyle(.pressable)
                    .accessibilityIdentifier("face-cluster-\(cluster.id)")
                }
            }
            rescanButton
        }
    }

    private var emptyClusters: some View {
        VStack(spacing: 12) {
            Image(systemName: "face.dashed")
                .font(.system(size: 44))
                .foregroundStyle(Color.bacanGreen.opacity(0.6))
            Text("No new faces found")
                .font(.system(.headline, design: .rounded).weight(.bold))
                .foregroundStyle(Color.ink)
            Text("We looked through your favorites and recents but didn't spot new faces to group. Favorite a few people-photos and try again.")
                .font(.system(.subheadline, design: .rounded))
                .foregroundStyle(Color.inkSoft)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            rescanButton
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 30)
        .padding(.horizontal, 12)
        .accessibilityIdentifier("face-empty")
    }

    private var rescanButton: some View {
        Button {
            store.send(.scanTapped)
        } label: {
            Label("Scan again", systemImage: "arrow.clockwise")
                .font(.system(.subheadline, design: .rounded).weight(.semibold))
                .foregroundStyle(Color.bacanGreen)
        }
        .buttonStyle(.pressable)
        .padding(.top, 6)
        .accessibilityIdentifier("face-rescan")
    }

    // MARK: Gates

    private var connectGate: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Let Bacán see your photos")
                .font(.system(.headline, design: .rounded).weight(.bold))
                .foregroundStyle(Color.ink)
            Text("To group faces, Bacán needs to peek at your library — all on-device. You can share your whole library or just a few.")
                .font(.system(.subheadline, design: .rounded))
                .foregroundStyle(Color.inkSoft)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                store.send(.connectTapped)
            } label: {
                Text(store.isRequesting ? "Asking…" : "Connect photos")
                    .font(.system(.headline, design: .rounded).weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Capsule(style: .continuous).fill(Color.bacanGreen))
            }
            .buttonStyle(.pressable)
            .disabled(store.isRequesting)
            .accessibilityIdentifier("face-connect-button")
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.familySurface))
    }

    private var deniedGate: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Photos are turned off")
                .font(.system(.headline, design: .rounded).weight(.bold))
                .foregroundStyle(Color.ink)
            Text("To group faces, let Bacán see your photos in Settings.")
                .font(.system(.subheadline, design: .rounded))
                .foregroundStyle(Color.inkSoft)
            Button {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            } label: {
                Text("Open Settings")
                    .font(.system(.headline, design: .rounded).weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Capsule(style: .continuous).fill(Color.bacanGreen))
            }
            .buttonStyle(.pressable)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.familySurface))
    }

    // MARK: Bits

    private func faceThumb(_ data: Data?, side: CGFloat) -> some View {
        ZStack {
            if let data, let ui = UIImage(data: data) {
                Image(uiImage: ui)
                    .resizable().scaledToFill()
            } else {
                Color.bacanGreen.opacity(0.12)
                Image(systemName: "person.fill")
                    .font(.system(size: side * 0.4))
                    .foregroundStyle(Color.bacanGreen.opacity(0.5))
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: side * 0.28, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: side * 0.28, style: .continuous).strokeBorder(.white, lineWidth: 3))
        .shadow(color: .black.opacity(0.08), radius: 3, x: 0, y: 2)
    }

    private func firstName(_ name: String) -> String {
        name.split(separator: " ").first.map(String.init) ?? name
    }
}
