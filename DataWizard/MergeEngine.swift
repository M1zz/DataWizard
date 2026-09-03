import Foundation

/// One cell the merge actually modified, traceable back to its source row.
/// The complete list doubles as the user's verification report: every change
/// the tool made is here, and anything not here was passed through untouched.
struct ChangeRecord: Identifiable {
    let id = UUID()
    let file: String        // source file name
    let ref: String         // row locator: Code → Email → 행 N
    let column: UnifiedColumn
    let before: String      // value as it appears in the original file
    let after: String       // value written to the merged output
}

/// Result of a merge run, surfaced to the UI.
struct MergeResult {
    var rows: [ApplicantRow]
    var counts: [Channel: Int]      // rows ingested per channel (post-filter)
    var duplicatePairs: Int         // number of phone keys that appeared in >1 row
    var keepCount: Int
    var removeCount: Int
    var unmatchedNoPhone: Int       // rows with no usable phone key
    var changes: [ChangeRecord] = []  // every cell the merge modified (audit trail)
    /// 각 행이 몇 번째로 올린 파일에서 왔는지 — 미리보기에서 파일마다 색을 달리 쓰기 위한 것.
    /// 중복 표시는 행을 지우지 않고 표시만 하므로 순서·개수가 그대로 유지된다.
    var origins: [Int] = []
    /// 도구가 만들어 낸 Unique ID(6F1…) 목록. 원본에 Code가 있던 행과 구분해야
    /// 기존 통합본에 이어붙일 때 번호가 밀린 코드로 엉뚱한 짝을 짓지 않는다.
    var generatedCodes: Set<String> = []
}

/// One source file to merge, with its auto-detected channel.
struct MergeInput: Identifiable {
    let id = UUID()
    var url: URL
    var channel: Channel
}

/// The engine that turns any number of reviewed channel files into one
/// normalized, deduplicated sheet, using each file's user-adjusted mapping.
struct MergeEngine {

    /// Reviewed files, each carrying its parsed rows and final field mapping.
    var plans: [FilePlan]

    /// Per-column value unification: unified field → (original value → canonical value).
    /// Applied so e.g. "Seoul" and "서울" land as one value in the merged column.
    var valueMap: [UnifiedColumn: [String: String]] = [:]

    /// 전화번호(Clean)에 쓸 목표 포맷 템플릿 — 모든 번호가 이 한 가지 표기로 통일된다.
    var phoneTemplate: String = Normalizer.defaultPhoneTemplate

    func run() throws -> MergeResult {
        var rows: [ApplicantRow] = []
        var counts: [Channel: Int] = [:]
        var changes: [ChangeRecord] = []
        var origins: [Int] = []

        // ---- Step 1: ingest every file into the unified schema ----
        for (fileIndex, plan) in plans.enumerated() {
            var usable = Array(plan.rows.enumerated())
            // 일반지원: only rows that reached "Submitted" are real applications.
            if plan.channel == .general, plan.headers.contains(ChannelMapping.generalStatusColumn) {
                usable = usable.filter {
                    ($0.element[ChannelMapping.generalStatusColumn] ?? "").trimmingCharacters(in: .whitespaces)
                        == ChannelMapping.generalSubmittedStatus
                }
            }
            let mapped = usable.map { map($0.element, index: $0.offset, using: plan, changes: &changes) }
            rows += mapped
            origins += Array(repeating: fileIndex, count: mapped.count)
            counts[plan.channel, default: 0] += mapped.count
        }

        // ---- Step 1b: 간편지원 Unique ID 부여 (spec Step 2-2: 6F1 + 일련번호) ----
        // Code가 없는 행에 파일 순서대로 6F10001, 6F10002… 를 채운다.
        var serial = 0
        var generatedCodes = Set<String>()
        for i in rows.indices where rows[i][.code].isEmpty {
            serial += 1
            let code = String(format: "6F1%04d", serial)
            rows[i][.code] = code
            generatedCodes.insert(code)
        }

        // ---- Step 2: dedup across channels by cleaned phone key ----
        let result = deduplicate(rows: rows)
        return MergeResult(
            rows: result.rows,
            counts: counts,
            duplicatePairs: result.duplicateGroups,
            keepCount: result.keep,
            removeCount: result.remove,
            unmatchedNoPhone: result.noPhone,
            changes: changes,
            origins: result.rows.count == origins.count ? origins : [],
            generatedCodes: generatedCodes
        )
    }

    // MARK: - mapping

