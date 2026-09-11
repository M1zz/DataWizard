import Foundation

/// A single source file prepared for review before merging.
///
/// Each unified output column is produced by combining an ordered list of this
/// file's source columns (joined by an optional separator). One source column is
/// the common case; two or more cover composites like 이름 = 성 + 이름, or an
/// address assembled from several fields.
/// 한 컬럼에 여러 칸을 넣을 때의 방식.
enum CombineMode: String, Codable {
    /// 순서대로 이어 붙인다 — 성 + 이름 → 김 철수.
    case join
    /// 값이 있는 첫 칸만 쓴다 — 남성/여성 칸과 male/female 칸을 한 칸으로.
    case first
}

struct FilePlan: Identifiable {
    let id = UUID()
    var url: URL
    var channel: Channel
    var headers: [String]                       // source columns, in file order
    var rows: [[String: String]]                // every parsed row, header-keyed
    var sources: [UnifiedColumn: [String]]      // unified field -> ordered source columns
    var separators: [UnifiedColumn: String]     // join string between combined sources ("")
    /// 여러 칸을 한 컬럼에 넣을 때 **어떻게** 넣을지.
    /// 없으면 지금까지처럼 이어 붙인다(`.join`).
    var combine: [UnifiedColumn: CombineMode] = [:]
    /// 시트에 숨겨져 있어 빼 둔 줄 수 (엑셀·넘버스에서 필터로 감춘 줄).
    var hiddenRowsSkipped = 0
    /// 숨겨진 줄까지 읽어 들였는가.
    var includesHiddenRows = false
    /// 파일 하나를 그대로 고치는 유틸 모드에서 만든 계획인가.
    /// true면 아카데미 전용 보정(‘그 외 국가’ 치환 등)을 건너뛰고 값을 있는 그대로 읽는다.
    var passthrough = false

    var fileName: String { url.lastPathComponent }

    /// The 지원방식 label written to each row. 일반 stays as-is; 간편지원 is split
    /// into Public/Private by file name, since the source form leaves the
    /// "지원 방식" field blank (spec Step 1-4: 지원 방식 구분값 추가).
    var applicationType: String {
        switch channel {
        case .general:
            return Channel.general.rawValue
        case .simple:
            let n = fileName.lowercased()
            if n.contains("public") { return "간편지원(Public)" }
            if n.contains("private") { return "간편지원(Private)" }
            return Channel.simple.rawValue
        }
    }

    /// Is this column sourced from at least one real source column?
    func isMapped(_ col: UnifiedColumn) -> Bool {
        (sources[col]?.contains { !$0.isEmpty }) ?? false
    }

    /// The single column used as this file's 출처 키 (row locator). Fixed per
    /// file — never mixed per row — so every key can be looked up in the same
    /// original column: Code if the file has one, else Email, else row numbers.
    var refColumn: UnifiedColumn? {
        if isMapped(.code) { return .code }
        if isMapped(.email) { return .email }
        return nil
    }

    /// This file's 출처 키 for one row, always read from `refColumn`.
    /// An empty cell falls back to the row number so the row stays findable.
    func rowRef(_ row: [String: String], index: Int) -> String {
        guard let col = refColumn else { return "행 \(index + 1)" }
        let v = compose(col, from: row)
        return v.isEmpty ? "행 \(index + 1)" : v
    }

    /// Combine this column's source values for one row, in order, skipping blanks.
    func compose(_ col: UnifiedColumn, from row: [String: String]) -> String {
        guard let cols = sources[col] else { return "" }
        let parts = cols.compactMap { c -> String? in
            let v = (row[c] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return v.isEmpty ? nil : v
        }
        // `.first` = 값이 있는 첫 칸만 쓴다. 같은 뜻을 다른 말로 적어 둔 두 칸
        // (남성/여성 · male/female)을 한 칸으로 모을 때 이어 붙이면 안 되기 때문.
        let joined = combine[col] == .first
            ? (parts.first ?? "")
            : parts.joined(separator: separators[col] ?? "")

        // 간편지원 국가: ‘그 외 국가’를 고르면 실제 국가명 컬럼의 값으로 치환해
        // 최종본처럼 진짜 국가명이 남도록 한다 (값 통일에서 영문으로 정리 가능).
        if col == .country, channel == .simple, !passthrough, joined == "그 외 국가" {
            let name = (row[ChannelMapping.simpleCountryNameColumn] ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty { return name }
        }
        return joined
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

        if channel == .simple {
            // Headers whose spelling varies between Public/Private exports.
            for (unified, candidates) in ChannelMapping.simpleAlternates where sources[unified] == nil {
                if let hit = candidates.first(where: { headerSet.contains($0) }) {
                    sources[unified] = [hit]
                }
            }
            // Current Status = 대학 단계 + 그 외 신분 (행마다 한쪽만 채워짐).
            let status = ChannelMapping.simpleStatusSources.filter { headerSet.contains($0) }
            if !status.isEmpty { sources[.currentStatus] = status }
            // School/University/Company = 재학 → 졸업 → 회사.
            let school = ChannelMapping.simpleSchoolSources.filter { headerSet.contains($0) }
            if !school.isEmpty { sources[.schoolCompany] = school }
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

    /// 파일 하나를 있는 그대로 다루는 계획 — 헤더가 곧 컬럼이고, 값은 변형 없이 읽는다.
    /// 유틸 모드(‘고칠 파일 + 고칠 컬럼’)의 출발점.
    static func passthrough(url: URL, includeHidden: Bool = false) throws -> FilePlan {
        let table: (headers: [String], rows: [[String: String]])
        var hiddenSkipped = 0
        if url.pathExtension.lowercased() == "xlsx" {
            // 첫 줄이 제목뿐인 파일이 흔해 머리글 줄을 스스로 찾고,
            // 시트에서 숨겨 둔 줄(필터로 감춘 줄)은 화면에서 보이는 대로 빼고 읽는다.
            let t = try XLSXReader.readVisibleTable(at: url, includeHidden: includeHidden)
            table = (t.headers, t.rows)
            hiddenSkipped = t.hiddenSkipped
        } else {
            table = try CSVParser.readTable(at: url)
        }
        var sources: [UnifiedColumn: [String]] = [:]
        for h in table.headers {
            guard let col = UnifiedColumn(rawValue: h), sources[col] == nil else { continue }
            sources[col] = [h]
        }
        return FilePlan(url: url, channel: .simple, headers: table.headers, rows: table.rows,
                        sources: sources, separators: [:],
                        hiddenRowsSkipped: hiddenSkipped, includesHiddenRows: includeHidden,
                        passthrough: true)
    }

    private static func readTable(url: URL, channel: Channel) throws -> (headers: [String], rows: [[String: String]]) {
        if url.pathExtension.lowercased() == "xlsx" {
            // 일반지원 .xlsx exports carry a title row, so the header is on row 1.
            return try XLSXReader.readTable(at: url, headerRowIndex: channel == .general ? 1 : 0)
        }
        return try CSVParser.readTable(at: url)
    }
}
