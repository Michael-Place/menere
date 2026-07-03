import FamilyDomain
import Foundation
import Testing

@testable import AgentTools

/// Locks the shared fuzzy name-resolution rules the agent tools rely on: species aliases, exact-match
/// precedence, ambiguity, and helpful no-hit behavior.
struct FuzzyResolverTests {
    private let monty = CareItem(kind: .plant, name: "Monty", tasks: [], species: "Monstera")
    private let bigMonstera = CareItem(kind: .plant, name: "Big Monstera", tasks: [], species: "Monstera")
    private let fern = CareItem(kind: .plant, name: "Fernando", tasks: [], species: "Boston Fern")

    private func aliases(_ i: CareItem) -> [String] { [i.species, i.speciesLatin].compactMap { $0 } }

    @Test func speciesAliasMatch() {
        // "the monstera" should resolve to Monty via its species alias.
        let items = [monty, fern]
        let result = Fuzzy.resolve("the monstera", in: items, name: { $0.name }, aliases: aliases)
        guard case let .matched(hit) = result else { Issue.record("expected a match, got \(result)"); return }
        #expect(hit.name == "Monty")
    }

    @Test func caseAndDiacriticInsensitive() {
        let items = [CareItem(kind: .plant, name: "Café", tasks: [])]
        guard case let .matched(hit) = Fuzzy.resolve("cafe", in: items, name: { $0.name }) else {
            Issue.record("expected a diacritic-insensitive match"); return
        }
        #expect(hit.name == "Café")
    }

    @Test func ambiguityWhenTwoMatch() {
        // Both "Monty" (species Monstera) and "Big Monstera" (name) match "monstera".
        let items = [monty, bigMonstera, fern]
        let result = Fuzzy.resolve("monstera", in: items, name: { $0.name }, aliases: aliases)
        guard case let .ambiguous(hits) = result else { Issue.record("expected ambiguous, got \(result)"); return }
        #expect(Set(hits.map(\.name)) == ["Monty", "Big Monstera"])
        let line = Fuzzy.disambiguation(hits.map(\.name))
        #expect(line.contains("Monty"))
        #expect(line.contains("Big Monstera"))
        #expect(line.contains("which one"))
    }

    @Test func exactMatchWinsOverPartial() {
        // "Monty" exact beats "Monty's Big Pot" partial.
        let items = [monty, CareItem(kind: .plant, name: "Monty's Big Pot", tasks: [])]
        guard case let .matched(hit) = Fuzzy.resolve("monty", in: items, name: { $0.name }) else {
            Issue.record("expected exact match to win"); return
        }
        #expect(hit.name == "Monty")
    }

    @Test func noHitListsAvailable() {
        let items = [monty, fern]
        let result = Fuzzy.resolve("ficus", in: items, name: { $0.name }, aliases: aliases)
        guard case .none = result else { Issue.record("expected no match, got \(result)"); return }
        let line = Fuzzy.noMatch("ficus", available: items.map(\.name))
        #expect(line.contains("Monty"))
        #expect(line.contains("Fernando"))
        #expect(line.contains("ficus"))
    }

    @Test func emptyQueryIsNoMatch() {
        guard case .none = Fuzzy.resolve("  ", in: [monty], name: { $0.name }) else {
            Issue.record("blank query should not match"); return
        }
    }
}
