import Foundation
import Dependencies

/// Events streamed out of an `AgentLoop.run(…)` as the loop drives the model + tools. C2's UI
/// consumes these: text bubbles, "using X" indicators, action-chip receipts, confirmation prompts,
/// and terminal finished/failed states.
public enum AgentLoopEvent: Sendable, Equatable {
    case assistantText(String)
    case toolStarted(name: String)
    case receipt(AgentReceipt)
    /// The loop is paused awaiting `resume(id:approved:)` for this tool call (garage open, unlock).
    case confirmationNeeded(id: String, description: String)
    case finished(summary: String)
    case failed(friendlyMessage: String)
}

/// The client-side agentic loop: send the utterance, call the dumb `agentTurn` proxy, execute any
/// tool_use blocks locally via the registry, append tool_result, and re-call until `end_turn` or the
/// turn cap. Confirmation-gated tools pause the loop and resume on the user's decision.
public actor AgentLoop {
    private let registry: AgentToolRegistry
    private let proxy: AgentProxyClient
    private let maxTurns: Int
    private var pending: [String: CheckedContinuation<Bool, Never>] = [:]

    public init(registry: AgentToolRegistry, proxy: AgentProxyClient, maxTurns: Int = 8) {
        self.registry = registry
        self.proxy = proxy
        self.maxTurns = maxTurns
    }

    /// Convenience: build the loop with the live proxy dependency for a given tool registry.
    public init(registry: AgentToolRegistry, maxTurns: Int = 8) {
        @Dependency(\.agentProxy) var proxy
        self.init(registry: registry, proxy: proxy, maxTurns: maxTurns)
    }

    /// Run one utterance against `systemPrompt`, streaming `AgentLoopEvent`s. The stream finishes on
    /// `.finished`/`.failed` (or when the consumer cancels).
    public nonisolated func run(utterance: String, systemPrompt: String) -> AsyncStream<AgentLoopEvent> {
        AsyncStream { continuation in
            let task = Task {
                await self.drive(utterance: utterance, systemPrompt: systemPrompt) { continuation.yield($0) }
                continuation.finish()
            }
            continuation.onTermination = { _ in
                task.cancel()
                Task { await self.cancelPending() }
            }
        }
    }

    /// Resume a paused confirmation. `approved == true` executes the tool; `false` injects a
    /// "user declined" tool_result and the loop continues.
    public func resume(id: String, approved: Bool) {
        if let c = pending.removeValue(forKey: id) { c.resume(returning: approved) }
    }

    private func cancelPending() {
        for (_, c) in pending { c.resume(returning: false) }
        pending.removeAll()
    }

    private func drive(
        utterance: String,
        systemPrompt: String,
        emit: @Sendable @escaping (AgentLoopEvent) -> Void
    ) async {
        var messages: [AgentMessage] = [.user(utterance)]
        let tools = registry.definitions()
        var finalText = ""

        do {
            for _ in 0..<maxTurns {
                let response = try await proxy.turn(systemPrompt, messages, tools)
                messages.append(AgentMessage(role: "assistant", content: response.content))

                // Surface assistant text as it arrives; remember the latest as the running summary.
                var turnText = ""
                for block in response.content {
                    if case let .text(t) = block, !t.isEmpty {
                        emit(.assistantText(t))
                        turnText += (turnText.isEmpty ? "" : "\n") + t
                    }
                }
                if !turnText.isEmpty { finalText = turnText }

                let toolUses: [(id: String, name: String, input: [String: AgentValue])] = response.content.compactMap {
                    if case let .toolUse(id, name, input) = $0 { return (id, name, input) }
                    return nil
                }

                // No tools requested → this turn is the final answer.
                if toolUses.isEmpty {
                    emit(.finished(summary: finalText))
                    return
                }

                var results: [AgentContentBlock] = []
                for use in toolUses {
                    guard let tool = registry.tool(named: use.name) else {
                        results.append(.toolResult(toolUseID: use.id, content: "Unknown tool “\(use.name)”.", isError: true))
                        continue
                    }

                    if tool.needsConfirmation(for: use.input) {
                        emit(.confirmationNeeded(id: use.id, description: tool.confirmationPrompt ?? "Run \(tool.name)?"))
                        let approved = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
                            pending[use.id] = c
                        }
                        if !approved {
                            results.append(.toolResult(toolUseID: use.id, content: "The user declined to run \(use.name).", isError: false))
                            continue
                        }
                    }

                    emit(.toolStarted(name: use.name))
                    do {
                        let result = try await tool.execute(use.input)
                        if let receipt = result.receipt { emit(.receipt(receipt)) }
                        results.append(.toolResult(toolUseID: use.id, content: result.content, isError: false))
                    } catch {
                        // Tools shouldn't throw, but relay gracefully if one does.
                        results.append(.toolResult(toolUseID: use.id, content: "That tool hit an error: \(error.localizedDescription)", isError: true))
                    }
                }
                messages.append(AgentMessage(role: "user", content: results))
            }

            // Hit the turn cap while still wanting tools — wrap up gracefully.
            emit(.finished(summary: finalText.isEmpty ? "That took more steps than I expected — let's pause there." : finalText))
        } catch {
            emit(.failed(friendlyMessage: "Sorry — I couldn't reach the assistant just now."))
        }
    }
}
