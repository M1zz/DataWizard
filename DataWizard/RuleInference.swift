import Foundation

/// 사용자가 든 예시 한 쌍 — “지금 값” → “바꾸고 싶은 값”.
struct RuleExample: Identifiable, Equatable {
    var id = UUID()
    var before: String = ""
    var after: String = ""

    /// 규칙을 뽑을 수 있는 온전한 예시인가.
    /// 빈 값으로 바꾸는 예시는 받지 않는다 — 데이터가 조용히 지워지는 사고를 막기 위해.
    var isUsable: Bool { !before.isEmpty && !after.isEmpty }
    /// 한쪽만 적다 만 상태 (안내 문구용).
    var isPartial: Bool { (before.isEmpty) != (after.isEmpty) }
}

/// 예시들을 전부 설명하는 후보 규칙 하나.
struct RuleCandidate: Identifiable {
    let id: String
    let title: String          // "‘-’ 없애기"
    let detail: String         // 규칙이 실제로 하는 일 한 줄
    let rank: Int              // 낮을수록 위 (단순하고 일반적인 규칙 우선)
    /// 예시로 든 값만 바꾸는 규칙인가 (다른 값엔 영향 없음).
    let isLiteralOnly: Bool
    private let transform: (String) -> String

    init(id: String, title: String, detail: String, rank: Int,
         isLiteralOnly: Bool = false, transform: @escaping (String) -> String) {
        self.id = id; self.title = title; self.detail = detail
        self.rank = rank; self.isLiteralOnly = isLiteralOnly; self.transform = transform
    }

    /// 규칙 적용. 결과가 비면 원본을 돌려준다 — 어떤 규칙도 값을 지우지 못하게 하는 마지막 방어선.
    func apply(_ s: String) -> String {
        guard !s.isEmpty else { return s }
        let out = transform(s)
        return out.isEmpty ? s : out
    }
}

/// “지금 값 → 바꾸고 싶은 값” 예시 몇 개에서 규칙을 역으로 추론한다.
///
/// 후보를 넉넉히 만들어 두고 **사용자가 든 예시를 하나도 빠짐없이 재현하는 것만** 남긴다.
/// 정규식을 몰라도 예시 두어 개만 적으면 컬럼 전체를 정리할 수 있게 하는 게 목적.
enum RuleInference {

    // MARK: - 진입점

    /// - Parameters:
    ///   - examples: 사용자가 적은 예시들
    ///   - sample: 이 컬럼의 실제 값들 (후보가 같은 동작인지 가려내는 데 씀)
    static func suggest(from examples: [RuleExample], sample: [String]) -> [RuleCandidate] {
        // 같은 ‘지금 값’을 두 번 적었으면 마지막 것만 인정.
        var seen = Set<String>()
        let usable = examples.filter(\.isUsable).reversed()
            .filter { seen.insert($0.before).inserted }
            .reversed()
            .map { ($0.before, $0.after) }
        guard let first = usable.first else { return [] }

        var pool = globalCandidates()
        pool += diffCandidates(first.0, first.1)
        pool += charCandidates(first.0, first.1)
        pool += separatorCandidates(first.0, first.1)
        pool += lengthCandidates(first.0, first.1)
        pool += digitRegroupCandidates(first.0, first.1)
        pool += tokenTemplateCandidates(first.0, first.1)

        // 예시를 전부 재현하지 못하는 후보는 버린다.
        var kept = pool.filter { cand in usable.allSatisfy { cand.apply($0.0) == $0.1 } }

        // 동작이 완전히 같은 후보는 하나만 남긴다 (더 단순한 설명 쪽으로).
        let probe = Array(Set(usable.map { $0.0 }).union(sample.prefix(80)))
        var byBehavior: [String: RuleCandidate] = [:]
        for c in kept.sorted(by: { $0.rank < $1.rank }) {
            let key = probe.map { c.apply($0) }.joined(separator: "\u{1}")
            if byBehavior[key] == nil { byBehavior[key] = c }
        }
        kept = Array(byBehavior.values)

        // 마지막 보루: 예시로 든 값만 그대로 바꾸는 규칙 — 항상 고를 수 있게 둔다.
        let table = Dictionary(usable, uniquingKeysWith: { _, last in last })
        kept.append(RuleCandidate(
            id: "literal",
            title: "예시로 적은 \(table.count)개 값만 그대로 바꾸기",
            detail: "규칙을 찾지 않고, 적어 준 짝만 그대로 반영합니다. 다른 값은 건드리지 않아요.",
            rank: 1000, isLiteralOnly: true,
            transform: { table[$0] ?? $0 }))

        return kept.sorted { $0.rank != $1.rank ? $0.rank < $1.rank : $0.title < $1.title }
    }

