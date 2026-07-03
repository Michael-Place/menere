import Foundation
import Dependencies
import FamilyDomain
import PersistenceClient
import HueClient
import LutronClient
import SonosClient
import NestClient
import HubspaceClient
import MerossClient
import HomeKitClient

/// The signed-in member acting through the agent. `uid` is the actor for activity/XP credit.
public struct AgentContext: Sendable, Equatable {
    public var hid: String
    public var uid: String
    public var firstName: String?
    public init(hid: String, uid: String, firstName: String? = nil) {
        self.hid = hid
        self.uid = uid
        self.firstName = firstName
    }
}

/// The clients the tools wrap, captured once at registry-build time.
struct AgentDeps: Sendable {
    let persistence: PersistenceClient
    let hue: HueClient
    let lutron: LutronClient
    let sonos: SonosClient
    let nest: NestClient
    let hubspace: HubspaceClient
    let meross: MerossClient
    let homekit: HomeKitClient
}

/// The "MCP-type interface": the curated set of tools the on-phone agent can call, assembled from
/// injected dependencies. Future devices join by adding a tool here.
public struct AgentToolRegistry: Sendable {
    public let tools: [any AgentTool]
    private let byName: [String: any AgentTool]

    public init(tools: [any AgentTool]) {
        self.tools = tools
        self.byName = Dictionary(tools.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
    }

    public func tool(named name: String) -> (any AgentTool)? { byName[name] }

    /// Definitions forwarded to the proxy on every turn.
    public func definitions() -> [AgentToolDefinition] {
        tools.map { AgentToolDefinition(name: $0.name, description: $0.description, inputSchema: $0.inputSchema) }
    }

    /// Build the live registry for `context`, reading every client via `@Dependency` (so tests mock
    /// all of them). Call inside a `withDependencies { … }` scope or a reducer.
    public static func live(context: AgentContext) -> AgentToolRegistry {
        @Dependency(\.persistence) var persistence
        @Dependency(\.hue) var hue
        @Dependency(\.lutron) var lutron
        @Dependency(\.sonos) var sonos
        @Dependency(\.nest) var nest
        @Dependency(\.hubspace) var hubspace
        @Dependency(\.meross) var meross
        @Dependency(\.homekit) var homekit
        let deps = AgentDeps(
            persistence: persistence, hue: hue, lutron: lutron, sonos: sonos,
            nest: nest, hubspace: hubspace, meross: meross, homekit: homekit
        )
        var tools: [any AgentTool] = []
        tools += queryTools(context, deps)
        tools += familyTools(context, deps)
        tools += houseTools(context, deps)
        return AgentToolRegistry(tools: tools)
    }
}

// MARK: - Shared helpers for tool bodies

enum AgentJSON {
    /// Compact model-facing JSON string from an object.
    static func object(_ dict: [String: AgentValue]) -> String { AgentValue.object(dict).jsonString }
    static func array(_ items: [AgentValue]) -> String { AgentValue.array(items).jsonString }
    static func string(_ s: String) -> AgentValue { .string(s) }
    static func int(_ i: Int) -> AgentValue { .int(i) }
    static func double(_ d: Double) -> AgentValue { .double(d) }
    static func bool(_ b: Bool) -> AgentValue { .bool(b) }
}

enum AgentDates {
    private static let full: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
    private static let fullFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let dateOnly: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// Parse a full ISO-8601 timestamp or a bare `yyyy-MM-dd` date.
    static func parse(_ s: String) -> Date? {
        if let d = full.date(from: s) { return d }
        if let d = fullFractional.date(from: s) { return d }
        return dateOnly.date(from: s)
    }

    static func iso(_ d: Date) -> String { full.string(from: d) }

    static func human(_ d: Date, allDay: Bool) -> String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = allDay ? .none : .short
        return f.string(from: d)
    }

    static var timeZoneID: String { TimeZone.current.identifier }
}
