import SwiftUI

/// 이름이 달라도 ‘같은 컬럼’인지 값으로 알아보는 도구.
///
/// 완성된 틀(`BaseSheet`)이 이미 가지고 있는 값과, 이번에 올린 파일의 값을 견줘
/// `거주지 → 도시`, `휴대폰 → Phone` 같은 짝을 제안한다. 근거는 세 가지다:
///   1. 값 겹침 — 틀에 있는 값이 이번 값에도 그대로 나오면 거의 확실한 같은 컬럼
///   2. 값 모양 — `010-1234-5678`처럼 자릿수·구분자 패턴이 같은가
///   3. 이름 유사도 — 마지막 보조 근거 (`Similarity`, 한↔영 사전 다리 포함)
/// 셋 다 확률일 뿐이므로 **자동으로 합치지 않는다.** 제안만 하고 사람이 고른다.
enum ColumnMatcher {

    // MARK: - 값의 모양

    /// 한 값의 모양. 숫자는 `9`, 로마자는 `a`, 한글은 `가`, 나머지 기호는 그대로 두고
    /// 같은 종류가 이어지면 길이를 붙인다. `010-1234-5678` → `93-94-94`
    static func shape(_ value: String) -> String {
        var out = ""
        var runClass: Character?
        var runLen = 0

        func flush() {
            guard let c = runClass else { return }
            out.append(c)
            if c == "9" || c == "a" || c == "가" {
                // 문자열로 붙인다 — Character("10")은 두 글자라 런타임에 터진다.
                // (숫자는 늘 종류 문자 뒤에만 오므로 여러 자리라도 헷갈리지 않는다.)
                out.append(runLen <= 12 ? String(runLen) : "n")
            }
            runClass = nil
            runLen = 0
        }

        for ch in value.prefix(80) {
            let c: Character
            if ch.isNumber { c = "9" }
            else if isHangul(ch) { c = "가" }
            else if ch.isLetter { c = "a" }
            else { c = ch }
            if c == runClass, c == "9" || c == "a" || c == "가" {
                runLen += 1
            } else {
                flush()
                runClass = c
                runLen = 1
            }
        }
        flush()
        return out
    }

    /// 길이를 뺀 성긴 모양 — `a@a.a`, `9-9-9`.
    /// 자릿수가 조금씩 다른 값들(이메일 아이디 길이 등)까지 같은 무리로 본다.
    static func coarseShape(_ value: String) -> String {
        var out = ""
        var last: Character?
        for ch in value.prefix(80) {
            let c: Character
            if ch.isNumber { c = "9" }
            else if isHangul(ch) { c = "가" }
            else if ch.isLetter { c = "a" }
            else { c = ch }
            let isClass = (c == "9" || c == "a" || c == "가")
            if isClass && c == last { continue }
            out.append(c)
            last = c
        }
        return out
    }

    private static func isHangul(_ ch: Character) -> Bool {
        guard let u = ch.unicodeScalars.first?.value else { return false }
        return (0xAC00...0xD7A3).contains(u) || (0x1100...0x11FF).contains(u)
            || (0x3130...0x318F).contains(u)
    }

    /// 한 컬럼의 값들을 비교하기 좋은 형태로 요약해 둔 것.
    struct Profile {
        var keys: Set<String> = []          // 정규화한 값 (겹침 비교용)
        var shapes: [String: Double] = [:]  // 모양 → 비율 (자릿수까지)
        var coarse: [String: Double] = [:]  // 길이를 뺀 모양 → 비율
        var distinct = 0
        var sample: [String] = []
    }

    static func profile(_ values: [String], limit: Int = 600) -> Profile {
        var p = Profile()
        var counts: [String: Int] = [:]
        var coarseCounts: [String: Int] = [:]
        var seen = Set<String>()
        var used = 0
        for v in values {
            let t = v.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { continue }
            used += 1
            counts[shape(t), default: 0] += 1
            coarseCounts[coarseShape(t), default: 0] += 1
            let key = ValueCanonicalizer.key(t)
            if !key.isEmpty { p.keys.insert(key) }
            if seen.insert(t).inserted {
                p.distinct += 1
                if p.sample.count < 6 { p.sample.append(t) }
            }
            if used >= limit { break }
        }
        guard used > 0 else { return p }
        for (k, n) in counts { p.shapes[k] = Double(n) / Double(used) }
        for (k, n) in coarseCounts { p.coarse[k] = Double(n) / Double(used) }
        return p
    }

    // MARK: - 점수

    /// 겹치는 값의 비율 — 적은 쪽 기준이라 ‘이번 달 5개 도시 ⊂ 틀의 20개 도시’도 1.0.
    static func overlapScore(_ a: Profile, _ b: Profile) -> Double {
        guard !a.keys.isEmpty, !b.keys.isEmpty else { return 0 }
        let inter = a.keys.intersection(b.keys).count
        return Double(inter) / Double(min(a.keys.count, b.keys.count))
    }

    /// 모양 분포가 얼마나 겹치는가 (히스토그램 교집합, 0…1).
    /// 자릿수까지 같은지(fine)와 생김새만 같은지(coarse)를 반씩 본다 —
    /// 전화번호는 자릿수가, 이메일·주소는 생김새가 결정적이라서.
    static func shapeScore(_ a: Profile, _ b: Profile) -> Double {
        guard !a.shapes.isEmpty, !b.shapes.isEmpty else { return 0 }
        func intersect(_ x: [String: Double], _ y: [String: Double]) -> Double {
            var sum = 0.0
            for (k, v) in x { sum += min(v, y[k] ?? 0) }
            return sum
        }
        return 0.5 * intersect(a.shapes, b.shapes) + 0.5 * intersect(a.coarse, b.coarse)
    }

    struct Candidate: Identifiable {
        let column: UnifiedColumn
        let score: Double
        let reason: String
        var id: String { column.rawValue }
        var percent: Int { Int((score * 100).rounded()) }
    }

    struct Suggestion: Identifiable {
        let source: UnifiedColumn          // 이번 파일의 컬럼 (틀에 없는 이름)
        let candidates: [Candidate]        // 틀의 컬럼 후보, 점수순
        var id: String { source.rawValue }
        var best: Candidate? { candidates.first }
    }

