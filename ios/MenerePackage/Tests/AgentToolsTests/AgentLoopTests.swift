import Dependencies
import FamilyDomain
import Foundation
import Testing

@testable import AgentTools

/// A scriptable stand-in for the `agentTurn` proxy: returns a fixed list of turns in order (clamping
/// to the last), while counting calls so we can assert the turn cap.
private actor ScriptedProxy {
    private let responses: [AgentTurnResponse]
    private(set) var calls = 0

    init(_ responses: [AgentTurnResponse]) { self.responses = responses }

    func next() -> AgentTurnResponse {
        let r = responses[min(calls, responses.count - 1)]
        calls += 1
        return r
    }

    nonisolated func client() -> AgentProxyClient {
        AgentProxyClient(turn: { _, _, _ in await self.next() })
    }
}

private func text(_ s: String, stop: String = "end_turn") -> AgentTurnResponse {
    AgentTurnResponse(content: [.text(s)], stopReason: stop)
}
private func toolUse(_ name: String, _ input: [String: AgentValue], id: String = "tu1") -> AgentTurnResponse {
    AgentTurnResponse(content: [.toolUse(id: id, name: name, input: input)], stopReason: "tool_use")
}

struct AgentLoopTests {
    private let ctx = AgentContext(hid: "H1", uid: "u1", firstName: "Michael")

    // MARK: full walk — mark_care_done → receipt → follow-up text → finished
    @Test func fullWalkMarkCareDone() async {
        let monty = CareItem(
            kind: .plant, name: "Monty",
            tasks: [CareTask(id: "t1", title: "Water", intervalDays: 7)],
            species: "Monstera"
        )
        let proxy = ScriptedProxy([
            toolUse("mark_care_done", ["itemName": .string("the monstera")]),
            text("Done — watered Monty."),
        ])

        var events: [AgentLoopEvent] = []
        await withDependencies {
            $0.stubAgentClients()
            $0.persistence.careItems = { _ in [monty] }
            $0.persistence.members = { _ in [HouseholdMember(id: "u1", name: "Michael")] }
            $0.persistence.saveCareItem = { _, _ in }
            $0.persistence.logActivity = { _, _ in }
        } operation: {
            let registry = AgentToolRegistry.live(context: ctx)
            let loop = AgentLoop(registry: registry, proxy: proxy.client())
            for await e in loop.run(utterance: "water the monstera", systemPrompt: "sys") {
                events.append(e)
            }
        }

        #expect(events.contains(.toolStarted(name: "mark_care_done")))
        let receipt = events.compactMap { if case let .receipt(r) = $0 { return r } else { return nil } }.first
        #expect(receipt?.line.contains("Monty") == true)
        #expect(events.contains(.assistantText("Done — watered Monty.")))
        #expect(events.last == .finished(summary: "Done — watered Monty."))
    }

    // MARK: confirmation pause → approve → executes
    @Test func confirmationApprovedExecutes() async {
        let danger = confirmingTool()
        let proxy = ScriptedProxy([
            toolUse("danger", ["action": .string("open")]),
            text("All set."),
        ])
        let loop = AgentLoop(registry: AgentToolRegistry(tools: [danger]), proxy: proxy.client())

        var events: [AgentLoopEvent] = []
        for await e in loop.run(utterance: "open it", systemPrompt: "sys") {
            events.append(e)
            if case let .confirmationNeeded(id, _) = e { await loop.resume(id: id, approved: true) }
        }

        #expect(events.contains { if case .confirmationNeeded = $0 { return true } else { return false } })
        #expect(events.contains(.toolStarted(name: "danger")))
        let receipt = events.compactMap { if case let .receipt(r) = $0 { return r } else { return nil } }.first
        #expect(receipt?.line == "did it")
        #expect(events.last == .finished(summary: "All set."))
    }

    // MARK: confirmation pause → deny → skips, injects "declined", continues
    @Test func confirmationDeniedSkips() async {
        let danger = confirmingTool()
        let proxy = ScriptedProxy([
            toolUse("danger", ["action": .string("open")]),
            text("Okay, left it alone."),
        ])
        let loop = AgentLoop(registry: AgentToolRegistry(tools: [danger]), proxy: proxy.client())

        var events: [AgentLoopEvent] = []
        for await e in loop.run(utterance: "open it", systemPrompt: "sys") {
            events.append(e)
            if case let .confirmationNeeded(id, _) = e { await loop.resume(id: id, approved: false) }
        }

        #expect(events.contains { if case .confirmationNeeded = $0 { return true } else { return false } })
        #expect(!events.contains(.toolStarted(name: "danger")))  // denied → never executed
        #expect(!events.contains { if case .receipt = $0 { return true } else { return false } })
        #expect(events.last == .finished(summary: "Okay, left it alone."))
    }

    // MARK: 8-turn cap
    @Test func eightTurnCap() async {
        let noop = BasicAgentTool(name: "noop", description: "no-op", inputSchema: .object([:])) { _ in
            AgentToolResult(content: "{}")
        }
        // Always asks for another tool call → never ends naturally.
        let proxy = ScriptedProxy([toolUse("noop", [:])])
        let loop = AgentLoop(registry: AgentToolRegistry(tools: [noop]), proxy: proxy.client())

        var events: [AgentLoopEvent] = []
        for await e in loop.run(utterance: "loop forever", systemPrompt: "sys") {
            events.append(e)
        }

        let calls = await proxy.calls
        #expect(calls == 8)  // capped at 8 model turns
        #expect(events.contains { if case .finished = $0 { return true } else { return false } })
    }

    // MARK: tool-failure relay — a throwing tool is caught and fed back so the model relays
    @Test func toolFailureRelay() async {
        struct Boom: Error {}
        let boom = BasicAgentTool(name: "boom", description: "always fails", inputSchema: .object([:])) { _ in
            throw Boom()
        }
        let proxy = ScriptedProxy([
            toolUse("boom", [:]),
            text("Sorry, that didn't work."),
        ])
        let loop = AgentLoop(registry: AgentToolRegistry(tools: [boom]), proxy: proxy.client())

        var events: [AgentLoopEvent] = []
        for await e in loop.run(utterance: "go", systemPrompt: "sys") {
            events.append(e)
        }

        #expect(events.contains(.toolStarted(name: "boom")))     // it tried
        #expect(!events.contains { if case .receipt = $0 { return true } else { return false } })
        #expect(events.last == .finished(summary: "Sorry, that didn't work."))  // model relayed after the failure
    }

    // MARK: proxy failure → friendly failed event
    @Test func proxyFailureIsFriendly() async {
        struct NetFail: Error {}
        let proxy = AgentProxyClient(turn: { _, _, _ in throw NetFail() })
        let loop = AgentLoop(registry: AgentToolRegistry(tools: []), proxy: proxy)

        var events: [AgentLoopEvent] = []
        for await e in loop.run(utterance: "hi", systemPrompt: "sys") {
            events.append(e)
        }
        #expect(events.count == 1)
        if case .failed = events.first { } else { Issue.record("expected a failed event, got \(events)") }
    }

    // A confirmation-gated tool that emits a receipt when it runs.
    private func confirmingTool() -> BasicAgentTool {
        BasicAgentTool(
            name: "danger",
            description: "confirmation-gated test tool",
            inputSchema: .object(["action": .string("open or close")], required: ["action"]),
            requiresConfirmation: true,
            confirmationPrompt: "Do the dangerous thing?",
            confirmationGate: { input in (input.string("action") ?? "") == "open" }
        ) { _ in
            AgentToolResult(content: "done", receipt: AgentReceipt(icon: "bolt", line: "did it"))
        }
    }
}
