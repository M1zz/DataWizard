import SwiftUI
import UniformTypeIdentifiers

/// Holds the pending auto-save work item so rapid edits coalesce into one write.
/// A reference type kept in @State so it survives View re-creation.
final class SaveDebouncer {
    var work: DispatchWorkItem?
}

struct ContentView: View {
    enum Stage { case files, columns, review, result }
    /// 검토 화면의 두 보기: 결정할 일만(todo) vs 전체 컬럼(all).
    enum ReviewTab: String, CaseIterable, Identifiable {
        case todo = "결정 TODO"
        case all  = "전체 컬럼"
        var id: String { rawValue }
    }
    /// 컬럼 고르기 진입 시 첫 갈림길의 선택 결과.
    /// nil = 아직 안 고름(갈림길 화면), withTemplate = 기존 통합본에 맞춰 채우기,
    /// fromScratch = 남길 컬럼을 직접 골라 새 틀 만들기.
    enum ColumnMode { case withTemplate, fromScratch }

    @State private var inputs: [MergeInput] = []
    @State private var plans: [FilePlan] = []
    @State private var stage: Stage = .files
    @State private var reviewTab: ReviewTab = .todo
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
    @State private var referenceName: String?
    @State private var referenceColumns: Set<UnifiedColumn> = []   // 참조에서 인식된 컬럼
    @State private var referenceUnmatched: [String] = []           // 스키마에 없던 헤더
    @State private var detailColumn: UnifiedColumn?
    @State private var configColumn: UnifiedColumn?
    @State private var regexColumn: UnifiedColumn?
    @State private var mappingColumn: UnifiedColumn?

    @State private var result: MergeResult?
    @State private var errorMessage: String?
    @State private var excludeRemoved = false
    @State private var isPreparing = false
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

