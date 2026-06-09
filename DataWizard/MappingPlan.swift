import Foundation

/// A single source file prepared for review before merging.
/// Holds the file's columns, its parsed rows, and an editable field mapping
/// (unified field → source column) that the user can adjust in the review step.
struct FilePlan: Identifiable {
    let id = UUID()
    var url: URL
    var channel: Channel
    var headers: [String]                  // source columns, in file order
    var rows: [[String: String]]           // every parsed row, header-keyed
    var mapping: [UnifiedColumn: String]   // unified field -> source column ("" = unmapped)
    var surnameColumn: String              // 간편지원 builds 이름 from surname + given ("" = none)

    var fileName: String { url.lastPathComponent }

    /// The four fields every roster needs; always shown in the editor.
    static let coreFields: [UnifiedColumn] = [.koreanName, .phone, .email, .dob]

    /// Computed/derived columns the user never maps by hand.
    private static let derived: Set<UnifiedColumn> = [.channel, .dupFlag, .phoneClean, .dobClean]

    /// Mapped fields beyond the core four, in canonical column order.
    var extraMappedFields: [UnifiedColumn] {
        let core = Set(FilePlan.coreFields)
        let mapped = Set(mapping.filter { !$0.value.isEmpty }.keys)
        return UnifiedColumn.allCases.filter {
            mapped.contains($0) && !core.contains($0) && !FilePlan.derived.contains($0)
        }
    }

    /// The first source value for a column, for the editor's preview cell.
    func sample(of column: String) -> String {
        guard !column.isEmpty, let first = rows.first else { return "" }
        return first[column] ?? ""
    }
}

/// Builds a `FilePlan` from a file on disk, seeding the mapping from the
/// channel's known layout while keeping only columns the file actually has.
enum PlanBuilder {

    static func build(url: URL, channel: Channel, previous: FilePlan?) throws -> FilePlan {
        let (headers, rows) = try readTable(url: url, channel: channel)
        let headerSet = Set(headers)

        // If the user already tuned this exact file, keep their edits.
        if let previous, previous.url == url, previous.channel == channel {
            return FilePlan(url: url, channel: channel, headers: headers, rows: rows,
                            mapping: previous.mapping, surnameColumn: previous.surnameColumn)
        }

        let defaults = channel == .general ? ChannelMapping.general : ChannelMapping.simpleKorean
        var mapping: [UnifiedColumn: String] = [:]
        for (unified, source) in defaults {
            mapping[unified] = headerSet.contains(source) ? source : ""
        }
        let surname = (channel == .simple && headerSet.contains(ChannelMapping.simpleSurnameColumn))
            ? ChannelMapping.simpleSurnameColumn : ""

        return FilePlan(url: url, channel: channel, headers: headers, rows: rows,
                        mapping: mapping, surnameColumn: surname)
    }

    private static func readTable(url: URL, channel: Channel) throws -> (headers: [String], rows: [[String: String]]) {
        if url.pathExtension.lowercased() == "xlsx" {
            // 일반지원 .xlsx exports carry a title row, so the header is on row 1.
            return try XLSXReader.readTable(at: url, headerRowIndex: channel == .general ? 1 : 0)
        }
        return try CSVParser.readTable(at: url)
    }
}

/// One thing worth flagging to the user about a file's mapping or data.
struct MappingIssue: Identifiable {
    enum Severity { case error, warning, info }
    let id = UUID()
    var severity: Severity
    var message: String

    var icon: String {
        switch severity {
        case .error:   return "xmark.octagon.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .info:    return "info.circle"
        }
    }
}

/// Inspects a plan and surfaces what will break, differ, or be dropped on merge:
/// missing key fields, mismatched phone formats, non-Korean names, unparseable
/// dates, and unmapped source columns.
enum PlanAnalyzer {

    static func issues(for plan: FilePlan) -> [MappingIssue] {
        var out: [MappingIssue] = []
        let sample = Array(plan.rows.prefix(300))

        func values(of field: UnifiedColumn) -> [String] {
            guard let col = plan.mapping[field], !col.isEmpty else { return [] }
            return sample.map { ($0[col] ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }

        // 1. Phone — required for dedup.
        if (plan.mapping[.phone] ?? "").isEmpty {
            out.append(.init(severity: .error,
                             message: "전화번호 컬럼이 매핑되지 않았습니다. 중복 검사가 불가능합니다."))
        } else {
            let phones = values(of: .phone)
            let pairs = phones.map { ($0, Normalizer.cleanPhone($0)) }
            let abnormal = pairs.filter { !$0.1.hasPrefix("010-") }
            let reformatted = pairs.filter { $0.0 != $0.1 }
            if let ex = abnormal.first {
                out.append(.init(severity: .warning,
                                 message: "표준 휴대폰(010-) 형태가 아닌 번호가 \(abnormal.count)건 있습니다. 예: ‘\(ex.0)’ → ‘\(ex.1)’"))
            } else if let ex = reformatted.first {
                out.append(.init(severity: .info,
                                 message: "전화번호 포맷이 ‘010-XXXX-XXXX’로 정규화됩니다. 예: ‘\(ex.0)’ → ‘\(ex.1)’"))
            }
        }

        // 2. Name — language / surname handling.
        if (plan.mapping[.koreanName] ?? "").isEmpty && plan.surnameColumn.isEmpty {
            out.append(.init(severity: .warning, message: "이름 컬럼이 매핑되지 않았습니다."))
        } else {
            let names = values(of: .koreanName)
            let nonKorean = names.filter { $0.range(of: "[A-Za-z]", options: .regularExpression) != nil }
            if let ex = nonKorean.first {
                out.append(.init(severity: .warning,
                                 message: "이름에 한글이 아닌 표기가 섞여 있습니다 (\(nonKorean.count)건). 예: ‘\(ex)’"))
            }
            if plan.channel == .simple && plan.surnameColumn.isEmpty {
                out.append(.init(severity: .info, message: "성(姓) 컬럼이 지정되지 않아 이름만 사용됩니다."))
            }
        }

        // 3. Email.
        if (plan.mapping[.email] ?? "").isEmpty {
            out.append(.init(severity: .info, message: "이메일 컬럼이 매핑되지 않았습니다."))
        }

        // 4. Birthdate format.
        if !(plan.mapping[.dob] ?? "").isEmpty {
            let dobs = values(of: .dob)
            let unparsed = dobs.filter {
                Normalizer.cleanDate($0) == $0
                    && $0.range(of: "^\\d{4}-\\d{2}-\\d{2}$", options: .regularExpression) == nil
            }
            if let ex = unparsed.first {
                out.append(.init(severity: .warning,
                                 message: "생년월일 포맷을 인식하지 못한 행이 \(unparsed.count)건 있습니다. 예: ‘\(ex)’"))
            }
        }

        // 5. Columns that won't make it into the merged file.
        var used = Set(plan.mapping.values.filter { !$0.isEmpty })
        if !plan.surnameColumn.isEmpty { used.insert(plan.surnameColumn) }
        let dropped = plan.headers.filter { !used.contains($0) }
        if !dropped.isEmpty {
            out.append(.init(severity: .info,
                             message: "매핑되지 않은 원본 컬럼 \(dropped.count)개는 병합 결과에 포함되지 않습니다."))
        }

        return out
    }
}
