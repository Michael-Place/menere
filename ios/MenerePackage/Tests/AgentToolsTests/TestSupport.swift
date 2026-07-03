import Dependencies
import HueClient
import LutronClient
import SonosClient
import NestClient
import HubspaceClient
import MerossClient
import HomeKitClient

@testable import AgentTools

extension DependencyValues {
    /// Register every fleet client with its preview value so `AgentToolRegistry.live` can capture
    /// them in a test context without tripping the live-dependency guard.
    mutating func stubAgentClients() {
        hue = .previewValue
        lutron = .previewValue
        sonos = .previewValue
        nest = .previewValue
        hubspace = .previewValue
        meross = .previewValue
        homekit = .previewValue
    }
}

/// Build the live registry inside a dependency scope where all clients (and a minimal persistence)
/// are overridden — for schema/inventory/gating tests that only inspect tools, never run them.
func withLiveRegistry<T>(_ body: (AgentToolRegistry) throws -> T) rethrows -> T {
    try withDependencies {
        $0.stubAgentClients()
        $0.persistence.members = { _ in [] }
    } operation: {
        try body(AgentToolRegistry.live(context: AgentContext(hid: "H1", uid: "u1", firstName: "Michael")))
    }
}
