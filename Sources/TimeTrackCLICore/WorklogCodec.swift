import Foundation
import TimeTrackKit

// JSON + CSV encoder for the `worklog` interchange record
// (docs/interchange-format.md §3, §5). Export-only in this build — `import
// worklog` needs the new `manual_entry` event type (§7.2) and is issue #59
// Phase D, not this one.
public enum WorklogCodec {

    public enum Format {
        case json
        case csv
    }

    // MARK: - Envelope constants (§3.1, §5.2)

    public static let formatName = "timetrack.worklog"
    public static let supportedVersion = 1
    public static let csvHeader = [
        "date", "started", "ended", "seconds", "raw_seconds",
        "jira_key", "known_task_id", "description", "capture_tasks", "status",
    ]

    // The four normalisation knobs §5.4 requires export to expose (rather than
    // hardcode), recorded in the JSON envelope so an exported file is
    // self-describing.
    public struct Normalisation {
        public let dropBelowSec: Int
        public let minIntervalMin: Int
        public let roundToMin: Int
        public let aggregateKey: String?

        public init(dropBelowSec: Int, minIntervalMin: Int, roundToMin: Int, aggregateKey: String?) {
            self.dropBelowSec = dropBelowSec
            self.minIntervalMin = minIntervalMin
            self.roundToMin = roundToMin
            self.aggregateKey = aggregateKey
        }
    }

    // MARK: - Encode (export)

    // Renders the full envelope/records payload as a `String` ready to print
    // (stdout) or write to a file. Hand-rolled for the same reason as
    // KnownTaskCodec: fixed field order regardless of Dictionary hashing.
    //
    // No trailing newline — callers append exactly one.
    public static func encode(
        records: [Store.WorklogRecord],
        format: Format,
        generated: Date,
        window: (from: Date, to: Date),
        normalisation: Normalisation
    ) -> String {
        switch format {
        case .json: return encodeJSON(records: records, generated: generated, window: window, normalisation: normalisation)
        case .csv:  return encodeCSV(records: records)
        }
    }

    private static func encodeJSON(
        records: [Store.WorklogRecord],
        generated: Date,
        window: (from: Date, to: Date),
        normalisation: Normalisation
    ) -> String {
        var out = "{\n"
        out += "  \"format\": \(jsonString(formatName)),\n"
        out += "  \"version\": \(supportedVersion),\n"
        out += "  \"generated\": \(jsonString(iso8601(generated))),\n"
        out += "  \"window\": { \"from\": \(jsonString(dateOnly(window.from))), \"to\": \(jsonString(dateOnly(window.to))) },\n"
        out += "  \"normalisation\": { \"drop_below_sec\": \(normalisation.dropBelowSec), " +
               "\"min_interval_min\": \(normalisation.minIntervalMin), " +
               "\"round_to_min\": \(normalisation.roundToMin), " +
               "\"aggregate_key\": \(normalisation.aggregateKey.map(jsonString) ?? "null") },\n"
        if records.isEmpty {
            out += "  \"records\": []\n}"
            return out
        }
        out += "  \"records\": [\n"
        out += records.map { "    " + encodeJSONRecord($0) }.joined(separator: ",\n")
        out += "\n  ]\n}"
        return out
    }

    private static func encodeJSONRecord(_ r: Store.WorklogRecord) -> String {
        let datePart = r.date.map { jsonString(dateOnly($0)) } ?? "null"
        let endedPart = r.ended.map { jsonString(iso8601($0)) } ?? "null"
        let keyPart = r.jiraKey.map(jsonString) ?? "null"
        let knownIdPart = r.knownTaskId.map(String.init) ?? "null"
        let descPart = r.description.map(jsonString) ?? "null"
        let tasksPart = "[" + r.captureTasks.map(jsonString).joined(separator: ", ") + "]"
        return "{ \"date\": \(datePart), \"started\": \(jsonString(iso8601(r.started))), \"ended\": \(endedPart), " +
               "\"seconds\": \(r.seconds), \"raw_seconds\": \(r.rawSeconds), " +
               "\"jira_key\": \(keyPart), \"known_task_id\": \(knownIdPart), \"description\": \(descPart), " +
               "\"capture_tasks\": \(tasksPart), \"status\": \(jsonString(r.status.rawValue)) }"
    }

    private static func encodeCSV(records: [Store.WorklogRecord]) -> String {
        var lines = [csvHeader.joined(separator: ",")]
        for r in records {
            let fields = [
                r.date.map(dateOnly) ?? "",
                iso8601(r.started),
                r.ended.map(iso8601) ?? "",
                String(r.seconds),
                String(r.rawSeconds),
                r.jiraKey ?? "",
                r.knownTaskId.map(String.init) ?? "",
                r.description ?? "",
                encodeCaptureTasksCell(r.captureTasks),
                r.status.rawValue,
            ]
            lines.append(fields.map(csvQuoteIfNeeded).joined(separator: ","))
        }
        return lines.joined(separator: "\n")
    }

    // §3.2 list-valued field encoding: `;`-separated, backslash-escaping both
    // `;` and `\` so the cell round-trips losslessly. Applied BEFORE the outer
    // RFC 4180 quoting, which is independent of this escaping.
    private static func encodeCaptureTasksCell(_ names: [String]) -> String {
        names.map { name -> String in
            var escaped = ""
            for ch in name {
                if ch == "\\" || ch == ";" { escaped.append("\\") }
                escaped.append(ch)
            }
            return escaped
        }.joined(separator: ";")
    }

    private static func csvQuoteIfNeeded(_ field: String) -> String {
        if field.contains(",") || field.contains("\"") || field.contains("\n") || field.contains("\r") {
            return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return field
    }

    // MARK: - JSON string escaping (identical to KnownTaskCodec's)

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

    // MARK: - Timestamps (§3: ISO-8601 with an explicit UTC offset; dates are
    // YYYY-MM-DD in the local calendar, matching Calendar.current.startOfDay)

    private static func iso8601(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.timeZone = TimeZone.current
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: date)
    }

    private static func dateOnly(_ date: Date) -> String {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = TimeZone.current
        return df.string(from: date)
    }
}