    // MARK: - 통째로 거는 규칙

    private static func globalCandidates() -> [RuleCandidate] {
        [
            RuleCandidate(id: "trim", title: "앞뒤 공백 없애기",
                          detail: "값 앞뒤에 딸려 온 빈칸만 정리합니다.", rank: 1,
                          transform: { $0.trimmingCharacters(in: .whitespacesAndNewlines) }),
            RuleCandidate(id: "collapse", title: "공백 여러 칸을 한 칸으로",
                          detail: "가운데 이어진 빈칸을 한 칸으로 줄이고 앞뒤 공백도 없앱니다.", rank: 2,
                          transform: {
                              $0.split(whereSeparator: { $0.isWhitespace })
                                  .joined(separator: " ")
                          }),
            RuleCandidate(id: "nospace", title: "공백 모두 없애기",
                          detail: "값 안의 빈칸을 전부 지웁니다.", rank: 13,
                          transform: { $0.filter { !$0.isWhitespace } }),
            RuleCandidate(id: "lower", title: "모두 소문자로",
                          detail: "영문을 전부 소문자로 바꿉니다.", rank: 9,
                          transform: { $0.lowercased() }),
            RuleCandidate(id: "upper", title: "모두 대문자로",
                          detail: "영문을 전부 대문자로 바꿉니다.", rank: 9,
                          transform: { $0.uppercased() }),
            RuleCandidate(id: "titlecase", title: "단어 첫 글자만 대문자로",
                          detail: "seoul → Seoul 처럼 단어마다 첫 글자를 대문자로 만듭니다.", rank: 8,
                          transform: {
                              $0.split(separator: " ", omittingEmptySubsequences: false)
                                  .map { w -> String in
                                      guard let f = w.first else { return String(w) }
                                      return f.uppercased() + w.dropFirst().lowercased()
                                  }
                                  .joined(separator: " ")
                          }),
            RuleCandidate(id: "digits", title: "숫자만 남기기",
                          detail: "숫자가 아닌 글자를 전부 지웁니다.", rank: 12,
                          transform: { $0.filter(\.isNumber) }),
            RuleCandidate(id: "nobrackets", title: "괄호와 그 안의 내용 없애기",
                          detail: "‘서울 (Seoul)’ → ‘서울’ 처럼 괄호 묶음을 통째로 지웁니다.", rank: 10,
                          transform: {
                              applyRegex("\\s*[\\(（\\[][^\\)）\\]]*[\\)）\\]]\\s*", "", to: $0)
                                  .trimmingCharacters(in: .whitespaces)
                          }),
        ]
    }

    // MARK: - 예시의 차이에서 뽑는 규칙

    /// 두 문자열의 공통 앞부분·공통 뒷부분을 걷어내고 남은 ‘달라진 토막’을 찾는다.
    private static func diffParts(_ b: String, _ a: String)
        -> (prefix: String, midB: String, midA: String, suffix: String) {
        let bc = Array(b), ac = Array(a)
        var head = 0
        while head < bc.count && head < ac.count && bc[head] == ac[head] { head += 1 }
        var tail = 0
        while tail < bc.count - head && tail < ac.count - head
                && bc[bc.count - 1 - tail] == ac[ac.count - 1 - tail] { tail += 1 }
        return (String(bc[0..<head]),
                String(bc[head..<(bc.count - tail)]),
                String(ac[head..<(ac.count - tail)]),
                String(bc[(bc.count - tail)...]))
    }

