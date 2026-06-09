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
    @State private var checked: Set<UnifiedColumn> = []
    @State private var detailColumn: UnifiedColumn?
    @State private var configColumn: UnifiedColumn?
    @State private var regexColumn: UnifiedColumn?

    @State private var result: MergeResult?
    @State private var errorMessage: String?
    @State private var excludeRemoved = false
    @State private var isPreparing = false
    @State private var isRunning = false

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
    }

    /// Detail viewer for one column, with the same anomaly flags used in review.
    private func detailSheet(_ col: UnifiedColumn) -> some View {
        let vals = ColumnReviewBuilder.allValues(col, in: plans)
        let reasons = Dictionary(AnomalyDetector.scan(vals).map { ($0.value, $0.reason) },
                                 uniquingKeysWith: { first, _ in first })
        return ColumnDetailView(columnName: col.rawValue,
                                values: vals,
                                mapping: valueMap[col] ?? [:],
                                anomalyReasons: reasons,
                                onClose: { detailColumn = nil })
    }

    // MARK: - Stage 1: add files (centered onboarding)

    private var filesStage: some View {
        ScrollView {
            VStack(spacing: 20) {
                VStack(spacing: 8) {
                    Image(systemName: "wand.and.stars")
                        .font(.system(size: 44))
                        .foregroundStyle(Color.accentColor)
                    Text("데이터 마법사")
                        .font(.system(size: 28, weight: .bold, design: .rounded))
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
                VStack(alignment: .leading, spacing: 16) {
                    progressHeader
                    ForEach(reviews) { review in
                        ReviewSection(title: review.column.rawValue,
                                      subtitle: subtitle(for: review),
                                      isChecked: checkBinding(review.column),
                                      onDetail: { detailColumn = review.column },
                                      onConfigure: review.kind == .derived ? nil
                                        : { configColumn = review.column },
                                      onRegex: (review.kind == .category || review.kind == .freeText)
                                        ? { regexColumn = review.column } : nil) {
                            body(for: review)
                        }
                    }
                }
                .padding(24)
            }
        }
    }

    private var progressHeader: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("컬럼별 검토")
                    .font(.title3.weight(.bold))
                Text("각 컬럼의 값을 확인하고 ‘이대로 OK’를 체크하세요. 모두 체크하면 합칠 수 있어요.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 6) {
                Text("\(checked.count) / \(finalColumns.count) 완료")
                    .font(.headline).monospacedDigit()
                Button(allChecked ? "모두 해제" : "모두 이대로 OK") { toggleAll() }
                    .controlSize(.small)
            }
        }
        .padding(.bottom, 4)
    }

    private var reviewToolbar: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("검토").font(.title2.weight(.bold))
                Text("\(finalColumns.count)개 컬럼 · 완성될 결과를 확인하세요")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            if let errorMessage { errorLabel(errorMessage).frame(maxWidth: 300) }
            Button("← 파일") { stage = .files }
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
                           onAuto: { autoUnify(review.column, values: review.values) })
        case .phone, .date:
            ExamplesBody(note: review.note, examples: review.examples)
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
        return composite > 0 ? "\(base) · \(composite)개 파일에서 컬럼 조합" : base
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
                Text("전화번호가 없어 중복 검사에서 제외된 행 \(r.unmatchedNoPhone)건.")
                    .font(.caption).foregroundStyle(.secondary)
            }
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
                set: { if $0 { checked.insert(col) } else { checked.remove(col) } })
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
                self.seedValueMap(from: revs)
                self.stage = .review
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
        let engine = MergeEngine(plans: plans, valueMap: valueMap)
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
    let values: [DistinctValue]
    let mapping: [String: String]
    var anomalyReasons: [String: String] = [:]   // value → why it looks off
    let onClose: () -> Void

    @State private var query = ""

    private var filtered: [DistinctValue] {
        guard !query.isEmpty else { return values }
        return values.filter { $0.value.localizedCaseInsensitiveContains(query) }
    }
    private var totalRows: Int { values.reduce(0) { $0 + $1.count } }
    private var valueKinds: Int { Set(values.map { $0.value }).count }
    private var showsUnified: Bool { mapping.contains { $0.key != $0.value } }
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
                    Text("\(valueKinds)종 값 · \(totalRows)행"
                         + (splitCount > 0 ? " · 출처 분리 \(values.count)행" : "")
                         + (anomalyReasons.isEmpty ? "" : " · ⚠︎ 점검 \(anomalyReasons.count)건"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("닫기", action: onClose).keyboardShortcut(.cancelAction)
            }
            .padding(16)
            Divider()

            if values.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "tray").font(.system(size: 28)).foregroundStyle(.tertiary)
                    Text("표시할 값이 없습니다.\n(병합 후 결정되는 값일 수 있어요.)")
                        .font(.callout).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                TextField("값 검색…", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .padding(.horizontal, 16).padding(.vertical, 10)

                ScrollView {
                    LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                        Section {
                            ForEach(filtered) { dv in
                                HStack(spacing: 12) {
                                    HStack(spacing: 5) {
                                        if let reason = anomalyReasons[dv.value] {
                                            Image(systemName: "exclamationmark.triangle.fill")
                                                .font(.caption2).foregroundStyle(.orange)
                                                .help(reason)
                                        }
                                        Text(dv.value.isEmpty ? "(빈 값)" : dv.value)
                                            .font(.callout)
                                            .foregroundStyle(dv.value.isEmpty ? .secondary : .primary)
                                            .textSelection(.enabled)
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
                                    Text("\(dv.count)")
                                        .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                                        .frame(width: 56, alignment: .trailing)
                                    if showsUnified {
                                        let canonical = mapping[dv.value] ?? dv.value
                                        Text(canonical)
                                            .font(.caption)
                                            .foregroundStyle(canonical != dv.value ? Color.accentColor : .secondary)
                                            .frame(width: 150, alignment: .leading)
                                            .lineLimit(1).truncationMode(.tail)
                                    }
                                }
                                .padding(.horizontal, 16).padding(.vertical, 6)
                                Divider()
                            }
                        } header: {
                            HStack(spacing: 12) {
                                Text("값").frame(maxWidth: .infinity, alignment: .leading)
                                if showsSource { Text("출처 파일").frame(width: 160, alignment: .leading) }
                                Text("건수").frame(width: 56, alignment: .trailing)
                                if showsUnified { Text("통일 값").frame(width: 150, alignment: .leading) }
                            }
                            .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            .padding(.horizontal, 16).padding(.vertical, 6)
                            .background(Color(nsColor: .windowBackgroundColor))
                        }
                    }
                }
            }
        }
        .frame(width: showsSource ? 740 : 580, height: 580)
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
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.headline)
                        .lineLimit(1).truncationMode(.tail).help(title)
                    Text(subtitle)
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                if let onRegex {
                    Button(action: onRegex) {
                        Image(systemName: "curlybraces")
                    }
                    .controlSize(.small)
                    .help("정규식 규칙을 골라 이 컬럼 값을 일괄 정리합니다.")
                }
                if let onConfigure {
                    Button(action: onConfigure) {
                        Image(systemName: "slider.horizontal.3")
                    }
                    .controlSize(.small)
                    .help("이 컬럼을 어떤 원본 컬럼들에서 가져올지(조합) 설정합니다.")
                }
                if let onDetail {
                    Button(action: onDetail) {
                        Image(systemName: "list.bullet.rectangle")
                    }
                    .controlSize(.small)
                    .help("이 컬럼의 모든 값을 자세히 봅니다.")
                }
                if isChecked {
                    Label("완료", systemImage: "checkmark.circle.fill")
                        .font(.caption).foregroundStyle(.green)
                }
                Toggle(isOn: $isChecked) { Text("이대로 OK") }
                    .toggleStyle(.checkbox)
                    .font(.callout)
                    .fixedSize()
            }
            if !isChecked {
                content()
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isChecked ? Color.green.opacity(0.07) : Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(isChecked ? Color.green.opacity(0.45) : Color.clear, lineWidth: 1)
        )
    }
}