    /// 한 쌍의 점수와 그렇게 본 이유.
    static func score(source: Profile, target: Profile,
                      sourceName: String, targetName: String) -> (score: Double, reason: String) {
        let overlap = overlapScore(source, target)
        let shape = shapeScore(source, target)
        let name = Similarity.score(sourceName, targetName)

        var best = 0.0
        var reason = ""
        // 값이 실제로 겹치면 가장 강한 근거.
        let byValue = 0.9 * overlap + 0.1 * name
        if byValue > best {
            best = byValue
            let inter = source.keys.intersection(target.keys).count
            reason = "값이 \(inter)종 겹침"
        }
        // 값 모양이 같은 경우 (전화번호·날짜·사번처럼 형식이 뚜렷할 때).
        let byShape = 0.75 * shape + 0.25 * name
        if byShape > best {
            best = byShape
            reason = "값 모양이 같음" + (source.sample.first.map { " (\($0))" } ?? "")
        }
        // 이름만으로도 충분히 비슷한 경우 (연락처 ↔ 전화번호).
        let byName = 0.85 * name + 0.15 * shape
        if byName > best {
            best = byName
            reason = "이름이 비슷함"
        }
        return (min(best, 1), reason)
    }

    /// `sources`(이번 파일의 컬럼) 각각에 대해 `targets`(틀의 컬럼) 후보를 매긴다.
    /// 최고 점수가 기준 미만이면 아예 제안하지 않는다 — 억지로 짝지어 주지 않는다.
    static func suggest(sources: [(column: UnifiedColumn, values: [String])],
                        targets: [(column: UnifiedColumn, values: [String])],
                        minScore: Double = 0.5,
                        maxCandidates: Int = 5) -> [Suggestion] {
        suggest(sourceProfiles: sources.map { ($0.column, profile($0.values)) },
                targetProfiles: targets.map { ($0.column, profile($0.values)) },
                minScore: minScore, maxCandidates: maxCandidates)
    }

    /// 값 훑기(profile)를 이미 해 둔 경우 — 컬럼이 많을 때 이쪽을 쓴다.
    /// 컬럼 100개를 서로 견주면 profile을 매번 다시 만드는 것만으로 몇 초가 날아간다.
    static func suggest(sourceProfiles: [(UnifiedColumn, Profile)],
                        targetProfiles: [(UnifiedColumn, Profile)],
                        minScore: Double = 0.5,
                        maxCandidates: Int = 5) -> [Suggestion] {
        guard !sourceProfiles.isEmpty, !targetProfiles.isEmpty else { return [] }

        var out: [Suggestion] = []
        for (sourceColumn, sp) in sourceProfiles {
            guard sp.distinct > 0 else { continue }
            var cands: [Candidate] = []
            for (col, tp) in targetProfiles where tp.distinct > 0 && col != sourceColumn {
                let r = score(source: sp, target: tp,
                              sourceName: sourceColumn.rawValue, targetName: col.rawValue)
                guard r.score >= minScore else { continue }
                cands.append(Candidate(column: col, score: r.score, reason: r.reason))
            }
            guard !cands.isEmpty else { continue }
            cands.sort { $0.score > $1.score }
            out.append(Suggestion(source: sourceColumn,
                                  candidates: Array(cands.prefix(maxCandidates))))
        }
        return out.sorted { ($0.best?.score ?? 0) > ($1.best?.score ?? 0) }
    }
}

// MARK: - 짝짓기 확인 시트

/// 제안을 한 줄씩 보여 주고, 사람이 고른 것만 합친다.
/// 왼쪽은 이번 파일의 값, 오른쪽은 틀에 이미 들어 있는 값 — 눈으로 확인하고 고르게.
struct ColumnMatchSheet: View {
    let baseName: String
    let suggestions: [ColumnMatcher.Suggestion]
    let sourceSamples: [UnifiedColumn: [String]]
    let targetSamples: [UnifiedColumn: [String]]
    let onApply: ([(source: UnifiedColumn, target: UnifiedColumn)]) -> Void
    let onClose: () -> Void

    /// 컬럼별 선택 — 값이 없으면 ‘합치지 않음’.
    @State private var choice: [UnifiedColumn: UnifiedColumn] = [:]

