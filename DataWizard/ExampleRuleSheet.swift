import SwiftUI

/// “지금 값 → 바꾸고 싶은 값”을 몇 개 보여 주면 규칙을 찾아 주는 시트.
///
/// 정규식을 몰라도, 고치고 싶은 값 두어 개만 손으로 적으면 같은 규칙이 걸리는
/// 나머지 값까지 한꺼번에 정리된다. 고르기 전에 무엇이 바뀌는지 전부 보여 준다.
struct ExampleRuleSheet: View {
    let column: UnifiedColumn
    let values: [DistinctValue]
    @Binding var mapping: [String: String]
    let onClose: () -> Void

    @State private var examples: [RuleExample] = [RuleExample(), RuleExample()]
    @State private var selectedRuleID: String?
    @State private var didSeed = false

    // MARK: - 계산

    private var sample: [String] { values.map(\.value) }
    private var candidates: [RuleCandidate] {
        RuleInference.suggest(from: examples, sample: sample)
    }
    private var selectedRule: RuleCandidate? {
        candidates.first { $0.id == selectedRuleID } ?? candidates.first
    }
    private var usableCount: Int { examples.filter(\.isUsable).count }

    /// 이 컬럼에 실제로는 없는 값을 예시로 적었을 때 알려 주기 위한 목록.
    private var unknownExamples: [String] {
        let known = Set(sample)
        return examples.filter(\.isUsable).map(\.before).filter { !known.contains($0) }
    }

    private struct Change: Identifiable {
        var id: String { from }
        let from: String
        let to: String
        let count: Int
    }

    private func changes(for rule: RuleCandidate) -> [Change] {
        values.compactMap { dv in
            let out = rule.apply(dv.value)
            return out == dv.value ? nil : Change(from: dv.value, to: out, count: dv.count)
        }
    }

    private func impact(_ rule: RuleCandidate) -> Int {
        values.reduce(0) { $0 + (rule.apply($1.value) == $1.value ? 0 : 1) }
    }

