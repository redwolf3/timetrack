import Foundation
import TimeTrackKit

// JSON + CSV codec for the `known_task` interchange record
// (docs/interchange-format.md §3, §4). Export and import share this so the two
// encodings — and the reader/writer for each — can never drift from each other
// or from `KnownTask` (Sources/TimeTrackKit/Store.swift).
//
// Decoding never produces a `KnownTask` directly: it produces
// `KnownTasksLoader.KnownTaskEntry`, the same intermediate representation the
// YAML loader uses, and hands off to `KnownTasksLoader.ingest(entries:...)` —
// the one upsert path (§4.2). `id`, `provisional`, `retired`, and `created` are
// all ignored on import per §4.1/§4.2; only `description` and `jira_key`
// survive into an entry.
public enum KnownTaskCodec {

    public enum Format {
        case json
        case csv
    }

    // MARK: - Errors

    public enum CodecError: Error, CustomStringConvertible {
        case unknownFormat(String)
        case unsupportedVersion(Int)
        case malformedJSON(String)
        case malformedCSV(String)
        case csvHeaderMismatch(expected: [String], found: [String])

        public var description: String {
            switch self {
            case .unknownFormat(let format):
                return "unknown format '\(format)' (expected '\(KnownTaskCodec.formatName)')"
            case .unsupportedVersion(let version):
                // Below 1 is malformed, not merely newer than us — saying "supports
                // up to N" there would imply a future build might accept it.
                guard version >= 1 else {
                    return "invalid version \(version) (versions start at 1)"
                }
                return "unsupported version \(version) (this build supports up to version \(KnownTaskCodec.supportedVersion))"
            case .malformedJSON(let msg):
                return "malformed JSON — \(msg)"
            case .malformedCSV(let msg):
                return "malformed CSV — \(msg)"
            case .csvHeaderMismatch(let expected, let found):
                return "CSV header mismatch — expected columns [\(expected.joined(separator: ","))], " +
                       "found [\(found.joined(separator: ","))]"
            }
        }
    }

    // MARK: - Envelope constants (§3.1)

    public static let formatName = "timetrack.known_task"
    public static let supportedVersion = 1
    public static let csvHeader = ["id", "jira_key", "description", "provisional", "retired", "created"]

    // MARK: - Encode (export)

    // Renders the full envelope/records payload as a `String` ready to print
    // (stdout) or write to a file. Deliberately does NOT hand-roll through
    // JSONSerialization for the JSON case: `[String: Any]` has no defined key
    // order, and Swift's Dictionary hashing is randomized per process, so two
    // separate `export known` invocations over identical data could otherwise
    // emit records with different key order and fail the byte-identical
    // round-trip acceptance test in §4.2. Building the string by hand fixes the
    // field order (id, jira_key, description, provisional, retired, created)
    // regardless of hashing.
    //
    // No trailing newline — callers append exactly one, whether writing to
    // stdout (CLIOutput.write appends its own) or to a file.
    public static func encode(tasks: [KnownTask], format: Format, generated: Date) -> String {
        switch format {
        case .json: return encodeJSON(tasks: tasks, generated: generated)
        case .csv:  return encodeCSV(tasks: tasks)
        }
    }

    private static func encodeJSON(tasks: [KnownTask], generated: Date) -> String {
        var out = "{\n"
        out += "  \"format\": \(jsonString(formatName)),\n"
        out += "  \"version\": \(supportedVersion),\n"
        out += "  \"generated\": \(jsonString(iso8601(generated))),\n"
        // window is omitted for known_task (§3.1).
        if tasks.isEmpty {
            out += "  \"records\": []\n}"
            return out
        }
        out += "  \"records\": [\n"
        out += tasks.map { "    " + encodeJSONRecord($0) }.joined(separator: ",\n")
        out += "\n  ]\n}"
        return out
    }

    private static func encodeJSONRecord(_ t: KnownTask) -> String {
        let idPart = t.id.map(String.init) ?? "null"
        let keyPart = t.jiraKey.map(jsonString) ?? "null"
        return "{ \"id\": \(idPart), \"jira_key\": \(keyPart), \"description\": \(jsonString(t.description)), " +
               "\"provisional\": \(t.provisional), \"retired\": \(t.retired), " +
               "\"created\": \(jsonString(iso8601FromMillis(t.createdTs))) }"
    }

