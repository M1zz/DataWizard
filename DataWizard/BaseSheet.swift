import Foundation

/// 자동으로 만들어 주는 일련번호의 모양.
/// 규칙을 따로 적게 하지 않고 **첫 값 하나**로 정한다 — `6F10001`이라고 적으면
/// `6F1` + 4자리, 1번부터라는 뜻이고 다음은 `6F10002`가 된다.
struct KeyPattern: Equatable {
    var prefix: String
    var digits: Int
    var start: Int
    var suffix: String = ""

    static let auto = KeyPattern(prefix: "AUTO-", digits: 4, start: 1)

    init(prefix: String, digits: Int, start: Int, suffix: String = "") {
        self.prefix = prefix
        self.digits = max(1, digits)
        self.start = start
        self.suffix = suffix
    }

    /// 예시 값에서 규칙을 읽어 낸다 (마지막 숫자 덩어리를 번호로 본다).
    /// `6F10001` → 6F1·4자리·1부터, `A-001` → A-·3자리·1부터, `1001` → 4자리·1001부터.
    init?(example: String) {
        let text = example.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let chars = Array(text)
        // 뒤에서부터 숫자 덩어리를 찾는다 (끝에 붙은 글자는 suffix로 둔다).
        var end = chars.count
        while end > 0, !chars[end - 1].isNumber { end -= 1 }
        guard end > 0 else { return nil }
        var begin = end
        while begin > 0, chars[begin - 1].isNumber { begin -= 1 }
        let number = String(chars[begin..<end])
        guard let value = Int(number) else { return nil }
        self.prefix = String(chars[0..<begin])
        self.digits = number.count
        self.start = value
        self.suffix = String(chars[end...])
    }

    /// `offset`번째 값 (0이면 첫 값).
    func value(_ offset: Int) -> String {
        let n = start + offset
        let body = String(n)
        let padded = body.count >= digits ? body
            : String(repeating: "0", count: digits - body.count) + body
        return prefix + padded + suffix
    }

    /// 사람에게 보여 줄 예시 — `6F10001, 6F10002, 6F10003 …`
    var sample: String { (0..<3).map { value($0) }.joined(separator: ", ") + " …" }
}

/// 이미 만들어 둔 통합본 — ‘기존에 만들던 데이터’.
///
/// 헤더 순서와 스키마 밖 컬럼(온테점수·수기 메모 등)까지 원본 그대로 들고 있다가,
/// 이번에 정제한 컬럼의 값만 덮어써서 되돌려준다. 한 번에 73컬럼을 다 끝내지 않고
/// 컬럼 하나씩 이어서 완성해 나가기 위한 기준선이다.
struct BaseSheet {
    var name: String
    var headers: [String]                       // 원본 헤더, 파일에 적힌 순서 그대로
    var rows: [[String: String]]                // 헤더 키 행
    var columnHeader: [UnifiedColumn: String]   // 컬럼 → 이 파일의 실제 헤더 문자열
    /// 키 컬럼으로 합치면서 한 줄로 포갠 행 수 (안내용).
    var mergedByKey = 0
    /// 키가 비어 있어 새로 만들어 준 번호 개수 (안내용).
    var generatedKeys = 0
    /// 각 행이 몇 번째로 올린 파일에서 왔는지 (`stacked`로 만든 시트만).
    /// 미리보기에서 파일마다 색을 달리 보여 주기 위한 것. 사용자가 고른 틀이면 비어 있다.
    var rowOrigins: [Int] = []

    /// 이 파일의 컬럼 — 헤더 순서 그대로.
    /// 고정 스키마가 없어졌으므로 ‘아는 컬럼/모르는 컬럼’ 구분도 없다. 헤더가 곧 컬럼이다.
    var columns: [UnifiedColumn] {
        headers.compactMap { h in
            UnifiedColumn(rawValue: h).flatMap { columnHeader[$0] == h ? $0 : nil }
        }
    }

