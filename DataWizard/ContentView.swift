import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    enum Stage { case files, review, result }

    @State private var inputs: [MergeInput] = []
    @State private var plans: [FilePlan] = []
    @State private var stage: Stage = .files

    // Column-centric review of the final output
    @State private var finalColumns: [UnifiedColumn] = []
    @State private var reviews: [ColumnReview] = []
    @State private var valueMap: [UnifiedColumn: [String: String]] = [:]
    // 매핑표가 적용된 컬럼의 허용 통일 값 목록 — 있으면 자유 입력 대신
    // 이 중 하나만 고를 수 있다 (오타·임의 값 차단).
    @State private var allowedValues: [UnifiedColumn: [String]] = [:]
    @State private var checked: Set<UnifiedColumn> = []
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

    var body: some View {
        Group {
            switch stage {
            case .files:  filesStage
            case .review: reviewStage
            case .result: resultStage
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
                        Text(isPreparing ? "불러오는 중…" : "컬럼 검토 →").fontWeight(.semibold)
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

    // MARK: - Stage 2: column-by-column review with checkboxes

    private var allChecked: Bool {
        !finalColumns.isEmpty && finalColumns.allSatisfy { checked.contains($0) }
    }

    private var reviewStage: some View {
        VStack(spacing: 0) {
            reviewToolbar
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    progressHeader
                    ForEach(reviews) { review in
                        reviewSection(review)
                    }
                }
                .padding(24)
            }
        }
        .onChange(of: checked) { _ in refreshPreview() }
        .onChange(of: valueMap) { _ in refreshPreview() }
        .onChange(of: phoneTemplate) { _ in refreshPreview() }
    }

    private func reviewSection(_ review: ColumnReview) -> some View {
        ReviewSection(title: review.column.rawValue,
                      subtitle: subtitle(for: review),
                      isChecked: checkBinding(review.column),
                      onDetail: { detailColumn = review.column },
                      onConfigure: review.kind == .derived ? nil
                        : { configColumn = review.column },
                      onRegex: review.kind == .derived ? nil
                        : { regexColumn = review.column },
                      onMapping: (review.kind == .category || review.kind == .freeText)
                        ? { mappingColumn = review.column } : nil) {
            body(for: review)
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
                Text("\(checked.count) / \(finalColumns.count) 완료")
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
                Text("\(finalColumns.count)개 컬럼 · 완성될 결과를 확인하세요")
                    .font(.body).foregroundStyle(.secondary)
            }
            Spacer()
            if let errorMessage { errorLabel(errorMessage).frame(maxWidth: 300) }
            Button("← 파일") { stage = .files }
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
            .disabled(!allChecked || isRunning)
            .help(allChecked ? "병합을 시작합니다" : "모든 컬럼을 검토(체크)해야 합칠 수 있어요.")
        }
        .padding(20)
    }

    // MARK: - Per-column review body

    @ViewBuilder
    private func body(for review: ColumnReview) -> some View {
        switch review.kind {
        case .category:
            ValueUnifyBody(values: review.values,
                           mapping: bindingForColumn(review.column),
                           allowed: allowedValues[review.column] ?? [],
                           onAuto: { autoUnify(review.column, values: review.values) })
        case .phone:
            ProposalsBody(note: review.note,
                          proposals: review.proposals,
                          targetLabel: phoneTemplate,
                          mapping: bindingForColumn(review.column),
                          phoneTemplate: $phoneTemplate)
        case .date:
            ProposalsBody(note: review.note,
                          proposals: review.proposals,
                          targetLabel: "yyyy-MM-dd",
                          mapping: bindingForColumn(review.column))
        case .freeText:
            FreeTextBody(note: review.note,
                         samples: review.samples,
                         distinctCount: review.distinctCount,
                         anomalies: review.anomalies,
                         mapping: bindingForColumn(review.column))
        case .derived:
            NoteBody(note: review.note)
        }
    }

    private func subtitle(for review: ColumnReview) -> String {
        let base: String
        switch review.kind {
        case .category:
            base = "값 통일 · \(review.distinctCount)종 값 · \(review.total)행"
        case .phone:
            base = review.flaggedCount > 0
                ? "전화번호 정규화 · 표준(010-) 아님 \(review.flaggedCount)종"
                : "전화번호 정규화 · 모두 표준 형식"
        case .date:
            base = review.flaggedCount > 0
                ? "생년월일 정규화 · 인식 못함 \(review.flaggedCount)종"
                : "생년월일 정규화 · 모두 인식됨"
        case .freeText:
            base = "자유 입력 · \(review.distinctCount)종 값 · \(review.total)행"
                + (review.anomalies.isEmpty ? "" : " · ⚠︎ 점검 필요 \(review.anomalies.count)건")
        case .derived:
            return "자동 생성 컬럼"
        }
        let composite = plans.filter { ($0.sources[review.column]?.count ?? 0) > 1 }.count
        // 합치기 전에 이 컬럼에서 바뀔 값 종 수를 미리 보여줘 신뢰를 줍니다.
        let edits = (valueMap[review.column] ?? [:]).filter { $0.key != $0.value }.count
        var line = base
        if edits > 0 { line += " · ✏️ 수정 예정 \(edits)종" }
        if composite > 0 { line += " · \(composite)개 파일에서 컬럼 조합" }
        // 매핑표가 적용된 컬럼: 허용 목록 밖 값이 남아 있으면 경고를 노출.
        if let allowed = allowedValues[review.column], !allowed.isEmpty {
            let out = review.values.filter {
                !allowed.contains(valueMap[review.column]?[$0.value] ?? $0.value)
            }.count
            line += out == 0 ? " · 🔒 매핑표 고정" : " · ⚠️ 매핑표 외 \(out)종"
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
        var diff: [Int: Set<UnifiedColumn>] = [:]
        var n = 0
        for (i, row) in rows.enumerated() where i < preview.baselineRows.count {
            for c in finalColumns where row[c] != preview.baselineRows[i][c] {
                diff[i, default: []].insert(c)
                n += 1
            }
        }
        preview.rows = rows
        preview.diff = diff
        preview.diffCount = n
        preview.columns = finalColumns
        preview.checked = checked
    }

    private func toggleAll() {
        checked = allChecked ? [] : Set(finalColumns)
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
                self.preview.reset()
                self.seedValueMap(from: revs)
                self.stage = .review
                // 합쳐진 현재 상태를 처음부터 별도 윈도우로 보여줍니다.
                self.refreshPreview()
                self.openWindow(id: "preview")
            }
        }
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
                try Exporter.write(result, to: url, excludeRemoved: excludeRemoved)
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
    var onDetail: (() -> Void)? = nil
    var onConfigure: (() -> Void)? = nil
    var onRegex: (() -> Void)? = nil
    var onMapping: (() -> Void)? = nil
    @ViewBuilder var content: () -> Content

    private var hasActions: Bool {
        onDetail != nil || onConfigure != nil || onRegex != nil || onMapping != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Section header: column name + status + OK
            HStack(alignment: .firstTextBaseline) {
                Rectangle()
                    .fill(isChecked ? Color.green : Color.accentColor)
                    .frame(width: 4, height: 26)
                    .clipShape(Capsule())
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.title3.weight(.semibold))
                        .lineLimit(1).truncationMode(.tail).help(title)
                    Text(subtitle)
                        .font(.subheadline).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                if isChecked {
                    Label("완료", systemImage: "checkmark.circle.fill")
                        .font(.subheadline.weight(.medium)).foregroundStyle(.green)
                }
                Toggle(isOn: $isChecked) { Text("이대로 OK") }
                    .toggleStyle(.checkbox)
                    .font(.body)
                    .fixedSize()
            }
            .padding(.vertical, 10)

            if !isChecked {
                // Labeled action buttons (no more icon-only guessing)
                if hasActions {
                    HStack(spacing: 8) {
                        if let onDetail {
                            Button(action: onDetail) {
                                Label("전체 보기", systemImage: "list.bullet.rectangle")
                            }
                            .help("이 컬럼의 모든 값을 이전 값 → 이후 값으로 자세히 봅니다.")
                        }
                        if let onConfigure {
                            Button(action: onConfigure) {
                                Label("컬럼 조합", systemImage: "slider.horizontal.3")
                            }
                            .help("이 컬럼을 어떤 원본 컬럼들에서 가져올지(조합) 설정합니다.")
                        }
                        if let onRegex {
                            Button(action: onRegex) {
                                Label("정규식", systemImage: "curlybraces")
                            }
                            .help("정규식 규칙을 골라 이 컬럼 값을 일괄 정리합니다.")
                        }
                        if let onMapping {
                            Button(action: onMapping) {
                                Label("매핑표", systemImage: "tablecells")
                            }
                            .help("매핑표(원본 → 통일)를 붙여넣어 이 컬럼 값을 한 번에 매핑합니다.")
                        }
                        Spacer(minLength: 0)
                    }
                    .controlSize(.regular)
                    .padding(.bottom, 10)
                }
                content()
                    .padding(.bottom, 4)
            }

            Divider().padding(.top, 8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
                          ? "매핑표 값으로 고정됨 (\(allowed.count)종)"
                          : "매핑표 값으로 고정됨 · 선택 필요 \(outOfSet)종",
                          systemImage: outOfSet == 0 ? "lock.fill" : "exclamationmark.triangle.fill")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(outOfSet == 0 ? Color.green : Color.orange)
                        .help("매핑표가 적용된 컬럼이라 통일 값은 매핑표의 값 중 하나로만 정할 수 있습니다.")
                }
                Spacer()
                if allowed.isEmpty {
                    Button(action: onAuto) {
                        Label("자동 통일", systemImage: "wand.and.stars")
                    }
                    .help("같은 뜻으로 보이는 값을 자동으로 한 값에 모읍니다.")
                } else if !recommendable.isEmpty {
                    Button {
                        // 사용자가 누르는 행위가 곧 승인 — 추천을 일괄 반영.
                        for (dv, target) in recommendable { mapping[dv.value] = target }
                    } label: {
                        Label("추천대로 승인 (\(recommendable.count))", systemImage: "wand.and.stars")
                    }
                    .help("매핑표 밖의 값들을 유사도가 가장 높은 허용 값으로 한 번에 배정합니다. 배정 후에도 행마다 다시 바꿀 수 있어요.")
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
                        Label("프리셋", systemImage: "textformat.123")
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
                Text("‘\(column.rawValue)’ 정규식 클렌징").font(.headline)
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
            coverageBar
            Divider()
            HStack(spacing: 0) {
                editorPane
                Divider()
                previewPane
            }
            Divider()
            footer
        }
        .frame(width: 820, height: 660)
        .onAppear { if !didSeed { seed(); didSeed = true } }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("‘\(column.rawValue)’ 매핑표").font(.headline)
                Text("한 줄에 하나씩 ‘원본 → 통일’ 형태로 적거나 붙여넣으세요. 구분자는 탭·→·:·쉼표 모두 됩니다.")
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
            HStack {
                Text("매핑표").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
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
        .frame(width: 380)
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

    private var footer: some View {
        HStack {
            Text("적용하면 매핑표의 \(parsed.pairs.count)개 규칙이 ‘\(column.rawValue)’ 값에 반영됩니다.")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
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