    private var picked: [(source: UnifiedColumn, target: UnifiedColumn)] {
        suggestions.compactMap { s in
            choice[s.source].map { (source: s.source, target: $0) }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(suggestions) { s in row(s) }
                }
                .padding(20)
            }
            Divider()
            footer
        }
        .frame(minWidth: 720, minHeight: 460)
        .onAppear {
            // 가장 그럴듯한 후보를 미리 골라 두되, 확정은 사람이 누른다.
            // 1·2위가 엇비슷하면(모호하면) 아무것도 고르지 않는다 — 잘못 합치는 게 더 나쁘다.
            for s in suggestions where choice[s.source] == nil {
                guard let b = s.best, b.score >= 0.6, !isAmbiguous(s) else { continue }
                choice[s.source] = b.column
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("이름이 다른 같은 컬럼 찾기")
                .font(.title2.weight(.bold))
            Text(baseName.isEmpty
                 ? "올린 파일들끼리 값을 견줘 봤어요. 같은 컬럼이면 한 칸으로 합칩니다 — 아니면 ‘합치지 않음’으로 두세요."
                 : "틀 ‘\(baseName)’에 있는 값과 이번 파일의 값을 견줘 봤어요. 같은 컬럼이면 합쳐서 틀의 자리에 채웁니다 — 아니면 ‘합치지 않음’으로 두세요.")
                .font(.body).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
    }

    /// 1·2위 점수가 붙어 있으면 근거가 약하다 — 사람이 값을 보고 고르게 둔다.
    private func isAmbiguous(_ s: ColumnMatcher.Suggestion) -> Bool {
        guard s.candidates.count > 1, let top = s.candidates.first else { return false }
        return top.score - s.candidates[1].score < 0.08
    }

    private func row(_ s: ColumnMatcher.Suggestion) -> some View {
        let target = choice[s.source]
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(s.source.rawValue)
                        .font(.body.weight(.semibold))
                    Text(baseName.isEmpty ? "이 컬럼을" : "이번 파일")
                        .font(.body).foregroundStyle(.secondary)
                }
                Image(systemName: "arrow.right")
                    .foregroundStyle(target == nil ? Color.secondary : Color.accentColor)
                Picker("", selection: Binding(
                    get: { choice[s.source] },
                    set: { v in
                        if let v { choice[s.source] = v } else { choice.removeValue(forKey: s.source) }
                    })) {
                    Text("합치지 않음 — 따로 두기").tag(UnifiedColumn?.none)
                    ForEach(s.candidates) { c in
                        Text((baseName.isEmpty ? "‘\(c.column.rawValue)’ 칸으로" : "틀의 ‘\(c.column.rawValue)’")
                             + "  ·  \(c.percent)% \(c.reason)")
                            .tag(UnifiedColumn?.some(c.column))
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 380)
                Spacer(minLength: 0)
            }
            if isAmbiguous(s) {
                Label("비슷한 후보가 여럿이에요 — 값을 보고 골라 주세요", systemImage: "questionmark.circle")
                    .font(.body).foregroundStyle(.orange)
            }
            HStack(alignment: .top, spacing: 12) {
                valueColumn("이번 값", sourceSamples[s.source] ?? [])
                if let target {
                    valueColumn((baseName.isEmpty ? "‘\(target.rawValue)’의 값" : "틀 ‘\(target.rawValue)’의 값"),
                                targetSamples[target] ?? [])
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .stroke(target == nil ? Color.primary.opacity(0.07) : Color.accentColor.opacity(0.35),
                    lineWidth: 1))
    }

    private func valueColumn(_ title: String, _ values: [String]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.body).foregroundStyle(.secondary)
            ForEach(values.prefix(4), id: \.self) { v in
                Text(v).font(.body).lineLimit(1).truncationMode(.middle)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var footer: some View {
        HStack {
            Text(picked.isEmpty ? "고른 짝이 없습니다" : "\(picked.count)개를 합칩니다")
                .font(.body).foregroundStyle(.secondary)
            Spacer()
            Button("닫기") { onClose() }
            Button {
                onApply(picked)
            } label: {
                Text("선택한 \(picked.count)개 합치기").fontWeight(.semibold)
            }
            .buttonStyle(.borderedProminent)
            .disabled(picked.isEmpty)
        }
        .padding(16)
    }
}

// MARK: - 여러 칸을 한 칸으로 합치기 설정

/// 고른 컬럼들을 한 칸으로 합칠 때, **어디에·어떤 순서로·무엇을 사이에 넣어** 합칠지 정한다.
/// 예: 틀의 `이름` 칸에 `성` + `이름`을 공백으로 이어 붙이기.
struct ColumnMergeSetupSheet: View {
    let columns: [UnifiedColumn]
    let templateColumns: Set<UnifiedColumn>
    /// 컬럼의 실제 값 몇 개 (미리보기용).
    let sample: (UnifiedColumn) -> [String]
    let onApply: (_ target: UnifiedColumn, _ order: [UnifiedColumn],
                  _ separator: String, _ mode: CombineMode, _ thenClean: Bool) -> Void
    let onClose: () -> Void

    @State private var target: UnifiedColumn
    @State private var order: [UnifiedColumn]
    @State private var separator: String
    @State private var custom = ""
    /// 어떻게 합칠지 — 이어 붙이기 / 값이 있는 것 하나만.
    @State private var mode: CombineMode = .join
    /// 합친 뒤 값 정리 화면까지 갈지.
    @State private var thenClean = false

    init(columns: [UnifiedColumn],
         templateColumns: Set<UnifiedColumn>,
         sample: @escaping (UnifiedColumn) -> [String],
         onApply: @escaping (UnifiedColumn, [UnifiedColumn], String,
                             CombineMode, Bool) -> Void,
         onClose: @escaping () -> Void) {
        self.columns = columns
        self.templateColumns = templateColumns
        self.sample = sample
        self.onApply = onApply
        self.onClose = onClose
        // 틀 안에 있는 칸이 있으면 그 칸을 받는 자리로 (틀 구성을 지키는 게 목적이니까).
        let inTemplate = columns.first { templateColumns.contains($0) }
        _target = State(initialValue: inTemplate ?? columns[0])
        _order = State(initialValue: columns)
        _separator = State(initialValue: " ")
    }

    /// 지금 설정대로 만들어질 값 (실제 값으로 보여 준다).
    private var previewLine: String {
        let parts = order.compactMap { sample($0).first }.filter { !$0.isEmpty }
        guard !parts.isEmpty else { return "—" }
        return mode == .first ? parts[0] : parts.joined(separator: separator)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("여러 칸을 한 칸으로 합치기").font(.title2.weight(.bold))

            VStack(alignment: .leading, spacing: 6) {
                Text("어느 칸에 넣을까요?").font(.body.weight(.semibold))
                Picker("", selection: $target) {
                    ForEach(columns) { c in
                        Text(c.rawValue + (templateColumns.contains(c) ? "  (틀 안)" : "  (틀 밖)"))
                            .tag(c)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 360)
                Text("고른 칸들의 값이 이 칸으로 들어가고, 나머지 칸은 사라집니다.")
                    .font(.body).foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("어떻게 합칠까요?").font(.body.weight(.semibold))
                Picker("", selection: $mode) {
                    Text("이어 붙이기 — 성 + 이름 → 김 철수").tag(CombineMode.join)
                    Text("값이 있는 것 하나만 — 남성/여성 칸과 male/female 칸을 한 칸으로")
                        .tag(CombineMode.first)
                }
                .labelsHidden()
                .pickerStyle(.radioGroup)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(mode == .first ? "어느 것을 먼저 볼까요? (비어 있으면 다음 것)"
                                    : "어떤 순서로 이어 붙일까요?")
                    .font(.body.weight(.semibold))
                ForEach(Array(order.enumerated()), id: \.element) { idx, c in
                    HStack(spacing: 8) {
                        Text("\(idx + 1).").font(.body.monospacedDigit()).foregroundStyle(.secondary)
                        Text(c.rawValue).font(.body)
                        Text(sample(c).first ?? "—")
                            .font(.body).foregroundStyle(.secondary)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        Button {
                            guard idx > 0 else { return }
                            order.swapAt(idx, idx - 1)
                        } label: { Image(systemName: "arrow.up") }
                            .disabled(idx == 0)
                        Button {
                            guard idx < order.count - 1 else { return }
                            order.swapAt(idx, idx + 1)
                        } label: { Image(systemName: "arrow.down") }
                            .disabled(idx == order.count - 1)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 8)
                        .fill(Color(nsColor: .controlBackgroundColor)))
                }
            }

            if mode == .join {
                VStack(alignment: .leading, spacing: 6) {
                    Text("사이에 무엇을 넣을까요?").font(.body.weight(.semibold))
                    HStack(spacing: 8) {
                        chip("붙여쓰기", "")
                        chip("공백", " ")
                        chip("쉼표", ", ")
                        chip("하이픈", "-")
                        TextField("직접", text: $custom)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 90)
                            .onChange(of: custom) { v in if !v.isEmpty { separator = v } }
                    }
                }
            }

            Toggle(isOn: $thenClean) {
                Text("합친 뒤에 이어서 값도 하나로 통일하기 (male → 남성처럼)")
            }
            .toggleStyle(.checkbox)
            .help("합치고 나면 그 컬럼의 값 정리 화면으로 바로 넘어갑니다.")

            HStack(spacing: 8) {
                Text("이렇게 됩니다").font(.body.weight(.semibold))
                Text(previewLine)
                    .font(.body)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 6)
                        .fill(Color.accentColor.opacity(0.12)))
            }

            HStack {
                Spacer()
                Button("취소") { onClose() }
                Button("합치기") { onApply(target, order, separator, mode, thenClean) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(minWidth: 520)
    }

    private func chip(_ title: String, _ value: String) -> some View {
        let on = separator == value && custom.isEmpty
        return Button {
            custom = ""
            separator = value
        } label: {
            Text(title)
                .font(.body)
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(Capsule().fill(on ? Color.accentColor.opacity(0.18)
                                              : Color.primary.opacity(0.06)))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 이 칸 채우기 (어디서 → 어떻게)

/// 틀 안의 칸 하나를 채우는 창. **어디서 가져올지**(파일별 칸 목록)를 먼저 고르고,
/// 여러 개를 골랐으면 **어떻게 넣을지**(순서·사이에 넣을 것)를 정한다.
struct FillColumnSheet: View {
    struct Candidate: Identifiable {
        let column: UnifiedColumn
        let fileName: String
        let fileIndex: Int
        let samples: [String]
        let percent: Int?          // 값으로 추천된 정도 (없으면 nil)
        var id: String { fileName + "\u{1}" + column.rawValue }
    }

    let target: UnifiedColumn
    let inTemplate: Bool
    let candidates: [Candidate]
    let onApply: (_ sources: [UnifiedColumn], _ separator: String) -> Void
    let onGenerate: () -> Void
    let onClose: () -> Void

    @State private var picked: [UnifiedColumn] = []
    @State private var separator = " "
    @State private var custom = ""

    /// 파일별로 묶어 보여 준다 — 어느 파일의 어느 칸인지 헷갈리지 않게.
    private var byFile: [(file: String, items: [Candidate])] {
        var order: [String] = []
        var map: [String: [Candidate]] = [:]
        for c in candidates {
            if map[c.fileName] == nil { order.append(c.fileName) }
            map[c.fileName, default: []].append(c)
        }
        return order.map { (file: $0, items: map[$0] ?? []) }
    }

    private var previewLine: String {
        let parts = picked.compactMap { col in
            candidates.first { $0.column == col }?.samples.first
        }.filter { !$0.isEmpty }
        return parts.isEmpty ? "—" : parts.joined(separator: separator)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text("‘\(target.rawValue)’ 채우기").font(.title2.weight(.bold))
                Text(inTemplate ? "틀 안의 칸이에요 — 여기에 값을 넣으면 완성본이 채워집니다."
                                : "이 칸에 넣을 값을 고르세요.")
                    .font(.body).foregroundStyle(.secondary)
            }

            Text("① 어디서 가져올까요?").font(.body.weight(.semibold))
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(byFile, id: \.file) { group in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(group.file)
                                .font(.body.weight(.semibold)).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.middle)
                            ForEach(group.items) { item in
                                sourceRow(item)
                            }
                        }
                    }
                    if candidates.isEmpty {
                        Text("가져올 만한 칸을 못 찾았어요. 값을 직접 만들어 넣을 수 있습니다.")
                            .font(.body).foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxHeight: 240)

            if picked.count >= 2 {
                Text("② 어떻게 넣을까요?").font(.body.weight(.semibold))
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(picked.enumerated()), id: \.element) { idx, col in
                        HStack(spacing: 8) {
                            Text("\(idx + 1).").font(.body.monospacedDigit())
                                .foregroundStyle(.secondary)
                            Text(col.rawValue).font(.body).lineLimit(1)
                            Spacer(minLength: 8)
                            Button { move(idx, by: -1) } label: { Image(systemName: "arrow.up") }
                                .disabled(idx == 0)
                            Button { move(idx, by: 1) } label: { Image(systemName: "arrow.down") }
                                .disabled(idx == picked.count - 1)
                        }
                    }
                    HStack(spacing: 8) {
                        Text("사이에").font(.body)
                        chip("붙여쓰기", "")
                        chip("공백", " ")
                        chip("쉼표", ", ")
                        chip("하이픈", "-")
                        TextField("직접", text: $custom)
                            .textFieldStyle(.roundedBorder).frame(width: 80)
                            .onChange(of: custom) { v in if !v.isEmpty { separator = v } }
                    }
                }
            }

            HStack(spacing: 8) {
                Text("이렇게 됩니다").font(.body.weight(.semibold))
                Text(previewLine)
                    .font(.body).lineLimit(1)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 6)
                        .fill(Color.accentColor.opacity(0.12)))
            }

            HStack {
                Button("값 만들기…") { onGenerate() }
                Spacer()
                Button("취소") { onClose() }
                Button("채우기") { onApply(picked, separator) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(picked.isEmpty)
            }
        }
        .padding(20)
        .frame(minWidth: 560)
        .onAppear {
            // 가장 그럴듯한 후보 하나를 미리 골라 둔다.
            if picked.isEmpty, let best = candidates.first(where: { ($0.percent ?? 0) >= 70 }) {
                picked = [best.column]
            }
        }
    }

    private func sourceRow(_ item: Candidate) -> some View {
        let on = picked.contains(item.column)
        return Button {
            if on { picked.removeAll { $0 == item.column } } else { picked.append(item.column) }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: on ? "checkmark.square.fill" : "square")
                    .foregroundStyle(on ? Color.accentColor : Color.secondary.opacity(0.7))
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(item.column.rawValue).font(.body).lineLimit(1)
                        if let p = item.percent {
                            Text("\(p)%")
                                .font(.body.weight(.semibold)).foregroundStyle(Color.accentColor)
                        }
                    }
                    Text(item.samples.prefix(3).joined(separator: " · "))
                        .font(.body).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.tail)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8)
                .fill(on ? Color.accentColor.opacity(0.10)
                      : Color(nsColor: .controlBackgroundColor)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func move(_ idx: Int, by delta: Int) {
        let j = idx + delta
        guard picked.indices.contains(j) else { return }
        picked.swapAt(idx, j)
    }

    private func chip(_ title: String, _ value: String) -> some View {
        let on = separator == value && custom.isEmpty
        return Button {
            custom = ""
            separator = value
        } label: {
            Text(title)
                .font(.body)
                .padding(.horizontal, 10).padding(.vertical, 3)
                .background(Capsule().fill(on ? Color.accentColor.opacity(0.18)
                                              : Color.primary.opacity(0.06)))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 변경 내역 (이전 → 이후)

/// 값 정리가 무엇을 어떻게 바꿨는지 모아 보는 창.
/// 값 단위로 묶어서 ‘이 값이 저 값으로, 몇 행에서’를 한 줄로 읽게 한다.
struct ChangeLogSheet: View {
    let changes: [ChangeRecord]
    let onClose: () -> Void

    @State private var query = ""
    @State private var column: UnifiedColumn?

    /// 컬럼 · 이전 값 · 새 값이 같은 것끼리 묶는다.
    struct Group: Identifiable {
        let column: UnifiedColumn
        let before: String
        let after: String
        var rows: [String]           // 어느 행이었는지 (Code·이메일·행 번호)
        var files: Set<String>
        var id: String { column.rawValue + "\u{1}" + before + "\u{1}" + after }
    }

    private var columns: [UnifiedColumn] {
        var seen = Set<UnifiedColumn>()
        return changes.compactMap { seen.insert($0.column).inserted ? $0.column : nil }
    }

    private var groups: [Group] {
        var map: [String: Group] = [:]
        var order: [String] = []
        for c in changes {
            if let col = column, c.column != col { continue }
            if !query.isEmpty,
               !c.before.localizedCaseInsensitiveContains(query),
               !c.after.localizedCaseInsensitiveContains(query),
               !c.column.rawValue.localizedCaseInsensitiveContains(query) { continue }
            let key = c.column.rawValue + "\u{1}" + c.before + "\u{1}" + c.after
            if map[key] == nil {
                map[key] = Group(column: c.column, before: c.before, after: c.after,
                                 rows: [], files: [])
                order.append(key)
            }
            if map[key]!.rows.count < 50 { map[key]!.rows.append(c.ref) }
            map[key]!.files.insert(c.file)
        }
        return order.compactMap { map[$0] }.sorted { $0.rows.count > $1.rows.count }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("변경 내역").font(.title2.weight(.bold))
                    Text("값 정리가 바꾼 칸 \(changes.count)개 — 이전 값이 무엇이었는지 그대로 남습니다.")
                        .font(.body).foregroundStyle(.secondary)
                }
                Spacer()
                Picker("컬럼", selection: $column) {
                    Text("모든 컬럼").tag(UnifiedColumn?.none)
                    ForEach(columns) { c in Text(c.rawValue).tag(UnifiedColumn?.some(c)) }
                }
                .frame(maxWidth: 220)
                TextField("값 검색…", text: $query)
                    .textFieldStyle(.roundedBorder).frame(width: 180)
                Button("복사") { copyAll() }
                Button("닫기") { onClose() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(16)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(groups) { g in row(g) }
                    if groups.isEmpty {
                        Text("바뀐 값이 없습니다.")
                            .font(.body).foregroundStyle(.secondary)
                            .padding(20)
                    }
                }
                .padding(16)
            }
        }
        .frame(minWidth: 720, minHeight: 480)
    }

    private func row(_ g: Group) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(g.column.rawValue)
                    .font(.body.weight(.semibold)).foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text("\(g.rows.count)행")
                    .font(.body.monospacedDigit()).foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                Text(g.before.isEmpty ? "(빈 칸)" : g.before)
                    .font(.body)
                    .foregroundStyle(g.before.isEmpty ? .secondary : .primary)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 6)
                        .fill(Color.primary.opacity(0.06)))
                Image(systemName: "arrow.right").foregroundStyle(.secondary)
                Text(g.after.isEmpty ? "(빈 칸)" : g.after)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 6)
                        .fill(Color.accentColor.opacity(0.14)))
                Spacer(minLength: 0)
            }
            Text(g.files.sorted().joined(separator: " · ")
                 + " · " + g.rows.prefix(4).joined(separator: ", ")
                 + (g.rows.count > 4 ? " 외" : ""))
                .font(.body).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.tail)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10)
            .fill(Color(nsColor: .controlBackgroundColor)))
    }

    private func copyAll() {
        var lines = ["컬럼\t이전 값\t새 값\t행 수\t파일"]
        for g in groups {
            lines.append([g.column.rawValue, g.before, g.after, "\(g.rows.count)",
                          g.files.sorted().joined(separator: " ")].joined(separator: "\t"))
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
    }
}

