import Foundation

/// A resumable snapshot of the whole working session — the parsed files plus
/// every decision the user has made so far. We persist the *parsed* rows (not
/// just file paths) so resuming never has to re-open the originals: the sandbox
/// can't re-access user-picked files after relaunch without security-scoped
/// bookmarks, and keeping the data means "멈췄다 이어서" works even if the source
/// files were moved or deleted.
struct SessionSnapshot: Codable {
    var savedAt: Date
    var stage: String                        // "files" | "columns" | "review"
    var phoneTemplate: String
    var includedColumns: [String]            // UnifiedColumn.rawValue
    var checked: [String]
    var valueMap: [String: [String: String]] // column rawValue → (원본 → 통일)
    var allowedValues: [String: [String]]
    // 사용자가 지정한 컬럼 타입/포맷 (옵셔널 — 이전 버전 세션도 그대로 복원).
    var typeOverride: [String: String]?      // column rawValue → ColumnType.rawValue
    var formatChoice: [String: String]?      // column rawValue → FormatPreset.rawValue
    var customFormat: [String: String]?      // column rawValue → 사용자 정규식
    var referenceName: String?
    var referenceColumns: [String]
    var referenceUnmatched: [String]
    var files: [FileSnapshot]
    // 부분 정제(기존 통합본에 이어붙이기) 상태 — 옵셔널이라 이전 버전 세션도 그대로 열린다.
    var columnMode: String?                  // "withTemplate" | "fromScratch" | "patchBase"
    var focusColumns: [String]?              // 이번에 정제하기로 고른 컬럼
    var base: BaseSnapshot?                  // 기준으로 삼은 기존 통합본 (값까지)
    /// 그 기준본이 사용자가 직접 고른 ‘틀’인가 (아니면 올린 파일을 이어 붙인 시트).
    /// 옵셔널 — 이전 버전 세션은 false로 열린다.
    var baseIsUserFile: Bool?
    /// 틀과 이번 데이터를 짝지을 컬럼 (nil이면 Code→전화→이메일 자동).
    var matchColumn: String?
    /// 컬럼 이름만 빌려 온 틀 (값은 안 가져옴).
    var templateName: String?
    var templateColumns: [String]?
    /// 여러 파일을 합칠 때 ‘같은 행’을 가리는 키 컬럼.
    var keyColumn: String?
    /// 키가 비었을 때 만들어 줄 번호의 첫 값 (예: 6F10001).
    var keyPattern: String?
    /// 사람이 ‘확정’으로 표시한 행들 (행 이름표).
    var confirmedRows: [String]?
    /// 사용자가 직접 지운 행 (`파일#줄`).
    var deletedRows: [String]?
    /// 행을 거르는 기준 컬럼과 남길 값들.
    var filterColumn: String?
    var filterKeep: [String]?
    /// 틀의 빈 칸을 만들어 채우는 규칙 (컬럼 → `fixed:값` 또는 `serial:첫번호`).
    var generatedColumns: [String: String]?
    /// 이 세션이 ‘시트에서 숨긴 행은 안 읽는’ 규칙으로 만들어졌는가.
    /// (이전 세션은 숨긴 행까지 들어 있을 수 있어 구분이 필요하다.)
    var hiddenRowsAware: Bool?

    struct FileSnapshot: Codable {
        var path: String
        var channel: String                  // Channel.rawValue
        var headers: [String]
        var rows: [[String: String]]
        var sources: [String: [String]]      // UnifiedColumn.rawValue → source headers
        var separators: [String: String]
        /// 유틸 모드(파일 하나 그대로 고치기)로 만든 계획인가. 옵셔널 — 이전 세션도 열린다.
        var passthrough: Bool?
        /// 시트에서 숨겨져 있어 안 읽은 행 수 — 되살릴 때도 그대로 알려 줘야 한다.
        var hiddenRowsSkipped: Int?
        var includesHiddenRows: Bool?
        /// 컬럼마다 ‘어떻게 합칠지’ (`join` | `first`). 없으면 이어 붙이기.
        var combine: [String: String]?
    }

