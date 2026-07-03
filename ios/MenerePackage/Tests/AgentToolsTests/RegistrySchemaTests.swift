import Dependencies
import Foundation
import Testing

@testable import AgentTools

/// Locks the curated tool set: every tool's schema encodes to a valid JSON Schema, the full
/// inventory is present, and the confirmation-gated tools gate on the right action.
struct RegistrySchemaTests {
    private static let expectedTools: Set<String> = [
        // queries
        "get_today_snapshot", "query_calendar", "search_brain", "get_meal_plan", "get_lists",
        "get_list_items", "get_house_status", "get_money_month", "get_care_due",
        // family actions
        "add_event", "add_to_list", "check_off_list_item", "complete_chore", "mark_care_done",
        "log_expense", "set_dinner",
        // house actions
        "set_room_lights", "recall_ritual", "set_shade", "sonos", "set_thermostat", "set_spigot",
        "garage", "homekit_lock",
    ]

    @Test func fullInventoryPresent() {
        withLiveRegistry { reg in
            #expect(Set(reg.tools.map(\.name)) == Self.expectedTools)
        }
    }

    @Test func everyToolHasValidJSONSchema() throws {
        try withLiveRegistry { reg in
            for tool in reg.tools {
                let jsonString = tool.inputSchema.jsonValue.jsonString
                let data = Data(jsonString.utf8)
                let obj = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any], "\(tool.name): schema is not a JSON object")
                #expect(obj["type"] as? String == "object", "\(tool.name): root type must be object")
                let props = try #require(obj["properties"] as? [String: Any], "\(tool.name): missing properties")
                // Every declared property is itself a typed schema.
                for (key, value) in props {
                    let prop = try #require(value as? [String: Any], "\(tool.name).\(key): property is not an object")
                    #expect(prop["type"] as? String != nil, "\(tool.name).\(key): property missing type")
                }
                // Required is a subset of the declared properties.
                if let required = obj["required"] as? [String] {
                    #expect(required.allSatisfy { props[$0] != nil }, "\(tool.name): required references an undeclared property")
                }
            }
        }
    }

    @Test func definitionsMirrorTools() {
        withLiveRegistry { reg in
            #expect(Set(reg.definitions().map(\.name)) == Set(reg.tools.map(\.name)))
        }
    }

    @Test func garageOpenGatesButCloseDoesNot() throws {
        try withLiveRegistry { reg in
            let garage = try #require(reg.tool(named: "garage"))
            #expect(garage.requiresConfirmation)
            #expect(garage.needsConfirmation(for: ["action": .string("open")]))
            #expect(!garage.needsConfirmation(for: ["action": .string("close")]))
        }
    }

    @Test func lockUnlockGatesButLockDoesNot() throws {
        try withLiveRegistry { reg in
            let lock = try #require(reg.tool(named: "homekit_lock"))
            #expect(lock.requiresConfirmation)
            #expect(lock.needsConfirmation(for: ["action": .string("unlock"), "name": .string("Front")]))
            #expect(!lock.needsConfirmation(for: ["action": .string("lock"), "name": .string("Front")]))
        }
    }

    @Test func nonGatedToolNeverConfirms() throws {
        try withLiveRegistry { reg in
            let addEvent = try #require(reg.tool(named: "add_event"))
            #expect(!addEvent.requiresConfirmation)
            #expect(!addEvent.needsConfirmation(for: [:]))
        }
    }
}