/// 여러 컬럼을 한꺼번에 고른 다음 ‘데이터 정리하기’를 눌렀을 때 나오는 창.
/// 틀 안의 칸을 **기준**으로 세워 두고, 그 칸마다 **틀 밖의 어느 컬럼에서
/// 값을 가져올지**를 한 줄씩 정한다. (이 도구의 목표가 틀 안의 행을 채우는 것이므로,
/// 값 형식을 다듬는 일보다 이 결정이 먼저다.)
struct FillFromSheet: View {
    struct Candidate: Identifiable {
        let column: UnifiedColumn
        let fileName: String
        let samples: [String]
        let percent: Int?          // 값 모양으로 추천된 정도
        var id: String { fileName + "\u{1}" + column.rawValue }
    }

    /// 값을 채워야 할 틀 안 컬럼 — 빈 행이 많은 순서.
    let targets: [UnifiedColumn]
    /// 컬럼마다 비어 있는 행 수와, 전체 행 수.
    let holes: [UnifiedColumn: Int]
    let rowTotal: Int
    /// 이번에 함께 고른 컬럼들 (후보 맨 위에 따로 모아 보여 준다).
    let selectedOutside: [UnifiedColumn]
    /// 대상 컬럼 → 가져올 만한 후보들.
    let candidates: [UnifiedColumn: [Candidate]]
    /// 대상마다 **여러 컬럼을 순서대로** 합쳐 넣을 수 있다 (성 + 이름 → 김 철수).
    let onApply: (_ plans: [(target: UnifiedColumn,
                             sources: [UnifiedColumn],
                             separator: String,
                             mode: CombineMode)],
                  _ thenClean: Bool) -> Void
    /// 가져올 컬럼이 없을 때 — 패턴(고정값·번호 매기기)을 만들어 자동으로 채운다.
    let onGenerate: (UnifiedColumn) -> Void
    /// 값을 가져오는 게 아니라, 이미 있는 값의 오타·표기만 손보러 갈 때.
    let onCleanOnly: () -> Void
    let onClose: () -> Void