    private static func encodeCSV(tasks: [KnownTask]) -> String {
        var lines = [csvHeader.joined(separator: ",")]
        for t in tasks {
            let fields = [
                t.id.map(String.init) ?? "",
                t.jiraKey ?? "",
                t.description,
                t.provisional ? "true" : "false",
                t.retired ? "true" : "false",
                iso8601FromMillis(t.createdTs),
            ]
            lines.append(fields.map(csvQuoteIfNeeded).joined(separator: ","))
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Decode (import)

    // Decodes `text` into the shared entry representation. Returns any
    // non-fatal warnings (currently: extra trailing CSV columns, §3.2) alongside
    // the entries so the caller can print them to stderr — the codec itself
    // does no I/O, keeping it as easy to unit test as the YAML loader.
    public static func decode(text: String, format: Format) throws -> (entries: [KnownTasksLoader.KnownTaskEntry], warnings: [String]) {
        switch format {
        case .json: return (try decodeJSON(text), [])
        case .csv:  return try decodeCSV(text)
        }
    }

    private static func decodeJSON(_ text: String) throws -> [KnownTasksLoader.KnownTaskEntry] {
        guard let data = text.data(using: .utf8) else {
            throw CodecError.malformedJSON("input is not valid UTF-8")
        }
        let top: Any
        do {
            top = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        } catch {
            throw CodecError.malformedJSON("\(error.localizedDescription)")
        }

        let recordsJSON: [Any]
        if let array = top as? [Any] {
            // Bare top-level array (§3.1): implied v1 of the type the command implies.
            recordsJSON = array
        } else if let obj = top as? [String: Any] {
            guard let format = obj["format"] as? String else {
                throw CodecError.malformedJSON("missing 'format' field")
            }
            guard format == formatName else {
                throw CodecError.unknownFormat(format)
            }
            guard let version = obj["version"] as? Int else {
                throw CodecError.malformedJSON("missing 'version' field")
            }
            // Versions are 1-based (§3.1 — a bare top-level array is read as v1),
            // so 0 and negatives are malformed rather than merely unsupported.
            guard version >= 1, version <= supportedVersion else {
                throw CodecError.unsupportedVersion(version)
            }
            guard let arr = obj["records"] as? [Any] else {
                throw CodecError.malformedJSON("missing 'records' array")
            }
            recordsJSON = arr
        } else {
            throw CodecError.malformedJSON("top-level value must be a JSON object or array")
        }

        return try recordsJSON.map(decodeJSONEntry)
    }

    private static func decodeJSONEntry(_ any: Any) throws -> KnownTasksLoader.KnownTaskEntry {
        guard let obj = any as? [String: Any] else {
            throw CodecError.malformedJSON("record is not a JSON object")
        }
        guard let rawDescription = obj["description"] as? String else {
            throw CodecError.malformedJSON("record missing 'description'")
        }
        let description = rawDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !description.isEmpty else {
            throw CodecError.malformedJSON("record has an empty 'description'")
        }

        // jira_key is `string | null` (§4.1); absent, JSON null, and a string are
        // the only valid encodings. A number or bool must be rejected rather than
        // silently read as absent — that would import a keyed row as provisional
        // and quietly drop the user's key. NSNull is how JSONSerialization
        // represents an explicit null, and is equivalent to absent per §3.
        let rawKey = obj["jira_key"]
        let jiraKey: String?
        switch rawKey {
        case nil, is NSNull:
            jiraKey = nil
        case let string as String:
            jiraKey = string
        default:
            throw CodecError.malformedJSON(
                "record '\(description)' has a non-string 'jira_key' (expected a string or null)"
            )
        }

        // KnownTaskEntry.init folds a whitespace-only key to nil (provisional),
        // per §3's null/empty equivalence — every source gets that for free.
        // id, provisional, retired, created are read by no one here: they are
        // export-only / ignored-on-import per §4.1.
        return KnownTasksLoader.KnownTaskEntry(description: description, jiraKey: jiraKey)
    }

    private static func decodeCSV(_ text: String) throws -> (entries: [KnownTasksLoader.KnownTaskEntry], warnings: [String]) {
        let rows = try parseCSVRows(text)
        guard let header = rows.first else {
            throw CodecError.malformedCSV("file is empty")
        }
        guard header.count >= csvHeader.count, Array(header.prefix(csvHeader.count)) == csvHeader else {
            throw CodecError.csvHeaderMismatch(expected: csvHeader, found: header)
        }
        var warnings: [String] = []
        if header.count > csvHeader.count {
            let extra = header[csvHeader.count...].joined(separator: ",")
            warnings.append("ignoring extra trailing column(s): \(extra)")
        }

        var entries: [KnownTasksLoader.KnownTaskEntry] = []
        for (rowIndex, row) in rows.dropFirst().enumerated() {
            guard row.count >= csvHeader.count else {
                throw CodecError.malformedCSV("row \(rowIndex + 2) has \(row.count) column(s), expected at least \(csvHeader.count)")
            }
            let description = row[2].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !description.isEmpty else {
                throw CodecError.malformedCSV("row \(rowIndex + 2) has an empty description")
            }
            // An empty jira_key cell means provisional (§3 null/empty
            // equivalence); KnownTaskEntry.init does that fold for every source.
            entries.append(KnownTasksLoader.KnownTaskEntry(description: description, jiraKey: row[1]))
        }
        return (entries, warnings)
    }

    // MARK: - RFC 4180 CSV row parsing
    //
    // Hand-rolled rather than split(separator:) because a quoted field may
    // itself contain the delimiter, a literal quote (doubled), or an embedded
    // newline — none of which a naive line/comma split handles. Tolerates CRLF,
    // LF, or a lone CR as a row terminator (§3.2: readers accept CRLF, writers
    // emit LF).
    private static func parseCSVRows(_ text: String) throws -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        var sawAnyContentInRow = false

        let chars = Array(text)
        var i = 0
        let n = chars.count

        func endField() { row.append(field); field = "" }
        func endRow() { endField(); rows.append(row); row = []; sawAnyContentInRow = false }

        while i < n {
            let c = chars[i]
            if inQuotes {
                if c == "\"" {
                    if i + 1 < n, chars[i + 1] == "\"" {
                        field.append("\"")
                        i += 2
                    } else {
                        inQuotes = false
                        i += 1
                    }
                } else {
                    field.append(c)
                    i += 1
                }
                continue
            }
            switch c {
            case "\"":
                inQuotes = true
                sawAnyContentInRow = true
                i += 1
            case ",":
                sawAnyContentInRow = true
                endField()
                i += 1
            case "\r":
                if i + 1 < n, chars[i + 1] == "\n" { i += 2 } else { i += 1 }
                endRow()
            case "\n":
                i += 1
                endRow()
            default:
                sawAnyContentInRow = true
                field.append(c)
                i += 1
            }
        }
        guard !inQuotes else {
            throw CodecError.malformedCSV("unterminated quoted field")
        }
        // A trailing newline produces no dangling row; a file with no trailing
        // newline still needs its last row flushed.
        if sawAnyContentInRow || !field.isEmpty {
            endRow()
        }

        // A wholly blank physical line — no delimiters at all — decodes above to
        // a single empty-string field, indistinguishable at this point from a
        // one-column row. Hand-edited and spreadsheet-exported CSV commonly end
        // (or are interspersed) with such lines, and they are not a data row
        // with an empty description; they are the absence of one. Left in,
        // they'd trip decodeCSV's column-count guard while naming a row number
        // the user can't see in their editor. A row with more than one field is
        // NOT dropped here even if every cell is blank (e.g. ",,,,,") — it has
        // the right shape to be real data and must still fail validation for an
        // empty description rather than being silently discarded.
        return rows.filter { !($0.count == 1 && $0[0].isEmpty) }
    }

    private static func csvQuoteIfNeeded(_ field: String) -> String {
        if field.contains(",") || field.contains("\"") || field.contains("\n") || field.contains("\r") {
            return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return field
    }

    // MARK: - JSON string escaping
    //
    // Hand-rolled to go with the hand-rolled envelope above (see the ordering
    // note on `encode`) rather than mixing in JSONSerialization for just the
    // string parts.
    private static func jsonString(_ s: String) -> String {
        var out = "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        out += "\""
        return out
    }

    // MARK: - Timestamps (§3: ISO-8601 with an explicit UTC offset)

    private static func iso8601(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.timeZone = TimeZone.current
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: date)
    }

    private static func iso8601FromMillis(_ millis: Int64) -> String {
        iso8601(Date(timeIntervalSince1970: Double(millis) / 1000.0))
    }
}
