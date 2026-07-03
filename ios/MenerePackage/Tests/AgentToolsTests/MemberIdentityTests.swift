import FamilyDomain
import Foundation
import Testing

@testable import AgentTools

/// P0.1 — real name + nickname support. Covers `HouseholdMember.fullName` decode-safety and the
/// assistant roster context that teaches the model both names (e.g. "Michael (goes by Migueluh)").
struct MemberIdentityTests {
    // MARK: HouseholdMember decode-safety

    @Test func decodesLegacyMemberWithoutFullName() throws {
        // A pre-P0.1 doc carrying only `name` must still decode, with fullName nil.
        let json = #"{"id":"u1","name":"Migueluh","color":"botanical"}"#.data(using: .utf8)!
        let member = try JSONDecoder().decode(HouseholdMember.self, from: json)
        #expect(member.name == "Migueluh")
        #expect(member.fullName == nil)
        #expect(member.color == .botanical)
    }

    @Test func decodesMemberWithFullName() throws {
        let json = #"{"id":"u1","name":"Migueluh","fullName":"Michael","color":"botanical"}"#
            .data(using: .utf8)!
        let member = try JSONDecoder().decode(HouseholdMember.self, from: json)
        #expect(member.name == "Migueluh")
        #expect(member.fullName == "Michael")
    }

    @Test func encodeRoundTripsFullName() throws {
        let original = HouseholdMember(id: "u1", name: "Migueluh", fullName: "Michael", color: .botanical)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(HouseholdMember.self, from: data)
        #expect(decoded == original)
        #expect(decoded.fullName == "Michael")
    }

    // MARK: MemberIdentity roster labels

    @Test func rosterLabelShowsBothNamesWhenDistinct() {
        let id = MemberIdentity(name: "Migueluh", fullName: "Michael")
        #expect(id.rosterLabel == "Michael (goes by Migueluh)")
    }

    @Test func rosterLabelFallsBackToDisplayNameWhenNoFullName() {
        #expect(MemberIdentity(name: "Oliver", fullName: nil).rosterLabel == "Oliver")
    }

    @Test func rosterLabelCollapsesWhenNamesMatch() {
        // Oliver's real name equals his display name — no redundant "(goes by …)".
        #expect(MemberIdentity(name: "Oliver", fullName: "Oliver").rosterLabel == "Oliver")
        #expect(MemberIdentity(name: "Oliver", fullName: "oliver").rosterLabel == "Oliver")
    }

    // MARK: System prompt wiring

    @Test func systemPromptIncludesRealAndNicknamePairs() {
        let prompt = AgentSystemPrompt.build(
            firstName: "Migueluh",
            members: [
                MemberIdentity(name: "Migueluh", fullName: "Michael"),
                MemberIdentity(name: "Vale", fullName: "Valentina"),
                MemberIdentity(name: "Oliver", fullName: "Oliver"),
            ]
        )
        #expect(prompt.contains("Michael (goes by Migueluh)"))
        #expect(prompt.contains("Valentina (goes by Vale)"))
        // Warm greeting still uses the display first name.
        #expect(prompt.contains("acting on behalf of Migueluh"))
    }
}
