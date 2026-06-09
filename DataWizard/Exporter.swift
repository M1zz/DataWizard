import Foundation

/// Writes a merge result to a CSV file using the unified column order.
enum Exporter {

    /// Build the export string. When `excludeRemoved` is true, rows flagged
    /// "중복 - 삭제" are omitted entirely (an active-only roster).
    static func makeCSV(from result: MergeResult, excludeRemoved: Bool) -> String {
        let headers = UnifiedColumn.orderedHeaders
        var rows: [[String]] = []
        for row in result.rows {
            if excludeRemoved && row[.dupFlag] == "중복 - 삭제" { continue }
            let line = UnifiedColumn.allCases.map { row[$0] }
            rows.append(line)
        }
        return CSVParser.write(headers: headers, rows: rows)
    }

    /// Write the CSV to disk at the given URL.
    static func write(_ result: MergeResult, to url: URL, excludeRemoved: Bool) throws {
        let csv = makeCSV(from: result, excludeRemoved: excludeRemoved)
        try csv.data(using: .utf8)?.write(to: url)
    }
}
