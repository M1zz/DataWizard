import SwiftUI

// 값을 손보는 창들 — 값 훑어보기·패턴 정리·매핑표·원본 칸 고르기·원본 파일 보기.

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
                    Text("‘\(columnName)’ 변화 미리보기").font(.headline)
                    Text((changedKinds > 0
                          ? "바뀌는 값 \(changedKinds)종 · 그대로 두는 값 \(max(valueKinds - changedKinds, 0))종"
                          : "바뀌는 값이 없어요 — 전부 원본 그대로 나갑니다")
                         + (expandRaw ? " · 원본 \(rawValues.count)행 전부 펼침"
                                      : " · \(valueKinds)종 값 · \(totalRows)행")
                         + (!expandRaw && splitCount > 0 ? " · 출처 분리 \(values.count)행" : "")
                         + (anomalyReasons.isEmpty ? "" : " · ⚠︎ 점검 \(anomalyReasons.count)건"))
                        .font(.body).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
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
                                Text("지금 값 (원본)")
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                Text("바뀔 값 (완성본)")
                                    .foregroundStyle(changedKinds > 0 ? Color.accentColor : .secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
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
            // 무엇이 달라지는지부터 — 바뀌는 값이 있으면 그게 먼저다.
            if changedKinds > 0 { sort = .changedFirst }
            else if !anomalyReasons.isEmpty { sort = .anomalyFirst }
        }
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
    /// 표에는 적었는데 **이 컬럼엔 없는** 원본 값들.
    /// (값이 여러 컬럼에 나뉘어 있을 때 “표는 맞는데 매핑이 안 된다”의 대부분이 이것이다.)
    private var unusedRules: [String] {
        let here = Set(values.map(\.value))
        return parsed.pairs.map(\.from).filter { !here.contains($0) }
    }
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
                if !unusedRules.isEmpty {
                    Text("표의 \(unusedRules.count)줄은 이 컬럼에 없는 값이에요 (예: \(unusedRules.prefix(3).joined(separator: " · "))). "
                         + "값이 두 컬럼에 나뉘어 있다면, 먼저 완성본 미리보기에서 두 컬럼을 "
                         + "‘값이 있는 것 하나만’으로 한 칸에 모은 뒤 이 표를 붙여넣으세요.")
                        .font(.body).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
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
            if !unusedRules.isEmpty {
                Text("· 이 컬럼에 없는 값 \(unusedRules.count)줄")
                    .font(.body.weight(.medium)).foregroundStyle(.orange)
                    .help("표에 적었지만 ‘\(column.rawValue)’에는 없는 값이에요 — 다른 컬럼에 들어 있을 수 있습니다:\n"
                          + unusedRules.prefix(12).joined(separator: "\n")
                          + (unusedRules.count > 12 ? "\n…" : ""))
            }
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
