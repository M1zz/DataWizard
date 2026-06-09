import Foundation

/// One distinct value found in a merged column, with how many rows carry it.
struct DistinctValue: Identifiable {
    var id: String { value }
    let value: String
    let count: Int
}

/// Discovers which merged columns hold categorical values worth unifying
/// (e.g. a 도시 column where some rows say "Seoul" and others "서울"),
/// and the distinct values that land in each across all files.
enum ValueScanner {

    /// Free-text or derived columns — never offered for value unification.
    static let freeText: Set<UnifiedColumn> = [
        .koreanName, .email, .phone, .phoneClean, .dob, .dobClean, .code, .channel, .dupFlag,
        .currentAddress, .selfIntro, .motivation, .essayInitiative, .essayCraft, .essayChallenge,
        .portfolioLinks, .portfolioFile, .cvFile, .coreCompetencies, .submittedAt,
        .major, .school, .schoolCompany, .majorDept, .snsChannel
    ]

    /// A column with more distinct values than this is treated as free-text, not categorical.
    static let maxDistinct = 40

    /// The mapped (un-normalized) value of a unified column for one source row.
    private static func value(_ col: UnifiedColumn, row: [String: String], plan: FilePlan) -> String {
        guard let src = plan.mapping[col], !src.isEmpty else { return "" }
        return (row[src] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Distinct non-empty values for a column across all files, most frequent first.
    static func distinct(_ col: UnifiedColumn, in plans: [FilePlan]) -> [DistinctValue] {
        var counts: [String: Int] = [:]
        for plan in plans where !(plan.mapping[col] ?? "").isEmpty {
            for row in plan.rows {
                let v = value(col, row: row, plan: plan)
                if v.isEmpty { continue }
                counts[v, default: 0] += 1
            }
        }
        return counts
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .map { DistinctValue(value: $0.key, count: $0.value) }
    }

    /// Columns worth a value-unification pass: mapped somewhere, categorical, low-cardinality.
    static func candidates(in plans: [FilePlan]) -> [UnifiedColumn] {
        UnifiedColumn.allCases.filter { col in
            guard !freeText.contains(col) else { return false }
            guard plans.contains(where: { !($0.mapping[col] ?? "").isEmpty }) else { return false }
            let n = distinct(col, in: plans).count
            return n >= 2 && n <= maxDistinct
        }
    }
}

/// Suggests how to collapse value variants onto one canonical form.
enum ValueCanonicalizer {

    /// Built-in synonyms keyed by normalized form, so cross-script variants
    /// ("Seoul" ↔ "서울") and common KO/EN terms collapse together.
    private static let dictionary: [String: String] = [
        "seoul": "서울", "서울": "서울", "서울특별시": "서울", "서울시": "서울",
        "busan": "부산", "부산": "부산", "부산광역시": "부산",
        "incheon": "인천", "인천": "인천", "인천광역시": "인천",
        "daegu": "대구", "대구": "대구", "daejeon": "대전", "대전": "대전",
        "gwangju": "광주", "광주": "광주", "ulsan": "울산", "울산": "울산",
        "sejong": "세종", "세종": "세종",
        "gyeonggi": "경기", "경기": "경기", "경기도": "경기",
        "pohang": "포항", "포항": "포항", "포항시": "포항",
        "jeju": "제주", "제주": "제주", "제주도": "제주",
        "southkorea": "대한민국", "korea": "대한민국", "republicofkorea": "대한민국",
        "한국": "대한민국", "대한민국": "대한민국", "남한": "대한민국",
        "male": "남성", "m": "남성", "남": "남성", "남자": "남성", "남성": "남성",
        "female": "여성", "f": "여성", "여": "여성", "여자": "여성", "여성": "여성",
        "yes": "예", "y": "예", "예": "예", "네": "예", "true": "예",
        "no": "아니오", "n": "아니오", "아니오": "아니오", "아니요": "아니오", "false": "아니오"
    ]

    /// Normalized matching key: lowercased, non-alphanumerics stripped (Hangul kept).
    static func key(_ s: String) -> String {
        String(String.UnicodeScalarView(
            s.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }
        ))
    }

    /// Propose original → canonical for a column's values.
    /// A dictionary hit wins; otherwise variants sharing a normalized key collapse
    /// onto their most frequent spelling.
    static func suggest(_ values: [DistinctValue]) -> [String: String] {
        var representative: [String: DistinctValue] = [:]   // normalized key -> most frequent value
        for v in values {
            let k = key(v.value)
            if let cur = representative[k], cur.count >= v.count { continue }
            representative[k] = v
        }
        var out: [String: String] = [:]
        for v in values {
            let k = key(v.value)
            if let canon = dictionary[k] {
                out[v.value] = canon
            } else if let rep = representative[k] {
                out[v.value] = rep.value
            } else {
                out[v.value] = v.value
            }
        }
        return out
    }
}
