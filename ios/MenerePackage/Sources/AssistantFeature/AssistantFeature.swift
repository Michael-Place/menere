import AgentTools
import ComposableArchitecture
import FamilyDomain
import Foundation
import PersistenceClient
import UserDomain

/// One rendered turn in the assistant conversation. Streaming assistant text is appended into the
/// trailing `.assistant` bubble; tool receipts cluster into `.receipts`; a transient `.toolActivity`
/// shows the "using …" line while a tool runs (and is removed the moment the next event lands).
public struct ChatMessage: Equatable, Identifiable {
    public let id: UUID
    public var kind: Kind

    public enum Kind: Equatable {
        case user(String)
        case assistant(String)
        case receipts([AgentReceipt])
        case toolActivity(String)   // tool name — rendered as a friendly "using …" line
        case error(String)
    }

    public init(id: UUID = UUID(), kind: Kind) {
        self.id = id
        self.kind = kind
    }
}

/// Holds the live `AgentLoop` actor so a later `confirmationResponded` can resume it, while keeping
/// `State` `Equatable` (loop identity is irrelevant to view equality).
public struct LoopBox: Equatable, @unchecked Sendable {
    var loop: AgentLoop?
    public static func == (lhs: LoopBox, rhs: LoopBox) -> Bool { true }
    public init(_ loop: AgentLoop? = nil) { self.loop = loop }
}

/// A pending confirmation gate surfaced by the loop (garage open / lock unlock). While set, the input
/// bar is disabled and an inline confirmation card is shown in the conversation.
public struct PendingConfirmation: Equatable, Sendable {
    public var id: String
    public var description: String
}

/// The assistant chat feature (P14-C2): a warm, family-voice sheet over the on-phone `AgentLoop`.
/// It streams the loop's events into chat bubbles + action-chip receipts, gates security actions
/// behind an inline confirmation card, and relays graceful failures. No agent-core logic lives here
/// — this is pure presentation over `AgentTools`.
@Reducer
public struct AssistantReducer {
    @ObservableState
    public struct State: Equatable {
        public var messages: [ChatMessage] = []
        public var input: String = ""
        public var isThinking = false
        public var pendingConfirmation: PendingConfirmation?
        /// The acting member's first name — greets the empty state and personalizes the system prompt.
        public var firstName: String?
        /// Family member identities (display name + optional real name), fed to the system prompt.
        public var members: [MemberIdentity] = []
        /// The in-flight loop, so a confirmation decision can resume it.
        var loopBox = LoopBox()

        public init() {}

        /// Send is available only with text and no turn/confirmation in flight.
        var canSend: Bool {
            !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !isThinking && pendingConfirmation == nil
        }
    }

    public enum Action: Equatable, BindableAction {
        case task
        case rosterLoaded(firstName: String?, members: [MemberIdentity])
        case examplePromptTapped(String)
        case sendTapped
        case streamEvent(AgentLoopEvent)
        case confirmationResponded(Bool)
        case newChatTapped
        case dismissTapped
        case binding(BindingAction<State>)
    }

    public init() {}

    private enum CancelID { case stream }

    private func ctx() -> (hid: String, uid: String)? {
        @Shared(.user) var user
        guard let hid = user?.householdId, let uid = user?.id else { return nil }
        return (hid, uid)
    }

    public var body: some ReducerOf<Self> {
        BindingReducer()
        Reduce { state, action in
            switch action {
            case .task:
                // Load the roster once so the greeting + system prompt have names. Best-effort.
                guard let (hid, _) = ctx() else { return .none }
                return .run { send in
                    @Dependency(\.persistence) var persistence
                    let members = (try? await persistence.members(hid)) ?? []
                    @Shared(.user) var user
                    let full = (user?.id).flatMap { members.member(forUID: $0) }?.name ?? user?.displayName
                    let first = full?.split(whereSeparator: { $0.isWhitespace }).first.map(String.init)
                    await send(.rosterLoaded(
                        firstName: (first?.isEmpty == false) ? first : nil,
                        members: members.map { MemberIdentity(name: $0.name, fullName: $0.fullName) }
                    ))
                }

            case let .rosterLoaded(firstName, members):
                state.firstName = firstName
                state.members = members
                return .none

            case let .examplePromptTapped(text):
                // Prefill the composer (do NOT auto-send) so the user can tweak it.
                state.input = text
                return .none

            case .sendTapped:
                let text = state.input.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty, !state.isThinking, state.pendingConfirmation == nil,
                      let (hid, uid) = ctx() else { return .none }

                state.messages.append(ChatMessage(kind: .user(text)))
                state.input = ""
                state.isThinking = true

                // Reuse the SESSION's loop so its retained transcript carries context across turns
                // ("water the monstera" → "when's it due again?"). Only build a fresh loop when there
                // isn't one yet (first turn, or after New chat). Built in the reducer body because the
                // dependency context is active here, so `confirmationResponded` can resume the actor.
                let loop: AgentLoop
                if let existing = state.loopBox.loop {
                    loop = existing
                } else {
                    let context = AgentContext(hid: hid, uid: uid, firstName: state.firstName)
                    let registry = AgentToolRegistry.live(context: context)
                    loop = AgentLoop(registry: registry)
                    state.loopBox = LoopBox(loop)
                }

                let firstName = state.firstName
                let members = state.members
                return .run { send in
                    // Ground the model with a live snapshot each turn (cheap, best-effort) so "today"
                    // stays fresh even as the conversation grows.
                    let snapshot = await loop.todaySnapshot()
                    let prompt = AgentSystemPrompt.build(
                        firstName: firstName,
                        members: members,
                        todaySnapshot: snapshot
                    )
                    for await event in loop.run(utterance: text, systemPrompt: prompt) {
                        await send(.streamEvent(event))
                    }
                }
                .cancellable(id: CancelID.stream, cancelInFlight: true)

            case let .streamEvent(event):
                apply(event, to: &state)
                return .none

            case let .confirmationResponded(approved):
                guard let pending = state.pendingConfirmation else { return .none }
                state.pendingConfirmation = nil
                // Resume the paused loop; it keeps emitting into the still-open stream effect.
                let loop = state.loopBox.loop
                return .run { _ in
                    await loop?.resume(id: pending.id, approved: approved)
                }

            case .newChatTapped:
                // Start a fresh conversation: clear the transcript + the session loop (its retained
                // history goes with it), cancel anything in flight, and drop any confirmation gate.
                let loop = state.loopBox.loop
                state.messages.removeAll()
                state.input = ""
                state.isThinking = false
                state.pendingConfirmation = nil
                state.loopBox = LoopBox()
                return .merge(
                    .cancel(id: CancelID.stream),
                    .run { _ in await loop?.reset() }
                )

            case .dismissTapped:
                // Parent owns the presentation flag; just stop any in-flight loop.
                return .cancel(id: CancelID.stream)

            case .binding:
                return .none
            }
        }
    }

