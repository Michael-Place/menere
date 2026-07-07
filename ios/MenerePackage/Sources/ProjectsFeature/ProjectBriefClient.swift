import Dependencies
import DependenciesMacros
import FamilyDomain
import FirebaseFunctions
import Foundation

/// Wraps the `generateProjectBrief` HTTPS callable (Projects PR4) — the AI read on where a project
/// stands. Mirrors ``BriefingClient`` (Today's `generateDailyBriefing`): the household/project are
/// passed explicitly, `force` bypasses the server-side cache (the refresh button), and
/// `decisionFocus` asks the model to weigh the gathered options (the "Help me decide" helper).
///
/// The function may not be deployed yet at build time — `generate` throws ``ProjectBriefError`` and
/// callers treat any failure as "no brief, show the gentle CTA". Nothing here assumes success.
@DependencyClient
public struct ProjectBriefClient: Sendable {
    /// Generate (or fetch the cached) brief for a project. `force` regenerates; `decisionFocus`
    /// asks for the pros/cons decision read.
    public var generate: @Sendable (_ hid: String, _ projectId: String, _ force: Bool, _ decisionFocus: Bool) async throws -> ProjectBrief
}

public enum ProjectBriefError: Error, Equatable {
    case invalidResponse
}

extension ProjectBriefClient: DependencyKey {
    public static let liveValue = ProjectBriefClient(
        generate: { hid, projectId, force, decisionFocus in
            let callable = Functions.functions(region: "us-central1").httpsCallable("generateProjectBrief")
            let result = try await callable.call([
                "hid": hid,
                "projectId": projectId,
                "force": force,
                "decisionFocus": decisionFocus,
            ])
            guard let data = result.data as? [String: Any] else {
                throw ProjectBriefError.invalidResponse
            }
            // Accept either a flat payload or a nested `brief` object.
            let payload = (data["brief"] as? [String: Any]) ?? data
            guard
                let summary = payload["summary"] as? String,
                !summary.isEmpty
            else { throw ProjectBriefError.invalidResponse }
            let highlights = (payload["highlights"] as? [String] ?? []).filter { !$0.isEmpty }
            let decisionRaw = (payload["decision"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let decision = (decisionRaw?.isEmpty == false) ? decisionRaw : nil
            return ProjectBrief(summary: summary, highlights: highlights, decision: decision, generatedAt: Date())
        }
    )

    /// Test/preview default: a canned pool brief so previews render a populated card without a network.
    public static let previewValue = ProjectBriefClient(
        generate: { _, _, _, decisionFocus in
            ProjectBrief(
                summary: "The backyard pool is moving right along, Michael. You've got three builders in the mix and two quotes gathered — Aqua Dreams is the low bid so far. HOA approval is still the long pole, so nudge that this week.",
                highlights: [
                    "Aqua Dreams is $22.5k under your budget — the current front-runner",
                    "Still waiting on the HOA + city permits",
                    "Confirm Blue Haven's insurance before comparing further",
                ],
                decision: decisionFocus
                    ? "Leaning Aqua Dreams: lowest bid and a solid warranty, but verify their license and references first. Blue Haven is pricier with a longer timeline. Hold the final call until the third quote lands."
                    : nil,
                generatedAt: Date()
            )
        }
    )
}

extension DependencyValues {
    public var projectBrief: ProjectBriefClient {
        get { self[ProjectBriefClient.self] }
        set { self[ProjectBriefClient.self] = newValue }
    }
}
