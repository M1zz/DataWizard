import SwiftUI
import UniformTypeIdentifiers

// 완성본 미리보기 창 — 표를 그리고, 거기서 바로 고치고 채우는 작업대.

/// 미리보기에서 컬럼 머리글에 색으로 드러내는 ‘이 컬럼 작업이 끝났나’ 상태.
/// 검토 화면의 뱃지(⚠️ 결정 필요 / ✅ 확정 / ✅ 해결됨)와 같은 판정을 쓴다.
enum ColumnWorkStatus {
    case needsWork(Int)   // 아직 결정하지 못한 값이 N종 남음
    case confirmed        // 사용자가 ‘이대로 확정’까지 체크함
    case resolved         // 결정거리는 있었지만 다 해결됨 (확정 전)
    case nothingToDo      // 애초에 판단할 게 없던 컬럼 (파생·처음부터 깨끗함)

    var needsWork: Bool { if case .needsWork = self { return true }; return false }

    var icon: String {
        switch self {
        case .needsWork:   return "exclamationmark.triangle.fill"
        case .confirmed:   return "checkmark.circle.fill"
        case .resolved:    return "checkmark.circle"
        case .nothingToDo: return "minus.circle"
        }
    }
    var tint: Color {
        switch self {
        case .needsWork:            return .orange
        case .confirmed, .resolved: return .green
        case .nothingToDo:          return .secondary
        }
    }
    /// 머리글 이름 옆에 붙는 남은 건수 (해결된 컬럼엔 없음).
    var badge: String? {
        if case .needsWork(let n) = self { return "\(n)" }
        return nil
    }
    var help: String {
        switch self {
        case .needsWork(let n): return "더 작업이 필요해요 — 아직 결정하지 못한 값 \(n)종"
        case .confirmed:        return "작업 완료 — ‘이대로 확정’까지 체크한 컬럼"
        case .resolved:         return "남은 결정 없음 — 아직 ‘이대로 확정’은 누르지 않았어요"
        case .nothingToDo:      return "손댈 값이 없던 컬럼"
        }
    }


}

/// 표가 가로로 얼마나 밀렸는지.
/// 값을 **따로 기억해 두지 않는다** — 표를 다시 만들면 스크롤이 0으로 돌아가는데
/// 기억해 둔 값은 그대로라, 컬럼을 화면 밖에 그리고 표가 텅 비어 보였다.
/// 그릴 때마다 스크롤뷰에 직접 물어본다.
final class TableScroll: ObservableObject {
    weak var clip: NSClipView?
    /// 스크롤이 움직였다는 신호 (이 값이 바뀌면 다시 그린다).
    @Published var tick = 0

    var offsetX: CGFloat { clip?.bounds.origin.x ?? 0 }
    /// 스크롤뷰를 못 찾았으면 구간을 좁히지 않는다 (컬럼이 사라지는 것보다 느린 게 낫다).
    var known: Bool { clip != nil }
}

/// 표가 들어 있는 NSScrollView를 찾아 `TableScroll`에 이어 준다.
struct ScrollOffsetReader: NSViewRepresentable {
    let scroll: TableScroll

    final class Coordinator {
        var token: NSObjectProtocol?
        weak var observed: NSClipView?
        deinit { if let token { NotificationCenter.default.removeObserver(token) } }
    }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async { attach(view, context.coordinator) }
        return view
    }

    /// 표가 다시 만들어지면 스크롤뷰도 새것으로 바뀔 수 있다 — 그릴 때마다 다시 확인한다.
    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { attach(nsView, context.coordinator) }
    }

    private func attach(_ view: NSView, _ coordinator: Coordinator) {
        guard let clip = view.enclosingScrollView?.contentView else { return }
        guard coordinator.observed !== clip else { return }
        if let token = coordinator.token { NotificationCenter.default.removeObserver(token) }
        clip.postsBoundsChangedNotifications = true
        coordinator.observed = clip
        scroll.clip = clip
        coordinator.token = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification, object: clip, queue: .main
        ) { [weak scroll] _ in scroll?.tick &+= 1 }
        scroll.tick &+= 1
    }
}

/// Shared state for the standalone preview window. ContentView writes into it
/// on every cleaning action; the window observes and re-renders live.
final class PreviewModel: ObservableObject {
    static let shared = PreviewModel()

    @Published var rows: [ApplicantRow] = []           // 현재 상태로 합쳐진 행들
    @Published var baselineRows: [ApplicantRow] = []   // 정리 전 병합본 (비교 기준)
    @Published var diff: [Int: Set<UnifiedColumn>] = [:]  // row index → 개선된 컬럼
    @Published var diffCount = 0
    @Published var columns: [UnifiedColumn] = []
    @Published var checked: Set<UnifiedColumn> = []
    // 지금 검토 카드를 펼쳐 놓은 컬럼 — 미리보기에서 그 열을 강조해,
    // ‘확정’을 누르기 전에도 어느 셀을 만지고 있는지 보이게 한다.
    @Published var focused: UnifiedColumn?
    // 컬럼별 미해결 결정 종 수 (0이면 키 없음) — 검토 화면의 openCount와 같은 값.
    @Published var openCounts: [UnifiedColumn: Int] = [:]
    // 사람이 판단할 거리가 있었던 컬럼들 — ‘해결됨’과 ‘볼 것도 없었음’을 가른다.
    @Published var decisionColumns: Set<UnifiedColumn> = []
    // 행마다 어느 파일에서 왔는지 (-1 = 이번에 새로 붙인 행). 비어 있으면 색 표시 안 함.
    @Published var rowFiles: [Int] = []
    @Published var fileNames: [String] = []
    // 아직 한 칸으로 합쳐지지 않은 컬럼(일부 파일에만 있음)과 그 짝 후보.
    @Published var splitColumns: Set<UnifiedColumn> = []
    @Published var pairHints: [UnifiedColumn: String] = [:]
    // 컬럼마다 어느 파일에 들어 있는지 (파일 순번) — 열 배경색·점 표시에 쓴다.
    @Published var columnOwners: [UnifiedColumn: [Int]] = [:]
    /// 값이 하나도 없는 컬럼 — 머리글에 ‘비어 있음’으로 알려 준다.
    @Published var emptyColumns: Set<UnifiedColumn> = []
    /// 틀에 없는 컬럼 — 결과에는 들어가지만 ‘틀 밖’이라고 알려 준다.
    /// 없앨 대상이 아니라 **틀 안을 채울 재료**다.
    @Published var extraColumns: Set<UnifiedColumn> = []
    /// 틀 안 컬럼과, 그 컬럼에 아직 비어 있는 행 수 — 이 도구의 목표가 이 숫자를 0으로 만드는 것.
    @Published var templateSet: Set<UnifiedColumn> = []
    @Published var holeCounts: [UnifiedColumn: Int] = [:]
    /// 틀이 정한 컬럼 순서 — 표에서 틀 안 컬럼을 이 순서대로 **왼쪽에 먼저** 세운다.
    @Published var templateOrder: [UnifiedColumn] = []
    /// 틀을 쓰고 있는가 (틀 밖 표시를 켤지).
    @Published var usingTemplate = false
    // 미리보기 창에서 고른 컬럼과, 메인 창에 보내는 요청.
    @Published var selection: Set<UnifiedColumn> = []
    @Published var request: PreviewRequest?

    /// 미리보기 창이 메인 창에 시키는 일.
    enum PreviewRequest: Equatable {
        case clean([UnifiedColumn])                 // 고른 컬럼 정리하러 가기
        case merge(UnifiedColumn, UnifiedColumn)    // 두 컬럼을 한 칸으로
        case edit(UnifiedColumn, String, String)    // 컬럼 · 이전 값 · 새 값
        case confirmRow(String, Bool)               // 행 이름표 · 확정 여부
        case confirmRows([String], Bool)           // 여러 행을 한 번에 확정 / 해제
        case fill(UnifiedColumn)                    // 이 칸 채우기 (어디서 → 어떻게)
        /// 여러 컬럼을 골라 ‘데이터 정리하기’를 눌렀을 때 — 틀 안의 칸을 기준으로
        /// 어느 컬럼에서 값을 가져올지 먼저 묻는다.
        case fillFrom([UnifiedColumn])
        /// 이 컬럼의 값을 통째로 다른 컬럼으로 옮기기.
        case move(UnifiedColumn)
    }