    /// Fold one loop event into the transcript.
    private func apply(_ event: AgentLoopEvent, to state: inout State) {
        switch event {
        case let .assistantText(text):
            let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty else { return }
            removeTransientActivity(&state)
            // Append into the trailing assistant bubble if it's the last thing shown; else open one.
            if case let .assistant(existing) = state.messages.last?.kind {
                state.messages[state.messages.count - 1].kind = .assistant(existing + "\n\n" + clean)
            } else {
                state.messages.append(ChatMessage(kind: .assistant(clean)))
            }

        case let .toolStarted(name):
            removeTransientActivity(&state)
            state.messages.append(ChatMessage(kind: .toolActivity(name)))

        case let .receipt(receipt):
            removeTransientActivity(&state)
            // Cluster consecutive receipts into a single chip row.
            if case let .receipts(existing) = state.messages.last?.kind {
                state.messages[state.messages.count - 1].kind = .receipts(existing + [receipt])
            } else {
                state.messages.append(ChatMessage(kind: .receipts([receipt])))
            }

        case let .confirmationNeeded(id, description):
            removeTransientActivity(&state)
            state.pendingConfirmation = PendingConfirmation(id: id, description: description)

        case let .finished(summary):
            removeTransientActivity(&state)
            state.isThinking = false
            // Only surface the summary if nothing was said this turn (avoids duplicating text).
            let clean = summary.trimmingCharacters(in: .whitespacesAndNewlines)
            let hasAssistantText = state.messages.contains { if case .assistant = $0.kind { return true }; return false }
            if !clean.isEmpty, !hasAssistantText {
                state.messages.append(ChatMessage(kind: .assistant(clean)))
            }

        case let .failed(message):
            removeTransientActivity(&state)
            state.isThinking = false
            state.pendingConfirmation = nil
            state.messages.append(ChatMessage(kind: .error(message)))
        }
    }

    private func removeTransientActivity(_ state: inout State) {
        if case .toolActivity = state.messages.last?.kind {
            state.messages.removeLast()
        }
    }
}

// MARK: - Friendly tool labels

public enum AssistantToolLabels {
    /// A warm, present-tense "using …" line for a tool name (falls back to a humanized name).
    public static func activity(for tool: String) -> String {
        switch tool {
        case "get_today_snapshot": return "Checking today…"
        case "query_calendar": return "Checking the calendar…"
        case "search_brain": return "Searching the family brain…"
        case "get_meal_plan": return "Checking the meal plan…"
        case "get_lists", "get_list_items": return "Checking the lists…"
        case "add_to_list": return "Adding to the list…"
        case "check_off_list_item": return "Checking that off…"
        case "add_event": return "Adding to the calendar…"
        case "set_dinner": return "Setting dinner…"
        case "complete_chore": return "Marking the chore done…"
        case "mark_care_done": return "Marking care done…"
        case "get_care_due": return "Checking home care…"
        case "get_house_status": return "Checking the house…"
        case "set_room_lights": return "Adjusting the lights…"
        case "recall_ritual": return "Setting the scene…"
        case "set_shade": return "Adjusting the shades…"
        case "set_thermostat": return "Adjusting the thermostat…"
        case "set_spigot": return "Working the spigot…"
        case "sonos": return "Cueing up music…"
        case "garage": return "Working the garage…"
        case "homekit_lock": return "Working the lock…"
        case "get_money_month", "log_expense": return "Checking the books…"
        default:
            let humanized = tool.replacingOccurrences(of: "_", with: " ")
            return "Working on it (\(humanized))…"
        }
    }
}