    /// 대상 → 고른 출처들 (고른 순서가 곧 붙는 순서).
    @State private var pick: [UnifiedColumn: [UnifiedColumn]] = [:]
    /// 대상 → 사이에 넣을 글자 (둘 이상 골랐을 때만 쓴다).
    @State private var sep: [UnifiedColumn: String] = [:]
    /// 대상 → 어떻게 넣을지 (이어 붙이기 / 값이 있는 첫 칸만).
    @State private var how: [UnifiedColumn: CombineMode] = [:]
    /// 채운 뒤 곧바로 값 정리 화면으로 갈지.
    @State private var thenClean = false
    @State private var didSeed = false

    /// 받을 칸을 뺀, 함께 고른 컬럼들 (= 넣을 재료).
    private var materials: [UnifiedColumn] {
        let targetSet = Set(targets)
        return selectedOutside.filter { !targetSet.contains($0) }
    }

    private func sources(_ t: UnifiedColumn) -> [UnifiedColumn] { pick[t] ?? [] }
    private func separator(_ t: UnifiedColumn) -> String { sep[t] ?? " " }
    private func mode(_ t: UnifiedColumn) -> CombineMode { how[t] ?? .join }

    private var chosen: [(target: UnifiedColumn, sources: [UnifiedColumn],
                          separator: String, mode: CombineMode)] {
        targets.compactMap { t in
            let list = sources(t)
            return list.isEmpty ? nil
                : (target: t, sources: list, separator: separator(t), mode: mode(t))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text("틀 안의 칸을 어디서 채울까요?").font(.title2.weight(.bold))
                Text("고른 것 중 \(targets.count)개를 값을 받을 칸으로 세웠어요"
                     + (materials.isEmpty ? ""
                        : " — 나머지 \(materials.count)개(\(materials.map(\.rawValue).joined(separator: " · ")))는 "
                          + "여기에 넣을 재료입니다")
                     + ". 행 수는 그대로예요 — 값이 자리를 옮길 뿐입니다.")
                    .font(.body).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                // ‘+’로 이어 붙인 문자열엔 마크다운이 먹지 않는다 — 강조 없이 또렷한 문장으로.
                Text("둘 이상 고르면 사이에 무엇을 넣을지 정해 한 칸으로 붙습니다 "
                     + "— 국문 성 + 국문 이름 → 김 철수. "
                     + "가져올 컬럼이 아예 없으면 ‘패턴으로 채우기’로 같은 값이나 번호를 만들어 넣으세요.")
                    .font(.body).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(targets, id: \.self) { t in
                        targetRow(t)
                    }
                }
            }
            .frame(maxHeight: 400)