    /// 사용자가 고른 틀 이름 (있으면 그 파일에서 온 행임을 이름으로 보여 준다).
    @Published var baseName = ""
    /// 이번에 새로 붙인 행 (틀에 없던 사람).
    @Published var newRows: Set<Int> = []
    /// 행마다의 이름표 (키 값 등) — 행 순서가 바뀌어도 ‘확정’ 표시가 따라가게.
    @Published var rowKeys: [String] = []
    /// 사람이 ‘확정’으로 표시한 행들.
    @Published var confirmedRows: Set<String> = []
    /// 중복으로 보이는 행 (지운 게 아니라 표시만).
    @Published var duplicateRows: Set<Int> = []
    /// 중복 행 → 앞서 나온 같은 사람의 행 번호.
    @Published var duplicateOf: [Int: Int] = [:]
    /// 값 정리가 바꾼 셀들 (이전 → 이후).
    @Published var changes: [ChangeRecord] = []
    /// 작업대에 띄울 ‘지금 할 일’ 한 줄과, 그 일이 가리키는 칸.
    @Published var nextHint = ""
    @Published var nextColumn: UnifiedColumn?
    /// 창을 열 때 중복만 보여 줄지.
    @Published var showDuplicatesOnly = false
    /// 지금 결과를 다시 만드는 중인가 (백그라운드).
    @Published var isBuilding = false

    /// 백그라운드에서 만들어 온 결과를 한 번에 반영한다.
    func apply(_ p: PreviewPayload) {
        rows = p.rows
        if !p.baselineRows.isEmpty { baselineRows = p.baselineRows }
        diff = p.diff
        diffCount = p.diffCount
        columns = p.columns
        rowFiles = p.rowFiles
        rowKeys = p.rowKeys
        newRows = p.newRows
        duplicateRows = p.duplicateRows
        duplicateOf = p.duplicateOf
        baseName = p.baseName
        changes = p.changes
        isBuilding = false
    }

    func rowKey(_ i: Int) -> String { i < rowKeys.count ? rowKeys[i] : "행 \(i + 1)" }
    func isConfirmed(_ i: Int) -> Bool { confirmedRows.contains(rowKey(i)) }

    /// 사용자가 ‘완성본 미리보기’ 버튼을 눌러 연 창인가.
    /// 앱을 켤 때 시스템이 창을 복원해도 이 값이 false면 스스로 닫는다.
    var openedByUser = false

    /// 올린 순서대로 도는 파일 색 — 첫 화면 파일 칩·미리보기가 같은 색을 쓴다.
    static let filePalette: [Color] = [.blue, .green, .orange, .purple, .pink, .teal]
    static func paletteColor(_ index: Int) -> Color {
        filePalette[((index % filePalette.count) + filePalette.count) % filePalette.count]
    }

    /// 한 파일에서만 온 컬럼이면 그 파일 색 — 열 배경으로 출처를 보여 준다.
    func ownerTint(_ c: UnifiedColumn) -> Color? {
        guard fileNames.count > 1, let o = columnOwners[c], o.count == 1, o[0] >= 0 else { return nil }
        return Self.paletteColor(o[0])
    }

    /// 이 행이 온 파일의 색 (모르면 nil).
    func fileTint(row i: Int) -> Color? {
        guard i < rowFiles.count else { return nil }
        let f = rowFiles[i]
        return f >= 0 ? Self.paletteColor(f) : nil
    }

    func fileLabel(row i: Int) -> String {
        guard i < rowFiles.count else { return "" }
        let f = rowFiles[i]
        guard f >= 0 else {
            // 올린 파일에서 온 게 아닌 줄 — 틀에 원래 있던 행이거나, 출처를 모르는 행.
            if newRows.contains(i) { return baseName.isEmpty ? "이번에 추가" : "틀에 없던 사람" }
            return baseName.isEmpty ? "출처 모름" : baseName
        }
        return f < fileNames.count ? fileNames[f] : "파일 \(f + 1)"
    }

    /// 이 줄이 어디서 온 데이터인지 한 문장으로 (툴팁).
    func rowOriginHelp(row i: Int) -> String {
        guard i < rowFiles.count else { return "" }
        let f = rowFiles[i]
        let from = f >= 0 && f < fileNames.count ? fileNames[f] : ""
        if f < 0 {
            return baseName.isEmpty
                ? "\(i + 1)행 — 새로 붙인 행"
                : "\(i + 1)행 · 틀 ‘\(baseName)’의 행 — 이번 데이터에 짝이 없어 그대로 뒀습니다."
        }
        if newRows.contains(i) {
            return "\(i + 1)행 · ‘\(from)’에서 새로 붙인 행"
        }
        return baseName.isEmpty
            ? "\(i + 1)행 · ‘\(from)’에서 온 행"
            : "\(i + 1)행 · 틀 ‘\(baseName)’의 행 — ‘\(from)’의 값으로 채웠습니다."
    }

    /// 줄 머리에 붙는 짧은 꼬리표 (`신규` / `틀`).
    func rowBadge(row i: Int) -> String? {
        guard i < rowFiles.count else { return nil }
        if newRows.contains(i) { return "신규" }
        if rowFiles[i] < 0 && !baseName.isEmpty { return "틀" }
        return nil
    }

    /// ‘이대로 확정’이 미해결보다 앞선다 — 검토 화면의 isResolved(체크했으면 끝)와
    /// 같은 순서라, 미리보기에서 초록인데 병합이 막히는 일이 없다.
    func status(_ c: UnifiedColumn) -> ColumnWorkStatus {
        if checked.contains(c) { return .confirmed }
        if let n = openCounts[c], n > 0 { return .needsWork(n) }
        return decisionColumns.contains(c) ? .resolved : .nothingToDo
    }

    var needsWorkColumns: [UnifiedColumn] { columns.filter { status($0).needsWork } }
    var confirmedColumns: [UnifiedColumn] { columns.filter { checked.contains($0) } }

    /// 틀 안 컬럼을 **틀이 정한 순서대로 왼쪽에** 세우고, 틀 밖(재료)은 그 뒤로 민다.
    /// 파일 세 개의 컬럼이 합집합으로 늘어서도 완성될 표의 모양이 먼저 보이게.
    func templateFirst(_ cols: [UnifiedColumn]) -> [UnifiedColumn] {
        guard usingTemplate, !templateOrder.isEmpty else { return cols }
        var rank: [UnifiedColumn: Int] = [:]
        for (i, c) in templateOrder.enumerated() { rank[c] = i }
        return cols.enumerated().sorted { a, b in
            let ra = rank[a.element], rb = rank[b.element]
            switch (ra, rb) {
            case let (x?, y?): return x == y ? a.offset < b.offset : x < y
            case (_?, nil):    return true
            case (nil, _?):    return false
            default:           return a.offset < b.offset
            }
        }.map(\.element)
    }

    /// 컬럼을 세 갈래로 나눈다 — 색이 이 갈래를 그대로 나타낸다.
    /// 여러 파일의 컬럼이 합집합으로 늘어서 있어도, 무엇이 목표인지 한눈에 보이게.
    enum ColumnKind { case templateFilled, templateHole, outside }
    func kind(_ c: UnifiedColumn) -> ColumnKind {
        guard usingTemplate else { return .templateFilled }
        if !templateSet.contains(c) { return .outside }
        return (holeCounts[c] ?? 0) > 0 ? .templateHole : .templateFilled
    }

    /// 갈래별 색 — 파랑 = 틀 안인데 아직 빈 행이 있음(할 일), 초록 = 틀 안 다 참,
    /// 회색 = 틀 밖(재료).
    func kindTint(_ c: UnifiedColumn) -> Color {
        switch kind(c) {
        case .templateHole:   return .accentColor
        case .templateFilled: return .green
        case .outside:        return .secondary
        }
    }

    /// 셀 한 칸의 배경색. 컬럼 상태가 열 전체로 내려와 세로줄로 읽히게 합니다.
    /// 확정한 컬럼은 사람이 손봐서 끝낸 열이므로 초록으로 채웁니다.
    func cellTint(_ c: UnifiedColumn, improved: Bool) -> Color {
        switch status(c) {
        case .confirmed:            return .green.opacity(improved ? 0.16 : 0.10)
        case .needsWork:            return .orange.opacity(improved ? 0.12 : 0.06)
        case .resolved, .nothingToDo:
            if improved { return .accentColor.opacity(0.10) }
            guard usingTemplate else { return .clear }
            // 갈래를 열 전체에 아주 옅게 깔아 준다 — 어느 열이 틀 안이고 밖인지 구분되게.
            switch kind(c) {
            case .templateHole:   return .accentColor.opacity(0.03)
            case .templateFilled: return .green.opacity(0.04)
            case .outside:        return .secondary.opacity(0.07)
            }
        }
    }

