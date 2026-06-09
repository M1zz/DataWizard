import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    enum Stage { case files, review, result }

    @State private var inputs: [MergeInput] = []
    @State private var plans: [FilePlan] = []
    @State private var stage: Stage = .files

    // Value unification (across the merged columns)
    @State private var valueMap: [UnifiedColumn: [String: String]] = [:]
    @State private var unifyColumns: [UnifiedColumn] = []
    @State private var columnValues: [UnifiedColumn: [DistinctValue]] = [:]

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
                    Text("흩어진 지원 파일들을 추가하면, 어떤 필드와 값이 어떻게 합쳐지는지 검토한 뒤 하나의 명단으로 만듭니다.")
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
                        Text(isPreparing ? "불러오는 중…" : "검토 & 매핑 →").fontWeight(.semibold)
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

    // MARK: - Stage 2: review mapping + value unification (full width)

    private var reviewStage: some View {
        VStack(spacing: 0) {
            reviewToolbar
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    VStack(alignment: .leading, spacing: 16) {
                        sectionHeader("① 필드 매핑",
                                      "각 파일의 원본 컬럼이 어떤 통합 필드로 들어갈지 확인·수정하세요.")
                        ForEach($plans) { $plan in
                            PlanReviewCard(plan: $plan)
                        }
                    }

                    if !unifyColumns.isEmpty {
                        VStack(alignment: .leading, spacing: 16) {
                            HStack(alignment: .firstTextBaseline) {
                                sectionHeader("② 값 통일",
                                              "한 컬럼으로 합쳐질 때 같은 뜻의 값을 하나로 모으세요. 예: ‘Seoul’과 ‘서울’.")
                                Spacer()
                                Button { rescanValues() } label: {
                                    Label("값 다시 스캔", systemImage: "arrow.clockwise")
                                }
                                .controlSize(.small)
                                .help("필드 매핑을 바꿨다면 눌러 값 목록을 새로고침하세요.")
                            }
                            ForEach(unifyColumns, id: \.self) { col in
                                ValueUnifyCard(column: col,
                                               values: columnValues[col] ?? [],
                                               mapping: bindingForColumn(col),
                                               onAuto: { autoUnify(col) })
                            }
                        }
                    }
                }
                .padding(24)
            }
        }
    }

    private var reviewToolbar: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("검토").font(.title2.weight(.bold))
                Text("\(plans.count)개 파일 · 매핑과 값을 확인한 뒤 합치세요")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            if let errorMessage {
                errorLabel(errorMessage).frame(maxWidth: 320)
            }
            Button("← 파일") { stage = .files }
            Button(action: runMerge) {
                HStack {
                    if isRunning { ProgressView().controlSize(.small) }
                    Text(isRunning ? "합치는 중…" : "이대로 합치기").fontWeight(.semibold)
                }
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .disabled(isRunning)
        }
        .padding(20)
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

    // MARK: - Small shared views

    private func sectionHeader(_ title: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.title3.weight(.bold))
            Text(subtitle).font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
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

    private func bindingForColumn(_ col: UnifiedColumn) -> Binding<[String: String]> {
        Binding(get: { valueMap[col] ?? [:] }, set: { valueMap[col] = $0 })
    }

    private func autoUnify(_ col: UnifiedColumn) {
        valueMap[col] = ValueCanonicalizer.suggest(columnValues[col] ?? [])
    }

    /// Parse every added file into an editable plan, scan categorical values, then review.
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
            let cols = failure == nil ? ValueScanner.candidates(in: built) : []
            var values: [UnifiedColumn: [DistinctValue]] = [:]
            for c in cols { values[c] = ValueScanner.distinct(c, in: built) }
            DispatchQueue.main.async {
                self.isPreparing = false
                if let failure { self.errorMessage = failure; return }
                self.plans = built
                self.applyScan(cols: cols, values: values)
                self.stage = .review
            }
        }
    }

    /// Re-scan distinct values after the user changes field mappings.
    private func rescanValues() {
        let cols = ValueScanner.candidates(in: plans)
        var values: [UnifiedColumn: [DistinctValue]] = [:]
        for c in cols { values[c] = ValueScanner.distinct(c, in: plans) }
        applyScan(cols: cols, values: values)
    }

    private func applyScan(cols: [UnifiedColumn], values: [UnifiedColumn: [DistinctValue]]) {
        unifyColumns = cols
        columnValues = values
        // Seed identity so each value defaults to itself until the user unifies it.
        for c in cols {
            for dv in values[c] ?? [] where valueMap[c]?[dv.value] == nil {
                valueMap[c, default: [:]][dv.value] = dv.value
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

/// Review card for one file: header, detected issues, and an editable
/// field-mapping table with live sample values.
struct PlanReviewCard: View {
    @Binding var plan: FilePlan

    var body: some View {
        let issues = PlanAnalyzer.issues(for: plan)
        VStack(alignment: .leading, spacing: 14) {
            header

            if !issues.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(issues) { issue in
                        Label(issue.message, systemImage: issue.icon)
                            .font(.caption)
                            .foregroundStyle(color(for: issue.severity))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .underPageBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            VStack(spacing: 6) {
                MappingHeaderRow()
                if plan.channel == .simple {
                    MappingRow(label: "성 (姓)",
                               selection: $plan.surnameColumn,
                               headers: plan.headers,
                               sample: plan.sample(of: plan.surnameColumn))
                }
                ForEach(FilePlan.coreFields, id: \.self) { field in
                    mappingRow(for: field)
                }
            }

            if !plan.extraMappedFields.isEmpty {
                DisclosureGroup("그 외 매핑된 필드 \(plan.extraMappedFields.count)개") {
                    VStack(spacing: 6) {
                        ForEach(plan.extraMappedFields, id: \.self) { field in
                            mappingRow(for: field)
                        }
                    }
                    .padding(.top, 6)
                }
                .font(.callout)
            }
        }
        .padding(16)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var header: some View {
        HStack {
            Image(systemName: "doc.fill").foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(plan.fileName).font(.headline)
                Text("\(plan.channel.rawValue) · \(plan.rows.count)행 · 원본 컬럼 \(plan.headers.count)개")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private func mappingRow(for field: UnifiedColumn) -> some View {
        MappingRow(
            label: field.rawValue,
            selection: Binding(
                get: { plan.mapping[field] ?? "" },
                set: { plan.mapping[field] = $0 }
            ),
            headers: plan.headers,
            sample: plan.sample(of: plan.mapping[field] ?? "")
        )
    }

    private func color(for severity: MappingIssue.Severity) -> Color {
        switch severity {
        case .error:   return .red
        case .warning: return .orange
        case .info:    return .secondary
        }
    }
}

private struct MappingHeaderRow: View {
    var body: some View {
        HStack(spacing: 10) {
            Text("통합 필드").frame(width: 150, alignment: .leading)
            Text("원본 컬럼").frame(width: 220, alignment: .leading)
            Text("예시 값").frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
    }
}

/// A single editable mapping line: unified field ← source column, with a sample.
struct MappingRow: View {
    let label: String
    @Binding var selection: String
    let headers: [String]
    let sample: String

    var body: some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.callout)
                .frame(width: 150, alignment: .leading)
                .lineLimit(1).truncationMode(.tail)
                .help(label)
            Picker("", selection: $selection) {
                Text("— 없음 —").tag("")
                ForEach(headers, id: \.self) { h in Text(h).tag(h) }
            }
            .labelsHidden()
            .frame(width: 220)
            Text(sample.isEmpty ? "—" : sample)
                .font(.caption).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(sample)
        }
    }
}

/// Card to collapse value variants in one merged column onto a canonical form.
struct ValueUnifyCard: View {
    let column: UnifiedColumn
    let values: [DistinctValue]
    @Binding var mapping: [String: String]
    let onAuto: () -> Void

    var body: some View {
        let groupCount = Set(values.map { mapping[$0.value] ?? $0.value }).count
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(column.rawValue)
                        .font(.headline).lineLimit(1).truncationMode(.tail).help(column.rawValue)
                    Text("\(values.count)개 값 → \(groupCount)개로 통일")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(action: onAuto) {
                    Label("자동 통일", systemImage: "wand.and.stars")
                }
                .controlSize(.small)
                .help("같은 뜻으로 보이는 값을 자동으로 한 값에 모읍니다.")
            }

            VStack(spacing: 6) {
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
        .padding(16)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}