    private static func diffCandidates(_ b: String, _ a: String) -> [RuleCandidate] {
        let d = diffParts(b, a)
        var out: [RuleCandidate] = []

        if !d.midB.isEmpty && d.midA.isEmpty {
            let gone = d.midB
            out.append(RuleCandidate(
                id: "remove:\(gone)", title: "‘\(gone)’ 없애기",
                detail: "값 어디에 있든 ‘\(gone)’를 지웁니다.", rank: 5,
                transform: { $0.replacingOccurrences(of: gone, with: "") }))
            if d.prefix.isEmpty {
                out.append(RuleCandidate(
                    id: "dropPrefix:\(gone)", title: "맨 앞의 ‘\(gone)’만 떼기",
                    detail: "값이 ‘\(gone)’로 시작할 때만 그 부분을 떼어냅니다.", rank: 6,
                    transform: { $0.hasPrefix(gone) ? String($0.dropFirst(gone.count)) : $0 }))
            }
            if d.suffix.isEmpty {
                out.append(RuleCandidate(
                    id: "dropSuffix:\(gone)", title: "맨 뒤의 ‘\(gone)’만 떼기",
                    detail: "값이 ‘\(gone)’로 끝날 때만 그 부분을 떼어냅니다.", rank: 6,
                    transform: { $0.hasSuffix(gone) ? String($0.dropLast(gone.count)) : $0 }))
            }
        }

        if d.midB.isEmpty && !d.midA.isEmpty {
            let add = d.midA
            if d.prefix.isEmpty {
                out.append(RuleCandidate(
                    id: "addPrefix:\(add)", title: "맨 앞에 ‘\(add)’ 붙이기",
                    detail: "이미 ‘\(add)’로 시작하는 값은 그대로 둡니다.", rank: 6,
                    transform: { $0.hasPrefix(add) ? $0 : add + $0 }))
            }
            if d.suffix.isEmpty {
                out.append(RuleCandidate(
                    id: "addSuffix:\(add)", title: "맨 뒤에 ‘\(add)’ 붙이기",
                    detail: "이미 ‘\(add)’로 끝나는 값은 그대로 둡니다.", rank: 6,
                    transform: { $0.hasSuffix(add) ? $0 : $0 + add }))
            }
        }

        if !d.midB.isEmpty && !d.midA.isEmpty {
            let from = d.midB, to = d.midA
            let whole = d.prefix.isEmpty && d.suffix.isEmpty
            out.append(RuleCandidate(
                id: "replace:\(from)>\(to)",
                title: whole ? "‘\(from)’를 ‘\(to)’로 바꾸기" : "‘\(from)’ 부분만 ‘\(to)’로 바꾸기",
                detail: "값 어디에 있든 ‘\(from)’를 찾아 ‘\(to)’로 바꿉니다.",
                rank: whole ? 90 : 5,
                transform: { $0.replacingOccurrences(of: from, with: to) }))
        }
        return out
    }

    // MARK: - 글자 단위로 지우거나 바꾸는 규칙

    /// 같은 글자가 값 안에 여러 번 나오는 경우(예: `010-1234-5678` 의 하이픈 두 개)는
    /// 달라진 토막이 한 덩어리가 아니라 흩어져 있어 `diffCandidates` 가 잡지 못한다.
    /// 그래서 ‘이 글자를 전부 지우면/바꾸면 예시가 되는가’를 글자마다 직접 확인한다.
    private static func charCandidates(_ b: String, _ a: String) -> [RuleCandidate] {
        var out: [RuleCandidate] = []
        let inBefore = Set(b)
        // 바꿔 넣을 후보: 결과에만 새로 나타난 글자 + 자주 쓰는 구분자.
        var targets = Set(a).subtracting(inBefore).map(String.init)
        targets += ["-", ".", "/", " ", ""]

        for c in inBefore.sorted(by: { String($0) < String($1) }) {
            let ch = String(c)
            let label = c.isWhitespace ? "빈칸" : "‘\(ch)’"

            if b.replacingOccurrences(of: ch, with: "") == a {
                out.append(RuleCandidate(
                    id: "removeAll:\(ch)", title: "\(label) 모두 없애기",
                    detail: "값 안에 있는 \(label)를 몇 개든 전부 지웁니다.", rank: 4,
                    transform: { $0.replacingOccurrences(of: ch, with: "") }))
                continue
            }
            for t in Set(targets) where t != ch {
                guard b.replacingOccurrences(of: ch, with: t) == a else { continue }
                let toLabel = t.isEmpty ? "없애기" : (t == " " ? "빈칸으로 바꾸기" : "‘\(t)’로 바꾸기")
                out.append(RuleCandidate(
                    id: "replaceAll:\(ch)>\(t)", title: "\(label) 모두 \(toLabel)",
                    detail: "값 안에 있는 \(label)를 몇 개든 전부 바꿉니다.", rank: 4,
                    transform: { $0.replacingOccurrences(of: ch, with: t) }))
            }
        }
        return out
    }