    func value(_ col: UnifiedColumn, in row: [String: String]) -> String {
        guard let h = columnHeader[col] else { return "" }
        return (row[h] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 기존본 한 행의 위치 표시 (변경 보고서용): Code → Email → 행 N.
    func rowRef(_ row: [String: String], index: Int) -> String {
        let code = value(.code, in: row)
        if !code.isEmpty { return code }
        let email = value(.email, in: row)
        if !email.isEmpty { return email }
        return "행 \(index + 1)"
    }

    /// 이 행을 ApplicantRow로 (미리보기·비교용).
    func applicantRow(_ row: [String: String]) -> ApplicantRow {
        var out = ApplicantRow()
        for (col, header) in columnHeader { out[col] = row[header] ?? "" }
        return out
    }
}

extension BaseSheet {

    /// 이 컬럼에 이미 들어 있는 값들 — 빈 값 제외, 처음 나온 순서.
    /// ‘완성될 틀에는 어떤 값이 들어 있나’를 기준으로 이번 데이터를 견주기 위한 것.
    func distinctValues(_ col: UnifiedColumn, limit: Int = 400) -> [String] {
        guard columnHeader[col] != nil else { return [] }
        var seen = Set<String>()
        var out: [String] = []
        for row in rows {
            let v = value(col, in: row)
            guard !v.isEmpty, seen.insert(v).inserted else { continue }
            out.append(v)
            if out.count >= limit { break }
        }
        return out
    }

    /// 이 컬럼이 ‘정해진 값이 반복되는’ 컬럼처럼 보이는가.
    /// 그럴 때만 틀의 값 목록을 정답지로 쓸 수 있다 — 이름·이메일처럼 행마다 다른
    /// 컬럼에 목록을 들이대면 전부 ‘목록 밖’이 되어 버린다.
    func looksCategorical(_ col: UnifiedColumn, values: [String]? = nil) -> Bool {
        let vals = values ?? distinctValues(col)
        guard !vals.isEmpty, vals.count <= 40 else { return false }
        var filled = 0
        for row in rows where !value(col, in: row).isEmpty { filled += 1 }
        guard filled >= 4, vals.count * 3 <= filled else { return false }
        let avg = vals.reduce(0) { $0 + $1.count } / vals.count
        return avg <= 40
    }
}

/// 기존 통합본 파일을 읽어 `BaseSheet`으로 만든다. 헤더는 최종 스키마 컬럼명과
/// 같은 이름으로 대응시키고, 못 알아본 헤더는 값을 그대로 보존한 채 남겨 둔다.
enum BaseSheetLoader {

    enum LoadError: LocalizedError {
        case noColumns(String)
        case empty(String)

        var errorDescription: String? {
            switch self {
            case .noColumns(let name):
                return "‘\(name)’에서 컬럼 이름(첫 줄)을 찾지 못했어요. 첫 줄이 머리글인 CSV/XLSX인지 확인해 주세요."
            case .empty(let name):
                return "‘\(name)’에 데이터 행이 없어요."
            }
        }
    }

    static func load(url: URL) throws -> BaseSheet {
        let name = url.lastPathComponent
        let table: (headers: [String], rows: [[String: String]])
        if url.pathExtension.lowercased() == "xlsx" {
            // 첫 줄에 파일 제목만 있는 내보내기 파일이 흔하다 — 머리글 줄을 스스로 찾는다.
            let t = try XLSXReader.readTableAutoHeader(at: url)
            table = (t.headers, t.rows)
        } else {
            table = try CSVParser.readTable(at: url)
        }

        // 헤더가 곧 컬럼. 같은 이름이 두 번 나오면 첫 번째만 그 이름을 갖는다
        // (CSVParser가 두 번째부터 "이름 (2)"로 구분해 주므로 실제로는 거의 없다).
        var columnHeader: [UnifiedColumn: String] = [:]
        for h in table.headers {
            guard let col = UnifiedColumn(rawValue: h), columnHeader[col] == nil else { continue }
            columnHeader[col] = h
        }
        guard !columnHeader.isEmpty else { throw LoadError.noColumns(name) }
        guard !table.rows.isEmpty else { throw LoadError.empty(name) }

        return BaseSheet(name: name, headers: table.headers, rows: table.rows,
                         columnHeader: columnHeader)
    }
}

extension BaseSheet {

    /// 올린 파일들을 컬럼 이름으로 맞춰 그대로 이어 붙인 시트 —
    /// ‘아직 아무것도 안 고친 상태의 결과물’이다.
    ///
    /// 같은 이름의 헤더는 자동으로 같은 칸에 들어가고, 그 파일에 없는 컬럼은 빈칸으로
    /// 남는다. 이 시트를 기준선으로 삼으면, 값 정리 결과를 행 순서 그대로 덮어써서
    /// ‘고른 컬럼만 바뀐 합본’을 만들 수 있다.
    /// `template`을 주면 그 컬럼 이름·순서를 먼저 깔고, 파일에만 있는 컬럼을 뒤에 붙인다.
    /// (틀에서 **컬럼명만** 가져오는 흐름 — 틀의 값은 한 줄도 들어오지 않는다.)
    /// `key`를 주면 **같은 키를 가진 행을 한 줄로 포갠다** (파일이 달라도 같은 사람이면 한 줄).
    /// 먼저 들어온 값이 이기고, 빈칸만 뒤 파일 값으로 채운다.
    /// 키가 비어 있는 행에는 `AUTO-0001` 같은 번호를 만들어 넣는다 (그 행도 한 줄로 남는다).
    /// 값 하나를 ‘같은 사람인가’ 비교용으로 다듬는다 — 이메일은 소문자, 전화는 숫자만.
    static func identityKey(_ value: String) -> String {
        let t = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !t.isEmpty else { return "" }
        if t.contains("@") { return "e:" + t }
        let digits = t.filter(\.isNumber)
        if digits.count >= 9 { return "p:" + String(digits.suffix(11)) }
        return "v:" + t
    }

    /// `identity`는 키가 비었을 때 ‘그래도 같은 사람인지’ 가릴 컬럼들 (이메일·전화 등).
    /// 덕분에 키가 없는 파일의 행도 새 줄을 만들지 않고 기존 줄에 붙는다.
    static func stacked(_ plans: [FilePlan], name: String,
                        template: [UnifiedColumn] = [],
                        key: UnifiedColumn? = nil,
                        keyPattern: KeyPattern = .auto,
                        identity: [UnifiedColumn] = []) -> BaseSheet {
        var headers: [String] = []
        var seenHeader = Set<String>()
        for col in template where seenHeader.insert(col.rawValue).inserted {
            headers.append(col.rawValue)
        }
        for plan in plans {
            for h in plan.headers where seenHeader.insert(h).inserted { headers.append(h) }
        }

        var rows: [[String: String]] = []
        var origins: [Int] = []
        var mergedByKey = 0
        var generatedKeys = 0
        var indexByKey: [String: Int] = [:]
        var indexByIdentity: [String: Int] = [:]
        let keyHeader = key.flatMap { k in headers.first { $0 == k.rawValue } }
        rows.reserveCapacity(plans.reduce(0) { $0 + $1.rows.count })

        for (i, plan) in plans.enumerated() {
            for src in plan.rows {
                var row: [String: String] = [:]
                for h in headers { row[h] = src[h] ?? "" }

                guard let key, let keyHeader else {
                    rows.append(row)
                    origins.append(i)
                    continue
                }
                // 이 행의 ‘같은 사람인가’ 표식들 (이메일·전화 등) — 키가 없을 때 쓴다.
                let marks = identity.compactMap { col -> String? in
                    let k = identityKey(plan.compose(col, from: src))
                    return k.isEmpty ? nil : k
                }

                /// 이미 있는 줄에 포갠다 — 빈칸만 채우고 기존 값은 지키지 않는다.
                func mergeInto(_ at: Int) {
                    var merged = rows[at]
                    for h in headers where (merged[h] ?? "").isEmpty {
                        merged[h] = row[h] ?? ""
                    }
                    rows[at] = merged
                    mergedByKey += 1
                    for m in marks where indexByIdentity[m] == nil { indexByIdentity[m] = at }
                }

                func appendRow(_ keyValue: String) {
                    row[keyHeader] = keyValue
                    rows.append(row)
                    origins.append(i)
                    indexByKey[keyValue.lowercased()] = rows.count - 1
                    for m in marks where indexByIdentity[m] == nil { indexByIdentity[m] = rows.count - 1 }
                }

                let value = plan.compose(key, from: src)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty {
                    if let at = indexByKey[value.lowercased()] {
                        row[keyHeader] = value
                        mergeInto(at)
                    } else {
                        appendRow(value)
                    }
                    continue
                }

                // 키가 비었다 — 이메일·전화로 같은 사람을 찾아 그 줄에 붙인다.
                if let at = marks.compactMap({ indexByIdentity[$0] }).first {
                    mergeInto(at)
                    continue
                }
                // 정말 처음 보는 사람일 때만 새 줄 + 새 번호.
                var made = ""
                repeat {
                    made = keyPattern.value(generatedKeys)
                    generatedKeys += 1
                } while indexByKey[made.lowercased()] != nil
                appendRow(made)
            }
        }

        var columnHeader: [UnifiedColumn: String] = [:]
        for h in headers {
            guard let col = UnifiedColumn(rawValue: h), columnHeader[col] == nil else { continue }
            columnHeader[col] = h
        }
        return BaseSheet(name: name, headers: headers, rows: rows,
                         columnHeader: columnHeader,
                         mergedByKey: mergedByKey, generatedKeys: generatedKeys,
                         rowOrigins: origins)
    }
}

/// 기존 통합본 위에 이번에 정제한 컬럼만 덮어쓴 결과.
struct PatchResult {
    var headers: [String]                  // 최종 출력 헤더 (기존 순서 + 이번에 생긴 컬럼)
    var rows: [[String: String]]
    var newRowIndices: Set<Int> = []       // 아래에 새로 붙인 행
    var changedCells: [Int: Set<String>] = [:]   // 행 인덱스 → 값이 바뀐 헤더들
    var columns: [UnifiedColumn] = []      // 이번에 덮어쓴 컬럼
    var matchedRows = 0                    // 새 데이터와 이어붙은 기존 행
    var unmatchedRows = 0                  // 새 데이터에 없어 그대로 둔 기존 행
    var appendedRows = 0                   // 새로 붙인 행
    var changedCellCount = 0
    var keptBlankCount = 0                 // 새 값이 비어 있어 기존 값을 지킨 셀
    var addedColumns: [UnifiedColumn] = [] // 기존본에 없어 새로 만든 컬럼
    var changes: [ChangeRecord] = []
    /// 출력 행마다 어느 새 데이터 행에서 왔는지 (-1 = 짝이 없어 기존 값 그대로).
    /// 미리보기에서 ‘이 줄은 어느 파일에서 온 값인가’를 색으로 보여 주는 데 쓴다.
    var sourceRows: [Int] = []
}

/// 기존 행과 새 행을 어떻게 짝지을지.
enum RowMatch {
    /// 같은 파일을 그대로 고치는 유틸 모드 — 행 순서가 그대로 대응한다.
    /// Code·전화·이메일 컬럼이 아예 없는 파일도 안전하게 다룰 수 있다.
    case position
    /// 다른 파일에서 온 데이터를 이어붙일 때 — Code → 전화번호 → 이메일 순으로 찾는다.
    case key
    /// 사용자가 고른 컬럼 값이 같은 행끼리 짝짓는다.
    /// Code·전화·이메일이 없는 파일(사번·주문번호·학번 등)을 위한 길.
    case column(UnifiedColumn)
}

/// 새로 정제한 행들을 기존 통합본에 이어붙인다.
///
/// 매칭은 Code → 전화번호 → 이메일 순. 매칭된 기존 행에는 `columns`에 고른 컬럼의
/// 값만 덮어쓰고, 나머지 컬럼·수기 입력 값은 손대지 않는다. 새 값이 비어 있으면
/// 기존 값을 지운다는 뜻이 아니므로 그대로 둔다 (`keptBlankCount`로 보고).
enum PatchEngine {

    static let markerHeader = "이어붙임"
    static let markerValue = "신규"
    private static let removedFlag = "중복 - 삭제"

    static func apply(base: BaseSheet,
                      merged: [ApplicantRow],
                      generatedCodes: Set<String>,
                      columns: [UnifiedColumn],
                      appendNewRows: Bool,
                      markNewRows: Bool,
                      match: RowMatch = .key) -> PatchResult {

        // ---- 출력 헤더: 기존 순서를 지키고, 없던 컬럼만 뒤에 붙인다 ----
        var columnHeader = base.columnHeader
        var headers = base.headers
        var added: [UnifiedColumn] = []
        for col in columns where columnHeader[col] == nil {
            columnHeader[col] = col.rawValue
            headers.append(col.rawValue)
            added.append(col)
        }

        // ---- 새 데이터 색인: 중복 삭제 행은 뒤로 미뤄 Keep 행이 우선 잡히게 ----
        var byCode: [String: Int] = [:]
        var byPhone: [String: Int] = [:]
        var byEmail: [String: Int] = [:]
        var byColumn: [String: Int] = [:]
        let order = merged.indices.sorted { a, b in
            let da = merged[a][.dupFlag] == removedFlag
            let db = merged[b][.dupFlag] == removedFlag
            return da == db ? a < b : !da
        }
        for i in order {
            // 도구가 만들어 낸 Unique ID(6F1…)는 파일 구성이 바뀌면 번호가 밀리므로
            // 매칭 키에서 제외한다 — 엉뚱한 사람에게 값이 붙는 사고를 막기 위해.
            let code = merged[i][.code].trimmingCharacters(in: .whitespacesAndNewlines)
            if !code.isEmpty, !generatedCodes.contains(code), byCode[code] == nil { byCode[code] = i }
            let phone = Normalizer.phoneKey(merged[i][.phone])
            if !phone.isEmpty, byPhone[phone] == nil { byPhone[phone] = i }
            let email = merged[i][.email].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if !email.isEmpty, byEmail[email] == nil { byEmail[email] = i }
            if case .column(let c) = match {
                let key = merged[i][c].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if !key.isEmpty, byColumn[key] == nil { byColumn[key] = i }
            }
        }

        var out = base.rows
        // 새로 만든 컬럼은 모든 기존 행에 빈 칸으로 자리를 잡아 둔다 (짝을 못 찾은 행 포함).
        for col in added {
            guard let h = columnHeader[col] else { continue }
            for i in out.indices where out[i][h] == nil { out[i][h] = "" }
        }
        var result = PatchResult(headers: headers, rows: [], columns: columns, addedColumns: added)
        var consumed = Set<Int>()
        var sourceRows = Array(repeating: -1, count: base.rows.count)

        /// 기존 행 하나의 짝을 찾는다.
        func partner(of brow: [String: String], at bi: Int) -> Int? {
            switch match {
            case .position:
                return bi < merged.count ? bi : nil
            case .column(let c):
                let key = base.value(c, in: brow).lowercased()
                return key.isEmpty ? nil : byColumn[key]
            case .key:
                break
            }
            var hit: Int?
            let code = base.value(.code, in: brow)
            if !code.isEmpty, !generatedCodes.contains(code) { hit = byCode[code] }
            if hit == nil {
                let phone = Normalizer.phoneKey(base.value(.phone, in: brow))
                if !phone.isEmpty { hit = byPhone[phone] }
            }
            if hit == nil {
                let email = base.value(.email, in: brow).lowercased()
                if !email.isEmpty { hit = byEmail[email] }
            }
            return hit
        }

        // ---- 기존 행마다: 짝을 찾아 고른 컬럼만 덮어쓴다 ----
        for (bi, brow) in base.rows.enumerated() {
            guard let m = partner(of: brow, at: bi) else { result.unmatchedRows += 1; continue }
            consumed.insert(m)
            sourceRows[bi] = m
            result.matchedRows += 1

            let ref = base.rowRef(brow, index: bi)
            for col in columns {
                guard let header = columnHeader[col] else { continue }
                let before = (brow[header] ?? "")
                let after = merged[m][col]
                if after.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    if !before.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        result.keptBlankCount += 1
                    }
                    continue
                }
                if after == before { continue }
                out[bi][header] = after
                result.changedCells[bi, default: []].insert(header)
                result.changedCellCount += 1
                result.changes.append(ChangeRecord(file: base.name, ref: ref, column: col,
                                                   before: before, after: after))
            }
        }

        // ---- 기존본에 없던 사람: 맨 아래에 붙이고 ‘신규’로 표시 ----
        if appendNewRows {
            for i in merged.indices
            where !consumed.contains(i) && merged[i][.dupFlag] != removedFlag {
                var row: [String: String] = [:]
                for h in headers { row[h] = "" }
                // 새 사람이므로 알고 있는 스키마 값은 전부 채운다 (고른 컬럼만이 아니라).
                for (col, header) in columnHeader { row[header] = merged[i][col] }
                if markNewRows { row[markerHeader] = markerValue }
                result.newRowIndices.insert(out.count)
                out.append(row)
                sourceRows.append(i)
                result.appendedRows += 1
            }
        }

        if markNewRows && result.appendedRows > 0 && !headers.contains(markerHeader) {
            headers.append(markerHeader)
            result.headers = headers
        }
        result.rows = out
        result.sourceRows = sourceRows
        return result
    }

