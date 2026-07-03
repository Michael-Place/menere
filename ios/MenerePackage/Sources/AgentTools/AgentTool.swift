import Foundation

/// A human-facing receipt for a completed tool action — an SF Symbol + a one-line confirmation.
/// C2's UI renders these as action chips ("✓ Watered Monty", "💡 Downstairs dimmed").
public struct AgentReceipt: Sendable, Equatable {
    public let icon: String   // SF Symbol name
    public let line: String   // human confirmation, e.g. "✓ Watered Monty"
    public init(icon: String, line: String) {
        self.icon = icon
        self.line = line
    }
}

/// The result of running a tool: `content` is model-facing (compact JSON/text the loop feeds back as
/// a `tool_result`); `receipt` is the optional human chip. Tools NEVER surface errors as throws —
/// failures come back as `content` explaining what went wrong so the model can relay gracefully.
public struct AgentToolResult: Sendable, Equatable {
    public let content: String
    public let receipt: AgentReceipt?
    public init(content: String, receipt: AgentReceipt? = nil) {
        self.content = content
        self.receipt = receipt
    }
}

/// A tool the on-phone agent can call. Concrete tools capture their dependencies + the acting
/// household/member context at construction (see `AgentToolRegistry`).
public protocol AgentTool: Sendable {
    var name: String { get }
    var description: String { get }        // model-facing, concise
    var inputSchema: JSONSchema { get }
    /// When true the LOOP pauses and surfaces a confirmation request instead of executing; the
    /// action runs only on user approval (garage open, lock unlock).
    var requiresConfirmation: Bool { get }
    /// Optional human prompt shown at the confirmation gate (C2's UI). Defaults to the tool name.
    var confirmationPrompt: String? { get }
    /// Whether THIS specific call needs confirmation. Defaults to `requiresConfirmation`, but tools
    /// can refine it per-input — e.g. garage OPEN pauses while CLOSE runs straight through.
    func needsConfirmation(for input: [String: AgentValue]) -> Bool
    func execute(_ input: [String: AgentValue]) async throws -> AgentToolResult
}

public extension AgentTool {
    var requiresConfirmation: Bool { false }
    var confirmationPrompt: String? { nil }
    func needsConfirmation(for input: [String: AgentValue]) -> Bool { requiresConfirmation }

    /// The Anthropic tool definition (`{ name, description, input_schema }`) as an `AgentValue`.
    var definition: AgentValue {
        .object([
            "name": .string(name),
            "description": .string(description),
            "input_schema": inputSchema.jsonValue,
        ])
    }
}

/// A closure-backed concrete `AgentTool`, so the registry can assemble the whole curated set from
/// captured dependencies without one struct per verb.
public struct BasicAgentTool: AgentTool {
    public let name: String
    public let description: String
    public let inputSchema: JSONSchema
    public let requiresConfirmation: Bool
    public let confirmationPrompt: String?
    /// Optional per-input refinement of `requiresConfirmation` (e.g. only when `action == "open"`).
    private let confirmationGate: (@Sendable ([String: AgentValue]) -> Bool)?
    private let run: @Sendable ([String: AgentValue]) async throws -> AgentToolResult

    public init(
        name: String,
        description: String,
        inputSchema: JSONSchema,
        requiresConfirmation: Bool = false,
        confirmationPrompt: String? = nil,
        confirmationGate: (@Sendable ([String: AgentValue]) -> Bool)? = nil,
        run: @escaping @Sendable ([String: AgentValue]) async throws -> AgentToolResult
    ) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
        self.requiresConfirmation = requiresConfirmation
        self.confirmationPrompt = confirmationPrompt
        self.confirmationGate = confirmationGate
        self.run = run
    }

    public func needsConfirmation(for input: [String: AgentValue]) -> Bool {
        guard requiresConfirmation else { return false }
        return confirmationGate?(input) ?? true
    }

    public func execute(_ input: [String: AgentValue]) async throws -> AgentToolResult {
        try await run(input)
    }
}

// MARK: - Conversation model (the loop's running transcript + proxy wire shapes)

/// A content block in the agent conversation.
public enum AgentContentBlock: Sendable, Equatable {
    case text(String)
    case toolUse(id: String, name: String, input: [String: AgentValue])
    case toolResult(toolUseID: String, content: String, isError: Bool)

    /// Foundation wire shape for the callable payload.
    public var wire: [String: Any] {
        switch self {
        case let .text(s):
            return ["type": "text", "text": s]
        case let .toolUse(id, name, input):
            return ["type": "tool_use", "id": id, "name": name, "input": input.mapValues(\.anyValue)]
        case let .toolResult(toolUseID, content, isError):
            return ["type": "tool_result", "tool_use_id": toolUseID, "content": content, "is_error": isError]
        }
    }

    /// Parse an assistant content block from a callable response element.
    static func parse(_ raw: [String: Any]) -> AgentContentBlock? {
        switch raw["type"] as? String {
        case "text":
            return .text(raw["text"] as? String ?? "")
        case "tool_use":
            let id = raw["id"] as? String ?? UUID().uuidString
            let name = raw["name"] as? String ?? ""
            let input: [String: AgentValue]
            if let obj = raw["input"] as? [String: Any] {
                input = obj.mapValues { AgentValue(any: $0) }
            } else {
                input = [:]
            }
            return .toolUse(id: id, name: name, input: input)
        default:
            return nil
        }
    }
}

/// A single conversation turn (user or assistant).
public struct AgentMessage: Sendable, Equatable {
    public var role: String   // "user" | "assistant"
    public var content: [AgentContentBlock]
    public init(role: String, content: [AgentContentBlock]) {
        self.role = role
        self.content = content
    }
    public static func user(_ text: String) -> AgentMessage { .init(role: "user", content: [.text(text)]) }
    public var wire: [String: Any] { ["role": role, "content": content.map(\.wire)] }
}

/// The dumb proxy's response: the raw assistant content blocks + stop reason.
public struct AgentTurnResponse: Sendable, Equatable {
    public var content: [AgentContentBlock]
    public var stopReason: String?
    public init(content: [AgentContentBlock], stopReason: String?) {
        self.content = content
        self.stopReason = stopReason
    }
}

/// A tool definition forwarded to the proxy.
public struct AgentToolDefinition: Sendable, Equatable {
    public let name: String
    public let description: String
    public let inputSchema: JSONSchema
    public init(name: String, description: String, inputSchema: JSONSchema) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
    }
    public var wire: [String: Any] {
        ["name": name, "description": description, "input_schema": inputSchema.anyValue]
    }
}
