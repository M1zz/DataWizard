import SwiftUI
import UniformTypeIdentifiers

/// Holds the pending auto-save work item so rapid edits coalesce into one write.
/// A reference type kept in @State so it survives View re-creation.
final class SaveDebouncer {
    var work: DispatchWorkItem?
}

struct ContentView: View {
    /// work  = 유틸 모드: 고칠 파일 + 고칠 컬럼, 두 개만 물어보고 바로 작업 (기본)
    /// files~ = 여러 파일을 아카데미 통합본으로 합치는 흐름 (필요할 때만)
    enum Stage { case work, files, columns, focus, review, result }
    /// 컬럼 고르기 진입 시 첫 갈림길의 선택 결과.
    /// nil = 아직 안 고름(갈림길 화면),
    /// patchBase   = 기존 통합본을 그대로 두고 이번에 고른 컬럼 값만 덮어쓰기(부분 정제),
    /// withTemplate = 기존 통합본의 컬럼 구성만 빌려 이번 데이터로 전부 새로 채우기,
    /// fromScratch  = 남길 컬럼을 직접 골라 새 틀 만들기.
    enum ColumnMode: String { case patchBase, withTemplate, fromScratch }

    @State private var inputs: [MergeInput] = []
    @State private var plans: [FilePlan] = []
    @State private var stage: Stage = .work
    // 컬럼 고르기 단계의 갈림길 선택 (nil이면 갈림길 화면을 먼저 보여줌).
    @State private var columnMode: ColumnMode?

    // Column-centric review of the final output
    @State private var finalColumns: [UnifiedColumn] = []
    @State private var reviews: [ColumnReview] = []
    @State private var valueMap: [UnifiedColumn: [String: String]] = [:]
    // 매핑표가 적용된 컬럼의 허용 통일 값 목록 — 있으면 자유 입력 대신
    // 이 중 하나만 고를 수 있다 (오타·임의 값 차단).
    @State private var allowedValues: [UnifiedColumn: [String]] = [:]
    @State private var checked: Set<UnifiedColumn> = []
    // 사용자가 컬럼에 직접 지정한 검토 타입 (없으면 자동 판단값 사용).
    @State private var typeOverride: [UnifiedColumn: ColumnType] = [:]
    // ‘포맷’ 타입 컬럼이 맞춰야 할 형식(프리셋), 그리고 직접 입력 정규식.
    @State private var formatChoice: [UnifiedColumn: FormatPreset] = [:]
    @State private var customFormat: [UnifiedColumn: String] = [:]
    // 사용자가 ‘최종 컬럼 고르기’ 단계에서 남기기로 한 컬럼들. 검토·미리보기·
    // 내보내기가 모두 이 집합만 대상으로 한다.
    @State private var includedColumns: Set<UnifiedColumn> = []
    // 이전에 완성한 보고서를 ‘참조 파일’로 불러오면, 그 헤더로 남길 컬럼을 맞춘다.
    // 예: 2분기 보고서를 넣으면 7·8·9월 데이터도 같은 컬럼 구성으로 정렬된다.
    // 틀에서 ‘컬럼 이름’만 빌려 온 경우 — 값은 올린 파일 것만 들어간다.
    @State private var templateName: String?
    @State private var templateColumns: [UnifiedColumn] = []
    /// 틀 파일의 컬럼별 값 — 결과에는 안 들어가고, ‘이 컬럼이 저 컬럼이구나’를 가리는 데만 쓴다.
    @State private var templateValues: [UnifiedColumn: [String]] = [:]
    /// 여러 파일을 합칠 때 ‘같은 행’을 가리는 키 컬럼 (nil이면 그냥 세로로 쌓기).
    @State private var keyColumn: UnifiedColumn?
    /// 사용자가 직접 골랐는가 — 자동 추천이 그 위를 덮어쓰지 않게.
    @State private var keyColumnChosen = false
    /// 키가 비어 있을 때 만들어 줄 번호의 ‘첫 값’ — 이 한 줄로 규칙이 정해진다.
    @State private var keyPatternText = "AUTO-0001"
    /// 자동으로 짝지은 컬럼 (되돌리기용 스냅샷과 함께).
    @State private var autoMatched: [(source: UnifiedColumn, target: UnifiedColumn)] = []
    @State private var undoPlans: [FilePlan]?

    @State private var referenceName: String?
    @State private var referenceColumns: Set<UnifiedColumn> = []   // 참조에서 인식된 컬럼
    @State private var referenceUnmatched: [String] = []           // 스키마에 없던 헤더
    // ---- 부분 정제: 기존에 만들던 통합본에 이번 컬럼만 이어붙이기 ----
    // 값까지 통째로 들고 있는 기준 파일. 있으면 결과물은 이 파일의 컬럼 구성·값을
    // 그대로 유지한 채, focusColumns 만 새로 정제한 값으로 바뀐다.
    @State private var base: BaseSheet?
    /// `base`가 사용자가 따로 불러온 ‘만들던 통합본’인가.
    /// false면 올린 파일들을 그대로 이어 붙인 시트라, 행 번호로 짝지으면 된다.
    @State private var baseIsUserFile = false
    /// 기준 통합본과 이번 데이터를 무엇으로 짝지을지. nil이면 Code→전화→이메일 자동.
    @State private var matchColumn: UnifiedColumn?
    @State private var focusColumns: Set<UnifiedColumn> = []
    /// 첫 화면에서 이미 정리된(손볼 거리 없는) 컬럼까지 펼쳐 보여줄지.
    /// 기본은 접힘 — 시작할 땐 손볼 컬럼만 눈에 들어오게.
    @State private var showSettledColumns = false
    /// 전체 컬럼 체크 목록을 펼쳤는가. 기본은 접힘 — 한 번에 하나씩 제안한다.
    @State private var showAllColumns = false
    /// 여러 컬럼을 한 칸으로 합치기 전 확인 (nil이면 안 물어봄).
    @State private var confirmMerge: [UnifiedColumn]?
    /// 지금 제안하고 있는 컬럼의 순서 (할 일이 적은 것부터).
    @State private var proposalIndex = 0
    /// 합치기 단계에서 사람이 확인을 마친 항목들 (한 번에 하나씩 보여 주기 위해).
    @State private var mergeDone: Set<String> = []
    /// 손댈 것 없는 컬럼 중 자동으로 다듬을 수 있는 것도 결과에 채울지.
    @State private var autoFillSettled = true
    /// ‘그대로 완성되는 컬럼’ 이름을 모두 펼쳐 볼지.
    @State private var showSettledSummary = false
    @State private var patch: PatchResult?
    @State private var appendNewRows = true
    @State private var markNewRows = true

    // 검토 화면의 컬럼 목록 순서 — 손볼 거리 있는 컬럼이 위.
    // 검토에 들어올 때 한 번 고정한다 (고치는 동안 줄이 튀지 않게).
    @State private var stepOrder: [UnifiedColumn] = []
    /// 지금 자세히 보고 있는 컬럼. nil이면 목록 화면.
    @State private var openColumn: UnifiedColumn?

    /// 올린 파일 원본을 그대로 들여다보는 창.
    @State private var filePreview: FilePlan?

    @State private var detailColumn: UnifiedColumn?
    @State private var configColumn: UnifiedColumn?
    @State private var exampleColumn: UnifiedColumn?
    @State private var regexColumn: UnifiedColumn?
    @State private var mappingColumn: UnifiedColumn?

    @State private var result: MergeResult?
    @State private var errorMessage: String?
    @State private var excludeRemoved = false
    @State private var isDropTargeted = false
    @State private var isBaseDropTargeted = false
    // 틀(사용자가 고른 통합본)의 컬럼별 값 목록 — ‘완성될 파일 기준’ 판정에 쓴다.
    // 매번 훑지 않도록 틀을 잡을 때 한 번 만들어 둔다.
    @State private var baseValues: [UnifiedColumn: [String]] = [:]
    /// 그중 ‘정해진 값이 반복되는’ 컬럼 — 값 목록을 정답지로 쓸 수 있는 컬럼.
    @State private var baseCategorical: Set<UnifiedColumn> = []
    // 이름이 다른 같은 컬럼 제안 (틀의 값 ↔ 이번 값 패턴 매칭).
    @State private var matchSuggestions: [ColumnMatcher.Suggestion] = []
    @State private var matchSamples: [UnifiedColumn: [String]] = [:]
    @State private var showMatchSheet = false
    /// 같은 이름인데 파일마다 값 모양이 크게 다른 컬럼 (합친 뒤 정리 대상).
    @State private var shapeConflicts: [UnifiedColumn] = []
    @State private var isPreparing = false
    /// 파일을 읽는 동안 화면이 멈춘 것처럼 보이지 않게 — 진행 표시.
    @State private var isLoadingFiles = false
    @State private var loadingNote = ""
    /// 버튼을 눌러 잠깐 기다려야 할 때 화면에 띄우는 안내 (nil이면 안 띄움).
    @State private var busyNote: String?
    @State private var isRunning = false

    // 전화번호(Clean) 목표 포맷 템플릿 — 모든 번호를 이 한 가지 표기로 통일.
    // 샘플 번호 010-1234-5678을 원하는 모양으로 적은 문자열 (직접 입력 가능).
    @State private var phoneTemplate: String = Normalizer.defaultPhoneTemplate

    // 별도 윈도우로 뜨는 ‘지금 상태로 합쳐진 파일’ 미리보기의 공유 모델.
    @StateObject private var preview = PreviewModel.shared
    @Environment(\.openWindow) private var openWindow

    // 멈췄다 이어서 하기 — 이전 세션 스냅샷(있으면 파일 화면에서 복원 제안).
    @Environment(\.scenePhase) private var scenePhase
    @State private var resumable: SessionSnapshot?
    /// 앱을 켠 뒤 한 번만 자동으로 이어 연다.
    @State private var didAutoResume = false
    /// ‘새 작업 시작’ 확인 중인가 (저장해 둔 작업을 지우는 동작이라 한 번 묻는다).
    @State private var confirmStartOver = false
    @State private var saveDebouncer = SaveDebouncer()
    /// 마지막으로 자동 저장한 시각 — 저장되고 있다는 걸 눈으로 확인시켜 준다.
    @State private var lastSavedAt: Date?
    /// 사람이 ‘확정’으로 표시한 행들 (키 값 기준이라 행 순서가 바뀌어도 유지).
    @State private var confirmedRowKeys: Set<String> = []
    /// 사용자가 직접 지운 행 (`파일#줄`). 이것 말고는 어떤 행도 사라지지 않는다.
    @State private var deletedSourceIDs: Set<String> = []
    /// 행을 걸러 낼 기준 컬럼(예: Process Status)과 ‘남길 값’들. 비어 있으면 안 거른다.
    @State private var filterColumn: UnifiedColumn?
    @State private var filterKeep: Set<String> = []
    @State private var showFilterSheet = false
    /// 틀의 빈 칸을 만들어 채우는 규칙 (컬럼 → 고정값 또는 번호 매기기).
    @State private var generatedColumns: [UnifiedColumn: GeneratedValue] = [:]
    /// 지금 ‘빈 칸 채우기’에서 보고 있는 칸의 순서.
    @State private var emptyIndex = 0
    /// 값 만들기 창을 띄운 컬럼.
    @State private var generateColumn: UnifiedColumn?
    @State private var generateFixed = ""
    @State private var generateSerial = "1"
    @State private var generateIsSerial = false
    /// ‘이 값 채우기’ 창을 띄운 대상 칸.
    @State private var fillTarget: UnifiedColumn?
    /// 한 컬럼의 변경사항만 미리 보는 창.
    @State private var changePreviewColumn: UnifiedColumn?
    /// 컬럼 하나를 정리하는 작업 창 — 도구 창을 닫으면 여기로 돌아온다.
    @State private var cleanHubColumn: UnifiedColumn?
    /// 미리보기에서 여러 컬럼을 골라 ‘데이터 정리하기’를 누른 경우 — 그 선택 전체.
    @State private var fillFromSelection: [UnifiedColumn] = []
    /// 값을 통째로 다른 컬럼으로 옮길 컬럼.
    @State private var moveSource: UnifiedColumn?
    /// 미리보기 계산 순번 — 늦게 끝난 옛 계산이 새 결과를 덮지 않게.
    @State private var previewToken = 0

    /// 화면을 그릴 때마다 데이터를 다시 훑지 않도록 미리 계산해 둔 것들.
    /// (글자 하나 칠 때마다 632행 × 116컬럼을 몇 번씩 훑고 있었다.)
    struct WorkCache {
        /// 컬럼별 값 예시 몇 개 — 칩·목록에서 바로 보여 주기 위해 미리 뽑아 둔다.
        var samples: [UnifiedColumn: [String]] = [:]
        var keyCandidates: [UnifiedColumn] = []
        var identityColumns: [UnifiedColumn] = []
        var filterCandidates: [UnifiedColumn] = []
        var filterCounts: [UnifiedColumn: [(value: String, count: Int)]] = [:]
        var status: [UnifiedColumn: (text: String, warn: Bool, badge: String)] = [:]
        var todo: [UnifiedColumn] = []
        var settled: [UnifiedColumn] = []
        var empty: [UnifiedColumn] = []
        var needClean: [(column: UnifiedColumn, note: String)] = []
        var proposalOrder: [UnifiedColumn] = []
        var autoEditable: [UnifiedColumn] = []
        /// 틀 안 컬럼마다 **아직 비어 있는 행 수** — 이 도구의 목표가 바로 이 칸을 채우는 것이라
        /// 다른 무엇보다 먼저 센다. (빈 칸이 하나도 없으면 목록에 넣지 않는다.)
        var holes: [(column: UnifiedColumn, empty: Int)] = []
        /// 위 목록을 컬럼으로 찾아 쓰기 좋게 만든 것 — 창·미리보기가 같은 값을 본다.
        var holeByColumn: [UnifiedColumn: Int] = [:]
        /// 틀 안 전체 칸 수와 그중 채워진 칸 수 — 진행률 한 줄용.
        var templateCells = 0
        var templateFilled = 0
    }
    @State private var cache = WorkCache()

    var body: some View {
        stagedContent
            .modifier(SessionAutosave(save: { scheduleSave() },
                                      saveNow: { saveNow() },
                                      scenePhase: scenePhase,
                                      valueMap: valueMap, allowedValues: allowedValues,
                                      checked: checked, includedColumns: includedColumns,
                                      focusColumns: focusColumns, finalColumns: finalColumns,
                                      stage: stage, planCount: plans.count,
                                      keyColumn: keyColumn, templateName: templateName))
    }

    /// 화면 + 시트들. (한 덩어리로 두면 타입 체크가 버거워 저장 감시와 나눠 둔다.)
    private var stagedContent: some View {
        Group {
            switch stage {
            case .work:    workStage
            case .files:   filesStage
            case .columns: columnsStage
            case .focus:   focusStage
            case .review:  reviewStage
            case .result:  resultStage
            }
        }
        .frame(minWidth: 820, minHeight: 580)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay { if busyNote != nil { loadingOverlay } }
        .confirmationDialog("지금까지의 작업을 지우고 새로 시작할까요?",
                            isPresented: $confirmStartOver, titleVisibility: .visible) {
            Button("새로 시작", role: .destructive) { startOver() }
            Button("그대로 두기", role: .cancel) { }
        } message: {
            Text("올린 파일과 지금까지 정한 것(틀·키·채운 칸·정리한 값)이 전부 지워집니다. "
                 + "되돌릴 수 없어요.")
        }
        // 창은 **하나로 모아 둔다** — `.sheet`를 여러 개 겹쳐 달면
        // 뒤에 단 것이 조용히 안 뜬다 (‘눌러도 아무 반응이 없다’의 원인).
        .sheet(item: Binding(get: { activeSheet },
                             set: { if $0 == nil { dismissTopSheet() } })) { kind in
            sheetContent(kind)
        }
        // 이전 세션이 있으면 파일 화면에서 이어서 하기를 제안.
        .onAppear {
            // 앱을 켜면 지난 작업을 **자동으로** 이어 연다 — 묻지 않는다.
            // (다시 시작하려면 위쪽 ‘새 작업 시작…’ 버튼.)
            if !didAutoResume {
                didAutoResume = true
                if plans.isEmpty, let saved = SessionStore.load() {
                    withBusy("지난 작업을 이어 여는 중…") { restore(saved) }
                }
            }
            // 앱을 켜면서 시스템이 복원한 미리보기 창은 닫는다 (버튼으로 열 때만 보이게).
            if !preview.openedByUser {
                DispatchQueue.main.async {
                    NSApp.windows
                        .filter { $0.title == PreviewWindowView.windowTitle }
                        .forEach { $0.close() }
                }
            }
        }
        // 완성본 미리보기 창에서 누른 동작을 여기서 실제로 수행한다.
        .onChange(of: preview.request) { req in handlePreviewRequest(req) }
        .onChange(of: typeOverride) { _ in scheduleSave() }
        .onChange(of: formatChoice) { _ in scheduleSave() }
        .onChange(of: customFormat) { _ in scheduleSave() }
        .onChange(of: phoneTemplate) { _ in scheduleSave() }
        .onChange(of: templateColumns) { _ in scheduleSave() }
        // 작업 상태가 바뀔 때마다 (debounce) 자동 저장 — 언제 멈춰도 이어서 가능.

        // 창을 내리거나 앱을 벗어나는 순간 즉시 저장.

    }

    /// 한 번에 하나만 뜨는 창들. 어느 것을 띄울지는 이 순서로 정한다.
    private enum SheetKind: Int, Identifiable {
        case merge, filter, generate, fill, fillFrom, move, changes
        case filePreview, detail, config, example, regex, mapping, match
        case cleanHub
        var id: Int { rawValue }
    }

    private var activeSheet: SheetKind? {
        if confirmMerge != nil { return .merge }
        if showFilterSheet { return .filter }
        if generateColumn != nil { return .generate }
        if fillTarget != nil { return .fill }
        if !fillFromSelection.isEmpty { return .fillFrom }
        if moveSource != nil { return .move }
        if changePreviewColumn != nil { return .changes }
        if filePreview != nil { return .filePreview }
        if detailColumn != nil { return .detail }
        if configColumn != nil { return .config }
        if exampleColumn != nil { return .example }
        if regexColumn != nil { return .regex }
        if mappingColumn != nil { return .mapping }
        if showMatchSheet { return .match }
        if cleanHubColumn != nil { return .cleanHub }
        return nil
    }

    /// 지금 떠 있는 창 **하나만** 닫는다. 정리 작업 창 위에서 도구 창을 열었을 때,
    /// 도구를 닫으면 작업 창으로 되돌아와 이어서 할 수 있게 하기 위해서다.
    private func dismissTopSheet() {
        switch activeSheet {
        case .merge:       confirmMerge = nil
        case .filter:      showFilterSheet = false
        case .generate:    generateColumn = nil
        case .fill:        fillTarget = nil
        case .fillFrom:    fillFromSelection = []
        case .move:        moveSource = nil
        case .changes:     changePreviewColumn = nil
        case .filePreview: filePreview = nil
        case .detail:      detailColumn = nil
        case .config:      configColumn = nil
        case .example:     exampleColumn = nil
        case .regex:       regexColumn = nil
        case .mapping:     mappingColumn = nil
        case .match:       showMatchSheet = false
        case .cleanHub:    cleanHubColumn = nil
        case .none:        break
        }
    }

    @ViewBuilder
    private func sheetContent(_ kind: SheetKind) -> some View {
        switch kind {
        case .merge:    mergeConfirmSheet
        case .filter:   rowFilterSheet
        case .generate: generateSheet
        case .fill:     fillSheet
        case .fillFrom: fillFromSheet
        case .move:     moveSheet
        case .changes:  changePreviewSheet
        case .filePreview:
            if let plan = filePreview {
                FilePreviewSheet(plan: plan,
                                 tint: fileTint(plans.firstIndex(where: { $0.id == plan.id }) ?? 0),
                                 onClose: { filePreview = nil })
            }
        case .detail:
            if let col = detailColumn { detailSheet(col) }
        case .config:
            if let col = configColumn {
                ColumnSourceSheet(column: col, plans: $plans, onClose: {
                    configColumn = nil
                    // 어느 칸을 쓸지 바뀌었으니 컬럼·값·미리보기를 다시 만든다.
                    if stage == .work { rebuildWorkColumns() }
                })
            }
        case .example:
            if let col = exampleColumn {
                ExampleRuleSheet(column: col,
                                 values: ValueScanner.distinct(col, in: plans),
                                 mapping: bindingForColumn(col),
                                 onClose: { exampleColumn = nil })
            }
        case .regex:
            if let col = regexColumn {
                RegexCleanupSheet(column: col,
                                  values: ValueScanner.distinct(col, in: plans),
                                  mapping: bindingForColumn(col),
                                  onClose: { regexColumn = nil })
            }
        case .mapping:
            if let col = mappingColumn {
                MappingTableSheet(column: col,
                                  values: ValueScanner.distinct(col, in: plans),
                                  mapping: bindingForColumn(col),
                                  allowed: Binding(get: { allowedValues[col] ?? [] },
                                                   set: { allowedValues[col] = $0 }),
                                  onClose: { mappingColumn = nil })
            }
        case .cleanHub:
            if let col = cleanHubColumn { cleanHubSheet(col) }
        case .match:
            ColumnMatchSheet(baseName: base?.name ?? "",
                             suggestions: matchSuggestions,
                             sourceSamples: matchSamples,
                             targetSamples: matchSamples,
                             onApply: { pairs in
                                 showMatchSheet = false
                                 withBusy("컬럼을 합치는 중…") { applyMatches(pairs) }
                             },
                             onClose: { showMatchSheet = false })
        }
    }

    /// Detail viewer for one column, with the same anomaly flags used in review.
    private func detailSheet(_ col: UnifiedColumn) -> some View {
        let vals = ColumnReviewBuilder.allValues(col, in: plans, phoneTemplate: phoneTemplate)
        let reasons = Dictionary(AnomalyDetector.scan(vals).map { ($0.value, $0.reason) },
                                 uniquingKeysWith: { first, _ in first })
        // 파일별로 어떤 컬럼이 출처 키인지 명시 (파일당 한 컬럼으로 고정됨).
        let refInfo = plans.map { "\($0.fileName) → \($0.refColumn?.rawValue ?? "행 번호")" }
            .joined(separator: "\n")
        return ColumnDetailView(columnName: col.rawValue,
                                values: vals,
                                rawValues: ColumnReviewBuilder.rawRows(col, in: plans, phoneTemplate: phoneTemplate),
                                mapping: valueMap[col] ?? [:],
                                anomalyReasons: reasons,
                                refInfo: refInfo,
                                onClose: { detailColumn = nil })
    }

    // MARK: - Stage 0: 합칠 파일 올리기 + 고칠 컬럼 고르기

