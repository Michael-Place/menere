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
    /// The most messages retained in `history` between turns; oldest whole exchanges are trimmed
    /// past this so a long session stays within a sensible window.
    private let maxHistoryMessages: Int
    private var pending: [String: CheckedContinuation<Bool, Never>] = [:]
    /// The running multi-turn transcript (user/assistant text + tool_use/tool_result blocks),
    /// RETAINED across `run(…)` calls so follow-ups resolve anaphora ("water the monstera" → "when's
    /// it due again?") and can reference what the loop just did. `reset()` clears it (New chat).
    private var history: [AgentMessage] = []

    public init(registry: AgentToolRegistry, proxy: AgentProxyClient, maxTurns: Int = 8, maxHistoryMessages: Int = 60) {
        self.registry = registry
        self.proxy = proxy
        self.maxTurns = maxTurns
        self.maxHistoryMessages = maxHistoryMessages
    }

    /// Convenience: build the loop with the live proxy dependency for a given tool registry.
    public init(registry: AgentToolRegistry, maxTurns: Int = 8, maxHistoryMessages: Int = 60) {
        @Dependency(\.agentProxy) var proxy
        self.init(registry: registry, proxy: proxy, maxTurns: maxTurns, maxHistoryMessages: maxHistoryMessages)
    }

    /// Clear the conversation (New chat) — drops the retained transcript and any pending confirmation.
    public func reset() {
        history.removeAll()
        cancelPending()
    }

    /// The messages retained so far (test/introspection hook).
    public var transcript: [AgentMessage] { history }

    /// Fetch the grounding "today" snapshot via the registry, for the per-turn system prompt. Kept on
    /// the loop so callers reusing an existing loop don't need to hold the registry.
    public func todaySnapshot() async -> String? {
        guard let tool = registry.tool(named: "get_today_snapshot") else { return nil }
        return try? await tool.execute([:]).content
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
        // Seed this turn from the RETAINED history so the model has the whole conversation. New user
        // utterances merge into a trailing user message (from a tool-capped prior turn) to preserve
        // user/assistant alternation.
        var messages = appendingUserUtterance(utterance, to: history)
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

                // No tools requested → this turn is the final answer. Persist the transcript so the
                // NEXT turn (a follow-up) sees everything said + done here.
                if toolUses.isEmpty {
                    history = trimmedHistory(messages)
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

            // Hit the turn cap while still wanting tools — wrap up gracefully, but keep the transcript
            // (it ends on a valid tool_result user turn) so a follow-up still has context.
            history = trimmedHistory(messages)
            emit(.finished(summary: finalText.isEmpty ? "That took more steps than I expected — let's pause there." : finalText))
        } catch {
            // The proxy call threw BEFORE any assistant turn was appended, so `messages` is still a
            // valid transcript (no dangling tool_use). Keep it so the user's question survives a
            // transient network blip and the next turn has the full thread.
            history = trimmedHistory(messages)
            emit(.failed(friendlyMessage: "Sorry — I couldn't reach the assistant just now."))
        }
    }

    /// Append a fresh user utterance, merging into a trailing user message when present (a prior
    /// tool-capped turn can leave history ending on a `tool_result` user message; two consecutive
    /// user turns would break alternation).
    private func appendingUserUtterance(_ text: String, to base: [AgentMessage]) -> [AgentMessage] {
        var messages = base
        if var last = messages.last, last.role == "user" {
            last.content.append(.text(text))
            messages[messages.count - 1] = last
        } else {
            messages.append(.user(text))
        }
        return messages
    }

    /// Trim the retained transcript to `maxHistoryMessages`, then drop leading messages until the
    /// first is a "clean" user turn (role user, no `tool_result` blocks) — so we never orphan a
    /// tool_result from its tool_use or start the thread on an assistant turn.
    private func trimmedHistory(_ messages: [AgentMessage]) -> [AgentMessage] {
        guard messages.count > maxHistoryMessages else { return messages }
        var window = Array(messages.suffix(maxHistoryMessages))
        while let first = window.first, !isCleanUserStart(first) {
            window.removeFirst()
        }
        return window
    }

    private func isCleanUserStart(_ message: AgentMessage) -> Bool {
        guard message.role == "user" else { return false }
        return !message.content.contains { if case .toolResult = $0 { return true } else { return false } }
    }
}