/// Body for a categorical column: edit how value variants collapse onto one value.
struct ValueUnifyBody: View {
    let values: [DistinctValue]
    @Binding var mapping: [String: String]
    let onAuto: () -> Void

    var body: some View {
        let groupCount = Set(values.map { mapping[$0.value] ?? $0.value }).count
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("\(values.count)개 값 → \(groupCount)개로 통일")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(action: onAuto) {
                    Label("자동 통일", systemImage: "wand.and.stars")
                }
                .controlSize(.small)
                .help("같은 뜻으로 보이는 값을 자동으로 한 값에 모읍니다.")
            }

            HStack(spacing: 10) {
                Text("원본 값").frame(width: 220, alignment: .leading)
                Text("건수").frame(width: 48, alignment: .trailing)
                Text("통일 값").frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.caption.weight(.semibold)).foregroundStyle(.secondary)

            ForEach(values) { dv in
                let canonical = mapping[dv.value] ?? dv.value
                let changed = canonical != dv.value
                HStack(spacing: 10) {
                    Text(dv.value)
                        .font(.callout)
                        .frame(width: 220, alignment: .leading)
                        .lineLimit(1).truncationMode(.tail).help(dv.value)
                    Text("\(dv.count)")
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(width: 48, alignment: .trailing)
                    HStack(spacing: 6) {
                        Image(systemName: changed ? "arrow.right" : "equal")
                            .font(.caption2)
                            .foregroundStyle(changed ? Color.accentColor : Color.secondary)
                        TextField("", text: Binding(
                            get: { mapping[dv.value] ?? dv.value },
                            set: { mapping[dv.value] = $0 }
                        ))
                        .textFieldStyle(.roundedBorder)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}

/// Body for an auto-normalized column (phone/date): explanation + original → cleaned.
struct ExamplesBody: View {
    let note: String
    let examples: [ColumnExample]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !note.isEmpty {
                Text(note).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !examples.isEmpty {
                HStack(spacing: 10) {
                    Text("원본 값").frame(width: 240, alignment: .leading)
                    Text("자동 변환 →").frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)

                ForEach(examples) { ex in
                    HStack(spacing: 10) {
                        Text(ex.original)
                            .font(.callout)
                            .frame(width: 240, alignment: .leading)
                            .lineLimit(1).truncationMode(.tail).help(ex.original)
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.right")
                                .font(.caption2).foregroundStyle(Color.secondary)
                            Text(ex.cleaned.isEmpty ? "—" : ex.cleaned)
                                .font(.callout)
                                .foregroundStyle(ex.flagged ? Color.orange : Color.primary)
                            if ex.flagged {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .font(.caption2).foregroundStyle(.orange)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
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
                Text(note).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !samples.isEmpty {
                Text("예시 값")
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(Array(samples.enumerated()), id: \.offset) { _, value in
                    Text("• \(value)")
                        .font(.callout)
                        .lineLimit(1).truncationMode(.tail).help(value)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if distinctCount > samples.count {
                    Text("외 \(distinctCount - samples.count)종")
                        .font(.caption).foregroundStyle(.tertiary)
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
                    .font(.caption.weight(.semibold)).foregroundStyle(.orange)
                Spacer()
                if !fixable.isEmpty {
                    Button {
                        for f in fixable { mapping[f.value] = f.suggestion }
                    } label: {
                        Label("추천값으로 일괄 수정 (\(fixable.count))", systemImage: "wand.and.stars")
                    }
                    .controlSize(.small)
                    .help("자동으로 고칠 수 있는 값을 추천 형태로 한 번에 바꿉니다. 이후 직접 수정할 수 있어요.")
                }
            }

            HStack(spacing: 10) {
                Text("원본 값").frame(width: 150, alignment: .leading)
                Text("건수").frame(width: 40, alignment: .trailing)
                Text("사유").frame(width: 190, alignment: .leading)
                Text("수정 값").frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.caption.weight(.semibold)).foregroundStyle(.secondary)

            ForEach(anomalies) { f in
                let current = mapping[f.value] ?? f.value
                let changed = current != f.value
                HStack(alignment: .top, spacing: 10) {
                    Text(f.value)
                        .font(.callout)
                        .frame(width: 150, alignment: .leading)
                        .lineLimit(1).truncationMode(.middle)
                        .help(f.files.isEmpty ? f.value : "\(f.value)\n출처: \(f.files.joined(separator: ", "))")
                    Text("\(f.count)")
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(width: 40, alignment: .trailing)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(f.reason)
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if f.fixable && !changed {
                            Button("추천: \(f.suggestion)") { mapping[f.value] = f.suggestion }
                                .buttonStyle(.link).font(.caption2)
                        }
                    }
                    .frame(width: 190, alignment: .leading)
                    HStack(spacing: 6) {
                        Image(systemName: changed ? "arrow.right" : "equal")
                            .font(.caption2)
                            .foregroundStyle(changed ? Color.accentColor : Color.secondary)
                        TextField("", text: Binding(
                            get: { mapping[f.value] ?? f.value },
                            set: { mapping[f.value] = $0 }
                        ))
                        .textFieldStyle(.roundedBorder)
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

    private var customError: String? {
        guard !customPattern.isEmpty else { return nil }
        return RegexCleaner.isValid(customPattern) ? nil : "정규식 형식이 올바르지 않습니다."
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
                    previewSection
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

/// Configure how one unified column is sourced from each file: pick an ordered
/// set of source columns to combine (1 = plain mapping, 2+ = composite like
/// 성 + 이름), with a shared separator and a live preview.
struct ColumnSourceSheet: View {
    let column: UnifiedColumn
    @Binding var plans: [FilePlan]
    let onClose: () -> Void

    private let maxSlots = 4

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

            HStack(spacing: 8) {
                Text("이어 붙일 때 구분자").font(.callout)
                TextField("예: 공백, - 등 (비우면 붙여 씀)", text: separatorBinding)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 220)
                Spacer()
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

/// Body for a derived column: just the explanation.
struct NoteBody: View {
    let note: String
    var body: some View {
        Text(note)
            .font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
