import SwiftUI

// 컬럼 하나를 검토하는 카드와 그 본문들 — 값 통일·제안·형식·자유입력.

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
                            Label("변화 미리보기", systemImage: "arrow.left.arrow.right")
                        }
                        .help("이 컬럼이 **지금 값 → 바뀔 값**으로 어떻게 달라지는지 나란히 놓고 봅니다.")
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