    func reset() {
        rows = []; baselineRows = []; diff = [:]; diffCount = 0
        columns = []; checked = []
        rowFiles = []; fileNames = []
        splitColumns = []; pairHints = [:]; columnOwners = [:]; baseName = ""; newRows = []
        emptyColumns = []; extraColumns = []; usingTemplate = false
        templateSet = []; holeCounts = [:]; templateOrder = []
        rowKeys = []; duplicateRows = []; duplicateOf = [:]
        showDuplicatesOnly = false
        selection = []; request = nil
        openCounts = [:]; decisionColumns = []
        focused = nil
    }
}

/// 이 창은 앱을 껐다 켤 때 되살아나지 않게 표시해 둔다 (버튼으로만 열리도록).
struct NonRestorableWindow: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let v = NSView(frame: .zero)
        DispatchQueue.main.async { v.window?.isRestorable = false }
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { nsView.window?.isRestorable = false }
    }
}

/// Standalone window: the merged file as it currently stands — all final
/// columns, improved cells highlighted, OK'd columns checked. Updates live
/// while the user cleans data in the main window.
struct PreviewWindowView: View {
    /// 앱 화면 안에 끼워 넣은 것인가 (별도 창이 아니라).
    var embedded = false
    @ObservedObject var model = PreviewModel.shared
    @State private var query = ""
    @State private var improvedOnly = false
    @State private var unconfirmedOnly = false
    /// 틀 밖 컬럼만 보기 — 어느 파일에서 온 값이 아직 안 옮겨졌는지 한눈에.
    @State private var extrasOnly = false
    /// 틀 안에 빈 행이 남은 컬럼만 보기 — 이 도구가 하려는 일 그 자체.
    @State private var holesOnly = false
    @State private var showChanges = false
    /// 눌러서 데려갈 컬럼 (표를 가로로 스크롤한다).
    @State private var jumpColumn: String?
    /// 값을 고치는 중인 셀 (컬럼 · 지금 값).
    struct EditTarget: Identifiable {
        let column: UnifiedColumn
        let value: String
        var id: String { column.rawValue + "\u{1}" + value }
    }
    @State private var editing: EditTarget?
    @State private var editText = ""
    /// 컬럼 폭 — 머리글 오른쪽 끝을 잡고 끌어서 바꾼다.
    @State private var columnWidths: [String: CGFloat] = [:]
    @State private var widthDrag: (column: String, start: CGFloat)?
    /// 표가 가로로 얼마나 밀렸는지 — 그릴 때마다 스크롤뷰에서 직접 읽는다.
    /// 이 값과 창 너비로 ‘지금 그릴 컬럼 구간’을 **한 번만** 정해 모든 줄이 똑같이 쓴다.
    @StateObject private var scroll = TableScroll()
    @State private var viewportWidth: CGFloat = 900
    private static let defaultColumnWidth: CGFloat = 190

    private func width(_ c: UnifiedColumn) -> CGFloat {
        columnWidths[c.rawValue] ?? Self.defaultColumnWidth
    }

    /// 이 컬럼의 폭을 **값이 잘리지 않을 만큼** 넓힌다.
    /// (표에서 `…`로 잘려 보이는 건 폭 때문이지 값이 잘린 게 아니다 — 복사·내보내기는
    /// 늘 값 전체가 나간다. 그래도 눈으로 확인하려면 폭을 맞출 수 있어야 한다.)
    private func fitWidth(_ c: UnifiedColumn) {
        let attrs: [NSAttributedString.Key: Any] =
            [.font: NSFont.systemFont(ofSize: NSFont.systemFontSize)]
        var w = (c.rawValue as NSString).size(withAttributes: attrs).width + 64   // 체크박스·아이콘 자리
        for (_, row) in visibleRows.prefix(300) {
            let value = row[c]
            guard !value.isEmpty else { continue }
            w = max(w, (value as NSString).size(withAttributes: attrs).width + 24)
        }
        columnWidths[c.rawValue] = min(560, max(90, ceil(w)))
    }

    private func fitAllWidths() {
        for c in shownColumns { fitWidth(c) }
    }

    /// 표에 그릴 컬럼. 파일이 여럿이면 컬럼이 합집합이라 금세 난잡해지니
    /// ‘채울 칸만’(틀 안 빈 행) · ‘틀 밖만’(재료)으로 좁혀 볼 수 있다.
    private var shownColumns: [UnifiedColumn] {
        guard model.usingTemplate else { return model.columns }
        var cols = model.columns
        if holesOnly { cols = cols.filter { (model.holeCounts[$0] ?? 0) > 0 } }
        else if extrasOnly { cols = cols.filter { model.extraColumns.contains($0) } }
        return model.templateFirst(cols)
    }

    /// 파일 색·컬럼 상태 색을 켤지 (기본 켬, 설정에 기억).
    @AppStorage("previewShowColors.v2") private var showColors = true
    /// 창 제목 — 시작할 때 복원된 창을 찾아 닫는 데 쓴다.
    static let windowTitle = "완성본 미리보기"
    @Environment(\.dismiss) private var dismiss

    /// (원본 행 번호, 행) — 검색·필터를 거쳐도 diff/이전값 조회용 인덱스 유지.
    private var visibleRows: [(Int, ApplicantRow)] {
        var rows = Array(model.rows.enumerated()).map { ($0.offset, $0.element) }
        if improvedOnly {
            rows = rows.filter { !(model.diff[$0.0]?.isEmpty ?? true) }
        }
        if unconfirmedOnly {
            rows = rows.filter { !model.isConfirmed($0.0) }
        }
        if model.showDuplicatesOnly {
            rows = rows.filter { model.duplicateRows.contains($0.0) }
        }
        if !query.isEmpty {
            rows = rows.filter { _, row in
                model.columns.contains { row[$0].localizedCaseInsensitiveContains(query) }
            }
        }
        return rows
    }

    /// 창 위쪽 줄 — 요약·선택 동작·보기 옵션. (한 덩어리로 두면 타입 체크가 버거워
    /// 조각으로 나눠 둔다.)
    /// 창 위쪽 — **위는 지금 상태, 아래는 할 수 있는 일**로 두 줄로 나눠 둔다.
    /// (한 줄에 몰아 두니 무엇이 정보고 무엇이 버튼인지 구분이 안 됐다.)
    private var windowToolbar: some View {
        VStack(spacing: 0) {
            statusRow
            if !model.rows.isEmpty {
                Divider().opacity(0.4)
                toolRow
            }
        }
    }

    /// 첫 줄: 지금 표가 어떤 상태인지 (읽는 줄) + 값 검색.
    private var statusRow: some View {
        HStack(spacing: 10) {
            Label("완성본 미리보기", systemImage: "eye")
                .font(.headline)
                .lineLimit(1).fixedSize()
            if model.rows.isEmpty {
                Text("파일을 올리고 ‘완성본 미리보기’를 누르면 채워집니다.")
                    .font(.body).foregroundStyle(.secondary)
                    .lineLimit(1)
            } else {
                summaryChips
            }
            Spacer(minLength: 8)
            if !model.rows.isEmpty {
                TextField("값 검색…", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 170)
                    .fixedSize()
            }
        }
        .padding(.horizontal, 16).padding(.top, 10).padding(.bottom, 8)
    }

