import SwiftUI

/// Root of the tvOS app. Owns the `PairingModel` and swaps between the launch spinner, the big
/// pairing-code screen, and the connected household screen.
struct RootView: View {
    @State private var model = PairingModel()

    var body: some View {
        ZStack {
            BacanBackground()
            switch model.phase {
            case .launching:
                LoadingScreen(message: "Warming up the living room…")
            case .awaitingPairing(let code):
                PairingCodeScreen(code: code)
            case .connecting:
                LoadingScreen(message: "Linking this TV…")
            case .connected(let summary):
                ConnectedScreen(summary: summary)
            case .failed(let message):
                FailureScreen(message: message)
            }
        }
        .task { await model.start() }
    }
}

// MARK: - Shared chrome

/// The warm ¡Bacán! cream-to-green wash behind every screen.
struct BacanBackground: View {
    var body: some View {
        LinearGradient(
            colors: [
                Color(red: 0.98, green: 0.96, blue: 0.90),   // familyCanvas cream
                Color(red: 0.90, green: 0.94, blue: 0.86),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .ignoresSafeArea()
    }
}

private let bacanGreen = Color(red: 0.20, green: 0.45, blue: 0.32)
private let terracotta = Color(red: 0.82, green: 0.45, blue: 0.32)

struct LoadingScreen: View {
    let message: String
    var body: some View {
        VStack(spacing: 40) {
            ProgressView().scaleEffect(2.0)
            Text(message)
                .font(.system(.title2, design: .rounded))
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Pairing code

struct PairingCodeScreen: View {
    let code: String

    var body: some View {
        VStack(spacing: 48) {
            VStack(spacing: 12) {
                Text("¡Bacán!")
                    .font(.system(size: 64, weight: .heavy, design: .rounded))
                    .foregroundStyle(bacanGreen)
                Text("Link this TV to your family")
                    .font(.system(.title, design: .rounded).weight(.semibold))
                    .foregroundStyle(.primary)
            }

            HStack(spacing: 20) {
                ForEach(Array(code.enumerated()), id: \.offset) { _, ch in
                    Text(String(ch))
                        .font(.system(size: 96, weight: .bold, design: .monospaced))
                        .foregroundStyle(bacanGreen)
                        .frame(width: 120, height: 150)
                        .background(
                            RoundedRectangle(cornerRadius: 24)
                                .fill(.white)
                                .shadow(color: .black.opacity(0.12), radius: 10, y: 6)
                        )
                }
            }

            VStack(spacing: 10) {
                Text("On your phone, open ¡Bacán!")
                    .font(.system(.title2, design: .rounded).weight(.medium))
                Text("Settings  →  Link Apple TV  →  enter this code")
                    .font(.system(.title3, design: .rounded))
                    .foregroundStyle(terracotta)
            }
            .multilineTextAlignment(.center)
            .padding(.top, 8)
        }
        .padding(80)
    }
}

// MARK: - Connected

/// Once linked, the TV has two modes: the **Ambient** family-scrapbook screensaver (the idle
/// default) and the **Command Center** — the "what's going on today" board. The remote switches
/// between them via the **Play/Pause** button (works from anywhere) or a focusable button that
/// surfaces when the remote is touched. A short welcome banner greets the room on first connect.
struct ConnectedScreen: View {
    let summary: PairingModel.HouseholdSummary

    enum Mode { case ambient, command }

    @State private var mode: Mode = .ambient
    @State private var showWelcome = true
    @FocusState private var toggleFocused: Bool

    var body: some View {
        ZStack {
            switch mode {
            case .ambient:
                ambient
            case .command:
                CommandCenterView(summary: summary) {
                    withAnimation(.easeInOut(duration: 0.4)) { mode = .ambient }
                }
                .transition(.opacity)
            }
        }
        // The living-room idiom: Play/Pause on the Siri Remote flips between the screensaver and
        // the command center, no matter where focus sits.
        .onPlayPauseCommand {
            withAnimation(.easeInOut(duration: 0.4)) {
                mode = (mode == .ambient) ? .command : .ambient
            }
        }
    }

    // MARK: Ambient (screensaver) mode

    private var ambient: some View {
        ZStack {
            SlideshowView(hid: summary.hid)

            if showWelcome {
                ZStack {
                    Color.black.opacity(0.45).ignoresSafeArea()
                    VStack(spacing: 14) {
                        Text("You're connected! 🎉")
                            .font(.system(size: 60, weight: .heavy, design: .rounded))
                            .foregroundStyle(.white)
                        Text("Welcome to \(summary.familyName)'s living room")
                            .font(.system(.title2, design: .rounded))
                            .foregroundStyle(.white.opacity(0.85))
                        Text("Press ▶︎❚❚ for the Command Center")
                            .font(.system(.title3, design: .rounded))
                            .foregroundStyle(.white.opacity(0.7))
                            .padding(.top, 6)
                    }
                }
                .transition(.opacity)
            }

            // Focusable reveal: dim hint at rest, brightens when the remote gives it focus.
            VStack {
                HStack {
                    Spacer()
                    Button {
                        withAnimation(.easeInOut(duration: 0.4)) { mode = .command }
                    } label: {
                        Label("Command Center", systemImage: "rectangle.3.group.fill")
                            .font(.system(.title3, design: .rounded).weight(.semibold))
                    }
                    .focused($toggleFocused)
                    .opacity(toggleFocused ? 1 : 0.35)
                }
                Spacer()
            }
            .padding(.top, 54)
            .padding(.trailing, 70)
        }
        .task {
            try? await Task.sleep(nanoseconds: 3_200_000_000)
            withAnimation(.easeInOut(duration: 1.0)) { showWelcome = false }
        }
    }
}

struct CountTile: View {
    let value: Int
    let label: String
    let emoji: String

    var body: some View {
        VStack(spacing: 12) {
            Text(emoji).font(.system(size: 64))
            Text("\(value)")
                .font(.system(size: 80, weight: .heavy, design: .rounded))
                .foregroundStyle(bacanGreen)
            Text(label)
                .font(.system(.title3, design: .rounded).weight(.medium))
                .foregroundStyle(.secondary)
        }
        .frame(width: 260, height: 300)
        .background(
            RoundedRectangle(cornerRadius: 32)
                .fill(.white)
                .shadow(color: .black.opacity(0.10), radius: 12, y: 8)
        )
    }
}

struct FailureScreen: View {
    let message: String
    var body: some View {
        VStack(spacing: 24) {
            Text("Hmm.")
                .font(.system(size: 56, weight: .heavy, design: .rounded))
                .foregroundStyle(terracotta)
            Text(message)
                .font(.system(.title2, design: .rounded))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 900)
        }
        .padding(80)
    }
}