    var body: some View {
        Group {
            switch stage {
            case .files:   filesStage
            case .columns: columnsStage
            case .review:  reviewStage
            case .result:  resultStage
            }
        }
        .frame(minWidth: 820, minHeight: 580)
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(item: $detailColumn) { col in detailSheet(col) }
        .sheet(item: $configColumn) { col in
            ColumnSourceSheet(column: col, plans: $plans, onClose: { configColumn = nil })
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
        // 이전 세션이 있으면 파일 화면에서 이어서 하기를 제안.
        .onAppear { if resumable == nil { resumable = SessionStore.load() } }
        // 작업 상태가 바뀔 때마다 (debounce) 자동 저장 — 언제 멈춰도 이어서 가능.
        .onChange(of: valueMap) { _ in scheduleSave() }
        .onChange(of: allowedValues) { _ in scheduleSave() }
        .onChange(of: typeOverride) { _ in scheduleSave() }
        .onChange(of: formatChoice) { _ in scheduleSave() }
        .onChange(of: customFormat) { _ in scheduleSave() }
        .onChange(of: checked) { _ in scheduleSave() }
        .onChange(of: includedColumns) { _ in scheduleSave() }
        .onChange(of: phoneTemplate) { _ in scheduleSave() }
        .onChange(of: referenceName) { _ in scheduleSave() }
        .onChange(of: stage) { _ in scheduleSave() }
        // 창을 내리거나 앱을 벗어나는 순간 즉시 저장.
        .onChange(of: scenePhase) { phase in if phase != .active { saveNow() } }
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
                    Text("데이터 마법사")
                        .font(.system(.largeTitle, design: .rounded).weight(.bold))
                    Text("흩어진 지원 파일들을 추가하면, 완성될 컬럼과 그 안의 값을 하나씩 확인한 뒤 하나의 명단으로 만듭니다.")
                        .font(.callout)
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
                        .font(.caption)
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
                        .font(.caption).foregroundStyle(.secondary)
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

    /// 컬럼 선택 화면에 보여줄 전체 후보 — 스키마 73컬럼을 순서대로.
    /// 참조가 있으면 참조 컬럼을 맨 위로, 없으면 데이터 있는 컬럼을 위로 모아
    /// 인지부하를 줄인다. (각 그룹 안에서는 스키마 순서를 유지.)
    private var columnCandidates: [UnifiedColumn] {
        func rank(_ c: UnifiedColumn) -> Int {
            if referenceColumns.contains(c) { return 0 }
            if dataColumns.contains(c) { return 1 }
            return 2
        }
        return UnifiedColumn.allCases.enumerated()
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

    /// 첫 갈림길: 맞출 통합본(틀)이 이미 있는지 묻는다.
    /// 있으면 그 틀 구성에 데이터를 빠짐없이 채우고(참조 로드 → 바로 검토),
    /// 없으면 남길 컬럼을 직접 골라 새 틀을 만든다.
    private var columnForkView: some View {
        ScrollView {
            VStack(spacing: 28) {
                VStack(spacing: 10) {
                    Image(systemName: "square.grid.3x3.topleft.filled")
                        .font(.system(size: 40))
                        .foregroundStyle(Color.accentColor)
                    Text("맞출 통합본 틀이 있으신가요?")
                        .font(.system(.largeTitle, design: .rounded).weight(.bold))
                        .multilineTextAlignment(.center)
                    Text("이미 완성해 둔 통합본이 있으면 그 컬럼 구성 그대로 이번 데이터를 빠짐없이 채워 넣고, 없으면 어떤 컬럼을 남길지 골라 새 틀을 만듭니다.")
                        .font(.callout).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(alignment: .top, spacing: 16) {
                    forkCard(icon: "doc.on.doc.fill",
                             title: "네, 기존 통합본이 있어요",
                             detail: "완성본 파일을 불러와 같은 컬럼 구성에 이번 데이터를 빠짐없이 채웁니다.",
                             cta: "완성본 불러오기…",
                             prominent: true,
                             action: chooseTemplate)
                    forkCard(icon: "sparkles",
                             title: "아니요, 새로 만들게요",
                             detail: "남길 컬럼을 직접 골라 새 통합본 틀을 만듭니다.",
                             cta: "컬럼 직접 고르기",
                             prominent: false,
                             action: { columnMode = .fromScratch })
                }
                .frame(maxWidth: 620)

                if let errorMessage { errorLabel(errorMessage).frame(maxWidth: 520) }

                Button("← 파일") { backToFiles() }
                    .controlSize(.large)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: 680)
            .padding(40)
            .frame(maxWidth: .infinity)
        }
    }

    /// 갈림길의 큰 선택 카드 하나.
    private func forkCard(icon: String, title: String, detail: String,
                          cta: String, prominent: Bool,
                          action: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 30))
                .foregroundStyle(prominent ? Color.accentColor : Color.secondary)
            Text(title).font(.title3.weight(.bold))
                .fixedSize(horizontal: false, vertical: true)
            Text(detail).font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Group {
                if prominent {
                    Button(action: action) {
                        Text(cta).fontWeight(.semibold).frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    Button(action: action) {
                        Text(cta).fontWeight(.semibold).frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
            }
            .controlSize(.large)
        }
        .padding(20)
        .frame(maxWidth: .infinity, minHeight: 220, alignment: .topLeading)
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
                Text("선택 \(includedColumns.count) / \(UnifiedColumn.allCases.count)개")
                    .font(.headline).monospacedDigit()
                Spacer()
                Button("데이터 있는 것만") { includedColumns = dataColumns }
                    .help("값이 실제로 들어 있는 컬럼만 남깁니다. 빈 자리 컬럼은 제외돼요.")
                Button("전체 선택") { includedColumns = Set(UnifiedColumn.allCases) }
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
                        .font(.callout.weight(.medium))
                        .lineLimit(1).truncationMode(.middle)
                    Text("컬럼 \(referenceColumns.count)개를 이 구성으로 맞췄어요"
                         + (referenceUnmatched.isEmpty ? ""
                            : " · 못 알아본 헤더 \(referenceUnmatched.count)개"))
                        .font(.caption).foregroundStyle(.secondary)
                        .help(referenceUnmatched.isEmpty ? ""
                              : "스키마에 없는 헤더:\n" + referenceUnmatched.joined(separator: "\n"))
                } else {
                    Text("이전 완성본으로 컬럼 맞추기")
                        .font(.callout.weight(.medium))
                    Text("예: 2분기 보고서를 넣으면 7·8·9월 데이터도 같은 컬럼 구성으로 남깁니다.")
                        .font(.caption).foregroundStyle(.secondary)
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
                        .font(.caption)
                        .foregroundStyle(status.hasData ? Color.secondary : Color.orange)
                }
                Spacer(minLength: 8)
                if referenceColumns.contains(col) {
                    Text("참조")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Capsule().fill(Color.accentColor.opacity(0.12)))
                }
                if !status.hasData {
                    Text("빈 컬럼")
                        .font(.caption2.weight(.semibold))
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

    // MARK: - Stage 2: column-by-column review with checkboxes

    /// 검토·미리보기에 실제로 나타나는 컬럼 — 데이터가 있는 최종 컬럼 중
    /// 사용자가 남기기로 선택한 것들.
    private var visibleFinalColumns: [UnifiedColumn] {
        finalColumns.filter { includedColumns.contains($0) }
    }
    private var visibleReviews: [ColumnReview] {
        reviews.filter { includedColumns.contains($0.column) }
    }
    /// 내보내기에 쓸 컬럼 — 스키마(73컬럼) 순서를 지키며 선택된 것만.
    private var includedOrdered: [UnifiedColumn] {
        UnifiedColumn.allCases.filter { includedColumns.contains($0) }
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

    /// 병합 가능 조건: 남은 미해결 결정이 없다.
    private var canMerge: Bool { openDecisions.isEmpty }

    private var reviewStage: some View {
        VStack(spacing: 0) {
            reviewToolbar
            Divider()
            reviewTabBar
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    switch reviewTab {
                    case .todo:
                        decisionProgressHeader
                        if decisionReviews.isEmpty {
                            emptyDecisionsCard
                        } else {
                            ForEach(decisionReviews) { review in
                                reviewSection(review)
                            }
                        }
                    case .all:
                        progressHeader
                        ForEach(visibleReviews) { review in
                            reviewSection(review)
                        }
                    }
                }
                .padding(24)
            }
        }
        .onChange(of: checked) { _ in refreshPreview() }
        .onChange(of: valueMap) { _ in refreshPreview() }
        .onChange(of: phoneTemplate) { _ in refreshPreview() }
    }

    /// 결정 TODO / 전체 컬럼 전환 탭. 각 탭에 남은 항목 배지를 붙여 준다.
    private var reviewTabBar: some View {
        HStack(spacing: 0) {
            Picker("", selection: $reviewTab) {
                Text(openDecisions.isEmpty
                     ? "결정 TODO ✓"
                     : "결정 TODO (\(openDecisions.count))").tag(ReviewTab.todo)
                Text("전체 컬럼 \(visibleFinalColumns.count)").tag(ReviewTab.all)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 360)
            Spacer()
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 10)
    }

    /// 결정할 게 하나도 없을 때(모두 자동 처리됨) 보여주는 안내.
    private var emptyDecisionsCard: some View {
        VStack(spacing: 8) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 34)).foregroundStyle(.green)
            Text("따로 결정할 항목이 없어요")
                .font(.title3.weight(.semibold))
            Text("전화번호·생년월일·매핑 값이 모두 자동으로 정리됐습니다.\n바로 합치거나, ‘전체 컬럼’ 탭에서 원하는 값을 더 다듬을 수 있어요.")
                .font(.body).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    /// 결정 TODO 탭의 진행 헤더: 해결한 결정 수 / 전체 + 진행 막대.
    private var decisionProgressHeader: some View {
        let total = decisionReviews.count
        let done = total - openDecisions.count
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("결정해야 할 일")
                        .font(.title3.weight(.bold))
                    Text(openDecisions.isEmpty
                         ? "모든 결정을 마쳤어요. 이제 ‘이대로 합치기’를 누르면 완성본이 만들어집니다."
                         : "판단이 필요한 항목만 모았어요. 값을 고치거나 ‘이대로 확정’을 체크해 하나씩 지워 나가세요.")
                        .font(.body).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Text("\(done) / \(total) 해결")
                    .font(.headline).monospacedDigit()
                    .foregroundStyle(openDecisions.isEmpty ? Color.green : Color.primary)
            }
            ProgressView(value: total == 0 ? 1 : Double(done), total: total == 0 ? 1 : Double(total))
                .tint(openDecisions.isEmpty ? .green : .accentColor)
        }
        .padding(.bottom, 8)
    }