    /// 출력용 2차원 배열 (헤더 순서대로).
    static func table(_ patch: PatchResult) -> [[String]] {
        patch.rows.map { row in patch.headers.map { row[$0] ?? "" } }
    }
}


/// 유틸 모드: 파일 하나의 값에 ‘값 통일’만 적용해 돌려준다.
///
/// 병합·중복 판정·파생 컬럼 생성이 전혀 없다 — 넣은 파일의 행이 그 순서 그대로
/// 나온다. 아카데미 통합본을 만들 때 쓰는 `MergeEngine` 과 달리, 아무 CSV에나
/// 걸어도 원본을 건드리지 않는 게 목적이다.
enum ValueApplier {

    /// 파일 여러 개를 올린 순서 그대로 이어 붙인다 — `BaseSheet.stacked` 와 같은 순서라
    /// 행 번호로 짝지어 제자리에 덮어쓸 수 있다.
    static func run(plans: [FilePlan],
                    valueMap: [UnifiedColumn: [String: String]])
        -> (rows: [ApplicantRow], changes: [ChangeRecord]) {
        var rows: [ApplicantRow] = []
        var changes: [ChangeRecord] = []
        for plan in plans {
            let r = run(plan: plan, valueMap: valueMap)
            rows += r.rows
            changes += r.changes
        }
        return (rows, changes)
    }

    /// - Returns: 통일 값이 적용된 행들과, 실제로 바뀐 셀의 내역.
    static func run(plan: FilePlan,
                    valueMap: [UnifiedColumn: [String: String]])
        -> (rows: [ApplicantRow], changes: [ChangeRecord]) {

        var out: [ApplicantRow] = []
        var changes: [ChangeRecord] = []
        out.reserveCapacity(plan.rows.count)

        for (i, src) in plan.rows.enumerated() {
            var row = ApplicantRow()
            for col in plan.sources.keys {
                var value = plan.compose(col, from: src)
                if let canonical = valueMap[col]?[value], canonical != value {
                    changes.append(ChangeRecord(file: plan.fileName,
                                                ref: plan.rowRef(src, index: i),
                                                column: col,
                                                before: value, after: canonical))
                    value = canonical
                }
                row[col] = value
            }
            out.append(row)
        }
        return (out, changes)
    }
}