            Toggle(isOn: $thenClean) {
                Text("채운 뒤에 이어서 값도 하나로 통일하기 (male → 남성처럼)")
            }
            .toggleStyle(.checkbox)
            .help("채우고 나면 그 컬럼의 값 정리 화면으로 바로 넘어갑니다.")

            HStack(spacing: 10) {
                Button("이미 있는 값의 오타·표기 정리…") { onCleanOnly() }
                    .help("값을 새로 가져오지 않고, 고른 컬럼에 이미 들어 있는 값만 손봅니다 — "
                          + "같은 뜻인데 다르게 적힌 값을 하나로 모으고, 예시를 적으면 규칙을 찾아 한꺼번에 고칩니다.")
                Spacer()
                Button("닫기") { onClose() }
                Button(chosen.isEmpty ? "가져오기" : "\(chosen.count)개 칸 채우기") {
                    onApply(chosen, thenClean)
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(chosen.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 780)
        .onAppear { if !didSeed { seed(); didSeed = true } }
    }

    /// 한 줄 = 틀 안의 칸 하나. 왼쪽이 기준(틀 안), 오른쪽이 가져올 곳(틀 밖).
    private func targetRow(_ t: UnifiedColumn) -> some View {
        let list = candidates[t] ?? []
        let blank = holes[t] ?? 0
        let picked = sources(t)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(t.rawValue).font(.body.weight(.semibold))
                        .lineLimit(1).truncationMode(.tail)
                    Text(blank > 0 ? "\(blank)/\(rowTotal)행 비어 있음"
                                   : (picked.isEmpty ? "다 차 있음" : "지금 값은 새 값으로 바뀜"))
                        .font(.body).monospacedDigit()
                        .foregroundStyle(blank > 0 ? Color.accentColor
                                         : (picked.isEmpty ? .secondary : .orange))
                }
                .frame(width: 220, alignment: .leading)

                Image(systemName: "arrow.left").foregroundStyle(.secondary)

                // 여러 개를 고를 수 있는 메뉴 — 고른 순서대로 붙는다.
                Menu {
                    if picked.isEmpty == false {
                        Button("고른 것 모두 빼기") { pick[t] = [] }
                        Divider()
                    }
                    // 함께 체크해 온 컬럼을 맨 위에 따로 — 100개 넘는 목록에서 찾아 헤매지 않게.
                    let near = list.filter { selectedOutside.contains($0.column) }
                    let rest = list.filter { !selectedOutside.contains($0.column) }
                    if !near.isEmpty {
                        Section("함께 고른 컬럼") {
                            ForEach(near) { c in candidateButton(t, c, picked) }
                        }
                    }
                    Section(near.isEmpty ? "" : "그 밖의 컬럼") {
                        ForEach(rest) { c in candidateButton(t, c, picked) }
                    }
                } label: {
                    Text(menuLabel(t))
                        .lineLimit(1).truncationMode(.tail)
                }
                .disabled(list.isEmpty)
                .frame(maxWidth: .infinity)

                Button("패턴으로 채우기…") { onGenerate(t) }
                    .fixedSize()
                    .help("모든 행에 같은 값을 넣거나, 첫 번호를 적어 1씩 올라가는 번호를 만들어 넣습니다.")
            }

