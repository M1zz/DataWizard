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
    @State private var saveDebouncer = SaveDebouncer()
    /// 마지막으로 자동 저장한 시각 — 저장되고 있다는 걸 눈으로 확인시켜 준다.
    @State private var lastSavedAt: Date?
    /// 사람이 ‘확정’으로 표시한 행들 (키 값 기준이라 행 순서가 바뀌어도 유지).
    @State private var confirmedRowKeys: Set<String> = []
    /// 사용자가 직접 지운 행 (`파일#줄`). 이것 말고는 어떤 행도 사라지지 않는다.
    @State private var deletedSourceIDs: Set<String> = []

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
        .sheet(isPresented: Binding(get: { confirmMerge != nil },
                                    set: { if !$0 { confirmMerge = nil } })) {
            mergeConfirmSheet
        }
        .sheet(item: $filePreview) { plan in
            FilePreviewSheet(plan: plan,
                             tint: fileTint(plans.firstIndex(where: { $0.id == plan.id }) ?? 0),
                             onClose: { filePreview = nil })
        }
        .sheet(item: $detailColumn) { col in detailSheet(col) }
        .sheet(item: $configColumn) { col in
            ColumnSourceSheet(column: col, plans: $plans, onClose: {
                configColumn = nil
                // 어느 칸을 쓸지 바뀌었으니 컬럼·값·미리보기를 다시 만든다.
                if stage == .work { rebuildWorkColumns() }
            })
        }
        .sheet(item: $exampleColumn) { col in
            ExampleRuleSheet(column: col,
                             values: ValueScanner.distinct(col, in: plans),
                             mapping: bindingForColumn(col),
                             onClose: { exampleColumn = nil })
        }
        .sheet(item: $regexColumn) { col in
            // Cleanup is value-based, so aggregate across files (one row per value).
            RegexCleanupSheet(column: col,
                              values: ValueScanner.distinct(col, in: plans),
                              mapping: bindingForColumn(col),
                              onClose: { regexColumn = nil })
        }
        .sheet(item: $mappingColumn) { col in
            MappingTableSheet(column: col,
                              values: ValueScanner.distinct(col, in: plans),
                              mapping: bindingForColumn(col),
                              allowed: Binding(get: { allowedValues[col] ?? [] },
                                               set: { allowedValues[col] = $0 }),
                              onClose: { mappingColumn = nil })
        }
        .sheet(isPresented: $showMatchSheet) {
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
        // 이전 세션이 있으면 파일 화면에서 이어서 하기를 제안.
        .onAppear {
            if resumable == nil { resumable = SessionStore.load() }
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
                    workColumnBar
                    Divider()
                    ScrollView {
                        VStack(alignment: .leading, spacing: 10) {
                            workMergeCard
                            workPreviewCard
                            workProposalCard
                            workTodoSummary
                            workColumnBoard
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
                                    Text("\(plan.rows.count)행 · \(plan.headers.count)컬럼 · 눌러서 보기")
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
            } else {
                Button("만들던 통합본에 이어붙이기…") { chooseBase() }
                    .controlSize(.small)
                    .help("이미 만들어 둔 통합본이 있으면 그 파일을 기준으로, 고른 컬럼 값만 덮어씁니다.")
            }
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
    private var proposalOrder: [UnifiedColumn] {
        let scored: [(col: UnifiedColumn, work: Int)] = finalColumns.compactMap { col in
            guard let r = reviewFor(col), r.kind != .derived else { return nil }
            let gap = templateGap(r)
            let work = openCount(r) + gap.outside + (gap.isNew ? 1 : 0)
            return work > 0 ? (col, work) : nil
        }
        return scored.enumerated()
            .sorted { ($0.element.work, $0.offset) < ($1.element.work, $1.offset) }
            .map { $0.element.col }
    }

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
    private var settledColumns: [UnifiedColumn] {
        finalColumns.filter { col in
            guard let r = reviewFor(col), r.kind != .derived else { return false }
            return !focusStatus(col).warn && !focusColumns.contains(col)
        }
    }

    /// 그중 사람 판단 없이 값을 다듬을 수 있는 컬럼 — 이미 정해진 통일 규칙이 있는 것들.
    private var autoEditableColumns: [UnifiedColumn] {
        settledColumns.filter { col in
            (valueMap[col] ?? [:]).contains { $0.key != $0.value }
        }
    }

    /// 값을 정리해야 하는 컬럼들 — 미정리 값이 남았거나 파일마다 모양이 다른 컬럼.
    private var columnsNeedingClean: [(column: UnifiedColumn, note: String)] {
        finalColumns.compactMap { col in
            guard let r = reviewFor(col), r.kind != .derived else { return nil }
            let open = openCount(r)
            if open > 0 { return (col, "\(open)종") }
            if shapeConflicts.contains(col) { return (col, "파일마다 모양 다름") }
            return nil
        }
    }

    /// 지금 무엇이 남았는지 한 카드로 — 채울 것 / 정리할 것 / 이미 끝난 것.
    @ViewBuilder
    private var workTodoSummary: some View {
        let fill = emptyColumns
        let clean = columnsNeedingClean
        let settled = settledColumns
        VStack(alignment: .leading, spacing: 8) {
            Text("남은 일").font(.headline)
            if fill.isEmpty && clean.isEmpty {
                Label("채울 것도, 정리할 값도 없습니다 — 이제 가져가면 돼요.",
                      systemImage: "checkmark.seal.fill")
                    .font(.body).foregroundStyle(.green)
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
                         clean.map { "\($0.column.rawValue) (\($0.note))" },
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

    /// 여러 컬럼을 한 칸으로 합치기 전 확인 — 무엇이 어디로 가는지 보여 준다.
    @ViewBuilder
    private var mergeConfirmSheet: some View {
        if let cols = confirmMerge, cols.count >= 2 {
            let target = cols[0]
            let sources = Array(cols.dropFirst())
            VStack(alignment: .leading, spacing: 12) {
                Text("한 칸으로 합치기").font(.title2.weight(.bold))
                Text(sources.map(\.rawValue).joined(separator: " · ") + " → ‘\(target.rawValue)’")
                    .font(.body.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Text("앞에 있는 ‘\(target.rawValue)’ 이름이 남고, 나머지 칸의 값이 그 자리로 들어갑니다. "
                     + "한 파일에 둘 다 값이 있으면 공백으로 이어 붙여요 (성 + 이름처럼).")
                    .font(.body).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    Button("취소") { confirmMerge = nil }
                    Button("합치기") {
                        let pairs = sources.map { (source: $0, target: target) }
                        confirmMerge = nil
                        focusColumns = [target]
                        withBusy("컬럼을 합치는 중…") { applyMatches(pairs) }
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
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
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: 8)],
                      alignment: .leading, spacing: 8) {
                ForEach(split.todo) { col in columnChip(col) }
                if showAllColumns {
                    ForEach(split.settled) { col in columnChip(col) }
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
                    Label("한 칸으로 합치기", systemImage: "arrow.trianglehead.merge")
                }
                .help("고른 컬럼을 하나로 합칩니다. 앞에 있는 ‘\(picked[0].rawValue)’ 이름이 남아요.")
            }
            if picked.count == 1, emptyColumns.contains(picked[0]) {
                Button("채울 칸 고르기…") { configColumn = picked[0] }
            }
            Button {
                withBusy("검토 화면을 만드는 중…") { startWork() }
            } label: {
                Text(picked.count == 1 ? "이 컬럼 정리하기 →" : "\(picked.count)개 정리하기 →")
                    .fontWeight(.semibold)
            }
            .buttonStyle(.borderedProminent)
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
                    if !status.badge.isEmpty {
                        Text(status.badge)
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.orange)
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Capsule().fill(Color.orange.opacity(0.12)))
                    }
                }
                HStack(spacing: 6) {
                    if plans.count > 1 { ownerDots(col) }
                    Text(status.text)
                        .font(.body).foregroundStyle(.secondary)
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
                              : (empty ? Color.orange.opacity(0.35) : Color.primary.opacity(0.08)),
                              style: StrokeStyle(lineWidth: on ? 1.5 : 1,
                                                 dash: empty && !on ? [4, 3] : [])))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(status.text)
    }

    /// 손볼 거리가 남은 컬럼 / 이미 정리된 컬럼으로 한 번에 가른다.
    /// (focusStatus 는 컬럼마다 값을 훑으므로 목록마다 다시 계산하지 않는다.)
    private var workColumnSplit: (todo: [UnifiedColumn], settled: [UnifiedColumn]) {
        var todo: [UnifiedColumn] = [], settled: [UnifiedColumn] = []
        for col in finalColumns {
            if focusStatus(col).warn { todo.append(col) } else { settled.append(col) }
        }
        return (todo, settled)
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

    /// 지금 합치면 이렇게 나온다 — 실제 값으로 보여 주는 미리보기.
    @ViewBuilder
    private var workPreviewCard: some View {
        // 조각으로 나눠 둔다 — 한 덩어리로 두면 에디터(SourceKit)가 타입 추론을 포기하고
        // ‘Ambiguous use of opacity’ 같은 엉뚱한 오류를 띄운다.
        Group {
            if !plans.isEmpty && !preview.rows.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    previewCardHeader
                    previewTable
                    previewLegend
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(previewCardBackground)
            }
        }
    }

    private var previewCardHeader: some View {
        let sample = previewSampleRows()
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("완성본 미리보기").font(.headline)
            Text("지금 상태로 만들어진 결과입니다 — 전체 \(preview.rows.count)행 중 \(sample.count)줄")
                .font(.body).foregroundStyle(.secondary)
            Spacer()
        }
    }

    private var previewTable: some View {
        let cols: [UnifiedColumn] = preview.columns.isEmpty ? finalColumns : preview.columns
        let sample: [Int] = previewSampleRows()
        let border: Color = Color.primary.opacity(0.08)
        return ScrollView([.horizontal, .vertical]) {
            VStack(alignment: .leading, spacing: 0) {
                previewHeaderRow(cols)
                ForEach(sample, id: \.self) { i in
                    previewBodyRow(cols, at: i)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: 220, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Color(nsColor: .textBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .stroke(border, lineWidth: 1))
    }

    private var previewCardBackground: some View {
        let fill: Color = Color.primary.opacity(0.03)
        return RoundedRectangle(cornerRadius: 12, style: .continuous).fill(fill)
    }

    private func previewHeaderRow(_ cols: [UnifiedColumn]) -> some View {
        HStack(spacing: 0) {
            Text("행 · 어느 파일에서")
                .font(.body.weight(.semibold)).foregroundStyle(.secondary)
                .frame(width: 150, alignment: .leading)
                .padding(.horizontal, 8).padding(.vertical, 6)
            ForEach(cols) { col in previewHeaderCell(col) }
        }
        .background(Color.primary.opacity(0.04))
    }

    /// 완성본 미리보기의 머리글 한 칸 — 이름 + 출처 점 + 사람 말 설명.
    private func previewHeaderCell(_ col: UnifiedColumn) -> some View {
        let split = isSplitColumn(col)
        let here = (col == currentProposalColumn)
        let owner = columnOwnerTint(col)
        let owners = columnOwnerIndices(col)
        let isEmpty = emptyColumns.contains(col)
        let caption: String? = here ? "지금 볼 컬럼"
            : (isEmpty ? "비어 있음 — 채울 칸을 골라 주세요"
               : (split ? splitCaption(col)
                  : (owners.isEmpty ? nil : (plans.count > 1 ? "모든 파일에 있음" : nil))))
        // 주황 글씨는 눈이 아파서 신호는 점·배경으로만 주고, 글씨는 회색으로.
        let captionTint: Color = here ? .accentColor : .secondary
        let background: Color = here ? Color.accentColor.opacity(0.16)
            : (owner?.opacity(0.16) ?? (split ? Color.orange.opacity(0.10) : Color.clear))
        return VStack(alignment: .leading, spacing: 1) {
            Text(col.rawValue)
                .font(.body.weight(here ? .bold : .semibold))
                .foregroundStyle(here ? Color.accentColor : .primary)
                .lineLimit(1).truncationMode(.tail)
            if let caption {
                HStack(spacing: 4) {
                    if !here && plans.count > 1 { ownerDots(col) }
                    Text(caption)
                        .font(.body).foregroundStyle(captionTint)
                        .lineLimit(1).truncationMode(.tail)
                }
            }
        }
        .frame(width: 152, alignment: .leading)
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(background)
        .overlay(alignment: .leading) { proposalEdge(here) }
        .overlay(alignment: .trailing) { proposalEdge(here) }
        .overlay(alignment: .bottom) {
            Rectangle().fill(split ? Color.orange.opacity(0.5) : Color.primary.opacity(0.1))
                .frame(height: 1)
        }
        .help(splitCaption(col).map { "\(col.rawValue) — \($0)" } ?? col.rawValue)
    }

    private func previewBodyRow(_ cols: [UnifiedColumn], at i: Int) -> some View {
        let row = preview.rows[i]
        let tint = preview.fileTint(row: i)
        let improved = preview.diff[i] ?? []
        return HStack(spacing: 0) {
            HStack(spacing: 4) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(tint ?? Color.secondary.opacity(0.35))
                    .frame(width: 3, height: 14)
                if let badge = preview.rowBadge(row: i) {
                    Text(badge)
                        .font(.body.weight(.semibold)).foregroundStyle(.secondary)
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(Capsule().fill(Color.secondary.opacity(0.14)))
                }
                Text(preview.fileLabel(row: i))
                    .font(.body).foregroundStyle(tint ?? .secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            .frame(width: 150, alignment: .leading)
            .padding(.horizontal, 8).padding(.vertical, 5)
            .help(preview.rowOriginHelp(row: i))
            ForEach(cols) { col in
                previewBodyCell(col, value: row[col], improved: improved.contains(col))
            }
        }
        .background(tint == nil ? Color.clear : tint!.opacity(0.10))
    }

    /// 이 컬럼이 어느 파일에 있는지 점으로 — 있는 파일은 그 색, 없는 파일은 빈 동그라미.
    private func ownerDots(_ col: UnifiedColumn) -> some View {
        let owners = Set(columnOwnerIndices(col))
        return HStack(spacing: 2) {
            ForEach(plans.indices, id: \.self) { i in
                Circle()
                    .fill(owners.contains(i) ? fileTint(i) : Color.clear)
                    .overlay(Circle().stroke(owners.contains(i) ? Color.clear
                                             : Color.secondary.opacity(0.5), lineWidth: 1))
                    .frame(width: 6, height: 6)
                    .help(plans[i].fileName + (owners.contains(i) ? "에 있음" : "엔 없음"))
            }
        }
    }

    /// 미리보기 셀 한 칸 — 배경색이 그 컬럼의 출처(파일)를 말해 준다.
    private func previewBodyCell(_ col: UnifiedColumn, value: String,
                                 improved: Bool) -> some View {
        let here = (col == currentProposalColumn)
        let background: Color = here ? Color.accentColor.opacity(0.10)
            : (columnOwnerTint(col)?.opacity(0.07)
               ?? (isSplitColumn(col) ? Color.orange.opacity(0.05) : Color.clear))
        return Text(value.isEmpty ? "—" : value)
            .font(.body)
            .fontWeight(improved ? .medium : .regular)
            .foregroundStyle(improved ? Color.accentColor
                             : (value.isEmpty ? Color.secondary.opacity(0.5) : .primary))
            .lineLimit(1).truncationMode(.tail)
            .frame(width: 152, alignment: .leading)
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(background)
            .overlay(alignment: .leading) { proposalEdge(here) }
            .overlay(alignment: .trailing) { proposalEdge(here) }
            .help(value)
            .contextMenu {
                Button("이 값 복사") { copyToPasteboard(value) }
                    .disabled(value.isEmpty)
                Button("‘\(col.rawValue)’ 열 전체 복사") {
                    copyToPasteboard(preview.rows.map { $0[col] }.joined(separator: "\n"))
                }
                Divider()
                Button("큰 창에서 고치기…") { openPreviewWindow() }
            }
    }

    private func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
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
    private var emptyColumns: [UnifiedColumn] {
        finalColumns.filter { col in
            guard filesHaving(col) > 0 else { return true }   // 어떤 파일도 이 컬럼을 안 채움
            return (reviewFor(col)?.total ?? 0) == 0          // 채우긴 하는데 값이 다 비었음
        }
    }

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
        if !baseIsUserFile {
            base = BaseSheet.stacked(plans, name: stackedName(plans),
                                     template: templateColumns, key: keyColumn,
                                 keyPattern: keyPattern, identity: identityColumns,
                                 excluding: deletedSourceIDs)
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

            if let resumable {
                resumeCard(resumable).frame(maxWidth: 560)
            }

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

    private func detailFooter(_ review: ColumnReview, at i: Int?) -> some View {
        let open = openCount(review)
        let isLast = (i ?? 0) >= stepOrder.count - 1
        return HStack(spacing: 10) {
            Button("← 이전 컬럼") { openStep(-1) }
                .disabled((i ?? 0) == 0)
            Spacer()
            if open > 0 {
                Text("아직 \(open)종이 남았어요 — 그대로 둬도 됩니다")
                    .font(.body).foregroundStyle(.secondary)
            }
            Button("목록으로") {
                withAnimation(.easeInOut(duration: 0.15)) { openColumn = nil }
            }
            Button {
                if open > 0 { checked.insert(review.column) }   // 남은 값은 ‘이대로 확정’
                openStep(1)
            } label: {
                Text(isLast ? "이 컬럼 끝내기 →" : (open > 0 ? "그대로 두고 다음 →" : "다음 컬럼 →"))
                    .fontWeight(.semibold)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .help(open > 0 ? "남은 값을 원본 그대로 두고 이 컬럼을 끝냅니다."
                           : "이 컬럼은 정리가 끝났어요. 다음 컬럼으로 갑니다.")
        }
        .padding(.top, 4)
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
                                 excluding: deletedSourceIDs)
        }
        finalColumns = (!baseIsUserFile ? base?.columns : nil)
            ?? ColumnReviewBuilder.plainColumns(in: built)
        reviews = ColumnReviewBuilder.plainReviews(in: built)
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
                                 excluding: deletedSourceIDs)
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
        // 키로 포갠 결과물은 행 수가 원본과 다르다 — 그 키로 짝지어야 값이 제자리에 간다.
        if let keyColumn, !baseIsUserFile { return .column(keyColumn) }
        if isUtility && !baseIsUserFile { return .position }
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

    /// 틀의 컬럼 순서를 반영해 컬럼 목록과 기준선을 다시 만든다.
    private func rebuildWorkColumns() {
        guard !plans.isEmpty else {
            base = nil
            finalColumns = []
            return
        }
        base = BaseSheet.stacked(plans, name: stackedName(plans),
                                 template: templateColumns, key: keyColumn,
                                 keyPattern: keyPattern, identity: identityColumns,
                                 excluding: deletedSourceIDs)
        finalColumns = base?.columns ?? ColumnReviewBuilder.plainColumns(in: plans)
        reviews = ColumnReviewBuilder.plainReviews(in: plans)
        seedValueMap(from: reviews)
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
            focusColumns = Set(valid)
            preview.selection = []
            bringMainWindowToFront()
            withBusy("검토 화면을 만드는 중…") { startWork() }
        case .merge(let a, let b):
            preview.selection = []
            bringMainWindowToFront()
            withBusy("두 컬럼을 합치는 중…") { mergeTwoColumns(a, b) }
        case .edit(let col, let before, let after):
            withBusy("값을 바꾸는 중…") { editValue(col, from: before, to: after) }
        case .confirmRow(let key, let on):
            if on { confirmedRowKeys.insert(key) } else { confirmedRowKeys.remove(key) }
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

    /// 고른 두 컬럼을 한 칸으로. 앞(왼쪽)에 있는 컬럼 이름이 남는다.
    private func mergeTwoColumns(_ a: UnifiedColumn, _ b: UnifiedColumn) {
        guard a != b,
              let ia = finalColumns.firstIndex(of: a),
              let ib = finalColumns.firstIndex(of: b) else { return }
        let target = ia < ib ? a : b
        let source = ia < ib ? b : a
        applyMatches([(source: source, target: target)])
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

    private func refreshPreview() {
        let current = currentRows()
        let rows = current.rows

        // 부분 정제·유틸 모드에서는 ‘합쳐진 새 파일’이 아니라
        // ‘값이 덮어써진 원본’이 결과물이다.
        if isPatching, let base {
            refreshPatchPreview(base: base, rows: rows, generatedCodes: current.generatedCodes,
                                origins: current.origins)
            return
        }

        if preview.baselineRows.isEmpty {
            // 기준선은 항상 기본 포맷 — 포맷 변경도 ‘개선’으로 표시되도록.
            let raw = MergeEngine(plans: plans, valueMap: [:], phoneTemplate: Normalizer.defaultPhoneTemplate)
            preview.baselineRows = (try? raw.run())?.rows ?? []
        }
        // 아직 고른 컬럼이 없으면(첫 화면) 전체 컬럼을 보여 준다 — 완성본이니까.
        let cols = visibleFinalColumns.isEmpty ? finalColumns : visibleFinalColumns
        var diff: [Int: Set<UnifiedColumn>] = [:]
        var n = 0
        for (i, row) in rows.enumerated() where i < preview.baselineRows.count {
            for c in cols where row[c] != preview.baselineRows[i][c] {
                diff[i, default: []].insert(c)
                n += 1
            }
        }
        // 컬럼별 ‘아직 할 일이 남았나’ — 검토 화면 뱃지와 같은 판정을 미리보기로 넘긴다.
        var opens: [UnifiedColumn: Int] = [:]
        var relevant: Set<UnifiedColumn> = []
        // 컬럼을 아직 안 골랐어도(첫 화면) 색이 보이도록 전체 리뷰로 계산한다.
        for r in reviews {
            if isDecisionRelevant(r) { relevant.insert(r.column) }
            let open = openCount(r)
            if open > 0 { opens[r.column] = open }
        }

        preview.rows = rows
        preview.diff = diff
        preview.diffCount = n
        preview.columns = cols
        preview.checked = checked
        preview.openCounts = opens
        preview.decisionColumns = relevant
        sendRowKeys(rows)
        preview.rowFiles = current.origins.isEmpty ? planRowOrigins(rows.count) : current.origins
        preview.fileNames = plans.map(\.fileName)
        sendColumnMarks()
    }

    /// 키로 삼을 만한 컬럼들 — 값이 (거의) 행마다 고유하고 잘 채워진 컬럼.
    private var keyCandidates: [UnifiedColumn] {
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
            guard total > 0, filled * 2 >= total else { return false }   // 절반 이상 채워져 있고
            return dup * 10 <= filled                                    // 겹치는 값이 10% 이하
        }
    }

    /// 키가 없을 때 ‘같은 사람인가’를 가릴 컬럼들 — 이메일·전화처럼 생긴 값 우선.
    private var identityColumns: [UnifiedColumn] {
        let candidates = keyCandidates.filter { $0 != keyColumn }
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
        return Array(candidates.filter(looksLikeContact).prefix(2))
    }

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

    /// 올린 파일들의 행 수로 만든 ‘행 → 파일’ 표. 개수가 맞지 않으면 빈 배열.
    private func planRowOrigins(_ expected: Int) -> [Int] {
        var out: [Int] = []
        for (i, p) in plans.enumerated() { out += Array(repeating: i, count: p.rows.count) }
        return out.count == expected ? out : []
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

    /// 행 하나의 이름표 — 키 값이 있으면 그것, 없으면 Code·이메일, 그것도 없으면 행 번호.
    private func rowLabel(_ row: ApplicantRow, at i: Int) -> String {
        for col in [keyColumn, .code, .email].compactMap({ $0 }) {
            let v = row[col].trimmingCharacters(in: .whitespacesAndNewlines)
            if !v.isEmpty { return col.rawValue + "\u{1}" + v.lowercased() }
        }
        return "행 \(i + 1)"
    }

    private func sendRowKeys(_ rows: [ApplicantRow]) {
        preview.rowKeys = rows.enumerated().map { rowLabel($1, at: $0) }
        preview.confirmedRows = confirmedRowKeys
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
        // 컬럼을 고르는 중이면 지금 제안하는 컬럼을 강조해 둔다.
        if stage == .work, openColumn == nil { preview.focused = currentProposalColumn }
    }

    /// 지금 선택·결정 상태로 기존본을 덮어쓴 결과를 만든다.
    private func buildPatch(base: BaseSheet,
                            rows: [ApplicantRow], generatedCodes: Set<String>) -> PatchResult {
        PatchEngine.apply(base: base,
                          merged: rows,
                          generatedCodes: generatedCodes,
                          columns: focusOrdered,
                          appendNewRows: appendNewRows,
                          markNewRows: markNewRows,
                          match: rowMatch)
    }

    /// 이번에 정제하기로 한 컬럼 — 결과물의 컬럼 순서대로.
    /// 고르지 않았어도 ‘정해 둔 규칙대로 다듬을 수 있는’ 컬럼은 함께 채운다
    /// (판단이 필요 없는 컬럼까지 사람이 일일이 고르게 하지 않는다).
    private var focusOrdered: [UnifiedColumn] {
        let auto = autoFillSettled ? Set(autoEditableColumns) : []
        return allColumns.filter { focusColumns.contains($0) || auto.contains($0) }
    }

    /// 부분 정제 모드의 미리보기: 기존본 그대로에, 이번 결정이 바꾸는 셀만 표시된다.
    /// 비교 기준(baseline)이 손대기 전 기존본이라, 파란 셀이 곧 ‘이번 작업의 변경분’이다.
    private func refreshPatchPreview(base: BaseSheet, rows sourceRows: [ApplicantRow],
                                     generatedCodes: Set<String>, origins mergedOrigins: [Int] = []) {
        let p = buildPatch(base: base, rows: sourceRows, generatedCodes: generatedCodes)

        var columnHeader = base.columnHeader
        for c in p.addedColumns { columnHeader[c] = c.rawValue }
        func toRow(_ r: [String: String]) -> ApplicantRow {
            var out = ApplicantRow()
            for (col, h) in columnHeader { out[col] = r[h] ?? "" }
            return out
        }

        var cols = base.columns
        for c in p.addedColumns where !cols.contains(c) { cols.append(c) }

        let baseline = base.rows.map { base.applicantRow($0) }
        let rows = p.rows.map(toRow)

        var diff: [Int: Set<UnifiedColumn>] = [:]
        var n = 0
        for (i, row) in rows.enumerated() {
            if i < baseline.count {
                for c in cols where row[c] != baseline[i][c] {
                    diff[i, default: []].insert(c); n += 1
                }
            } else {
                // 새로 붙인 행: 이번에 채운 컬럼을 표시해 눈에 띄게 한다.
                for c in p.columns where !row[c].isEmpty {
                    diff[i, default: []].insert(c); n += 1
                }
            }
        }

        var opens: [UnifiedColumn: Int] = [:]
        var relevant: Set<UnifiedColumn> = []
        // 컬럼을 아직 안 골랐어도(첫 화면) 색이 보이도록 전체 리뷰로 계산한다.
        for r in reviews {
            if isDecisionRelevant(r) { relevant.insert(r.column) }
            let open = openCount(r)
            if open > 0 { opens[r.column] = open }
        }

        // 행마다 어느 파일에서 온 값인지 — 큰 미리보기 창에서도 파일 색을 유지한다.
        // 사용자가 고른 틀에 이어붙이는 중이면, 그 줄에 값을 넣어 준 파일의 색을 쓴다
        // (짝을 못 찾아 기존 값 그대로인 줄은 -1 = 틀 색).
        var origins: [Int] = []
        if !p.sourceRows.isEmpty, !mergedOrigins.isEmpty {
            origins = p.sourceRows.map { m in
                m >= 0 && m < mergedOrigins.count ? mergedOrigins[m] : -1
            }
        }
        if origins.isEmpty {
            origins = base.rowOrigins.count == base.rows.count ? base.rowOrigins : []
            // 기준선이 오래돼 출처가 없으면(예전 세션) 올린 파일들의 행 수로 다시 만든다.
            if origins.isEmpty, !baseIsUserFile { origins = planRowOrigins(base.rows.count) }
            if !origins.isEmpty {
                while origins.count < rows.count { origins.append(-1) }   // 새로 붙인 행
            }
        }
        preview.rowFiles = origins
        preview.baseName = baseIsUserFile ? base.name : ""
        preview.newRows = p.newRowIndices
        preview.duplicateRows = base.duplicateRows
        sendRowKeys(rows)
        preview.fileNames = plans.map(\.fileName)
        sendColumnMarks()

        preview.baselineRows = baseline
        preview.rows = rows
        preview.diff = diff
        preview.diffCount = n
        preview.columns = cols
        preview.checked = checked
        preview.openCounts = opens
        preview.decisionColumns = relevant
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
                sources: Dictionary(uniqueKeysWithValues: p.sources.map { ($0.key.rawValue, $0.value) }),
                separators: Dictionary(uniqueKeysWithValues: p.separators.map { ($0.key.rawValue, $0.value) }),
                passthrough: p.passthrough)
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
                columnHeader: Dictionary(uniqueKeysWithValues:
                    b.columnHeader.map { ($0.key.rawValue, $0.value) }),
                rowOrigins: b.rowOrigins)
        }
        return SessionSnapshot(
            savedAt: Date(),
            stage: stageStr,
            phoneTemplate: phoneTemplate,
            includedColumns: includedColumns.map { $0.rawValue },
            checked: checked.map { $0.rawValue },
            valueMap: Dictionary(uniqueKeysWithValues: valueMap.map { ($0.key.rawValue, $0.value) }),
            allowedValues: Dictionary(uniqueKeysWithValues: allowedValues.map { ($0.key.rawValue, $0.value) }),
            typeOverride: Dictionary(uniqueKeysWithValues: typeOverride.map { ($0.key.rawValue, $0.value.rawValue) }),
            formatChoice: Dictionary(uniqueKeysWithValues: formatChoice.map { ($0.key.rawValue, $0.value.rawValue) }),
            customFormat: Dictionary(uniqueKeysWithValues: customFormat.map { ($0.key.rawValue, $0.value) }),
            referenceName: referenceName,
            referenceColumns: referenceColumns.map { $0.rawValue },
            referenceUnmatched: referenceUnmatched,
            files: files,
            columnMode: columnMode?.rawValue,
            focusColumns: focusColumns.map { $0.rawValue },
            base: baseSnap,
            baseIsUserFile: baseIsUserFile,
            matchColumn: matchColumn?.rawValue,
            templateName: templateName,
            templateColumns: templateColumns.map { $0.rawValue },
            keyColumn: keyColumn?.rawValue,
            keyPattern: keyPatternText,
            confirmedRows: Array(confirmedRowKeys),
            deletedRows: Array(deletedSourceIDs))
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
            var sources: [UnifiedColumn: [String]] = [:]
            for (k, v) in f.sources { if let c = col(k) { sources[c] = v } }
            var seps: [UnifiedColumn: String] = [:]
            for (k, v) in f.separators { if let c = col(k) { seps[c] = v } }
            return FilePlan(url: URL(fileURLWithPath: f.path),
                            channel: Channel(rawValue: f.channel) ?? .simple,
                            headers: f.headers, rows: f.rows,
                            sources: sources, separators: seps,
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
        includedColumns = Set(s.includedColumns.compactMap(col))
        checked = Set(s.checked.compactMap(col))
        valueMap = Dictionary(uniqueKeysWithValues:
            s.valueMap.compactMap { kv in col(kv.key).map { ($0, kv.value) } })
        allowedValues = Dictionary(uniqueKeysWithValues:
            s.allowedValues.compactMap { kv in col(kv.key).map { ($0, kv.value) } })
        typeOverride = Dictionary(uniqueKeysWithValues:
            (s.typeOverride ?? [:]).compactMap { kv in
                guard let c = col(kv.key), let t = ColumnType(rawValue: kv.value) else { return nil }
                return (c, t)
            })
        formatChoice = Dictionary(uniqueKeysWithValues:
            (s.formatChoice ?? [:]).compactMap { kv in
                guard let c = col(kv.key), let f = FormatPreset(rawValue: kv.value) else { return nil }
                return (c, f)
            })
        customFormat = Dictionary(uniqueKeysWithValues:
            (s.customFormat ?? [:]).compactMap { kv in col(kv.key).map { ($0, kv.value) } })
        referenceName = s.referenceName
        referenceColumns = Set(s.referenceColumns.compactMap(col))
        referenceUnmatched = s.referenceUnmatched
        base = s.base.map { b in
            BaseSheet(name: b.name, headers: b.headers, rows: b.rows,
                      columnHeader: Dictionary(uniqueKeysWithValues:
                        b.columnHeader.compactMap { kv in col(kv.key).map { ($0, kv.value) } }),
                      rowOrigins: b.rowOrigins ?? [])
        }
        focusColumns = Set((s.focusColumns ?? []).compactMap(col))
        baseIsUserFile = (s.baseIsUserFile ?? false) && base != nil
        // 사용자가 고른 틀이 아니면 기준선은 올린 파일들로 다시 만든다.
        // (이전 버전 세션에는 행 출처가 없어서 미리보기 파일 색이 안 나왔다.)
        if !baseIsUserFile, !plans.isEmpty {
            base = BaseSheet.stacked(plans, name: stackedName(plans))
        }
        matchColumn = s.matchColumn.flatMap(col)
        templateName = s.templateName
        templateColumns = (s.templateColumns ?? []).compactMap(col)
        keyColumn = s.keyColumn.flatMap(col)
        keyColumnChosen = s.keyColumn != nil
        if let p = s.keyPattern, !p.isEmpty { keyPatternText = p }
        confirmedRowKeys = Set(s.confirmedRows ?? [])
        deletedSourceIDs = Set(s.deletedRows ?? [])
        indexBase()
        refreshMatches()
        patch = nil
        resumable = nil
        preview.reset()
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
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let r: MergeResult
                if utility {
                    // 유틸 모드: 올린 순서 그대로 이어 붙이고 값 통일만 적용한다.
                    let applied = ValueApplier.run(plans: allPlans, valueMap: map)
                    r = MergeResult(rows: applied.rows, counts: [:], duplicatePairs: 0,
                                    keepCount: 0, removeCount: 0, unmatchedNoPhone: 0,
                                    changes: applied.changes)
                } else {
                    r = try MergeEngine(plans: allPlans, valueMap: map,
                                        codePattern: pattern,
                                        phoneTemplate: template).run()
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

/// Full-detail viewer for one column: every distinct value with counts,
/// the unified value (if any), searchable and selectable.
struct ColumnDetailView: View {
    let columnName: String
    let values: [DistinctValue]               // grouped: one row per distinct value
    var rawValues: [DistinctValue] = []        // ungrouped: one row per source row
    let mapping: [String: String]
    var anomalyReasons: [String: String] = [:]   // value → why it looks off
    var refInfo: String = ""                   // 파일별 출처 키 컬럼 안내 (file → column)
    let onClose: () -> Void

    @State private var query = ""
    @State private var sort: ValueSort = .countDesc
    @State private var changedOnly = false
    @State private var expandRaw = true        // 로우데이터: 행을 합치지 않고 전부 펼침
    @State private var didPickInitialSort = false   // 첫 정렬만 자동 지정 (그다음은 사용자 몫)

    /// The list to show: every source row (raw) or one row per distinct value.
    private var base: [DistinctValue] { expandRaw ? rawValues : values }

    /// 값 전체 보기에서 고를 수 있는 정렬 기준.
    enum ValueSort: String, CaseIterable, Identifiable {
        case countDesc   = "건수 많은 순"
        case countAsc    = "건수 적은 순"
        case valueAsc    = "값 가나다순"
        case valueDesc   = "값 가나다 역순"
        case changedFirst = "바뀐 값 먼저"
        case anomalyFirst = "점검 필요 먼저"
        var id: String { rawValue }
        var symbol: String {
            switch self {
            case .countDesc:    return "arrow.down.to.line"
            case .countAsc:     return "arrow.up.to.line"
            case .valueAsc:     return "textformat.abc"
            case .valueDesc:    return "textformat.abc.dottedunderline"
            case .changedFirst: return "arrow.left.arrow.right"
            case .anomalyFirst: return "exclamationmark.triangle"
            }
        }
    }

    /// 현재 화면에서 고를 수 있는 정렬 기준.
    /// ‘바뀐 값 먼저’는 변경이 있을 때, ‘점검 필요 먼저’는 이상값이 있을 때만.
    private var sortOptions: [ValueSort] {
        ValueSort.allCases.filter {
            switch $0 {
            case .changedFirst: return changedKinds > 0
            case .anomalyFirst: return !anomalyReasons.isEmpty
            default:            return true
            }
        }
    }

    /// 이 값의 이후 값(매핑 적용 결과). 매핑이 없으면 원본 그대로.
    private func after(_ dv: DistinctValue) -> String { mapping[dv.value] ?? dv.value }
    private func isChanged(_ dv: DistinctValue) -> Bool { after(dv) != dv.value }

    private var filtered: [DistinctValue] {
        var rows = query.isEmpty
            ? base
            : base.filter { $0.value.localizedCaseInsensitiveContains(query) }
        if changedOnly { rows = rows.filter(isChanged) }
        return rows.sorted(by: ordering)
    }

    /// 선택한 기준으로 두 값의 순서를 정합니다. 동률이면 값 가나다순으로 안정화.
    private func ordering(_ a: DistinctValue, _ b: DistinctValue) -> Bool {
        switch sort {
        case .countDesc:
            if a.count != b.count { return a.count > b.count }
        case .countAsc:
            if a.count != b.count { return a.count < b.count }
        case .valueAsc:
            break
        case .valueDesc:
            if a.value != b.value {
                return a.value.localizedStandardCompare(b.value) == .orderedDescending
            }
        case .changedFirst:
            let ca = isChanged(a), cb = isChanged(b)
            if ca != cb { return ca && !cb }
            if a.count != b.count { return a.count > b.count }
        case .anomalyFirst:
            let fa = anomalyReasons[a.value] != nil
            let fb = anomalyReasons[b.value] != nil
            if fa != fb { return fa && !fb }
            if a.count != b.count { return a.count > b.count }
        }
        return a.value.localizedStandardCompare(b.value) == .orderedAscending
    }
    private var totalRows: Int { values.reduce(0) { $0 + $1.count } }
    private var valueKinds: Int { Set(values.map { $0.value }).count }
    /// Distinct original values whose 이후 값 differs from the 이전 값.
    private var changedKinds: Int { Set(values.filter(isChanged).map { $0.value }).count }
    /// Same value appearing in more than one source file → 동명이인 후보.
    private var splitCount: Int { values.count - valueKinds }

    /// All source files present in this column, in stable order, for color assignment.
    private var allFiles: [String] {
        Array(Set(values.flatMap { $0.files })).sorted()
    }
    private var showsSource: Bool { !allFiles.isEmpty }

    private static let palette: [Color] =
        [.blue, .green, .orange, .purple, .pink, .teal, .red, .indigo]

    private func color(for file: String) -> Color {
        guard let i = allFiles.firstIndex(of: file) else { return .secondary }
        return Self.palette[i % Self.palette.count]
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(columnName).font(.headline)
                    Text((expandRaw ? "원본 \(rawValues.count)행 (전부 펼침) · \(valueKinds)종 값"
                                    : "\(valueKinds)종 값 · \(totalRows)행")
                         + (!expandRaw && splitCount > 0 ? " · 출처 분리 \(values.count)행" : "")
                         + (changedKinds > 0 ? " · ↪︎ 바뀐 값 \(changedKinds)종" : "")
                         + (anomalyReasons.isEmpty ? "" : " · ⚠︎ 점검 \(anomalyReasons.count)건"))
                        .font(.body).foregroundStyle(.secondary)
                }
                Spacer()
                Button("닫기", action: onClose).keyboardShortcut(.cancelAction)
            }
            .padding(16)
            Divider()

            if base.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "tray").font(.system(size: 28)).foregroundStyle(.tertiary)
                    Text("표시할 값이 없습니다.\n(병합 후 결정되는 값일 수 있어요.)")
                        .font(.body).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(spacing: 10) {
                    TextField("값 검색…", text: $query)
                        .textFieldStyle(.roundedBorder)
                    Toggle(isOn: $expandRaw) { Text("원본 행 펼치기") }
                        .toggleStyle(.checkbox)
                        .fixedSize()
                        .help("켜면 같은 값이라도 원본의 모든 행을 한 줄씩 그대로 보여줍니다(합치지 않음). 끄면 값 종류별로 묶어 보여줍니다.")
                    if changedKinds > 0 {
                        Toggle(isOn: $changedOnly) { Text("바뀐 값만") }
                            .toggleStyle(.checkbox)
                            .fixedSize()
                            .help("이전 값과 이후 값이 다른 값만 봅니다.")
                    }
                    Picker(selection: $sort) {
                        ForEach(sortOptions) { opt in
                            Label(opt.rawValue, systemImage: opt.symbol).tag(opt)
                        }
                    } label: {
                        Label("정렬", systemImage: "arrow.up.arrow.down")
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .fixedSize()
                    .help("값 목록을 정렬할 기준을 고르세요.")
                }
                .padding(.horizontal, 16).padding(.vertical, 10)

                ScrollView {
                    LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                        Section {
                            ForEach(filtered) { dv in
                                let changed = isChanged(dv)
                                HStack(spacing: 12) {
                                    // 출처 키: 원본 파일에서 이 행을 찾는 식별자 (Code/Email/행)
                                    Text(dv.refs.isEmpty ? "—"
                                         : dv.refs[0] + (dv.refs.count > 1 ? " 외 \(dv.refs.count - 1)" : ""))
                                        .font(.body.monospaced())
                                        .foregroundStyle(dv.refs.isEmpty ? .tertiary : .secondary)
                                        .textSelection(.enabled)
                                        .lineLimit(1).truncationMode(.middle)
                                        .frame(width: 150, alignment: .leading)
                                        .help(dv.refs.isEmpty ? "출처 식별자 없음"
                                              : "원본에서 이 행을 찾는 값:\n" + dv.refs.joined(separator: "\n")
                                                + (dv.count > dv.refs.count ? "\n…" : ""))
                                    // 이전 값 (원본)
                                    HStack(spacing: 5) {
                                        if let reason = anomalyReasons[dv.value] {
                                            Image(systemName: "exclamationmark.triangle.fill")
                                                .font(.body).foregroundStyle(.orange)
                                                .help(reason)
                                        }
                                        Text(dv.value.isEmpty ? "(빈 값)" : dv.value)
                                            .font(.body)
                                            .foregroundStyle(dv.value.isEmpty ? .secondary : .primary)
                                            .textSelection(.enabled)
                                            .lineLimit(1).truncationMode(.tail).help(dv.value)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    // 이후 값 (정리·통일 결과)
                                    HStack(spacing: 6) {
                                        Image(systemName: changed ? "arrow.right" : "equal")
                                            .font(.body)
                                            .foregroundStyle(changed ? Color.accentColor : Color.secondary.opacity(0.5))
                                        Text(after(dv).isEmpty ? "(빈 값)" : after(dv))
                                            .font(.body)
                                            .fontWeight(changed ? .medium : .regular)
                                            .foregroundStyle(changed ? Color.accentColor : .secondary)
                                            .textSelection(.enabled)
                                            .lineLimit(1).truncationMode(.tail).help(after(dv))
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    if showsSource {
                                        VStack(alignment: .leading, spacing: 2) {
                                            ForEach(dv.files, id: \.self) { file in
                                                HStack(spacing: 4) {
                                                    Circle().fill(color(for: file))
                                                        .frame(width: 7, height: 7)
                                                    Text(file)
                                                        .font(.body)
                                                        .foregroundStyle(.secondary)
                                                        .lineLimit(1).truncationMode(.middle)
                                                }
                                            }
                                        }
                                        .frame(width: 160, alignment: .leading)
                                        .help(dv.files.joined(separator: "\n"))
                                    }
                                    if !expandRaw {
                                        Text("\(dv.count)")
                                            .font(.body).monospacedDigit().foregroundStyle(.secondary)
                                            .frame(width: 56, alignment: .trailing)
                                    }
                                }
                                .padding(.horizontal, 16).padding(.vertical, 6)
                                .background(changed ? Color.accentColor.opacity(0.05) : .clear)
                                Divider()
                            }
                        } header: {
                            HStack(spacing: 12) {
                                Text("출처 키").frame(width: 150, alignment: .leading)
                                    .help("원본 파일에서 이 행을 찾는 식별자입니다. 파일당 한 컬럼으로 고정됩니다.\n"
                                          + (refInfo.isEmpty ? "" : refInfo))
                                Text("이전 값").frame(maxWidth: .infinity, alignment: .leading)
                                Text("이후 값").frame(maxWidth: .infinity, alignment: .leading)
                                if showsSource { Text("출처 파일").frame(width: 160, alignment: .leading) }
                                if !expandRaw { Text("건수").frame(width: 56, alignment: .trailing) }
                            }
                            .font(.body.weight(.semibold)).foregroundStyle(.secondary)
                            .padding(.horizontal, 16).padding(.vertical, 6)
                            .background(Color(nsColor: .windowBackgroundColor))
                        }
                    }
                }
            }
        }
        .frame(width: showsSource ? 1020 : 800, height: 580)
        // 점검 필요(⚠️)한 값이 있으면 그걸 맨 위로 놓고 연다. 정렬 메뉴는 그대로라
        // 사용자가 건수순 등으로 바꾸면 그 선택이 유지된다.
        .onAppear {
            guard !didPickInitialSort else { return }
            didPickInitialSort = true
            if !anomalyReasons.isEmpty { sort = .anomalyFirst }
        }
    }
}

struct Stat: View {
    let label: String
    let value: String
    var small = false
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(small ? .headline : .title2.weight(.bold))
                .monospacedDigit()
            Text(label)
                .font(.body).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

/// One added file: its name, auto-detected channel, and a remove button.
struct InputFileRow: View {
    let input: MergeInput
    let onRemove: () -> Void

    var body: some View {
        HStack {
            Image(systemName: "doc.fill").foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 1) {
                Text(input.url.lastPathComponent)
                    .font(.body.weight(.medium))
                    .lineLimit(1).truncationMode(.middle)
                Text("\(input.channel.rawValue) (자동 감지)")
                    .font(.body).foregroundStyle(.secondary)
            }
            Spacer()
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

/// A reviewable column section: a header with an "이대로 OK" checkbox over its body.
/// Tints green once checked.
struct ReviewSection<Content: View>: View {
    let title: String
    let subtitle: String
    @Binding var isChecked: Bool
    /// 한 번에 한 컬럼씩 진행할 때 — 카드를 접지 않고 늘 펼쳐 둔다.
    var alwaysExpanded: Bool = false
    /// ⚠️ 아직 결정이 필요한가 — 접힌 카드에서 강조 테두리로 눈에 띄게.
    var needsAttention: Bool = false
    /// 추천값으로 한 번에 고칠 수 있는 값의 종 수 (0이면 자동 해결 버튼 숨김).
    var resolveCount: Int = 0
    /// 자동 해결 실행 (추천값 일괄 적용). resolveCount>0일 때만 쓰인다.
    var onResolve: (() -> Void)? = nil
    /// 헤더에 표시할 컬럼 타입 선택 메뉴 (파생 컬럼은 nil).
    var typeControl: AnyView? = nil
    /// 카드를 펼치거나 접을 때 알려 준다 — 미리보기에서 그 열을 강조하기 위해.
    var onExpandChange: ((Bool) -> Void)? = nil
    var onDetail: (() -> Void)? = nil
    /// 예시 몇 개로 규칙을 찾아 주는 시트 — 가장 쉬운 길이라 액션 줄 맨 앞에 둔다.
    var onExample: (() -> Void)? = nil
    var onConfigure: (() -> Void)? = nil
    var onRegex: (() -> Void)? = nil
    var onMapping: (() -> Void)? = nil
    @ViewBuilder var content: () -> Content

    /// 접힘/펼침 — 기본은 접힘. 결정 항목을 큰 카드로 먼저 훑고 하나씩 펼친다.
    @State private var isExpanded = false

    private var expanded: Bool { alwaysExpanded || isExpanded }

    private var hasActions: Bool {
        onDetail != nil || onExample != nil || onConfigure != nil
            || onRegex != nil || onMapping != nil
    }

    private var accentColor: Color {
        isChecked ? .green : (needsAttention ? .orange : .accentColor)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if expanded && !isChecked {
                Divider().padding(.vertical, 4)
                bodyContent
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(needsAttention && !isChecked ? Color.orange.opacity(0.55)
                                                      : Color.primary.opacity(0.06),
                        lineWidth: needsAttention && !isChecked ? 1.5 : 1)
        )
        // 펼친 카드가 곧 ‘지금 만지고 있는 컬럼’이다.
        .onChange(of: isExpanded) { open in onExpandChange?((open || alwaysExpanded) && !isChecked) }
        .onAppear { if alwaysExpanded { onExpandChange?(!isChecked) } }
        .onDisappear { if expanded { onExpandChange?(false) } }
    }

    // 접힌 상태에서도 항상 보이는 헤더 — 누르면 펼쳐진다.
    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            Rectangle()
                .fill(accentColor)
                .frame(width: 4, height: 34)
                .clipShape(Capsule())

            // 왼쪽 영역 전체가 펼침 토글 버튼 (체크박스는 별도).
            Button {
                guard !alwaysExpanded else { return }   // 한 컬럼씩 모드에선 접히지 않는다
                withAnimation(.easeInOut(duration: 0.18)) { isExpanded.toggle() }
            } label: {
                HStack(alignment: .center, spacing: 10) {
                    Image(systemName: isChecked ? "checkmark.circle.fill"
                                                : (expanded ? "chevron.down" : "chevron.right"))
                        .font(.body.weight(.semibold))
                        .foregroundStyle(isChecked ? Color.green : Color.secondary)
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(title)
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1).truncationMode(.tail).help(title)
                        Text(subtitle)
                            .font(.body).foregroundStyle(.secondary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 12)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if let typeControl { typeControl }

            if isChecked {
                Label("완료", systemImage: "checkmark.circle.fill")
                    .font(.body.weight(.medium)).foregroundStyle(.green)
            } else if !expanded {
                if resolveCount > 0, let onResolve {
                    // 추천값이 있으면 펼치지 않고도 한 번에 실제로 고친다.
                    Button {
                        onResolve()
                    } label: {
                        Label("추천값으로 \(resolveCount)건 해결", systemImage: "wand.and.stars")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .help("오타·유사값을 추천 형태로 한 번에 바꿉니다. 펼쳐서 직접 확인·수정할 수도 있어요.")
                } else {
                    // 자동값이 없으면 정직하게: 눌러도 펼쳐질 뿐이므로 라벨도 그대로.
                    Button(needsAttention ? "직접 고치기" : "열기") {
                        withAnimation(.easeInOut(duration: 0.18)) { isExpanded = true }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            Toggle(isOn: $isChecked) { Text("이대로 확정") }
                .toggleStyle(.checkbox)
                .font(.body)
                .fixedSize()
        }
        // 카드는 조용하게 — 체크 표시가 바뀔 때만 살짝 페이드.
        .animation(.easeInOut(duration: 0.18), value: isChecked)
    }

    // 펼쳤을 때만 만들어지는 편집 본문 (액션 버튼 + content).
    private var bodyContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            if hasActions {
                HStack(spacing: 8) {
                    if let onExample {
                        Button(action: onExample) {
                            Label("예시로 고치기", systemImage: "wand.and.stars")
                        }
                        .buttonStyle(.borderedProminent)
                        .help("‘서울특별시 → 서울’처럼 바꾸고 싶은 예를 두어 개 적으면, 같은 규칙이 걸리는 나머지 값까지 찾아 줍니다. 정규식을 몰라도 됩니다.")
                    }
                    if let onDetail {
                        Button(action: onDetail) {
                            Label("값 살펴보기", systemImage: "list.bullet.rectangle")
                        }
                        .help("이 컬럼의 모든 값을 이전 값 → 이후 값으로 하나하나 훑어보고 싶을 때.")
                    }
                    if let onConfigure {
                        Button(action: onConfigure) {
                            Label("여러 칸 합치기", systemImage: "slider.horizontal.3")
                        }
                        .help("여러 원본 칸(예: 성 + 이름)을 한 칸으로 합치고 싶을 때.")
                    }
                    if let onRegex {
                        Button(action: onRegex) {
                            Label("패턴으로 정리하기", systemImage: "curlybraces")
                        }
                        .help("같은 규칙(예: 전화번호 형식)으로 여러 값을 한꺼번에 고치고 싶을 때.")
                    }
                    if let onMapping {
                        Button(action: onMapping) {
                            Label("여러 값을 하나로 모으기", systemImage: "tablecells")
                        }
                        .help("여러 값들을 하나의 표현으로 모으고 싶을 때 (원본 → 통일 표를 붙여넣기).")
                    }
                    Spacer(minLength: 0)
                }
                .controlSize(.regular)
                .padding(.bottom, 10)
            }
            content()
        }
    }
}

/// Body for a categorical column: edit how value variants collapse onto one value.
struct ValueUnifyBody: View {
    let values: [DistinctValue]
    @Binding var mapping: [String: String]
    var allowed: [String] = []      // 매핑표 적용 후엔 이 목록의 값만 선택 가능
    let onAuto: () -> Void

    /// 허용 목록 밖에 있는(아직 선택 안 된) 값들.
    private var outOfSetValues: [DistinctValue] {
        guard !allowed.isEmpty else { return [] }
        return values.filter { !allowed.contains(mapping[$0.value] ?? $0.value) }
    }
    private var outOfSet: Int { outOfSetValues.count }

    /// 매핑표 밖 값에 가장 유사한 허용 값 추천 (없으면 nil → 직접 선택).
    private func recommendation(for value: String) -> (target: String, score: Double)? {
        Similarity.best(value, in: allowed)
    }
    /// 추천이 있는 미선택 값 수 — ‘추천대로 승인’ 버튼 카운트.
    private var recommendable: [(DistinctValue, String)] {
        outOfSetValues.compactMap { dv in
            recommendation(for: dv.value).map { (dv, $0.target) }
        }
    }

    /// 화면을 열 때 ⚠️(허용 목록 밖)였던 값들 — 목록 맨 위로 올려 둔다.
    /// 고르는 즉시 줄이 아래로 튀지 않도록 순서는 열 때 한 번만 정한다.
    @State private var raisedFirst: Set<String> = []

    private var ordered: [DistinctValue] {
        guard !raisedFirst.isEmpty else { return values }
        return values.filter { raisedFirst.contains($0.value) }
             + values.filter { !raisedFirst.contains($0.value) }
    }

    var body: some View {
        let groupCount = Set(values.map { mapping[$0.value] ?? $0.value }).count
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("\(values.count)개 값 → \(groupCount)개로 통일")
                    .font(.body).foregroundStyle(.secondary)
                if !allowed.isEmpty {
                    Label(outOfSet == 0
                          ? "정해둔 값으로만 고정됨 (\(allowed.count)종)"
                          : "정해둔 값으로만 고정됨 · 선택 필요 \(outOfSet)종",
                          systemImage: outOfSet == 0 ? "lock.fill" : "exclamationmark.triangle.fill")
                        .font(.body.weight(.medium))
                        .foregroundStyle(outOfSet == 0 ? Color.green : Color.orange)
                        .help("값을 모아둔 컬럼이라, 통일 값은 미리 정해둔 값 중 하나로만 고를 수 있어요.")
                }
                Spacer()
                if allowed.isEmpty {
                    Button(action: onAuto) {
                        Label("비슷한 값 자동으로 모으기", systemImage: "wand.and.stars")
                    }
                    .help("같은 뜻으로 보이는 값을 자동으로 한 값에 모아 줍니다.")
                } else if !recommendable.isEmpty {
                    Button {
                        // 사용자가 누르는 행위가 곧 승인 — 추천을 일괄 반영.
                        for (dv, target) in recommendable { mapping[dv.value] = target }
                    } label: {
                        Label("추천대로 모아 넣기 (\(recommendable.count))", systemImage: "wand.and.stars")
                    }
                    .help("아직 안 정해진 값들을, 가장 비슷한 값으로 한 번에 모아 넣습니다. 넣은 뒤에도 행마다 다시 바꿀 수 있어요.")
                }
            }

            HStack(spacing: 10) {
                Text("원본 값").frame(width: 240, alignment: .leading)
                Text("건수").frame(width: 56, alignment: .trailing)
                Text("통일 값").frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.body.weight(.semibold)).foregroundStyle(.secondary)

            ForEach(ordered) { dv in
                let canonical = mapping[dv.value] ?? dv.value
                let changed = canonical != dv.value
                let inSet = allowed.isEmpty || allowed.contains(canonical)
                HStack(spacing: 10) {
                    Text(dv.value)
                        .font(.body)
                        .frame(width: 240, alignment: .leading)
                        .lineLimit(1).truncationMode(.tail).help(dv.value)
                    Text("\(dv.count)")
                        .font(.body).foregroundStyle(.secondary)
                        .frame(width: 56, alignment: .trailing)
                    HStack(spacing: 6) {
                        Image(systemName: !inSet ? "exclamationmark.triangle.fill"
                                                 : (changed ? "arrow.right" : "equal"))
                            .font(.body)
                            .foregroundStyle(!inSet ? Color.orange
                                             : (changed ? Color.accentColor : Color.secondary))
                        if allowed.isEmpty {
                            // 매핑표 없음: 자유 입력
                            TextField("", text: Binding(
                                get: { mapping[dv.value] ?? dv.value },
                                set: { mapping[dv.value] = $0 }
                            ))
                            .textFieldStyle(.roundedBorder)
                            .font(.body)
                        } else {
                            // 매핑표 적용됨: 허용 값 중 하나만 선택 가능
                            Picker("", selection: Binding(
                                get: { canonical },
                                set: { mapping[dv.value] = $0 }
                            )) {
                                if !inSet {
                                    Text("⚠️ 선택하세요 (현재: \(canonical))").tag(canonical)
                                }
                                ForEach(allowed, id: \.self) { Text($0).tag($0) }
                            }
                            .labelsHidden()
                            .frame(maxWidth: 280)
                            // 매핑표 밖의 값: 유사도 추천을 보여주고 클릭으로 승인.
                            // 추천이 없거나 안 맞으면 위 Picker에서 직접 고른다.
                            if !inSet, let rec = recommendation(for: dv.value) {
                                Button {
                                    mapping[dv.value] = rec.target
                                } label: {
                                    Label("추천: \(rec.target) (\(Int(rec.score * 100))%)",
                                          systemImage: "wand.and.stars")
                                        .font(.body)
                                }
                                .buttonStyle(.link)
                                .help("유사도가 가장 높은 허용 값입니다. 누르면 이 값으로 승인됩니다.")
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.vertical, 1)
                .background(inSet ? Color.clear : Color.orange.opacity(0.05))
            }
        }
        .onAppear { raisedFirst = Set(outOfSetValues.map(\.value)) }
    }
}

/// Phone/date review as an explicit proposal table: **every** distinct value is
/// listed with its proposed conversion — nothing is converted silently. The user
/// reads the table, fixes 확인 필요 rows, then approves with ‘이대로 OK’.
struct ProposalsBody: View {
    let note: String
    let proposals: [ProposedChange]
    let targetLabel: String          // e.g. "010-1234-5678"
    @Binding var mapping: [String: String]
    var phoneTemplate: Binding<String>? = nil   // 전화번호일 때만: 목표 포맷 템플릿

    /// 직접 입력한 템플릿이 유효한가 (샘플 010-1234-5678을 담고 있는가).
    private var templateValid: Bool {
        guard let t = phoneTemplate?.wrappedValue else { return true }
        return Normalizer.isValidPhoneTemplate(t)
    }

    /// 표시할 제안 값 — 전화번호는 선택한 템플릿 모양으로 즉석 변환.
    private func proposedText(_ p: ProposedChange) -> String {
        if let t = phoneTemplate?.wrappedValue {
            return Normalizer.formatPhone(p.value, template: t) ?? p.proposed
        }
        return p.proposed
    }

    enum Filter: String, CaseIterable, Identifiable {
        case all = "전체", changed = "변환 제안", same = "이미 표준", failed = "확인 필요"
        var id: String { rawValue }
    }
    @State private var filter: Filter = .all

    private var changedRows: [ProposedChange] { proposals.filter { $0.standard && $0.changed } }
    private var sameRows: [ProposedChange] { proposals.filter { $0.standard && !$0.changed } }
    private var failedRows: [ProposedChange] { proposals.filter { !$0.standard } }
    /// 확인 필요 중 사용자가 아직 손대지 않은 값.
    private var unresolved: Int {
        failedRows.filter { (mapping[$0.value] ?? $0.value) == $0.value }.count
    }

    /// 화면을 열 때 ⚠️였던 값들 — 목록 맨 위로 올려 둔다.
    /// 타이핑할 때마다 순서가 바뀌면 고치던 줄이 눈앞에서 사라지므로,
    /// 순서는 열 때 한 번만 정하고 고친 뒤에도 그 자리에 남긴다(심볼만 초록으로).
    @State private var raisedFirst: Set<String> = []

    private func freezeRaisedOrder() {
        raisedFirst = Set(failedRows
            .filter { (mapping[$0.value] ?? $0.value) == $0.value }
            .map(\.value))
    }

    private var visible: [ProposedChange] {
        let rows: [ProposedChange]
        switch filter {
        case .all:     rows = proposals
        case .changed: rows = changedRows
        case .same:    rows = sameRows
        case .failed:  rows = failedRows
        }
        guard !raisedFirst.isEmpty else { return rows }
        return rows.filter { raisedFirst.contains($0.value) }
             + rows.filter { !raisedFirst.contains($0.value) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !note.isEmpty {
                Text(note).font(.body).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            targetBanner    // 맨 위: 모든 값을 어떤 모양으로 맞출 것인가

            // 제안 요약: 무엇이 몇 종 바뀌는지 한 줄로 명시
            HStack(spacing: 12) {
                Label("변환 제안 \(changedRows.count)종", systemImage: "arrow.right.circle.fill")
                    .foregroundStyle(Color.accentColor)
                Label("이미 표준 \(sameRows.count)종", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                if !failedRows.isEmpty {
                    Label(unresolved == 0
                          ? "확인 필요 \(failedRows.count)종 — 모두 수정됨"
                          : "확인 필요 \(failedRows.count)종 · 미해결 \(unresolved)종",
                          systemImage: unresolved == 0 ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(unresolved == 0 ? Color.green : Color.orange)
                }
                Spacer()
                Picker("", selection: $filter) {
                    ForEach(Filter.allCases) { f in Text(f.rawValue).tag(f) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            .font(.body.weight(.medium))

            if visible.isEmpty {
                Text("해당하는 값이 없습니다.")
                    .font(.body).foregroundStyle(.secondary)
            } else {
                HStack(spacing: 10) {
                    Text("이전 값").frame(width: 220, alignment: .leading)
                    Text("건수").frame(width: 56, alignment: .trailing)
                    Text("제안 값 (‘\(targetLabel)’)").frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.body.weight(.semibold)).foregroundStyle(.secondary)

                ForEach(visible) { p in
                    proposalRow(p)
                }
            }
        }
        .onAppear(perform: freezeRaisedOrder)
    }

    /// 목표 포맷 배너 — 값 목록보다 먼저, ‘무엇으로 맞출 것인가’부터 보여준다.
    /// 전화번호는 여기서 바로 목표 모양을 고르거나 직접 적을 수 있다.
    private var targetBanner: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "target").foregroundStyle(Color.accentColor)
                Text("목표 포맷").font(.body.weight(.semibold)).foregroundStyle(.secondary)
                Text(targetLabel)
                    .font(.body.monospaced().weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 5)
                        .fill(Color.accentColor.opacity(0.12)))
                if let phoneTemplate {
                    Menu {
                        ForEach(Normalizer.PhoneFormat.allCases) { f in
                            Button(f.rawValue) { phoneTemplate.wrappedValue = f.rawValue }
                        }
                    } label: {
                        Label("자주 쓰는 형식", systemImage: "textformat.123")
                    }
                    .fixedSize()
                    TextField("예: +82 10-1234-5678", text: phoneTemplate)
                        .textFieldStyle(.roundedBorder)
                        .font(.body.monospaced())
                        .frame(width: 230)
                        .help("샘플 번호 010-1234-5678이 원하는 모양으로 보이게 적으세요. 구분 기호는 자유입니다.")
                    if templateValid {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                            .help("모든 번호가 이 모양으로 통일됩니다.")
                    }
                }
                Spacer()
            }
            if let t = phoneTemplate?.wrappedValue, !templateValid {
                Label("샘플 숫자(01012345678 또는 8210…)가 그대로 들어 있어야 해요 — 지금: \(t)",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.body).foregroundStyle(.orange)
            } else {
                Text(phoneTemplate == nil
                     ? "모든 값을 이 날짜 표기로 바꿉니다. 인식 못 한 값만 아래에서 직접 고치세요."
                     : "모든 번호를 이 모양으로 통일합니다. 표준으로 못 바꾼 값만 아래에서 직접 고치세요.")
                    .font(.body).foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.accentColor.opacity(0.25), lineWidth: 1))
    }

    @ViewBuilder
    private func proposalRow(_ p: ProposedChange) -> some View {
        let current = mapping[p.value] ?? p.value
        let edited = current != p.value
        HStack(spacing: 10) {
            Text(p.value.isEmpty ? "(빈 값)" : p.value)
                .font(.body)
                .frame(width: 220, alignment: .leading)
                .lineLimit(1).truncationMode(.middle).help(p.value)
                .textSelection(.enabled)
            Text("\(p.count)")
                .font(.body).monospacedDigit().foregroundStyle(.secondary)
                .frame(width: 56, alignment: .trailing)
            if p.standard {
                // 표준 도달: 제안 값을 그대로 보여주고 사용자는 읽고 승인만
                let shown = proposedText(p)
                HStack(spacing: 6) {
                    Image(systemName: shown != p.value ? "arrow.right" : "equal")
                        .font(.body)
                        .foregroundStyle(shown != p.value ? Color.accentColor : Color.secondary.opacity(0.6))
                    Text(shown)
                        .font(.body)
                        .foregroundStyle(shown != p.value ? Color.accentColor : .secondary)
                        .textSelection(.enabled)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                // 확인 필요: 제안이 표준에 못 미침 → 직접 수정 (저장 시 자동 정규화)
                HStack(spacing: 6) {
                    Image(systemName: edited ? "arrow.right" : "exclamationmark.triangle.fill")
                        .font(.body)
                        .foregroundStyle(edited ? Color.accentColor : .orange)
                    TextField("", text: Binding(
                        get: { mapping[p.value] ?? p.value },
                        set: { mapping[p.value] = $0 }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .font(.body)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.vertical, 1)
        .background(p.standard ? Color.clear : Color.orange.opacity(0.05))
    }
}

/// Body for a free-text column: a note plus a few sample values.
struct SamplesBody: View {
    let note: String
    let samples: [String]
    let distinctCount: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !note.isEmpty {
                Text(note).font(.body).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !samples.isEmpty {
                Text("예시 값")
                    .font(.body.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(Array(samples.enumerated()), id: \.offset) { _, value in
                    Text("• \(value)")
                        .font(.body)
                        .lineLimit(1).truncationMode(.tail).help(value)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if distinctCount > samples.count {
                    Text("외 \(distinctCount - samples.count)종")
                        .font(.body).foregroundStyle(.tertiary)
                }
            }
        }
    }
}

/// Body for a free-text column: surfaces values that look off (구분 기호, 공백,
/// 숫자 혼입 등) with an editable correction per value, then a few samples.
/// Corrections flow through the same valueMap the merge applies to every column.
struct FreeTextBody: View {
    let note: String
    let samples: [String]
    let distinctCount: Int
    let anomalies: [AnomalyDetector.Finding]
    @Binding var mapping: [String: String]

    private var fixable: [AnomalyDetector.Finding] { anomalies.filter { $0.fixable } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !anomalies.isEmpty { anomalyBox }
            SamplesBody(note: note, samples: samples, distinctCount: distinctCount)
        }
    }

    private var anomalyBox: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("점검이 필요한 값 \(anomalies.count)건", systemImage: "exclamationmark.triangle.fill")
                    .font(.body.weight(.semibold)).foregroundStyle(.orange)
                Spacer()
                if !fixable.isEmpty {
                    Button {
                        for f in fixable { mapping[f.value] = f.suggestion }
                    } label: {
                        Label("추천값으로 일괄 수정 (\(fixable.count))", systemImage: "wand.and.stars")
                    }
                    .help("자동으로 고칠 수 있는 값을 추천 형태로 한 번에 바꿉니다. 이후 직접 수정할 수 있어요.")
                }
            }

            HStack(spacing: 10) {
                Text("원본 값").frame(width: 170, alignment: .leading)
                Text("건수").frame(width: 48, alignment: .trailing)
                Text("사유").frame(width: 200, alignment: .leading)
                Text("수정 값").frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.body.weight(.semibold)).foregroundStyle(.secondary)

            ForEach(anomalies) { f in
                let current = mapping[f.value] ?? f.value
                let changed = current != f.value
                HStack(alignment: .top, spacing: 10) {
                    Text(f.value)
                        .font(.body)
                        .frame(width: 170, alignment: .leading)
                        .lineLimit(1).truncationMode(.middle)
                        .help(f.files.isEmpty ? f.value : "\(f.value)\n출처: \(f.files.joined(separator: ", "))")
                    Text("\(f.count)")
                        .font(.body).foregroundStyle(.secondary)
                        .frame(width: 48, alignment: .trailing)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(f.reason)
                            .font(.body).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if f.fixable && !changed {
                            Button("추천: \(f.suggestion)") { mapping[f.value] = f.suggestion }
                                .buttonStyle(.link).font(.body)
                        }
                    }
                    .frame(width: 200, alignment: .leading)
                    HStack(spacing: 6) {
                        Image(systemName: changed ? "arrow.right" : "equal")
                            .font(.body)
                            .foregroundStyle(changed ? Color.accentColor : Color.secondary)
                        TextField("", text: Binding(
                            get: { mapping[f.value] ?? f.value },
                            set: { mapping[f.value] = $0 }
                        ))
                        .textFieldStyle(.roundedBorder)
                        .font(.body)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(10)
        .background(Color.orange.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.orange.opacity(0.25)))
    }
}

/// Body for a 포맷 column validated against a regex (email / custom).
/// 전화·생년월일은 전용 제안 화면(ProposalsBody)을 쓰므로 여기 오지 않는다.
/// 형식에 맞지 않는 값만 모아 인라인으로 고치게 한다 — 고친 값은 valueMap을
/// 통해 병합에 반영된다.
struct FormatBody: View {
    let values: [DistinctValue]
    let preset: FormatPreset
    let presetPattern: String            // 프리셋 정규식 (custom이면 빈 문자열)
    @Binding var customPattern: String
    @Binding var mapping: [String: String]

    private var isCustom: Bool { preset == .custom }
    private var pattern: String { isCustom ? customPattern : presetPattern }
    private var patternValid: Bool { !pattern.isEmpty && RegexCleaner.isValid(pattern) }

    private func current(_ v: String) -> String { mapping[v] ?? v }
    private var failures: [DistinctValue] {
        guard patternValid else { return [] }
        return values.filter { !RegexCleaner.fullyMatches(current($0.value), pattern) }
    }
    private var okCount: Int { values.count - failures.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            targetBanner            // 맨 위: 이 컬럼이 도달해야 할 모양
            if patternValid {
                if failures.isEmpty {
                    Label("모든 값이 형식에 맞습니다 (\(values.count)종).",
                          systemImage: "checkmark.seal.fill")
                        .font(.body.weight(.medium)).foregroundStyle(.green)
                } else {
                    failureBox
                }
            } else if isCustom {
                Text("맞춰야 할 정규식을 입력하면, 형식에 안 맞는 값만 모아 보여줍니다.")
                    .font(.body).foregroundStyle(.secondary)
            }
        }
    }

    /// 목표 형식 배너 — 이름·예시를 크게, 정규식은 아래 작게. 값 목록보다 먼저
    /// 오도록 본문 맨 위에 둔다 (무엇에 맞추는지가 먼저 보여야 한다).
    private var targetBanner: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "target").foregroundStyle(Color.accentColor)
                Text("목표 형식").font(.body.weight(.semibold)).foregroundStyle(.secondary)
                Text(preset.rawValue).font(.body.weight(.semibold))
                if !isCustom {
                    Text(preset.hint)
                        .font(.body.monospaced().weight(.medium))
                        .foregroundStyle(Color.accentColor)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 5)
                            .fill(Color.accentColor.opacity(0.12)))
                }
                Spacer()
                if patternValid {
                    Text("맞음 \(okCount) · 안 맞음 \(failures.count)")
                        .font(.body.monospacedDigit())
                        .foregroundStyle(failures.isEmpty ? Color.green : Color.orange)
                }
            }
            if isCustom {
                customField
            } else {
                HStack(spacing: 6) {
                    Text(preset.about).font(.body).foregroundStyle(.secondary)
                    Text(pattern)
                        .font(.body.monospaced()).foregroundStyle(.tertiary)
                        .lineLimit(1).truncationMode(.middle)
                        .help("이 컬럼의 값은 전체가 이 정규식과 맞아야 통과합니다: \(pattern)")
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.accentColor.opacity(0.25), lineWidth: 1))
    }

    private var customField: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField("맞춰야 할 정규식 (예: \\d{4}-\\d{2}-\\d{2})", text: $customPattern)
                .textFieldStyle(.roundedBorder)
                .font(.body.monospaced())
            if !customPattern.isEmpty && !RegexCleaner.isValid(customPattern) {
                Label("정규식 형식이 올바르지 않습니다.", systemImage: "exclamationmark.triangle.fill")
                    .font(.body).foregroundStyle(.red)
            }
        }
    }

    private var failureBox: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("형식에 맞지 않는 값 \(failures.count)종", systemImage: "exclamationmark.triangle.fill")
                .font(.body.weight(.semibold)).foregroundStyle(.orange)
            HStack(spacing: 10) {
                Text("원본 값").frame(width: 200, alignment: .leading)
                Text("건수").frame(width: 48, alignment: .trailing)
                Text("고친 값 (형식에 맞게)").frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.body.weight(.semibold)).foregroundStyle(.secondary)

            ForEach(failures) { dv in
                let cur = current(dv.value)
                let ok = RegexCleaner.fullyMatches(cur, pattern)
                HStack(alignment: .center, spacing: 10) {
                    Text(dv.value)
                        .font(.body)
                        .frame(width: 200, alignment: .leading)
                        .lineLimit(1).truncationMode(.middle)
                        .help(dv.files.isEmpty ? dv.value
                              : "\(dv.value)\n출처: \(dv.files.joined(separator: ", "))")
                    Text("\(dv.count)")
                        .font(.body).foregroundStyle(.secondary)
                        .frame(width: 48, alignment: .trailing)
                    HStack(spacing: 6) {
                        Image(systemName: ok ? "checkmark.circle.fill" : "arrow.right")
                            .foregroundStyle(ok ? Color.green : Color.secondary)
                        TextField("", text: Binding(
                            get: { mapping[dv.value] ?? dv.value },
                            set: { mapping[dv.value] = $0 }))
                        .textFieldStyle(.roundedBorder)
                        .font(.body)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(10)
        .background(Color.orange.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.orange.opacity(0.25)))
    }
}

/// Pick regex cleanup rules for one column, preview what changes, then commit.
/// Selected rules apply in order to every distinct value; results are written to
/// the column's valueMap, which the merge applies like any other unification.
struct RegexCleanupSheet: View {
    let column: UnifiedColumn
    let values: [DistinctValue]
    @Binding var mapping: [String: String]
    let onClose: () -> Void

    @State private var selected: Set<String> = []
    @State private var customPattern = ""
    @State private var customReplacement = ""
    @State private var targetPattern = ""

    /// Quick target patterns the cleaned value should end up matching (Req 2).
    static let targetPresets: [(label: String, pattern: String)] = [
        ("전화번호", "\\d{3}-\\d{4}-\\d{4}"),
        ("이메일", "[^@\\s]+@[^@\\s]+\\.[^@\\s]+"),
        ("yyyy-MM-dd", "\\d{4}-\\d{2}-\\d{2}"),
        ("숫자만", "\\d+")
    ]

    private var customError: String? {
        guard !customPattern.isEmpty else { return nil }
        return RegexCleaner.isValid(customPattern) ? nil : "정규식 형식이 올바르지 않습니다."
    }

    private var targetError: String? {
        guard !targetPattern.isEmpty else { return nil }
        return RegexCleaner.isValid(targetPattern) ? nil : "정규식 형식이 올바르지 않습니다."
    }

    /// Values whose cleaned result still doesn't fully match the target pattern.
    private var failures: [Change] {
        guard !targetPattern.isEmpty, targetError == nil else { return [] }
        return values.compactMap { dv in
            let out = RegexCleaner.apply(activePresets, to: dv.value)
            return fullyMatches(out, targetPattern) ? nil
                : Change(from: dv.value, to: out, count: dv.count)
        }
    }

    /// Does the whole string match the pattern (anchored start-to-end)?
    private func fullyMatches(_ s: String, _ pattern: String) -> Bool {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return true }
        let range = NSRange(s.startIndex..., in: s)
        return re.firstMatch(in: s, range: range)?.range == range
    }

    /// Selected presets in library order, plus a valid custom rule last.
    private var activePresets: [RegexPreset] {
        var list = RegexLibrary.presets.filter { selected.contains($0.id) }
        if !customPattern.isEmpty, customError == nil {
            list.append(RegexPreset(id: "custom", name: "직접 입력", summary: "",
                                    pattern: customPattern, replacement: customReplacement, example: ""))
        }
        return list
    }

    private struct Change: Identifiable {
        var id: String { from }
        let from: String
        let to: String
        let count: Int
    }

    private var changes: [Change] {
        guard !activePresets.isEmpty else { return [] }
        return values.compactMap { dv in
            let out = RegexCleaner.apply(activePresets, to: dv.value)
            return out == dv.value ? nil : Change(from: dv.value, to: out, count: dv.count)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    presetList
                    customRow
                    targetRow
                    previewSection
                    failureSection
                }
                .padding(16)
            }
            Divider()
            footer
        }
        .frame(width: 660, height: 680)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("‘\(column.rawValue)’ — 패턴으로 한꺼번에 정리하기").font(.headline)
                Text("적용할 규칙을 고르면 아래에서 바뀔 값을 미리 볼 수 있어요. 위에서부터 차례로 적용됩니다.")
                    .font(.body).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button("닫기", action: onClose).keyboardShortcut(.cancelAction)
        }
        .padding(16)
    }

    private var presetList: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("자주 쓰는 규칙")
                .font(.body.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(RegexLibrary.presets) { preset in
                Toggle(isOn: Binding(
                    get: { selected.contains(preset.id) },
                    set: { if $0 { selected.insert(preset.id) } else { selected.remove(preset.id) } }
                )) {
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 8) {
                            Text(preset.name).font(.body.weight(.medium))
                            Text(preset.pattern)
                                .font(.body.monospaced()).foregroundStyle(.tertiary)
                                .lineLimit(1).truncationMode(.tail)
                        }
                        Text("\(preset.summary)  \(preset.example)")
                            .font(.body).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.tail)
                    }
                }
                .toggleStyle(.checkbox)
            }
        }
    }

    private var customRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("직접 입력")
                .font(.body.weight(.semibold)).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                TextField("패턴 (정규식)", text: $customPattern)
                    .textFieldStyle(.roundedBorder).font(.body.monospaced())
                Image(systemName: "arrow.right").font(.body).foregroundStyle(.secondary)
                TextField("치환할 값 (비우면 삭제)", text: $customReplacement)
                    .textFieldStyle(.roundedBorder).font(.body.monospaced())
                    .frame(width: 180)
            }
            if let customError {
                Label(customError, systemImage: "exclamationmark.triangle.fill")
                    .font(.body).foregroundStyle(.red)
            }
        }
    }

    private var targetRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("목표 패턴 (선택) — 정리 후 이 형태가 아니면 ‘실패’로 표시")
                .font(.body.weight(.semibold)).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                ForEach(Self.targetPresets, id: \.label) { preset in
                    Button(preset.label) { targetPattern = preset.pattern }
                        .buttonStyle(.bordered).controlSize(.small)
                        .tint(targetPattern == preset.pattern ? .accentColor : .secondary)
                }
                Divider().frame(height: 16)
                TextField("패턴 (정규식)", text: $targetPattern)
                    .textFieldStyle(.roundedBorder).font(.body.monospaced())
            }
            if let targetError {
                Label(targetError, systemImage: "exclamationmark.triangle.fill")
                    .font(.body).foregroundStyle(.red)
            }
        }
    }

    @ViewBuilder
    private var failureSection: some View {
        if !targetPattern.isEmpty, targetError == nil {
            HStack {
                Label(failures.isEmpty ? "목표 패턴에 모두 일치" : "패턴 불일치(실패) \(failures.count)종",
                      systemImage: failures.isEmpty ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(failures.isEmpty ? Color.green : Color.orange)
                Spacer()
            }
            if !failures.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(failures) { c in
                        HStack(spacing: 8) {
                            Text(c.from.isEmpty ? "(빈 값)" : c.from)
                                .font(.body)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .lineLimit(1).truncationMode(.middle).help(c.from)
                            Image(systemName: "arrow.right")
                                .font(.body).foregroundStyle(.secondary)
                            Text(c.to.isEmpty ? "(빈 값)" : c.to)
                                .font(.body).foregroundStyle(.orange)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .lineLimit(1).truncationMode(.middle).help(c.to)
                            Text("\(c.count)")
                                .font(.body).monospacedDigit().foregroundStyle(.secondary)
                                .frame(width: 44, alignment: .trailing)
                        }
                        .padding(.vertical, 5)
                        Divider()
                    }
                }
                .padding(.horizontal, 10)
                .background(Color.orange.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    @ViewBuilder
    private var previewSection: some View {
        let total = values.count
        HStack {
            Text("미리보기")
                .font(.body.weight(.semibold)).foregroundStyle(.secondary)
            Spacer()
            Text(activePresets.isEmpty ? "규칙을 선택하세요"
                 : "변경 \(changes.count)종 / 전체 \(total)종")
                .font(.body).foregroundStyle(.secondary)
        }

        if !activePresets.isEmpty {
            if changes.isEmpty {
                Text("선택한 규칙으로 바뀌는 값이 없습니다.")
                    .font(.body).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(changes) { c in
                        HStack(spacing: 8) {
                            Text(c.from.isEmpty ? "(빈 값)" : c.from)
                                .font(.body)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .lineLimit(1).truncationMode(.middle).help(c.from)
                            Image(systemName: "arrow.right")
                                .font(.body).foregroundStyle(.secondary)
                            Text(c.to.isEmpty ? "(빈 값)" : c.to)
                                .font(.body)
                                .foregroundStyle(c.to.isEmpty ? .secondary : Color.accentColor)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .lineLimit(1).truncationMode(.middle).help(c.to)
                            Text("\(c.count)")
                                .font(.body).monospacedDigit().foregroundStyle(.secondary)
                                .frame(width: 44, alignment: .trailing)
                        }
                        .padding(.vertical, 5)
                        Divider()
                    }
                }
                .padding(.horizontal, 10)
                .background(Color(nsColor: .controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private var footer: some View {
        HStack {
            Text("적용하면 위 변경이 ‘\(column.rawValue)’ 값에 반영됩니다.")
                .font(.body).foregroundStyle(.secondary)
            Spacer()
            Button("취소", action: onClose)
            Button("적용 (\(changes.count))") {
                for c in changes { mapping[c.from] = c.to }
                onClose()
            }
            .buttonStyle(.borderedProminent)
            .disabled(changes.isEmpty)
        }
        .padding(16)
    }
}

/// Import a mapping table (원본 → 통일) for one column. The user pastes or loads
/// a list, sees live which of the column's values it covers, and applies it —
/// every pair lands in the same valueMap the merge uses. A coverage badge tracks
/// how many distinct values still have no mapping. (Req 3: 매핑테이블로 전 데이터 매핑)
struct MappingTableSheet: View {
    let column: UnifiedColumn
    let values: [DistinctValue]
    @Binding var mapping: [String: String]
    @Binding var allowed: [String]      // 적용 시 매핑표의 통일 값들이 이 컬럼의 허용 목록이 됨
    let onClose: () -> Void

    @State private var text = ""
    @State private var didSeed = false
    /// 2단계 흐름: 먼저 규칙을 받고(rules), 그다음 적용 결과를 보여준다(preview).
    private enum Step { case rules, preview }
    @State private var step: Step = .rules

    private var parsed: MappingTableParser.Parsed { MappingTableParser.parse(text) }
    private var tableFrom: Set<String> { Set(parsed.pairs.map { $0.from }) }
    private var uncovered: [DistinctValue] { values.filter { !tableFrom.contains($0.value) } }
    private var coveredCount: Int { values.count - uncovered.count }
    private var lookup: [String: String] {
        Dictionary(parsed.pairs.map { ($0.from, $0.to) }, uniquingKeysWith: { _, last in last })
    }
    /// 매핑표에 등장한 통일 값들(중복 제거, 등장 순) — 미매핑 값 배정 메뉴에 사용.
    private var tableTargets: [String] {
        var seen = Set<String>()
        return parsed.pairs.map { $0.to }.filter { !$0.isEmpty && seen.insert($0).inserted }
    }
    /// 배정 메뉴용: 통일 값을 이 값과 유사한 순서로 정렬.
    private func sortedTargets(for value: String) -> [String] {
        tableTargets.sorted { Similarity.score(value, $0) > Similarity.score(value, $1) }
    }
    /// 추천이 있는 미매핑 값들 — ‘추천대로 모두 배정’ 카운트.
    private var recommendableUncovered: [(String, String)] {
        uncovered.compactMap { dv in
            Similarity.best(dv.value, in: tableTargets).map { (dv.value, $0.target) }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            stepBar
            Divider()
            coverageBar
            Divider()
            switch step {
            case .rules:   editorPane
            case .preview: previewPane
            }
            Divider()
            footer
        }
        .frame(width: 820, height: 660)
        .onAppear { if !didSeed { seed(); didSeed = true } }
    }

    /// 두 단계를 보여주는 진행 표시 — 지금 어느 단계인지 한눈에.
    private var stepBar: some View {
        HStack(spacing: 10) {
            stepChip(index: 1, title: "모으기 규칙 적기", active: step == .rules, done: step == .preview)
            Image(systemName: "chevron.right").font(.body).foregroundStyle(.tertiary)
            stepChip(index: 2, title: "적용 결과 확인", active: step == .preview, done: false)
            Spacer()
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
    }

    private func stepChip(index: Int, title: String, active: Bool, done: Bool) -> some View {
        HStack(spacing: 6) {
            ZStack {
                Circle().fill(active ? Color.accentColor : (done ? Color.green : Color.secondary.opacity(0.25)))
                    .frame(width: 20, height: 20)
                if done {
                    Image(systemName: "checkmark").font(.body.weight(.bold)).foregroundStyle(.white)
                } else {
                    Text("\(index)").font(.body.weight(.bold))
                        .foregroundStyle(active ? .white : .secondary)
                }
            }
            Text(title)
                .font(.body.weight(active ? .semibold : .regular))
                .foregroundStyle(active ? .primary : .secondary)
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("‘\(column.rawValue)’ — 여러 값을 하나로 모으기").font(.headline)
                Text("한 줄에 하나씩 ‘원본 값 → 모을 값’ 형태로 적거나 붙여넣으세요. 구분자는 탭·→·:·쉼표 모두 됩니다.")
                    .font(.body).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button("닫기", action: onClose).keyboardShortcut(.cancelAction)
        }
        .padding(16)
    }

    /// All-mapped vs. how many distinct values still fall outside the table.
    private var coverageBar: some View {
        let done = uncovered.isEmpty
        return HStack(spacing: 12) {
            Label(done ? "모든 값이 매핑됨" : "미매핑 \(uncovered.count)종",
                  systemImage: done ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                .font(.body.weight(.semibold))
                .foregroundStyle(done ? Color.green : Color.orange)
            Text("전체 \(values.count)종 · 매핑 \(coveredCount)종 · 규칙 \(parsed.pairs.count)개"
                 + (parsed.skipped.isEmpty ? "" : " · 못 읽은 줄 \(parsed.skipped.count)개"))
                .font(.body).foregroundStyle(.secondary)
            Spacer()
            if !recommendableUncovered.isEmpty {
                Button {
                    // 누르는 행위가 곧 승인 — 추천 배정 줄이 매핑표에 추가된다.
                    appendLines(recommendableUncovered.map { "\($0.0) → \($0.1)" })
                } label: {
                    Label("추천대로 모두 배정 (\(recommendableUncovered.count))", systemImage: "wand.and.stars")
                }
                .controlSize(.small)
                .help("미매핑 값들을 유사도가 가장 높은 통일 값에 한 번에 배정합니다. 배정된 줄은 왼쪽 매핑표에서 확인·수정할 수 있어요.")
            }
            if !uncovered.isEmpty {
                Button {
                    appendLines(uncovered.map { "\($0.value) → \($0.value)" })
                } label: {
                    Label("미매핑 \(uncovered.count)종 모두 그대로 두기", systemImage: "text.badge.plus")
                }
                .controlSize(.small)
                .help("아직 매핑표에 없는 값들을 ‘값 → 값(그대로)’ 줄로 추가합니다. 값을 바꾸는 게 아니라, ‘이 값은 그대로 두기로 했다’를 명시해 커버리지를 채우는 용도예요. 특정 값으로 바꾸려면 오른쪽 미리보기에서 ‘선택…’으로 배정하세요.")
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    private var editorPane: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let label = MappingPresets.label(for: column),
               let pairs = MappingPresets.pairs(for: column) {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.seal.fill").foregroundStyle(Color.accentColor)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("\(label) 있음").font(.body.weight(.medium))
                        Text("사양서의 공식 규칙 \(pairs.count)개를 한 번에 채웁니다. 채운 뒤 수정할 수 있어요.")
                            .font(.body).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(action: fillPreset) {
                        Label("공식 매핑표 채우기", systemImage: "square.and.arrow.down.on.square")
                    }
                    .controlSize(.regular)
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.08)))
            }
            HStack {
                Text("모으기 규칙 (원본 → 모을 값)").font(.body.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Button { loadFile() } label: {
                    Label("파일 불러오기", systemImage: "doc.badge.plus")
                }
                .controlSize(.small)
                if !text.isEmpty {
                    Button("지우기") { text = "" }.controlSize(.small)
                }
            }
            TextEditor(text: $text)
                .font(.body.monospaced())
                .padding(6)
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.secondary.opacity(0.25)))
            Text("예) 서울특별시 → 서울")
                .font(.body).foregroundStyle(.tertiary)
        }
        .padding(16)
        .frame(maxWidth: .infinity)
    }

    private var previewPane: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("적용 결과 미리보기")
                .font(.body.weight(.semibold)).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Text("원본 값").frame(maxWidth: .infinity, alignment: .leading)
                Text("건수").frame(width: 44, alignment: .trailing)
                Text("→ 통일").frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.body.weight(.semibold)).foregroundStyle(.secondary)

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(values) { dv in
                        let hit = lookup[dv.value]
                        HStack(spacing: 8) {
                            Text(dv.value.isEmpty ? "(빈 값)" : dv.value)
                                .font(.body)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .lineLimit(1).truncationMode(.middle).help(dv.value)
                            Text("\(dv.count)")
                                .font(.body).monospacedDigit().foregroundStyle(.secondary)
                                .frame(width: 44, alignment: .trailing)
                            HStack(spacing: 4) {
                                Image(systemName: hit == nil ? "minus" : "arrow.right")
                                    .font(.body)
                                    .foregroundStyle(hit == nil ? Color.orange : Color.accentColor)
                                if let hit {
                                    Text(hit)
                                        .font(.body)
                                        .lineLimit(1).truncationMode(.middle)
                                } else {
                                    // 미매핑: 유사도순으로 정렬된 통일 값 중 하나를 골라 배정.
                                    // 가장 유사한 값은 ✨ 추천으로 맨 위에 표시된다.
                                    let rec = Similarity.best(dv.value, in: tableTargets)
                                    Menu {
                                        if let rec {
                                            Button("✨ 추천: \(rec.target) (\(Int(rec.score * 100))%)") {
                                                appendLines(["\(dv.value) → \(rec.target)"])
                                            }
                                            Divider()
                                        }
                                        ForEach(sortedTargets(for: dv.value), id: \.self) { t in
                                            Button(t) { appendLines(["\(dv.value) → \(t)"]) }
                                        }
                                        if !tableTargets.isEmpty { Divider() }
                                        Button("‘\(dv.value)’ 그대로 두기") {
                                            appendLines(["\(dv.value) → \(dv.value)"])
                                        }
                                    } label: {
                                        Label(rec.map { "추천: \($0.target)" } ?? "선택…",
                                              systemImage: rec == nil ? "chevron.up.chevron.down" : "wand.and.stars")
                                            .font(.body)
                                            .foregroundStyle(Color.orange)
                                            .lineLimit(1)
                                    }
                                    .menuStyle(.borderlessButton)
                                    .fixedSize()
                                    .help("이 값을 매핑표의 통일 값 중 하나에 배정합니다. 목록은 유사한 순서로 정렬되며, 고르면 왼쪽 매핑표에 줄이 추가됩니다.")
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.vertical, 5)
                        Divider()
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var footer: some View {
        switch step {
        case .rules:
            HStack {
                Text(parsed.pairs.isEmpty
                     ? "규칙을 한 줄 이상 적으면 다음 단계로 갈 수 있어요."
                     : "규칙 \(parsed.pairs.count)개 준비됨 · 전체 \(values.count)종 중 \(coveredCount)종 반영 예정")
                    .font(.body).foregroundStyle(.secondary)
                Spacer()
                Button("취소", action: onClose)
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) { step = .preview }
                } label: {
                    Label("다음: 적용 결과 보기", systemImage: "arrow.right")
                }
                .buttonStyle(.borderedProminent)
                .disabled(parsed.pairs.isEmpty)
            }
            .padding(16)
        case .preview:
            HStack {
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) { step = .rules }
                } label: {
                    Label("규칙 수정", systemImage: "arrow.left")
                }
                Spacer()
                Text(uncovered.isEmpty
                     ? "모든 값이 반영됩니다. 적용하면 ‘\(column.rawValue)’에 규칙 \(parsed.pairs.count)개가 적용돼요."
                     : "아직 안 정해진 값 \(uncovered.count)종 — 위에서 배정하거나 그대로 둘 수 있어요.")
                    .font(.body).foregroundStyle(uncovered.isEmpty ? Color.secondary : Color.orange)
                Button("취소", action: onClose)
                Button("적용 (\(parsed.pairs.count))") {
                    for p in parsed.pairs { mapping[p.from] = p.to }
                    // 매핑표의 통일 값들이 이 컬럼의 허용 값이 된다 — 이후 이 컬럼은
                    // 자유 입력이 막히고 이 목록 중 하나만 고를 수 있다.
                    var seen = Set<String>()
                    allowed = parsed.pairs.map { $0.to }.filter { !$0.isEmpty && seen.insert($0).inserted }
                    onClose()
                }
                .buttonStyle(.borderedProminent)
                .disabled(parsed.pairs.isEmpty)
            }
            .padding(16)
        }
    }

    // MARK: - helpers

    /// Pre-fill the editor from mappings the user already set (non-identity only),
    /// so the table round-trips the column's current state.
    private func seed() {
        let lines = values.compactMap { dv -> String? in
            guard let to = mapping[dv.value], to != dv.value else { return nil }
            return "\(dv.value) → \(to)"
        }
        text = lines.joined(separator: "\n")
    }

    private func appendLines(_ lines: [String]) {
        let block = lines.joined(separator: "\n")
        guard !block.isEmpty else { return }
        text = text.isEmpty ? block : text + "\n" + block
    }

    /// 이 컬럼의 공식 매핑표를 편집기에 채운다. 이미 규칙이 있으면 원본(from)이
    /// 겹치지 않는 줄만 덧붙여 사용자가 손댄 내용을 보존한다.
    private func fillPreset() {
        guard let pairs = MappingPresets.pairs(for: column) else { return }
        let existing = tableFrom
        let missing = pairs.filter { !existing.contains($0.from) }.map { "\($0.from) → \($0.to)" }
        appendLines(missing)
    }

    private func loadFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.commaSeparatedText, .text, .tabSeparatedText]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let s = try? String(contentsOf: url, encoding: .utf8) else { return }
        appendLines([s])
    }
}

/// Configure how one unified column is sourced from each file: pick an ordered
/// set of source columns to combine (1 = plain mapping, 2+ = composite like
/// 성 + 이름), with a shared separator and a live preview.
struct ColumnSourceSheet: View {
    let column: UnifiedColumn
    @Binding var plans: [FilePlan]
    let onClose: () -> Void

    private let maxSlots = 4

    /// Quick separators offered for combining columns (Req 1: 공백여부 지정).
    static let separatorPresets: [(label: String, value: String)] =
        [("붙여쓰기", ""), ("공백", " "), ("하이픈 -", "-"), ("쉼표 ,", ", ")]

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("‘\(column.rawValue)’ 가져오기 설정").font(.headline)
                    Text("각 파일에서 이 컬럼을 만들 원본 컬럼을 고르세요. 여러 개를 고르면 순서대로 이어 붙입니다.")
                        .font(.body).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button("닫기", action: onClose).keyboardShortcut(.defaultAction)
            }
            .padding(16)

            VStack(alignment: .leading, spacing: 6) {
                Text("컬럼 사이를 어떻게 이어 붙일까요?").font(.body)
                HStack(spacing: 8) {
                    ForEach(Self.separatorPresets, id: \.label) { preset in
                        Button(preset.label) { separatorBinding.wrappedValue = preset.value }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .tint(separatorBinding.wrappedValue == preset.value ? .accentColor : .secondary)
                    }
                    Divider().frame(height: 16)
                    TextField("직접 입력", text: separatorBinding)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 120)
                    Spacer()
                }
            }
            .padding(.horizontal, 16).padding(.bottom, 12)

            Divider()

            ScrollView {
                VStack(spacing: 12) {
                    ForEach($plans) { $plan in
                        fileRow($plan)
                    }
                }
                .padding(16)
            }
        }
        .frame(width: 640, height: 560)
    }

    private func fileRow(_ plan: Binding<FilePlan>) -> some View {
        let current = plan.wrappedValue.sources[column] ?? []
        let slotCount = min(maxSlots, current.count + 1)
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(plan.wrappedValue.fileName).font(.body.weight(.medium))
                    .lineLimit(1).truncationMode(.middle).help(plan.wrappedValue.fileName)
                Spacer()
                Text("→ \(previewValue(plan.wrappedValue).isEmpty ? "—" : previewValue(plan.wrappedValue))")
                    .font(.body).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.tail)
            }
            HStack(spacing: 8) {
                ForEach(0..<slotCount, id: \.self) { i in
                    if i > 0 {
                        Image(systemName: "plus").font(.body).foregroundStyle(.tertiary)
                    }
                    Picker("", selection: slotBinding(plan, i)) {
                        Text(i == 0 ? "— 없음 —" : "— 추가 —").tag("")
                        ForEach(plan.wrappedValue.headers, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden().frame(width: 180)
                }
                Spacer()
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func previewValue(_ plan: FilePlan) -> String {
        guard let first = plan.rows.first else { return "" }
        return plan.compose(column, from: first)
    }

    private var separatorBinding: Binding<String> {
        Binding(
            get: { plans.first(where: { $0.separators[column] != nil })?.separators[column] ?? "" },
            set: { sep in for i in plans.indices { plans[i].separators[column] = sep } }
        )
    }

    private func slotBinding(_ plan: Binding<FilePlan>, _ index: Int) -> Binding<String> {
        Binding(
            get: {
                let arr = plan.wrappedValue.sources[column] ?? []
                return index < arr.count ? arr[index] : ""
            },
            set: { newValue in
                var arr = plan.wrappedValue.sources[column] ?? []
                while arr.count <= index { arr.append("") }
                arr[index] = newValue
                arr = arr.filter { !$0.isEmpty }
                plan.wrappedValue.sources[column] = arr
            }
        )
    }
}

// MARK: - Preview window (합쳐진 파일 미리보기)

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
    // 미리보기 창에서 고른 컬럼과, 메인 창에 보내는 요청.
    @Published var selection: Set<UnifiedColumn> = []
    @Published var request: PreviewRequest?

    /// 미리보기 창이 메인 창에 시키는 일.
    enum PreviewRequest: Equatable {
        case clean([UnifiedColumn])                 // 고른 컬럼 정리하러 가기
        case merge(UnifiedColumn, UnifiedColumn)    // 두 컬럼을 한 칸으로
        case edit(UnifiedColumn, String, String)    // 컬럼 · 이전 값 · 새 값
        case confirmRow(String, Bool)               // 행 이름표 · 확정 여부
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
    /// 창을 열 때 중복만 보여 줄지.
    @Published var showDuplicatesOnly = false

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

    /// 셀 한 칸의 배경색. 컬럼 상태가 열 전체로 내려와 세로줄로 읽히게 합니다.
    /// 확정한 컬럼은 사람이 손봐서 끝낸 열이므로 초록으로 채웁니다.
    func cellTint(_ c: UnifiedColumn, improved: Bool) -> Color {
        switch status(c) {
        case .confirmed:            return .green.opacity(improved ? 0.16 : 0.10)
        case .needsWork:            return .orange.opacity(improved ? 0.12 : 0.06)
        case .resolved, .nothingToDo:
            if improved { return .accentColor.opacity(0.10) }
            // 한 파일에서만 온 컬럼은 그 파일 색으로 — 어디서 온 열인지 배경으로 보이게.
            if let t = ownerTint(c) { return t.opacity(0.10) }
            return splitColumns.contains(c) ? .orange.opacity(0.05) : .clear
        }
    }

    func reset() {
        rows = []; baselineRows = []; diff = [:]; diffCount = 0
        columns = []; checked = []
        rowFiles = []; fileNames = []
        splitColumns = []; pairHints = [:]; columnOwners = [:]; baseName = ""; newRows = []
        emptyColumns = []; rowKeys = []; duplicateRows = []; showDuplicatesOnly = false
        selection = []; request = nil
        openCounts = [:]; decisionColumns = []
        focused = nil
    }
}

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

/// 올린 파일을 **원본 그대로** 들여다보는 창.
/// 합쳐진 결과가 아니라, 그 파일에 실제로 뭐가 들어 있는지 확인하는 용도.
struct FilePreviewSheet: View {
    let plan: FilePlan
    let tint: Color
    let onClose: () -> Void

    @State private var query = ""

    private var visible: [(Int, [String: String])] {
        let all = Array(plan.rows.enumerated()).map { ($0.offset, $0.element) }
        guard !query.isEmpty else { return all }
        return all.filter { _, row in
            plan.headers.contains { (row[$0] ?? "").localizedCaseInsensitiveContains(query) }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 3).fill(tint).frame(width: 4, height: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(plan.fileName).font(.title2.weight(.bold))
                        .lineLimit(1).truncationMode(.middle)
                    Text("\(plan.rows.count)행 · \(plan.headers.count)컬럼"
                         + (visible.count == plan.rows.count ? "" : " · \(visible.count)행 표시")
                         + " — 올린 파일 그대로입니다 (정리 전)")
                        .font(.body).foregroundStyle(.secondary)
                }
                Spacer()
                TextField("값 검색…", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 200)
                Button { copyTable() } label: { Label("표 복사", systemImage: "doc.on.doc") }
                    .help("이 파일을 탭 구분으로 복사합니다.")
                Button("닫기") { onClose() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(16)
            Divider()
            ScrollView([.horizontal, .vertical]) {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    Section {
                        ForEach(visible.prefix(500), id: \.0) { i, row in
                            HStack(spacing: 0) {
                                Text("\(i + 1)")
                                    .font(.body.monospacedDigit()).foregroundStyle(.secondary)
                                    .frame(width: 56, alignment: .trailing)
                                    .padding(.horizontal, 8).padding(.vertical, 4)
                                ForEach(plan.headers, id: \.self) { h in
                                    let v = row[h] ?? ""
                                    Text(v.isEmpty ? "—" : v)
                                        .font(.body)
                                        .foregroundStyle(v.isEmpty ? Color.secondary.opacity(0.5) : .primary)
                                        .lineLimit(1).truncationMode(.tail)
                                        .frame(width: 190, alignment: .leading)
                                        .padding(.horizontal, 8).padding(.vertical, 4)
                                        .help(v)
                                        .contextMenu {
                                            Button("이 값 복사") { copy(v) }
                                            Button("‘\(h)’ 열 전체 복사") {
                                                copy(plan.rows.map { $0[h] ?? "" }.joined(separator: "\n"))
                                            }
                                        }
                                }
                            }
                            .background(i.isMultiple(of: 2) ? Color.clear : tint.opacity(0.06))
                            Divider()
                        }
                    } header: {
                        HStack(spacing: 0) {
                            Text("행")
                                .font(.body.weight(.semibold)).foregroundStyle(.secondary)
                                .frame(width: 56, alignment: .trailing)
                                .padding(.horizontal, 8).padding(.vertical, 6)
                            ForEach(plan.headers, id: \.self) { h in
                                Text(h)
                                    .font(.body.weight(.semibold))
                                    .lineLimit(2).truncationMode(.tail)
                                    .frame(width: 190, alignment: .leading)
                                    .padding(.horizontal, 8).padding(.vertical, 6)
                                    .help(h)
                            }
                        }
                        .background(Color(nsColor: .underPageBackgroundColor))
                    }
                }
            }
            if visible.count > 500 {
                Divider()
                Text("앞 500행만 보여 줍니다 — 전체는 ‘표 복사’로 가져가세요.")
                    .font(.body).foregroundStyle(.secondary)
                    .padding(.horizontal, 16).padding(.vertical, 6)
            }
        }
        .frame(minWidth: 860, minHeight: 520)
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func copyTable() {
        var lines = [(["행"] + plan.headers).joined(separator: "\t")]
        for (i, row) in visible {
            let cells = plan.headers.map { (row[$0] ?? "").replacingOccurrences(of: "\t", with: " ") }
            lines.append((["\(i + 1)"] + cells).joined(separator: "\t"))
        }
        copy(lines.joined(separator: "\n"))
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
    @ObservedObject var model = PreviewModel.shared
    @State private var query = ""
    @State private var improvedOnly = false
    @State private var unconfirmedOnly = false
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
    private static let defaultColumnWidth: CGFloat = 190

    private func width(_ c: UnifiedColumn) -> CGFloat {
        columnWidths[c.rawValue] ?? Self.defaultColumnWidth
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
    private var windowToolbar: some View {
        HStack(spacing: 10) {
            Label("완성본 미리보기", systemImage: "eye")
                .font(.headline)
            if model.rows.isEmpty {
                Text("파일을 올리고 ‘완성본 미리보기’를 누르면 채워집니다.")
                    .font(.body).foregroundStyle(.secondary)
            } else {
                summaryChips
            }
            Spacer()
            selectionActions
            if !model.rows.isEmpty { viewOptions }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    @ViewBuilder
    private var summaryChips: some View {
        Text("전체 \(model.rows.count)행"
             + (visibleRows.count == model.rows.count ? "" : " 중 \(visibleRows.count)행 표시")
             + " · OK \(model.checked.count)/\(model.columns.count)컬럼")
            .font(.body).foregroundStyle(.secondary)
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
                .help("아직 결정하지 못한 값이 남은 컬럼: "
                      + model.needsWorkColumns.map(\.rawValue).joined(separator: ", "))
        }
        if !model.confirmedRows.isEmpty {
            Label("확정 \(model.confirmedRows.count) / \(model.rows.count)행",
                  systemImage: "checkmark.seal.fill")
                .font(.body.weight(.medium)).foregroundStyle(.green)
                .help("행 왼쪽의 동그라미를 눌러 ‘다 봤다’고 표시한 행 수입니다.")
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
            Label("보는 중: \(f.rawValue)", systemImage: "eye.fill")
                .font(.body.weight(.medium))
                .foregroundStyle(Color.accentColor)
                .lineLimit(1)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Capsule().fill(Color.accentColor.opacity(0.14)))
                .help("표에서 파란 기둥으로 표시된 컬럼입니다.")
        }
    }

    @ViewBuilder
    private var viewOptions: some View {
        Toggle(isOn: $showColors) { Text("색 표시") }
            .toggleStyle(.checkbox)
            .fixedSize()
            .help("파일 색·컬럼 상태 색을 켜고 끕니다.")
        Toggle(isOn: $improvedOnly) { Text("개선된 행만") }
            .toggleStyle(.checkbox)
            .fixedSize()
            .help("정리로 값이 바뀐 행만 봅니다.")
        Toggle(isOn: $unconfirmedOnly) { Text("확정 안 한 행만") }
            .toggleStyle(.checkbox)
            .fixedSize()
            .help("아직 확정 표시를 안 한 행만 봅니다.")
        if !model.duplicateRows.isEmpty {
            Toggle(isOn: Binding(get: { model.showDuplicatesOnly },
                                 set: { model.showDuplicatesOnly = $0 })) {
                Text("중복만 (\(model.duplicateRows.count))")
            }
            .toggleStyle(.checkbox)
            .fixedSize()
            .help("앞줄에 같은 사람이 이미 있는 행만 봅니다. 지울지는 직접 정하세요.")
        }
        Button { copyTable() } label: {
            Label("표 복사", systemImage: "doc.on.doc")
        }
        .help("지금 보이는 표를 탭 구분으로 복사합니다 — 엑셀·구글 시트에 그대로 붙습니다.")
        TextField("값 검색…", text: $query)
            .textFieldStyle(.roundedBorder)
            .frame(width: 180)
    }

    var body: some View {
        VStack(spacing: 0) {
            windowToolbar

            Divider()

            if model.rows.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "tray").font(.system(size: 28)).foregroundStyle(.tertiary)
                    Text("아직 보여줄 데이터가 없습니다.")
                        .font(.body).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView([.horizontal, .vertical]) {
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                        Section {
                            ForEach(visibleRows, id: \.1.id) { i, row in
                                HStack(spacing: 0) {
                                    rowHeadCell(i)
                                    ForEach(model.columns, id: \.self) { c in
                                        bodyCell(c, row: row, at: i)
                                    }
                                }
                                .background(model.isConfirmed(i) ? Color.green.opacity(0.10) : .clear)
                                .background(showColors ? (model.fileTint(row: i)?.opacity(0.14) ?? .clear) : .clear)
                                Divider()
                            }
                        } header: {
                            HStack(spacing: 0) {
                                Text(model.rowFiles.isEmpty ? "확정 · 행" : "확정 · 행 · 어느 파일에서 왔나")
                                    .font(.body.weight(.semibold)).foregroundStyle(.secondary)
                                    .frame(width: model.rowFiles.isEmpty ? 82 : 215, alignment: .leading)
                                    .padding(.horizontal, 8).padding(.vertical, 6)
                                ForEach(Array(model.columns.enumerated()), id: \.element) { idx, c in
                                    headerCell(c, number: idx + 1)
                                }
                            }
                            .background(Color(nsColor: .underPageBackgroundColor))
                        }
                    }
                }
                Divider()
                legendBar
            }
        }
        .frame(minWidth: 720, minHeight: 420)
        .background(NonRestorableWindow())
        .sheet(item: $editing) { editSheet($0) }
        // 앱을 켤 때 저절로 뜨는(복원되는) 창은 닫는다 — 버튼으로 열었을 때만 남는다.
        // onAppear 시점엔 아직 창이 다 뜨지 않아 dismiss가 먹지 않을 수 있어 다음 차례로 미룬다.
        .onAppear {
            guard !model.openedByUser else { return }
            DispatchQueue.main.async {
                if model.openedByUser { return }
                dismiss()
                NSApp.windows.first { $0.title == PreviewWindowView.windowTitle }?.close()
            }
        }
    }

    /// 표의 셀 한 칸. 컬럼 상태가 배경으로 내려오고, 개선된 값은 파란 굵은 글씨,
    /// 지금 보는 열은 좌우 세로선으로 기둥처럼 이어진다.
    private func bodyCell(_ c: UnifiedColumn, row: ApplicantRow, at i: Int) -> some View {
        let improved = model.diff[i]?.contains(c) ?? false
        let focused = model.focused == c
        let picked = model.selection.contains(c)
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
            .background(showColors ? model.cellTint(c, improved: improved) : .clear)
            .background(picked ? Color.accentColor.opacity(0.07) : .clear)
            .background(focused ? Color.accentColor.opacity(0.12) : .clear)
            .overlay(alignment: .leading) { focusEdge(focused) }
            .overlay(alignment: .trailing) { focusEdge(focused) }
            .help(improved
                  ? "개선됨\n이전: \(i < model.baselineRows.count ? model.baselineRows[i][c] : "")\n이후: \(value)"
                  : value)
            .contextMenu { cellMenu(c, value) }
    }

    /// 셀에서 바로 할 수 있는 일 — 복사와 값 고치기.
    @ViewBuilder
    private func cellMenu(_ c: UnifiedColumn, _ value: String) -> some View {
        Button("값 고치기…") {
            editText = value
            editing = EditTarget(column: c, value: value)
        }
        .disabled(value.isEmpty)
        Divider()
        Button("이 값 복사") { copyToClipboard(value) }
            .disabled(value.isEmpty)
        Button("‘\(c.rawValue)’ 열 전체 복사") {
            copyToClipboard(model.rows.map { $0[c] }.joined(separator: "\n"))
        }
        Button("표 전체 복사 (붙여넣기용)") { copyTable() }
    }

    private func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// 지금 보이는 표를 탭으로 구분해 복사 — 엑셀·시트에 그대로 붙습니다.
    private func copyTable() {
        var lines: [String] = []
        lines.append((["행", "출처"] + model.columns.map(\.rawValue)).joined(separator: "\t"))
        for (i, row) in visibleRows {
            let cells = model.columns.map { row[$0].replacingOccurrences(of: "\t", with: " ") }
            lines.append((["\(i + 1)", model.fileLabel(row: i)] + cells).joined(separator: "\t"))
        }
        copyToClipboard(lines.joined(separator: "\n"))
    }

    /// 값 고치기 창 — 같은 값이 여러 행에 있으면 몇 행이 함께 바뀌는지 알려 준다.
    private func editSheet(_ target: EditTarget) -> some View {
        let affected = model.rows.filter { $0[target.column] == target.value }.count
        return VStack(alignment: .leading, spacing: 12) {
            Text("‘\(target.column.rawValue)’ 값 고치기")
                .font(.title2.weight(.bold))
            HStack(spacing: 8) {
                Text(target.value)
                    .font(.body)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))
                Image(systemName: "arrow.right").foregroundStyle(.secondary)
                TextField("새 값", text: $editText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 260)
            }
            Text(affected > 1
                 ? "이 컬럼에서 ‘\(target.value)’인 \(affected)행이 함께 바뀝니다."
                 : "이 값 1행이 바뀝니다.")
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
                if model.duplicateRows.contains(i) {
                Text("중복")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Capsule().fill(Color.orange.opacity(0.16)))
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
    private func headerCell(_ c: UnifiedColumn, number: Int) -> some View {
        let st = model.status(c)
        let isFocused = model.focused == c
        let split = model.splitColumns.contains(c)
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
                Text("\(number)")
                    .font(.body.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 16, alignment: .trailing)
                Image(systemName: st.icon)
                    .font(.body)
                    .foregroundStyle(showColors ? st.tint : .secondary)
                Text(c.rawValue)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1).truncationMode(.tail)
                if let badge = st.badge {
                    Text(badge)
                        .font(.body.weight(.bold))
                        .foregroundStyle(Color.orange)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Capsule().fill(Color.orange.opacity(0.20)))
                }
            }
            // 아직 한 칸으로 안 합쳐진 컬럼 — 인라인 미리보기와 같은 둘째 줄.
            if isFocused {
                Text("지금 볼 컬럼")
                    .font(.body).foregroundStyle(Color.accentColor)
                    .padding(.leading, 20)
            } else if model.emptyColumns.contains(c) {
                Text("비어 있음 — 채울 칸을 골라 주세요")
                    .font(.body).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.tail)
                    .padding(.leading, 20)
            } else if let hint = model.pairHints[c] {
                HStack(spacing: 4) {
                    ownerDots(c)
                    Text(hint)
                        .font(.body).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.tail)
                }
                .padding(.leading, 20)
            } else if model.fileNames.count > 1, !(model.columnOwners[c] ?? []).isEmpty {
                HStack(spacing: 4) {
                    ownerDots(c)
                    Text("모든 파일에 있음")
                        .font(.body).foregroundStyle(.secondary)
                }
                .padding(.leading, 20)
            }
        }
        .frame(width: width(c), height: 42, alignment: .leading)
        .padding(.horizontal, 8).padding(.vertical, 6)
        .overlay(alignment: .top) {
            if picked { Rectangle().fill(Color.accentColor).frame(height: 3) }
        }
        // 오른쪽 끝을 잡고 끌면 폭이 바뀐다.
        .overlay(alignment: .trailing) { widthHandle(c) }
        .contextMenu {
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
              + (isFocused ? "\n지금 검토 중인 컬럼입니다." : ""))
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
            Button { requestClean() } label: {
                Label("데이터 정리하기", systemImage: "wand.and.stars")
            }
            .buttonStyle(.borderedProminent)
            .help("고른 컬럼의 값 형식을 통일하러 갑니다.")
            Button("선택 해제") { model.selection = [] }
                .controlSize(.small)
        } else if !model.rows.isEmpty {
            Text("컬럼 이름 옆 네모를 체크하면 정리·합치기를 할 수 있어요")
                .font(.body).foregroundStyle(.secondary)
        }
    }

    private func requestClean() {
        let cols = model.columns.filter { model.selection.contains($0) }
        guard !cols.isEmpty else { return }
        model.request = .clean(cols)
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
            .help("끌어서 폭 바꾸기 — 오른쪽 클릭하면 기본으로 되돌립니다.")
    }

    /// 머리글 배경 — 상태색이 먼저, 그다음 ‘어느 파일에서 온 열인지’ 색.
    private func headerTint(_ c: UnifiedColumn, _ st: ColumnWorkStatus) -> Color {
        if st.needsWork { return .orange.opacity(0.14) }
        if model.checked.contains(c) { return .green.opacity(0.14) }
        if let t = model.ownerTint(c) { return t.opacity(0.22) }
        return model.splitColumns.contains(c) ? .orange.opacity(0.08) : .clear
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
            if !model.splitColumns.isEmpty {
                legendItem("square.dashed", .orange, "아직 안 합쳐진 컬럼")
            }
            if model.fileNames.count > 1 {
                HStack(spacing: 4) {
                    Circle().fill(Color.secondary.opacity(0.35)).frame(width: 8, height: 8)
                    Text("열 배경·점 = 그 컬럼이 들어 있는 파일")
                        .font(.body).foregroundStyle(.secondary)
                }
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
        .background(Color(nsColor: .underPageBackgroundColor))
    }

    private func legendItem(_ icon: String, _ tint: Color, _ label: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.body).foregroundStyle(tint)
            Text(label).font(.body).foregroundStyle(.secondary)
        }
    }
}

/// Body for a derived column: just the explanation.
struct NoteBody: View {
    let note: String
    var body: some View {
        Text(note)
            .font(.body).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