    private func reviewSection(_ review: ColumnReview) -> some View {
        ReviewSection(title: review.column.rawValue,
                      subtitle: subtitle(for: review),
                      isChecked: checkBinding(review.column),
                      needsAttention: openCount(review) > 0,
                      resolveCount: autoFixCount(review),
                      onResolve: { applyAutoFix(review) },
                      typeControl: review.kind == .derived ? nil : typeControl(for: review),
                      onDetail: { detailColumn = review.column },
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
                    Section("형식") {
                        ForEach(FormatPreset.allCases) { p in
                            Button {
                                setFormat(p, for: review.column)
                            } label: {
                                Label("\(p.rawValue)  \(p.hint)",
                                      systemImage: p == effectiveFormat(review) ? "checkmark" : "circle")
                            }
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: type.symbol)
                    Text(type == .format ? "포맷 · \(effectiveFormat(review).rawValue)" : type.rawValue)
                    if isAuto {
                        Text("자동").font(.caption2)
                            .foregroundStyle(tint.opacity(0.9))
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Capsule().fill(tint.opacity(0.16)))
                    }
                }
                .font(.caption.weight(.medium))
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

    private var progressHeader: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("컬럼별 검토")
                    .font(.title3.weight(.bold))
                Text("각 컬럼의 값을 확인하고 ‘이대로 OK’를 체크하세요. 모두 체크하면 합칠 수 있어요.")
                    .font(.body).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 6) {
                Text("\(checked.intersection(visibleFinalColumns).count) / \(visibleFinalColumns.count) 완료")
                    .font(.headline).monospacedDigit()
                Button(allChecked ? "모두 해제" : "모두 이대로 OK") { toggleAll() }
            }
        }
        .padding(.bottom, 4)
    }

    private var reviewToolbar: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("검토").font(.title2.weight(.bold))
                Text(canMerge
                     ? "\(visibleFinalColumns.count)개 컬럼 · 결정 완료 — 합칠 준비가 됐어요"
                     : "\(visibleFinalColumns.count)개 컬럼 · 결정할 일 \(openDecisions.count)건 남음")
                    .font(.body).foregroundStyle(.secondary)
            }
            Spacer()
            if let errorMessage { errorLabel(errorMessage).frame(maxWidth: 300) }
            Button("← 컬럼 고르기") { stage = .columns }
            Button {
                refreshPreview()
                openWindow(id: "preview")
            } label: {
                Label("미리보기", systemImage: "macwindow.badge.plus")
            }
            .help("합쳐진 파일의 현재 상태를 별도 윈도우로 봅니다. 정리할수록 개선된 셀이 표시됩니다.")
            Button(action: runMerge) {
                HStack {
                    if isRunning { ProgressView().controlSize(.small) }
                    Text(isRunning ? "합치는 중…" : "이대로 합치기").fontWeight(.semibold)
                }
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .disabled(!canMerge || isRunning)
            .help(canMerge ? "병합을 시작합니다"
                           : "결정 TODO의 미해결 항목 \(openDecisions.count)건을 먼저 해결해야 합칠 수 있어요.")
        }
        .padding(20)
    }

    // MARK: - Per-column review body

    @ViewBuilder
    private func body(for review: ColumnReview) -> some View {
        if review.kind == .derived {
            NoteBody(note: review.note)
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
        if let result {
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
                            .font(.callout)
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
                    .font(.caption).foregroundStyle(.secondary)
            }
            // 검증 요약: 이 도구가 수정한 셀의 전체 개수. 보고서와 1:1로 대조 가능.
            Label(r.changes.isEmpty
                  ? "값 수정 0건 — 모든 값이 원본 그대로 저장되었습니다."
                  : "값 수정 \(r.changes.count)건 — 전체 내역이 변경 보고서에 기록되어 있습니다.",
                  systemImage: r.changes.isEmpty ? "checkmark.seal.fill" : "doc.text.magnifyingglass")
                .font(.callout.weight(.medium))
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
                            .font(.caption.weight(.semibold))
                            .frame(width: columnWidth(c), alignment: .leading)
                            .padding(.horizontal, 8).padding(.vertical, 6)
                    }
                }
                .background(Color(nsColor: .underPageBackgroundColor))

                ForEach(Array(r.rows.prefix(300))) { row in
                    HStack(spacing: 0) {
                        ForEach(cols, id: \.self) { c in
                            Text(row[c])
                                .font(.caption)
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
            .font(.callout).foregroundStyle(.red)
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

    /// 이전 완성본을 참조 파일로 불러와, 그 헤더로 남길 컬럼을 맞춘다.
    /// 완성본의 헤더는 최종 스키마 컬럼명과 같으므로 이름으로 대응시킨다.
    /// 갈림길에서 ‘틀 있음’을 골랐을 때: 완성본을 불러오고, 성공하면 그 틀
    /// 구성이 곧 최종본이므로 컬럼 선택을 건너뛰고 바로 값 검토로 넘어간다.
    private func chooseTemplate() {
        guard loadReference() else { return }   // 취소·오류면 갈림길에 머무름
        columnMode = .withTemplate
        proceedToReview()
    }

    /// 갈림길에서 파일 단계로 되돌아갈 때 선택 상태를 초기화한다.
    private func backToFiles() {
        stage = .files
        columnMode = nil
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
                headers = try XLSXReader.readTable(at: url, headerRowIndex: 0).headers
            } else {
                headers = try CSVParser.readTable(at: url).headers
            }
            return applyReference(headers: headers, name: url.lastPathComponent)
        } catch {
            errorMessage = "\(url.lastPathComponent): \(error.localizedDescription)"
            return false
        }
    }

    /// 참조 헤더를 스키마 컬럼에 대응시켜 남길 컬럼을 설정한다. 대응된 컬럼은
    /// (현재 파일에 값이 없어도) 참조와 같은 구성을 위해 그대로 포함한다.
    @discardableResult
    private func applyReference(headers: [String], name: String) -> Bool {
        let byName = Dictionary(UnifiedColumn.allCases.map {
            ($0.rawValue.trimmingCharacters(in: .whitespacesAndNewlines), $0)
        }, uniquingKeysWith: { first, _ in first })
        var matched: Set<UnifiedColumn> = []
        var unmatched: [String] = []
        for h in headers {
            let key = h.trimmingCharacters(in: .whitespacesAndNewlines)
            if key.isEmpty { continue }
            if let col = byName[key] { matched.insert(col) }
            else { unmatched.append(h) }
        }
        guard !matched.isEmpty else {
            errorMessage = "‘\(name)’에서 알아볼 수 있는 컬럼을 찾지 못했어요. 최종 결과물 형식의 파일인지 확인해 주세요."
            return false
        }
        errorMessage = nil
        referenceName = name
        referenceColumns = matched
        referenceUnmatched = unmatched
        includedColumns = matched      // 참조 구성에 맞춰 남길 컬럼을 재설정
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
                        refreshPreview()
                        openWindow(id: "preview")
                    } else {
                        checked.remove(col)
                    }
                })
    }

    /// Rebuild the preview-window model from the current plans + valueMap.
    /// Same engine as the real merge, so the preview IS the future output.
    /// Diffs against the baseline (정리 전 병합본) to show what improved.
    private func refreshPreview() {
        let engine = MergeEngine(plans: plans, valueMap: valueMap, phoneTemplate: phoneTemplate)
        let rows = (try? engine.run())?.rows ?? []

        if preview.baselineRows.isEmpty {
            // 기준선은 항상 기본 포맷 — 포맷 변경도 ‘개선’으로 표시되도록.
            let raw = MergeEngine(plans: plans, valueMap: [:], phoneTemplate: Normalizer.defaultPhoneTemplate)
            preview.baselineRows = (try? raw.run())?.rows ?? []
        }
        let cols = visibleFinalColumns
        var diff: [Int: Set<UnifiedColumn>] = [:]
        var n = 0
        for (i, row) in rows.enumerated() where i < preview.baselineRows.count {
            for c in cols where row[c] != preview.baselineRows[i][c] {
                diff[i, default: []].insert(c)
                n += 1
            }
        }
        preview.rows = rows
        preview.diff = diff
        preview.diffCount = n
        preview.columns = cols
        preview.checked = checked
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
        refreshPreview()
        openWindow(id: "preview")
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
                separators: Dictionary(uniqueKeysWithValues: p.separators.map { ($0.key.rawValue, $0.value) }))
        }
        let stageStr: String
        switch stage {
        case .columns: stageStr = "columns"
        case .review:  stageStr = "review"
        default:       stageStr = "files"
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
            files: files)
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
        DispatchQueue.global(qos: .utility).async { SessionStore.save(snap) }
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
                            sources: sources, separators: seps)
        }
        plans = restored
        inputs = restored.map { MergeInput(url: $0.url, channel: $0.channel) }
        finalColumns = ColumnReviewBuilder.finalColumns(in: restored)
        reviews = ColumnReviewBuilder.reviews(in: restored)
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
        resumable = nil
        preview.reset()
        errorMessage = nil

        // 복원 시에는 이미 갈림길을 지나 컬럼을 고른 상태이므로, 참조 유무로
        // 모드를 되살려 갈림길 화면을 다시 띄우지 않는다.
        columnMode = referenceColumns.isEmpty ? .fromScratch : .withTemplate

        switch s.stage {
        case "review":
            stage = .review
            refreshPreview()
            openWindow(id: "preview")
        case "columns":
            stage = .columns
        default:
            stage = .files
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
        let engine = MergeEngine(plans: plans, valueMap: valueMap, phoneTemplate: phoneTemplate)
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let r = try engine.run()
                DispatchQueue.main.async {
                    self.result = r
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

extension UnifiedColumn: Identifiable {
    public var id: String { rawValue }
}

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
                        .font(.subheadline).foregroundStyle(.secondary)
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
                                        .font(.subheadline.monospaced())
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
                                                .font(.subheadline).foregroundStyle(.orange)
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
                                            .font(.subheadline)
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
                                                        .font(.caption2)
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
                                            .font(.subheadline).monospacedDigit().foregroundStyle(.secondary)
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
                            .font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                            .padding(.horizontal, 16).padding(.vertical, 6)
                            .background(Color(nsColor: .windowBackgroundColor))
                        }
                    }
                }
            }
        }
        .frame(width: showsSource ? 1020 : 800, height: 580)
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
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
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
                    .font(.callout.weight(.medium))
                    .lineLimit(1).truncationMode(.middle)
                Text("\(input.channel.rawValue) (자동 감지)")
                    .font(.caption).foregroundStyle(.secondary)
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
    /// ⚠️ 아직 결정이 필요한가 — 접힌 카드에서 강조 테두리로 눈에 띄게.
    var needsAttention: Bool = false
    /// 추천값으로 한 번에 고칠 수 있는 값의 종 수 (0이면 자동 해결 버튼 숨김).
    var resolveCount: Int = 0
    /// 자동 해결 실행 (추천값 일괄 적용). resolveCount>0일 때만 쓰인다.
    var onResolve: (() -> Void)? = nil
    /// 헤더에 표시할 컬럼 타입 선택 메뉴 (파생 컬럼은 nil).
    var typeControl: AnyView? = nil
    var onDetail: (() -> Void)? = nil
    var onConfigure: (() -> Void)? = nil
    var onRegex: (() -> Void)? = nil
    var onMapping: (() -> Void)? = nil
    @ViewBuilder var content: () -> Content

    /// 접힘/펼침 — 기본은 접힘. 결정 항목을 큰 카드로 먼저 훑고 하나씩 펼친다.
    @State private var isExpanded = false

    private var hasActions: Bool {
        onDetail != nil || onConfigure != nil || onRegex != nil || onMapping != nil
    }

    private var accentColor: Color {
        isChecked ? .green : (needsAttention ? .orange : .accentColor)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if isExpanded && !isChecked {
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
                withAnimation(.easeInOut(duration: 0.18)) { isExpanded.toggle() }
            } label: {
                HStack(alignment: .center, spacing: 10) {
                    Image(systemName: isChecked ? "checkmark.circle.fill"
                                                : (isExpanded ? "chevron.down" : "chevron.right"))
                        .font(.body.weight(.semibold))
                        .foregroundStyle(isChecked ? Color.green : Color.secondary)
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(title)
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1).truncationMode(.tail).help(title)
                        Text(subtitle)
                            .font(.subheadline).foregroundStyle(.secondary)
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
                    .font(.subheadline.weight(.medium)).foregroundStyle(.green)
            } else if !isExpanded {
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
    }

    // 펼쳤을 때만 만들어지는 편집 본문 (액션 버튼 + content).
    private var bodyContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            if hasActions {
                HStack(spacing: 8) {
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

    var body: some View {
        let groupCount = Set(values.map { mapping[$0.value] ?? $0.value }).count
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("\(values.count)개 값 → \(groupCount)개로 통일")
                    .font(.subheadline).foregroundStyle(.secondary)
                if !allowed.isEmpty {
                    Label(outOfSet == 0
                          ? "정해둔 값으로만 고정됨 (\(allowed.count)종)"
                          : "정해둔 값으로만 고정됨 · 선택 필요 \(outOfSet)종",
                          systemImage: outOfSet == 0 ? "lock.fill" : "exclamationmark.triangle.fill")
                        .font(.subheadline.weight(.medium))
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
            .font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)

            ForEach(values) { dv in
                let canonical = mapping[dv.value] ?? dv.value
                let changed = canonical != dv.value
                let inSet = allowed.isEmpty || allowed.contains(canonical)
                HStack(spacing: 10) {
                    Text(dv.value)
                        .font(.body)
                        .frame(width: 240, alignment: .leading)
                        .lineLimit(1).truncationMode(.tail).help(dv.value)
                    Text("\(dv.count)")
                        .font(.subheadline).foregroundStyle(.secondary)
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
                                        .font(.subheadline)
                                }
                                .buttonStyle(.link)
                                .help("유사도가 가장 높은 허용 값입니다. 누르면 이 값으로 승인됩니다.")
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
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

    private var visible: [ProposedChange] {
        switch filter {
        case .all:     return proposals
        case .changed: return changedRows
        case .same:    return sameRows
        case .failed:  return failedRows
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !note.isEmpty {
                Text(note).font(.subheadline).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

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

            // 목표 포맷: 프리셋 메뉴 + 직접 입력 (샘플 번호를 원하는 모양으로)
            if let phoneTemplate {
                HStack(spacing: 8) {
                    Text("목표 포맷").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
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
                    } else {
                        Label("샘플 숫자(01012345678 또는 8210…)가 그대로 들어 있어야 해요",
                              systemImage: "exclamationmark.triangle.fill")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    Spacer()
                }
            }

            if visible.isEmpty {
                Text("해당하는 값이 없습니다.")
                    .font(.body).foregroundStyle(.secondary)
            } else {
                HStack(spacing: 10) {
                    Text("이전 값").frame(width: 220, alignment: .leading)
                    Text("건수").frame(width: 56, alignment: .trailing)
                    Text("제안 값 (‘\(targetLabel)’)").frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)

                ForEach(visible) { p in
                    proposalRow(p)
                }
            }
        }
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
                .font(.subheadline).monospacedDigit().foregroundStyle(.secondary)
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
                Text(note).font(.subheadline).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !samples.isEmpty {
                Text("예시 값")
                    .font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(Array(samples.enumerated()), id: \.offset) { _, value in
                    Text("• \(value)")
                        .font(.body)
                        .lineLimit(1).truncationMode(.tail).help(value)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if distinctCount > samples.count {
                    Text("외 \(distinctCount - samples.count)종")
                        .font(.subheadline).foregroundStyle(.tertiary)
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
            .font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)

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
                        .font(.subheadline).foregroundStyle(.secondary)
                        .frame(width: 48, alignment: .trailing)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(f.reason)
                            .font(.subheadline).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if f.fixable && !changed {
                            Button("추천: \(f.suggestion)") { mapping[f.value] = f.suggestion }
                                .buttonStyle(.link).font(.subheadline)
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
            header
            if isCustom { customField }
            if patternValid {
                if failures.isEmpty {
                    Label("모든 값이 형식에 맞습니다 (\(values.count)종).",
                          systemImage: "checkmark.seal.fill")
                        .font(.callout.weight(.medium)).foregroundStyle(.green)
                } else {
                    failureBox
                }
            } else if isCustom {
                Text("맞춰야 할 정규식을 입력하면, 형식에 안 맞는 값만 모아 보여줍니다.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "textformat.123").foregroundStyle(Color.accentColor)
            Text("형식: \(preset.rawValue)")
                .font(.body.weight(.medium))
            Text(isCustom ? (pattern.isEmpty ? "정규식 미입력" : pattern) : preset.hint)
                .font(.callout.monospaced()).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle)
            Spacer()
            if patternValid {
                Text("맞음 \(okCount) · 안 맞음 \(failures.count)")
                    .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
    }

    private var customField: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField("맞춰야 할 정규식 (예: \\d{4}-\\d{2}-\\d{2})", text: $customPattern)
                .textFieldStyle(.roundedBorder)
                .font(.body.monospaced())
            if !customPattern.isEmpty && !RegexCleaner.isValid(customPattern) {
                Label("정규식 형식이 올바르지 않습니다.", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.red)
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
            .font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)

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
                        .font(.subheadline).foregroundStyle(.secondary)
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
                    .font(.caption).foregroundStyle(.secondary)
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
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(RegexLibrary.presets) { preset in
                Toggle(isOn: Binding(
                    get: { selected.contains(preset.id) },
                    set: { if $0 { selected.insert(preset.id) } else { selected.remove(preset.id) } }
                )) {
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 8) {
                            Text(preset.name).font(.callout.weight(.medium))
                            Text(preset.pattern)
                                .font(.caption2.monospaced()).foregroundStyle(.tertiary)
                                .lineLimit(1).truncationMode(.tail)
                        }
                        Text("\(preset.summary)  \(preset.example)")
                            .font(.caption).foregroundStyle(.secondary)
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
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                TextField("패턴 (정규식)", text: $customPattern)
                    .textFieldStyle(.roundedBorder).font(.callout.monospaced())
                Image(systemName: "arrow.right").font(.caption2).foregroundStyle(.secondary)
                TextField("치환할 값 (비우면 삭제)", text: $customReplacement)
                    .textFieldStyle(.roundedBorder).font(.callout.monospaced())
                    .frame(width: 180)
            }
            if let customError {
                Label(customError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.red)
            }
        }
    }

    private var targetRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("목표 패턴 (선택) — 정리 후 이 형태가 아니면 ‘실패’로 표시")
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                ForEach(Self.targetPresets, id: \.label) { preset in
                    Button(preset.label) { targetPattern = preset.pattern }
                        .buttonStyle(.bordered).controlSize(.small)
                        .tint(targetPattern == preset.pattern ? .accentColor : .secondary)
                }
                Divider().frame(height: 16)
                TextField("패턴 (정규식)", text: $targetPattern)
                    .textFieldStyle(.roundedBorder).font(.callout.monospaced())
            }
            if let targetError {
                Label(targetError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.red)
            }
        }
    }

    @ViewBuilder
    private var failureSection: some View {
        if !targetPattern.isEmpty, targetError == nil {
            HStack {
                Label(failures.isEmpty ? "목표 패턴에 모두 일치" : "패턴 불일치(실패) \(failures.count)종",
                      systemImage: failures.isEmpty ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(failures.isEmpty ? Color.green : Color.orange)
                Spacer()
            }
            if !failures.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(failures) { c in
                        HStack(spacing: 8) {
                            Text(c.from.isEmpty ? "(빈 값)" : c.from)
                                .font(.callout)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .lineLimit(1).truncationMode(.middle).help(c.from)
                            Image(systemName: "arrow.right")
                                .font(.caption2).foregroundStyle(.secondary)
                            Text(c.to.isEmpty ? "(빈 값)" : c.to)
                                .font(.callout).foregroundStyle(.orange)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .lineLimit(1).truncationMode(.middle).help(c.to)
                            Text("\(c.count)")
                                .font(.caption).monospacedDigit().foregroundStyle(.secondary)
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
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Spacer()
            Text(activePresets.isEmpty ? "규칙을 선택하세요"
                 : "변경 \(changes.count)종 / 전체 \(total)종")
                .font(.caption).foregroundStyle(.secondary)
        }

        if !activePresets.isEmpty {
            if changes.isEmpty {
                Text("선택한 규칙으로 바뀌는 값이 없습니다.")
                    .font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(changes) { c in
                        HStack(spacing: 8) {
                            Text(c.from.isEmpty ? "(빈 값)" : c.from)
                                .font(.callout)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .lineLimit(1).truncationMode(.middle).help(c.from)
                            Image(systemName: "arrow.right")
                                .font(.caption2).foregroundStyle(.secondary)
                            Text(c.to.isEmpty ? "(빈 값)" : c.to)
                                .font(.callout)
                                .foregroundStyle(c.to.isEmpty ? .secondary : Color.accentColor)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .lineLimit(1).truncationMode(.middle).help(c.to)
                            Text("\(c.count)")
                                .font(.caption).monospacedDigit().foregroundStyle(.secondary)
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
                .font(.caption).foregroundStyle(.secondary)
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
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
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
                    Image(systemName: "checkmark").font(.caption2.weight(.bold)).foregroundStyle(.white)
                } else {
                    Text("\(index)").font(.caption2.weight(.bold))
                        .foregroundStyle(active ? .white : .secondary)
                }
            }
            Text(title)
                .font(.subheadline.weight(active ? .semibold : .regular))
                .foregroundStyle(active ? .primary : .secondary)
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("‘\(column.rawValue)’ — 여러 값을 하나로 모으기").font(.headline)
                Text("한 줄에 하나씩 ‘원본 값 → 모을 값’ 형태로 적거나 붙여넣으세요. 구분자는 탭·→·:·쉼표 모두 됩니다.")
                    .font(.caption).foregroundStyle(.secondary)
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
                .font(.callout.weight(.semibold))
                .foregroundStyle(done ? Color.green : Color.orange)
            Text("전체 \(values.count)종 · 매핑 \(coveredCount)종 · 규칙 \(parsed.pairs.count)개"
                 + (parsed.skipped.isEmpty ? "" : " · 못 읽은 줄 \(parsed.skipped.count)개"))
                .font(.caption).foregroundStyle(.secondary)
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
                        Text("\(label) 있음").font(.callout.weight(.medium))
                        Text("사양서의 공식 규칙 \(pairs.count)개를 한 번에 채웁니다. 채운 뒤 수정할 수 있어요.")
                            .font(.caption).foregroundStyle(.secondary)
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
                Text("모으기 규칙 (원본 → 모을 값)").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
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
                .font(.callout.monospaced())
                .padding(6)
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.secondary.opacity(0.25)))
            Text("예) 서울특별시 → 서울")
                .font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(16)
        .frame(maxWidth: .infinity)
    }

    private var previewPane: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("적용 결과 미리보기")
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Text("원본 값").frame(maxWidth: .infinity, alignment: .leading)
                Text("건수").frame(width: 44, alignment: .trailing)
                Text("→ 통일").frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.caption.weight(.semibold)).foregroundStyle(.secondary)

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(values) { dv in
                        let hit = lookup[dv.value]
                        HStack(spacing: 8) {
                            Text(dv.value.isEmpty ? "(빈 값)" : dv.value)
                                .font(.callout)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .lineLimit(1).truncationMode(.middle).help(dv.value)
                            Text("\(dv.count)")
                                .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                                .frame(width: 44, alignment: .trailing)
                            HStack(spacing: 4) {
                                Image(systemName: hit == nil ? "minus" : "arrow.right")
                                    .font(.caption2)
                                    .foregroundStyle(hit == nil ? Color.orange : Color.accentColor)
                                if let hit {
                                    Text(hit)
                                        .font(.callout)
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
                                            .font(.callout)
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
                    .font(.caption).foregroundStyle(.secondary)
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
                    .font(.caption).foregroundStyle(uncovered.isEmpty ? Color.secondary : Color.orange)
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
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button("닫기", action: onClose).keyboardShortcut(.defaultAction)
            }
            .padding(16)

            VStack(alignment: .leading, spacing: 6) {
                Text("컬럼 사이를 어떻게 이어 붙일까요?").font(.callout)
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
                Text(plan.wrappedValue.fileName).font(.callout.weight(.medium))
                    .lineLimit(1).truncationMode(.middle).help(plan.wrappedValue.fileName)
                Spacer()
                Text("→ \(previewValue(plan.wrappedValue).isEmpty ? "—" : previewValue(plan.wrappedValue))")
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.tail)
            }
            HStack(spacing: 8) {
                ForEach(0..<slotCount, id: \.self) { i in
                    if i > 0 {
                        Image(systemName: "plus").font(.caption2).foregroundStyle(.tertiary)
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

    func reset() {
        rows = []; baselineRows = []; diff = [:]; diffCount = 0
        columns = []; checked = []
    }
}

/// Standalone window: the merged file as it currently stands — all final
/// columns, improved cells highlighted, OK'd columns checked. Updates live
/// while the user cleans data in the main window.
struct PreviewWindowView: View {
    @ObservedObject var model = PreviewModel.shared
    @State private var query = ""
    @State private var improvedOnly = false

    /// (원본 행 번호, 행) — 검색·필터를 거쳐도 diff/이전값 조회용 인덱스 유지.
    private var visibleRows: [(Int, ApplicantRow)] {
        var rows = Array(model.rows.enumerated()).map { ($0.offset, $0.element) }
        if improvedOnly {
            rows = rows.filter { !(model.diff[$0.0]?.isEmpty ?? true) }
        }
        if !query.isEmpty {
            rows = rows.filter { _, row in
                model.columns.contains { row[$0].localizedCaseInsensitiveContains(query) }
            }
        }
        return rows
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Label("합쳐진 파일 미리보기", systemImage: "eye")
                    .font(.headline)
                if model.rows.isEmpty {
                    Text("파일을 추가하고 ‘컬럼 검토’로 이동하면 채워집니다.")
                        .font(.subheadline).foregroundStyle(.secondary)
                } else {
                    Text("전체 \(model.rows.count)행"
                         + (visibleRows.count == model.rows.count ? "" : " 중 \(visibleRows.count)행 표시")
                         + " · OK \(model.checked.count)/\(model.columns.count)컬럼")
                        .font(.subheadline).foregroundStyle(.secondary)
                    if model.diffCount > 0 {
                        Label("개선된 셀 \(model.diffCount)개", systemImage: "sparkles")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(Color.accentColor)
                            .help("정리 전 병합본과 비교해 값이 좋아진 셀 수입니다. 표에서 파란 배경으로 표시됩니다.")
                    }
                }
                Spacer()
                if !model.rows.isEmpty {
                    Toggle(isOn: $improvedOnly) { Text("개선된 행만") }
                        .toggleStyle(.checkbox)
                        .fixedSize()
                        .help("정리로 값이 바뀐 행만 봅니다.")
                    TextField("값 검색…", text: $query)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 200)
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 10)

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
                                    ForEach(model.columns, id: \.self) { c in
                                        let improved = model.diff[i]?.contains(c) ?? false
                                        Text(row[c])
                                            .font(.subheadline)
                                            .fontWeight(improved ? .medium : .regular)
                                            .foregroundStyle(improved ? Color.accentColor : .primary)
                                            .lineLimit(1).truncationMode(.tail)
                                            .frame(width: 150, alignment: .leading)
                                            .padding(.horizontal, 8).padding(.vertical, 4)
                                            .background(improved ? Color.accentColor.opacity(0.10) : .clear)
                                            .help(improved
                                                  ? "개선됨\n이전: \(i < model.baselineRows.count ? model.baselineRows[i][c] : "")\n이후: \(row[c])"
                                                  : row[c])
                                    }
                                }
                                Divider()
                            }
                        } header: {
                            HStack(spacing: 0) {
                                ForEach(model.columns, id: \.self) { c in
                                    HStack(spacing: 4) {
                                        Image(systemName: model.checked.contains(c)
                                              ? "checkmark.circle.fill" : "circle.dotted")
                                            .font(.caption)
                                            .foregroundStyle(model.checked.contains(c) ? Color.green : Color.secondary)
                                        Text(c.rawValue)
                                            .font(.subheadline.weight(.semibold))
                                            .lineLimit(1).truncationMode(.tail)
                                    }
                                    .frame(width: 150, alignment: .leading)
                                    .padding(.horizontal, 8).padding(.vertical, 6)
                                    .help(c.rawValue + (model.checked.contains(c) ? " — 검토 완료" : " — 검토 전"))
                                }
                            }
                            .background(Color(nsColor: .underPageBackgroundColor))
                        }
                    }
                }
            }
        }
        .frame(minWidth: 720, minHeight: 420)
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
