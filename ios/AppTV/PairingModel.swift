import FirebaseAuth
import FirebaseFirestore
import Foundation
import Observation

/// Drives the whole tvOS first-run flow: generate a pairing code → wait for the phone to confirm →
/// sign in with the custom token → read a bit of household data to prove the shared backend works.
///
/// Intentionally a plain `@Observable` model (not TCA) — the phone app owns the heavy TCA stack;
/// the TV stays lean and talks to Firebase directly.
@MainActor
@Observable
final class PairingModel {
    enum Phase: Equatable {
        case launching
        case awaitingPairing(code: String)
        case connecting
        case connected(HouseholdSummary)
        case failed(String)
    }

    struct HouseholdSummary: Equatable {
        var familyName: String
        var plants: Int
        var pets: Int
        var documents: Int
        var events: Int
    }

    private(set) var phase: Phase = .launching

    private let db = Firestore.firestore()
    private var pairingListener: ListenerRegistration?

    /// Codes avoid look-alike glyphs (no O/0, I/1) so they're easy to read off the TV and type on a
    /// phone.
    private static let codeAlphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")

    // For testing/QA: an injectable fixed code so a driver can pair a known value.
    private let forcedCode: String?

    init(forcedCode: String? = nil) {
        self.forcedCode = forcedCode
    }

    /// Entry point called from the root view's `.task`.
    func start() async {
        // Already linked on a previous launch? Jump straight to the household screen.
        if let user = Auth.auth().currentUser {
            await loadHousehold(for: user)
            return
        }
        await beginPairing()
    }

    // MARK: - Pairing

    private func beginPairing() async {
        let code = forcedCode ?? Self.makeCode()
        do {
            try await db.collection("tvPairing").document(code).setData([
                "status": "pending",
                "createdAt": FieldValue.serverTimestamp(),
            ])
        } catch {
            phase = .failed("Couldn't reach ¡Bacán! to start pairing. \(error.localizedDescription)")
            return
        }
        phase = .awaitingPairing(code: code)
        observePairing(code: code)
    }

    private func observePairing(code: String) {
        pairingListener?.remove()
        pairingListener = db.collection("tvPairing").document(code)
            .addSnapshotListener { [weak self] snapshot, _ in
                guard let self else { return }
                guard let data = snapshot?.data(),
                      (data["status"] as? String) == "paired",
                      let token = data["customToken"] as? String
                else { return }
                self.pairingListener?.remove()
                self.pairingListener = nil
                Task { await self.signIn(withCustomToken: token) }
            }
    }

    private func signIn(withCustomToken token: String) async {
        phase = .connecting
        do {
            let result = try await Auth.auth().signIn(withCustomToken: token)
            await loadHousehold(for: result.user)
        } catch {
            phase = .failed("Sign-in failed. \(error.localizedDescription)")
        }
    }

    // MARK: - Household read (proves shared backend + auth)

    private func loadHousehold(for user: User) async {
        // The TV's uid is `tv-{hid}`, so the household id is recoverable straight from the uid.
        let hid = householdId(from: user.uid)
        guard let hid else {
            phase = .failed("This TV isn't linked to a family yet.")
            return
        }
        do {
            let household = db.collection("households").document(hid)

            let care = try await household.collection("careItems").getDocuments()
            var plants = 0, pets = 0
            for doc in care.documents {
                switch doc.data()["kind"] as? String {
                case "plant": plants += 1
                case "pet": pets += 1
                default: break
                }
            }
            let documents = try await household.collection("documents").count.getAggregation(source: .server).count.intValue
            let events = try await household.collection("events").count.getAggregation(source: .server).count.intValue

            let hDoc = try await household.getDocument()
            let familyName = (hDoc.data()?["name"] as? String)?.trimmingCharacters(in: .whitespaces)

            phase = .connected(HouseholdSummary(
                familyName: (familyName?.isEmpty == false ? familyName! : "your family"),
                plants: plants,
                pets: pets,
                documents: documents,
                events: events
            ))
        } catch {
            phase = .failed("Couldn't load your family. \(error.localizedDescription)")
        }
    }

    private func householdId(from uid: String) -> String? {
        uid.hasPrefix("tv-") ? String(uid.dropFirst(3)) : nil
    }

    // MARK: - Helpers

    private static func makeCode() -> String {
        String((0..<6).map { _ in codeAlphabet.randomElement()! })
    }
}