    /// 앱을 열면 바로 이 화면. 단계를 밟게 하지 않고 두 가지만 묻는다:
    /// 합칠 파일들과, 그중 지금 고칠 컬럼. 나머지는 전부 그대로 이어 붙여 돌려준다.
    @ViewBuilder
    private var workStage: some View {
        Group {
            if plans.isEmpty || !isUtility {
                workDropView
            } else {
                VStack(spacing: 0) {
                    workToolbar
                    Divider()
                    workFileStrip
                    Divider()
                    // 이 창은 **길잡이**다 — 얼마나 됐는지 보여 주고, 실제 작업은
                    // 완성본 미리보기(작업대)에서 하도록 안내만 한다.
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            workProgressCard
                            workVerifyCard
                        }
                        .padding(24)
                    }
                }
                .overlay { if isDropTargeted { dropOverlay("여기에 놓으면 파일이 더해집니다") } }
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted, perform: acceptDroppedFiles)
        .overlay { if isLoadingFiles { loadingOverlay } }
        // 첫 화면 카드가 실제 완성본이므로, 값·선택이 바뀌면 다시 만든다.
        .onAppear { if preview.rows.isEmpty && !plans.isEmpty { refreshPreview() } }
        .onChange(of: focusColumns) { _ in refreshPreview() }
    }

    /// 눌러서 기다려야 하는 동작을 한 곳에서 처리한다.
    /// 안내를 먼저 그린 다음(한 프레임 뒤) 실제 작업을 시작해, 화면이 멈춘 것처럼 보이지 않게 한다.
    private func withBusy(_ note: String, _ work: @escaping () -> Void) {
        busyNote = note
        DispatchQueue.main.async {
            work()
            busyNote = nil
        }
    }

    /// 파일을 읽는 동안 덮어 두는 진행 표시 — ‘멈춘 게 아니라 일하는 중’임을 보여 준다.
    private var loadingOverlay: some View {
        ZStack {
            Color.black.opacity(0.08).ignoresSafeArea()
            VStack(spacing: 12) {
                ProgressView().controlSize(.large)
                Text(busyNote ?? (loadingNote.isEmpty ? "여는 중…" : loadingNote))
                    .font(.body.weight(.medium))
                    .lineLimit(2).multilineTextAlignment(.center)
                Text("파일이 크면 몇 초 걸릴 수 있어요")
                    .font(.body).foregroundStyle(.secondary)
            }
            .padding(28)
            .frame(maxWidth: 420)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.regularMaterial))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1))
        }
        .transition(.opacity)
    }

    private func dropOverlay(_ title: String) -> some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color.accentColor.opacity(0.08))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.accentColor, lineWidth: 2))
            .overlay(Label(title, systemImage: "arrow.down.doc.fill")
                .font(.title2.weight(.semibold))
                .padding(16)
                .background(.regularMaterial, in: Capsule()))
            .padding(8)
            .allowsHitTesting(false)
    }

    private var workToolbar: some View {
        let rows = plans.reduce(0) { $0 + $1.rows.count }
        return HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(plans.count == 1 ? "파일 1개 · \(rows)행"
                                      : "파일 \(plans.count)개 · 합쳐서 \(rows)행")
                    .font(.title3.weight(.bold))
                Text("컬럼 \(finalColumns.count)개 — 같은 이름의 컬럼끼리 자동으로 맞춰집니다. 고르지 않은 컬럼은 손대지 않아요.")
                    .font(.body).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let templateName {
                    Text(templateCoverageLine(templateName))
                        .font(.body).foregroundStyle(Color.accentColor)
                        .fixedSize(horizontal: false, vertical: true)
                } else if baseIsUserFile, let sheet = base {
                    Text(baseCoverageLine(sheet))
                        .font(.body).foregroundStyle(Color.accentColor)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
            savedBadge
            if let errorMessage { errorLabel(errorMessage).frame(maxWidth: 240) }
            Button {
                openPreviewWindow()
            } label: {
                Label("완성본 미리보기", systemImage: "macwindow.badge.plus")
            }
            .help("지금 합쳐진 결과를 큰 창으로 봅니다. 파일 색·컬럼 상태가 그대로 보여요.")
            Button("파일 더 넣기…") { pickWorkFiles() }
                .disabled(isLoadingFiles)
            Button("새 작업 시작…") { confirmStartOver = true }
                .help("지금까지의 작업을 지우고 빈 화면에서 다시 시작합니다.")
            Button {
                // 고른 게 없으면 막지 않는다 — 손 안 대고 그대로 뽑는 것도 정상적인 결과.
                if focusColumns.isEmpty { runMerge() }
                else { withBusy("검토 화면을 만드는 중…") { startWork() } }
            } label: {
                HStack {
                    if isRunning { ProgressView().controlSize(.small) }
                    Text(focusColumns.isEmpty
                         ? "손 안 대고 그대로 가져가기 →"
                         : (focusColumns.count == 1 ? "고치러 가기 →"
                                                    : "고른 \(focusColumns.count)개 고치러 가기 →"))
                        .fontWeight(.semibold)
                }
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .disabled(isRunning)
            .help(focusColumns.isEmpty
                  ? "고른 컬럼 없이 지금 상태 그대로 합쳐 내보냅니다. 다듬을 수 있는 컬럼은 규칙대로 채워집니다."
                  : "고른 컬럼만 검토하고, 나머지는 올린 그대로 이어 붙입니다.")
        }
        .padding(20)
    }

    /// 올린 파일 목록 — 각 파일이 몇 행·몇 컬럼인지, 빼기 버튼.
    private var workFileStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(plans.enumerated()), id: \.element.id) { idx, plan in
                    HStack(spacing: 8) {
                        Button {
                            filePreview = plan
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "doc.text.fill")
                                    .foregroundStyle(fileTint(idx))
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(plan.fileName)
                                        .font(.body.weight(.medium))
                                        .lineLimit(1).truncationMode(.middle)
                                    Text("\(plan.rows.count)행 · \(plan.headers.count)컬럼"
                                         + (plan.hiddenRowsSkipped > 0
                                            ? " · 숨긴 행 \(plan.hiddenRowsSkipped)개 제외" : "")
                                         + " · 눌러서 보기")
                                        .font(.body).foregroundStyle(.secondary)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("‘\(plan.fileName)’ 원본을 그대로 봅니다.")
                        Button {
                            removeWorkFile(plan)
                        } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                        .help("이 파일 빼기")
                    }
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .frame(maxWidth: 280)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color(nsColor: .controlBackgroundColor)))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color.primary.opacity(0.08), lineWidth: 1))
                }
                Button(action: pickWorkFiles) {
                    Label("파일 추가", systemImage: "plus")
                        .padding(.horizontal, 6).padding(.vertical, 10)
                }
                .buttonStyle(.bordered)
            }
            .padding(.horizontal, 24).padding(.vertical, 10)
        }
    }

    private var workColumnBar: some View {
        HStack(spacing: 10) {
            Text("어떤 컬럼을 고칠까요?").font(.headline)
            Text("선택 \(focusColumns.count) / \(finalColumns.count)")
                .font(.body).monospacedDigit().foregroundStyle(.secondary)
            Spacer()
            if baseIsUserFile, let base {
                Label("기준: \(base.name)", systemImage: "arrow.trianglehead.merge")
                    .font(.body).foregroundStyle(Color.accentColor)
                    .lineLimit(1).truncationMode(.middle)
                Picker("짝짓기", selection: $matchColumn) {
                    Text("자동 (Code·전화·이메일)").tag(UnifiedColumn?.none)
                    ForEach(matchColumnChoices) { c in
                        Text(c.rawValue).tag(UnifiedColumn?.some(c))
                    }
                }
                .frame(maxWidth: 220)
                .help("기준 파일의 어느 행이 이번 데이터의 어느 행과 같은 대상인지 가릴 컬럼입니다. 사번·주문번호처럼 행마다 고유한 값이 좋아요.")
                Button("해제") { clearUserBase() }
                    .controlSize(.small)
            }
            // ‘만들던 통합본에 이어붙이기’는 없앴다. 밖에서 가져오는 파일은 **틀 하나뿐**이고,
            // 틀은 컬럼 이름만 준다 — 행은 올린 파일에서만 온다. (예전 세션이 기준본을 들고
            // 있으면 위의 ‘해제’로 풀 수 있게만 남겨 둔다.)
            if showAllColumns {
            Divider().frame(height: 16)
            Button("손볼 거리 있는 것만") {
                focusColumns = unresolvedColumns
                showSettledColumns = false
            }
                .disabled(unresolvedColumns.isEmpty)
                .help("오타 의심값·형식이 어긋난 값이 남아 있는 컬럼만 고릅니다.")
            Button("전체 선택") {
                focusColumns = Set(finalColumns)
                showSettledColumns = true      // 고른 걸 숨겨 두지 않는다
            }
            Button("전체 해제") { focusColumns = [] }
            }
        }
        .controlSize(.regular)
        .padding(.horizontal, 24).padding(.vertical, 12)
    }

    // MARK: 하나씩 제안하기

    /// 손볼 거리가 있는 컬럼을 **일이 적은 순서**로. 금방 끝나는 것부터 하나씩 권한다.
    private var proposalOrder: [UnifiedColumn] { cache.proposalOrder }

    /// 아직 손봐야 하는 값들 — `openCount`와 같은 기준, 값 자체가 필요할 때.
    private func openValues(_ review: ColumnReview) -> Set<String> {
        let map = valueMap[review.column] ?? [:]
        switch effectiveType(review) {
        case .format:
            if usesProposalUI(review) {
                return Set(review.proposals
                    .filter { !$0.standard && (map[$0.value] ?? $0.value) == $0.value }
                    .map(\.value))
            }
            return Set(formatFailures(review).map(\.value))
        case .category:
            guard let allowed = allowedValues[review.column], !allowed.isEmpty else { return [] }
            return Set(review.values.filter { !allowed.contains(map[$0.value] ?? $0.value) }.map(\.value))
        case .freeText:
            return Set(review.anomalies.filter { (map[$0.value] ?? $0.value) == $0.value }.map(\.value))
        }
    }

    /// 이 컬럼이 표에서 어디에 붙어 있는지 보여 줄 이웃들 —
    /// 앞뒤 컬럼을 그대로 보여 주고, 행을 알아볼 식별 컬럼(Code·이름)을 맨 앞에 덧붙인다.
    private func neighborColumns(_ col: UnifiedColumn) -> [UnifiedColumn] {
        guard let i = finalColumns.firstIndex(of: col) else { return [col] }
        var out = Array(finalColumns[max(0, i - 2)...min(finalColumns.count - 1, i + 2)])
        let ids = [UnifiedColumn.code, .koreanName, .email]
        if let id = ids.first(where: { finalColumns.contains($0) && !out.contains($0) }) {
            out.insert(id, at: 0)
        }
        return out
    }

    /// “전체 14개 컬럼 중 5번째 · 7월.csv·8월.csv에 있음”
    private func columnPlaceNote(_ col: UnifiedColumn) -> String {
        let pos = (finalColumns.firstIndex(of: col).map { $0 + 1 }) ?? 0
        let owners = plans.enumerated().filter { $0.element.isMapped(col) }
        let names = owners.map { $0.element.fileName }.joined(separator: " · ")
        var line = "합쳐진 표의 \(pos)번째 컬럼"
        if plans.count > 1 { line += " · \(owners.count)/\(plans.count) 파일에 있음 (\(names))" }
        return line
    }

    /// 제안 카드 안의 미니 미리보기 — 합쳐진 표에서 이 컬럼이 어떻게 보이는지,
    /// 손볼 값이 있는 줄을 먼저 골라 파일 색과 함께 보여 준다.
    /// 손볼 값이 있는 줄을 먼저, 그다음 멀쩡한 줄 — 파일도 골고루.
    private func proposalSampleRows(_ col: UnifiedColumn,
                                    flagged: Set<String>) -> [(file: Int, row: [String: String])] {
        var hits: [(file: Int, row: [String: String])] = []
        var rest: [(file: Int, row: [String: String])] = []
        for (i, plan) in plans.enumerated() where plan.isMapped(col) {
            for row in plan.rows.prefix(200) {
                let v = plan.compose(col, from: row)
                guard !v.isEmpty else { continue }
                if flagged.contains(v) {
                    if hits.count < 4 { hits.append((i, row)) }
                } else if rest.count < 4 {
                    rest.append((i, row))
                }
                if hits.count >= 4 && rest.count >= 4 { break }
            }
        }
        return Array((hits + rest).prefix(5))
    }

    @ViewBuilder
    private func proposalPreview(_ review: ColumnReview) -> some View {
        let col = review.column
        let flagged = openValues(review)
        let shown = neighborColumns(col)
        let rows = proposalSampleRows(col, flagged: flagged)
        let border: Color = Color.primary.opacity(0.08)
        return Group {
            if !rows.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    proposalHeaderRow(shown, focus: col)
                    ForEach(rows.indices, id: \.self) { i in
                        proposalRow(rows[i], shown: shown, focus: col, flagged: flagged)
                    }
                }
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(nsColor: .textBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(border, lineWidth: 1))
            }
        }
    }

    /// 미니 표의 머리글 — 지금 보는 컬럼만 넓게, 파랗게.
    private func proposalHeaderRow(_ shown: [UnifiedColumn], focus: UnifiedColumn) -> some View {
        HStack(spacing: 0) {
            Text("파일")
                .font(.body.weight(.semibold)).foregroundStyle(.secondary)
                .frame(width: 120, alignment: .leading)
                .padding(.horizontal, 8).padding(.vertical, 5)
            ForEach(shown) { c in proposalHeaderCell(c, focus: focus) }
        }
        .background(Color.primary.opacity(0.04))
    }

    private func proposalHeaderCell(_ c: UnifiedColumn, focus: UnifiedColumn) -> some View {
        let here = (c == focus)
        let width: CGFloat = here ? 190 : 130
        let background: Color = here ? Color.accentColor.opacity(0.16) : Color.clear
        return VStack(alignment: .leading, spacing: 1) {
            Text(c.rawValue)
                .font(.body.weight(here ? .bold : .semibold))
                .foregroundStyle(here ? Color.accentColor : Color.secondary)
                .lineLimit(1).truncationMode(.tail)
            if here {
                Text("지금 볼 컬럼").font(.body).foregroundStyle(Color.accentColor)
            }
        }
        .frame(width: width, alignment: .leading)
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(background)
        .overlay(alignment: .leading) { proposalEdge(here) }
        .overlay(alignment: .trailing) { proposalEdge(here) }
    }

    private func proposalRow(_ item: (file: Int, row: [String: String]),
                             shown: [UnifiedColumn], focus: UnifiedColumn,
                             flagged: Set<String>) -> some View {
        let plan = plans[item.file]
        let tint: Color = fileTint(item.file)
        return HStack(spacing: 0) {
            HStack(spacing: 5) {
                RoundedRectangle(cornerRadius: 2).fill(tint).frame(width: 3, height: 12)
                Text(plan.fileName)
                    .font(.body).foregroundStyle(tint)
                    .lineLimit(1).truncationMode(.middle)
            }
            .frame(width: 120, alignment: .leading)
            .padding(.horizontal, 8).padding(.vertical, 4)
            ForEach(shown) { c in
                proposalCell(c, plan: plan, row: item.row, focus: focus, flagged: flagged)
            }
        }
        .background(tint.opacity(0.08))
    }

    private func proposalCell(_ c: UnifiedColumn, plan: FilePlan, row: [String: String],
                              focus: UnifiedColumn, flagged: Set<String>) -> some View {
        let here = (c == focus)
        let value = plan.isMapped(c) ? plan.compose(c, from: row) : ""
        let bad = here && flagged.contains(value)
        let width: CGFloat = here ? 190 : 130
        let background: Color = here ? Color.accentColor.opacity(0.10) : Color.clear
        let color: Color = value.isEmpty ? Color.secondary.opacity(0.5)
            : (here ? Color.primary : Color.secondary)
        return HStack(spacing: 4) {
            Text(value.isEmpty ? "—" : value)
                .font(.body.weight(bad ? .semibold : .regular))
                .foregroundStyle(color)
                .lineLimit(1).truncationMode(.tail)
            if bad {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.body).foregroundStyle(.orange)
            }
        }
        .frame(width: width, alignment: .leading)
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(background)
        .overlay(alignment: .leading) { proposalEdge(here) }
        .overlay(alignment: .trailing) { proposalEdge(here) }
        .help(value)
    }

    /// 지금 보는 컬럼의 좌우 세로선 — 표를 관통하는 기둥으로 읽히게.
    @ViewBuilder
    private func proposalEdge(_ on: Bool) -> some View {
        if on { Rectangle().fill(Color.accentColor).frame(width: 2) }
    }

    /// “이 컬럼부터 할까요?” — 한 번에 한 장.
    @ViewBuilder
    private var workProposalCard: some View {
        let order = proposalOrder
        if order.isEmpty {
            workAllSettledCard
        } else {
            let i = min(max(proposalIndex, 0), order.count - 1)
            let col = order[i]
            let review = reviewFor(col)
            let status = focusStatus(col)
            let picked = focusColumns.contains(col)
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    Text((plans.count > 1 || baseIsUserFile ? "2. 정리 — " : "") + "이 컬럼부터 할까요?")
                        .font(.title3.weight(.bold))
                    Spacer()
                    Text("손볼 컬럼 \(order.count)개 · 제안 \(i + 1)번째")
                        .font(.body).monospacedDigit().foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text(col.rawValue)
                            .font(.system(.title2, design: .rounded).weight(.bold))
                            .lineLimit(1).truncationMode(.tail)
                        if i == 0 {
                            Text("가장 빨리 끝나요")
                                .font(.body.weight(.semibold)).foregroundStyle(.green)
                                .padding(.horizontal, 8).padding(.vertical, 3)
                                .background(Capsule().fill(Color.green.opacity(0.14)))
                        }
                        if picked {
                            Text("이미 고름")
                                .font(.body.weight(.semibold)).foregroundStyle(Color.accentColor)
                                .padding(.horizontal, 8).padding(.vertical, 3)
                                .background(Capsule().fill(Color.accentColor.opacity(0.14)))
                        }
                    }
                    Text(status.text)
                        .font(.body).foregroundStyle(.secondary)
                    if let review {
                        Text("합쳐진 표에서는 이렇게 보여요 — " + columnPlaceNote(col))
                            .font(.body).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        ScrollView(.horizontal, showsIndicators: false) {
                            proposalPreview(review)
                        }
                    }
                }
                HStack(spacing: 10) {
                    Button {
                        focusColumns = [col]
                        withBusy("‘\(col.rawValue)’ 검토 화면을 만드는 중…") { startWork() }
                    } label: {
                        Text("이것부터 고치기 →").fontWeight(.semibold)
                    }
                    .controlSize(.large)
                    .buttonStyle(.borderedProminent)
                    Button(picked ? "이번 목록에서 빼기" : "이번에 같이 고치기") {
                        if picked { focusColumns.remove(col) } else { focusColumns.insert(col) }
                    }
                    Spacer()
                    Button("다음 제안 →") {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            proposalIndex = (i + 1) % order.count
                        }
                    }
                    .disabled(order.count < 2)
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.accentColor.opacity(0.06)))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(0.25), lineWidth: 1))
        }
    }

    /// 손댈 게 없어 이번에 고르지 않아도 결과에 그대로 완성되는 컬럼들.
    private var settledColumns: [UnifiedColumn] { cache.settled }

    /// 그중 사람 판단 없이 값을 다듬을 수 있는 컬럼 — 이미 정해진 통일 규칙이 있는 것들.
    private var autoEditableColumns: [UnifiedColumn] { cache.autoEditable }

    /// 값을 정리해야 하는 컬럼들 — 미정리 값이 남았거나 파일마다 모양이 다른 컬럼.
    private var columnsNeedingClean: [(column: UnifiedColumn, note: String)] { cache.needClean }

    /// 이 창의 전부 — “얼마나 됐고, 어디서 이어서 하면 되는지”.
    /// 키 고르기·빈칸 채우기 같은 실제 작업은 전부 작업대(완성본 미리보기)에서 한다.
    @ViewBuilder
    private var workProgressCard: some View {
        let holeCells = cache.templateCells - cache.templateFilled
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("완성본 미리보기에서 채울 컬럼을 고르세요")
                    .font(.system(.title2, design: .rounded).weight(.bold))
                Text("표에서 파란 열이 아직 빈 행이 있는 칸입니다. 머리글을 누르면 그 컬럼을 채웁니다.")
                    .font(.body).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("성·이름처럼 둘로 나뉜 컬럼은 틀 안의 칸과 함께 체크한 뒤 "
                     + "‘이 칸들 채우기’를 누르면 한 칸으로 붙습니다 — 국문 성 + 국문 이름 → 김 철수.")
                    .font(.body).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button { openPreviewWindow() } label: {
                Label("완성본 미리보기 열기", systemImage: "macwindow.badge.plus")
                    .fontWeight(.semibold)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)

            if cache.templateCells > 0 { templateProgressBar }
            Divider()
            HStack(alignment: .top, spacing: 28) {
                if cache.templateCells > 0 {
                    progressStat("더 채워야 할 칸", holeCells.formatted(),
                                 "틀 안 \(cache.holes.count)개 컬럼에 남아 있어요", .accentColor)
                }
                if !cache.needClean.isEmpty {
                    progressStat("값을 정리할 컬럼", "\(cache.needClean.count)개",
                                 "오타·형식이 어긋난 값이 남았어요", .orange)
                }
                if let dup = base?.duplicateRows.count, dup > 0 {
                    progressStat("중복으로 보이는 행", "\(dup)행",
                                 "표시만 해 뒀어요 — 지울지는 직접", .orange)
                }
                if cache.templateCells > 0 && cache.holes.isEmpty && cache.needClean.isEmpty {
                    progressStat("남은 일", "없음", "이제 가져가면 돼요", .green)
                }
                Spacer(minLength: 0)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(Color.accentColor.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(Color.accentColor.opacity(0.22), lineWidth: 1))
    }

    /// 틀이 얼마나 찼는지 막대 하나로 — 이 도구의 진행도는 이것 하나면 된다.
    private var templateProgressBar: some View {
        let pct = Double(cache.templateFilled) / Double(max(cache.templateCells, 1))
        return VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("틀 안 채움").font(.body.weight(.semibold))
                Text("\(Int(pct * 100))%").font(.body.monospacedDigit().weight(.bold))
                    .foregroundStyle(Color.accentColor)
                Spacer()
                Text("\(cache.templateFilled) / \(cache.templateCells)칸")
                    .font(.body.monospacedDigit()).foregroundStyle(.secondary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.08))
                    Capsule().fill(Color.accentColor.opacity(0.75))
                        .frame(width: max(2, geo.size.width * pct))
                }
            }
            .frame(height: 8)
        }
    }

    private func progressStat(_ title: String, _ value: String,
                              _ note: String, _ tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.body).foregroundStyle(.secondary)
            Text(value).font(.system(.title, design: .rounded).weight(.bold))
                .foregroundStyle(tint).monospacedDigit()
            Text(note).font(.body).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: 240, alignment: .leading)
    }

    /// 숫자가 맞는지 확인하는 칸 — 행이 빠지거나 늘지 않았는지만 본다.
    @ViewBuilder
    private var workVerifyCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("데이터 정합성").font(.headline)
            rowCountTable
            HStack(spacing: 8) {
                Button("파일 다시 읽기") { reloadWorkFiles() }
                    .controlSize(.small)
                    .disabled(isLoadingFiles)
                    .help("올린 파일을 원본에서 다시 읽어 값만 새로 고칩니다. "
                          + "정해 둔 컬럼 구성(합친 칸·구분자)은 그대로 이어 갑니다.")
                Text("값이 한 칸씩 밀려 보이거나 원본이 바뀌었을 때 쓰세요.")
                    .font(.body).foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            if let key = keyColumn {
                Text("같은 행인지 가리는 키: ‘\(key.rawValue)’"
                     + ((base?.generatedKeys ?? 0) > 0
                        ? " · 키가 비어 있던 \(base!.generatedKeys)행엔 번호를 만들어 넣었어요" : ""))
                    .font(.body).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color.primary.opacity(0.03)))
    }

    /// 지금 무엇이 남았는지 한 카드로 — 채울 것 / 정리할 것 / 이미 끝난 것.
    @ViewBuilder
    private var workTodoSummary: some View {
        let fill = emptyColumns
        let clean = columnsNeedingClean
        let settled = settledColumns
        let holes = cache.holes
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("남은 일").font(.headline)
                if cache.templateCells > 0 {
                    let pct = Int((Double(cache.templateFilled) / Double(cache.templateCells)) * 100)
                    Text("틀 안 \(templateColumns.count)컬럼 × \(base?.rows.count ?? 0)행 중 \(pct)% 채워짐")
                        .font(.body).monospacedDigit().foregroundStyle(.secondary)
                }
            }
            if fill.isEmpty && clean.isEmpty && holes.isEmpty {
                Label("틀 안이 다 찼고 정리할 값도 없습니다 — 이제 가져가면 돼요.",
                      systemImage: "checkmark.seal.fill")
                    .font(.body).foregroundStyle(.green)
            }
            // 이 도구가 하려는 일 그 자체 — 틀 안의 빈 행 채우기.
            if !holes.isEmpty {
                let rows = base?.rows.count ?? 0
                todoLine("square.and.pencil",
                         "틀 안에 빈 행이 남은 컬럼 \(holes.count)개",
                         holes.prefix(12).map { "\($0.column.rawValue) — \($0.empty)/\(rows)행 비어 있음" },
                         "틀 밖 컬럼을 없애는 게 아니라, 틀 안의 이 빈 행을 채우는 게 목표예요.",
                         "‘\(holes[0].column.rawValue)’ 채우기…") { fillTarget = holes[0].column }
            }
            if !fill.isEmpty {
                todoLine("rectangle.dashed", "채워야 할 컬럼 \(fill.count)개",
                         fill.map(\.rawValue),
                         templateName == nil ? "값이 하나도 안 들어온 컬럼이에요."
                                             : "틀 ‘\(templateName!)’에는 있는데 아직 값이 없어요.",
                         "‘\(fill[0].rawValue)’ 채우기…") { configColumn = fill[0] }
            }
            if !clean.isEmpty {
                todoLine("wand.and.stars", "값을 정리할 컬럼 \(clean.count)개",
                         clean.map { item in
                             let ex = (cache.samples[item.column] ?? []).prefix(2)
                                 .joined(separator: " · ")
                             return "\(item.column.rawValue) (\(item.note))"
                                 + (ex.isEmpty ? "" : " — \(ex)")
                         },
                         "오타·형식이 어긋난 값이 남아 있어요.",
                         "‘\(clean[0].column.rawValue)’부터 정리 →") {
                    focusColumns = [clean[0].column]
                    withBusy("‘\(clean[0].column.rawValue)’ 검토 화면을 만드는 중…") { startWork() }
                }
            }
            if !settled.isEmpty {
                todoLine("checkmark.circle.fill", "손댈 것 없이 완성되는 컬럼 \(settled.count)개",
                         settled.map(\.rawValue),
                         "고르지 않아도 결과 파일에 그대로 들어갑니다.", nil, nil)
                if !autoEditableColumns.isEmpty {
                    Toggle(isOn: $autoFillSettled) {
                        Text("이 중 \(autoEditableColumns.count)개는 정해 둔 규칙대로 다듬어서 채우기")
                            .font(.body)
                    }
                    .toggleStyle(.checkbox)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(fill.isEmpty && clean.isEmpty ? Color.green.opacity(0.07)
                                                : Color.primary.opacity(0.04)))
    }

    /// 남은 일 한 줄 — 무엇이 몇 개인지, 어떤 컬럼인지, 바로 가는 버튼.
    private func todoLine(_ symbol: String, _ title: String, _ names: [String],
                          _ why: String, _ actionTitle: String?,
                          _ action: (() -> Void)?) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol).foregroundStyle(.secondary).font(.body)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.semibold))
                Text(names.prefix(8).joined(separator: " · ")
                     + (names.count > 8 ? " 외 \(names.count - 8)개" : ""))
                    .font(.body).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(why).font(.body).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if let actionTitle, let action {
                Button(actionTitle, action: action).controlSize(.small)
            }
        }
    }

    /// “이건 안 골라도 알아서 완성됩니다” — 고르지 않은 컬럼이 사라지는 게 아님을 보여 준다.
    @ViewBuilder
    private var workSettledSummary: some View {
        let settled = settledColumns
        if !settled.isEmpty {
            let auto = autoEditableColumns
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
                    Text("손댈 것 없이 완성되는 컬럼 \(settled.count)개")
                        .font(.body.weight(.semibold))
                    Spacer()
                    Button(showSettledSummary ? "접기" : "모두 보기") {
                        withAnimation(.easeInOut(duration: 0.18)) { showSettledSummary.toggle() }
                    }
                    .controlSize(.small)
                }
                Text((showSettledSummary ? settled : Array(settled.prefix(6)))
                        .map(\.rawValue).joined(separator: " · ")
                     + (showSettledSummary || settled.count <= 6 ? "" : " … 외 \(settled.count - 6)개"))
                    .font(.body).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("고르지 않아도 결과 파일에 그대로 들어갑니다 — 값도 원본 그대로예요.")
                    .font(.body).foregroundStyle(.secondary)
                if !auto.isEmpty {
                    Toggle(isOn: $autoFillSettled) {
                        Text("이 중 \(auto.count)개는 정해 둔 규칙대로 다듬어서 채우기 (\(auto.prefix(3).map(\.rawValue).joined(separator: " · "))\(auto.count > 3 ? " 외" : ""))")
                            .font(.body)
                    }
                    .toggleStyle(.checkbox)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.green.opacity(0.07)))
        }
    }

    /// 어떤 값을 남길지 골라 행을 거르는 창 — 지우는 게 아니라 감추는 것.
    @ViewBuilder
    private var rowFilterSheet: some View {
        if let col = filterColumn {
            let counts = filterValueCounts(col)
            let keeping = counts.filter { filterKeep.contains($0.value) }
                .reduce(0) { $0 + $1.count }
            VStack(alignment: .leading, spacing: 12) {
                Text("어떤 행을 남길까요?").font(.title2.weight(.bold))
                Picker("기준 컬럼", selection: Binding(
                    get: { col },
                    set: { newCol in
                        filterColumn = newCol
                        filterKeep = Set(filterValueCounts(newCol).map(\.value))
                    })) {
                    ForEach(filterCandidates) { c in Text(c.rawValue).tag(c) }
                }
                .frame(maxWidth: 360)
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(counts, id: \.value) { item in
                            Toggle(isOn: Binding(
                                get: { filterKeep.contains(item.value) },
                                set: { on in
                                    if on { filterKeep.insert(item.value) }
                                    else { filterKeep.remove(item.value) }
                                })) {
                                HStack {
                                    Text(item.value).font(.body)
                                    Spacer()
                                    Text("\(item.count)행")
                                        .font(.body.monospacedDigit()).foregroundStyle(.secondary)
                                }
                            }
                            .toggleStyle(.checkbox)
                        }
                    }
                }
                .frame(maxHeight: 260)
                HStack(spacing: 8) {
                    Button("모두 남기기") { filterKeep = Set(counts.map(\.value)) }
                        .controlSize(.small)
                    Button("모두 빼기") { filterKeep = [] }
                        .controlSize(.small)
                    Spacer()
                    Text("남는 행 \(keeping)행 / 전체 \(counts.reduce(0) { $0 + $1.count })행")
                        .font(.body.weight(.semibold))
                }
                Text("빼는 행은 지우는 게 아니라 결과에서 잠깐 감춰 둡니다. ‘모두 남기기’로 언제든 되돌려요.")
                    .font(.body).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("거르지 않기") {
                        showFilterSheet = false
                        applyRowFilter(nil, keep: [])
                    }
                    Spacer()
                    Button("취소") { showFilterSheet = false }
                    Button("이대로 하기") {
                        showFilterSheet = false
                        applyRowFilter(col, keep: filterKeep)
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(20)
            .frame(minWidth: 520)
        }
    }

    /// 여러 칸을 한 칸으로 합치기 — 어디에·어떤 순서로·무엇을 사이에 넣을지 정한다.
    @ViewBuilder
    private var mergeConfirmSheet: some View {
        if let cols = confirmMerge, cols.count >= 2 {
            ColumnMergeSetupSheet(
                columns: cols,
                templateColumns: Set(templateColumns),
                sample: { col in sampleValues(col, limit: 1) },
                onApply: { target, order, separator, mode, thenClean in
                    confirmMerge = nil
                    focusColumns = [target]
                    withBusy("칸을 합치는 중…") {
                        applyColumnMerge(target: target, order: order,
                                         separator: separator, mode: mode)
                        if thenClean { startWork() }
                    }
                },
                onClose: { confirmMerge = nil })
        }
    }

    /// 고른 칸들을 한 칸으로 — 값은 정한 순서대로, 정한 구분자로 이어 붙는다.
    /// (행은 건드리지 않는다. 어느 칸의 값을 어떻게 읽을지만 바꾼다.)
    private func applyColumnMerge(target: UnifiedColumn,
                                  order: [UnifiedColumn],
                                  separator: String,
                                  mode: CombineMode = .join,
                                  keepSource: Bool = false) {
        mutatePlans(target: target, order: order, separator: separator,
                    mode: mode, keepSource: keepSource)
        rebuildWorkColumns()
        scheduleSave()
    }

    /// 계획(파일별 컬럼 매핑)만 고친다 — **행은 건드리지 않는다.**
    /// 여러 칸을 연달아 채울 때 이걸 여러 번 부르고 마지막에 한 번만 다시 만든다.
    private func mutatePlans(target: UnifiedColumn,
                             order: [UnifiedColumn],
                             separator: String,
                             mode: CombineMode = .join,
                             /// 복제: 값을 가져오되 **원래 컬럼도 그대로 남긴다**.
                             keepSource: Bool = false) {
        for i in plans.indices {
            var sources: [String] = []
            for col in order {
                if let hs = plans[i].sources[col] { sources += hs }
            }
            guard !sources.isEmpty else { continue }
            plans[i].sources[target] = sources
            plans[i].separators[target] = separator
            plans[i].combine[target] = mode
            if !plans[i].headers.contains(target.rawValue) {
                plans[i].headers.append(target.rawValue)
            }
            if keepSource { continue }      // 복제는 원래 컬럼을 건드리지 않는다
            for col in order where col != target {
                // 파일의 **진짜 헤더 이름**으로 지워야 한다. 컬럼 이름은 앞뒤 공백을 떼어
                // 쓰는데(`대학교 재학/휴학/졸업 예정`), 파일 헤더엔 공백이 붙어 있을 수 있어
                // (`… 예정 `) 이름만으로 지우면 껍데기 컬럼이 목록에 남았다.
                // 그 껍데기는 값이 하나도 없어서, 거기에 해 둔 값 정리는 아무 일도 안 한다.
                let raw = plans[i].sources[col] ?? [col.rawValue]
                plans[i].sources[col] = nil
                plans[i].separators[col] = nil
                plans[i].combine[col] = nil
                plans[i].headers.removeAll { raw.contains($0) || $0 == col.rawValue }
            }
        }
        // 이미 해 둔 값 정리도 새 칸으로 옮겨 둔다 (복제는 원래 컬럼 것을 남겨 둔다).
        guard !keepSource else { return }
        for col in order where col != target {
            if let m = valueMap.removeValue(forKey: col) {
                valueMap[target] = (valueMap[target] ?? [:]).merging(m) { a, _ in a }
            }
            // 허용 목록(매핑표로 정한 값들)도 같이 옮긴다 — 안 옮기면 옮긴 칸이
            // 그 목록을 잃고 ‘정리할 값’이 다시 살아난다.
            if let a = allowedValues.removeValue(forKey: col), allowedValues[target] == nil {
                allowedValues[target] = a
            }
            typeOverride[col] = nil
            formatChoice[col] = nil
            customFormat[col] = nil
        }
    }

    // MARK: - 틀의 빈 칸 채우기

    /// 틀에는 있는데 값이 하나도 없는 칸들 — 여기부터 채워야 완성본이 된다.
    private var emptyTemplateColumns: [UnifiedColumn] {
        guard !templateColumns.isEmpty else { return [] }
        let empty = Set(cache.empty)
        return templateColumns.filter { empty.contains($0) && generatedColumns[$0] == nil }
    }

    /// 틀에 없는 컬럼들 — 대개 이 값들이 틀 안의 칸으로 옮겨 가야 한다.
    private var outsideTemplateColumns: [UnifiedColumn] {
        guard !templateColumns.isEmpty else { return [] }
        let inTemplate = Set(templateColumns)
        return finalColumns.filter { !inTemplate.contains($0) }
    }

    /// 이 빈 칸에 넣을 만한 후보 (값 모양·이름으로 고른 것).
    private func fillCandidates(for col: UnifiedColumn) -> [(column: UnifiedColumn, percent: Int)] {
        matchSuggestions.compactMap { s in
            guard let b = s.best, b.column == col else { return nil }
            return (s.source, b.percent)
        }
    }

    /// 지금 해야 할 **한 가지** — 앱은 길잡이, 작업대(미리보기)는 실제 작업.
    /// 급한 순서: 틀 빈 칸 → 틀 밖 컬럼 → 값 정리 → 중복 확인 → 끝.
    private var nextStepHint: (text: String, column: UnifiedColumn?) {
        if let col = emptyTemplateColumns.first {
            return ("‘\(col.rawValue)’ 칸이 통째로 비어 있어요 — 어디서 가져올지 정해 주세요", col)
        }
        // 틀 안의 **빈 행**을 채우는 게 이 도구의 목표 — 틀 밖 컬럼을 없애는 게 아니다.
        if let hole = cache.holes.first {
            return ("‘\(hole.column.rawValue)’에 빈 행이 \(hole.empty)개 남았어요 — 어느 컬럼에서 가져올까요",
                    hole.column)
        }
        if let first = cache.needClean.first {
            return ("‘\(first.column.rawValue)’에 정리할 값이 \(first.note) 남았어요", first.column)
        }
        if let dup = base?.duplicateRows.count, dup > 0 {
            return ("중복으로 보이는 행 \(dup)개를 확인해 주세요 (지울지는 직접 정합니다)", nil)
        }
        return ("더 할 일이 없어요 — 이대로 가져가면 됩니다", nil)
    }

    /// 지금 상태가 믿을 만한지 한 줄로 — 행 수·중복·빈 칸·정리할 값.
    private var verificationBar: some View {
        let total = plans.reduce(0) { $0 + $1.rows.count }
        let result = base?.rows.count ?? total
        let dup = base?.duplicateRows.count ?? 0
        return HStack(spacing: 10) {
            Text("지금 상태").font(.body.weight(.semibold))
            checkChip(result == total ? "행 수 \(result) = \(total) ✓"
                                      : "행 수 \(result) / \(total)",
                      ok: result == total, action: nil)
            if dup > 0 {
                checkChip("중복 \(dup)행 표시됨", ok: false) {
                    preview.showDuplicatesOnly = true
                    openPreviewWindow()
                }
            }
            if !emptyTemplateColumns.isEmpty {
                checkChip("빈 칸 \(emptyTemplateColumns.count)개", ok: false) {
                    if let c = emptyTemplateColumns.first { fillTarget = c }
                }
            }
            // 틀을 쓰는 동안의 진짜 진행률 — 틀 안 칸이 얼마나 찼는가.
            if cache.templateCells > 0 {
                let pct = Int((Double(cache.templateFilled) / Double(cache.templateCells)) * 100)
                let blank = cache.templateCells - cache.templateFilled
                checkChip(blank == 0 ? "틀 안 다 찼어요 ✓" : "틀 안 \(pct)% 참 · 빈 칸 \(blank)",
                          ok: blank == 0) {
                    if let c = cache.holes.first?.column { fillTarget = c }
                }
            }
            if !outsideTemplateColumns.isEmpty {
                // 틀 밖은 ‘없앨 것’이 아니라 틀 안을 채울 **재료**다 — 경고색을 쓰지 않는다.
                checkChip("틀 밖 재료 \(outsideTemplateColumns.count)개", ok: true, tint: .secondary) {
                    focusColumns = Set(outsideTemplateColumns)
                }
            }
            if !cache.needClean.isEmpty {
                checkChip("정리할 값 \(cache.needClean.count)컬럼", ok: false) {
                    if let c = cache.needClean.first?.column {
                        focusColumns = [c]
                        withBusy("검토 화면을 만드는 중…") { startWork() }
                    }
                }
            }
            if !preview.changes.isEmpty {
                checkChip("바뀐 값 \(preview.changes.count)개", ok: true) { openPreviewWindow() }
            }
            Spacer(minLength: 8)
        }
        .padding(.horizontal, 24).padding(.vertical, 8)
        .background(Color.primary.opacity(0.03))
    }

    @ViewBuilder
    private func checkChip(_ text: String, ok: Bool, tint override: Color? = nil,
                           action: (() -> Void)?) -> some View {
        let tint: Color = override ?? (ok ? .green : .orange)
        if let action {
            Button(action: action) { chipLabel(text, tint) }
                .buttonStyle(.plain)
        } else {
            chipLabel(text, tint)
        }
    }

    private func chipLabel(_ text: String, _ tint: Color) -> some View {
        Text(text)
            .font(.body.weight(.medium))
            .foregroundStyle(tint)
            .padding(.horizontal, 10).padding(.vertical, 3)
            .background(Capsule().fill(tint.opacity(0.12)))
    }

    /// 틀의 빈 칸을 하나씩 채우는 카드 — 가져오기 / 합치기 / 만들기 / 비워 두기.
    @ViewBuilder
    private var templateFillCard: some View {
        let empties = emptyTemplateColumns
        if !empties.isEmpty {
            let i = min(max(emptyIndex, 0), empties.count - 1)
            let col = empties[i]
            let candidates = fillCandidates(for: col)
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text("틀의 빈 칸 채우기").font(.title3.weight(.bold))
                    Text("\(empties.count)개 중 \(i + 1)번째")
                        .font(.body).monospacedDigit().foregroundStyle(.secondary)
                    Spacer()
                    if outsideTemplateColumns.count > 0 {
                        Text("틀 밖 컬럼 \(outsideTemplateColumns.count)개가 아직 남아 있어요")
                            .font(.body).foregroundStyle(.orange)
                    }
                }
                Text(col.rawValue)
                    .font(.system(.title2, design: .rounded).weight(.bold))
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                if let first = candidates.first {
                    Text("파일의 ‘\(first.column.rawValue)’가 이 칸 같아요 (\(first.percent)%)")
                        .font(.body).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("이 칸에 넣을 값을 파일에서 못 찾았어요. 직접 고르거나, 합치거나, 만들어 넣으면 됩니다.")
                        .font(.body).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 10) {
                    if let first = candidates.first {
                        Button {
                            withBusy("‘\(first.column.rawValue)’를 옮기는 중…") {
                                applyColumnMerge(target: col, order: [first.column], separator: "")
                            }
                        } label: {
                            Text("‘\(first.column.rawValue)’ 값 가져오기").fontWeight(.semibold)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    Button("이 값 채우기…") { fillTarget = col }
                    Button("파일별로 직접 고르기…") { configColumn = col }
                    Spacer()
                    Button("비워 두기") {
                        withAnimation { emptyIndex = (i + 1) % max(empties.count, 1) }
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.orange.opacity(0.07)))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.orange.opacity(0.35), lineWidth: 1))
        }
    }

    /// ‘이 값 채우기’ — 어디서 가져올지 고르고, 여럿이면 어떻게 넣을지 정한다.
    @ViewBuilder
    private var fillSheet: some View {
        if let target = fillTarget {
            FillColumnSheet(
                target: target,
                inTemplate: templateColumns.contains(target),
                candidates: fillSourceCandidates(for: target),
                onApply: { sources, separator in
                    fillTarget = nil
                    guard !sources.isEmpty else { return }
                    focusColumns = [target]
                    withBusy("‘\(target.rawValue)’를 채우는 중…") {
                        applyColumnMerge(target: target, order: sources, separator: separator)
                    }
                },
                onGenerate: {
                    fillTarget = nil
                    generateFixed = ""
                    generateSerial = keyPatternText
                    generateIsSerial = false
                    generateColumn = target
                },
                onClose: { fillTarget = nil })
        }
    }

    /// 여러 컬럼을 고른 뒤 ‘데이터 정리하기’를 눌렀을 때 — 틀 안의 칸마다
    /// 어느 컬럼에서 값을 가져올지 한 줄씩 정하는 창.
    @ViewBuilder
    private var fillFromSheet: some View {
        if !fillFromSelection.isEmpty {
            let picked = fillFromSelection
            let holeMap = cache.holeByColumn
            let targets = fillTargets(picked, holes: holeMap)
            FillFromSheet(
                targets: targets,
                holes: holeMap,
                rowTotal: base?.rows.count ?? 0,
                // 함께 고른 컬럼은 전부 후보 맨 위로 (틀 안이든 밖이든).
                selectedOutside: picked,
                candidates: Dictionary(uniqueKeysWithValues:
                    targets.map { t in
                        (t, fillFromCandidates(for: t,
                                               preferring: picked.filter { $0 != t }))
                    }),
                onApply: { plan, thenClean in
                    fillFromSelection = []
                    guard !plan.isEmpty else { return }
                    focusColumns = Set(plan.map(\.target))
                    withBusy("\(plan.count)개 칸을 채우는 중…") {
                        applyColumnFills(plan)
                        // ‘채우고 값도 통일’을 골랐으면 그대로 정리 화면까지 데려간다.
                        if thenClean { startWork() }
                    }
                },
                onGenerate: { col in
                    // 가져올 데가 없는 칸 — 패턴(같은 값·번호 매기기)을 만들어 채운다.
                    fillFromSelection = []
                    generateFixed = ""
                    generateSerial = keyPatternText
                    generateIsSerial = false
                    generateColumn = col
                },
                onCleanOnly: {
                    let cols = picked
                    fillFromSelection = []
                    focusColumns = Set(cols)
                    withBusy("검토 화면을 만드는 중…") { startWork() }
                },
                onClose: { fillFromSelection = [] })
        }
    }

    /// 한 컬럼의 값을 다른 컬럼으로 옮기는 창.
    @ViewBuilder
    private var moveSheet: some View {
        if let source = moveSource {
            let holeMap = cache.holeByColumn
            // 받을 수 있는 컬럼 — 틀 안을 먼저, 그중에서도 빈 행이 많은 것부터.
            let dests = finalColumns.filter { $0 != source }
                .map { (column: $0,
                        inTemplate: templateColumns.contains($0),
                        blank: holeMap[$0] ?? (cache.empty.contains($0) ? (base?.rows.count ?? 0) : 0)) }
                .sorted {
                    if $0.inTemplate != $1.inTemplate { return $0.inTemplate }
                    return $0.blank > $1.blank
                }
            ColumnActionSheet(
                source: source,
                destinations: dests,
                rowTotal: base?.rows.count ?? 0,
                sample: { col in firstSampleValue(col) },
                overlap: { dest in overlapCount(source, dest) },
                onApply: { dest, order, separator, mode, keepSource in
                    moveSource = nil
                    focusColumns = [dest]
                    withBusy(keepSource ? "‘\(source.rawValue)’의 값을 복제하는 중…"
                                        : "‘\(source.rawValue)’의 값을 옮기는 중…") {
                        applyColumnMerge(target: dest, order: order, separator: separator,
                                         mode: mode, keepSource: keepSource)
                        verifyRowCount(keepSource ? "값을 복제한" : "값을 옮긴")
                    }
                },
                onClean: {
                    moveSource = nil
                    cleanHubColumn = source          // 이어서 정리 작업 창으로
                },
                onMerge: {
                    moveSource = nil
                    fillFromSelection = [source]
                },
                onClose: { moveSource = nil })
        }
    }

    /// 두 컬럼이 **같은 행에서 둘 다 차 있는지** 센다 — 옮기기·복제의 충돌 규모.
    private func overlapCount(_ source: UnifiedColumn, _ dest: UnifiedColumn)
        -> (both: Int, srcOnly: Int, destOnly: Int) {
        var both = 0, onlySource = 0, onlyDest = 0
        for plan in plans {
            let hasSource = plan.isMapped(source), hasDest = plan.isMapped(dest)
            guard hasSource || hasDest else { continue }
            for row in plan.rows {
                let a = hasSource ? plan.compose(source, from: row) : ""
                let b = hasDest ? plan.compose(dest, from: row) : ""
                if !a.isEmpty, !b.isEmpty { both += 1 }
                else if !a.isEmpty { onlySource += 1 }
                else if !b.isEmpty { onlyDest += 1 }
            }
        }
        return (both, onlySource, onlyDest)
    }

    /// 올린 파일들을 통틀어 이 컬럼의 **값 예시**. 창마다 따로 긁던 것을 하나로.
    private func sampleValues(_ col: UnifiedColumn, limit: Int = 3) -> [String] {
        var out: [String] = []
        for plan in plans {
            for v in plan.sampleValues(col, limit: limit) where !out.contains(v) {
                out.append(v)
                if out.count >= limit { return out }
            }
        }
        return out
    }

    /// 이 컬럼의 값 하나 — 창에서 결과를 실제 값으로 보여 주기 위한 것.
    private func firstSampleValue(_ col: UnifiedColumn) -> String {
        sampleValues(col, limit: 1).first ?? ""
    }

    /// 값을 **받을** 칸들. 빈 행이 있는 틀 안 칸이 1순위지만, 다 차 있는 칸이나
    /// 틀 밖 칸도 받는 자리가 될 수 있어야 한다 — ‘이름’ 칸을 성 + 이름으로
    /// 다시 채우는 것처럼. (그래서 이 창이 빈 채로 뜨는 일은 없다.)
    private func fillTargets(_ picked: [UnifiedColumn],
                             holes: [UnifiedColumn: Int]) -> [UnifiedColumn] {
        let withHoles = picked
            .filter { templateColumns.contains($0) && (holes[$0] ?? 0) > 0 }
            .sorted { (holes[$0] ?? 0) > (holes[$1] ?? 0) }
        if !withHoles.isEmpty { return withHoles }
        let inTemplate = picked.filter { templateColumns.contains($0) }
        return inTemplate.isEmpty ? picked : inTemplate
    }

    /// 이 칸에 넣을 만한 후보 — 함께 고른 틀 밖 컬럼을 맨 앞에 세운다.
    private func fillFromCandidates(for target: UnifiedColumn,
                                    preferring outside: [UnifiedColumn])
        -> [FillFromSheet.Candidate] {
        let recommended = Dictionary(uniqueKeysWithValues:
            fillCandidates(for: target).map { ($0.column, $0.percent) })
        let prefer = Set(outside)
        var seen = Set<UnifiedColumn>()
        var out: [FillFromSheet.Candidate] = []
        for (_, plan) in plans.enumerated() {
            for header in plan.headers {
                guard let col = UnifiedColumn(rawValue: header), col != target,
                      plan.isMapped(col), seen.insert(col).inserted else { continue }
                // 틀 안에서 이미 제 몫을 하는 칸은 빼 둔다 (틀 밖·빈 칸 위주로).
                if templateColumns.contains(col), !cache.empty.contains(col),
                   recommended[col] == nil, !prefer.contains(col) { continue }
                let samples = plan.sampleValues(col, limit: 2)
                // 함께 고른 컬럼은 값 예시를 못 뽑아도 후보에서 빼지 않는다
                // (골라 놨는데 목록에 없으면 왜 안 되는지 알 수가 없다).
                guard !samples.isEmpty || prefer.contains(col) else { continue }
                out.append(.init(column: col, fileName: plan.fileName,
                                 samples: samples, percent: recommended[col]))
            }
        }
        // 함께 고른 컬럼 → (틀 안 칸을 채우는 거라면) 틀 밖 컬럼 → 닮은 정도 순.
        let fillingTemplate = templateColumns.contains(target)
        func rank(_ c: FillFromSheet.Candidate) -> Int {
            var score = c.percent ?? 0
            if prefer.contains(c.column) { score += 1000 }
            if fillingTemplate, !templateColumns.contains(c.column) { score += 300 }
            return score
        }
        return out.sorted { rank($0) > rank($1) }
    }

    /// 여러 칸을 한 번에 채운다 — 계획만 고쳐 두고 **다시 만드는 건 마지막에 한 번**.
    private func applyColumnFills(_ plan: [(target: UnifiedColumn,
                                           sources: [UnifiedColumn],
                                           separator: String,
                                           mode: CombineMode)]) {
        for item in plan {
            mutatePlans(target: item.target, order: item.sources,
                        separator: item.separator, mode: item.mode)
        }
        rebuildWorkColumns()
        verifyRowCount("칸을 채운")
        scheduleSave()
    }

    /// 이 칸에 넣을 만한 후보들 — **파일마다** 어떤 칸이 있는지 값 예시와 함께.
    private func fillSourceCandidates(for target: UnifiedColumn)
        -> [FillColumnSheet.Candidate] {
        let recommended = Dictionary(uniqueKeysWithValues:
            fillCandidates(for: target).map { ($0.column, $0.percent) })
        var out: [FillColumnSheet.Candidate] = []
        for (i, plan) in plans.enumerated() {
            for header in plan.headers {
                guard let col = UnifiedColumn(rawValue: header), col != target,
                      plan.isMapped(col) else { continue }
                // 이미 틀 안에서 제 몫을 하는 칸은 후보에서 빼 둔다 (틀 밖·빈 칸 위주로).
                if templateColumns.contains(col), !cache.empty.contains(col),
                   recommended[col] == nil { continue }
                let samples = plan.sampleValues(col, limit: 3)
                guard !samples.isEmpty else { continue }
                out.append(.init(column: col, fileName: plan.fileName, fileIndex: i,
                                 samples: samples, percent: recommended[col]))
            }
        }
        // 추천을 위로.
        return out.sorted { ($0.percent ?? 0) > ($1.percent ?? 0) }
    }

    /// 빈 칸에 넣을 값을 만들어 주는 창 — 같은 값으로 채우거나, 번호를 매기거나.
    @ViewBuilder
    private var generateSheet: some View {
        if let col = generateColumn {
            let pattern = KeyPattern(example: generateSerial) ?? .auto
            VStack(alignment: .leading, spacing: 12) {
                Text("‘\(col.rawValue)’ 값 만들기").font(.title2.weight(.bold))
                Picker("", selection: $generateIsSerial) {
                    Text("모든 행에 같은 값").tag(false)
                    Text("번호 매기기").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 320)
                if generateIsSerial {
                    HStack(spacing: 8) {
                        Text("첫 번호").font(.body.weight(.semibold))
                        TextField("예: 6F10001", text: $generateSerial)
                            .textFieldStyle(.roundedBorder).frame(width: 180)
                        Text("→ \(pattern.sample)").font(.body).foregroundStyle(.secondary)
                    }
                } else {
                    HStack(spacing: 8) {
                        Text("넣을 값").font(.body.weight(.semibold))
                        TextField("예: POSTECH", text: $generateFixed)
                            .textFieldStyle(.roundedBorder).frame(width: 240)
                    }
                }
                Text("비어 있는 칸에만 넣습니다 — 이미 값이 있는 행은 건드리지 않아요.")
                    .font(.body).foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Button("취소") { generateColumn = nil }
                    Button("넣기") {
                        let rule: GeneratedValue = generateIsSerial
                            ? .serial(pattern) : .fixed(generateFixed)
                        generateColumn = nil
                        withBusy("값을 만들어 넣는 중…") {
                            generatedColumns[col] = rule
                            rebuildStatusCache()
                            refreshPreview()
                            scheduleSave()
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!generateIsSerial && generateFixed.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .padding(20)
            .frame(minWidth: 460)
        }
    }

    /// 컬럼을 눌러 고르는 판 — 하나 고르면 정리하러 가고, 여럿 고르면 함께 정리하거나 합친다.
    private var workColumnBoard: some View {
        let split = workColumnSplit
        let picked = finalColumns.filter { focusColumns.contains($0) }
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text("컬럼 고르기").font(.headline)
                Text("눌러서 고르고, 여러 개를 골라 함께 정리하거나 한 칸으로 합칠 수 있어요")
                    .font(.body).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button("손볼 것만") {
                    focusColumns = Set(split.todo)
                    showAllColumns = false
                }
                .disabled(split.todo.isEmpty)
                Button("모두") { focusColumns = Set(finalColumns); showAllColumns = true }
                Button("해제") { focusColumns = [] }
            }
            if !picked.isEmpty { boardActionBar(picked) }
            let outside = Set(outsideTemplateColumns)
            if !outside.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.arrow.triangle.2.circlepath")
                        .foregroundStyle(.orange)
                    Text("틀 밖 컬럼 \(outside.count)개")
                        .font(.body.weight(.semibold)).foregroundStyle(.orange)
                    Text("이 값들은 틀 안의 칸으로 옮겨야 합니다 — 옮기지 않으면 결과 맨 뒤에 따로 붙어요.")
                        .font(.body).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Button("모두 고르기") { focusColumns = outside }
                        .controlSize(.small)
                    if !matchSuggestions.isEmpty {
                        Button("짝지어 주기…") { showMatchSheet = true }
                            .controlSize(.small)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.orange.opacity(0.08)))
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: 8)],
                          alignment: .leading, spacing: 8) {
                    ForEach(finalColumns.filter { outside.contains($0) }) { col in columnChip(col) }
                }
                Divider()
                Text("틀 안 컬럼").font(.body.weight(.semibold)).foregroundStyle(.secondary)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: 8)],
                      alignment: .leading, spacing: 8) {
                ForEach(split.todo.filter { !outside.contains($0) }) { col in columnChip(col) }
                if showAllColumns {
                    ForEach(split.settled.filter { !outside.contains($0) }) { col in columnChip(col) }
                }
            }
            if !split.settled.isEmpty {
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) { showAllColumns.toggle() }
                } label: {
                    Label(showAllColumns
                          ? "정리된 컬럼 접기"
                          : "정리된 컬럼도 보기 (\(split.settled.count)개)",
                          systemImage: showAllColumns ? "chevron.up" : "chevron.down")
                        .font(.body).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color.primary.opacity(0.03)))
    }

    /// 고른 컬럼으로 할 수 있는 일 — 개수에 따라 문구가 바뀐다.
    private func boardActionBar(_ picked: [UnifiedColumn]) -> some View {
        HStack(spacing: 10) {
            Text(picked.count == 1 ? "‘\(picked[0].rawValue)’ 골랐어요"
                                   : "\(picked.count)개 골랐어요")
                .font(.body.weight(.semibold))
            Text(picked.prefix(4).map(\.rawValue).joined(separator: " · ")
                 + (picked.count > 4 ? " 외" : ""))
                .font(.body).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 8)
            if picked.count >= 2 {
                Button {
                    confirmMerge = picked
                } label: {
                    Label("한 칸으로 합치기…", systemImage: "arrow.trianglehead.merge")
                }
                .help("어느 칸에·어떤 순서로·무엇을 사이에 넣어 합칠지 정할 수 있어요.")
            }
            if picked.count == 1 {
                Button("이 값 채우기…") { fillTarget = picked[0] }
                    .help("어디서 가져올지 고르고, 여럿이면 어떻게 넣을지 정합니다.")
            }
            if picked.count == 1 {
                Button {
                    withBusy("검토 화면을 만드는 중…") { startWork() }
                } label: {
                    Text("이 컬럼 정리하기 →").fontWeight(.semibold)
                }
                .buttonStyle(.borderedProminent)
            } else {
                Menu {
                    Button("한 칸으로 합치기…") { confirmMerge = picked }
                    Button("따로따로 정리하기 →") {
                        withBusy("검토 화면을 만드는 중…") { startWork() }
                    }
                } label: {
                    Text("\(picked.count)개 정리하기 ▾").fontWeight(.semibold)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("여러 칸을 하나로 합칠지, 각각 따로 정리할지 고르세요.")
            }
            Button("해제") { focusColumns = [] }
                .controlSize(.small)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Color.accentColor.opacity(0.10)))
    }

    /// 컬럼 하나짜리 칩 — 이름·상태·출처 점. 누르면 골라지고 다시 누르면 풀린다.
    private func columnChip(_ col: UnifiedColumn) -> some View {
        let on = focusColumns.contains(col)
        let status = focusStatus(col)
        let empty = emptyColumns.contains(col)
        let outside = !templateColumns.isEmpty && !templateColumns.contains(col)
        return Button {
            if on { focusColumns.remove(col) } else { focusColumns.insert(col) }
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Image(systemName: on ? "checkmark.square.fill" : "square")
                        .foregroundStyle(on ? Color.accentColor : Color.secondary.opacity(0.7))
                    Text(col.rawValue)
                        .font(.body.weight(.semibold))
                        .lineLimit(1).truncationMode(.tail)
                    Spacer(minLength: 0)
                    if outside {
                        Text("틀 밖")
                            .font(.body.weight(.bold))
                            .foregroundStyle(.orange)
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Capsule().fill(Color.orange.opacity(0.18)))
                    } else if !status.badge.isEmpty {
                        Text(status.badge)
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.orange)
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Capsule().fill(Color.orange.opacity(0.12)))
                    }
                }
                Text(status.text)
                    .font(.body).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.tail)
                if let vals = cache.samples[col], !vals.isEmpty {
                    Text(vals.joined(separator: " · "))
                        .font(.body).foregroundStyle(.secondary.opacity(0.8))
                        .lineLimit(1).truncationMode(.tail)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(on ? Color.accentColor.opacity(0.10)
                      : Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(on ? Color.accentColor.opacity(0.5)
                              : (outside ? Color.orange.opacity(0.55)
                                 : (empty ? Color.orange.opacity(0.35) : Color.primary.opacity(0.08))),
                              style: StrokeStyle(lineWidth: on || outside ? 1.5 : 1,
                                                 dash: empty && !on ? [4, 3] : [])))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(status.text)
    }

    /// 손볼 거리가 남은 컬럼 / 이미 정리된 컬럼으로 한 번에 가른다.
    /// (focusStatus 는 컬럼마다 값을 훑으므로 목록마다 다시 계산하지 않는다.)
    private var workColumnSplit: (todo: [UnifiedColumn], settled: [UnifiedColumn]) {
        (cache.todo, cache.settled)
    }

    /// 컬럼 목록 — 손볼 거리가 있는 것만 펼쳐 두고, 이미 정리된 컬럼은 접어 둔다.
    /// 시작할 때 눈에 들어오는 건 오늘 할 일뿐이어야 한다.
    private var workColumnListBody: some View {
        let split = workColumnSplit
        let hiddenPicked = split.settled.filter(focusColumns.contains).count
        return Group {
            LazyVStack(spacing: 6) {
                if split.todo.isEmpty {
                    workAllSettledCard
                } else {
                    ForEach(split.todo) { col in workPickRow(col) }
                }
                if !split.settled.isEmpty {
                    Button {
                        withAnimation(.easeInOut(duration: 0.18)) { showSettledColumns.toggle() }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: showSettledColumns ? "chevron.down" : "chevron.right")
                                .font(.body.weight(.bold))
                            Text(showSettledColumns
                                 ? "정리된 컬럼 접기"
                                 : "정리된 컬럼도 보기 (\(split.settled.count)개)")
                            if hiddenPicked > 0 && !showSettledColumns {
                                Text("\(hiddenPicked)개 선택됨")
                                    .font(.body.weight(.semibold))
                                    .padding(.horizontal, 7).padding(.vertical, 2)
                                    .background(Capsule().fill(Color.accentColor.opacity(0.14)))
                                    .foregroundStyle(Color.accentColor)
                            }
                            Spacer()
                        }
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6).padding(.vertical, 10)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("오타·형식 문제가 없는 컬럼입니다. 그래도 다듬고 싶으면 펼쳐서 고르세요.")
                    if showSettledColumns {
                        ForEach(split.settled) { col in workPickRow(col) }
                    }
                }
            }
        }
    }

    /// 손볼 거리가 하나도 없을 때 — 빈 목록 대신 무엇을 하면 되는지 알려 준다.
    private var workAllSettledCard: some View {
        VStack(spacing: 8) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 30)).foregroundStyle(.green)
            Text("손볼 거리가 있는 컬럼이 없어요")
                .font(.title3.weight(.semibold))
            Text("오타 의심값이나 형식이 어긋난 값을 찾지 못했습니다.\n그냥 가져가도 되고, 아래에서 컬럼을 펼쳐 직접 다듬어도 됩니다.")
                .font(.body).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
    }

    // MARK: 완성본 미리보기 (파일별 색 · 쪼개진 컬럼 표시)

    /// 몇 번째로 올린 파일인지에 따른 색. 파일 칩·미리보기 줄이 같은 색을 쓴다.
    private func fileTint(_ index: Int) -> Color { PreviewModel.paletteColor(index) }

    /// 미리보기에 보여 줄 줄 — **실제 완성본**(정리 결과가 반영된 결과표)에서
    /// 파일마다 몇 줄씩 골고루 뽑는다. 어느 파일 줄도 안 보이는 일이 없게.
    private func previewSampleRows(limit: Int = 9) -> [Int] {
        guard !preview.rows.isEmpty else { return [] }
        let files = preview.rowFiles
        guard !files.isEmpty else { return Array(preview.rows.indices.prefix(limit)) }
        let kinds = max(1, Set(files).count)
        let perFile = max(1, limit / kinds)
        var taken: [Int: Int] = [:]
        var out: [Int] = []
        for i in preview.rows.indices {
            let f = i < files.count ? files[i] : -1
            guard (taken[f] ?? 0) < perFile else { continue }
            taken[f, default: 0] += 1
            out.append(i)
            if out.count >= limit { break }
        }
        return out
    }

    /// 지금 제안 카드가 가리키는 컬럼 — 완성본 미리보기에서도 같은 열을 강조한다.
    private var currentProposalColumn: UnifiedColumn? {
        let order = proposalOrder
        guard !order.isEmpty else { return nil }
        return order[min(max(proposalIndex, 0), order.count - 1)]
    }

    /// 아직 한 칸으로 합쳐지지 않아 쪼개져 있는 컬럼인가 (일부 파일에만 있음).
    private func isSplitColumn(_ col: UnifiedColumn) -> Bool {
        guard plans.count > 1 else { return false }
        let owners = filesHaving(col)
        // 어느 파일에도 없는 컬럼(자동 생성·빈 자리)은 ‘쪼개진’ 게 아니다.
        return owners > 0 && owners < plans.count
    }

    /// 이 컬럼을 가진 파일들의 순번.
    private func columnOwnerIndices(_ col: UnifiedColumn) -> [Int] {
        plans.indices.filter { plans[$0].isMapped(col) }
    }

    /// 한 파일에서만 온 컬럼이면 그 파일 색 — 열 배경으로 출처를 보여 준다.
    private func columnOwnerTint(_ col: UnifiedColumn) -> Color? {
        let owners = columnOwnerIndices(col)
        guard plans.count > 1, owners.count == 1 else { return nil }
        return fileTint(owners[0])
    }

    /// 사람 말로 된 출처 설명 — `0/3 파일` 같은 표기 대신.
    private func splitCaption(_ col: UnifiedColumn) -> String? {
        guard plans.count > 1 else { return nil }
        let owners = columnOwnerIndices(col)
        guard !owners.isEmpty, owners.count < plans.count else { return nil }
        if let hint = pairHint(col) { return "‘\(hint)’와 같은 컬럼일까요?" }
        if owners.count == 1 { return "‘\(plans[owners[0]].fileName)’에만 있음" }
        let missing = plans.indices.filter { !owners.contains($0) }.map { plans[$0].fileName }
        return "‘\(missing.prefix(2).joined(separator: ", "))’엔 없음"
    }

    /// 이 컬럼과 짝지을 후보가 있으면 그 이름.
    private func pairHint(_ col: UnifiedColumn) -> String? {
        for s in matchSuggestions {
            if s.source == col, let b = s.best { return b.column.rawValue }
            if let b = s.best, b.column == col { return s.source.rawValue }
        }
        return nil
    }

    /// 첫 화면에 끼워 넣은 **작업대** — 큰 창과 똑같은 화면이다.
    /// (앱은 다음에 뭘 할지 안내하고, 실제 작업은 이 표에서 한다.)
    @ViewBuilder
    private var workPreviewCard: some View {
        if !plans.isEmpty && !preview.rows.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("작업대").font(.headline)
                    Text("지금 상태 그대로의 결과입니다 — 여기서 바로 고치고 채울 수 있어요")
                        .font(.body).foregroundStyle(.secondary)
                    Spacer()
                    Button("큰 창으로 열기") { openPreviewWindow() }
                        .controlSize(.small)
                }
                PreviewWindowView(embedded: true)
                    .frame(height: 420)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color(nsColor: .textBackgroundColor)))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.primary.opacity(0.08), lineWidth: 1))
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(0.03)))
        }
    }

    private var previewLegend: some View {
        HStack(spacing: 12) {
            ForEach(Array(plans.enumerated()), id: \.element.id) { idx, plan in
                HStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 2).fill(fileTint(idx)).frame(width: 10, height: 10)
                    Text(plan.fileName)
                        .font(.body).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
            }
            if !preview.baseName.isEmpty {
                HStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 2).fill(Color.secondary.opacity(0.35))
                        .frame(width: 10, height: 10)
                    Text("틀: \(preview.baseName)")
                        .font(.body).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
            }
            Divider().frame(height: 12)
            HStack(spacing: 4) {
                RoundedRectangle(cornerRadius: 2).fill(Color.orange.opacity(0.3)).frame(width: 10, height: 10)
                Text("아직 안 합쳐진 컬럼")
                    .font(.body).foregroundStyle(.secondary)
            }
            HStack(spacing: 4) {
                Circle().fill(Color.secondary.opacity(0.35)).frame(width: 8, height: 8)
                Text("열 배경·점 = 그 컬럼이 들어 있는 파일")
                    .font(.body).foregroundStyle(.secondary)
            }
            HStack(spacing: 4) {
                Text("—").font(.body).foregroundStyle(.secondary.opacity(0.6))
                Text("그 파일엔 없는 값 (빈칸)").font(.body).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    /// 합치기 단계에서 사람이 한 번씩 확인해야 하는 일 하나.
    struct MergeStep: Identifiable {
        let id: String
        let symbol: String
        let tint: Color
        let title: String
        let detail: String
        var actionTitle: String? = nil
        var action: (() -> Void)? = nil
        /// 고를 거리가 있는 단계(키 고르기)용 — 메뉴 항목들.
        var menuTitle: String? = nil
        var menuOptions: [(title: String, action: () -> Void)] = []
    }

    /// 지금 결과에서 값이 하나도 없는 컬럼 — 틀에만 있거나, 파일에 값이 안 들어온 컬럼.
    private var emptyColumns: [UnifiedColumn] { cache.empty }

    /// 빈 컬럼에 짝이 될 만한 후보가 있으면 (자동으로 잇기엔 확신이 모자란 것들).
    private func emptyColumnHint(_ col: UnifiedColumn) -> (source: UnifiedColumn, percent: Int)? {
        for s in matchSuggestions {
            if let b = s.best, b.column == col { return (s.source, b.percent) }
        }
        return nil
    }

    /// 지금 남아 있는 합치기 할 일들 — 확인한 것은 빠진다.
    private var mergeSteps: [MergeStep] {
        guard plans.count > 1 || baseIsUserFile else { return [] }
        var out: [MergeStep] = []

        if plans.count > 1 {
            let rows = plans.reduce(0) { $0 + $1.rows.count }
            let merged = base?.mergedByKey ?? 0
            let made = base?.generatedKeys ?? 0
            var detail: String
            if let keyColumn {
                detail = "같은 ‘\(keyColumn.rawValue)’ 값이면 파일이 달라도 한 줄로 포갭니다."
                detail += merged > 0
                    ? "\n\(rows)행 → \(base?.rows.count ?? rows)행 (같은 키 \(merged)행을 포갰어요)"
                    : "\n\(rows)행 그대로 — 겹치는 키가 없었습니다."
                if made > 0 { detail += "\n키가 비어 있던 \(made)행에는 AUTO-0001처럼 번호를 만들어 넣었어요." }
            } else {
                detail = "지금은 키 없이 파일을 세로로 쌓기만 합니다 — 같은 사람이 여러 파일에 있으면 여러 줄로 남아요."
                if let auto = autoKeyColumn() { detail += "\n‘\(auto.rawValue)’를 키로 쓰면 한 줄로 포갤 수 있습니다." }
            }
            var options: [(title: String, action: () -> Void)] = [
                ("키 없이 그냥 쌓기", { applyKeyColumn(nil) })
            ]
            for c in keyCandidates.prefix(8) {
                options.append(("‘\(c.rawValue)’를 키로", { applyKeyColumn(c) }))
            }
            out.append(MergeStep(
                id: "key",
                symbol: "key.fill", tint: .accentColor,
                title: keyColumn.map { "키 컬럼: ‘\($0.rawValue)’" } ?? "키 컬럼: 없음 (그냥 쌓기)",
                detail: detail,
                menuTitle: "키 바꾸기",
                menuOptions: options))
        }

        if !autoMatched.isEmpty {
            let names = autoMatched.prefix(4)
                .map { "\($0.source.rawValue) → \($0.target.rawValue)" }
                .joined(separator: "\n")
            out.append(MergeStep(
                id: "auto",
                symbol: "wand.and.stars", tint: .accentColor,
                title: "자동으로 채운 컬럼 \(autoMatched.count)개",
                detail: "값이 같아 보여서 이렇게 이어 붙였어요. 맞으면 그대로 두세요.\n" + names
                    + (autoMatched.count > 4 ? "\n…" : ""),
                actionTitle: "되돌리기",
                action: { withBusy("되돌리는 중…") { undoAutoMatch() } }))
        }
        if !matchSuggestions.isEmpty {
            out.append(MergeStep(
                id: "pairs",
                symbol: "arrow.trianglehead.merge", tint: .accentColor,
                title: "이름이 다른 같은 컬럼 \(matchSuggestions.count)건",
                detail: matchSummary + "\n같은 컬럼이면 한 칸으로 합치고, 아니면 그대로 두면 됩니다.",
                actionTitle: "짝지어 주기…", action: { showMatchSheet = true }))
        }
        for col in shapeConflicts {
            out.append(MergeStep(
                id: "shape:" + col.rawValue,
                symbol: "exclamationmark.triangle.fill", tint: .orange,
                title: "‘\(col.rawValue)’는 파일마다 값 모양이 달라요",
                detail: "합치는 데는 문제없지만, 한 형식으로 맞추지 않으면 결과에 두 가지 표기가 섞입니다.",
                actionTitle: "‘\(col.rawValue)’ 정리하기", action: {
                    focusColumns = [col]
                    withBusy("‘\(col.rawValue)’ 검토 화면을 만드는 중…") { startWork() }
                }))
        }
        let paired = Set(matchSuggestions.map(\.source))
            .union(matchSuggestions.compactMap { $0.best?.column })
        let partial = finalColumns.filter {
            let n = filesHaving($0)
            return n > 0 && n < plans.count && !paired.contains($0)
        }
        if let col = filterCandidates.first(where: { c in
            // ‘상태’처럼 생긴 컬럼을 먼저 권한다.
            let n = c.rawValue.lowercased()
            return n.contains("status") || n.contains("상태") || n.contains("진행")
        }) ?? filterCandidates.first {
            let counts = filterValueCounts(col)
            let top = counts.prefix(4)
                .map { "\($0.value) \($0.count)행" }.joined(separator: " · ")
            let filtered = filteredOutSourceIDs.count
            out.append(MergeStep(
                id: "filter",
                symbol: "line.3.horizontal.decrease.circle", tint: .accentColor,
                title: filterColumn == nil
                    ? "행을 걸러 낼까요? — ‘\(col.rawValue)’로 나뉩니다"
                    : "‘\(filterColumn!.rawValue)’로 거르는 중 — \(filtered)행 빼 둠",
                detail: top + (counts.count > 4 ? " · 외 \(counts.count - 4)종" : "")
                    + "\n예를 들어 작성 중인 신청은 빼고 ‘제출 완료’만 남길 수 있어요. "
                    + "빼도 지우는 게 아니라 잠깐 감춰 두는 것이고, 언제든 되돌립니다.",
                actionTitle: "고르기…",
                action: {
                    if filterColumn == nil {
                        filterColumn = col
                        filterKeep = Set(filterValueCounts(col).map(\.value))
                    }
                    showFilterSheet = true
                }))
        }
        if let sheet = base, !sheet.duplicateRows.isEmpty {
            out.append(MergeStep(
                id: "dup",
                symbol: "person.2.fill", tint: .orange,
                title: "중복으로 보이는 행 \(sheet.duplicateRows.count)개",
                detail: "같은 이메일·전화·키가 앞줄에 이미 나왔어요 (\(sheet.duplicateGroups)명). "
                    + "**행은 하나도 지우지 않았습니다** — 표시만 해 뒀어요.\n"
                    + "미리보기에서 ‘중복만 보기’로 확인한 뒤, 지울지 직접 정하세요.",
                actionTitle: "중복 행 \(sheet.duplicateRows.count)개 지우기",
                action: { withBusy("중복 행을 지우는 중…") { deleteDuplicateRows() } },
                menuTitle: "중복 보기",
                menuOptions: [("미리보기에서 중복만 보기", {
                    preview.showDuplicatesOnly = true
                    openPreviewWindow()
                })]))
        }
        let empties = emptyColumns
        if let first = empties.first {
            let hint = empties.compactMap { c -> String? in
                emptyColumnHint(c).map { "‘\(c.rawValue)’는 파일의 ‘\($0.source.rawValue)’일 수 있어요 (\($0.percent)%)" }
            }.first
            var detail = empties.prefix(6).map(\.rawValue).joined(separator: " · ")
                + (empties.count > 6 ? " 외 \(empties.count - 6)개" : "")
            detail += "\n올린 파일에서 이 컬럼에 넣을 값을 못 찾았어요. 채우는 방법은 셋입니다:"
            if let hint { detail += "\n① " + hint + " → ‘짝지어 주기…’로 이어 붙이기" }
            else { detail += "\n① 파일의 어느 칸이 이 컬럼인지 직접 골라 주기 (아래 버튼)" }
            detail += "\n② 그 값이 들어 있는 파일을 더 올리기"
            detail += "\n③ 원래 비워 두는 칸이면 그냥 두기 — 결과에도 빈칸으로 남습니다"
            out.append(MergeStep(
                id: "empty",
                symbol: "rectangle.dashed", tint: .orange,
                title: "아직 비어 있는 컬럼 \(empties.count)개",
                detail: detail,
                actionTitle: "‘\(first.rawValue)’ 채울 칸 고르기…",
                action: { configColumn = first }))
        }
        if !partial.isEmpty {
            out.append(MergeStep(
                id: "partial",
                symbol: "square.dashed", tint: .secondary,
                title: "한 파일에만 있는 컬럼 \(partial.count)개",
                detail: partial.prefix(6).map(\.rawValue).joined(separator: " · ")
                    + (partial.count > 6 ? " 외" : "")
                    + "\n그 컬럼이 없는 파일의 행은 빈칸으로 남습니다. 원래 그런 거라면 그냥 넘어가세요."))
        }
        return out.filter { !mergeDone.contains($0.id) }
    }

    /// 이 앱이 하는 두 가지 일 중 첫 번째 — **합치기**.
    /// 할 일이 여럿이면 한 번에 하나씩만 보여 준다 (2단계 정리와 같은 방식).
    @ViewBuilder
    private var workMergeCard: some View {
        if plans.count > 1 || baseIsUserFile {
            let steps = mergeSteps
            let common = finalColumns.filter { filesHaving($0) == plans.count }
            let rows = plans.reduce(0) { $0 + $1.rows.count }
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("1. 합치기").font(.headline)
                    Text("파일 \(plans.count)개를 세로로 쌓아 \(rows)행 · 컬럼 \(finalColumns.count)개"
                         + (common.isEmpty ? "" : " · 공통 컬럼 \(common.count)개는 그대로 겹침"))
                        .font(.body).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    if steps.isEmpty {
                        Label("확인할 것 없음", systemImage: "checkmark.seal.fill")
                            .font(.body.weight(.semibold)).foregroundStyle(.green)
                    } else {
                        Text("확인할 일 \(steps.count)개 중 1번째")
                            .font(.body).monospacedDigit().foregroundStyle(.secondary)
                    }
                }
                rowCountTable
                if let step = steps.first {
                    mergeStepCard(step, remaining: steps.count)
                } else {
                    HStack(spacing: 8) {
                        Text("같은 이름의 컬럼은 한 칸으로 겹치고, 없는 컬럼은 빈칸으로 둡니다. 합치기는 끝났고 남은 일은 값 정리뿐이에요.")
                            .font(.body).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 8)
                        if !mergeDone.isEmpty {
                            Button("확인한 것 다시 보기") { mergeDone = [] }
                                .controlSize(.small)
                        }
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(steps.isEmpty ? Color.green.opacity(0.07) : Color.primary.opacity(0.04)))
        }
    }

    /// 행 수 대조표 — 올린 파일마다 몇 행이고, 결과물이 몇 행인지 한눈에.
    /// 숫자가 맞는지 눈으로 확인할 수 있어야 결과를 믿을 수 있다.
    @ViewBuilder
    private var rowCountTable: some View {
        let total = plans.reduce(0) { $0 + $1.rows.count }
        let result = base?.rows.count ?? total
        let merged = base?.mergedByKey ?? 0
        let made = base?.generatedKeys ?? 0
        VStack(alignment: .leading, spacing: 4) {
            Text("행 수 맞춰 보기").font(.body.weight(.semibold))
            ForEach(Array(plans.enumerated()), id: \.element.id) { idx, plan in
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 2).fill(fileTint(idx))
                        .frame(width: 8, height: 8)
                    Text(plan.fileName)
                        .font(.body).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 8)
                    Text("\(plan.rows.count)행")
                        .font(.body.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            if plans.contains(where: { $0.hiddenRowsSkipped > 0 }) {
                HStack(spacing: 6) {
                    Text("시트에서 숨겨져 있던 행 (안 읽음)")
                        .font(.body).foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Text("\(plans.reduce(0) { $0 + $1.hiddenRowsSkipped })행")
                        .font(.body.monospacedDigit()).foregroundStyle(.secondary)
                    Button("포함하기") { reloadIncludingHiddenRows() }
                        .controlSize(.small)
                        .help("엑셀·넘버스에서 감춰 둔 줄까지 다시 읽어 옵니다.")
                }
            }
            Divider()
            HStack(spacing: 6) {
                Text("올린 파일 합계").font(.body)
                Spacer(minLength: 8)
                Text("\(total)행").font(.body.monospacedDigit())
            }
            HStack(spacing: 6) {
                Text("결과물").font(.body.weight(.semibold))
                Spacer(minLength: 8)
                Text("\(result)행")
                    .font(.body.monospacedDigit().weight(.semibold))
                    .foregroundStyle(result == total ? .primary : Color.accentColor)
            }
            if result == total {
                Label("행 수가 딱 맞습니다 — 빠진 행이 없어요.", systemImage: "checkmark.circle.fill")
                    .font(.body).foregroundStyle(.green)
            } else {
                Text(rowCountNote(total: total, result: result, merged: merged, made: made))
                    .font(.body).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let dup = base?.duplicateRows.count, dup > 0 {
                HStack(spacing: 6) {
                    Text("중복으로 보이는 행").font(.body).foregroundStyle(.orange)
                    Spacer(minLength: 8)
                    Text("\(dup)행").font(.body.monospacedDigit()).foregroundStyle(.orange)
                }
                Text("표시만 해 뒀어요 — 지울지는 직접 정하시면 됩니다.")
                    .font(.body).foregroundStyle(.secondary)
            }
            if !filteredOutSourceIDs.isEmpty, let col = filterColumn {
                HStack(spacing: 6) {
                    Text("‘\(col.rawValue)’로 빼 둔 행").font(.body).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 8)
                    Text("\(filteredOutSourceIDs.count)행")
                        .font(.body.monospacedDigit()).foregroundStyle(.secondary)
                    Button("되돌리기") { applyRowFilter(nil, keep: []) }
                        .controlSize(.small)
                }
            }
            if !deletedSourceIDs.isEmpty {
                HStack(spacing: 6) {
                    Text("내가 지운 행").font(.body).foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Text("\(deletedSourceIDs.count)행")
                        .font(.body.monospacedDigit()).foregroundStyle(.secondary)
                    Button("되살리기") { withBusy("되살리는 중…") { restoreDeletedRows() } }
                        .controlSize(.small)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Color(nsColor: .controlBackgroundColor)))
    }

    /// 행 수가 왜 달라졌는지 한 문장으로.
    private func rowCountNote(total: Int, result: Int, merged: Int, made: Int) -> String {
        var parts: [String] = []
        if !deletedSourceIDs.isEmpty { parts.append("내가 지운 행 \(deletedSourceIDs.count)개") }
        if result > total { parts.append("기준 파일에 없던 \(result - total)행이 새로 붙었어요") }
        if made > 0 { parts.append("키가 없던 \(made)행에는 번호를 만들어 줬어요") }
        if parts.isEmpty { return "행 수 그대로 — 빠지거나 늘어난 행이 없습니다." }
        return parts.joined(separator: " · ")
    }

    /// 합치기 할 일 한 장 — 무엇을, 왜, 그리고 어떻게 넘어가는지.
    private func mergeStepCard(_ step: MergeStep, remaining: Int) -> some View {
        let border: Color = step.tint.opacity(0.35)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: step.symbol)
                    .foregroundStyle(step.tint)
                VStack(alignment: .leading, spacing: 3) {
                    Text(step.title)
                        .font(.body.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    Text(step.detail)
                        .font(.body).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
            }
            if step.id == "key", keyColumn != nil { keyPatternEditor }
            HStack(spacing: 10) {
                if let title = step.actionTitle, let action = step.action {
                    Button(action: action) { Text(title).fontWeight(.semibold) }
                        .buttonStyle(.borderedProminent)
                }
                if let menuTitle = step.menuTitle, !step.menuOptions.isEmpty {
                    Menu(menuTitle) {
                        ForEach(step.menuOptions.indices, id: \.self) { i in
                            Button(step.menuOptions[i].title) { step.menuOptions[i].action() }
                        }
                    }
                    .fixedSize()
                }
                Button(step.actionTitle == nil ? "알겠어요" : "이대로 둘게요") {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        _ = mergeDone.insert(step.id)
                    }
                }
                Spacer()
                if remaining > 1 {
                    Text("확인하면 다음 것을 보여 드려요")
                        .font(.body).foregroundStyle(.secondary)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .stroke(border, lineWidth: 1))
    }

    private var matchSummary: String {
        let head = matchSuggestions.prefix(3).compactMap { s in
            s.best.map { "\(s.source.rawValue) → \($0.column.rawValue) (\($0.percent)%)" }
        }.joined(separator: " · ")
        return matchSuggestions.count > 3 ? head + " · 외 \(matchSuggestions.count - 3)개" : head
    }

    /// 틀에 없는 이번 컬럼 ↔ 이번 파일이 채우지 않는 틀 컬럼을 값으로 견줘 짝을 찾는다.
    /// 값을 훑으므로 파일·틀이 바뀔 때만 계산해 둔다.
    private func refreshMatches() {
        guard !plans.isEmpty else {
            matchSuggestions = []; matchSamples = [:]; shapeConflicts = []
            return
        }
        shapeConflicts = computeShapeConflicts()
        // 컬럼만 빌려 온 틀: 아직 아무 파일도 채우지 못한 틀 컬럼을 후보로 둔다.
        if !templateColumns.isEmpty {
            let mine = Set(ColumnReviewBuilder.plainColumns(in: plans))
            let sources = finalColumns.filter { !templateColumns.contains($0) && mine.contains($0) }
                .map { (column: $0, values: ColumnReviewBuilder.rawValues($0, in: plans)) }
            let targets = templateColumns.filter { !mine.contains($0) }
                .map { (column: $0, values: templateValues[$0] ?? []) }
                .filter { !$0.values.isEmpty }
            matchSuggestions = ColumnMatcher.suggest(sources: sources, targets: targets)
            var samples: [UnifiedColumn: [String]] = [:]
            for s in sources { samples[s.column] = Array(distinctFew(s.values)) }
            for t in targets { samples[t.column] = Array(t.values.prefix(6)) }
            matchSamples = samples
            return
        }
        guard baseIsUserFile, base != nil else {
            // 틀이 없으면 올린 파일들끼리 견준다 — 파일A ‘거주지’ ↔ 파일B ‘도시’.
            let (suggestions, samples) = fileToFileSuggestions()
            matchSuggestions = suggestions
            matchSamples = samples.mapValues { vals in
                var seen: [String] = []
                for v in vals where !v.isEmpty && !seen.contains(v) {
                    seen.append(v)
                    if seen.count >= 6 { break }
                }
                return seen
            }
            return
        }
        let mine = Set(finalColumns)
        let sources = finalColumns.filter { baseValues[$0] == nil }
            .map { (column: $0, values: ColumnReviewBuilder.rawValues($0, in: plans)) }
        let targets = baseValues.filter { !mine.contains($0.key) && !$0.value.isEmpty }
            .map { (column: $0.key, values: $0.value) }
        matchSuggestions = ColumnMatcher.suggest(sources: sources, targets: targets)

        var samples: [UnifiedColumn: [String]] = [:]
        for s in sources {
            var seen: [String] = []
            for v in s.values where !v.isEmpty && !seen.contains(v) {
                seen.append(v)
                if seen.count >= 6 { break }
            }
            samples[s.column] = seen
        }
        for t in targets { samples[t.column] = Array(t.values.prefix(6)) }
        matchSamples = samples
    }

    private func distinctFew(_ values: [String], _ n: Int = 6) -> [String] {
        var seen: [String] = []
        for v in values where !v.isEmpty && !seen.contains(v) {
            seen.append(v)
            if seen.count >= n { break }
        }
        return seen
    }

    /// 틀을 잡자마자, 확실한 짝은 사람에게 묻지 않고 바로 채운다.
    /// (애매한 것만 `짝지어 주기…`로 남긴다. 되돌리기 버튼도 함께 제공.)
    private func autoMatchTemplateColumns(minScore: Double = 0.7) {
        guard !templateColumns.isEmpty, !plans.isEmpty else { return }
        var pairs: [(source: UnifiedColumn, target: UnifiedColumn)] = []
        var used = Set<UnifiedColumn>()
        for s in matchSuggestions {
            guard let best = s.best, best.score >= minScore, !used.contains(best.column) else { continue }
            // 1·2위가 붙어 있으면 자동으로 정하지 않는다.
            if s.candidates.count > 1, best.score - s.candidates[1].score < 0.08 { continue }
            pairs.append((source: s.source, target: best.column))
            used.insert(best.column)
        }
        guard !pairs.isEmpty else { return }
        undoPlans = plans
        applyMatches(pairs)
        autoMatched = pairs
    }

    /// 자동으로 채운 짝을 되돌린다.
    private func undoAutoMatch() {
        guard let snapshot = undoPlans else { return }
        plans = snapshot
        undoPlans = nil
        autoMatched = []
        rebuildWorkColumns()
    }

    /// 올린 파일들끼리 이름만 다른 같은 컬럼 찾기.
    /// 모든 파일에 있는 컬럼은 이미 짝이 맞으므로, **일부 파일에만 있는 컬럼끼리만** 견준다.
    /// 서로 다른 파일에 있는 것끼리만 짝지어 한 파일 안에서 두 컬럼이 겹치지 않게 한다.
    private func fileToFileSuggestions() -> ([ColumnMatcher.Suggestion], [UnifiedColumn: [String]]) {
        guard plans.count > 1 else { return ([], [:]) }
        let partial = finalColumns.filter { col in
            let n = filesHaving(col)
            return n > 0 && n < plans.count
        }
        guard partial.count > 1 else { return ([], [:]) }

        var owners: [UnifiedColumn: Set<Int>] = [:]
        var values: [UnifiedColumn: [String]] = [:]
        var profiles: [UnifiedColumn: ColumnMatcher.Profile] = [:]
        for col in partial {
            owners[col] = Set(plans.indices.filter { plans[$0].isMapped(col) })
            let vals = ColumnReviewBuilder.rawValues(col, in: plans)
            values[col] = vals
            profiles[col] = ColumnMatcher.profile(vals)   // 컬럼마다 딱 한 번만 훑는다
        }

        var out: [ColumnMatcher.Suggestion] = []
        var used = Set<UnifiedColumn>()
        // finalColumns 순서대로 도니까 먼저 나온(앞 파일의) 이름이 남는 이름이 된다.
        for col in partial where !used.contains(col) {
            guard let mineProfile = profiles[col] else { continue }
            let targets = partial.compactMap { other -> (UnifiedColumn, ColumnMatcher.Profile)? in
                guard other != col, !used.contains(other),
                      (owners[col] ?? []).isDisjoint(with: owners[other] ?? []),
                      let p = profiles[other] else { return nil }
                return (other, p)
            }
            guard !targets.isEmpty else { continue }
            let found = ColumnMatcher.suggest(sourceProfiles: [(col, mineProfile)],
                                              targetProfiles: targets)
            guard let best = found.first?.best else { continue }
            // 남길 이름은 먼저 나온 `col` — 뒤 파일의 컬럼을 이쪽으로 옮긴다.
            out.append(ColumnMatcher.Suggestion(
                source: best.column,
                candidates: [ColumnMatcher.Candidate(column: col, score: best.score,
                                                     reason: best.reason)]))
            used.insert(col)
            used.insert(best.column)
        }
        return (out, values)
    }

    /// 같은 이름인데 파일마다 값 모양이 크게 다른 컬럼 —
    /// 합치는 데는 문제가 없지만, 합친 뒤 한 형식으로 정리해야 한다.
    private func computeShapeConflicts() -> [UnifiedColumn] {
        guard plans.count > 1 else { return [] }
        var out: [UnifiedColumn] = []
        for col in finalColumns {
            let owners = plans.filter { $0.isMapped(col) }
            guard owners.count > 1 else { continue }
            let profiles = owners.map { ColumnMatcher.profile(ColumnReviewBuilder.rawValues(col, in: [$0])) }
            guard profiles.allSatisfy({ $0.distinct > 0 }) else { continue }
            var worst = 1.0
            for i in profiles.indices {
                for j in profiles.indices where j > i {
                    worst = min(worst, ColumnMatcher.shapeScore(profiles[i], profiles[j]))
                }
            }
            if worst < 0.4 { out.append(col) }
        }
        return out
    }

    /// 고른 짝을 실제로 합친다 — 이번 컬럼의 값이 틀의 컬럼 자리로 들어간다.
    /// 값은 하나도 바꾸지 않는다. 어느 칸에 넣을지만 바뀐다.
    private func applyMatches(_ pairs: [(source: UnifiedColumn, target: UnifiedColumn)]) {
        guard !pairs.isEmpty else { return }
        for pair in pairs {
            let from = pair.source.rawValue, to = pair.target.rawValue
            for i in plans.indices {
                guard let mine = plans[i].sources[pair.source] else { continue }
                if plans[i].sources[pair.target] != nil {
                    // 두 컬럼이 같은 파일에 다 있다 — 한 칸에 이어 붙인다 (값 사이 공백).
                    plans[i].sources[pair.target]? += mine
                    if (plans[i].separators[pair.target] ?? "").isEmpty {
                        plans[i].separators[pair.target] = " "
                    }
                    plans[i].sources[pair.source] = nil
                    plans[i].separators[pair.source] = nil
                    plans[i].headers.removeAll { $0 == from }
                    continue
                }
                for r in plans[i].rows.indices {
                    if let v = plans[i].rows[r].removeValue(forKey: from) { plans[i].rows[r][to] = v }
                }
                if let hi = plans[i].headers.firstIndex(of: from) {
                    if plans[i].headers.contains(to) { plans[i].headers.remove(at: hi) }
                    else { plans[i].headers[hi] = to }
                }
                plans[i].sources[pair.target] = [to]
                plans[i].sources[pair.source] = nil
                plans[i].separators[pair.target] = plans[i].separators[pair.source]
                plans[i].separators[pair.source] = nil
            }
            // 이미 손봐 둔 결정도 새 이름으로 옮겨 붙인다.
            if let m = valueMap.removeValue(forKey: pair.source) {
                valueMap[pair.target] = (valueMap[pair.target] ?? [:]).merging(m) { a, _ in a }
            }
            if let t = typeOverride.removeValue(forKey: pair.source) { typeOverride[pair.target] = t }
            if let f = formatChoice.removeValue(forKey: pair.source) { formatChoice[pair.target] = f }
            if let c = customFormat.removeValue(forKey: pair.source) { customFormat[pair.target] = c }
        }

        let before = focusColumns
        finalColumns = ColumnReviewBuilder.plainColumns(in: plans)
        reviews = ColumnReviewBuilder.plainReviews(in: plans)
        seedValueMap(from: reviews)
        rebuildRowCache()
        verifyRowCount("컬럼을 합친")
        if !baseIsUserFile {
            base = BaseSheet.stacked(plans, name: stackedName(plans),
                                     template: templateColumns, key: keyColumn,
                                 keyPattern: keyPattern, identity: identityColumns,
                                 excluding: deletedSourceIDs.union(filteredOutSourceIDs))
        }

        var next = before.intersection(Set(finalColumns))
        for pair in pairs where before.contains(pair.source) { next.insert(pair.target) }
        focusColumns = next
        includedColumns = next
        checked = checked.intersection(Set(finalColumns))
        errorMessage = nil
        refreshMatches()
        refreshPreview()
        scheduleSave()
    }

    /// 컬럼만 빌려 온 틀: 그 컬럼을 이번 파일이 얼마나 채우는지 한 줄로.
    private func templateCoverageLine(_ name: String) -> String {
        let mine = Set(ColumnReviewBuilder.plainColumns(in: plans))
        let filled = templateColumns.filter { mine.contains($0) }.count
        let empty = templateColumns.count - filled
        let extra = finalColumns.filter { !templateColumns.contains($0) }.count
        var line = "틀 ‘\(name)’의 컬럼 \(templateColumns.count)개 중 \(filled)개를 이번 파일이 채웁니다"
        if empty > 0 { line += " · \(empty)개는 빈칸" }
        if extra > 0 { line += " · 틀에 없는 컬럼 \(extra)개는 뒤에 붙습니다" }
        return line
    }

    /// 틀을 기준으로 이번 파일들이 어디까지 채우는지 한 줄로.
    private func baseCoverageLine(_ sheet: BaseSheet) -> String {
        let baseCols = sheet.columns
        let covered = baseCols.filter { finalColumns.contains($0) }.count
        let fresh = finalColumns.filter { baseValues[$0] == nil }.count
        var line = "틀 ‘\(sheet.name)’ 컬럼 \(baseCols.count)개 중 \(covered)개를 이번 파일이 채웁니다"
        if baseCols.count - covered > 0 { line += " · \(baseCols.count - covered)개는 기존 값 그대로" }
        if fresh > 0 { line += " · 틀에 없는 새 컬럼 \(fresh)개" }
        return line
    }

    /// 이 컬럼을 가진 파일 수 — 한 파일에만 있는 컬럼을 눈에 띄게 한다.
    private func filesHaving(_ col: UnifiedColumn) -> Int {
        plans.filter { $0.isMapped(col) }.count
    }

    private func workPickRow(_ col: UnifiedColumn) -> some View {
        let on = focusColumns.contains(col)
        let status = focusStatus(col)
        let owners = filesHaving(col)
        let partial = plans.count > 1 && owners < plans.count
        return Button {
            if on { focusColumns.remove(col) } else { focusColumns.insert(col) }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: on ? "checkmark.square.fill" : "square")
                    .font(.title3)
                    .foregroundStyle(on ? Color.accentColor : Color.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(col.rawValue)
                        .font(.body.weight(.medium))
                        .foregroundStyle(on ? .primary : .secondary)
                        .lineLimit(1).truncationMode(.tail).help(col.rawValue)
                    Text(status.text)
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if partial {
                    Text("\(owners)/\(plans.count) 파일")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Capsule().fill(Color.primary.opacity(0.06)))
                        .help("이 컬럼이 없는 파일의 행은 빈칸으로 남습니다. 이름만 다른 같은 컬럼이라면 검토 화면의 ‘여러 칸 합치기’에서 짝지어 주세요.")
                }
                if status.warn {
                    Text(status.badge)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Capsule().fill(Color.orange.opacity(0.12)))
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(on ? Color.accentColor.opacity(0.06) : Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(on ? Color.accentColor.opacity(0.35) : Color.primary.opacity(0.06),
                        lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// 파일이 아직 없을 때 — 합칠 파일들을 끌어다 놓거나 골라서 시작.
    private var workDropView: some View {
        VStack(spacing: 22) {
            Spacer(minLength: 0)

            workBaseInvite
                .frame(maxWidth: 600)
                .padding(.horizontal, 40)

            VStack(spacing: 14) {
                Image(systemName: isDropTargeted ? "tray.and.arrow.down.fill" : "tray.full")
                    .font(.system(size: 46))
                    .foregroundStyle(Color.accentColor)
                Text("2. 합칠 파일들을 모두 올려주세요")
                    .font(.system(.largeTitle, design: .rounded).weight(.bold))
                    .multilineTextAlignment(.center)
                Text("CSV·XLSX 여러 개를 한꺼번에 끌어다 놓으면 같은 이름의 컬럼끼리 맞춰 이어 붙입니다.\n그다음 지금 고칠 컬럼만 고르면 돼요 — 나머지는 올린 그대로 나갑니다.")
                    .font(.body).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Button(action: pickWorkFiles) {
                    Text("파일 고르기…").fontWeight(.semibold)
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .disabled(isLoadingFiles)
                Text("전에 만들어 둔 통합본은 여기 말고 위 1번 칸에 넣어 주세요.")
                    .font(.body).foregroundStyle(.secondary)
            }
            .frame(maxWidth: 520)
            .padding(40)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(isDropTargeted ? Color.accentColor.opacity(0.10) : Color.primary.opacity(0.03)))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(isDropTargeted ? Color.accentColor : Color.primary.opacity(0.12),
                              style: StrokeStyle(lineWidth: isDropTargeted ? 2 : 1, dash: [7, 5])))
            .padding(.horizontal, 40)

            if let errorMessage { errorLabel(errorMessage).frame(maxWidth: 520) }


            // 애플 아카데미 전용 흐름 — 채널 판별·중복 제거·Unique ID까지 자동으로.
            Button {
                errorMessage = nil
                stage = .files
            } label: {
                Label("애플 아카데미 지원 파일이에요 (중복 제거·Unique ID까지 자동)",
                      systemImage: "wand.and.stars")
            }
            .buttonStyle(.link)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// 첫 화면에서 함께 묻는다: 맞출 ‘틀’(만들던 통합본·양식)이 있나요?
    /// 있으면 그 파일의 컬럼 구성·값을 그대로 두고 고른 컬럼만 덮어쓴다.
    @ViewBuilder
    private var workBaseInvite: some View {
        Group {
            if let templateName {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title3).foregroundStyle(.green)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("1. 틀: \(templateName) — 컬럼 \(templateColumns.count)개")
                            .font(.body.weight(.semibold))
                            .lineLimit(1).truncationMode(.middle)
                        Text("이 파일에서는 **컬럼 이름만** 가져옵니다 — 값은 올린 파일 것만 들어가요. 이제 아래 2번 칸에 합칠 파일을 올려 주세요.")
                            .font(.body).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    Button("바꾸기…") { chooseTemplateColumns() }
                        .controlSize(.small)
                    Button("해제") { clearTemplateColumns() }
                        .controlSize(.small)
                }
                .padding(.horizontal, 14).padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.green.opacity(0.09)))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.green.opacity(0.45), lineWidth: 1))
            } else {
                HStack(spacing: 12) {
                    Image(systemName: "doc.on.doc")
                        .font(.title2)
                        .foregroundStyle(isBaseDropTargeted ? Color.accentColor : .secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("1. 맞출 틀이 있나요?  —  없으면 건너뛰세요")
                            .font(.body.weight(.semibold))
                        Text("전에 만들어 둔 통합본이나 채워 넣을 양식이 있으면 여기에 먼저 끌어다 놓으세요.\n그 파일에서는 **컬럼 이름만** 가져옵니다 — 값은 올린 파일 것만 들어가고, 결과는 그 컬럼 구성으로 나옵니다.")
                            .font(.body).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    Button("틀 파일 고르기…") { chooseTemplateColumns() }
                        .controlSize(.small)
                }
                .padding(.horizontal, 14).padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isBaseDropTargeted ? Color.accentColor.opacity(0.10)
                                             : Color.primary.opacity(0.03)))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(isBaseDropTargeted ? Color.accentColor : Color.primary.opacity(0.14),
                                  style: StrokeStyle(lineWidth: isBaseDropTargeted ? 2 : 1, dash: [5, 4])))
            }
        }
        // 이 칸에 떨어뜨린 파일은 합칠 파일이 아니라 ‘틀’ — 바깥 드롭보다 이쪽이 먼저 받는다.
        .onDrop(of: [.fileURL], isTargeted: $isBaseDropTargeted, perform: acceptBaseDrop)
    }

    // MARK: - Stage 1: add files (centered onboarding)

    private var filesStage: some View {
        ScrollView {
            VStack(spacing: 20) {
                VStack(spacing: 8) {
                    Image("AppLogo")
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .frame(width: 112, height: 112)
                        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                        .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
                        .accessibilityLabel("데이터 마법사 로고")
                    Text("여러 파일 하나로 합치기")
                        .font(.system(.largeTitle, design: .rounded).weight(.bold))
                    Text("흩어진 지원 파일들을 추가하면, 완성될 컬럼과 그 안의 값을 하나씩 확인한 뒤 하나의 명단으로 만듭니다. 파일 하나만 고칠 거라면 뒤로 가세요.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let resumable, inputs.isEmpty {
                    resumeCard(resumable)
                }

                Button(action: addFiles) {
                    Label("파일 추가…", systemImage: "plus").frame(maxWidth: .infinity)
                }
                .controlSize(.large)

                if inputs.isEmpty {
                    Text("CSV·XLSX 파일을 여러 개 추가할 수 있어요.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                } else {
                    VStack(spacing: 8) {
                        ForEach(inputs) { input in
                            InputFileRow(input: input) { remove(input) }
                        }
                    }
                }

                Button(action: prepareReview) {
                    HStack {
                        if isPreparing { ProgressView().controlSize(.small) }
                        Text(isPreparing ? "불러오는 중…" : "컬럼 고르기 →").fontWeight(.semibold)
                    }
                    .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .disabled(inputs.isEmpty || isPreparing)

                if let errorMessage { errorLabel(errorMessage) }

                Button("← 파일 하나 고치기로 돌아가기") { backToWork() }
                    .buttonStyle(.link)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: 520)
            .padding(40)
            .frame(maxWidth: .infinity)
        }
    }

    /// 예전 세션은 숨긴 행까지 읽어 둔 상태일 수 있다 — 그럴 땐 새로 여는 게 맞다.
    private func resumeNeedsReload(_ s: SessionSnapshot) -> Bool {
        (s.hiddenRowsAware ?? false) == false
            && s.files.contains { $0.path.lowercased().hasSuffix(".xlsx") }
    }

    /// 이전에 하던 작업을 이어서 할지 묻는 카드 (파일 화면 상단).
    private func resumeCard(_ s: SessionSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "arrow.uturn.forward.circle.fill")
                    .font(.title2).foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("이전 작업 이어서 하기")
                        .font(.headline)
                    Text("\(s.summary) · 저장 \(Self.savedAtText(s.savedAt))")
                        .font(.body).foregroundStyle(.secondary)
                    if resumeNeedsReload(s) {
                        Text("이 작업은 예전 규칙으로 읽혀서 **시트에서 숨긴 행까지** 들어 있을 수 있어요. "
                             + "숨긴 행을 빼고 다시 읽으려면 ‘새로 시작’ 후 파일을 다시 올려 주세요.")
                            .font(.body).foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer()
            }
            HStack {
                Button("새로 시작") { discardSession() }
                Spacer()
                Button {
                    restore(s)
                } label: {
                    Label("이어서 하기", systemImage: "play.fill").fontWeight(.semibold)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.accentColor.opacity(0.08)))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.accentColor.opacity(0.3), lineWidth: 1))
    }

    /// 저장 시각을 사람이 읽기 쉬운 상대/절대 표기로.
    private static func savedAtText(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ko_KR")
        f.dateFormat = "M월 d일 HH:mm"
        return f.string(from: date)
    }

    // MARK: - Stage 1.5: choose which columns to keep in the final output

    /// 데이터가 있는(검토 대상) 최종 컬럼 집합 — 이 안에 있으면 ‘데이터 있음’.
    private var dataColumns: Set<UnifiedColumn> { Set(finalColumns) }

    /// 이번 작업이 다루는 컬럼 전체와 그 순서 — 목록·내보내기의 기준선.
    /// 고정 스키마가 없어졌으므로 상수가 아니라 이번 파일들에서 계산한다:
    /// 기준 파일(있으면) 순서 → 이번 데이터의 컬럼 → 아카데미 프리셋의 나머지.
    private var allColumns: [UnifiedColumn] {
        var out: [UnifiedColumn] = []
        var seen = Set<UnifiedColumn>()
        for c in (base?.columns ?? []) where seen.insert(c).inserted { out.append(c) }
        for c in finalColumns where seen.insert(c).inserted { out.append(c) }
        for c in referenceColumns.sorted(by: { $0.rawValue < $1.rawValue })
        where seen.insert(c).inserted { out.append(c) }
        return out
    }

    /// 컬럼 선택 화면에 보여줄 후보 — 이번 데이터의 컬럼이 먼저, 아카데미 프리셋의
    /// 빈 자리 컬럼은 뒤에. 참조가 있으면 참조 컬럼을 맨 위로 올린다.
    private var columnCandidates: [UnifiedColumn] {
        var universe = allColumns
        var seen = Set(universe)
        for c in UnifiedColumn.academyPreset where seen.insert(c).inserted { universe.append(c) }
        func rank(_ c: UnifiedColumn) -> Int {
            if referenceColumns.contains(c) { return 0 }
            if dataColumns.contains(c) { return 1 }
            return 2
        }
        return universe.enumerated()
            .sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }
            .map { $0.element }
    }

    private func reviewFor(_ col: UnifiedColumn) -> ColumnReview? {
        reviews.first { $0.column == col }
    }

    /// 한 컬럼의 데이터 상태 요약 (선택 화면 부제).
    private func columnStatus(_ col: UnifiedColumn) -> (text: String, hasData: Bool) {
        guard dataColumns.contains(col) else {
            return (referenceColumns.contains(col)
                    ? "참조 기준 포함 · 현재 데이터 없음(빈 값)"
                    : "빈 컬럼 — 자리만 유지 (값 없음)", false)
        }
        if let r = reviewFor(col) {
            switch r.kind {
            case .derived: return ("자동 생성 컬럼", true)
            case .phone, .date:
                return ("\(r.total)행 · \(r.distinctCount)종", true)
            default:
                return ("\(r.total)행 · \(r.distinctCount)종 값", true)
            }
        }
        return ("데이터 있음", true)
    }

    /// 컬럼 고르기 단계. 아직 갈림길을 안 골랐으면 선택 화면을, 골랐으면
    /// (새로 만들기) 컬럼 선택 화면을 보여준다. ‘틀 있음’은 불러오는 즉시
    /// 값 검토로 넘어가므로 이 단계에 머무르지 않는다.
    @ViewBuilder
    private var columnsStage: some View {
        if columnMode == nil {
            columnForkView
        } else {
            columnPickerView
        }
    }

    /// 첫 갈림길: 이번 작업을 어떤 식으로 할지 고른다.
    /// 1) 기존에 만들던 통합본에 지금 정제할 컬럼만 덮어쓰기(부분 정제),
    /// 2) 기존 통합본의 컬럼 구성만 빌려 이번 데이터로 전부 새로 채우기,
    /// ③ 남길 컬럼을 직접 골라 새 틀 만들기.
    private var columnForkView: some View {
        ScrollView {
            VStack(spacing: 24) {
                VStack(spacing: 8) {
                    Text("결과물을 어디에 만들까요?")
                        .font(.system(.largeTitle, design: .rounded).weight(.bold))
                        .multilineTextAlignment(.center)
                    Text("방금 넣은 파일 \(plans.count)개를 어디에 담을지만 정하면 됩니다. 한 번에 모든 컬럼을 끝낼 필요는 없어요.")
                        .font(.body).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(spacing: 12) {
                    // 1) 이미 저장해 둔 결과 파일을 계속 고쳐 나가는 경우.
                    forkCard(number: 1,
                             icon: "arrow.trianglehead.merge",
                             title: "만들던 파일 이어서 고치기",
                             when: "지난주에 도시까지 정리해서 저장해 뒀어요. 오늘은 도시 하나만 더 손보고 싶어요.",
                             outcome: "결과물 = 그때 저장한 파일 그대로 + 오늘 고른 컬럼만 바뀜",
                             cta: "만들던 파일 불러오기…",
                             prominent: true,
                             action: chooseBase) {
                        Text("지난주 파일의 한 사람")
                            .foregroundStyle(.secondary)
                        exampleLine("도시", "서울", "Seoul", changed: true)
                        exampleLine("신분", "대학생", "대학생", changed: false)
                        exampleLine("메모", "면접 우선", "면접 우선", changed: false)
                        Text("오늘 고른 ‘도시’만 바뀌고 나머지는 그대로")
                            .foregroundStyle(Color.accentColor)
                    }

                    // 2) 틀만 빌리고 값은 이번 데이터로 전부 새로.
                    forkCard(number: 2,
                             icon: "doc.on.doc.fill",
                             title: "컬럼 구성만 따라 하기",
                             when: "2분기 보고서랑 똑같은 컬럼 순서로, 7·8·9월 데이터를 처음부터 정리하고 싶어요.",
                             outcome: "결과물 = 완전히 새 파일 (컬럼 이름·순서만 그 파일에서 빌려 옴)",
                             cta: "틀만 불러오기…",
                             prominent: false,
                             action: chooseTemplate) {
                        Text("2분기 보고서에서 빌리는 것")
                            .foregroundStyle(.secondary)
                        Text("컬럼 이름·순서:  이름 · 도시 · 신분")
                        Text("값은 안 씀 (사람도 안 가져옴)")
                            .foregroundStyle(.secondary)
                        Divider().padding(.vertical, 1)
                        Text("오늘 넣은 7·8·9월 파일의 사람들로 전부 새로 채움")
                            .foregroundStyle(Color.accentColor)
                    }

                    // ③ 맨 처음부터.
                    forkCard(number: 3,
                             icon: "sparkles",
                             title: "처음부터 새로 만들기",
                             when: "이 도구는 오늘 처음 써요. 참고할 파일도 없어요.",
                             outcome: "결과물 = 완전히 새 파일 (남길 컬럼을 다음 화면에서 직접 체크)",
                             cta: "컬럼 직접 고르기",
                             prominent: false,
                             action: { base = nil; patch = nil; focusColumns = []
                                       columnMode = .fromScratch }) {
                        Text("다음 화면에서 이렇게 고릅니다")
                            .foregroundStyle(.secondary)
                        Text("☑ 이름      ☑ 도시")
                        Text("☑ 전화번호  ☐ 주소")
                        Text("체크한 컬럼만 결과물에 남음")
                            .foregroundStyle(Color.accentColor)
                    }
                }
                .frame(maxWidth: 900)

                forkHelp.frame(maxWidth: 900)

                if let errorMessage { errorLabel(errorMessage).frame(maxWidth: 520) }

                Button("← 파일") { backToFiles() }
                    .controlSize(.large)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: 960)
            .padding(32)
            .frame(maxWidth: .infinity)
        }
    }

    /// 그래도 못 고르겠을 때 보는 안내 — 질문 하나로 셋 중 하나에 도달한다.
    private var forkHelp: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("어떤 걸 골라야 할지 모르겠다면", systemImage: "questionmark.circle.fill")
                .font(.body.weight(.semibold))
            Text("전에 이 도구로 만들어 저장해 둔 결과 파일이 있나요?")
                .font(.body)
            VStack(alignment: .leading, spacing: 6) {
                forkHelpRow("있고, 그 파일을 계속 고쳐 나가고 싶다", 1, "만들던 파일 이어서 고치기")
                forkHelpRow("있지만, 값은 오늘 넣은 데이터로 전부 다시 만들 거다", 2, "컬럼 구성만 따라 하기")
                forkHelpRow("없다 / 오늘 처음 만든다", 3, "처음부터 새로 만들기")
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color.primary.opacity(0.035)))
    }

    private func forkHelpRow(_ situation: String, _ number: Int, _ title: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("•").foregroundStyle(.secondary)
            Text(situation)
                .fixedSize(horizontal: false, vertical: true)
            Image(systemName: "arrow.right").font(.body).foregroundStyle(.secondary)
            Text("\(number)번 · \(title)")
                .fontWeight(.semibold).foregroundStyle(Color.accentColor)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .font(.body)
    }

    /// 예시 박스 안의 한 줄: `도시   서울 → Seoul`.
    /// 바뀌는 칸만 색·굵기로 튀게 해서, 무엇이 달라지는지 글 없이도 보이게 한다.
    private func exampleLine(_ field: String, _ before: String, _ after: String,
                             changed: Bool) -> some View {
        HStack(spacing: 5) {
            Text(field)
                .foregroundStyle(.secondary)
                .frame(width: 40, alignment: .leading)
            Text(before).foregroundStyle(.secondary)
            Image(systemName: changed ? "arrow.right" : "equal")
                .font(.system(size: 8))
                .foregroundStyle(changed ? Color.accentColor : Color.secondary.opacity(0.5))
            Text(after)
                .fontWeight(changed ? .bold : .regular)
                .foregroundStyle(changed ? Color.accentColor : Color.secondary)
            Spacer(minLength: 0)
        }
        .lineLimit(1)
    }

    /// 갈림길의 선택 카드 하나 — 번호·제목·‘이럴 때’ 한 문장·결과물, 그리고 오른쪽에 실제 값 예시.
    private func forkCard<Example: View>(number: Int, icon: String, title: String,
                                         when: String, outcome: String,
                                         cta: String, prominent: Bool,
                                         action: @escaping () -> Void,
                                         @ViewBuilder example: () -> Example) -> some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(spacing: 6) {
                ZStack {
                    Circle()
                        .fill(prominent ? Color.accentColor : Color.secondary.opacity(0.25))
                        .frame(width: 26, height: 26)
                    Text("\(number)").font(.body.weight(.bold))
                        .foregroundStyle(prominent ? .white : .secondary)
                }
                Image(systemName: icon)
                    .font(.system(size: 20))
                    .foregroundStyle(prominent ? Color.accentColor : Color.secondary)
            }
            .frame(width: 30)

            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.title3.weight(.bold))
                    .fixedSize(horizontal: false, vertical: true)
                // 사용자가 스스로에게 할 법한 말 그대로 — 자기 상황을 알아보게.
                Text("“\(when)”")
                    .font(.body).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Label(outcome, systemImage: "arrow.right.circle.fill")
                    .font(.body.weight(.medium))
                    .foregroundStyle(prominent ? Color.accentColor : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                Group {
                    if prominent {
                        Button(action: action) { Text(cta).fontWeight(.semibold) }
                            .buttonStyle(.borderedProminent)
                    } else {
                        Button(action: action) { Text(cta).fontWeight(.semibold) }
                            .buttonStyle(.bordered)
                    }
                }
                .controlSize(.large)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .leading, spacing: 4) {
                example()
            }
            .font(.system(.body, design: .monospaced))
            .frame(width: 290, alignment: .leading)
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1))
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(prominent ? Color.accentColor.opacity(0.06)
                                : Color(nsColor: .controlBackgroundColor)))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(prominent ? Color.accentColor.opacity(0.35)
                                  : Color.primary.opacity(0.08), lineWidth: 1))
    }

    private var columnPickerView: some View {
        VStack(spacing: 0) {
            // Toolbar
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("남길 컬럼 고르기").font(.title2.weight(.bold))
                    Text("최종 결과물에 어떤 컬럼을 남길지 먼저 정하세요. 여기서 고른 컬럼만 값 검토·미리보기·내보내기에 나타납니다.")
                        .font(.body).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                if let errorMessage { errorLabel(errorMessage).frame(maxWidth: 280) }
                Button("← 뒤로") { columnMode = nil }
                Button(action: proceedToReview) {
                    Text("다음: 값 검토 →").fontWeight(.semibold)
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .disabled(includedColumns.isEmpty)
                .help(includedColumns.isEmpty ? "최소 한 개 이상 컬럼을 남겨야 해요."
                                              : "선택한 컬럼으로 값 검토를 시작합니다.")
            }
            .padding(20)
            Divider()

            referenceBar
            Divider()

            // Quick actions + count
            HStack(spacing: 10) {
                Text("선택 \(includedColumns.count) / \(columnCandidates.count)개")
                    .font(.headline).monospacedDigit()
                Spacer()
                Button("데이터 있는 것만") { includedColumns = dataColumns }
                    .help("값이 실제로 들어 있는 컬럼만 남깁니다. 빈 자리 컬럼은 제외돼요.")
                Button("전체 선택") { includedColumns = Set(columnCandidates) }
                Button("전체 해제") { includedColumns = [] }
            }
            .controlSize(.regular)
            .padding(.horizontal, 24).padding(.vertical, 12)
            Divider()

            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(columnCandidates) { col in
                        columnPickRow(col)
                    }
                }
                .padding(24)
            }
        }
    }

    /// 이전 완성본을 참조로 불러오는 줄. 불러오면 그 컬럼 구성으로 맞춰진다.
    private var referenceBar: some View {
        HStack(spacing: 12) {
            Image(systemName: "doc.on.doc")
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                if let referenceName {
                    Text("참조: \(referenceName)")
                        .font(.body.weight(.medium))
                        .lineLimit(1).truncationMode(.middle)
                    Text("컬럼 \(referenceColumns.count)개를 이 구성으로 맞췄어요"
                         + (referenceUnmatched.isEmpty ? ""
                            : " · 못 알아본 헤더 \(referenceUnmatched.count)개"))
                        .font(.body).foregroundStyle(.secondary)
                        .help(referenceUnmatched.isEmpty ? ""
                              : "스키마에 없는 헤더:\n" + referenceUnmatched.joined(separator: "\n"))
                } else {
                    Text("이전 완성본으로 컬럼 맞추기")
                        .font(.body.weight(.medium))
                    Text("예: 2분기 보고서를 넣으면 7·8·9월 데이터도 같은 컬럼 구성으로 남깁니다.")
                        .font(.body).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
            if referenceName != nil {
                Button("참조 해제") { clearReference() }
            }
            Button(action: { loadReference() }) {
                Label(referenceName == nil ? "완성본 불러오기…" : "다른 파일로 바꾸기…",
                      systemImage: "tray.and.arrow.down")
            }
        }
        .padding(.horizontal, 24).padding(.vertical, 12)
        .background(referenceName != nil ? Color.accentColor.opacity(0.05) : Color.clear)
    }

    private func columnPickRow(_ col: UnifiedColumn) -> some View {
        let on = includedColumns.contains(col)
        let status = columnStatus(col)
        return Button {
            if on { includedColumns.remove(col) } else { includedColumns.insert(col) }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: on ? "checkmark.square.fill" : "square")
                    .font(.title3)
                    .foregroundStyle(on ? Color.accentColor : Color.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(col.rawValue)
                        .font(.body.weight(.medium))
                        .foregroundStyle(on ? .primary : .secondary)
                        .lineLimit(1).truncationMode(.tail).help(col.rawValue)
                    Text(status.text)
                        .font(.body)
                        .foregroundStyle(status.hasData ? Color.secondary : Color.orange)
                }
                Spacer(minLength: 8)
                if referenceColumns.contains(col) {
                    Text("참조")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Capsule().fill(Color.accentColor.opacity(0.12)))
                }
                if !status.hasData {
                    Text("빈 컬럼")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Capsule().fill(Color.orange.opacity(0.12)))
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(on ? Color.accentColor.opacity(0.06) : Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(on ? Color.accentColor.opacity(0.35) : Color.primary.opacity(0.06),
                            lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Stage 1.5b: 이번에 정제할 컬럼 고르기 (부분 정제)

    /// 이번에 손볼 후보 — 새로 넣은 파일에 데이터가 있는 최종 컬럼.
    /// 손댈 거리가 남은 컬럼(⚠️)을 위로, 그다음 기존본에 이미 있는 컬럼 순.
    private var focusCandidates: [UnifiedColumn] {
        let byColumn = Dictionary(reviews.map { ($0.column, $0) }, uniquingKeysWith: { a, _ in a })
        func rank(_ c: UnifiedColumn) -> Int {
            guard let r = byColumn[c] else { return 3 }
            if r.kind == .derived { return 2 }
            if openCount(r) > 0 { return 0 }
            return isDecisionRelevant(r) ? 1 : 2
        }
        return finalColumns.enumerated()
            .sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }
            .map { $0.element }
    }

    /// 지금 상태로 정제할 거리가 남아 있는 컬럼들 (‘손볼 거리 있는 것만’ 버튼용).
    private var unresolvedColumns: Set<UnifiedColumn> {
        Set(reviews.filter { $0.kind != .derived && openCount($0) > 0 }.map { $0.column })
    }

    // MARK: - 완성될 틀 기준 진단

    /// 틀에 비춰 이 컬럼에 할 일이 남았는가.
    /// 값 자체의 오타·형식(openCount)과 달리, ‘완성본에 이미 들어 있는 모양’과
    /// 이번 데이터가 어긋나는지를 본다.
    struct TemplateGap {
        var isNew = false     // 틀에 없는 컬럼 — 결과 파일 맨 뒤에 새로 생긴다
        var outside = 0       // 틀의 값 목록에 없는 값 종 수
        var known = 0         // 틀이 이 컬럼에 가지고 있는 값 종 수
        var locked = false    // 이미 틀 목록으로 잠가 둠 (그때부턴 openCount가 셈)
        var comparable = false // 값 목록으로 견줄 수 있는 컬럼인가 (범주형)
        var warn: Bool { isNew || outside > 0 }
    }

    /// 틀을 잡거나 바꿀 때 한 번 훑어 컬럼별 값 목록을 만들어 둔다.
    private func indexBase() {
        guard baseIsUserFile, let sheet = base else {
            baseValues = [:]; baseCategorical = []
            return
        }
        var vals: [UnifiedColumn: [String]] = [:]
        var cats: Set<UnifiedColumn> = []
        for col in sheet.columns {
            let v = sheet.distinctValues(col)
            vals[col] = v
            if sheet.looksCategorical(col, values: v) { cats.insert(col) }
        }
        baseValues = vals
        baseCategorical = cats
    }

    private func templateGap(_ review: ColumnReview) -> TemplateGap {
        var gap = TemplateGap()
        guard review.kind != .derived else { return gap }
        // 컬럼 이름만 빌려 온 틀: 그 목록에 없으면 ‘새 컬럼’.
        if !templateColumns.isEmpty {
            gap.isNew = !templateColumns.contains(review.column)
            return gap
        }
        guard baseIsUserFile, base != nil else { return gap }
        guard let known = baseValues[review.column] else {
            gap.isNew = true
            return gap
        }
        gap.known = known.count
        if !(allowedValues[review.column] ?? []).isEmpty {
            // 이미 목록으로 잠갔다 — 남은 값은 openCount가 세고 있으므로 여기서 또 세지 않는다.
            gap.locked = true
            gap.comparable = true
            return gap
        }
        guard baseCategorical.contains(review.column) else { return gap }
        gap.comparable = true
        let set = Set(known)
        let map = valueMap[review.column] ?? [:]
        gap.outside = review.values.filter { !set.contains(map[$0.value] ?? $0.value) }.count
        return gap
    }

    private func templateGap(_ col: UnifiedColumn) -> TemplateGap {
        reviewFor(col).map(templateGap) ?? TemplateGap()
    }

    /// 틀의 값 목록을 이 컬럼의 허용 목록으로 삼는다 —
    /// 이후로는 목록 밖 값이 미해결로 잡히고, 유사도 추천·선택 메뉴가 붙는다.
    private func lockToBase(_ col: UnifiedColumn) {
        guard let known = baseValues[col], !known.isEmpty else { return }
        allowedValues[col] = known
        refreshPreview()
    }

    private func unlockFromBase(_ col: UnifiedColumn) {
        allowedValues[col] = []
        refreshPreview()
    }

    /// 컬럼 한 줄에 붙는 상태 문구 — 값 종 수와 남은 결정 건수, 그리고 틀과의 어긋남.
    private func focusStatus(_ col: UnifiedColumn) -> (text: String, warn: Bool, badge: String) {
        cache.status[col] ?? computeFocusStatus(col)
    }

    /// 기존 통합본에 이번에 고른 컬럼만 덮어쓰는 흐름의 컬럼 선택 화면.
    /// 체크하지 않은 컬럼은 기존 파일 값이 그대로 유지된다.
    @ViewBuilder
    private var focusStage: some View {
        if let base {
            VStack(spacing: 0) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("이번에 정제할 컬럼 고르기").font(.title2.weight(.bold))
                        Text("체크한 컬럼만 새로 정제해서 ‘\(base.name)’에 덮어씁니다. 체크하지 않은 컬럼은 기존 파일 값이 그대로 유지돼요.")
                            .font(.body).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    if let errorMessage { errorLabel(errorMessage).frame(maxWidth: 260) }
                    Button("← 뒤로") { columnMode = nil; stage = .columns }
                    Button(action: proceedToFocusedReview) {
                        Text("다음: 값 검토 →").fontWeight(.semibold)
                    }
                    .controlSize(.large)
                    .buttonStyle(.borderedProminent)
                    .disabled(focusColumns.isEmpty)
                    .help(focusColumns.isEmpty ? "정제할 컬럼을 최소 하나 골라 주세요."
                                               : "고른 컬럼만 검토하고, 그 값만 기존본에 반영합니다.")
                }
                .padding(20)
                Divider()

                baseBar(base)
                Divider()

                HStack(spacing: 10) {
                    Text("선택 \(focusColumns.count) / \(finalColumns.count)개")
                        .font(.headline).monospacedDigit()
                    Spacer()
                    Button("손볼 거리 있는 것만") { focusColumns = unresolvedColumns }
                        .disabled(unresolvedColumns.isEmpty)
                        .help("전화번호 표준화 실패·매핑표 밖 값·오타 의심값이 남은 컬럼만 고릅니다.")
                    Button("전체 선택") { focusColumns = Set(finalColumns) }
                    Button("전체 해제") { focusColumns = [] }
                }
                .controlSize(.regular)
                .padding(.horizontal, 24).padding(.vertical, 12)
                Divider()

                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(focusCandidates) { col in
                            focusPickRow(col, base: base)
                        }
                    }
                    .padding(24)
                }
            }
        } else {
            Color.clear.onAppear { stage = .columns; columnMode = nil }
        }
    }

    /// 기준으로 삼은 기존 통합본 요약 줄.
    private func baseBar(_ base: BaseSheet) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.trianglehead.merge")
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text("이어붙일 파일: \(base.name)")
                    .font(.body.weight(.medium))
                    .lineLimit(1).truncationMode(.middle)
                Text("\(base.rows.count)행 · 컬럼 \(base.headers.count)개 — 고르지 않은 컬럼은 그대로 보존")
                    .font(.body).foregroundStyle(.secondary)
            }
            Spacer()
            Button("다른 파일로 바꾸기…") { chooseBase() }
        }
        .padding(.horizontal, 24).padding(.vertical, 12)
        .background(Color.accentColor.opacity(0.05))
    }

    private func focusPickRow(_ col: UnifiedColumn, base: BaseSheet) -> some View {
        let on = focusColumns.contains(col)
        let status = focusStatus(col)
        let inBase = base.columnHeader[col] != nil
        return Button {
            if on { focusColumns.remove(col) } else { focusColumns.insert(col) }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: on ? "checkmark.square.fill" : "square")
                    .font(.title3)
                    .foregroundStyle(on ? Color.accentColor : Color.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(col.rawValue)
                        .font(.body.weight(.medium))
                        .foregroundStyle(on ? .primary : .secondary)
                        .lineLimit(1).truncationMode(.tail).help(col.rawValue)
                    Text(status.text)
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if status.warn {
                    Text(status.badge)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Capsule().fill(Color.orange.opacity(0.12)))
                }
                Text(inBase ? "기존본에 있음" : "새 컬럼으로 추가")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(inBase ? Color.secondary : Color.accentColor)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Capsule().fill(inBase ? Color.primary.opacity(0.06)
                                                      : Color.accentColor.opacity(0.12)))
                    .help(inBase ? "기존 파일의 같은 이름 컬럼에 덮어씁니다."
                                 : "기존 파일에 없는 컬럼이라 맨 뒤에 새로 만들어 채웁니다.")
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(on ? Color.accentColor.opacity(0.06) : Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(on ? Color.accentColor.opacity(0.35) : Color.primary.opacity(0.06),
                            lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Stage 2: column-by-column review with checkboxes

    /// 검토·미리보기에 실제로 나타나는 컬럼 — 데이터가 있는 최종 컬럼 중
    /// 사용자가 남기기로 선택한 것들.
    private var visibleFinalColumns: [UnifiedColumn] {
        finalColumns.filter { includedColumns.contains($0) }
    }
    private var visibleReviews: [ColumnReview] {
        reviews.filter { includedColumns.contains($0.column) }
    }
    /// 내보내기에 쓸 컬럼 — 이번 작업의 컬럼 순서를 지키며 선택된 것만.
    private var includedOrdered: [UnifiedColumn] {
        allColumns.filter { includedColumns.contains($0) }
    }

    private var allChecked: Bool {
        !visibleFinalColumns.isEmpty && visibleFinalColumns.allSatisfy { checked.contains($0) }
    }

    // MARK: - Column type (사용자 지정 타입)

    /// 자동 판단한 기본 타입 (Claude의 판단). 사용자가 안 바꾸면 이 값을 쓴다.
    private func autoType(_ review: ColumnReview) -> ColumnType {
        switch review.kind {
        case .category:     return .category
        case .phone, .date: return .format
        case .freeText:     return review.column == .email ? .format : .freeText
        case .derived:      return .freeText   // 파생 컬럼엔 타입 선택기를 안 보임
        }
    }

    /// 이 컬럼에 실제로 적용되는 타입 (사용자 지정 > 자동 판단).
    private func effectiveType(_ review: ColumnReview) -> ColumnType {
        typeOverride[review.column] ?? autoType(review)
    }

    /// 포맷 타입일 때 자동으로 고르는 형식.
    private func autoFormat(_ review: ColumnReview) -> FormatPreset {
        switch review.kind {
        case .phone: return .phone
        case .date:  return .date
        default:     return .email
        }
    }
    private func effectiveFormat(_ review: ColumnReview) -> FormatPreset {
        formatChoice[review.column] ?? autoFormat(review)
    }
    /// 포맷 검증에 쓸 정규식 (직접 입력이면 사용자 패턴).
    private func effectivePattern(_ review: ColumnReview) -> String {
        let f = effectiveFormat(review)
        return f == .custom ? (customFormat[review.column] ?? "") : f.pattern
    }

    /// 전용 제안 화면(ProposalsBody)을 쓰는 포맷인가 — 전화/생년월일 컬럼에서
    /// 형식을 그대로 유지할 때만. 이메일·직접 정규식은 일반 검증 화면(FormatBody).
    private func usesProposalUI(_ review: ColumnReview) -> Bool {
        (review.kind == .phone && effectiveFormat(review) == .phone)
            || (review.kind == .date && effectiveFormat(review) == .date)
    }

    /// 포맷(일반 검증) 컬럼에서 형식에 맞지 않는 값들 (사용자 수정 반영).
    private func formatFailures(_ review: ColumnReview) -> [DistinctValue] {
        let pat = effectivePattern(review)
        guard !pat.isEmpty, RegexCleaner.isValid(pat) else { return [] }
        let map = valueMap[review.column] ?? [:]
        return review.values.filter { !RegexCleaner.fullyMatches(map[$0.value] ?? $0.value, pat) }
    }

    private func setType(_ type: ColumnType, for review: ColumnReview) {
        if type == autoType(review) { typeOverride[review.column] = nil }
        else { typeOverride[review.column] = type }
        refreshPreview()
    }
    private func setFormat(_ preset: FormatPreset, for col: UnifiedColumn) {
        formatChoice[col] = preset
        refreshPreview()
    }

    // MARK: - 자동 해결 (접힌 카드에서 한 번에 고치기)

    /// 이 컬럼에서 추천값으로 즉시 고칠 수 있는 값의 종 수.
    /// 오타 추천(자유입력)·유사도 추천(범주)만 해당 — 이메일·정규식·전화·날짜는
    /// 안전한 자동값이 없어 0(직접 입력해야 함).
    private func autoFixCount(_ review: ColumnReview) -> Int {
        let map = valueMap[review.column] ?? [:]
        switch effectiveType(review) {
        case .freeText:
            return review.anomalies.filter {
                $0.fixable && (map[$0.value] ?? $0.value) == $0.value
            }.count
        case .category:
            guard let allowed = allowedValues[review.column], !allowed.isEmpty else { return 0 }
            return review.values.filter {
                let cur = map[$0.value] ?? $0.value
                return !allowed.contains(cur) && Similarity.best($0.value, in: allowed) != nil
            }.count
        case .format:
            return 0
        }
    }

    /// 추천값을 한 번에 적용한다 (오타 추천 또는 매핑표 유사도 추천).
    private func applyAutoFix(_ review: ColumnReview) {
        let col = review.column
        var map = valueMap[col] ?? [:]
        switch effectiveType(review) {
        case .freeText:
            for f in review.anomalies where f.fixable && (map[f.value] ?? f.value) == f.value {
                map[f.value] = f.suggestion
            }
        case .category:
            if let allowed = allowedValues[col], !allowed.isEmpty {
                for dv in review.values {
                    let cur = map[dv.value] ?? dv.value
                    if allowed.contains(cur) { continue }
                    if let rec = Similarity.best(dv.value, in: allowed) { map[dv.value] = rec.target }
                }
            }
        case .format:
            return
        }
        valueMap[col] = map
        refreshPreview()
    }

    // MARK: - Decisions (결정 TODO)

    /// 이 컬럼에서 아직 사람이 결정하지 못한 값의 종 수.
    /// 0이면 결정 완료(자동 처리됐거나 사용자가 다 정리함). >0이면 ⚠️ 미해결.
    private func openCount(_ review: ColumnReview) -> Int {
        let map = valueMap[review.column] ?? [:]
        switch effectiveType(review) {
        case .format:
            if usesProposalUI(review) {
                // 표준 포맷에 도달하지 못했고, 사용자가 아직 손대지 않은 값.
                return review.proposals.filter {
                    !$0.standard && (map[$0.value] ?? $0.value) == $0.value
                }.count
            }
            // 이메일·직접 정규식: 형식에 맞지 않는 값이 결정 대상.
            return formatFailures(review).count
        case .category:
            // 허용 목록이 정해진 컬럼: 목록 밖에 남은 값이 결정 대상.
            guard let allowed = allowedValues[review.column], !allowed.isEmpty else { return 0 }
            return review.values.filter { !allowed.contains(map[$0.value] ?? $0.value) }.count
        case .freeText:
            // 오타 의심값 중 아직 수정하지 않은 값.
            return review.anomalies.filter { (map[$0.value] ?? $0.value) == $0.value }.count
        }
    }

    /// 이 컬럼이 ‘결정 TODO’에 나타날 만한가 (사람이 볼 판단거리가 있는가).
    /// 매핑표 적용 컬럼·전화/생년월일·이상값·값 종류가 여럿인 카테고리·이미 만진 컬럼.
    private func isDecisionRelevant(_ review: ColumnReview) -> Bool {
        if review.kind == .derived { return false }
        if openCount(review) > 0 { return true }
        if checked.contains(review.column) { return true }
        switch effectiveType(review) {
        case .format:
            if usesProposalUI(review) {
                return review.flaggedCount > 0    // 표준화 실패가 있었던 컬럼만 (깨끗하면 전체 탭으로)
            }
            // 이메일·직접 정규식: 형식 안 맞는 값이 하나라도 있으면 결정거리.
            let pat = effectivePattern(review)
            guard !pat.isEmpty, RegexCleaner.isValid(pat) else { return false }
            return review.values.contains { !RegexCleaner.fullyMatches($0.value, pat) }
        case .category:
            if !(allowedValues[review.column] ?? []).isEmpty { return true }   // 허용 목록 고정
            return review.distinctCount > 1        // 통일 후보(값이 여러 종)
        case .freeText:
            return !review.anomalies.isEmpty
        }
    }

    /// 이 컬럼의 결정이 끝났는가: 미해결 0 또는 사용자가 ‘이대로 확정’ 체크.
    private func isResolved(_ review: ColumnReview) -> Bool {
        openCount(review) == 0 || checked.contains(review.column)
    }

    /// 결정 TODO에 표시할 리뷰들 — 미해결(⚠️) 먼저, 그다음 컬럼 순서.
    private var decisionReviews: [ColumnReview] {
        visibleReviews.filter(isDecisionRelevant).sorted { a, b in
            let ra = isResolved(a), rb = isResolved(b)
            if ra != rb { return !ra && rb }          // 미해결이 위로
            let oa = openCount(a), ob = openCount(b)
            if oa != ob { return oa > ob }            // 미해결 종 수 많은 순
            return false                              // 안정 정렬 (filter가 export 순서 유지)
        }
    }

    private var openDecisions: [ColumnReview] {
        decisionReviews.filter { !isResolved($0) }
    }

    /// 유틸 모드인가 — 올린 파일을 그대로 다루는 흐름 (아카데미 통합 엔진을 쓰지 않음).
    private var isUtility: Bool { !plans.isEmpty && plans.allSatisfy(\.passthrough) }

    /// 언제든 가져갈 수 있다. 유틸은 사용자를 가로막지 않는다 —
    /// 미해결이 남아 있으면 막는 대신 몇 종 남았는지 알려만 준다.
    private var canMerge: Bool { true }

    private var reviewStage: some View {
        VStack(spacing: 0) {
            reviewToolbar
            Divider()
            if let col = openColumn, let review = reviewFor(col) {
                columnDetailPage(review)
            } else {
                columnListPage
            }
        }
        .onAppear { syncSteps() }
        .onChange(of: checked) { _ in refreshPreview(); syncSteps() }
        .onChange(of: valueMap) { _ in refreshPreview(); syncSteps() }
        .onChange(of: phoneTemplate) { _ in refreshPreview() }
        // 타입·형식은 값이 아니라 ‘무엇을 미해결로 볼지’를 바꾼다 — 컬럼 상태 표시가
        // 따라가도록 여기서도 다시 계산한다.
        .onChange(of: formatChoice) { _ in refreshPreview() }
        .onChange(of: customFormat) { _ in refreshPreview() }
    }

    /// 결정할 게 하나도 없을 때(모두 자동 처리됨) 보여주는 안내.
    private var emptyDecisionsCard: some View {
        VStack(spacing: 8) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 34)).foregroundStyle(.green)
            Text("눈에 띄는 문제가 없어요")
                .font(.title3.weight(.semibold))
            Text("고를 컬럼이 없습니다. ‘← 컬럼 고르기’에서 이번에 손볼 컬럼을 골라 주세요.")
                .font(.body).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    // MARK: - 컬럼 목록 → 컬럼 상세

    /// 목록에 보여줄 순서 — 손볼 거리(⚠️) 있는 컬럼이 위, 그다음은 원래 컬럼 순서.
    private var orderedReviewColumns: [UnifiedColumn] {
        func rank(_ r: ColumnReview) -> Int {
            if r.kind == .derived { return 3 }
            if openCount(r) > 0 || templateGap(r).warn { return 0 }
            return isDecisionRelevant(r) ? 1 : 2
        }
        return visibleReviews.enumerated()
            .sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }
            .map { $0.element.column }
    }

    /// 목록 순서를 현재 컬럼 구성에 맞춘다. 구성이 바뀌었을 때만 다시 잡아
    /// 값을 고치는 동안 줄이 튀지 않게 한다.
    private func syncSteps() {
        let cols = orderedReviewColumns
        if Set(cols) != Set(stepOrder) { stepOrder = cols }
        if let col = openColumn, !stepOrder.contains(col) { openColumn = nil }
    }

    /// 목록 순서에서 앞뒤 컬럼으로. 끝에서 더 가면 목록으로 돌아간다.
    private func openStep(_ delta: Int) {
        guard let col = openColumn, let i = stepOrder.firstIndex(of: col) else { return }
        let j = i + delta
        withAnimation(.easeInOut(duration: 0.15)) {
            openColumn = stepOrder.indices.contains(j) ? stepOrder[j] : nil
        }
    }

    // MARK: 목록 화면

    private var columnListPage: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                columnListHeader
                ForEach(stepOrder, id: \.self) { col in
                    if let review = reviewFor(col) { columnRow(review) }
                }
                if stepOrder.isEmpty { emptyDecisionsCard }
            }
            .padding(24)
        }
    }

    private var columnListHeader: some View {
        let total = decisionReviews.count
        let done = total - openDecisions.count
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("컬럼 \(stepOrder.count)개")
                        .font(.title3.weight(.bold))
                    Text(openDecisions.isEmpty
                         ? "손볼 값이 남지 않았어요. 컬럼을 눌러 자세히 볼 수 있고, 이제 가져가도 됩니다."
                         : "컬럼을 누르면 그 컬럼만 자세히 봅니다. 손볼 거리가 있는 컬럼을 위에 모아 뒀어요.")
                        .font(.body).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                if total > 0 {
                    VStack(alignment: .trailing, spacing: 4) {
                        Text("\(done) / \(total) 해결")
                            .font(.headline).monospacedDigit()
                            .foregroundStyle(openDecisions.isEmpty ? Color.green : Color.primary)
                        ProgressView(value: Double(done), total: Double(max(total, 1)))
                            .tint(openDecisions.isEmpty ? .green : .accentColor)
                            .frame(width: 160)
                    }
                }
            }
            if !openDecisions.isEmpty, let first = stepOrder.first(where: { r in
                reviewFor(r).map { openCount($0) > 0 } ?? false
            }) {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { openColumn = first }
                } label: {
                    Label("손볼 컬럼부터 시작하기 — \(first.rawValue)", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
            }
        }
        .padding(.bottom, 6)
    }

    /// 목록의 한 줄 — 눌러서 상세로. 추천값이 있으면 여기서 바로 고칠 수도 있다.
    private func columnRow(_ review: ColumnReview) -> some View {
        let open = openCount(review)
        let gap = templateGap(review)
        let attention = open > 0 || gap.warn
        let isChecked = checked.contains(review.column)
        let auto = autoFixCount(review)
        let tint: Color = attention ? .orange : (isDecisionRelevant(review) ? .green : .secondary)
        let symbol = attention ? "exclamationmark.triangle.fill"
            : (isChecked ? "checkmark.circle.fill"
                         : (isDecisionRelevant(review) ? "checkmark.circle" : "minus.circle"))
        let badge = open > 0 ? "\(open)종 남음"
            : (gap.isNew ? "틀에 없는 컬럼"
                         : (gap.outside > 0 ? "틀에 없는 값 \(gap.outside)종" : ""))
        return HStack(spacing: 12) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { openColumn = review.column }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: symbol)
                        .font(.title3).foregroundStyle(tint)
                        .frame(width: 20)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(review.column.rawValue)
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1).truncationMode(.tail)
                        Text(subtitle(for: review))
                            .font(.body).foregroundStyle(.secondary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if auto > 0 {
                Button { applyAutoFix(review) } label: {
                    Label("추천값으로 \(auto)건", systemImage: "wand.and.stars")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("오타·유사값을 추천 형태로 한 번에 바꿉니다. 열어서 직접 확인할 수도 있어요.")
            }
            if !badge.isEmpty {
                Text(badge)
                    .font(.body.weight(.semibold)).foregroundStyle(.orange)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Capsule().fill(Color.orange.opacity(0.12)))
            }
            Image(systemName: "chevron.right")
                .font(.body.weight(.bold)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .stroke(attention ? Color.orange.opacity(0.45) : Color.primary.opacity(0.07),
                    lineWidth: attention ? 1.5 : 1))
    }

    // MARK: 컬럼 상세 화면

    private func columnDetailPage(_ review: ColumnReview) -> some View {
        let i = stepOrder.firstIndex(of: review.column)
        return VStack(spacing: 0) {
            detailNavBar(review, at: i)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    detailIntro(review)
                    reviewSection(review, alwaysExpanded: true)
                    detailFooter(review, at: i)
                }
                .padding(24)
            }
        }
    }

    private func detailNavBar(_ review: ColumnReview, at i: Int?) -> some View {
        HStack(spacing: 10) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { openColumn = nil }
            } label: {
                Label("컬럼 목록", systemImage: "chevron.left")
            }
            Divider().frame(height: 16)
            Text(review.column.rawValue)
                .font(.headline)
                .lineLimit(1).truncationMode(.tail)
                .help(review.column.rawValue)
            if let i {
                Text("\(i + 1) / \(stepOrder.count)")
                    .font(.body).monospacedDigit().foregroundStyle(.secondary)
            }
            Spacer()
            Button("← 이전 컬럼") { openStep(-1) }
                .disabled((i ?? 0) == 0)
            Button("다음 컬럼 →") { openStep(1) }
                .disabled(i == nil || i! >= stepOrder.count - 1)
        }
        .padding(.horizontal, 24).padding(.vertical, 10)
    }

    /// ‘이 컬럼은 이런 값이에요’ — 무엇을 보고 있는지 한눈에.
    private func detailIntro(_ review: ColumnReview) -> some View {
        let open = openCount(review)
        let samples = sampleValues(review)
        return VStack(alignment: .leading, spacing: 8) {
            Text("이 컬럼은 이런 값이에요")
                .font(.body.weight(.semibold))
                .foregroundStyle(Color.accentColor)
            Text(explain(review))
                .font(.body).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            templateNote(review)
            HStack(spacing: 8) {
                statChip("\(review.total)행", "tablecells")
                statChip("값 \(review.distinctCount)종", "square.stack.3d.up")
                if open > 0 {
                    statChip("손볼 값 \(open)종", "exclamationmark.triangle.fill", tint: .orange)
                } else {
                    statChip("손볼 값 없음", "checkmark.circle.fill", tint: .green)
                }
            }
            if !samples.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("지금 들어 있는 값").font(.body).foregroundStyle(.secondary)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(samples, id: \.self) { v in
                                Text(v)
                                    .font(.body)
                                    .lineLimit(1)
                                    .padding(.horizontal, 8).padding(.vertical, 4)
                                    .background(Capsule().fill(Color.primary.opacity(0.06)))
                            }
                            if review.distinctCount > samples.count {
                                Text("… 외 \(review.distinctCount - samples.count)종")
                                    .font(.body).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color.accentColor.opacity(0.06)))
    }

    /// 완성될 틀과 견준 결과 — 무엇이 어긋나는지, 어떻게 맞출지.
    @ViewBuilder
    private func templateNote(_ review: ColumnReview) -> some View {
        let gap = templateGap(review)
        if baseIsUserFile, let sheet = base, gap.isNew || gap.known > 0 {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: gap.warn ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(gap.warn ? Color.orange : Color.green)
                VStack(alignment: .leading, spacing: 6) {
                    Text(templateSentence(gap, sheet.name))
                        .font(.body)
                        .fixedSize(horizontal: false, vertical: true)
                    if gap.outside > 0 {
                        Button("틀의 값 목록으로 맞추기") { lockToBase(review.column) }
                            .controlSize(.small)
                            .help("틀에 있는 \(gap.known)종을 이 컬럼의 허용 목록으로 잡습니다. 목록 밖 값은 비슷한 값을 추천받아 골라 넣을 수 있어요.")
                    } else if gap.locked {
                        Button("틀 목록 잠금 해제") { unlockFromBase(review.column) }
                            .controlSize(.small)
                            .help("허용 목록을 풀고 값을 자유롭게 둡니다.")
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill((gap.warn ? Color.orange : Color.green).opacity(0.09)))
        }
    }

    private func templateSentence(_ gap: TemplateGap, _ name: String) -> String {
        if gap.isNew { return "틀 ‘\(name)’에는 없는 컬럼이에요. 결과 파일 맨 뒤에 새로 추가됩니다." }
        if gap.outside > 0 {
            return "틀에는 이 컬럼에 \(gap.known)종이 들어 있어요. 이번 값 중 \(gap.outside)종이 그 목록에 없습니다 — 틀에 맞추려면 아래 버튼을 누르세요."
        }
        if gap.locked { return "틀의 값 목록(\(gap.known)종)에 맞추는 중이에요. 목록 밖 값은 위에서 골라 넣으면 됩니다." }
        if gap.comparable { return "이번 값은 모두 틀에 이미 있는 값이에요. 틀 기준으로 손볼 게 없습니다." }
        return "틀에도 있는 컬럼이에요. 값이 행마다 달라서 목록으로 견주지는 않았습니다."
    }

    private func statChip(_ text: String, _ symbol: String, tint: Color = .secondary) -> some View {
        Label(text, systemImage: symbol)
            .font(.body.weight(.medium))
            .foregroundStyle(tint)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Capsule().fill(tint.opacity(0.12)))
    }

    /// 이 컬럼이 어떤 컬럼이고 무엇을 해 주는지 한 문장으로.
    private func explain(_ review: ColumnReview) -> String {
        if review.kind == .derived { return "합칠 때 자동으로 계산되는 컬럼이에요. 따로 고칠 값은 없습니다." }
        let open = openCount(review)
        let tail = open > 0
            ? " 아직 \(open)종이 손볼 값으로 남아 있어요 — 고쳐도 되고 그대로 둬도 됩니다."
            : " 지금은 손볼 값이 없어요."
        switch effectiveType(review) {
        case .format:
            let f = effectiveFormat(review)
            return "‘\(f.rawValue)’ 형식으로 맞추는 컬럼이에요. 목표 모양은 \(f.hint) 입니다." + tail
        case .category:
            return "정해진 몇 가지 값이 반복되는 컬럼이에요. 같은 뜻인데 다르게 쓴 값을 하나로 모읍니다." + tail
        case .freeText:
            return "사람마다 자유롭게 적는 값이에요. 값을 바꾸지 않고, 오타로 보이는 것만 짚어 드립니다." + tail
        }
    }

    private func sampleValues(_ review: ColumnReview, _ n: Int = 8) -> [String] {
        if !review.values.isEmpty { return review.values.prefix(n).map(\.value) }
        return Array(review.samples.prefix(n))
    }

    /// 컬럼 하나를 다 본 뒤의 마무리 — **무엇이 바뀌는지 보고 → 적용하거나 → 넘어가거나**.
    /// (‘끝내기’는 무슨 일이 일어나는지 알 수 없어서 셋으로 갈랐다.)
    private func detailFooter(_ review: ColumnReview, at i: Int?) -> some View {
        let open = openCount(review)
        let changed = columnChanges(review.column)
        return HStack(spacing: 10) {
            Button("← 이전 컬럼") { openStep(-1) }
                .disabled((i ?? 0) == 0)
            Button("목록으로") {
                withAnimation(.easeInOut(duration: 0.15)) { openColumn = nil }
            }
            Spacer()
            if open > 0 {
                Text("아직 \(open)종이 남았어요 — 그대로 둬도 됩니다")
                    .font(.body).foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Button(changed.isEmpty ? "바뀐 값 없음" : "변경사항 미리보기 (\(changed.count))") {
                changePreviewColumn = review.column
            }
            .disabled(changed.isEmpty)
            .help("이 컬럼에서 어떤 값이 무엇으로 바뀌는지 이전 값 → 새 값으로 봅니다.")
            Button("넘어가기") { openStep(1) }
                .help(changed.isEmpty
                      ? "확정 표시 없이 다음 컬럼으로 갑니다 — 나중에 다시 볼 수 있어요."
                      : "확정 표시 없이 다음으로 갑니다. 지금까지 고친 값 \(changed.count)개는 그대로 남아요.")
            Button {
                checked.insert(review.column)     // 이 컬럼은 다 봤다 = 결과에 반영
                openStep(1)
            } label: {
                Text(changed.isEmpty ? "이대로 확정 →" : "적용하기 (\(changed.count)) →")
                    .fontWeight(.semibold)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .help(changed.isEmpty
                  ? "바꿀 값이 없어요. 이 컬럼을 다 본 것으로 표시하고 다음으로 갑니다."
                  : "바뀐 값 \(changed.count)개를 결과에 반영하고 다음 컬럼으로 갑니다.")
        }
        .padding(.top, 4)
    }

    /// 이 컬럼에서 지금 실제로 바뀌는 칸들 — 완성본에 들어갈 값 기준.
    private func columnChanges(_ col: UnifiedColumn) -> [ChangeRecord] {
        preview.changes.filter { $0.column == col }
    }

    /// 컬럼 하나를 정리하는 작업 창 — 여기서 도구를 골라 이어서 손본다.
    private func cleanHubSheet(_ col: UnifiedColumn) -> some View {
        let values = ValueScanner.distinct(col, in: plans)
        return CleanColumnHubSheet(
            column: col,
            values: values,
            mapping: valueMap[col] ?? [:],
            openCount: reviewFor(col).map { openCount($0) } ?? 0,
            onMappingTable: { mappingColumn = col },
            onExample: { exampleColumn = col },
            onRegex: { regexColumn = col },
            onChanges: { changePreviewColumn = col },
            onClose: { cleanHubColumn = nil })
    }

    /// 한 컬럼의 변경 내역만 떼어 보여 주는 창.
    @ViewBuilder
    private var changePreviewSheet: some View {
        if let col = changePreviewColumn {
            ChangeLogSheet(changes: columnChanges(col),
                           onClose: { changePreviewColumn = nil })
        }
    }

    private func reviewSection(_ review: ColumnReview, alwaysExpanded: Bool = false) -> some View {
        ReviewSection(title: review.column.rawValue,
                      subtitle: subtitle(for: review),
                      isChecked: checkBinding(review.column),
                      alwaysExpanded: alwaysExpanded,
                      needsAttention: openCount(review) > 0,
                      resolveCount: autoFixCount(review),
                      onResolve: { applyAutoFix(review) },
                      typeControl: review.kind == .derived ? nil : typeControl(for: review),
                      onExpandChange: { expanded in setFocus(review.column, expanded) },
                      onDetail: { detailColumn = review.column },
                      onExample: review.kind == .derived ? nil
                        : { exampleColumn = review.column },
                      onConfigure: review.kind == .derived ? nil
                        : { configColumn = review.column },
                      onRegex: review.kind == .derived ? nil
                        : { regexColumn = review.column },
                      onMapping: review.kind == .derived ? nil
                        : { mappingColumn = review.column }) {
            body(for: review)
        }
    }

    /// 검토 카드 헤더에 들어가는 컬럼 타입 선택 메뉴 (자유입력/범주/포맷).
    /// 포맷을 고르면 하위 메뉴에서 형식(전화번호/이메일/생년월일/직접)을 정한다.
    private func typeControl(for review: ColumnReview) -> AnyView {
        let type = effectiveType(review)
        let isAuto = typeOverride[review.column] == nil
        let tint = Self.typeColor(type)
        return AnyView(
            Menu {
                Section("이 컬럼의 타입") {
                    ForEach(ColumnType.allCases) { t in
                        Button {
                            setType(t, for: review)
                        } label: {
                            Label(t.rawValue + (t == autoType(review) ? " (자동)" : ""),
                                  systemImage: t == type ? "checkmark" : t.symbol)
                        }
                    }
                }
                if type == .format {
                    // 프리셋이 많아져 갈래별로 묶는다 — ‘연락처 > 이메일’처럼 찾게.
                    ForEach(FormatPreset.Group.allCases) { g in
                        Section(g.rawValue) {
                            ForEach(g.members) { p in
                                Button {
                                    setFormat(p, for: review.column)
                                } label: {
                                    Label("\(p.rawValue)  \(p.hint)",
                                          systemImage: p == effectiveFormat(review) ? "checkmark" : "circle")
                                }
                            }
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: type.symbol)
                    // 포맷이면 목표 예시까지 뱃지에 — 카드를 펴기 전에 보이도록.
                    Text(type == .format
                         ? "포맷 · \(effectiveFormat(review).rawValue) \(effectiveFormat(review).hint)"
                         : type.rawValue)
                    if isAuto {
                        Text("자동").font(.body)
                            .foregroundStyle(tint.opacity(0.9))
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Capsule().fill(tint.opacity(0.16)))
                    }
                }
                .font(.body.weight(.medium))
                .foregroundStyle(tint)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(Capsule().fill(tint.opacity(0.12)))
                .overlay(Capsule().stroke(tint.opacity(0.35), lineWidth: 1))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help(type.help)
        )
    }

    /// 컬럼 타입별 색: 자유 입력=회색(그대로), 범주=파랑(선택지), 포맷=보라(형식).
    static func typeColor(_ type: ColumnType) -> Color {
        switch type {
        case .freeText: return .gray
        case .category: return .blue
        case .format:   return .purple
        }
    }

    private var reviewToolbar: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(isPatching ? "검토 — 이번에 정제할 컬럼" : "검토")
                    .font(.title2.weight(.bold))
                Text(reviewSubtitle)
                    .font(.body).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if let errorMessage { errorLabel(errorMessage).frame(maxWidth: 300) }
            Button(isUtility ? "← 컬럼 고르기" : "← 컬럼 고르기") {
                stage = isUtility ? .work : (isPatching ? .focus : .columns)
            }
            Button {
                openPreviewWindow()
            } label: {
                Label("완성본 미리보기", systemImage: "macwindow.badge.plus")
            }
            .help("합쳐진 파일의 현재 상태를 별도 윈도우로 봅니다. 정리할수록 개선된 셀이 표시됩니다.")
            Button(action: runMerge) {
                HStack {
                    if isRunning { ProgressView().controlSize(.small) }
                    Text(isRunning ? (isPatching ? "정리하는 중…" : "합치는 중…")
                                   : mergeButtonTitle)
                        .fontWeight(.semibold)
                }
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .disabled(isRunning)
            .help(openDecisions.isEmpty
                  ? (isPatching ? "고른 컬럼의 값만 원본에 덮어씁니다. 나머지 컬럼은 그대로예요."
                                : "병합을 시작합니다")
                  : "아직 정리 안 한 값이 \(openDecisions.count)종 남아 있지만, 지금 가져가도 됩니다. 남은 값은 원본 그대로 나갑니다.")
        }
        .padding(20)
    }

    /// 가져가기 버튼 문구 — 유틸은 ‘고친 값 가져가기’, 통합은 ‘합치기’.
    private var mergeButtonTitle: String {
        if isUtility { return "고친 값 가져가기" }
        return isPatching ? "이 컬럼만 원본에 반영" : "이대로 합치기"
    }

    /// 검토 화면 부제 — 어느 파일에 반영되는지, 아직 남은 게 몇 종인지.
    /// 남아 있어도 막지 않는다. 알려 주기만 한다.
    private var reviewSubtitle: String {
        let state = openDecisions.isEmpty
            ? "정리할 값 없음 — 언제든 가져갈 수 있어요"
            : "아직 정리 안 한 값 \(openDecisions.count)종 (그대로 둬도 됩니다)"
        if isPatching, let base {
            return "‘\(base.name)’의 컬럼 \(visibleFinalColumns.count)개 · \(state)"
                + " — 고르지 않은 컬럼은 원본 그대로 나갑니다."
        }
        return "\(visibleFinalColumns.count)개 컬럼 · \(state)"
    }

    // MARK: - Per-column review body

    @ViewBuilder
    private func body(for review: ColumnReview) -> some View {
        if review.kind == .derived {
            VStack(alignment: .leading, spacing: 10) {
                NoteBody(note: review.note)
                if review.column == .code { keyPatternEditor }
            }
        } else {
            switch effectiveType(review) {
            case .category:
                ValueUnifyBody(values: review.values,
                               mapping: bindingForColumn(review.column),
                               allowed: allowedValues[review.column] ?? [],
                               onAuto: { autoUnify(review.column, values: review.values) })
            case .freeText:
                FreeTextBody(note: review.note,
                             samples: review.samples,
                             distinctCount: review.distinctCount,
                             anomalies: review.anomalies,
                             mapping: bindingForColumn(review.column))
            case .format:
                formatBody(for: review)
            }
        }
    }

    /// 포맷 타입의 본문. 전화/생년월일은 기존 전용 제안 화면을, 이메일·직접
    /// 정규식은 형식에 안 맞는 값만 모아 고치는 일반 검증 화면을 쓴다.
    @ViewBuilder
    private func formatBody(for review: ColumnReview) -> some View {
        if usesProposalUI(review) {
            if review.kind == .phone {
                ProposalsBody(note: review.note,
                              proposals: review.proposals,
                              targetLabel: phoneTemplate,
                              mapping: bindingForColumn(review.column),
                              phoneTemplate: $phoneTemplate)
            } else {
                ProposalsBody(note: review.note,
                              proposals: review.proposals,
                              targetLabel: "yyyy-MM-dd",
                              mapping: bindingForColumn(review.column))
            }
        } else {
            FormatBody(values: review.values,
                       preset: effectiveFormat(review),
                       presetPattern: effectivePattern(review),
                       customPattern: Binding(
                           get: { customFormat[review.column] ?? "" },
                           set: { customFormat[review.column] = $0 }),
                       mapping: bindingForColumn(review.column))
        }
    }

    private func subtitle(for review: ColumnReview) -> String {
        if review.kind == .derived { return "자동 생성 컬럼" }
        let map = valueMap[review.column] ?? [:]
        let base: String
        switch effectiveType(review) {
        case .category:
            base = "범주 · \(review.distinctCount)종 값 · \(review.total)행"
        case .freeText:
            base = "자유 입력 · \(review.distinctCount)종 값 · \(review.total)행"
                + (review.anomalies.isEmpty ? "" : " · ⚠︎ 오타 의심 \(review.anomalies.count)건")
        case .format:
            if review.kind == .phone && usesProposalUI(review) {
                base = review.flaggedCount > 0
                    ? "포맷(전화번호) · 표준(010-) 아님 \(review.flaggedCount)종"
                    : "포맷(전화번호) · 모두 표준 형식"
            } else if review.kind == .date && usesProposalUI(review) {
                base = review.flaggedCount > 0
                    ? "포맷(생년월일) · 인식 못함 \(review.flaggedCount)종"
                    : "포맷(생년월일) · 모두 인식됨"
            } else {
                let bad = formatFailures(review).count
                base = "포맷(\(effectiveFormat(review).rawValue)) · "
                    + (bad == 0 ? "모두 형식 맞음" : "형식 안 맞음 \(bad)종")
            }
        }
        let composite = plans.filter { ($0.sources[review.column]?.count ?? 0) > 1 }.count
        // 합치기 전에 이 컬럼에서 바뀔 값 종 수를 미리 보여줘 신뢰를 줍니다.
        let edits = map.filter { $0.key != $0.value }.count
        // 결정거리가 있는 컬럼엔 맨 앞에 상태 뱃지(⚠️ 결정 필요 / ✅ 해결됨)를 붙인다.
        var line = base
        if isDecisionRelevant(review) {
            let open = openCount(review)
            let badge = open > 0 ? "⚠️ 결정 필요 \(open)종 · "
                                 : (checked.contains(review.column) ? "✅ 확정 · " : "✅ 해결됨 · ")
            line = badge + base
        }
        if edits > 0 { line += " · ✏️ 수정 예정 \(edits)종" }
        if composite > 0 { line += " · \(composite)개 파일에서 컬럼 조합" }
        // 매핑표가 적용된 컬럼: 허용 목록 밖 값이 남아 있으면 경고를 노출.
        if let allowed = allowedValues[review.column], !allowed.isEmpty {
            let out = review.values.filter {
                !allowed.contains(valueMap[review.column]?[$0.value] ?? $0.value)
            }.count
            line += out == 0 ? " · 🔒 정해둔 값으로 고정" : " · ⚠️ 정해둔 값 밖 \(out)종"
        }
        return line
    }

    // MARK: - Stage 3: result (full width)

    @ViewBuilder
    private var resultStage: some View {
        if let patch, let base {
            patchResultStage(patch, base: base)
        } else if let result {
            VStack(spacing: 0) {
                HStack(alignment: .top) {
                    summaryHeader(result)
                    Spacer()
                    VStack(alignment: .trailing, spacing: 10) {
                        HStack {
                            Button("← 검토로") { stage = .review }
                            if !result.changes.isEmpty {
                                Button(action: exportChangeReport) {
                                    Label("변경 보고서…", systemImage: "doc.text.magnifyingglass")
                                }
                                .help("이 도구가 수정한 모든 셀(이전 값 → 이후 값)을 출처 키와 함께 CSV로 내보냅니다. 원본과 대조해 100% 검증할 수 있어요.")
                            }
                            Button(action: exportResult) {
                                Label("내보내기…", systemImage: "square.and.arrow.up")
                            }
                            .buttonStyle(.borderedProminent)
                        }
                        Toggle("중복 삭제 행 제외하고 내보내기", isOn: $excludeRemoved)
                            .toggleStyle(.checkbox)
                            .font(.body)
                        if let errorMessage { errorLabel(errorMessage).frame(maxWidth: 280) }
                    }
                }
                .padding(20)
                Divider()
                previewTable(result).padding(20)
            }
        } else {
            Color.clear.onAppear { stage = .review }
        }
    }

    // MARK: - Stage 3b: 기존본에 이어붙인 결과

    private func patchResultStage(_ patch: PatchResult, base: BaseSheet) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                patchSummary(patch, base: base)
                Spacer()
                VStack(alignment: .trailing, spacing: 10) {
                    HStack {
                        Button("← 검토로") { stage = .review }
                        if !patch.changes.isEmpty {
                            Button(action: exportPatchChangeReport) {
                                Label("변경 보고서…", systemImage: "doc.text.magnifyingglass")
                            }
                            .help("기존본의 어느 셀이 무엇에서 무엇으로 바뀌었는지 전부 CSV로 내보냅니다.")
                        }
                        Button(action: exportPatch) {
                            Label(isUtility ? "정리된 파일 저장…" : "업데이트된 파일 내보내기…",
                                  systemImage: "square.and.arrow.up")
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    // 유틸 모드는 같은 파일을 제자리에서 고치므로 새 행이 생길 일이 없다.
                    if !isUtility {
                        Toggle("기존본에 없던 사람 맨 아래에 추가", isOn: $appendNewRows)
                            .toggleStyle(.checkbox).font(.body)
                        Toggle("추가한 행에 ‘\(PatchEngine.markerValue)’ 표시 컬럼 넣기", isOn: $markNewRows)
                            .toggleStyle(.checkbox).font(.body)
                            .disabled(!appendNewRows)
                    }
                    if let errorMessage { errorLabel(errorMessage).frame(maxWidth: 300) }
                }
            }
            .padding(20)
            .onChange(of: appendNewRows) { _ in recomputePatch() }
            .onChange(of: markNewRows) { _ in recomputePatch() }
            Divider()
            patchTable(patch, base: base).padding(20)
        }
    }

    private func patchSummary(_ patch: PatchResult, base: BaseSheet) -> some View {
        let changedRows = patch.changedCells.count
        let untouched = max(base.headers.count - patch.columns.count, 0)
        return VStack(alignment: .leading, spacing: 12) {
            Text(isUtility ? "‘\(base.name)’ 정리했어요" : "‘\(base.name)’에 반영했어요")
                .font(.title3.weight(.bold))
                .lineLimit(1).truncationMode(.middle)
            HStack(spacing: 14) {
                Stat(label: "전체 행", value: "\(base.rows.count)")
                if isUtility {
                    Stat(label: "값이 바뀐 행", value: "\(changedRows)")
                } else {
                    Stat(label: "값 반영", value: "\(patch.matchedRows)")
                    Stat(label: "새로 추가", value: "\(patch.appendedRows)")
                }
                Stat(label: "바뀐 셀", value: "\(patch.changedCellCount)")
            }
            Text("이번에 정리한 컬럼: "
                 + (patch.columns.isEmpty ? "없음"
                    : patch.columns.map { $0.rawValue }.joined(separator: ", ")))
                .font(.body).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if !patch.addedColumns.isEmpty {
                Label("원본에 없어 새로 만든 컬럼 \(patch.addedColumns.count)개: "
                      + patch.addedColumns.map { $0.rawValue }.joined(separator: ", "),
                      systemImage: "plus.square.on.square")
                    .font(.body).foregroundStyle(Color.accentColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if patch.unmatchedRows > 0 {
                Label("이번 데이터에서 짝을 못 찾은 기존 행 \(patch.unmatchedRows)건 — 손대지 않고 그대로 뒀어요.",
                      systemImage: "questionmark.circle")
                    .font(.body).foregroundStyle(.secondary)
            }
            if patch.keptBlankCount > 0 {
                Label("새 값이 비어 있어 기존 값을 지킨 셀 \(patch.keptBlankCount)건 — 값이 지워지는 일은 없습니다.",
                      systemImage: "lock.shield")
                    .font(.body).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Label(patch.changedCellCount == 0
                  ? "바뀐 값 0건 — 원본이 그대로 유지됩니다."
                  : "고르지 않은 컬럼 \(untouched)개와 모든 행은 한 글자도 건드리지 않았습니다.",
                  systemImage: patch.changedCellCount == 0 ? "checkmark.seal.fill" : "checkmark.shield.fill")
                .font(.body.weight(.medium))
                .foregroundStyle(patch.changedCellCount == 0 ? Color.green : Color.accentColor)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// 결과 표: 사람을 알아볼 컬럼 몇 개 + 이번에 반영한 컬럼.
    /// 바뀐 셀은 파란 굵은 글씨, 새로 붙인 행은 초록 배경.
    private func patchTable(_ patch: PatchResult, base: BaseSheet) -> some View {
        var headers: [String] = []
        for col in [UnifiedColumn.code, .koreanName, .email] {
            if let h = base.columnHeader[col], !headers.contains(h) { headers.append(h) }
        }
        let idHeaders = headers
        for col in patch.columns {
            let h = base.columnHeader[col] ?? col.rawValue
            if !headers.contains(h) { headers.append(h) }
        }
        let shown = Array(patch.rows.enumerated().prefix(300))
        return ScrollView([.vertical, .horizontal]) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 0) {
                    ForEach(headers, id: \.self) { h in
                        Text(h)
                            .font(.body.weight(.semibold))
                            .lineLimit(1).truncationMode(.tail).help(h)
                            .frame(width: idHeaders.contains(h) ? 150 : 180, alignment: .leading)
                            .padding(.horizontal, 8).padding(.vertical, 6)
                            .foregroundStyle(idHeaders.contains(h) ? Color.secondary : Color.accentColor)
                    }
                }
                .background(Color(nsColor: .underPageBackgroundColor))

                ForEach(shown, id: \.offset) { item in
                    let changed = patch.changedCells[item.offset] ?? []
                    let isNew = patch.newRowIndices.contains(item.offset)
                    HStack(spacing: 0) {
                        ForEach(headers, id: \.self) { h in
                            let hit = changed.contains(h)
                            Text(item.element[h] ?? "")
                                .font(hit ? .caption.weight(.bold) : .caption)
                                .foregroundStyle(hit ? Color.accentColor : Color.primary)
                                .lineLimit(1).truncationMode(.tail)
                                .frame(width: idHeaders.contains(h) ? 150 : 180, alignment: .leading)
                                .padding(.horizontal, 8).padding(.vertical, 5)
                        }
                    }
                    .background(isNew ? Color.green.opacity(0.10)
                                      : (changed.isEmpty ? Color.clear : Color.accentColor.opacity(0.05)))
                    Divider()
                }
            }
        }
        .overlay(alignment: .bottomLeading) {
            HStack(spacing: 14) {
                Label("파란 굵은 글씨 = 이번에 바뀐 셀", systemImage: "pencil")
                Label("초록 행 = 새로 추가된 사람", systemImage: "plus.circle")
                if patch.rows.count > 300 {
                    Text("(앞 300행만 표시 · 전체 \(patch.rows.count)행)")
                }
            }
            .font(.body).foregroundStyle(.secondary)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(.regularMaterial, in: Capsule())
            .padding(8)
        }
    }

    private func summaryHeader(_ r: MergeResult) -> some View {
        let total = r.rows.count
        let active = r.rows.filter { $0[.dupFlag] != "중복 - 삭제" }.count
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                Stat(label: "전체 행", value: "\(total)")
                Stat(label: "중복 제거 후", value: "\(active)")
                Stat(label: "중복", value: "\(r.removeCount)")
            }
            HStack(spacing: 14) {
                ForEach(Channel.allCases, id: \.self) { ch in
                    if let n = r.counts[ch] {
                        Stat(label: ch.rawValue, value: "\(n)", small: true)
                    }
                }
            }
            if r.unmatchedNoPhone > 0 {
                Text("전화번호·이메일이 모두 없어 중복 검사에서 제외된 행 \(r.unmatchedNoPhone)건.")
                    .font(.body).foregroundStyle(.secondary)
            }
            // 검증 요약: 이 도구가 수정한 셀의 전체 개수. 보고서와 1:1로 대조 가능.
            Label(r.changes.isEmpty
                  ? "값 수정 0건 — 모든 값이 원본 그대로 저장되었습니다."
                  : "값 수정 \(r.changes.count)건 — 전체 내역이 변경 보고서에 기록되어 있습니다.",
                  systemImage: r.changes.isEmpty ? "checkmark.seal.fill" : "doc.text.magnifyingglass")
                .font(.body.weight(.medium))
                .foregroundStyle(r.changes.isEmpty ? Color.green : Color.accentColor)
        }
    }

    private func previewTable(_ r: MergeResult) -> some View {
        let cols: [UnifiedColumn] = [.channel, .dupFlag, .koreanName, .phoneClean, .email, .dobClean]
        return ScrollView([.vertical, .horizontal]) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 0) {
                    ForEach(cols, id: \.self) { c in
                        Text(c.rawValue)
                            .font(.body.weight(.semibold))
                            .frame(width: columnWidth(c), alignment: .leading)
                            .padding(.horizontal, 8).padding(.vertical, 6)
                    }
                }
                .background(Color(nsColor: .underPageBackgroundColor))

                ForEach(Array(r.rows.prefix(300))) { row in
                    HStack(spacing: 0) {
                        ForEach(cols, id: \.self) { c in
                            Text(row[c])
                                .font(.body)
                                .lineLimit(1).truncationMode(.tail)
                                .frame(width: columnWidth(c), alignment: .leading)
                                .padding(.horizontal, 8).padding(.vertical, 5)
                                .foregroundStyle(row[.dupFlag] == "중복 - 삭제" ? .secondary : .primary)
                        }
                    }
                    .background(rowTint(row))
                    Divider()
                }
            }
        }
    }

    private func columnWidth(_ c: UnifiedColumn) -> CGFloat {
        switch c {
        case .channel: return 120
        case .dupFlag: return 90
        case .koreanName: return 110
        case .phoneClean: return 130
        case .email: return 220
        case .dobClean: return 110
        default: return 120
        }
    }

    private func rowTint(_ row: ApplicantRow) -> Color {
        switch row[.dupFlag] {
        case "중복 - 삭제": return Color.red.opacity(0.06)
        case "중복 -Keep": return Color.green.opacity(0.06)
        default: return .clear
        }
    }

    private func errorLabel(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.body).foregroundStyle(.red)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Actions

    private func addFiles() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.commaSeparatedText, .text, xlsxType]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        let existing = Set(inputs.map { $0.url })
        for url in panel.urls where !existing.contains(url) {
            inputs.append(MergeInput(url: url, channel: Channel.detect(url: url)))
        }
    }

    private func remove(_ input: MergeInput) {
        inputs.removeAll { $0.id == input.id }
    }

    /// 여러 파일 합치기 화면에서 유틸 화면으로 되돌아간다.
    private func backToWork() {
        errorMessage = nil
        stage = .work
    }

    /// 이전 완성본을 참조 파일로 불러와, 그 헤더로 남길 컬럼을 맞춘다.
    /// 완성본의 헤더는 최종 스키마 컬럼명과 같으므로 이름으로 대응시킨다.
    /// 갈림길에서 ‘틀 있음’을 골랐을 때: 완성본을 불러오고, 성공하면 그 틀
    /// 구성이 곧 최종본이므로 컬럼 선택을 건너뛰고 바로 값 검토로 넘어간다.
    private func chooseTemplate() {
        guard loadReference() else { return }   // 취소·오류면 갈림길에 머무름
        base = nil                              // 값 기준선 없이 틀만 쓰는 흐름
        patch = nil
        focusColumns = []
        columnMode = .withTemplate
        proceedToReview()
    }

    /// 갈림길에서 파일 단계로 되돌아갈 때 선택 상태를 초기화한다.
    private func backToFiles() {
        stage = .files
        columnMode = nil
    }

    // MARK: - 유틸 모드 동작

    private func pickWorkFiles() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.commaSeparatedText, .text, xlsxType]
        panel.allowsMultipleSelection = true
        panel.message = "합칠 파일을 모두 고르세요. 같은 이름의 컬럼끼리 맞춰 이어 붙입니다."
        guard panel.runModal() == .OK else { return }
        addWorkFiles(panel.urls)
    }

    private func acceptDroppedFiles(_ providers: [NSItemProvider]) -> Bool {
        guard !providers.isEmpty else { return false }
        let group = DispatchGroup()
        var urls: [URL] = []
        let lock = NSLock()
        for provider in providers {
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
                defer { group.leave() }
                guard let data = item as? Data,
                      let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                lock.lock(); urls.append(url); lock.unlock()
            }
        }
        group.notify(queue: .main) {
            // 떨어뜨린 순서는 보장되지 않으므로 이름순으로 정렬해 결과가 매번 같게 한다.
            addWorkFiles(urls.sorted { $0.lastPathComponent < $1.lastPathComponent })
        }
        return true
    }

    /// 파일들을 유틸 모드로 더한다. 이미 있는 파일은 건너뛴다.
    /// 올린 파일들이 곧 결과물의 기준선이라, 고친 컬럼만 제자리에 덮어써 돌려줄 수 있다.
    private func addWorkFiles(_ urls: [URL]) {
        guard !urls.isEmpty, !isLoadingFiles else { return }
        let keep = isUtility ? plans : []
        let existing = Set(keep.map { $0.url })
        let todo = urls.filter { !existing.contains($0) }
        guard !todo.isEmpty else { return }

        // 파일 읽기는 백그라운드에서 — 큰 xlsx는 몇 초 걸린다.
        isLoadingFiles = true
        errorMessage = nil
        loadingNote = "파일 읽는 중… (0/\(todo.count))"
        DispatchQueue.global(qos: .userInitiated).async {
            var built = keep
            var failure: String?
            for (i, url) in todo.enumerated() {
                let note = "‘\(url.lastPathComponent)’ 읽는 중… (\(i + 1)/\(todo.count))"
                DispatchQueue.main.async { loadingNote = note }
                do { built.append(try PlanBuilder.passthrough(url: url)) }
                catch {
                    failure = "\(url.lastPathComponent): \(error.localizedDescription)"
                    break
                }
            }
            let result = built
            let error = failure
            DispatchQueue.main.async {
                guard error == nil else {
                    errorMessage = error
                    isLoadingFiles = false
                    return
                }
                guard !result.isEmpty else {
                    isLoadingFiles = false
                    return
                }
                // 컬럼 맞추기·미리보기 만들기는 상태를 건드려야 해서 메인에서 —
                // 화면에 진행 표시를 먼저 그린 뒤 한 박자 늦게 시작한다.
                loadingNote = "컬럼 맞추고 미리보기 만드는 중…"
                DispatchQueue.main.async {
                    adoptWorkPlans(result)
                    isLoadingFiles = false
                }
            }
        }
    }

    private func removeWorkFile(_ plan: FilePlan) {
        let rest = plans.filter { $0.id != plan.id }
        if rest.isEmpty {
            resetWork()
        } else {
            adoptWorkPlans(rest)
        }
    }

    /// 올린 파일 목록이 바뀔 때마다 컬럼·검토·기준선을 다시 계산한다.
    private func adoptWorkPlans(_ built: [FilePlan]) {
        plans = built
        inputs = built.map { MergeInput(url: $0.url, channel: $0.channel) }
        columnMode = .patchBase
        patch = nil
        result = nil
        if !baseIsUserFile {
            base = BaseSheet.stacked(built, name: stackedName(built),
                                     template: templateColumns, key: keyColumn,
                                 keyPattern: keyPattern, identity: identityColumns,
                                 excluding: deletedSourceIDs.union(filteredOutSourceIDs))
        }
        finalColumns = (!baseIsUserFile ? base?.columns : nil)
            ?? ColumnReviewBuilder.plainColumns(in: built)
        reviews = ColumnReviewBuilder.plainReviews(in: built)
        rebuildRowCache()
        checked = []
        valueMap = [:]
        allowedValues = [:]
        typeOverride = [:]
        formatChoice = [:]
        customFormat = [:]
        seedValueMap(from: reviews)
        // 기본은 아무것도 안 고른 상태 — 제안 카드에서 하나씩 고르게 한다.
        // (여러 개를 한 번에 하고 싶으면 목록을 펴서 직접 고르면 된다.)
        focusColumns = []
        showSettledColumns = false
        showAllColumns = false
        proposalIndex = 0
        mergeDone = []
        refreshMatches()
        // 틀이 있으면, 채울 수 있는 컬럼은 묻지 않고 바로 채운다.
        if !templateColumns.isEmpty { autoMatchTemplateColumns() }
        if !keyColumnChosen { keyPatternText = "AUTO-0001" }   // 유틸 흐름 기본
        // 키는 자동으로 골라 두고, 합치기 단계에서 확인만 받는다.
        if !keyColumnChosen, plans.count > 1, let auto = autoKeyColumn() {
            keyColumn = auto
            base = BaseSheet.stacked(plans, name: stackedName(plans),
                                     template: templateColumns, key: auto,
                                     keyPattern: keyPattern, identity: identityColumns,
                                 excluding: deletedSourceIDs.union(filteredOutSourceIDs))
            finalColumns = base?.columns ?? finalColumns
        }
        includedColumns = focusColumns
        preview.reset()
        refreshPreview()      // 첫 화면 카드가 곧 완성본이라 미리 만들어 둔다
        stage = .work
    }

    private func stackedName(_ built: [FilePlan]) -> String {
        built.count == 1 ? built[0].fileName : "합친 파일 \(built.count)개"
    }

    private func resetWork() {
        plans = []; inputs = []; reviews = []; finalColumns = []
        focusColumns = []; includedColumns = []; checked = []
        showSettledColumns = false
        stepOrder = []; openColumn = nil
        valueMap = [:]; allowedValues = [:]
        base = nil; baseIsUserFile = false; patch = nil; result = nil
        preview.reset()
        errorMessage = nil
        stage = .work
    }

    private func clearUserBase() {
        baseIsUserFile = false
        matchColumn = nil
        baseValues = [:]
        baseCategorical = []
        matchSuggestions = []
        matchSamples = [:]
        base = plans.isEmpty ? nil : BaseSheet.stacked(plans, name: stackedName(plans))
        patch = nil
    }

    /// 고른 컬럼만 검토 대상으로 잡고 값 검토로.
    private func startWork() {
        includedColumns = focusColumns
        checked = []
        stepOrder = orderedReviewColumns
        // 한 컬럼만 골랐으면 목록을 거치지 않고 바로 그 컬럼을 편다.
        openColumn = focusColumns.count == 1 ? focusColumns.first : nil
        stage = .review
        preview.reset()
        openPreviewWindow()
    }

    /// 지금 결정 상태로 만들어진 행들.
    /// 유틸 모드는 올린 순서대로 이어 붙여 값만 적용하고, 아카데미 모드는 병합 엔진을 돌린다.
    private func currentRows() -> (rows: [ApplicantRow], generatedCodes: Set<String>,
                                   changes: [ChangeRecord], origins: [Int]) {
        if isUtility {
            let r = ValueApplier.run(plans: plans, valueMap: valueMap)
            // 유틸은 올린 순서 그대로 이어 붙이므로 파일별 행 수로 출처를 만든다.
            var origins: [Int] = []
            for (i, p) in plans.enumerated() {
                origins += Array(repeating: i, count: p.rows.count)
            }
            return (r.rows, [], r.changes, origins.count == r.rows.count ? origins : [])
        }
        let r = try? MergeEngine(plans: plans, valueMap: valueMap,
                                 codePattern: keyPattern,
                                 phoneTemplate: phoneTemplate).run()
        return (r?.rows ?? [], r?.generatedCodes ?? [], r?.changes ?? [], r?.origins ?? [])
    }

    /// 올린 파일을 그대로 합치는 중이면 행 순서로, 따로 불러온 통합본에
    /// 이어붙이는 중이면 Code→전화→이메일 키로 짝짓는다.
    private var rowMatch: RowMatch {
        // 올린 파일을 그대로 쌓은 기준선은 행이 1:1로 대응한다 — 위치로 짝짓는다.
        // (키로 짝지으면 같은 키를 가진 둘째 행이 짝을 못 찾아 ‘새 행’으로 붙어 버린다.)
        if !baseIsUserFile { return .position }
        if let matchColumn { return .column(matchColumn) }
        return .key
    }

    /// 짝짓기 기준으로 고를 수 있는 컬럼 — 기준 파일과 이번 데이터에 모두 있는 것.
    private var matchColumnChoices: [UnifiedColumn] {
        guard let base else { return [] }
        let mine = Set(finalColumns)
        return base.columns.filter { mine.contains($0) }
    }

    /// 기준 파일을 불러왔을 때 짝짓기 기준을 자동으로 고른다.
    /// Code·전화·이메일이 있으면 그걸 쓰고(자동), 없으면 값이 겹치지 않는 컬럼 중 첫째.
    private func autoMatchColumn(for sheet: BaseSheet) -> UnifiedColumn? {
        let mine = Set(finalColumns)
        for c in [UnifiedColumn.code, .phone, .email]
        where sheet.columnHeader[c] != nil && mine.contains(c) { return nil }   // nil = 자동(키)
        // 값이 행마다 고유한 컬럼이 곧 식별자다 (사번·주문번호·학번 …).
        return sheet.columns.first { col in
            guard mine.contains(col) else { return false }
            var seen = Set<String>()
            var filled = 0
            for row in sheet.rows {
                let v = sheet.value(col, in: row)
                if v.isEmpty { continue }
                filled += 1
                if !seen.insert(v.lowercased()).inserted { return false }
            }
            return filled == sheet.rows.count
        }
    }

    /// 지금 ‘기존 통합본에 이어붙이는’ 모드인가.
    private var isPatching: Bool { base != nil && columnMode == .patchBase }

    /// 만들던 통합본을 값까지 통째로 불러온다. 이 파일이 결과물의 기준선이 되고,
    /// 고른 컬럼의 값만 여기에 덮어써진다 (행은 Code→전화→이메일로 짝지음).
    private func chooseBase() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.commaSeparatedText, .text, xlsxType]
        panel.allowsMultipleSelection = false
        panel.message = "이어서 채울 통합본(만들던 파일)을 고르세요. 이번에 고친 컬럼만 이 파일에 덮어씁니다."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        loadBase(url)
    }

    /// 틀 칸에 파일을 끌어다 놓았을 때 — 합칠 파일이 아니라 ‘틀’(컬럼 이름)로 받는다.
    private func acceptBaseDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
            guard let data = item as? Data,
                  let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
            DispatchQueue.main.async { loadTemplateColumns(url) }
        }
        return true
    }

    /// 틀 파일 고르기 — 컬럼 이름만 가져온다.
    private func chooseTemplateColumns() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.commaSeparatedText, .text, xlsxType]
        panel.allowsMultipleSelection = false
        panel.message = "결과물의 컬럼 구성으로 삼을 파일을 고르세요. 이 파일에서는 컬럼 이름만 가져옵니다."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        loadTemplateColumns(url)
    }

    private func clearTemplateColumns() {
        templateName = nil
        templateColumns = []
        templateValues = [:]
        autoMatched = []
        undoPlans = nil
        rebuildWorkColumns()
    }

    /// 만들던 통합본·양식을 ‘틀’로 삼는다. 합칠 파일 목록은 건드리지 않는다.
    /// 틀에서 **컬럼 이름만** 가져온다 — 그 파일의 값은 한 줄도 들어오지 않는다.
    /// 결과물은 올린 파일들을 세로로 쌓은 것이고, 컬럼 구성만 이 파일을 따른다.
    private func loadTemplateColumns(_ url: URL) {
        do {
            let sheet = try BaseSheetLoader.load(url: url)
            errorMessage = nil
            templateName = sheet.name
            templateColumns = sheet.columns
            templateValues = Dictionary(uniqueKeysWithValues:
                sheet.columns.map { ($0, sheet.distinctValues($0)) })
            // 값을 가져오는 흐름(이어붙이기)과 섞이지 않게 정리한다.
            baseIsUserFile = false
            baseValues = [:]
            baseCategorical = []
            matchColumn = nil
            patch = nil
            result = nil
            clearReference()
            // 결과물 만드는 방식은 그대로(올린 파일을 쌓은 기준선). 컬럼 순서만 이 파일을 따른다.
            columnMode = .patchBase
            rebuildWorkColumns()
            autoMatchTemplateColumns()   // 채울 수 있는 컬럼은 바로 채운다
            stage = .work
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// 어느 칸에서도 쓰이지 않고 제 이름으로도 매핑돼 있지 않은 헤더를 치운다.
    /// 컬럼을 옮길 때 **파일 헤더의 앞뒤 공백** 때문에 지워지지 않고 남던 껍데기다 —
    /// 값이 하나도 없어서, 거기에 값 정리를 해 봐야 아무 일도 일어나지 않는다.
    /// 그 껍데기에 해 둔 정리 규칙은 지금 그 값을 들고 있는 칸으로 옮겨 준다.
    private func pruneGhostHeaders() {
        for i in plans.indices {
            var used: [String: UnifiedColumn] = [:]      // 원본 헤더 → 그걸 쓰는 칸
            for (col, srcs) in plans[i].sources {
                for h in srcs where used[h] == nil { used[h] = col }
            }
            // 껍데기 = 목록엔 있는데 **제 이름으로는 아무 값도 읽지 않는** 헤더.
            // (그 값을 다른 칸이 가져갔더라도, 이 이름의 컬럼 자체는 빈 껍데기다.)
            let ghosts = plans[i].headers.filter { h in
                guard let col = UnifiedColumn(rawValue: h) else { return true }
                return plans[i].sources[col] == nil
            }
            guard !ghosts.isEmpty else { continue }
            for h in ghosts {
                if let col = UnifiedColumn(rawValue: h),
                   let rules = valueMap.removeValue(forKey: col), !rules.isEmpty,
                   let owner = used[h] {          // 지금 그 값을 들고 있는 칸
                    valueMap[owner] = (valueMap[owner] ?? [:]).merging(rules) { _, new in new }
                    if let a = allowedValues.removeValue(forKey: col), allowedValues[owner] == nil {
                        allowedValues[owner] = a
                    }
                }
            }
            plans[i].headers.removeAll { ghosts.contains($0) }
        }
    }

    /// 틀의 컬럼 순서를 반영해 컬럼 목록과 기준선을 다시 만든다.
    private func rebuildWorkColumns() {
        pruneGhostHeaders()
        guard !plans.isEmpty else {
            base = nil
            finalColumns = []
            return
        }
        base = BaseSheet.stacked(plans, name: stackedName(plans),
                                 template: templateColumns, key: keyColumn,
                                 keyPattern: keyPattern, identity: identityColumns,
                                 excluding: deletedSourceIDs.union(filteredOutSourceIDs))
        finalColumns = base?.columns ?? ColumnReviewBuilder.plainColumns(in: plans)
        reviews = ColumnReviewBuilder.plainReviews(in: plans)
        seedValueMap(from: reviews)
        rebuildRowCache()
        verifyRowCount("컬럼·행 구성을 바꾼")
        focusColumns = focusColumns.intersection(Set(finalColumns))
        includedColumns = focusColumns
        proposalIndex = 0
        refreshMatches()
        refreshPreview()
    }

    private func loadBase(_ url: URL) {
        do {
            let sheet = try BaseSheetLoader.load(url: url)
            errorMessage = nil
            base = sheet
            baseIsUserFile = true
            matchColumn = autoMatchColumn(for: sheet)
            indexBase()
            refreshMatches()
            patch = nil
            result = nil
            clearReference()
            columnMode = .patchBase
            if plans.isEmpty {
                // 아직 합칠 파일이 없다 — 틀만 받아 두고 파일 올리기 화면에 머무른다.
                focusColumns = []
                includedColumns = []
                stage = .work
            } else if isUtility {
                // 유틸 흐름에서는 첫 화면에 머무른다 — 파일과 컬럼만 정하면 되니까.
                includedColumns = focusColumns
                stage = .work
            } else {
                focusColumns = unresolvedColumns.intersection(Set(finalColumns))
                stage = .focus
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// 고른 컬럼만 검토 대상으로 잡고 값 검토로 넘어간다.
    private func proceedToFocusedReview() {
        includedColumns = focusColumns
        checked = []
        stepOrder = orderedReviewColumns; openColumn = nil
        stage = .review
        preview.reset()
        openPreviewWindow()
    }


    /// 이전 완성본을 참조 파일로 불러온다. 성공하면 true.
    @discardableResult
    private func loadReference() -> Bool {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.commaSeparatedText, .text, xlsxType]
        panel.allowsMultipleSelection = false
        panel.message = "이전에 완성한 보고서(참조용)를 고르세요. 이 파일의 컬럼 구성에 맞춰 남길 컬럼이 정해집니다."
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        do {
            let headers: [String]
            if url.pathExtension.lowercased() == "xlsx" {
                headers = try XLSXReader.readTableAutoHeader(at: url).headers
            } else {
                headers = try CSVParser.readTable(at: url).headers
            }
            return applyReference(headers: headers, name: url.lastPathComponent)
        } catch {
            errorMessage = "\(url.lastPathComponent): \(error.localizedDescription)"
            return false
        }
    }

    /// 참조 파일의 헤더를 그대로 이번 결과물의 컬럼 구성으로 삼는다.
    /// 헤더가 곧 컬럼이므로 ‘알아본 컬럼 / 못 알아본 헤더’ 구분은 더 이상 없다.
    @discardableResult
    private func applyReference(headers: [String], name: String) -> Bool {
        let matched = headers.compactMap { UnifiedColumn(rawValue: $0) }
        guard !matched.isEmpty else {
            errorMessage = "‘\(name)’에서 컬럼 이름(첫 줄)을 찾지 못했어요. 첫 줄이 머리글인 CSV/XLSX인지 확인해 주세요."
            return false
        }
        errorMessage = nil
        referenceName = name
        referenceColumns = Set(matched)
        referenceUnmatched = []
        includedColumns = Set(matched)   // 참조 구성에 맞춰 남길 컬럼을 재설정
        return true
    }

    private func clearReference() {
        referenceName = nil
        referenceColumns = []
        referenceUnmatched = []
    }

    private func checkBinding(_ col: UnifiedColumn) -> Binding<Bool> {
        Binding(get: { checked.contains(col) },
                set: {
                    if $0 {
                        checked.insert(col)
                        // OK할 때마다 ‘거기까지 완성된 파일’ 윈도우를 띄워 보여줍니다.
                        openPreviewWindow()
                    } else {
                        checked.remove(col)
                    }
                })
    }

    /// 펼친 카드를 미리보기의 강조 대상으로 넘긴다. 다른 카드를 펼치면 그쪽으로
    /// 옮겨가고, 접으면 (그 컬럼이 강조 중일 때만) 해제한다.
    private func setFocus(_ col: UnifiedColumn, _ expanded: Bool) {
        if expanded {
            preview.focused = col
        } else if preview.focused == col {
            preview.focused = nil
        }
    }

    /// Rebuild the preview-window model from the current plans + valueMap.
    /// Same engine as the real merge, so the preview IS the future output.
    /// Diffs against the baseline (정리 전 병합본) to show what improved.
    /// 미리보기 창에서 온 요청 처리 — 고른 컬럼 정리하러 가기 / 두 컬럼 합치기.
    private func handlePreviewRequest(_ req: PreviewModel.PreviewRequest?) {
        guard let req else { return }
        preview.request = nil
        switch req {
        case .clean(let cols):
            let valid = cols.filter { finalColumns.contains($0) }
            guard !valid.isEmpty else { return }
            preview.selection = []
            bringMainWindowToFront()
            // 컬럼 하나면 **그 자리에서 이어서** 정리한다 (다른 화면으로 튕기지 않게).
            if valid.count == 1 {
                cleanHubColumn = valid[0]
            } else {
                focusColumns = Set(valid)
                withBusy("검토 화면을 만드는 중…") { startWork() }
            }
        case .merge(let a, let b):
            preview.selection = []
            bringMainWindowToFront()
            // 바로 합치지 않고 ‘어떻게 합칠지’부터 물어본다.
            confirmMerge = finalColumns.filter { $0 == a || $0 == b }
        case .edit(let col, let before, let after):
            withBusy("값을 바꾸는 중…") { editValue(col, from: before, to: after) }
        case .fill(let col):
            preview.selection = []
            bringMainWindowToFront()
            fillTarget = col
        case .move(let col):
            preview.selection = []
            bringMainWindowToFront()
            moveSource = col
        case .fillFrom(let cols):
            let valid = cols.filter { finalColumns.contains($0) }
            guard !valid.isEmpty else { return }
            preview.selection = []
            bringMainWindowToFront()
            fillFromSelection = valid
        case .confirmRow(let key, let on):
            if on { confirmedRowKeys.insert(key) } else { confirmedRowKeys.remove(key) }
            preview.confirmedRows = confirmedRowKeys
            scheduleSave()
        case .confirmRows(let keys, let on):
            if on { confirmedRowKeys.formUnion(keys) }
            else { confirmedRowKeys.subtract(keys) }
            preview.confirmedRows = confirmedRowKeys
            scheduleSave()
        }
    }

    /// 미리보기에서 고친 값 — 같은 값이면 어느 행에 있든 함께 바뀐다.
    /// (이 도구는 ‘값 단위’로 정리하므로, 고침도 값 단위로 남는다 = 변경 보고서에 그대로 남음)
    private func editValue(_ col: UnifiedColumn, from before: String, to after: String) {
        let trimmed = after.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != before else { return }
        var map = valueMap[col] ?? [:]
        // 이미 다른 값에서 이 값으로 통일해 둔 것들도 같이 옮긴다.
        for (k, v) in map where v == before { map[k] = trimmed }
        map[before] = trimmed
        valueMap[col] = map
        refreshPreview()
        scheduleSave()
    }


    /// 미리보기 창에서 시작한 작업이라 메인 창을 앞으로 가져온다.
    private func bringMainWindowToFront() {
        NSApp.activate(ignoringOtherApps: true)
        if let w = NSApp.windows.first(where: { $0.isVisible && $0.title != "완성본 미리보기" }) {
            w.makeKeyAndOrderFront(nil)
        }
    }

    /// 완성본 미리보기 창 열기 — 사용자가 직접 연 것임을 표시해 둔다.
    private func openPreviewWindow() {
        preview.openedByUser = true
        withBusy("완성본 미리보기를 만드는 중…") {
            refreshPreview()
            openWindow(id: "preview")
        }
    }

    // MARK: - 미리 계산해 두기 (버벅임 방지)

    /// 파일 구성이 바뀔 때만 다시 계산하면 되는 것들 — 행을 전부 훑는 무거운 계산.
    private func rebuildRowCache() {
        var c = cache
        c.keyCandidates = computeKeyCandidates()
        c.identityColumns = computeIdentityColumns(from: c.keyCandidates)
        c.filterCandidates = []
        c.filterCounts = [:]
        for col in finalColumns where plans.contains(where: { $0.isMapped(col) }) {
            let counts = computeFilterValueCounts(col)
            if counts.count >= 2 && counts.count <= 12 {
                c.filterCandidates.append(col)
                c.filterCounts[col] = counts
            }
        }
        if let col = filterColumn, c.filterCounts[col] == nil {
            c.filterCounts[col] = computeFilterValueCounts(col)
        }
        cache = c
        rebuildStatusCache()
    }

    /// 값 정리 상태가 바뀔 때 다시 계산하는 것들 — 컬럼마다의 상태·남은 일.
    private func rebuildStatusCache() {
        var c = cache
        var status: [UnifiedColumn: (text: String, warn: Bool, badge: String)] = [:]
        var todo: [UnifiedColumn] = [], settled: [UnifiedColumn] = []
        var empty: [UnifiedColumn] = [], needClean: [(column: UnifiedColumn, note: String)] = []
        var scored: [(col: UnifiedColumn, work: Int)] = []

        for col in finalColumns {
            let st = computeFocusStatus(col)
            status[col] = st
            if st.warn { todo.append(col) } else { settled.append(col) }

            guard let r = reviewFor(col) else {
                empty.append(col)
                continue
            }
            if filesHaving(col) == 0 || r.total == 0 { empty.append(col) }
            if r.kind != .derived {
                let open = openCount(r)
                if open > 0 { needClean.append((col, "\(open)종")) }
                else if shapeConflicts.contains(col) { needClean.append((col, "파일마다 모양 다름")) }
                let gap = templateGap(r)
                let work = open + gap.outside + (gap.isNew ? 1 : 0)
                if work > 0 { scored.append((col, work)) }
            }
        }
        c.status = status
        c.todo = todo
        c.settled = settled.filter { !focusColumns.contains($0) }
        c.empty = empty
        c.needClean = needClean
        c.proposalOrder = scored.enumerated()
            .sorted { ($0.element.work, $0.offset) < ($1.element.work, $1.offset) }
            .map { $0.element.col }
        c.autoEditable = c.settled.filter { col in
            (valueMap[col] ?? [:]).contains { $0.key != $0.value }
        }
        (c.holes, c.templateCells, c.templateFilled) = computeTemplateHoles()
        c.holeByColumn = Dictionary(uniqueKeysWithValues: c.holes.map { ($0.column, $0.empty) })
        // 손볼 거리가 있는 칸은 값 예시를 함께 보여 준다 (뭘 고칠지 바로 알 수 있게).
        var samples: [UnifiedColumn: [String]] = [:]
        for col in c.todo.prefix(40) {
            guard let r = reviewFor(col) else { continue }
            let vals = r.values.isEmpty ? r.samples : r.values.map(\.value)
            samples[col] = Array(vals.prefix(3))
        }
        c.samples = samples
        cache = c
    }

    /// 틀 안 컬럼의 빈 칸을 센다. **이 앱의 목표는 틀 밖 컬럼을 없애는 게 아니라
    /// 틀 안의 행을 채우는 것**이라, 남은 일도 진행률도 여기서 나온다.
    /// 틀이 없으면 셀 것이 없다 (틀 = 컬럼 이름만 빌려 온 파일, 행은 올린 파일에서만 온다).
    private func computeTemplateHoles()
        -> (holes: [(column: UnifiedColumn, empty: Int)], cells: Int, filled: Int) {
        guard !templateColumns.isEmpty, let sheet = base, !sheet.rows.isEmpty else {
            return ([], 0, 0)
        }
        var holes: [(column: UnifiedColumn, empty: Int)] = []
        var cells = 0, filled = 0
        for col in templateColumns {
            let header = col.rawValue
            var blank = 0
            for row in sheet.rows {
                let v = row[header] ?? ""
                if v.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { blank += 1 }
            }
            cells += sheet.rows.count
            filled += sheet.rows.count - blank
            if blank > 0 { holes.append((col, blank)) }
        }
        // 많이 빈 칸부터 — 채웠을 때 결과가 가장 크게 완성되는 순서.
        holes.sort { $0.empty > $1.empty }
        return (holes, cells, filled)
    }

    /// 키로 삼을 만한 컬럼 — 값이 (거의) 행마다 고유하고 잘 채워진 컬럼.
    private func computeKeyCandidates() -> [UnifiedColumn] {
        finalColumns.filter { col in
            guard plans.contains(where: { $0.isMapped(col) }) else { return false }
            var seen = Set<String>()
            var filled = 0, dup = 0, total = 0
            for plan in plans where plan.isMapped(col) {
                for row in plan.rows {
                    total += 1
                    let v = plan.compose(col, from: row).trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !v.isEmpty else { continue }
                    filled += 1
                    if !seen.insert(v.lowercased()).inserted { dup += 1 }
                }
            }
            guard total > 0, filled * 2 >= total else { return false }
            return dup * 10 <= filled
        }
    }

    /// 키가 없을 때 ‘같은 사람인가’를 가릴 컬럼 — 이메일·전화처럼 생긴 값.
    private func computeIdentityColumns(from candidates: [UnifiedColumn]) -> [UnifiedColumn] {
        func looksLikeContact(_ col: UnifiedColumn) -> Bool {
            var checked = 0, hits = 0
            for plan in plans where plan.isMapped(col) {
                for row in plan.rows.prefix(60) {
                    let v = plan.compose(col, from: row)
                    guard !v.isEmpty else { continue }
                    checked += 1
                    if v.contains("@") || v.filter(\.isNumber).count >= 9 { hits += 1 }
                }
            }
            return checked > 0 && hits * 2 >= checked
        }
        return Array(candidates.filter { $0 != keyColumn }.filter(looksLikeContact).prefix(2))
    }

    /// 컬럼의 값별 행 수 (빈 값은 `(빈 칸)`).
    private func computeFilterValueCounts(_ col: UnifiedColumn) -> [(value: String, count: Int)] {
        var counts: [String: Int] = [:]
        for plan in plans where plan.isMapped(col) {
            for row in plan.rows {
                let v = plan.compose(col, from: row).trimmingCharacters(in: .whitespacesAndNewlines)
                counts[v.isEmpty ? "(빈 칸)" : v, default: 0] += 1
            }
        }
        return counts.sorted { $0.value > $1.value }.map { (value: $0.key, count: $0.value) }
    }

    /// 컬럼 한 줄에 붙는 상태 문구 — 값 종 수와 남은 결정, 그리고 틀과의 어긋남.
    private func computeFocusStatus(_ col: UnifiedColumn) -> (text: String, warn: Bool, badge: String) {
        guard let r = reviewFor(col) else { return ("데이터 있음", false, "") }
        if r.kind == .derived { return ("자동 생성 컬럼 — 합칠 때 새로 계산됩니다", false, "") }
        let open = openCount(r)
        let gap = templateGap(r)
        let head = "\(r.total)행 · \(r.distinctCount)종"
        if open > 0 { return ("\(head) · 미정리 \(open)종", true, "손볼 거리 있음") }
        if r.total == 0 {
            return ("아직 비어 있음 — 채울 칸을 골라 주거나 그대로 두면 빈칸으로 남습니다",
                    true, "비어 있음")
        }
        if gap.isNew {
            return ("\(head) · 틀에 없는 컬럼 — 결과 파일 맨 뒤에 새로 생깁니다", true, "틀에 없는 컬럼")
        }
        if gap.outside > 0 {
            return ("\(head) · 틀에 없는 값 \(gap.outside)종 (틀은 \(gap.known)종)", true, "틀과 다름")
        }
        if gap.known > 0 { return ("\(head) · 틀에 있는 값과 맞음", false, "") }
        return (isDecisionRelevant(r) ? "\(head) · 정리됨" : head, false, "")
    }

    /// 컬럼을 합치거나 행을 걸러 낸 뒤 **행 수가 맞는지** 확인한다.
    /// 데이터가 빠지거나 늘어나면 그 자리에서 알려 준다.
    private func verifyRowCount(_ what: String) {
        let excluded = deletedSourceIDs.union(filteredOutSourceIDs)
        var expected = 0
        for (i, plan) in plans.enumerated() {
            for r in plan.rows.indices where !excluded.contains("\(i)#\(r)") { expected += 1 }
        }
        let actual = base?.rows.count ?? expected
        if actual != expected {
            errorMessage = "\(what) 뒤 행 수가 달라졌어요 — 예상 \(expected)행, 실제 \(actual)행."
        } else if errorMessage?.contains("행 수가 달라졌어요") == true {
            errorMessage = nil
        }
    }

    /// 미리보기를 다시 만든다 — **무거운 계산은 백그라운드에서**.
    /// 메인 스레드를 붙잡지 않아야 마우스가 무지개로 돌지 않는다.
    private func refreshPreview() {
        guard !plans.isEmpty else { return }
        previewToken &+= 1
        let token = previewToken

        // 상태 의존 계산은 메인에서 먼저 (가볍고, 색·뱃지는 즉시 반영된다).
        var opens: [UnifiedColumn: Int] = [:]
        var relevant: Set<UnifiedColumn> = []
        for r in reviews {
            if isDecisionRelevant(r) { relevant.insert(r.column) }
            let open = openCount(r)
            if open > 0 { opens[r.column] = open }
        }
        rebuildStatusCache()
        preview.checked = checked
        preview.openCounts = opens
        preview.decisionColumns = relevant
        preview.fileNames = plans.map(\.fileName)
        preview.confirmedRows = confirmedRowKeys
        sendColumnMarks()
        preview.isBuilding = true

        // 백그라운드로 넘길 것들은 값 타입으로 복사해 간다 (뷰 상태를 건드리지 않게).
        let input = PreviewInput(plans: plans,
                                 valueMap: valueMap,
                                 phoneTemplate: phoneTemplate,
                                 codePattern: keyPattern,
                                 isUtility: isUtility,
                                 base: isPatching ? base : nil,
                                 baseIsUserFile: baseIsUserFile,
                                 patchColumns: focusOrdered,
                                 appendNewRows: appendNewRows,
                                 markNewRows: markNewRows,
                                 match: rowMatch,
                                 // 작업대는 늘 **전부** 보여 준다 — 고른 컬럼만 남으면
                                 // 어디서 값을 끌어올지 볼 수가 없다.
                                 visibleColumns: finalColumns,
                                 keyColumn: keyColumn,
                                 needsBaseline: preview.baselineRows.isEmpty,
                                 generated: generatedColumns)

        DispatchQueue.global(qos: .userInitiated).async {
            let payload = PreviewBuilder.build(input)
            DispatchQueue.main.async {
                guard token == previewToken else { return }   // 더 새 계산이 있으면 버린다
                preview.apply(payload)
            }
        }
    }

    /// 키로 삼을 만한 컬럼들 — 값이 (거의) 행마다 고유하고 잘 채워진 컬럼.
    private var keyCandidates: [UnifiedColumn] { cache.keyCandidates }

    /// 키가 없을 때 ‘같은 사람인가’를 가릴 컬럼들 — 이메일·전화처럼 생긴 값 우선.
    private var identityColumns: [UnifiedColumn] { cache.identityColumns }

    /// 키를 자동으로 골라 준다 — Code·사번처럼 사람을 가리키는 컬럼 먼저.
    private func autoKeyColumn() -> UnifiedColumn? {
        let candidates = keyCandidates
        for preferred in [UnifiedColumn.code, .email, .phone]
        where candidates.contains(preferred) { return preferred }
        return candidates.first
    }

    /// 자동으로 붙는 일련번호를 사람이 정하는 칸 — 규칙 대신 **첫 값**을 적게 한다.
    private var keyPatternEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("첫 번호").font(.body.weight(.semibold))
                TextField("예: 6F10001", text: $keyPatternText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 180)
                Text("→ \(keyPattern.sample)")
                    .font(.body).foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            Text("여기 적은 값이 첫 번호가 되고, 그다음부터 1씩 올라갑니다. "
                 + "앞에 붙인 글자와 자릿수도 그대로 따라갑니다 (`A-001` → `A-002`). "
                 + "이미 원본에 있는 번호는 건너뜁니다.")
                .font(.body).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Color.primary.opacity(0.04)))
        .onChange(of: keyPatternText) { _ in scheduleSave() }
    }

    /// 첫 값에서 읽어 낸 번호 규칙.
    private var keyPattern: KeyPattern { KeyPattern(example: keyPatternText) ?? .auto }

    /// 키가 바뀌면 결과물(기준선)을 다시 만든다.
    private func applyKeyColumn(_ col: UnifiedColumn?) {
        keyColumn = col
        keyColumnChosen = true
        withBusy(col == nil ? "그냥 쌓는 중…" : "‘\(col!.rawValue)’ 기준으로 합치는 중…") {
            rebuildWorkColumns()
        }
    }


    /// 숨겨 둔 행까지 포함해 파일을 다시 읽는다 (사용자가 눌렀을 때만).
    /// 올린 파일을 **원본에서 다시 읽어** 값만 새로 고친다.
    /// 지금까지 정해 둔 컬럼 구성(합친 칸·구분자·방식)은 그대로 이어 간다.
    /// (읽기 코드가 고쳐졌을 때 작업을 처음부터 다시 하지 않아도 되게.)
    private func reloadWorkFiles() {
        let old = plans
        guard !old.isEmpty else { return }
        isLoadingFiles = true
        loadingNote = "파일을 다시 읽는 중…"
        DispatchQueue.global(qos: .userInitiated).async {
            var built: [FilePlan] = []
            var failure: String?
            for plan in old {
                do {
                    var fresh = try PlanBuilder.passthrough(url: plan.url,
                                                            includeHidden: plan.includesHiddenRows)
                    // 사람이 정해 둔 매핑은 되살린다 — 원본에 그 칸이 아직 있을 때만.
                    let headers = Set(fresh.headers)
                    for (col, srcs) in plan.sources where srcs.allSatisfy(headers.contains) {
                        fresh.sources[col] = srcs
                        fresh.separators[col] = plan.separators[col]
                        fresh.combine[col] = plan.combine[col]
                        if !fresh.headers.contains(col.rawValue) {
                            fresh.headers.append(col.rawValue)
                        }
                    }
                    // 다른 칸으로 옮겨서 없앴던 컬럼은 되살리지 않는다 —
                    // 지금 쓰고 있는 컬럼 구성 그대로, 값만 새로 읽는 게 목적이다.
                    let keep = Set(plan.headers)
                    for h in fresh.headers where !keep.contains(h) {
                        if let col = UnifiedColumn(rawValue: h) {
                            fresh.sources[col] = nil
                            fresh.separators[col] = nil
                            fresh.combine[col] = nil
                        }
                    }
                    fresh.headers.removeAll { !keep.contains($0) }
                    built.append(fresh)
                } catch {
                    failure = "\(plan.url.lastPathComponent): \(error.localizedDescription)"
                    break
                }
            }
            let result = built
            let error = failure
            DispatchQueue.main.async {
                isLoadingFiles = false
                guard error == nil, !result.isEmpty else { errorMessage = error; return }
                plans = result
                rebuildWorkColumns()
                scheduleSave()
            }
        }
    }

    private func reloadIncludingHiddenRows() {
        let urls = plans.map(\.url)
        guard !urls.isEmpty else { return }
        isLoadingFiles = true
        loadingNote = "숨긴 행까지 다시 읽는 중…"
        DispatchQueue.global(qos: .userInitiated).async {
            var built: [FilePlan] = []
            var failure: String?
            for url in urls {
                do { built.append(try PlanBuilder.passthrough(url: url, includeHidden: true)) }
                catch { failure = "\(url.lastPathComponent): \(error.localizedDescription)"; break }
            }
            let result = built
            let error = failure
            DispatchQueue.main.async {
                isLoadingFiles = false
                guard error == nil, !result.isEmpty else {
                    errorMessage = error
                    return
                }
                plans = result
                rebuildWorkColumns()
            }
        }
    }

    /// 행을 걸러 낼 만한 컬럼 — 값이 몇 종류뿐인 ‘상태’ 같은 컬럼.
    private var filterCandidates: [UnifiedColumn] { cache.filterCandidates }

    /// 그 컬럼의 값별 행 수 (빈 값은 `(빈 칸)`으로).
    private func filterValueCounts(_ col: UnifiedColumn) -> [(value: String, count: Int)] {
        cache.filterCounts[col] ?? computeFilterValueCounts(col)
    }

    /// 지금 필터로 빠지는 행들 (`파일#줄`). 지운 게 아니라 ‘잠깐 빼 둔’ 것.
    private var filteredOutSourceIDs: Set<String> {
        guard let col = filterColumn, !filterKeep.isEmpty else { return [] }
        var out = Set<String>()
        for (i, plan) in plans.enumerated() {
            guard plan.isMapped(col) else { continue }
            for (r, row) in plan.rows.enumerated() {
                let v = plan.compose(col, from: row).trimmingCharacters(in: .whitespacesAndNewlines)
                if !filterKeep.contains(v.isEmpty ? "(빈 칸)" : v) { out.insert("\(i)#\(r)") }
            }
        }
        return out
    }

    private func applyRowFilter(_ col: UnifiedColumn?, keep: Set<String>) {
        filterColumn = col
        filterKeep = keep
        withBusy("행을 거르는 중…") { rebuildWorkColumns() }
        scheduleSave()
    }

    /// 중복으로 보이는 행들을 **사용자가 눌렀을 때만** 지운다. 되살리기도 한 번에.
    private func deleteDuplicateRows() {
        guard let sheet = base, !sheet.duplicateRows.isEmpty else { return }
        let ids = sheet.duplicateRows.compactMap { i -> String? in
            i < sheet.rowSourceIDs.count ? sheet.rowSourceIDs[i] : nil
        }
        deletedSourceIDs.formUnion(ids)
        rebuildWorkColumns()
        scheduleSave()
    }

    private func restoreDeletedRows() {
        guard !deletedSourceIDs.isEmpty else { return }
        deletedSourceIDs = []
        rebuildWorkColumns()
        scheduleSave()
    }



    /// 첫 화면에서 보이던 표시(쪼개진 컬럼·짝 후보·지금 보는 컬럼)를 미리보기 창으로 넘긴다.
    private func sendColumnMarks() {
        var split: Set<UnifiedColumn> = []
        var hints: [UnifiedColumn: String] = [:]
        for col in finalColumns where isSplitColumn(col) {
            split.insert(col)
            if let caption = splitCaption(col) { hints[col] = caption }
        }
        var owners: [UnifiedColumn: [Int]] = [:]
        for col in finalColumns { owners[col] = columnOwnerIndices(col) }
        preview.splitColumns = split
        preview.pairHints = hints
        preview.columnOwners = owners
        preview.emptyColumns = Set(emptyColumns)
        preview.nextHint = nextStepHint.text
        preview.nextColumn = nextStepHint.column
        preview.usingTemplate = !templateColumns.isEmpty
        preview.extraColumns = templateColumns.isEmpty ? []
            : Set(finalColumns.filter { !templateColumns.contains($0) })
        preview.templateSet = Set(templateColumns)
        preview.templateOrder = templateColumns
        preview.holeCounts = cache.holeByColumn
        // 컬럼을 고르는 중이면 지금 제안하는 컬럼을 강조해 둔다.
        if stage == .work, openColumn == nil { preview.focused = currentProposalColumn }
    }

    /// 지금 선택·결정 상태로 기존본을 덮어쓴 결과를 만든다.

    /// 이번에 정제하기로 한 컬럼 — 결과물의 컬럼 순서대로.
    /// 고르지 않았어도 ‘정해 둔 규칙대로 다듬을 수 있는’ 컬럼은 함께 채운다
    /// (판단이 필요 없는 컬럼까지 사람이 일일이 고르게 하지 않는다).
    private var focusOrdered: [UnifiedColumn] {
        let auto = autoFillSettled ? Set(autoEditableColumns) : []
        let made = Set(generatedColumns.keys)
        // 사람이 실제로 값을 바꿔 둔 컬럼은 **고르지 않았어도** 결과에 반영한다.
        // (이게 빠져 있어서, 작업대에서 바로 고친 값이 미리보기에 안 들어갔다.)
        let edited = Set(valueMap.compactMap { col, map in
            map.contains { $0.key != $0.value } ? col : nil
        })
        return allColumns.filter {
            focusColumns.contains($0) || auto.contains($0)
                || made.contains($0) || edited.contains($0)
        }
    }

    private func toggleAll() {
        checked = allChecked ? [] : Set(visibleFinalColumns)
    }

    private func bindingForColumn(_ col: UnifiedColumn) -> Binding<[String: String]> {
        Binding(get: { valueMap[col] ?? [:] }, set: { valueMap[col] = $0 })
    }

    private func autoUnify(_ col: UnifiedColumn, values: [DistinctValue]) {
        valueMap[col] = ValueCanonicalizer.suggest(values)
    }

    /// Parse every added file, then build the column-by-column review.
    private func prepareReview() {
        errorMessage = nil
        isPreparing = true
        // 아카데미 통합본의 Unique ID 기본값 (사양서 6F1 + 일련번호).
        if !keyColumnChosen, KeyPattern(example: keyPatternText)?.prefix == "AUTO-" {
            keyPatternText = "6F10001"
        }
        let current = inputs
        let previous = plans
        DispatchQueue.global(qos: .userInitiated).async {
            var built: [FilePlan] = []
            var failure: String?
            for input in current {
                do {
                    built.append(try PlanBuilder.build(
                        url: input.url, channel: input.channel,
                        previous: previous.first { $0.url == input.url }))
                } catch {
                    failure = "\(input.url.lastPathComponent): \(error.localizedDescription)"
                    break
                }
            }
            let cols = failure == nil ? ColumnReviewBuilder.finalColumns(in: built) : []
            let revs = failure == nil ? ColumnReviewBuilder.reviews(in: built) : []
            DispatchQueue.main.async {
                self.isPreparing = false
                if let failure { self.errorMessage = failure; return }
                self.plans = built
                self.finalColumns = cols
                self.reviews = revs
                self.checked = []
                self.typeOverride = [:]
                self.formatChoice = [:]
                self.customFormat = [:]
                self.base = nil
                self.patch = nil
                self.focusColumns = []
                self.preview.reset()
                self.seedValueMap(from: revs)
                // 컬럼 기본 선택 정하기.
                if !self.referenceColumns.isEmpty {
                    // 참조가 있으면 참조 구성을 유지 (데이터 없는 컬럼도 그대로 남김).
                    self.includedColumns = self.referenceColumns
                } else if self.includedColumns.isEmpty {
                    // 새로 불러온 파일: 데이터가 있는 최종 컬럼을 기본 선택으로.
                    self.includedColumns = Set(cols)
                } else {
                    // 이미 고른 게 있으면 유효한 것만 남겨 선택을 유지.
                    self.includedColumns.formIntersection(cols)
                    if self.includedColumns.isEmpty { self.includedColumns = Set(cols) }
                }
                // 먼저 ‘틀이 있는지’ 묻는 갈림길부터 시작한다.
                self.columnMode = nil
                self.stage = .columns
            }
        }
    }

    /// 컬럼 선택을 마치고 값 검토 단계로. 선택된 컬럼만 미리보기에 반영된다.
    private func proceedToReview() {
        checked = []
        stage = .review
        preview.reset()          // 비교 기준선을 이 흐름에 맞게 다시 잡는다
        openPreviewWindow()
    }

    // MARK: - Session save / resume (멈췄다 이어서 하기)

    /// 현재 작업 전체를 스냅샷으로 만든다 (파싱된 데이터 + 모든 결정).
    private func makeSnapshot() -> SessionSnapshot {
        let files = plans.map { p in
            SessionSnapshot.FileSnapshot(
                path: p.url.path,
                channel: p.channel.rawValue,
                headers: p.headers,
                rows: p.rows,
                sources: ColumnCoding.encode(p.sources),
                separators: ColumnCoding.encode(p.separators),
                passthrough: p.passthrough,
                hiddenRowsSkipped: p.hiddenRowsSkipped,
                includesHiddenRows: p.includesHiddenRows,
                combine: ColumnCoding.encode(p.combine))
        }
        let stageStr: String
        switch stage {
        case .work:    stageStr = "work"
        case .columns: stageStr = "columns"
        case .focus:   stageStr = "focus"
        case .review:  stageStr = "review"
        default:       stageStr = "files"
        }
        let baseSnap = base.map { b in
            SessionSnapshot.BaseSnapshot(
                name: b.name, headers: b.headers, rows: b.rows,
                columnHeader: ColumnCoding.encode(b.columnHeader),
                rowOrigins: b.rowOrigins)
        }
        return SessionSnapshot(
            savedAt: Date(),
            stage: stageStr,
            phoneTemplate: phoneTemplate,
            includedColumns: ColumnCoding.encode(includedColumns),
            checked: ColumnCoding.encode(checked),
            valueMap: ColumnCoding.encode(valueMap),
            allowedValues: ColumnCoding.encode(allowedValues),
            typeOverride: ColumnCoding.encode(typeOverride),
            formatChoice: ColumnCoding.encode(formatChoice),
            customFormat: ColumnCoding.encode(customFormat),
            referenceName: referenceName,
            referenceColumns: ColumnCoding.encode(referenceColumns),
            referenceUnmatched: referenceUnmatched,
            files: files,
            columnMode: columnMode?.rawValue,
            focusColumns: ColumnCoding.encode(focusColumns),
            base: baseSnap,
            baseIsUserFile: baseIsUserFile,
            matchColumn: matchColumn?.rawValue,
            templateName: templateName,
            templateColumns: ColumnCoding.encode(templateColumns),
            keyColumn: keyColumn?.rawValue,
            keyPattern: keyPatternText,
            confirmedRows: Array(confirmedRowKeys),
            deletedRows: Array(deletedSourceIDs),
            filterColumn: filterColumn?.rawValue,
            filterKeep: Array(filterKeep),
            generatedColumns: ColumnCoding.encode(generatedColumns.mapValues(\.encoded)),
            hiddenRowsAware: true)
    }

    /// 변경이 잦아도 0.8초 뒤 한 번만 저장 (디바운스).
    private func scheduleSave() {
        guard !plans.isEmpty, stage != .result else { return }
        saveDebouncer.work?.cancel()
        let item = DispatchWorkItem { saveNow() }
        saveDebouncer.work = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: item)
    }

    /// 지금 즉시 저장 (인코딩은 백그라운드에서).
    private func saveNow() {
        guard !plans.isEmpty, stage != .result else { return }
        let snap = makeSnapshot()
        lastSavedAt = Date()
        DispatchQueue.global(qos: .utility).async { SessionStore.save(snap) }
    }

    /// 툴바에 조용히 붙는 저장 표시.
    @ViewBuilder
    private var savedBadge: some View {
        if let lastSavedAt {
            Label("자동 저장됨 · \(lastSavedAt.formatted(date: .omitted, time: .shortened))",
                  systemImage: "checkmark.icloud")
                .font(.body).foregroundStyle(.secondary)
                .help("작업 내용은 앱 안에 자동으로 저장됩니다. 앱을 껐다 켜도 ‘이어서 하기’로 돌아올 수 있어요.")
        }
    }

    /// 스냅샷에서 작업을 그대로 복원한다 (파일 재접근 없이).
    private func restore(_ s: SessionSnapshot) {
        func col(_ raw: String) -> UnifiedColumn? { UnifiedColumn(rawValue: raw) }

        let restored: [FilePlan] = s.files.map { f in
            let sources = ColumnCoding.decode(f.sources)
            let seps = ColumnCoding.decode(f.separators)
            let how = ColumnCoding.decode(f.combine, as: CombineMode.self)
            return FilePlan(url: URL(fileURLWithPath: f.path),
                            channel: Channel(rawValue: f.channel) ?? .simple,
                            headers: f.headers, rows: f.rows,
                            sources: sources, separators: seps, combine: how,
                            hiddenRowsSkipped: f.hiddenRowsSkipped ?? 0,
                            includesHiddenRows: f.includesHiddenRows ?? false,
                            passthrough: f.passthrough ?? false)
        }
        plans = restored
        inputs = restored.map { MergeInput(url: $0.url, channel: $0.channel) }
        // 유틸 모드로 저장된 세션은 파일 그대로의 컬럼으로 되살린다.
        let utility = restored.count == 1 && restored[0].passthrough
        finalColumns = utility ? ColumnReviewBuilder.plainColumns(in: restored)
                               : ColumnReviewBuilder.finalColumns(in: restored)
        reviews = utility ? ColumnReviewBuilder.plainReviews(in: restored)
                          : ColumnReviewBuilder.reviews(in: restored)
        phoneTemplate = s.phoneTemplate
        includedColumns = ColumnCoding.decodeSet(s.includedColumns)
        checked = ColumnCoding.decodeSet(s.checked)
        valueMap = ColumnCoding.decode(s.valueMap)
        allowedValues = ColumnCoding.decode(s.allowedValues)
        typeOverride = ColumnCoding.decode(s.typeOverride, as: ColumnType.self)
        formatChoice = ColumnCoding.decode(s.formatChoice, as: FormatPreset.self)
        customFormat = ColumnCoding.decode(s.customFormat)
        referenceName = s.referenceName
        referenceColumns = ColumnCoding.decodeSet(s.referenceColumns)
        referenceUnmatched = s.referenceUnmatched
        base = s.base.map { b in
            BaseSheet(name: b.name, headers: b.headers, rows: b.rows,
                      columnHeader: ColumnCoding.decode(b.columnHeader),
                      rowOrigins: b.rowOrigins ?? [])
        }
        focusColumns = ColumnCoding.decodeSet(s.focusColumns)
        baseIsUserFile = (s.baseIsUserFile ?? false) && base != nil
        // 결과물을 다시 만드는 건 아래에서 rebuildWorkColumns()가 한 번에 한다 —
        // 틀 컬럼 순서·키 컬럼·번호 패턴·지운 행까지 전부 반영해서.
        matchColumn = s.matchColumn.flatMap(col)
        templateName = s.templateName
        templateColumns = ColumnCoding.decode(s.templateColumns)
        keyColumn = s.keyColumn.flatMap(col)
        keyColumnChosen = s.keyColumn != nil
        if let p = s.keyPattern, !p.isEmpty { keyPatternText = p }
        confirmedRowKeys = Set(s.confirmedRows ?? [])
        deletedSourceIDs = Set(s.deletedRows ?? [])
        filterColumn = s.filterColumn.flatMap(col)
        filterKeep = Set(s.filterKeep ?? [])
        generatedColumns = ColumnCoding.decode(s.generatedColumns)
            .compactMapValues { GeneratedValue(encoded: $0) }
        // 여기까지가 ‘저장해 둔 결정’ 복원. 이제 그 결정대로 **결과물을 다시 만든다**.
        // (이게 빠져 있어서 되살리면 진행도·틀 채움·만든 번호가 0으로 보였다.)
        if !baseIsUserFile, !plans.isEmpty {
            let keep = includedColumns
            rebuildWorkColumns()
            includedColumns = keep
        } else {
            indexBase()
            refreshMatches()
        }
        patch = nil
        resumable = nil
        errorMessage = nil

        // 복원 시에는 이미 갈림길을 지난 상태이므로 갈림길 화면을 다시 띄우지 않는다.
        if let saved = s.columnMode.flatMap(ColumnMode.init(rawValue:)) {
            columnMode = saved
        } else {
            columnMode = referenceColumns.isEmpty ? .fromScratch : .withTemplate
        }
        if columnMode == .patchBase && base == nil { columnMode = nil }

        switch s.stage {
        case "review":
            stage = .review
            openPreviewWindow()
        case "focus":
            stage = base == nil ? .columns : .focus
        case "columns":
            stage = .columns
        case "work":
            stage = .work
        default:
            stage = utility ? .work : .files
        }
    }

    /// 이어서 하기를 버리고 새로 시작.
    private func discardSession() {
        SessionStore.clear()
        resumable = nil
    }

    /// 저장해 둔 것까지 지우고 완전히 빈 화면으로 — ‘새 작업 시작’.
    private func startOver() {
        resetWork()
        templateName = nil; templateColumns = []; templateValues = [:]
        keyColumn = nil; keyColumnChosen = false
        generatedColumns = [:]
        deletedSourceIDs = []; filterColumn = nil; filterKeep = []
        confirmedRowKeys = []
        typeOverride = [:]; formatChoice = [:]; customFormat = [:]
        mergeDone = []
        cache = WorkCache()
        lastSavedAt = nil
        discardSession()
    }

    private func seedValueMap(from reviews: [ColumnReview]) {
        for review in reviews where review.kind == .category {
            for dv in review.values where valueMap[review.column]?[dv.value] == nil {
                valueMap[review.column, default: [:]][dv.value] = dv.value
            }
        }
    }

    private func runMerge() {
        errorMessage = nil
        isRunning = true
        let baseSheet = isPatching ? base : nil
        let cols = focusOrdered
        let append = appendNewRows, mark = markNewRows, match = rowMatch
        let utility = isUtility
        let allPlans = plans
        let map = valueMap
        let template = phoneTemplate
        let pattern = keyPattern
        let generated = generatedColumns
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let r: MergeResult
                if utility {
                    // 유틸 모드: 올린 순서 그대로 이어 붙이고 값 통일만 적용한다.
                    let applied = ValueApplier.run(plans: allPlans, valueMap: map)
                    var rows = applied.rows
                    ValueGenerator.apply(generated, to: &rows)
                    r = MergeResult(rows: rows, counts: [:], duplicatePairs: 0,
                                    keepCount: 0, removeCount: 0, unmatchedNoPhone: 0,
                                    changes: applied.changes)
                } else {
                    var merged = try MergeEngine(plans: allPlans, valueMap: map,
                                                 codePattern: pattern,
                                                 phoneTemplate: template).run()
                    ValueGenerator.apply(generated, to: &merged.rows)
                    r = merged
                }
                let p = baseSheet.map {
                    PatchEngine.apply(base: $0, merged: r.rows, generatedCodes: r.generatedCodes,
                                      columns: cols, appendNewRows: append, markNewRows: mark,
                                      match: match)
                }
                DispatchQueue.main.async {
                    self.result = r
                    self.patch = p
                    self.isRunning = false
                    self.stage = .result
                }
            } catch {
                DispatchQueue.main.async {
                    self.errorMessage = error.localizedDescription
                    self.isRunning = false
                }
            }
        }
    }

    /// 결과 화면에서 ‘신규 행’ 옵션을 바꾸면 이어붙이기를 다시 계산한다.
    private func recomputePatch() {
        guard let base, let result else { return }
        patch = PatchEngine.apply(base: base, merged: result.rows,
                                  generatedCodes: result.generatedCodes,
                                  columns: focusOrdered,
                                  appendNewRows: appendNewRows, markNewRows: markNewRows,
                                  match: rowMatch)
    }

    private func exportResult() {
        guard let result else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "제출자_merged.csv"
        if panel.runModal() == .OK, let url = panel.url {
            do {
                try Exporter.write(result, to: url, excludeRemoved: excludeRemoved,
                                   columns: includedOrdered)
                // 최종 내보내기를 마쳤으면 이어서 하기용 세션은 정리.
                SessionStore.clear()
                resumable = nil
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    /// 이번 컬럼을 덮어쓴 기존본을 통째로 내보낸다. 헤더도 값도 원본 구성 그대로라
    /// 다음번에 이 파일을 다시 불러와 그다음 컬럼을 이어서 정제하면 된다.
    private func exportPatch() {
        guard let patch, let base else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        let stem = (base.name as NSString).deletingPathExtension
        panel.nameFieldStringValue = isUtility ? "\(stem)_정리.csv" : "\(stem)_업데이트.csv"
        panel.message = "기존 파일을 덮어쓰지 않도록 새 이름으로 저장하는 걸 권합니다."
        if panel.runModal() == .OK, let url = panel.url {
            do {
                try Exporter.writePatch(patch, to: url)
                SessionStore.clear()
                resumable = nil
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    /// 기존본의 어느 셀이 바뀌었는지 전체 내역.
    private func exportPatchChangeReport() {
        guard let patch else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "변경보고서.csv"
        if panel.runModal() == .OK, let url = panel.url {
            do {
                try Exporter.writeChanges(patch.changes, to: url)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    /// Export the audit trail: every cell the merge modified, with its 출처 키.
    private func exportChangeReport() {
        guard let result else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "변경보고서.csv"
        if panel.runModal() == .OK, let url = panel.url {
            do {
                try Exporter.writeChanges(result.changes, to: url)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

// MARK: - Reusable pieces

private let xlsxType = UTType(filenameExtension: "xlsx") ?? .data

/// 작업 내용을 자동으로 저장한다 — 무엇이 바뀌든 0.8초 뒤 한 번,
/// 창을 내리거나 앱을 벗어나면 즉시. (본문 뷰의 타입 체크 부담도 덜어 준다.)
struct SessionAutosave: ViewModifier {
    let save: () -> Void
    let saveNow: () -> Void
    let scenePhase: ScenePhase

    let valueMap: [UnifiedColumn: [String: String]]
    let allowedValues: [UnifiedColumn: [String]]
    let checked: Set<UnifiedColumn>
    let includedColumns: Set<UnifiedColumn>
    let focusColumns: Set<UnifiedColumn>
    let finalColumns: [UnifiedColumn]
    let stage: ContentView.Stage
    let planCount: Int
    let keyColumn: UnifiedColumn?
    let templateName: String?

    func body(content: Content) -> some View {
        content
            .onChange(of: valueMap) { _ in save() }
            .onChange(of: allowedValues) { _ in save() }
            .onChange(of: checked) { _ in save() }
            .onChange(of: includedColumns) { _ in save() }
            .onChange(of: focusColumns) { _ in save() }
            .onChange(of: finalColumns) { _ in save() }
            .onChange(of: stage) { _ in save() }
            .onChange(of: planCount) { _ in save() }
            .onChange(of: keyColumn) { _ in save() }
            .onChange(of: templateName) { _ in save() }
            .onChange(of: scenePhase) { phase in if phase != .active { saveNow() } }
    }
}
