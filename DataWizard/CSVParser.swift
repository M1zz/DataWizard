import Foundation

/// A small RFC-4180 CSV parser. Handles quoted fields, embedded commas,
/// embedded newlines, escaped double-quotes, and a UTF-8 BOM.
enum CSVParser {

    /// Parse CSV text into rows of string fields.
    /// State machine:
    ///   - normal: a comma ends a field, a newline ends a row
    ///   - inQuotes: commas/newlines are literal; "" is an escaped quote
    static func parse(_ text: String) -> [[String]] {
        // Strip a leading UTF-8 BOM if present
        var s = text
        if s.hasPrefix("\u{FEFF}") { s.removeFirst() }

        var rows: [[String]] = []
        var field = ""
        var row: [String] = []
        var inQuotes = false

        let chars = Array(s)
        var i = 0
        while i < chars.count {
            let c = chars[i]

            if inQuotes {
                if c == "\"" {
                    // Look ahead: a doubled quote is an escaped quote
                    if i + 1 < chars.count && chars[i + 1] == "\"" {
                        field.append("\"")
                        i += 2
                        continue
                    } else {
                        inQuotes = false
                        i += 1
                        continue
                    }
                } else {
                    field.append(c)
                    i += 1
                    continue
                }
            } else {
                if c == "\"" {
                    inQuotes = true
                    i += 1
                    continue
                } else if c == "," {
                    row.append(field)
                    field = ""
                    i += 1
                    continue
                } else if c == "\r" {
                    // Swallow CR; the following LF (if any) closes the row
                    i += 1
                    continue
                } else if c == "\n" {
                    row.append(field)
                    rows.append(row)
                    field = ""
                    row = []
                    i += 1
                    continue
                } else {
                    field.append(c)
                    i += 1
                    continue
                }
            }
        }

        // Flush the final field/row if the file did not end with a newline
        if !field.isEmpty || !row.isEmpty {
            row.append(field)
            rows.append(row)
        }
        return rows
    }

    /// Read a CSV file from disk into its ordered header plus header-keyed rows.
    static func readTable(at url: URL) throws -> (headers: [String], rows: [[String: String]]) {
        let data = try Data(contentsOf: url)
        let text = String(decoding: data, as: UTF8.self)
        let parsed = parse(text)
        guard let header = parsed.first else { return ([], []) }
        var out: [[String: String]] = []
        for r in parsed.dropFirst() {
            // Skip blank lines
            if r.allSatisfy({ $0.trimmingCharacters(in: .whitespaces).isEmpty }) { continue }
            var dict: [String: String] = [:]
            for (idx, key) in header.enumerated() {
                dict[key] = idx < r.count ? r[idx] : ""
            }
            out.append(dict)
        }
        return (header, out)
    }

    /// Read a CSV file from disk and return [header-keyed dictionary] rows.
    static func readDicts(at url: URL) throws -> [[String: String]] {
        try readTable(at: url).rows
    }

    /// Serialize rows to a CSV string with a UTF-8 BOM (so Excel opens Korean correctly).
    static func write(headers: [String], rows: [[String]]) -> String {
        func escape(_ field: String) -> String {
            if field.contains(",") || field.contains("\"") || field.contains("\n") || field.contains("\r") {
                return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            }
            return field
        }
        var lines: [String] = []
        lines.append(headers.map(escape).joined(separator: ","))
        for r in rows {
            lines.append(r.map(escape).joined(separator: ","))
        }
        return "\u{FEFF}" + lines.joined(separator: "\r\n")
    }
}
