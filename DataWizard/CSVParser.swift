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

        // 줄바꿈을 LF로 통일한다. Swift에서 "\r\n"은 두 글자가 아니라 하나의
        // Character(grapheme cluster)라, 아래 상태 기계가 '\r'나 '\n' 어느 쪽과도
        // 같지 않다고 판단해 CRLF 파일 전체가 한 줄로 읽히던 문제를 막는다.
        // (이 도구가 내보내는 CSV도 CRLF다 — 내보낸 파일을 다시 읽어야 한다.)
        s = s.replacingOccurrences(of: "\r\n", with: "\n")
             .replacingOccurrences(of: "\r", with: "\n")

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
    /// Duplicate header names (Wix exports repeat e.g. ‘최종 학력을 선택해주세요.’)
    /// are disambiguated as “이름 (2)”, “이름 (3)” so no column silently
    /// overwrites another — the first occurrence keeps the original name.
    static func readTable(at url: URL) throws -> (headers: [String], rows: [[String: String]]) {
        let data = try Data(contentsOf: url)
        let text = String(decoding: data, as: UTF8.self)
        let parsed = parse(text)
        guard let rawHeader = parsed.first else { return ([], []) }

        var seen: [String: Int] = [:]
        let header = rawHeader.map { name -> String in
            let n = (seen[name] ?? 0) + 1
            seen[name] = n
            return n == 1 ? name : "\(name) (\(n))"
        }

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