    /// 둘째 줄: 지금 누를 수 있는 것들. 왼쪽은 **고른 컬럼에 하는 일**,
    /// 오른쪽은 **표 전체에 하는 일**(보기·복사·내보내기).
    private var toolRow: some View {
        HStack(spacing: 8) {
            selectionActions
            Spacer(minLength: 8)
            Divider().frame(height: 18)
            viewOptions
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(Color(nsColor: .underPageBackgroundColor).opacity(0.6))
    }

    @ViewBuilder
    private var summaryChips: some View {
        Text("전체 \(model.rows.count)행"
             + (visibleRows.count == model.rows.count ? "" : " 중 \(visibleRows.count)행 표시")
             + (shownColumns.count == model.columns.count
                ? " · 컬럼 \(model.columns.count)개"
                : " · 컬럼 \(model.columns.count)개 중 \(shownColumns.count)개 표시"))
            .font(.body).foregroundStyle(.secondary)
            .lineLimit(1).fixedSize()
        // 진행률은 ‘틀 안의 빈 행이 얼마나 남았나’로 읽는다 — 그게 목표니까.
        if model.usingTemplate {
            let holes = model.holeCounts.values.reduce(0, +)
            Label(holes == 0 ? "틀 안 다 찼어요"
                             : "채울 칸 \(holes) · \(model.holeCounts.count)컬럼",
                  systemImage: holes == 0 ? "checkmark.seal.fill" : "square.and.pencil")
                .font(.body.weight(.medium))
                .foregroundStyle(holes == 0 ? Color.green : Color.accentColor)
                .lineLimit(1).fixedSize()
                .help("틀 안 컬럼에 아직 값이 없는 칸 수입니다. 파란 열의 머리글을 누르면 바로 채웁니다.")
        }
        if model.needsWorkColumns.isEmpty {
            Label("모든 컬럼 작업 완료", systemImage: "checkmark.seal.fill")
                .font(.body.weight(.medium))
                .foregroundStyle(Color.green)
                .help("결정할 값이 남은 컬럼이 없습니다.")
        } else {
            Label("작업 필요 \(model.needsWorkColumns.count)컬럼",
                  systemImage: "exclamationmark.triangle.fill")
                .font(.body.weight(.medium))
                .foregroundStyle(Color.orange)
                .lineLimit(1).fixedSize()
                .help("아직 결정하지 못한 값이 남은 컬럼: "
                      + model.needsWorkColumns.map(\.rawValue).joined(separator: ", "))
        }
        if model.isBuilding {
            HStack(spacing: 5) {
                ProgressView().controlSize(.small)
                Text("결과를 다시 만드는 중…").font(.body).foregroundStyle(.secondary)
            }
        }
        if !model.rows.isEmpty {
            let done = model.confirmedRows.count
            Menu {
                Button("보이는 행 모두 확정 (\(visibleRows.count)행)") {
                    model.request = .confirmRows(visibleRows.map { model.rowKey($0.0) }, true)
                }
                if visibleRows.count != model.rows.count {
                    Button("전체 \(model.rows.count)행 모두 확정") {
                        model.request = .confirmRows(
                            (0..<model.rows.count).map { model.rowKey($0) }, true)
                    }
                }
                Divider()
                Button("보이는 행 확정 해제") {
                    model.request = .confirmRows(visibleRows.map { model.rowKey($0.0) }, false)
                }
                .disabled(done == 0)
                Button("확정 전부 해제") {
                    model.request = .confirmRows(
                        (0..<model.rows.count).map { model.rowKey($0) }, false)
                }
                .disabled(done == 0)
            } label: {
                Label("확정 \(done) / \(model.rows.count)행",
                      systemImage: done == model.rows.count && done > 0
                        ? "checkmark.seal.fill" : "checkmark.seal")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .foregroundStyle(done == model.rows.count && done > 0 ? Color.green : .secondary)
            .help("‘다 봤다’고 표시한 행 수입니다. 눌러서 한 번에 확정하거나 해제할 수 있어요.")
        }
        if model.diffCount > 0 {
            Label("개선된 셀 \(model.diffCount)개", systemImage: "sparkles")
                .font(.body.weight(.medium))
                .foregroundStyle(Color.accentColor)
                .help("정리 전과 비교해 값이 좋아진 셀 수입니다.")
        }
        if showColors, model.rowFiles.isEmpty {
            Label("행 출처 없음 — 파일 색을 못 그려요", systemImage: "questionmark.circle")
                .font(.body).foregroundStyle(.secondary)
                .help("합쳐진 행이 어느 파일에서 왔는지 정보가 없습니다. 파일을 다시 올리면 표시됩니다.")
        }
        if let f = model.focused {
            Button { jumpColumn = f.rawValue } label: {
                Text("보는 중: \(f.rawValue)")
                    .font(.body.weight(.medium))
                    .foregroundStyle(Color.accentColor)
                    .lineLimit(1)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Capsule().fill(Color.accentColor.opacity(0.14)))
            }
            .buttonStyle(.plain)
            .help("눌러서 그 컬럼으로 갑니다 (표에서 파란 기둥).")
        }
    }

    @ViewBuilder
    private var viewOptions: some View {
        // 체크박스를 한 줄에 늘어놓으면 창이 좁아질 때 글자가 세로로 접히거나
        // ‘…’로 잘린다. 보기 옵션은 메뉴 하나로 접어 둔다.
        Menu {
            Toggle("색 표시", isOn: $showColors)
            Divider()
            if model.usingTemplate, !model.holeCounts.isEmpty {
                Toggle("채울 칸만 보기 (\(model.holeCounts.count)컬럼)",
                       isOn: Binding(get: { holesOnly },
                                     set: { holesOnly = $0; if $0 { extrasOnly = false } }))
            }
            if model.usingTemplate, !model.extraColumns.isEmpty {
                Toggle("틀 밖 재료만 보기 (\(model.extraColumns.count)컬럼)",
                       isOn: Binding(get: { extrasOnly },
                                     set: { extrasOnly = $0; if $0 { holesOnly = false } }))
            }
            Divider()
            Toggle("개선된 행만", isOn: $improvedOnly)
            Toggle("확정 안 한 행만", isOn: $unconfirmedOnly)
            if !model.duplicateRows.isEmpty {
                Toggle("중복만 (\(model.duplicateRows.count)행)",
                       isOn: Binding(get: { model.showDuplicatesOnly },
                                     set: { model.showDuplicatesOnly = $0 }))
            }
            Divider()
            Button("모든 컬럼 폭을 값에 맞추기") { fitAllWidths() }
            Button("모든 컬럼 폭 기본으로") { columnWidths = [:] }
            if filtersOn {
                Divider()
                Button("보기 조건 모두 끄기") {
                    holesOnly = false; extrasOnly = false
                    improvedOnly = false; unconfirmedOnly = false
                    model.showDuplicatesOnly = false
                }
            }
        } label: {
            Label(filtersOn ? "보기 ●" : "보기", systemImage: "line.3.horizontal.decrease.circle")
        }
        .fixedSize()
        .help("무엇을 보여 줄지 고릅니다 — 채울 칸만, 틀 밖 재료만, 중복만…")
        if !model.changes.isEmpty {
            Button { showChanges = true } label: {
                Label("변경 \(model.changes.count)", systemImage: "arrow.left.arrow.right")
            }
            .fixedSize()
            .help("값 정리가 바꾼 칸을 이전 값 → 새 값으로 모아 봅니다.")
        }
        Menu {
            let picked = shownColumns.filter { model.selection.contains($0) }
            if !picked.isEmpty {
                Button("고른 컬럼만 복사 (\(picked.count)개)") {
                    copyTable(columns: picked, withOrigin: false)
                }
                Button("고른 컬럼 이름만 복사") {
                    copyToClipboard(picked.map(\.rawValue).joined(separator: "\t"), asTable: true)
                }
                Divider()
            }
            Button("보이는 표 전체 복사") { copyTable(columns: shownColumns, withOrigin: true) }
            Button("보이는 표 (행·출처 빼고)") {
                copyTable(columns: shownColumns, withOrigin: false)
            }
        } label: {
            Label("복사", systemImage: "doc.on.doc")
        }
        .fixedSize()
        .help("표를 탭 구분으로 복사합니다 — 엑셀·구글 시트에 그대로 붙습니다. "
              + "머리글 네모를 체크해 두면 그 컬럼만 복사할 수 있어요.")

        Menu {
            let picked = shownColumns.filter { model.selection.contains($0) }
            Text(picked.isEmpty ? "보이는 컬럼 \(shownColumns.count)개 · \(visibleRows.count)행"
                                : "고른 컬럼 \(picked.count)개 · \(visibleRows.count)행")
            Divider()
            Button("엑셀 파일(.xlsx)로 저장…") { exportTable(asXLSX: true) }
            Button("CSV로 저장…") { exportTable(asXLSX: false) }
        } label: {
            Label("내보내기", systemImage: "square.and.arrow.down")
        }
        .fixedSize()
        .help("지금 보이는 표를 그대로 파일로 저장합니다. "
              + "머리글을 골라 두면 고른 컬럼만, 보기를 좁혀 두면 그 행만 나갑니다.")
    }

    /// 지금 표를 좁혀 보고 있는가 (메뉴 버튼에 점을 찍어 알려 준다).
    private var filtersOn: Bool {
        holesOnly || extrasOnly || improvedOnly || unconfirmedOnly || model.showDuplicatesOnly
    }

    var body: some View {
        VStack(spacing: 0) {
            windowToolbar
            if !model.nextHint.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.turn.down.right").foregroundStyle(Color.accentColor)
                    Text("지금 할 일").font(.body.weight(.semibold))
                    Text(model.nextHint)
                        .font(.body).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.tail)
                    Spacer(minLength: 8)
                    if let c = model.nextColumn {
                        Button("이 컬럼 채우기…") { model.request = .fill(c) }
                            .controlSize(.small)
                            .fixedSize()
                            .help("‘\(c.rawValue)’에 넣을 값을 고릅니다.")
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 6)
                .background(Color.accentColor.opacity(0.08))
            }

            Divider()

            if model.rows.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "tray").font(.system(size: 28)).foregroundStyle(.tertiary)
                    Text("아직 보여줄 데이터가 없습니다.")
                        .font(.body).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                previewTableView
                Divider()
                legendBar
            }
        }
        .frame(minWidth: embedded ? 0 : 720, minHeight: embedded ? 0 : 420)
        .background(embedded ? nil : NonRestorableWindow())
        .sheet(item: $editing) { editSheet($0) }
        .sheet(isPresented: $showChanges) {
            ChangeLogSheet(changes: model.changes, onClose: { showChanges = false })
        }
        // 앱을 켤 때 저절로 뜨는(복원되는) 창은 닫는다 — 버튼으로 열었을 때만 남는다.
        // onAppear 시점엔 아직 창이 다 뜨지 않아 dismiss가 먹지 않을 수 있어 다음 차례로 미룬다.
        .onAppear {
            guard !embedded, !model.openedByUser else { return }
            DispatchQueue.main.async {
                if model.openedByUser { return }
                dismiss()
                NSApp.windows.first { $0.title == PreviewWindowView.windowTitle }?.close()
            }
        }
    }

    /// 표의 셀 한 칸. 컬럼 상태가 배경으로 내려오고, 개선된 값은 파란 굵은 글씨,
    /// 지금 보는 열은 좌우 세로선으로 기둥처럼 이어진다.
    /// 표의 셀 한 칸. 스크롤이 끊기지 않도록 **한 칸에 붙는 것을 최소로** 유지한다
    /// (배경 한 겹 · 강조선은 그 열일 때만 · 툴팁 없음 — 값은 더블클릭으로 크게 본다).
    private func bodyCell(_ c: UnifiedColumn, row: ApplicantRow, at i: Int) -> some View {
        let improved = model.diff[i]?.contains(c) ?? false
        let focused = model.focused == c
        let value = row[c]
        let fg: Color = improved ? .accentColor
            : (value.isEmpty ? Color.secondary.opacity(0.5) : .primary)
        return Text(value.isEmpty ? "—" : value)
            .font(.body)
            .fontWeight(improved ? .medium : .regular)
            .foregroundStyle(fg)
            .lineLimit(1).truncationMode(.tail)
            .frame(width: width(c), alignment: .leading)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(cellBackground(c, improved: improved, focused: focused,
                                       blank: value.isEmpty))
            .overlay(alignment: .trailing) { focusEdge(focused) }
            .contextMenu { cellMenu(c, value) }
            .onTapGesture(count: 2) {
                editText = value
                editing = EditTarget(column: c, value: value)
            }
    }

    /// 셀 배경 한 겹으로 합치기 — 겹쳐 그리던 세 겹을 하나로.
    private func cellBackground(_ c: UnifiedColumn, improved: Bool, focused: Bool,
                                blank: Bool) -> Color {
        // 값이 바뀐 칸이 가장 잘 보여야 한다 — 무엇이 손대졌는지가 제일 중요한 정보다.
        if improved { return .accentColor.opacity(0.20) }
        if focused { return .accentColor.opacity(0.12) }
        if model.selection.contains(c) { return .accentColor.opacity(0.07) }
        guard showColors else { return .clear }
        // 틀 안인데 **이 칸이 비었으면** 파랗게 — 채워야 할 칸이 어디인지 셀 단위로 보이게.
        if model.usingTemplate, model.templateSet.contains(c), blank {
            return .accentColor.opacity(0.13)
        }
        return model.cellTint(c, improved: improved)
    }

    /// 셀에서 바로 할 수 있는 일 — 복사와 값 고치기.
    @ViewBuilder
    private func cellMenu(_ c: UnifiedColumn, _ value: String) -> some View {
        Button(value.isEmpty ? "빈 칸 채우기…" : "값 고치기…") {
            editText = value
            editing = EditTarget(column: c, value: value)
        }
        Divider()
        Button("이 값 복사") { copyToClipboard(value) }
            .disabled(value.isEmpty)
        Button("이 컬럼 폭을 값에 맞추기") { fitWidth(c) }
        Button("‘\(c.rawValue)’ 열 전체 복사") {
            copyToClipboard(([c.rawValue] + model.rows.map { $0[c] }).joined(separator: "\n"),
                            asTable: true)
        }
        Button("표 전체 복사 (붙여넣기용)") {
            copyTable(columns: shownColumns, withOrigin: true)
        }
        Divider()
        Button("‘\(c.rawValue)’ 값 채우기…") { model.request = .fill(c) }
        Button("‘\(c.rawValue)’로 무엇을 할까요…") { model.request = .move(c) }
    }

    /// 클립보드에 넣는다.
    /// `asTable`이면 **탭 구분 표(TSV)라는 꼬리표**를 같이 붙인다 — 그냥 글자로만 넣으면
    /// 엑셀이 예전에 쓰던 ‘텍스트 나누기’ 설정(예: 공백으로 나누기)을 그대로 적용해서
    /// `South Korea`가 두 칸으로 쪼개지곤 한다.
    private func copyToClipboard(_ text: String, asTable: Bool = false) {
        let board = NSPasteboard.general
        board.clearContents()
        if asTable {
            // 엑셀은 **HTML 표**를 가장 먼저 본다. 이게 없으면 글자로 받아서
            // 예전에 쓰던 ‘텍스트 나누기’ 설정(고정 너비 6글자 같은 것)을 그대로 적용해
            // 값이 잘리거나 여러 칸으로 쪼개진다.
            let tsv = NSPasteboard.PasteboardType("public.utf8-tab-separated-values-text")
            board.declareTypes([.html, tsv, .tabularText, .string], owner: nil)
            board.setString(htmlTable(from: text), forType: .html)
            board.setString(text, forType: tsv)
            board.setString(text, forType: .tabularText)
        }
        board.setString(text, forType: .string)
    }

    /// 탭·줄바꿈으로 된 표를 HTML `<table>`로 — 표로 붙여넣게 하는 가장 확실한 방법.
    private func htmlTable(from tsv: String) -> String {
        func escape(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;")
             .replacingOccurrences(of: "<", with: "&lt;")
             .replacingOccurrences(of: ">", with: "&gt;")
        }
        var out = "<meta charset=\"utf-8\"><table>"
        for line in tsv.components(separatedBy: "\n") {
            out += "<tr>"
            for cell in line.components(separatedBy: "\t") {
                // 셀 하나하나를 글자로 못 박는다 (앞자리 0·긴 값이 그대로 남게).
                out += "<td style=\"mso-number-format:'\\@'\">" + escape(cell) + "</td>"
            }
            out += "</tr>"
        }
        return out + "</table>"
    }

    /// 지금 보이는 표를 탭으로 구분해 복사 — 엑셀·시트에 그대로 붙습니다.
    /// 지금 내보낼 컬럼 — 머리글을 골라 뒀으면 **그것만**, 아니면 보이는 표 전체.
    private var exportColumns: [UnifiedColumn] {
        let picked = shownColumns.filter { model.selection.contains($0) }
        return picked.isEmpty ? shownColumns : picked
    }

    /// 표를 탭 구분으로 복사. `withOrigin`이면 행 번호·출처 파일을 앞에 붙인다.
    private func copyTable(columns: [UnifiedColumn], withOrigin: Bool) {
        var lines: [String] = []
        let head = (withOrigin ? ["행", "출처"] : []) + columns.map(\.rawValue)
        lines.append(head.joined(separator: "\t"))
        for (i, row) in visibleRows {
            let cells = columns.map { row[$0].replacingOccurrences(of: "\t", with: " ") }
            let lead = withOrigin ? ["\(i + 1)", model.fileLabel(row: i)] : []
            lines.append((lead + cells).joined(separator: "\t"))
        }
        copyToClipboard(lines.joined(separator: "\n"), asTable: true)
    }

    /// 지금 보고 있는 표 그대로 파일로 저장한다 (골라 둔 컬럼이 있으면 그것만).
    private func exportTable(asXLSX: Bool) {
        let cols = exportColumns
        let headers = cols.map(\.rawValue)
        let rows = visibleRows.map { _, row in cols.map { row[$0] } }
        let panel = NSSavePanel()
        panel.title = "완성본 내보내기"
        panel.nameFieldStringValue = asXLSX ? "완성본.xlsx" : "완성본.csv"
        panel.allowedContentTypes = [asXLSX
            ? (UTType(filenameExtension: "xlsx") ?? .data)
            : .commaSeparatedText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            if asXLSX {
                try XLSXWriter.book(headers: headers, rows: rows).write(to: url)
            } else {
                // 엑셀이 한글을 깨지 않게 BOM을 붙인다.
                let csv = "\u{FEFF}" + CSVParser.write(headers: headers, rows: rows)
                try Data(csv.utf8).write(to: url)
            }
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            NSSound.beep()
        }
    }

    /// 값 고치기 창 — 같은 값이 여러 행에 있으면 몇 행이 함께 바뀌는지 알려 준다.
    private func editSheet(_ target: EditTarget) -> some View {
        let affected = model.rows.filter { $0[target.column] == target.value }.count
        return VStack(alignment: .leading, spacing: 12) {
            Text(target.value.isEmpty ? "‘\(target.column.rawValue)’ 빈 칸 채우기"
                                      : "‘\(target.column.rawValue)’ 값 고치기")
                .font(.title2.weight(.bold))
            HStack(spacing: 8) {
                Text(target.value.isEmpty ? "(빈 칸)" : target.value)
                    .font(.body)
                    .foregroundStyle(target.value.isEmpty ? .secondary : .primary)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))
                Image(systemName: "arrow.right").foregroundStyle(.secondary)
                TextField("새 값", text: $editText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 260)
            }
            Text(target.value.isEmpty
                 ? "이 컬럼에서 비어 있는 \(affected)행이 모두 이 값으로 채워집니다."
                 : (affected > 1
                    ? "이 컬럼에서 ‘\(target.value)’인 \(affected)행이 함께 바뀝니다."
                    : "이 값 1행이 바뀝니다."))
                .font(.body).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("취소") { editing = nil }
                Button("바꾸기") {
                    model.request = .edit(target.column, target.value, editText)
                    editing = nil
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(editText.trimmingCharacters(in: .whitespaces).isEmpty
                          || editText == target.value)
            }
        }
        .padding(20)
        .frame(minWidth: 460)
    }

    /// 행 맨 앞 칸 — 행 번호와, 어느 파일에서 온 줄인지 색·이름으로.
    private func rowHeadCell(_ i: Int) -> some View {
        let tint = showColors ? model.fileTint(row: i) : nil
        let hasFiles = !model.rowFiles.isEmpty
        let done = model.isConfirmed(i)
        return HStack(spacing: 5) {
            // 이 행은 다 봤다는 표시 — 어디까지 봤는지 눈으로 남긴다.
            Button {
                model.request = .confirmRow(model.rowKey(i), !done)
            } label: {
                Image(systemName: done ? "checkmark.seal.fill" : "circle")
                    .foregroundStyle(done ? Color.green : Color.secondary.opacity(0.5))
            }
            .buttonStyle(.plain)
            .help(done ? "확정 해제" : "이 행 확정")
            Text("\(i + 1)")
                .font(.body.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 34, alignment: .trailing)
            if hasFiles {
                RoundedRectangle(cornerRadius: 2)
                    .fill(tint ?? Color.secondary.opacity(0.35))
                    .frame(width: 3, height: 14)
                if let n = model.diff[i]?.count, n > 0 {
                Text("수정 \(n)")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Capsule().fill(Color.accentColor.opacity(0.16)))
            }
            if model.duplicateRows.contains(i) {
                let twin = model.duplicateOf[i]
                Text(twin.map { "\($0 + 1)행과 중복" } ?? "중복")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Capsule().fill(Color.orange.opacity(0.16)))
                    .help(twin.map { "\($0 + 1)행과 같은 사람으로 보입니다." }
                          ?? "앞줄에 같은 사람이 있습니다.")
            }
            if let badge = model.rowBadge(row: i) {
                    Text(badge)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(Capsule().fill(Color.secondary.opacity(0.14)))
                }
                Text(model.fileLabel(row: i))
                    .font(.body)
                    .foregroundStyle(tint ?? .secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
        }
        .frame(width: hasFiles ? 215 : 82, alignment: .leading)
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background((tint ?? Color.secondary).opacity(tint == nil ? 0.05 : 0.12))
        .help(hasFiles ? model.rowOriginHelp(row: i) : "\(i + 1)행")
    }

    /// 검토 중인 열의 좌우 세로선. 셀마다 그려도 위아래로 이어져 한 줄로 보인다.
    @ViewBuilder
    private func focusEdge(_ on: Bool) -> some View {
        if on {
            Rectangle().fill(Color.accentColor).frame(width: 2)
        }
    }

    /// 컬럼 머리글 한 칸 — 상태 아이콘 + 이름 + 남은 건수, 그리고 상태색 밑줄.
    /// 머리글은 스크롤해도 고정이라 여기 색이 곧 그 컬럼의 상태 표시가 된다.
    private func headerCell(_ c: UnifiedColumn) -> some View {
        let st = model.status(c)
        let isFocused = model.focused == c
        let extra = model.usingTemplate && model.extraColumns.contains(c)
        let picked = model.selection.contains(c)
        return VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 4) {
                Button {
                    if picked { model.selection.remove(c) } else { model.selection.insert(c) }
                } label: {
                    Image(systemName: picked ? "checkmark.square.fill" : "square")
                        .foregroundStyle(picked ? Color.accentColor : Color.secondary.opacity(0.6))
                }
                .buttonStyle(.plain)
                .help("이 컬럼 고르기 — 고른 뒤 ‘데이터 정리하기’나 ‘두 컬럼 합치기’를 누르세요.")
                Image(systemName: st.icon)
                    .font(.body)
                    .foregroundStyle(showColors ? st.tint : .secondary)
                // 이름을 누르면 이 컬럼으로 무엇을 할지 고르는 창이 뜬다.
                Text(c.rawValue)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1).truncationMode(.tail)
                    .contentShape(Rectangle())
                    .onTapGesture { model.request = .move(c) }
                if let badge = st.badge {
                    Text(badge)
                        .font(.body.weight(.bold))
                        .foregroundStyle(Color.orange)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Capsule().fill(Color.orange.opacity(0.20)))
                }
            }
            // 둘째 줄은 ‘지금 보는 중’·‘비어 있음’·‘틀 밖’만 — 어느 파일에서 왔는지는 안 보여 준다.
            if isFocused {
                Text("지금 볼 컬럼")
                    .font(.body).foregroundStyle(Color.accentColor)
                    .padding(.leading, 20)
            } else if let holes = model.holeCounts[c], holes > 0 {
                // 틀 안인데 아직 빈 행이 있는 컬럼 — 눌러서 바로 채우러 간다.
                Button { model.request = .fill(c) } label: {
                    Text("빈 행 \(holes)개 — 눌러서 채우기")
                        .font(.body.weight(.semibold)).foregroundStyle(Color.accentColor)
                        .lineLimit(1).truncationMode(.tail)
                }
                .buttonStyle(.plain)
                .padding(.leading, 20)
            } else if model.emptyColumns.contains(c) {
                Button { model.request = .fill(c) } label: {
                    Text("통째로 비어 있음 — 눌러서 채우기")
                        .font(.body.weight(.semibold)).foregroundStyle(Color.accentColor)
                        .lineLimit(1).truncationMode(.tail)
                }
                .buttonStyle(.plain)
                .padding(.leading, 20)
            } else {
                // 값이 차 있는 컬럼. 할 일이 둘이라 둘 다 보여 준다:
                // 틀 밖이면 **틀 안으로 보내기**, 그리고 (공통) 오타·형식 정리.
                let open = model.openCounts[c] ?? 0
                HStack(spacing: 8) {
                    if extra {
                        Button("틀 안으로 보내기") { model.request = .move(c) }
                            .buttonStyle(.plain)
                            .font(.body.weight(.semibold))
                            .foregroundStyle(Color.accentColor)
                            .help("이 컬럼의 값을 틀 안의 칸으로 옮깁니다.")
                        Text("·").foregroundStyle(.secondary)
                    }
                    Button { model.request = .clean([c]) } label: {
                        Text(open > 0 ? "정리할 값 \(open)종" : "값 정리")
                            .font(.body.weight(open > 0 ? .semibold : .regular))
                            .foregroundStyle(open > 0 ? Color.orange : .secondary)
                    }
                    .buttonStyle(.plain)
                    .help("같은 뜻인데 다르게 적힌 값을 하나로 맞추고, 형식(전화번호·날짜)을 정리합니다.")
                }
                .lineLimit(1)
                .padding(.leading, 20)
            }
        }
        .frame(width: width(c), height: 36, alignment: .leading)
        .padding(.horizontal, 8).padding(.vertical, 6)
        .overlay(alignment: .top) {
            if picked { Rectangle().fill(Color.accentColor).frame(height: 3) }
        }
        // 오른쪽 끝을 잡고 끌면 폭이 바뀐다.
        .overlay(alignment: .trailing) { widthHandle(c) }
        .contextMenu {
            Button("이 컬럼으로 무엇을 할까요…") { model.request = .move(c) }
            Divider()
            Button("이 값 채우기…") { model.request = .fill(c) }
            Button("값 정리하기 (오타·형식)…") { model.request = .clean([c]) }
            Divider()
            Button("이 컬럼 폭을 값에 맞추기") { fitWidth(c) }
            Button("모든 컬럼 폭을 값에 맞추기") { fitAllWidths() }
            Button("이 컬럼 폭 기본으로") { columnWidths[c.rawValue] = nil }
            Button("모든 컬럼 폭 기본으로") { columnWidths = [:] }
        }
        // 머리글도 아래 셀들과 같은 색 계열로 — 열 전체가 한 덩어리로 읽히게.
        .background(showColors ? headerTint(c, st) : Color.clear)
        .background(isFocused ? Color.accentColor.opacity(0.18) : .clear)
        .overlay(alignment: .leading) { focusEdge(isFocused) }
        .overlay(alignment: .trailing) { focusEdge(isFocused) }
        .overlay(alignment: .top) {
            // 검토 중인 열은 위쪽에도 선을 그어 머리부터 끝까지 한 기둥으로 보이게.
            if isFocused { Rectangle().fill(Color.accentColor).frame(height: 2) }
        }
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(isFocused ? Color.accentColor : st.tint.opacity(st.needsWork ? 0.9 : 0.40))
                .frame(height: 2)
        }
        .help("\(c.rawValue) — \(st.help)"
              + "\n이름을 누르면 이 컬럼으로 무엇을 할지 고를 수 있어요 "
              + "(정리 · 옮기기 · 복제 · 합치기)."
              + (isFocused ? "\n지금 검토 중인 컬럼입니다." : ""))
    }

    /// 표 본체 — 조각으로 나눠 둔다 (한 덩어리면 타입 체크가 버겁다).
    private var previewTableView: some View {
        GeometryReader { outer in
            ScrollViewReader { proxy in
                ScrollView([.horizontal, .vertical]) {
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                        Section {
                            ForEach(visibleRows, id: \.1.id) { i, row in
                                tableRow(i, row)
                            }
                        } header: {
                            tableHeader
                        }
                    }
                    // 가로로 얼마나 밀렸는지 — 모든 줄이 **같은 컬럼 구간**을 그리게 하려면
                    // 이 값이 필요하다 (줄마다 제 나름대로 재면 줄이 어긋난다).
                    .background(ScrollOffsetReader(scroll: scroll).frame(width: 0, height: 0))
                }
                .onChange(of: jumpColumn) { name in
                    guard let name else { return }
                    DispatchQueue.main.async {
                        withAnimation { proxy.scrollTo("col:" + name, anchor: .center) }
                        jumpColumn = nil
                    }
                }
                .onAppear { viewportWidth = outer.size.width }
                .onChange(of: outer.size.width) { viewportWidth = $0 }
            }
        }
    }

    /// 지금 화면에 걸치는 컬럼 구간. 양옆으로 두 칸씩 더 그려 스크롤이 끊겨 보이지 않게 한다.
    /// **모든 줄과 머리글이 이 구간 하나만 그린다** — 줄마다 다른 구간을 그리면 어긋난다.
    private var columnWindow: (range: Range<Int>, leading: CGFloat) {
        let cols = shownColumns
        guard !cols.isEmpty else { return (0..<0, 0) }
        // 스크롤 위치를 못 읽는 상황이면 좁히지 않는다 (안 보이는 컬럼이 생기는 것보다 낫다).
        guard scroll.known else { return (0..<cols.count, 0) }
        // 스크롤뷰에 지금 값을 물어본다 (`tick`이 바뀔 때마다 다시 그려진다).
        _ = scroll.tick
        let from = max(0, min(scroll.offsetX, tableWidth) - gutterWidth)
        let to = from + max(viewportWidth, 400)

        // 배열을 만들지 않고 훑는다 — 줄마다 다시 계산되는 자리라 가벼워야 한다.
        var first = 0, x: CGFloat = 0
        while first < cols.count - 1, x + width(cols[first]) + 16 < from {
            x += width(cols[first]) + 16
            first += 1
        }
        var last = first, endX = x
        while last < cols.count - 1, endX < to {
            endX += width(cols[last]) + 16
            last += 1
        }

        // 양옆으로 몇 칸 더 (스크롤 중 빈칸이 스치지 않게).
        var start = max(0, first - 3)
        last = min(cols.count - 1, last + 4)
        // 눌러서 데려갈 컬럼은 반드시 그려 둬야 그쪽으로 스크롤할 수 있다.
        if let jump = jumpColumn, let idx = cols.firstIndex(where: { $0.rawValue == jump }) {
            start = min(start, idx)
            last = max(last, idx)
        }
        var leading = x
        var i = first
        while i > start { i -= 1; leading -= width(cols[i]) + 16 }
        return (start..<(last + 1), max(0, leading))
    }

    /// 줄 머리(확정·행 번호·출처)의 너비 — 머리글과 본문이 같은 값을 써야 칸이 맞는다.
    private var gutterWidth: CGFloat { (model.rowFiles.isEmpty ? 82 : 215) + 16 }

    /// 표 한 줄의 전체 너비. 줄마다 `LazyHStack`이 제 나름대로 너비를 재면,
    /// 가로로 스크롤하던 중에 만들어진 줄은 다른 줄과 몇 px씩 어긋나 그려진다
    /// (24행·28행만 오른쪽으로 밀려 보이던 게 이것). 모든 줄에 같은 너비를 못 박는다.
    private var tableWidth: CGFloat {
        gutterWidth + shownColumns.reduce(0) { $0 + width($1) + 16 }
    }

    private func tableRow(_ i: Int, _ row: ApplicantRow) -> some View {
        let confirmed: Color = model.isConfirmed(i) ? Color.green.opacity(0.10) : Color.clear
        let file: Color = showColors ? (model.fileTint(row: i)?.opacity(0.14) ?? .clear) : .clear
        let window = columnWindow
        let cols = shownColumns
        return VStack(spacing: 0) {
            HStack(spacing: 0) {
                rowHeadCell(i)
                // 왼쪽에 안 그린 컬럼들의 자리는 **정확한 너비의 빈칸**으로 메운다.
                Color.clear.frame(width: window.leading, height: 1)
                ForEach(window.range, id: \.self) { idx in
                    bodyCell(cols[idx], row: row, at: i)
                }
                Spacer(minLength: 0)
            }
            .frame(width: tableWidth, height: 26, alignment: .leading)
            .background(confirmed)
            .background(file)
            Divider()
        }
    }

    private var tableHeader: some View {
        let title: String = model.rowFiles.isEmpty ? "확정 · 행" : "확정 · 행 · 어느 파일에서"
        let window = columnWindow
        let cols = shownColumns
        return HStack(spacing: 0) {
            Text(title)
                .font(.body.weight(.semibold)).foregroundStyle(.secondary)
                .frame(width: gutterWidth - 16, alignment: .leading)
                .padding(.horizontal, 8).padding(.vertical, 6)
            Color.clear.frame(width: window.leading, height: 1)
            ForEach(window.range, id: \.self) { idx in
                headerCell(cols[idx]).id("col:" + cols[idx].rawValue)
            }
            Spacer(minLength: 0)
        }
        .frame(width: tableWidth, height: 48, alignment: .leading)
        // 머리글은 스크롤 위에 떠 있다 — 불투명한 바닥을 먼저 깔아야 아래 행이 비쳐 보이지 않는다.
        .background(Color(nsColor: .underPageBackgroundColor))
        .background(Color(nsColor: .textBackgroundColor))
    }

    /// 컬럼을 고르면 나타나는 동작들 — 정리하러 가기 / 두 컬럼 합치기.
    @ViewBuilder
    private var selectionActions: some View {
        if !model.selection.isEmpty {
            Text("\(model.selection.count)개 선택")
                .font(.body.weight(.medium))
                .foregroundStyle(Color.accentColor)
            if model.selection.count == 2 {
                Button { requestMerge() } label: {
                    Label("두 컬럼 합치기", systemImage: "arrow.trianglehead.merge")
                }
                .help("고른 두 컬럼을 한 칸으로 합칩니다. 앞에 있는 컬럼 이름이 남아요.")
            }
            // 할 일이 둘이라 **버튼도 둘**이다 — 값을 옮길 것인가, 값을 다듬을 것인가.
            // (‘정리’ 한 단어로 뭉뚱그리면 무엇이 일어날지 알 수 없다.)
            let many = model.selection.count >= 2
            let sending = !many && model.usingTemplate
                && model.selection.contains { model.extraColumns.contains($0) }
            Button { requestClean() } label: {
                Text(many ? "한 칸으로 합치기…"
                          : (sending ? "틀 안으로 보내기…" : "여기 값 채우기…"))
            }
            .buttonStyle(.borderedProminent)
            .help(many
                  ? "고른 칸들을 한 칸으로 모읍니다 — 이어 붙이기(성 + 이름)나 "
                    + "값이 있는 것 하나만 중에 고를 수 있어요. 값은 자리를 옮깁니다."
                  : (sending ? "이 틀 밖 컬럼의 값을 틀 안의 어느 칸으로 보낼지 정합니다."
                             : "이 칸에 어느 컬럼의 값을 가져올지 정합니다."))

            Button {
                model.request = .clean(shownColumns.filter { model.selection.contains($0) })
            } label: {
                Text("오타·형식 정리…")
            }
            .help("값을 옮기지 않고 **그 자리에서** 다듬습니다 — 같은 뜻인데 다르게 적힌 값을 "
                  + "하나로 모으고, 전화번호·날짜 형식을 맞추고, 오타를 짚어 줍니다.")
            Button("선택 해제") { model.selection = [] }
                .controlSize(.small)
        } else if !model.rows.isEmpty {
            // 툴바가 좁아 두 줄로 접히면 오히려 안 읽힌다 — 한 줄로 짧게.
            Text("머리글 네모 체크 → 옮기기 · 정리")
                .font(.body).foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private func requestClean() {
        let cols = shownColumns.filter { model.selection.contains($0) }
        guard !cols.isEmpty else { return }
        // 여러 개를 골랐다면 십중팔구 ‘이 칸들을 한 칸으로 모으고 싶다’는 뜻이다.
        if cols.count >= 2 { model.request = .fillFrom(cols); return }
        guard let col = cols.first else { return }
        // 하나만 골랐을 땐 **틀과의 관계**로 할 일이 정해진다:
        //   틀 밖 → 틀 안의 칸으로 보내기,  틀 안 → 틀 밖에서 가져오기.
        if model.usingTemplate, model.extraColumns.contains(col) {
            model.request = .move(col)
        } else {
            model.request = .fillFrom([col])
        }
    }

    private func requestMerge() {
        let two = model.columns.filter { model.selection.contains($0) }
        guard two.count == 2 else { return }
        model.request = .merge(two[0], two[1])
    }

    /// 컬럼 폭 조절 손잡이 — 머리글 오른쪽 끝 4px.
    private func widthHandle(_ c: UnifiedColumn) -> some View {
        let active = widthDrag?.column == c.rawValue
        return Rectangle()
            .fill(active ? Color.accentColor : Color.primary.opacity(0.10))
            .frame(width: active ? 3 : 2)
            .padding(.vertical, 2)
            .contentShape(Rectangle().inset(by: -5))
            .onHover { inside in
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            // 스크롤뷰가 드래그를 가져가지 않도록 우선권을 준다 — 끄는 즉시 폭이 따라온다.
            .highPriorityGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        if widthDrag?.column != c.rawValue {
                            widthDrag = (c.rawValue, width(c))
                        }
                        guard let d = widthDrag else { return }
                        columnWidths[c.rawValue] = min(700, max(90, d.start + v.translation.width))
                    }
                    .onEnded { _ in widthDrag = nil }
            )
            .onTapGesture(count: 2) { fitWidth(c) }
            .help("끌어서 폭 바꾸기 · 두 번 누르면 값에 맞춰 넓힙니다.")
    }

    /// 머리글 배경 — 상태색이 먼저, 그다음 ‘어느 파일에서 온 열인지’ 색.
    private func headerTint(_ c: UnifiedColumn, _ st: ColumnWorkStatus) -> Color {
        guard model.usingTemplate else {
            if st.needsWork { return .orange.opacity(0.14) }
            if model.checked.contains(c) { return .green.opacity(0.14) }
            return .clear
        }
        // 틀을 쓰는 동안은 ‘틀 안 빈 행’이 가장 먼저 눈에 띄어야 한다 — 그게 할 일이니까.
        switch model.kind(c) {
        case .templateHole:   return .accentColor.opacity(0.20)
        case .outside:        return .secondary.opacity(0.12)
        case .templateFilled:
            if st.needsWork { return .orange.opacity(0.14) }
            return .green.opacity(0.12)
        }
    }

    /// 이 컬럼이 어느 파일에 있는지 점으로 — 있는 파일은 그 색, 없으면 빈 동그라미.
    private func ownerDots(_ c: UnifiedColumn) -> some View {
        let owners = Set(model.columnOwners[c] ?? [])
        return HStack(spacing: 2) {
            ForEach(model.fileNames.indices, id: \.self) { i in
                Circle()
                    .fill(owners.contains(i) ? PreviewModel.paletteColor(i) : Color.clear)
                    .overlay(Circle().stroke(owners.contains(i) ? Color.clear
                                             : Color.secondary.opacity(0.5), lineWidth: 1))
                    .frame(width: 6, height: 6)
                    .help(model.fileNames[i] + (owners.contains(i) ? "에 있음" : "엔 없음"))
            }
        }
    }

    /// 색이 뭘 뜻하는지 한 줄로 — 미리보기를 따로 띄워 보는 창이라 범례가 필요하다.
    private var legendBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
        VStack(alignment: .leading, spacing: 4) {
        if !model.fileNames.isEmpty && !model.rowFiles.isEmpty {
            HStack(spacing: 12) {
                Text("파일 색").font(.body.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(Array(model.fileNames.enumerated()), id: \.offset) { idx, name in
                    HStack(spacing: 4) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(PreviewModel.paletteColor(idx)).frame(width: 10, height: 10)
                        Text(name).font(.body).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                }
                if !model.baseName.isEmpty {
                    HStack(spacing: 4) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color.secondary.opacity(0.35)).frame(width: 10, height: 10)
                        Text("틀: \(model.baseName)")
                            .font(.body).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                }
                Spacer(minLength: 0)
            }
        }
        HStack(spacing: 14) {
            legendItem("exclamationmark.triangle.fill", .orange, "더 작업 필요")
            legendItem("checkmark.circle.fill", .green, "확정 완료")
            legendItem("checkmark.circle", .green, "남은 결정 없음")
            legendItem("minus.circle", .secondary, "손댈 값 없음")
            legendItem("rectangle.portrait.and.arrow.right", .accentColor, "검토 중인 열")

            if model.usingTemplate {
                // 컬럼 색 = 틀과의 관계. 파일이 여럿이라 컬럼이 합집합으로 늘어서도
                // 무엇이 목표인지(파란 열 채우기) 색만 보고 알 수 있게.
                legendSwatch(.accentColor, "틀 안 · 빈 행 있음 — 눌러서 채우기")
                legendSwatch(.green, "틀 안 · 다 참")
                legendSwatch(.secondary, "틀 밖 \(model.extraColumns.count)개 — 채우기 재료")
            }
            HStack(spacing: 4) {
                Text("—").font(.body).foregroundStyle(.secondary.opacity(0.6))
                Text("그 파일엔 없는 값").font(.body).foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 4) {
                Text("가").font(.body.weight(.medium)).foregroundStyle(Color.accentColor)
                Text("파란 굵은 글씨 = 값이 개선된 셀")
                    .font(.body).foregroundStyle(.secondary)
            }
        }
        }
        .padding(.horizontal, 16).padding(.vertical, 6)
        }
        .background(Color(nsColor: .underPageBackgroundColor))
    }

    private func legendSwatch(_ tint: Color, _ label: String) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2).fill(tint.opacity(0.35))
                .frame(width: 10, height: 10)
            Text(label).font(.body).foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .fixedSize()
    }

    private func legendItem(_ icon: String, _ tint: Color, _ label: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.body).foregroundStyle(tint)
            Text(label).font(.body).foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .fixedSize()
    }
}
