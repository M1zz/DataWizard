import Foundation

/// Writes a merge result to a CSV file using the unified column order.
enum Exporter {

    /// Build the export string. When `excludeRemoved` is true, rows flagged
    /// "중복 - 삭제" are omitted entirely (an active-only roster).
    ///
    /// `columns` decides which unified columns are written, in the given order.
    /// 고정 스키마가 없어졌으므로 순서는 언제나 호출하는 쪽이 정한다.
    static func makeCSV(from result: MergeResult, excludeRemoved: Bool,
                        columns: [UnifiedColumn]) -> String {
        let cols = columns
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
                      columns: [UnifiedColumn]) throws {
        let csv = makeCSV(from: result, excludeRemoved: excludeRemoved, columns: columns)
        try csv.data(using: .utf8)?.write(to: url)
    }

    /// 기존 통합본에 이번 컬럼만 덮어쓴 결과를 그대로 내보낸다.
    /// 헤더도 값도 원본 파일 구성을 유지하므로, 스키마 밖 컬럼(수기 입력·후속 작업)이
    /// 살아 있는 채로 이어서 작업할 수 있다.
    static func makePatchCSV(_ patch: PatchResult) -> String {
        CSVParser.write(headers: patch.headers, rows: PatchEngine.table(patch))
    }

    static func writePatch(_ patch: PatchResult, to url: URL) throws {
        try makePatchCSV(patch).data(using: .utf8)?.write(to: url)
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
