import Foundation

/// A family member's identity for the assistant roster context: the everyday display `name`
/// (a nickname is fine — used in warm copy) plus the optional real/legal `fullName`.
public struct MemberIdentity: Equatable, Sendable {
    /// Everyday display name (may be a nickname, e.g. "Migueluh").
    public let name: String
    /// Real/legal name (e.g. "Michael"), if known.
    public let fullName: String?

    public init(name: String, fullName: String? = nil) {
        self.name = name
        self.fullName = fullName
    }

    /// Roster phrasing that teaches the model the identity, e.g. "Michael (goes by Migueluh)".
    /// Falls back to just the display name when there's no distinct real name.
    var rosterLabel: String {
        if let full = fullName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !full.isEmpty, full.caseInsensitiveCompare(name) != .orderedSame {
            return "\(full) (goes by \(name))"
        }
        return name
    }
}

/// Builds the agent's system prompt: warm family context, capabilities, the current date/time +
/// timezone, and (optionally) today's snapshot inline so the model starts grounded.
public enum AgentSystemPrompt {
    /// - Parameters:
    ///   - firstName: the acting member's first name ("you act on behalf of {firstName}").
    ///   - members: family member identities (display name + optional real name) for context.
    ///   - todaySnapshot: optional pre-rendered `get_today_snapshot`-style JSON to inline.
    ///   - now: injectable clock (defaults to `Date()`).
    public static func build(
        firstName: String?,
        members: [MemberIdentity],
        todaySnapshot: String? = nil,
        now: Date = Date()
    ) -> String {
        let df = DateFormatter()
        df.dateFormat = "EEEE, MMMM d, yyyy 'at' h:mm a"
        let when = df.string(from: now)
        let tz = TimeZone.current.identifier

        let family = members.isEmpty ? "the family" : members.map(\.rosterLabel).joined(separator: ", ")
        let actingLine = firstName.map { "You are acting on behalf of \($0)." } ?? "You are acting on behalf of the family."

        var prompt = """
        You are Bacán, the warm and quietly witty assistant inside the Place family's private app. \(actingLine)

        The family: \(family). The littlest one, Francis, is called "Famfis" (his own pronunciation). The dogs are Fajita and Sprinkle. Only mention Famfis or the dogs when the data actually names them.

        Voice:
        - Warm, natural, a little witty — never corporate, never gushing. Use first names. Sentence case. No emoji, at most one exclamation point.
        - Be brief. Answer the question, do the thing, confirm plainly. Don't narrate your steps.
        - Only state what the tools actually return. Never invent events, chores, prices, or device states.

        Acting:
        - You have tools for the family calendar, lists, chores, home care, the document "brain", money, and the smart home (lights, shades, sonos, thermostat, water spigots, garage, locks).
        - Use tools to answer questions and to take actions. Prefer get_today_snapshot for open-ended "what's going on" asks.
        - When a name is ambiguous or not found, a tool will say so — relay its question or options rather than guessing.
        - Opening the garage and unlocking a door will pause for the user's confirmation; that's expected.

        Right now it is \(when) (\(tz)).
        """

        if let todaySnapshot, !todaySnapshot.isEmpty {
            prompt += "\n\nToday at a glance:\n\(todaySnapshot)"
        }
        return prompt
    }
}