    /// Map one source row into the unified schema by composing each column's
    /// configured source columns, then applying any value unification.
    /// Every applied unification is appended to `changes` (the audit trail).
    private func map(_ src: [String: String], index: Int, using plan: FilePlan,
                     changes: inout [ChangeRecord]) -> ApplicantRow {
        var row = ApplicantRow()
        row[.channel] = plan.applicationType

        for unified in plan.sources.keys where plan.isMapped(unified) {
            var value = plan.compose(unified, from: src)
            if let canonical = valueMap[unified]?[value], canonical != value {
                changes.append(ChangeRecord(file: plan.fileName,
                                            ref: plan.rowRef(src, index: index),
                                            column: unified,
                                            before: value, after: canonical))
                value = canonical
            }
            row[unified] = value
        }

        normalizeDerivedFields(&row)
        return row
    }

    /// Fill the cleaned phone/birthdate columns plus 만 나이 and Age Group.
    private func normalizeDerivedFields(_ row: inout ApplicantRow) {
        row[.phoneClean] = Normalizer.formatPhone(row[.phone], template: phoneTemplate)
            ?? row[.phone].trimmingCharacters(in: .whitespacesAndNewlines)
        row[.dobClean] = Normalizer.cleanDate(row[.dob])
        row[.age] = Normalizer.age(fromCleanDob: row[.dobClean])
        row[.ageGroup] = Normalizer.ageGroup(fromAge: row[.age])
    }

    // MARK: - dedup

    private func deduplicate(rows: [ApplicantRow])
        -> (rows: [ApplicantRow], duplicateGroups: Int, keep: Int, remove: Int, noPhone: Int) {

        // ---- Step 1: union rows that share a phone key OR an email (spec Step 1-5:
        // 전화번호와 이메일 주소를 Key 값으로 사용). Same person can match on either. ----
        var parent = Array(rows.indices)
        func find(_ x: Int) -> Int {
            var r = x
            while parent[r] != r { parent[r] = parent[parent[r]]; r = parent[r] }
            return r
        }
        func union(_ a: Int, _ b: Int) {
            let ra = find(a), rb = find(b)
            if ra != rb { parent[ra] = rb }
        }

        var firstByPhone: [String: Int] = [:]
        var firstByEmail: [String: Int] = [:]
        var noKey = 0
        for (i, row) in rows.enumerated() {
            let phone = Normalizer.phoneKey(row[.phone])
            let email = row[.email].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if phone.isEmpty && email.isEmpty { noKey += 1 }
            if !phone.isEmpty {
                if let j = firstByPhone[phone] { union(i, j) } else { firstByPhone[phone] = i }
            }
            if !email.isEmpty {
                if let j = firstByEmail[email] { union(i, j) } else { firstByEmail[email] = i }
            }
        }

        // ---- Step 2: collect rows per person ----
        var groups: [Int: [Int]] = [:]
        for i in rows.indices { groups[find(i), default: []].append(i) }

        // ---- Step 3: annotate the dup flag, keeping one row per person ----
        var out = rows

        // 유지 기준 (spec Step 1-5): 최종 제출 시간이 가장 최근인 행을 남긴다.
        // 시간이 같거나 없으면 일반지원 우선, 그다음 원래 순서.
        func submitKey(_ row: ApplicantRow) -> String {
            // '2026-05-14T03:59:56.007Z'와 '2026-05-14 03:25:41'을 같은 자리에서
            // 비교할 수 있게 구분자만 통일 (zero-padded라 사전순 == 시간순).
            row[.submittedAt]
                .replacingOccurrences(of: "T", with: " ")
                .replacingOccurrences(of: "Z", with: "")
        }
        func priority(_ channelRaw: String) -> Int {
            if channelRaw == Channel.general.rawValue { return 0 }
            if channelRaw.hasPrefix("간편") { return 1 }
            return 2
        }

        var duplicateGroups = 0
        var keep = 0
        var remove = 0

        for (_, indices) in groups where indices.count > 1 {
            duplicateGroups += 1
            let sorted = indices.sorted {
                let s0 = submitKey(out[$0]), s1 = submitKey(out[$1])
                if s0 != s1 { return s0 > s1 }                    // 최신 제출 먼저
                let p0 = priority(out[$0][.channel])
                let p1 = priority(out[$1][.channel])
                return p0 != p1 ? p0 < p1 : $0 < $1
            }
            for (rank, idx) in sorted.enumerated() {
                if rank == 0 {
                    out[idx][.dupFlag] = "중복 -Keep"
                    keep += 1
                } else {
                    out[idx][.dupFlag] = "중복 - 삭제"
                    remove += 1
                }
            }
        }

        return (out, duplicateGroups, keep, remove, noKey)
    }
}
