import Foundation

/// A single source file prepared for review before merging.
///
/// Each unified output column is produced by combining an ordered list of this
/// file's source columns (joined by an optional separator). One source column is
/// the common case; two or more cover composites like 이름 = 성 + 이름, or an
/// address assembled from several fields.
struct FilePlan: Identifiable {
    let id = UUID()
    var url: URL
    var channel: Channel
    var headers: [String]                       // source columns, in file order
    var rows: [[String: String]]                // every parsed row, header-keyed
    var sources: [UnifiedColumn: [String]]      // unified field -> ordered source columns
    var separators: [UnifiedColumn: String]     // join string between combined sources ("")

    var fileName: String { url.lastPathComponent }

    /// Is this column sourced from at least one real source column?
    func isMapped(_ col: UnifiedColumn) -> Bool {
        (sources[col]?.contains { !$0.isEmpty }) ?? false
    }

    /// Combine this column's source values for one row, in order, skipping blanks.
    func compose(_ col: UnifiedColumn, from row: [String: String]) -> String {
        guard let cols = sources[col] else { return "" }
        let parts = cols.compactMap { c -> String? in
            let v = (row[c] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return v.isEmpty ? nil : v
        }
        return parts.joined(separator: separators[col] ?? "")
    }
}

/// Detects how a file holds applicant names: a single full-name column, or a
/// surname column plus a given-name column. Used only to seed the default
/// column-source combination for the name field.
enum NameDetector {

    /// Ordered source columns for the name: `[surname, given]` when split,
    /// `[fullName]` when whole, `[]` if nothing matched.
    static func detect(in headers: [String]) -> [String] {
        let surname = headers.first(where: isSurname) ?? ""
        let given = headers.first(where: isGiven) ?? ""
        if !surname.isEmpty && !given.isEmpty { return [surname, given] }   // 성 + 이름
        if let full = headers.first(where: isFullName) { return [full] }    // 성명 / 이름 / Name
        if !given.isEmpty { return [given] }
        return []
    }

    private static func norm(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    static func isSurname(_ h: String) -> Bool {
        let n = norm(h)
        if n == "성" || n == "성씨" || n == "성(姓)" { return true }
        if n.contains("국문 성") || n.contains("한글 성") || n.contains("영문 성") { return true }
        return n.contains("last name") || n.contains("lastname")
            || n.contains("surname") || n.contains("family name") || n.contains("familyname")
    }

    static func isGiven(_ h: String) -> Bool {
        let n = norm(h)
        if n == "이름" { return true }
        if n.contains("국문 이름") || n.contains("한글 이름") || n.contains("영문 이름") { return true }
        return n.contains("first name") || n.contains("firstname")
            || n.contains("given name") || n.contains("givenname")
    }

    static func isFullName(_ h: String) -> Bool {
        let n = norm(h)
        let exact: Set<String> = ["이름", "성명", "성함", "name", "full name", "fullname",
                                  "korean name", "koreanname", "한글성명", "국문성명"]
        if exact.contains(n) { return true }
        return n.contains("성명") || n.contains("full name") || n.contains("korean name")
            || n.contains("지원자")
    }
}

/// Builds a `FilePlan` from a file on disk, seeding column sources from the
/// channel's known layout while keeping only columns the file actually has.
enum PlanBuilder {

    static func build(url: URL, channel: Channel, previous: FilePlan?) throws -> FilePlan {
        let (headers, rows) = try readTable(url: url, channel: channel)
        let headerSet = Set(headers)

        // If the user already tuned this exact file, keep their edits.
        if let previous, previous.url == url, previous.channel == channel {
            return FilePlan(url: url, channel: channel, headers: headers, rows: rows,
                            sources: previous.sources, separators: previous.separators)
        }

        let defaults = channel == .general ? ChannelMapping.general : ChannelMapping.simpleKorean
        var sources: [UnifiedColumn: [String]] = [:]
        for (unified, source) in defaults where headerSet.contains(source) {
            sources[unified] = [source]
        }

        // Name: prepend the surname column when the layout splits 성 / 이름.
        if channel == .simple, headerSet.contains(ChannelMapping.simpleSurnameColumn) {
            let given = sources[.koreanName]?.first ?? ""
            sources[.koreanName] = [ChannelMapping.simpleSurnameColumn, given].filter { !$0.isEmpty }
        }

        // Generic fallback for files that don't match a known layout.
        if !(sources[.koreanName]?.contains { !$0.isEmpty } ?? false) {
            let parts = NameDetector.detect(in: headers)
            if !parts.isEmpty { sources[.koreanName] = parts }
        }

        return FilePlan(url: url, channel: channel, headers: headers, rows: rows,
                        sources: sources, separators: [:])
    }

    private static func readTable(url: URL, channel: Channel) throws -> (headers: [String], rows: [[String: String]]) {
        if url.pathExtension.lowercased() == "xlsx" {
            // 일반지원 .xlsx exports carry a title row, so the header is on row 1.
            return try XLSXReader.readTable(at: url, headerRowIndex: channel == .general ? 1 : 0)
        }
        return try CSVParser.readTable(at: url)
    }
}
