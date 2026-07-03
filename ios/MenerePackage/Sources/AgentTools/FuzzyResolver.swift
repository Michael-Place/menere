import Foundation

/// Shared case/diacritic-insensitive name resolution for the agent tools. Matches a user-spoken
/// name against a set of live entities by their display name PLUS aliases (species, area, etc.).
///
/// - An exact (normalized) hit on name-or-alias wins outright.
/// - Otherwise a bidirectional "contains" match ("the monstera" ↔ alias "Monstera").
/// - 2+ distinct entities matching → `.ambiguous` (the tool asks which one).
/// - No entity matching → `.none` (the tool lists the near/available options).
public enum FuzzyMatch<Element> {
    case matched(Element)
    case ambiguous([Element])
    case none
}

public enum Fuzzy {
    /// Normalize for comparison: fold case + diacritics, collapse whitespace, trim.
    public static func normalize(_ s: String) -> String {
        let folded = s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        return folded
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// Resolve `query` against `items`, comparing its name plus optional aliases.
    public static func resolve<Element>(
        _ query: String,
        in items: [Element],
        name: (Element) -> String,
        aliases: (Element) -> [String] = { _ in [] }
    ) -> FuzzyMatch<Element> {
        let q = normalize(query)
        guard !q.isEmpty else { return .none }

        // 1. Exact matches on name or any alias.
        let exact = items.filter { el in
            let terms = ([name(el)] + aliases(el)).map(normalize)
            return terms.contains(q)
        }
        if exact.count == 1 { return .matched(exact[0]) }
        if exact.count > 1 { return .ambiguous(exact) }

        // 2. Bidirectional contains on name or any alias.
        let partial = items.filter { el in
            let terms = ([name(el)] + aliases(el)).map(normalize).filter { !$0.isEmpty }
            return terms.contains { term in term.contains(q) || q.contains(term) }
        }
        switch partial.count {
        case 0: return .none
        case 1: return .matched(partial[0])
        default: return .ambiguous(partial)
        }
    }

    /// A model-facing disambiguation line: "Found Monty and Big Monstera — which one?"
    public static func disambiguation(_ names: [String]) -> String {
        let list: String
        switch names.count {
        case 0: return "Found several matches — which one?"
        case 1: return "Found \(names[0])."
        case 2: list = "\(names[0]) and \(names[1])"
        default: list = names.dropLast().joined(separator: ", ") + ", and " + names.last!
        }
        return "Found \(list) — which one?"
    }

    /// A model-facing no-hit line listing what IS available.
    public static func noMatch(_ query: String, available names: [String]) -> String {
        guard !names.isEmpty else { return "Couldn't find \"\(query)\", and nothing is set up yet." }
        return "Couldn't find \"\(query)\". Available: \(names.joined(separator: ", "))."
    }
}
