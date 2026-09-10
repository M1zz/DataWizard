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
    let onApply: (_ target: UnifiedColumn, _ order: [UnifiedColumn], _ separator: String) -> Void
    let onClose: () -> Void

    @State private var target: UnifiedColumn
    @State private var order: [UnifiedColumn]
    @State private var separator: String
    @State private var custom = ""

    init(columns: [UnifiedColumn],
         templateColumns: Set<UnifiedColumn>,
         sample: @escaping (UnifiedColumn) -> [String],
         onApply: @escaping (UnifiedColumn, [UnifiedColumn], String) -> Void,
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
        return parts.joined(separator: separator)
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
                Text("어떤 순서로 이어 붙일까요?").font(.body.weight(.semibold))
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
                Button("합치기") { onApply(target, order, separator) }
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
