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

struct ConnectedScreen: View {
    let summary: PairingModel.HouseholdSummary

    var body: some View {
        VStack(spacing: 56) {
            VStack(spacing: 14) {
                Text("You're connected! 🎉")
                    .font(.system(size: 60, weight: .heavy, design: .rounded))
                    .foregroundStyle(bacanGreen)
                Text("Welcome to \(summary.familyName)'s living room")
                    .font(.system(.title2, design: .rounded))
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 28) {
                CountTile(value: summary.plants, label: "plants", emoji: "🪴")
                CountTile(value: summary.pets, label: "pets", emoji: "🐾")
                CountTile(value: summary.documents, label: "docs", emoji: "📄")
                CountTile(value: summary.events, label: "events", emoji: "📅")
            }
        }
        .padding(80)
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