            if picked.count >= 2 {
                // ① 어떻게 넣을지 — 이어 붙일지, 값이 있는 것 하나만 쓸지.
                HStack(spacing: 8) {
                    Text("어떻게").font(.body).foregroundStyle(.secondary)
                    Picker("", selection: Binding(get: { mode(t) },
                                                  set: { how[t] = $0 })) {
                        Text("이어 붙이기 (성 + 이름 → 김 철수)").tag(CombineMode.join)
                        Text("값이 있는 것 하나만 (남성/여성 · male/female)").tag(CombineMode.first)
                    }
                    .labelsHidden()
                    .pickerStyle(.radioGroup)
                    Spacer(minLength: 0)
                }
                .padding(.leading, 228)

                // 붙는 순서와 사이 글자 — 바로 아래에 결과 예시가 따라온다.
                HStack(spacing: 6) {
                    ForEach(Array(picked.enumerated()), id: \.element) { idx, col in
                        HStack(spacing: 3) {
                            Text("\(idx + 1).").font(.body.monospacedDigit())
                                .foregroundStyle(.secondary)
                            Text(col.rawValue).font(.body).lineLimit(1)
                            Button { move(t, idx, -1) } label: { Image(systemName: "chevron.left") }
                                .buttonStyle(.plain).disabled(idx == 0)
                            Button { move(t, idx, 1) } label: { Image(systemName: "chevron.right") }
                                .buttonStyle(.plain).disabled(idx == picked.count - 1)
                            Button { toggle(t, col) } label: { Image(systemName: "xmark") }
                                .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(Color.accentColor.opacity(0.12)))
                    }
                    if mode(t) == .join {
                        Text("사이에").font(.body).foregroundStyle(.secondary)
                        sepChip(t, "붙여쓰기", "")
                        sepChip(t, "공백", " ")
                        sepChip(t, "쉼표", ", ")
                        sepChip(t, "하이픈", "-")
                    } else {
                        Text("앞의 것부터 — 비어 있으면 다음 것을 씁니다")
                            .font(.body).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.leading, 228)
            }

            if !picked.isEmpty {
                Text("이렇게 들어갑니다 → \(previewLine(t))")
                    .font(.body.weight(.medium)).foregroundStyle(Color.accentColor)
                    .lineLimit(1).truncationMode(.tail)
                    .padding(.leading, 228)
            } else if list.isEmpty {
                Text("가져올 만한 컬럼을 못 찾았어요 — 표에서 그 컬럼도 같이 고르거나, 패턴으로 채우세요.")
                    .font(.body).foregroundStyle(.secondary)
                    .padding(.leading, 228)
            }
        }
        .padding(.vertical, 8).padding(.horizontal, 10)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(picked.isEmpty ? Color.primary.opacity(0.03)
                                 : Color.accentColor.opacity(0.08)))
    }

    private func candidateButton(_ t: UnifiedColumn, _ c: Candidate,
                                 _ picked: [UnifiedColumn]) -> some View {
        Button { toggle(t, c.column) } label: {
            Label(c.percent.map { "\(c.column.rawValue) — \($0)% 닮음" } ?? c.column.rawValue,
                  systemImage: picked.contains(c.column) ? "checkmark" : "")
        }
    }

    private func menuLabel(_ t: UnifiedColumn) -> String {
        let picked = sources(t)
        if picked.isEmpty { return (candidates[t] ?? []).isEmpty ? "가져올 곳 없음" : "가져올 컬럼 고르기…" }
        if picked.count == 1 { return picked[0].rawValue }
        return picked.map(\.rawValue).joined(separator: " + ")
    }

    /// 고른 컬럼들의 첫 예시 값을 실제로 붙여 본 결과.
    private func previewLine(_ t: UnifiedColumn) -> String {
        let list = candidates[t] ?? []
        let parts = sources(t).compactMap { col in
            list.first { $0.column == col }?.samples.first
        }.filter { !$0.isEmpty }
        if parts.isEmpty { return "—" }
        return mode(t) == .first ? parts[0] : parts.joined(separator: separator(t))
    }

    private func sepChip(_ t: UnifiedColumn, _ title: String, _ value: String) -> some View {
        let on = separator(t) == value
        return Button(title) { sep[t] = value }
            .buttonStyle(.plain)
            .font(.body.weight(on ? .semibold : .regular))
            .foregroundStyle(on ? Color.accentColor : .secondary)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(Capsule().fill(on ? Color.accentColor.opacity(0.16)
                                          : Color.primary.opacity(0.06)))
    }

    private func toggle(_ t: UnifiedColumn, _ col: UnifiedColumn) {
        var list = sources(t)
        if let i = list.firstIndex(of: col) { list.remove(at: i) } else { list.append(col) }
        pick[t] = list
    }

    private func move(_ t: UnifiedColumn, _ idx: Int, _ delta: Int) {
        var list = sources(t)
        let j = idx + delta
        guard list.indices.contains(idx), list.indices.contains(j) else { return }
        list.swapAt(idx, j)
        pick[t] = list
    }

    /// 받을 칸이 하나뿐이면, **함께 고른 나머지를 그대로 재료로 넣어 둔다.**
    /// 세 개를 체크하고 ‘합쳐 채우기’를 누른 사람의 뜻이 그거니까 — 창을 열자마자
    /// `① 국문 성 ② 국문 이름`과 `이렇게 들어갑니다 → 김 철수`가 보여야 한다.
    /// 받을 칸이 여럿이면 값 모양이 닮은 짝만 하나씩 미리 골라 둔다.
    private func seed() {
        let targetSet = Set(targets)
        let others = selectedOutside.filter { !targetSet.contains($0) }
        if targets.count == 1, !others.isEmpty {
            let list = candidates[targets[0]] ?? []
            let usable = others.filter { c in list.contains { $0.column == c } }
            if !usable.isEmpty { pick[targets[0]] = usable; return }
        }
        var used = Set<UnifiedColumn>()
        for t in targets {
            let list = candidates[t] ?? []
            guard let best = list.first(where: {
                others.contains($0.column) && ($0.percent ?? 0) > 0 && !used.contains($0.column)
            }) else { continue }
            pick[t] = [best.column]
            used.insert(best.column)
        }
    }
}

/// 컬럼 하나를 눌렀을 때 나오는 창 — **무엇을 할지 먼저 고른다.**
/// 값을 다듬을지, 다른 칸으로 옮길지, 복제할지, 여러 칸과 합칠지.
/// 옮기거나 복제할 땐 **양쪽에 값이 다 있는 행(충돌)을 어떻게 할지**까지 정한다.
struct ColumnActionSheet: View {

    enum Action: String, CaseIterable, Identifiable {
        case clean, move, copy, merge
        var id: String { rawValue }
        var title: String {
            switch self {
            case .clean: return "값 정리하기 — 오타·형식을 그 자리에서 맞춥니다"
            case .move:  return "다른 컬럼으로 옮기기 — 이 컬럼은 없어집니다"
            case .copy:  return "다른 컬럼에 복제하기 — 이 컬럼도 그대로 남습니다"
            case .merge: return "여러 컬럼과 한 칸으로 합치기…"
            }
        }
    }