    /// 기존 통합본을 값까지 통째로 저장 — 원본 파일에 다시 접근하지 않아도
    /// 이어붙이기 작업을 그대로 복원할 수 있게.
    struct BaseSnapshot: Codable {
        var name: String
        var headers: [String]
        var rows: [[String: String]]
        var columnHeader: [String: String]   // 컬럼 이름 → 파일의 헤더 문자열
        /// 행마다 몇 번째 파일에서 왔는지 (미리보기 색). 옵셔널 — 이전 세션도 열린다.
        var rowOrigins: [Int]?
    }

    /// Short human summary for the resume card.
    var summary: String {
        let stageName: String
        switch stage {
        case "work":    stageName = "컬럼 고르기"
        case "columns": stageName = "컬럼 고르기"
        case "focus":   stageName = "정제할 컬럼 고르기"
        case "review":  stageName = "값 검토"
        default:        stageName = "파일 추가"
        }
        if let base {
            return "파일 \(files.count)개 · 기존본 ‘\(base.name)’에 이어붙이기 · \(stageName) 단계"
        }
        return "파일 \(files.count)개 · \(stageName) 단계"
    }
}

/// Reads and writes the single resumable session to Application Support.
/// (Inside the sandbox container — no extra entitlement needed.)
enum SessionStore {

    private static var fileURL: URL? {
        let fm = FileManager.default
        guard let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        else { return nil }
        let dir = base.appendingPathComponent("DataWizard", isDirectory: true)
        if !fm.fileExists(atPath: dir.path) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir.appendingPathComponent("session.json")
    }

    /// Persist a snapshot. Encoding runs on the caller's queue; keep it off the
    /// main thread for large files.
    static func save(_ snapshot: SessionSnapshot) {
        guard let url = fileURL else { return }
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(snapshot) else { return }
        try? data.write(to: url, options: .atomic)
    }

    /// Load the saved snapshot, or nil if none exists / it can't be read.
    static func load() -> SessionSnapshot? {
        guard let url = fileURL, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(SessionSnapshot.self, from: data)
    }

    static func clear() {
        guard let url = fileURL else { return }
        try? FileManager.default.removeItem(at: url)
    }

    static var hasSaved: Bool {
        guard let url = fileURL else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }
}

/// 컬럼을 키로 쓰는 표를 세션에 담고 꺼낼 때 쓰는 변환.
/// 세션을 만들고 되살리는 코드에 `Dictionary(uniqueKeysWithValues:)`가
/// 스무 번 넘게 반복되던 것을 한 군데로 모았다.
enum ColumnCoding {

    // MARK: 담기 (컬럼 → 글자 키)

    static func encode<V>(_ map: [UnifiedColumn: V]) -> [String: V] {
        Dictionary(uniqueKeysWithValues: map.map { ($0.key.rawValue, $0.value) })
    }

    static func encode<V: RawRepresentable>(_ map: [UnifiedColumn: V]) -> [String: V.RawValue] {
        Dictionary(uniqueKeysWithValues: map.map { ($0.key.rawValue, $0.value.rawValue) })
    }

    static func encode(_ columns: [UnifiedColumn]) -> [String] { columns.map(\.rawValue) }
    static func encode(_ columns: Set<UnifiedColumn>) -> [String] { columns.map(\.rawValue) }

    // MARK: 꺼내기 (글자 키 → 컬럼)

    /// 이름을 컬럼으로 되돌리지 못하는 항목은 조용히 버린다 (예전 세션 호환).
    static func decode<V>(_ map: [String: V]?) -> [UnifiedColumn: V] {
        Dictionary(uniqueKeysWithValues: (map ?? [:]).compactMap { key, value in
            UnifiedColumn(rawValue: key).map { ($0, value) }
        })
    }

    static func decode<V: RawRepresentable>(_ map: [String: V.RawValue]?,
                                            as type: V.Type) -> [UnifiedColumn: V] {
        Dictionary(uniqueKeysWithValues: (map ?? [:]).compactMap { key, raw in
            guard let col = UnifiedColumn(rawValue: key), let v = V(rawValue: raw) else { return nil }
            return (col, v)
        })
    }

    static func decode(_ names: [String]?) -> [UnifiedColumn] {
        (names ?? []).compactMap { UnifiedColumn(rawValue: $0) }
    }

    static func decodeSet(_ names: [String]?) -> Set<UnifiedColumn> { Set(decode(names)) }
}
