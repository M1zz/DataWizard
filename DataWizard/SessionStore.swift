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

    struct FileSnapshot: Codable {
        var path: String
        var channel: String                  // Channel.rawValue
        var headers: [String]
        var rows: [[String: String]]
        var sources: [String: [String]]      // UnifiedColumn.rawValue → source headers
        var separators: [String: String]
    }

    /// Short human summary for the resume card.
    var summary: String {
        let stageName: String
        switch stage {
        case "columns": stageName = "컬럼 고르기"
        case "review":  stageName = "값 검토"
        default:        stageName = "파일 추가"
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