    // MARK: - 화면

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    examplesSection
                    Divider()
                    rulesSection
                    if let rule = selectedRule, usableCount > 0 {
                        Divider()
                        previewSection(rule)
                    }
                }
                .padding(16)
            }
            Divider()
            footer
        }
        .frame(width: 780, height: 700)
        .onAppear {
            guard !didSeed else { return }
            didSeed = true
            // 첫 줄에 이 컬럼에서 가장 많이 나온 값을 채워 둔다 — 빈 칸부터 시작하지 않게.
            if let top = values.first?.value, examples.indices.contains(0) {
                examples[0].before = top
            }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("‘\(column.rawValue)’ — 예시로 규칙 만들기").font(.headline)
                Text("고치고 싶은 값 두어 개만 ‘지금 값 → 바꾸고 싶은 값’으로 적어 주세요. 같은 규칙이 걸리는 나머지 값까지 찾아 드립니다.")
                    .font(.body).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button("닫기", action: onClose).keyboardShortcut(.cancelAction)
        }
        .padding(16)
    }

    // MARK: 1단계 — 예시 적기

    private var examplesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                stepLabel(1, "이렇게 바꾸고 싶어요")
                Spacer()
                Text("예:  서울특별시 → 서울    ·    2004.05.31 → 2004-05-31")
                    .font(.body).foregroundStyle(.tertiary)
            }

            HStack(spacing: 8) {
                Text("지금 값").font(.body.weight(.semibold)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Spacer().frame(width: 22)
                Text("바꾸고 싶은 값").font(.body.weight(.semibold)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Spacer().frame(width: 26)
            }

            ForEach($examples) { $ex in
                exampleRow($ex)
            }

            HStack(spacing: 10) {
                Button {
                    examples.append(RuleExample())
                } label: {
                    Label("예시 한 줄 더", systemImage: "plus.circle")
                }
                .controlSize(.small)
                Text(usableCount == 0
                     ? "한 줄만 적어도 제안이 나와요. 두 줄 이상이면 훨씬 정확해집니다."
                     : "예시 \(usableCount)개로 규칙을 찾았어요."
                        + (usableCount == 1 ? " 한 줄 더 적으면 더 정확해집니다." : ""))
                    .font(.body).foregroundStyle(.secondary)
                Spacer()
            }

            if !unknownExamples.isEmpty {
                Label("이 컬럼에 없는 값이에요: " + unknownExamples.joined(separator: ", ")
                      + " — 오타가 아닌지 확인해 주세요.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.body).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func exampleRow(_ ex: Binding<RuleExample>) -> some View {
        HStack(spacing: 8) {
            HStack(spacing: 4) {
                TextField("지금 값", text: ex.before)
                    .textFieldStyle(.roundedBorder)
                // 직접 타이핑하지 않고 이 컬럼의 실제 값에서 고를 수 있게.
                Menu {
                    ForEach(values.prefix(300)) { dv in
                        Button("\(dv.value)  (\(dv.count)행)") { ex.wrappedValue.before = dv.value }
                    }
                } label: {
                    Image(systemName: "list.bullet")
                }
                .menuStyle(.borderlessButton)
                .frame(width: 22)
                .help("이 컬럼에 실제로 있는 값 중에서 고릅니다.")
            }
            .frame(maxWidth: .infinity)

            Image(systemName: "arrow.right")
                .font(.body).foregroundStyle(.secondary)
                .frame(width: 22)

            TextField("바꾸고 싶은 값", text: ex.after)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: .infinity)

            Button {
                examples.removeAll { $0.id == ex.wrappedValue.id }
                if examples.isEmpty { examples = [RuleExample()] }
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .frame(width: 26)
            .help("이 예시 줄 지우기")
        }
    }

    // MARK: 2단계 — 규칙 고르기

    private var rulesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            stepLabel(2, "이런 규칙일까요? 하나 골라 주세요")

            if usableCount == 0 {
                emptyCard("위에 ‘지금 값’과 ‘바꾸고 싶은 값’을 한 줄만 채워도 규칙 제안이 나옵니다.",
                          icon: "arrow.up")
            } else if candidates.isEmpty {
                emptyCard("적어 주신 예시를 모두 설명하는 규칙을 찾지 못했어요. 예시가 서로 다른 규칙이면 나눠서 하시거나, 값을 다시 확인해 주세요.",
                          icon: "questionmark.circle")
            } else {
                VStack(spacing: 6) {
                    ForEach(candidates) { rule in
                        ruleRow(rule)
                    }
                }
            }
        }
    }

    private func ruleRow(_ rule: RuleCandidate) -> some View {
        let isOn = selectedRule?.id == rule.id
        let n = impact(rule)
        return Button {
            selectedRuleID = rule.id
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: isOn ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(isOn ? Color.accentColor : Color.secondary)
                VStack(alignment: .leading, spacing: 3) {
                    Text(rule.title)
                        .font(.body.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    Text(rule.detail)
                        .font(.body).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(n)종 바뀜")
                        .font(.body.weight(.semibold)).monospacedDigit()
                        .foregroundStyle(n == 0 ? Color.secondary : Color.accentColor)
                    Text("전체 \(values.count)종 중")
                        .font(.body).foregroundStyle(.tertiary)
                    if rule.isLiteralOnly {
                        Text("다른 값 영향 없음")
                            .font(.body).foregroundStyle(.green)
                    }
                }
                .fixedSize()
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isOn ? Color.accentColor.opacity(0.08) : Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(isOn ? Color.accentColor.opacity(0.45) : Color.primary.opacity(0.06),
                        lineWidth: isOn ? 1.5 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: 3단계 — 적용 결과 미리보기

    private func previewSection(_ rule: RuleCandidate) -> some View {
        let list = changes(for: rule)
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                stepLabel(3, "이렇게 바뀝니다")
                Spacer()
                Text(list.isEmpty ? "바뀌는 값 없음"
                                  : "\(list.count)종 · \(list.reduce(0) { $0 + $1.count })행")
                    .font(.body).foregroundStyle(.secondary).monospacedDigit()
            }
            if list.isEmpty {
                emptyCard("이 규칙으로는 바뀌는 값이 없어요. 다른 규칙을 골라 보세요.",
                          icon: "equal.circle")
            } else {
                VStack(spacing: 0) {
                    ForEach(list.prefix(200)) { c in
                        HStack(spacing: 8) {
                            Text(c.from)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .foregroundStyle(.secondary)
                            Image(systemName: "arrow.right")
                                .font(.body).foregroundStyle(.secondary)
                            Text(c.to)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .fontWeight(.semibold).foregroundStyle(Color.accentColor)
                            Text("\(c.count)행")
                                .font(.body).foregroundStyle(.tertiary).monospacedDigit()
                                .frame(width: 52, alignment: .trailing)
                        }
                        .font(.system(.body, design: .monospaced))
                        .lineLimit(1).truncationMode(.middle)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        Divider()
                    }
                    if list.count > 200 {
                        Text("… 외 \(list.count - 200)종")
                            .font(.body).foregroundStyle(.secondary)
                            .padding(.vertical, 6)
                    }
                }
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(nsColor: .textBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1))

                Label("나머지 \(values.count - list.count)종은 손대지 않습니다. 어떤 규칙도 값을 빈칸으로 만들지 않아요.",
                      systemImage: "lock.shield")
                    .font(.body).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: 공통 조각

    private func stepLabel(_ n: Int, _ title: String) -> some View {
        HStack(spacing: 6) {
            ZStack {
                Circle().fill(Color.accentColor.opacity(0.15)).frame(width: 20, height: 20)
                Text("\(n)").font(.body.weight(.bold)).foregroundStyle(Color.accentColor)
            }
            Text(title).font(.headline)
        }
    }

    private func emptyCard(_ message: String, icon: String) -> some View {
        Label(message, systemImage: icon)
            .font(.body).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.04)))
    }

    private var footer: some View {
        HStack {
            if let rule = selectedRule, usableCount > 0 {
                Text("고른 규칙: \(rule.title)")
                    .font(.body).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.tail)
            }
            Spacer()
            Button("취소", action: onClose)
            Button(action: applyRule) {
                Text(applyLabel).fontWeight(.semibold)
            }
            .buttonStyle(.borderedProminent)
            .disabled(selectedRule == nil || usableCount == 0
                      || changes(for: selectedRule!).isEmpty)
        }
        .padding(16)
    }

    private var applyLabel: String {
        guard let rule = selectedRule, usableCount > 0 else { return "이 규칙 적용" }
        let n = changes(for: rule).count
        return n == 0 ? "바뀌는 값 없음" : "이 규칙 적용 (\(n)종)"
    }

    private func applyRule() {
        guard let rule = selectedRule else { return }
        for dv in values {
            let out = rule.apply(dv.value)
            if out != dv.value { mapping[dv.value] = out }
        }
        onClose()
    }
}