    /// 양쪽에 값이 다 있을 때 무엇을 남길지.
    enum Conflict: String, CaseIterable, Identifiable {
        case keepDestination, takeSource, joinBoth
        var id: String { rawValue }
        var title: String {
            switch self {
            case .keepDestination: return "받는 칸 값을 그대로 두기 (빈 칸만 채움)"
            case .takeSource:      return "가져온 값으로 덮어쓰기"
            case .joinBoth:        return "둘 다 이어 붙이기"
            }
        }
    }

    let source: UnifiedColumn
    /// 받을 수 있는 컬럼들 — (컬럼, 틀 안인가, 비어 있는 행 수).
    let destinations: [(column: UnifiedColumn, inTemplate: Bool, blank: Int)]
    let rowTotal: Int
    /// 값 예시 (미리보기용).
    let sample: (UnifiedColumn) -> String
    /// 받는 칸과 이 컬럼이 **둘 다 차 있는 행 수** 등 — 충돌 규모를 미리 보여 준다.
    let overlap: (UnifiedColumn) -> (both: Int, srcOnly: Int, destOnly: Int)
    /// 옮기기·복제 실행. `keepSource`가 true면 복제.
    let onApply: (_ destination: UnifiedColumn, _ order: [UnifiedColumn],
                  _ separator: String, _ mode: CombineMode, _ keepSource: Bool) -> Void
    let onClean: () -> Void
    let onMerge: () -> Void
    let onClose: () -> Void

    @State private var action: Action = .move
    @State private var destination: UnifiedColumn?
    @State private var conflict: Conflict = .keepDestination
    @State private var separator = " "

    private var counts: (both: Int, srcOnly: Int, destOnly: Int)? {
        destination.map { overlap($0) }
    }

    /// 실제 값으로 결과를 보여 준다 — 어떤 선택이 무슨 결과인지 글보다 이게 빠르다.
    private var previewLine: String {
        let from = sample(source)
        guard let dest = destination else { return from.isEmpty ? "—" : from }
        let to = sample(dest)
        switch conflict {
        case .takeSource:      return from.isEmpty ? (to.isEmpty ? "(빈 칸)" : to) : from
        case .keepDestination: return to.isEmpty ? (from.isEmpty ? "(빈 칸)" : from) : to
        case .joinBoth:
            let parts = [to, from].filter { !$0.isEmpty }
            return parts.isEmpty ? "(빈 칸)" : parts.joined(separator: separator)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text("‘\(source.rawValue)’ — 무엇을 할까요?").font(.title2.weight(.bold))
                Text("행 수는 어떤 경우에도 그대로예요 — 값이 자리를 옮기거나 다듬어질 뿐입니다.")
                    .font(.body).foregroundStyle(.secondary)
            }

            Picker("", selection: $action) {
                ForEach(Action.allCases) { a in Text(a.title).tag(a) }
            }
            .labelsHidden()
            .pickerStyle(.radioGroup)

            if action == .move || action == .copy {
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    Text("어느 컬럼으로").font(.body.weight(.semibold))
                    Picker("", selection: $destination) {
                        Text("고르세요").tag(UnifiedColumn?.none)
                        ForEach(destinations, id: \.column) { d in
                            Text(d.column.rawValue
                                 + (d.inTemplate ? "  (틀 안" : "  (틀 밖")
                                 + (d.blank > 0 ? " · \(d.blank)/\(rowTotal)행 비어 있음)" : " · 다 참)"))
                                .tag(UnifiedColumn?.some(d.column))
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 460)
                }

                if let c = counts {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            Text("겹치는 행").font(.body.weight(.semibold))
                            Text(c.both == 0
                                 ? "없어요 — 그냥 빈 칸에 들어갑니다"
                                 : "\(c.both)행은 양쪽에 값이 다 있어요")
                                .font(.body)
                                .foregroundStyle(c.both == 0 ? .secondary : Color.orange)
                            Text("· 이 컬럼만 \(c.srcOnly)행 · 받는 칸만 \(c.destOnly)행")
                                .font(.body).foregroundStyle(.secondary)
                        }
                        if c.both > 0 {
                            Text("겹칠 때 어떻게 할까요?").font(.body.weight(.semibold))
                            Picker("", selection: $conflict) {
                                ForEach(Conflict.allCases) { k in Text(k.title).tag(k) }
                            }
                            .labelsHidden()
                            .pickerStyle(.radioGroup)
                            if conflict == .joinBoth {
                                HStack(spacing: 8) {
                                    Text("사이에").font(.body).foregroundStyle(.secondary)
                                    chip("붙여쓰기", "")
                                    chip("공백", " ")
                                    chip("쉼표", ", ")
                                    chip("하이픈", "-")
                                    Spacer(minLength: 0)
                                }
                            }
                        }
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(c.both > 0 ? Color.orange.opacity(0.08) : Color.primary.opacity(0.04)))
                }

                HStack(spacing: 8) {
                    Text("이렇게 됩니다").font(.body.weight(.semibold))
                    Text(previewLine)
                        .font(.body).lineLimit(1).truncationMode(.tail)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: 6)
                            .fill(Color.accentColor.opacity(0.12)))
                    Spacer(minLength: 0)
                }
            }

            HStack {
                Spacer()
                Button("취소") { onClose() }
                Button(actionTitle) { run() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled((action == .move || action == .copy) && destination == nil)
            }
        }
        .padding(20)
        .frame(width: 680)
    }

    private var actionTitle: String {
        switch action {
        case .clean: return "값 정리하러 가기"
        case .move:  return "옮기기"
        case .copy:  return "복제하기"
        case .merge: return "합칠 컬럼 고르기…"
        }
    }

    private func run() {
        switch action {
        case .clean: onClean()
        case .merge: onMerge()
        case .move, .copy:
            guard let dest = destination else { return }
            let keep = (action == .copy)
            switch conflict {
            case .takeSource:      onApply(dest, [source, dest], " ", .first, keep)
            case .keepDestination: onApply(dest, [dest, source], " ", .first, keep)
            case .joinBoth:        onApply(dest, [dest, source], separator, .join, keep)
            }
        }
    }

    private func chip(_ title: String, _ value: String) -> some View {
        let on = separator == value
        return Button(title) { separator = value }
            .buttonStyle(.plain)
            .font(.body.weight(on ? .semibold : .regular))
            .foregroundStyle(on ? Color.accentColor : .secondary)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Capsule().fill(on ? Color.accentColor.opacity(0.16)
                                          : Color.primary.opacity(0.06)))
    }
}
