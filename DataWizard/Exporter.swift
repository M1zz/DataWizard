import Foundation

/// Writes a merge result to a CSV file using the unified column order.
enum Exporter {

    /// Build the export string. When `excludeRemoved` is true, rows flagged
    /// "중복 - 삭제" are omitted entirely (an active-only roster).
    ///
    /// `columns` decides which unified columns are written, in the given order —
    /// the user picks these in the ‘최종 컬럼 고르기’ 단계. When nil, the full
    /// 73-column schema is written (backward-compatible default).
    static func makeCSV(from result: MergeResult, excludeRemoved: Bool,
                        columns: [UnifiedColumn]? = nil) -> String {
        let cols = columns ?? UnifiedColumn.allCases
        let headers = cols.map { $0.rawValue }
        var rows: [[String]] = []
        for row in result.rows {
            if excludeRemoved && row[.dupFlag] == "중복 - 삭제" { continue }
            rows.append(cols.map { row[$0] })
        }
        return CSVParser.write(headers: headers, rows: rows)
    }

    /// Write the CSV to disk at the given URL.
    static func write(_ result: MergeResult, to url: URL, excludeRemoved: Bool,
                      columns: [UnifiedColumn]? = nil) throws {
        let csv = makeCSV(from: result, excludeRemoved: excludeRemoved, columns: columns)
        try csv.data(using: .utf8)?.write(to: url)
    }

    /// Write the verification report: every cell the merge changed, one line per
    /// change, traceable to its source row. 원본과 대조해 100% 검증하는 용도.
    static func writeChanges(_ changes: [ChangeRecord], to url: URL) throws {
        let headers = ["파일", "출처 키", "컬럼", "이전 값", "이후 값"]
        let rows = changes.map { [$0.file, $0.ref, $0.column.rawValue, $0.before, $0.after] }
        let csv = CSVParser.write(headers: headers, rows: rows)
        try csv.data(using: .utf8)?.write(to: url)
    }
}
