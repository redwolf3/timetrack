import Foundation
import TimeTrackKit

// JSON + CSV encoder for the `worklog` interchange record
// (docs/interchange-format.md §3, §5). Export only in v1 — `import worklog`
// (§7.2) needs the new `manual_entry` event type and is a later phase.
public enum WorklogCodec {

    public enum Format {
        case json
        case csv
    }

    // MARK: - Envelope constants (§3.1, §5.4)

    public static let formatName = "timetrack.worklog"
    public static let supportedVersion = 1
    public static let csvHeader = [
        "date", "started", "ended", "seconds", "raw_seconds",
        "jira_key", "known_task_id", "description", "capture_tasks", "status",
    ]

    // The four normalisation knobs export exposes (§5.4); subFifteenResolutions
    // is deliberately excluded (§5.5).
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
    //
    // Hand-rolled JSON, same rationale as KnownTaskCodec: fixed field order
    // regardless of Dictionary hashing, so two exports of identical data are
    // byte-identical apart from `generated`. No trailing newline — callers
    // append exactly one, whether writing to stdout or a file.
    public static func encode(
        records: [Store.WorklogRecord],
        format: Format,
        generated: Date,
        from: Date,
        to: Date,
        normalisation: Normalisation
    ) -> String {
        switch format {
        case .json: return encodeJSON(records: records, generated: generated, from: from, to: to, normalisation: normalisation)
        case .csv:  return encodeCSV(records: records)
        }
    }

    private static func encodeJSON(
        records: [Store.WorklogRecord], generated: Date, from: Date, to: Date, normalisation: Normalisation
    ) -> String {
        var out = "{\n"
        out += "  \"format\": \(jsonString(formatName)),\n"
        out += "  \"version\": \(supportedVersion),\n"
        out += "  \"generated\": \(jsonString(iso8601(generated))),\n"
        out += "  \"window\": { \"from\": \(jsonString(dateOnly(from))), \"to\": \(jsonString(dateOnly(to))) },\n"
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
        return "{ \"date\": \(datePart), \"started\": \(jsonString(iso8601(r.started))), " +
               "\"ended\": \(endedPart), \"seconds\": \(r.seconds), \"raw_seconds\": \(r.rawSeconds), " +
               "\"jira_key\": \(keyPart), \"known_task_id\": \(knownIdPart), " +
               "\"description\": \(descPart), \"capture_tasks\": \(tasksPart), " +
               "\"status\": \(jsonString(r.status.rawValue)) }"
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
                encodeCaptureTasks(r.captureTasks),
                r.status.rawValue,
            ]
            lines.append(fields.map(csvQuoteIfNeeded).joined(separator: ","))
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - `capture_tasks` list encoding (§3.2)
    //
    // A single CSV cell of `;`-separated values; `;` and `\` inside a task name
    // are backslash-escaped so the join is reversible. The outer RFC 4180
    // quoting (csvQuoteIfNeeded) is applied after this and is independent of it.
    static func encodeCaptureTasks(_ tasks: [String]) -> String {
        tasks.map { task -> String in
            var escaped = ""
            for ch in task {
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

    // MARK: - JSON string escaping (mirrors KnownTaskCodec)

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
    // YYYY-MM-DD in the local calendar)

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
