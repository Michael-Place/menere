import Foundation
import Dependencies
import DependenciesMacros
import FirebaseFunctions

/// The client seam for the dumb `agentTurn` Cloud Function. The on-phone `AgentLoop` calls this once
/// per turn; the live impl forwards `{ system, messages, tools }` to the callable and parses back the
/// raw content blocks + stop reason. Injected via `@Dependency` so tests drive the loop with a
/// scripted mock proxy (no network).
@DependencyClient
public struct AgentProxyClient: Sendable {
    public var turn: @Sendable (
        _ system: String,
        _ messages: [AgentMessage],
        _ tools: [AgentToolDefinition]
    ) async throws -> AgentTurnResponse
}

extension AgentProxyClient: DependencyKey {
    public static let liveValue = AgentProxyClient(
        turn: { system, messages, tools in
            var data: [String: Any] = ["messages": messages.map(\.wire)]
            if !system.isEmpty { data["system"] = system }
            if !tools.isEmpty { data["tools"] = tools.map(\.wire) }

            let functions = Functions.functions(region: "us-central1")
            let result = try await functions.httpsCallable("agentTurn").call(data)

            let dict = result.data as? [String: Any]
            let stop = dict?["stopReason"] as? String
            let rawBlocks = (dict?["content"] as? [Any]) ?? []
            let blocks = rawBlocks.compactMap { element -> AgentContentBlock? in
                guard let raw = element as? [String: Any] else { return nil }
                return AgentContentBlock.parse(raw)
            }
            return AgentTurnResponse(content: blocks, stopReason: stop)
        }
    )
}

public extension DependencyValues {
    var agentProxy: AgentProxyClient {
        get { self[AgentProxyClient.self] }
        set { self[AgentProxyClient.self] = newValue }
    }
}
