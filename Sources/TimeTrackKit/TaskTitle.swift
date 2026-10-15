import Foundation

// A task's display title split into its JIRA-style key and the human
// description (issue #71).
//
// Why this exists: users type "KDAL-1234 - Paginate accounts API" into the
// new-task field. Storing that whole string as `name` leaves `code` nil, so the
// picker's dedup-by-code (DESIGN.md "Task sources", "JIRA key wins") never sees
// the key. Splitting at capture time puts the key in `code` where it belongs.
//
// INVARIANT: a parsed key is only a *capture-side* hint. It never makes time
// reportable — that still requires an explicit reconcile_bind to a Known Task
// (CLAUDE.md invariant 4). `code` on a Task is not a binding.
//
// Parsing is deliberately hand-rolled (no regex) so behaviour is identical on
// Darwin and Linux Foundation and is easy to read in six months.
public struct TaskTitle: Equatable, Sendable {
    public let key: String?        // JIRA-style key, uppercased; nil when none
    public let description: String // remainder, trimmed

    public init(key: String?, description: String) {
        self.key = key
        self.description = description
    }

    // Accepts "<KEY><sep><description>" where KEY is
    // [A-Za-z][A-Za-z0-9]*-[0-9]+ anchored at the start of the trimmed input,
    // and <sep> is optional whitespace, at most one of - : – —, then optional
    // whitespace — with at least one separator character present. The key must
    // be followed by a separator so "KDAL-1234abc" is NOT a key, and must be
    // followed by a non-empty description so a bare "KDAL-1234" stays a plain
    // name (we never fabricate an empty description).
    //
    // Anything that doesn't match returns key nil and the trimmed input
    // unchanged — parse is total and never loses user text.
    public static func parse(_ input: String) -> TaskTitle {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let unchanged = TaskTitle(key: nil, description: trimmed)
        let chars = Array(trimmed)
        var i = 0

        // Project part: ASCII letter, then ASCII letters/digits.
        guard i < chars.count, isASCIILetter(chars[i]) else { return unchanged }
        i += 1
        while i < chars.count, isASCIILetter(chars[i]) || isASCIIDigit(chars[i]) {
            i += 1
        }

        // Hyphen, then at least one digit.
        guard i < chars.count, chars[i] == "-" else { return unchanged }
        i += 1
        let digitsStart = i
        while i < chars.count, isASCIIDigit(chars[i]) {
            i += 1
        }
        guard i > digitsStart else { return unchanged }
        let keyEnd = i

        // Separator: optional whitespace, at most one punctuation separator,
        // optional whitespace. Must consume at least one character.
        while i < chars.count, chars[i].isWhitespace { i += 1 }
        if i < chars.count, separatorPunctuation.contains(chars[i]) { i += 1 }
        while i < chars.count, chars[i].isWhitespace { i += 1 }
        guard i > keyEnd else { return unchanged }

        let remainder = String(chars[i...]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !remainder.isEmpty else { return unchanged }

        let key = String(chars[0..<keyEnd]).uppercased()
        return TaskTitle(key: key, description: remainder)
    }

    // "-" and ":" are what people type; en/em dashes arrive via macOS smart
    // punctuation or pasted JIRA titles.
    private static let separatorPunctuation: Set<Character> = ["-", ":", "\u{2013}", "\u{2014}"]

    // ASCII-only on purpose: JIRA project keys are ASCII, and Character.isLetter
    // alone would accept e.g. "É" and fabricate keys from ordinary prose.
    private static func isASCIILetter(_ c: Character) -> Bool {
        c.isASCII && c.isLetter
    }

    private static func isASCIIDigit(_ c: Character) -> Bool {
        c.isASCII && c.isNumber
    }
}

extension Task {
    // Display title. A stored `code` is authoritative. Rows without one fall
    // back to a display-only parse of `name`: legacy ad-hoc rows created before
    // #71 embed the key in the name, and rewriting them in the DB would be a
    // silent mutation of history, so we only reinterpret them for display.
    public var title: TaskTitle {
        if let code = code, !code.isEmpty {
            return TaskTitle(key: code, description: name)
        }
        return TaskTitle.parse(name)
    }
}