    // MARK: - 구분자 기준으로 자르는 규칙

    private static func separatorCandidates(_ b: String, _ a: String) -> [RuleCandidate] {
        var seps = Set(b.filter { !$0.isLetter && !$0.isNumber }.map(String.init))
        for multi in [" (", " -", " / ", ", ", " · "] where b.contains(multi) { seps.insert(multi) }
        var out: [RuleCandidate] = []
        for sep in seps.sorted(by: { $0.count > $1.count }) {
            let label = sep == " " ? "빈칸" : "‘\(sep)’"
            out.append(RuleCandidate(
                id: "before:\(sep)", title: "\(label) 앞부분만 남기기",
                detail: "\(label)가 없는 값은 그대로 둡니다.", rank: 20,
                transform: { s in
                    guard let r = s.range(of: sep) else { return s }
                    return String(s[s.startIndex..<r.lowerBound])
                        .trimmingCharacters(in: .whitespaces)
                }))
            out.append(RuleCandidate(
                id: "after:\(sep)", title: "마지막 \(label) 뒷부분만 남기기",
                detail: "\(label)가 없는 값은 그대로 둡니다.", rank: 21,
                transform: { s in
                    guard let r = s.range(of: sep, options: .backwards) else { return s }
                    return String(s[r.upperBound...]).trimmingCharacters(in: .whitespaces)
                }))
        }
        return out
    }

    // MARK: - 길이로 자르는 규칙

    private static func lengthCandidates(_ b: String, _ a: String) -> [RuleCandidate] {
        var out: [RuleCandidate] = []
        let n = a.count
        guard n > 0, n < b.count else { return out }
        if b.hasPrefix(a) {
            out.append(RuleCandidate(
                id: "first:\(n)", title: "앞 \(n)글자만 남기기",
                detail: "\(n)글자보다 짧은 값은 그대로 둡니다.", rank: 30,
                transform: { String($0.prefix(n)) }))
        }
        if b.hasSuffix(a) {
            out.append(RuleCandidate(
                id: "last:\(n)", title: "뒤 \(n)글자만 남기기",
                detail: "\(n)글자보다 짧은 값은 그대로 둡니다.", rank: 30,
                transform: { String($0.suffix(n)) }))
        }
        return out
    }

    // MARK: - 숫자를 다시 묶는 규칙 (전화번호·날짜 모양 맞추기)

    /// `after`를 ‘숫자 덩어리 + 사이 글자’로 쪼갠다. ("010-1234-5678" → [3,4,4], ["", "-", "-", ""])
    private static func digitShape(_ s: String) -> (lengths: [Int], glue: [String])? {
        var lengths: [Int] = []
        var glue: [String] = []
        var current = ""
        var inDigits = false
        for ch in s {
            if ch.isNumber {
                if !inDigits { glue.append(current); current = ""; inDigits = true }
                current.append(ch)
            } else {
                if inDigits { lengths.append(current.count); current = ""; inDigits = false }
                current.append(ch)
            }
        }
        if inDigits { lengths.append(current.count); glue.append("") }
        else { glue.append(current) }
        guard lengths.count >= 2 else { return nil }
        return (lengths, glue)
    }

