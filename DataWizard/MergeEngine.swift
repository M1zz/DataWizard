import Foundation

/// Result of a merge run, surfaced to the UI.
struct MergeResult {
    var rows: [ApplicantRow]
    var counts: [Channel: Int]      // rows ingested per channel (post-filter)
    var duplicatePairs: Int         // number of phone keys that appeared in >1 row
    var keepCount: Int
    var removeCount: Int
    var unmatchedNoPhone: Int       // rows with no usable phone key
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

    func run() throws -> MergeResult {
        var rows: [ApplicantRow] = []
        var counts: [Channel: Int] = [:]

        // ---- Step 1: ingest every file into the unified schema ----
        for plan in plans {
            var usable = plan.rows
            // 일반지원: only rows that reached "Submitted" are real applications.
            if plan.channel == .general, plan.headers.contains(ChannelMapping.generalStatusColumn) {
                usable = usable.filter {
                    ($0[ChannelMapping.generalStatusColumn] ?? "").trimmingCharacters(in: .whitespaces)
                        == ChannelMapping.generalSubmittedStatus
                }
            }
            let mapped = usable.map { map($0, using: plan) }
            rows += mapped
            counts[plan.channel, default: 0] += mapped.count
        }

        // ---- Step 2: dedup across channels by cleaned phone key ----
        let result = deduplicate(rows: rows)
        return MergeResult(
            rows: result.rows,
            counts: counts,
            duplicatePairs: result.duplicateGroups,
            keepCount: result.keep,
            removeCount: result.remove,
            unmatchedNoPhone: result.noPhone
        )
    }

    // MARK: - mapping

    /// Map one source row into the unified schema using a file's reviewed mapping.
    private func map(_ src: [String: String], using plan: FilePlan) -> ApplicantRow {
        var row = ApplicantRow()
        row[.channel] = plan.channel.rawValue

        for (unified, sourceKey) in plan.mapping where !sourceKey.isEmpty {
            var value = (src[sourceKey] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if let canonical = valueMap[unified]?[value] { value = canonical }
            row[unified] = value
        }

        // 간편지원: build the full Korean name as "성 이름" (surname + given).
        if !plan.surnameColumn.isEmpty {
            let surname = (src[plan.surnameColumn] ?? "").trimmingCharacters(in: .whitespaces)
            let given = row[.koreanName]
            row[.koreanName] = [surname, given].filter { !$0.isEmpty }.joined()
        }

        normalizeDerivedFields(&row)
        return row
    }

    /// Fill the cleaned phone and cleaned birthdate columns.
    private func normalizeDerivedFields(_ row: inout ApplicantRow) {
        row[.phoneClean] = Normalizer.cleanPhone(row[.phone])
        row[.dobClean] = Normalizer.cleanDate(row[.dob])
    }

    // MARK: - dedup

    private func deduplicate(rows: [ApplicantRow])
        -> (rows: [ApplicantRow], duplicateGroups: Int, keep: Int, remove: Int, noPhone: Int) {

        // Step 1: group row indices by phone key
        var groups: [String: [Int]] = [:]
        var noPhone = 0
        for (i, row) in rows.enumerated() {
            let key = Normalizer.phoneKey(row[.phone])
            if key.isEmpty {
                noPhone += 1
                continue
            }
            groups[key, default: []].append(i)
        }

        // Step 2: copy rows so we can annotate the dup flag
        var out = rows

        // Channel priority for which duplicate to KEEP.
        // 일반지원 carries the richest record, so it wins over 간편지원.
        func priority(_ channelRaw: String) -> Int {
            switch channelRaw {
            case Channel.general.rawValue: return 0
            case Channel.simple.rawValue: return 1
            default: return 2
            }
        }

        var duplicateGroups = 0
        var keep = 0
        var remove = 0

        for (_, indices) in groups where indices.count > 1 {
            duplicateGroups += 1
            // Pick the keeper: lowest channel priority, tie-broken by original order.
            let sorted = indices.sorted {
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

        return (out, duplicateGroups, keep, remove, noPhone)
    }
}