    private static func digitRegroupCandidates(_ b: String, _ a: String) -> [RuleCandidate] {
        let db = b.filter(\.isNumber), da = a.filter(\.isNumber)
        guard !db.isEmpty, db == da, let shape = digitShape(a) else { return [] }
        let total = shape.lengths.reduce(0, +)
        return [RuleCandidate(
            id: "regroup:\(a)",
            title: "숫자만 뽑아 ‘\(a)’ 같은 모양으로 맞추기",
            detail: "숫자 \(total)개짜리 값만 \(shape.lengths.map(String.init).joined(separator: "-")) 로 다시 묶습니다. 개수가 다르면 손대지 않아요.",
            rank: 15,
            transform: { s in
                let digits = Array(s.filter(\.isNumber))
                guard digits.count == total else { return s }
                var out = shape.glue.first ?? ""
                var i = 0
                for (k, len) in shape.lengths.enumerated() {
                    out += String(digits[i..<(i + len)])
                    i += len
                    if k + 1 < shape.glue.count { out += shape.glue[k + 1] }
                }
                return out
            })]
    }

    // MARK: - 조각 순서를 바꾸는 규칙 (31/05/2004 → 2004-05-31)

    private enum TokKind { case digit, latin, hangul, other }

    private static func tokenize(_ s: String) -> [(kind: TokKind, text: String)] {
        func kind(_ c: Character) -> TokKind {
            if c.isNumber { return .digit }
            if c.isLetter {
                return c.unicodeScalars.allSatisfy { $0.value >= 0xAC00 && $0.value <= 0xD7A3 }
                    ? .hangul : .latin
            }
            return .other
        }
        var out: [(TokKind, String)] = []
        for c in s {
            let k = kind(c)
            if var last = out.last, last.0 == k {
                last.1.append(c); out[out.count - 1] = last
            } else {
                out.append((k, String(c)))
            }
        }
        return out.map { (kind: $0.0, text: $0.1) }
    }

    private static func tokenTemplateCandidates(_ b: String, _ a: String) -> [RuleCandidate] {
        let toks = tokenize(b)
        // 캡처 그룹은 $1…$9 까지만 쓴다 (템플릿에서 $10 이 애매해지는 걸 피함).
        let groups = toks.enumerated().filter { $0.element.kind != .other }
        guard groups.count >= 2, groups.count <= 9 else { return [] }

        var pattern = "^"
        var groupIndex: [Int: Int] = [:]      // 토큰 위치 → 캡처 번호
        var n = 0
        for (i, t) in toks.enumerated() {
            switch t.kind {
            case .other:
                pattern += NSRegularExpression.escapedPattern(for: t.text)
            case .digit:
                n += 1; groupIndex[i] = n
                pattern += "(\\d{\(t.text.count)})"
            case .latin:
                n += 1; groupIndex[i] = n
                pattern += "([A-Za-z]{\(t.text.count)})"
            case .hangul:
                n += 1; groupIndex[i] = n
                pattern += "([가-힣]{\(t.text.count)})"
            }
        }
        pattern += "$"

        // `after`를 토큰 조각으로 되짚어 템플릿을 만든다 (긴 조각 우선 — 우연한 짧은 일치 방지).
        let ordered = groups.sorted { $0.element.text.count > $1.element.text.count }
        var template = ""
        var usedGroups = Set<Int>()
        var idx = a.startIndex
        while idx < a.endIndex {
            var matched = false
            for (pos, tok) in ordered {
                guard let g = groupIndex[pos], !tok.text.isEmpty else { continue }
                if a[idx...].hasPrefix(tok.text) {
                    template += "$\(g)"
                    usedGroups.insert(g)
                    idx = a.index(idx, offsetBy: tok.text.count)
                    matched = true
                    break
                }
            }
            if !matched {
                template += NSRegularExpression.escapedTemplate(for: String(a[idx]))
                idx = a.index(after: idx)
            }
        }
        guard usedGroups.count >= 2 else { return [] }

        let p = pattern, t = template
        return [RuleCandidate(
            id: "template:\(p)>\(t)",
            title: "조각 순서를 바꿔 ‘\(a)’ 모양으로 맞추기",
            detail: "‘\(b)’와 같은 짜임의 값만 자리를 옮겨 다시 씁니다. 짜임이 다르면 손대지 않아요.",
            rank: 25,
            transform: { applyRegex(p, t, to: $0) })]
    }

    // MARK: - 도우미

    static func applyRegex(_ pattern: String, _ template: String, to s: String) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return s }
        let range = NSRange(s.startIndex..., in: s)
        return re.stringByReplacingMatches(in: s, range: range, withTemplate: template)
    }
}
