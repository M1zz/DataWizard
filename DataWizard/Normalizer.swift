import Foundation

/// Pure value-cleaning helpers. Each is broken into single-purpose steps
/// so the algorithm maps closely to the code, line by line.
enum Normalizer {

    /// 자주 쓰는 목표 포맷 프리셋. rawValue가 곧 템플릿이자 표시 라벨이다.
    /// 템플릿 = 샘플 번호(010-1234-5678)를 원하는 모양으로 적은 문자열.
    enum PhoneFormat: String, CaseIterable, Identifiable {
        case dashed     = "010-1234-5678"
        case digits     = "01012345678"
        case e164       = "+821012345678"
        case e164Dashed = "+82 10-1234-5678"
        var id: String { rawValue }
    }

    /// 기본 템플릿 (정답지와 같은 010-XXXX-XXXX).
    static let defaultPhoneTemplate = PhoneFormat.dashed.rawValue

    /// +82 / 0 누락 / 구분 기호 섞임 등 어떤 표기든, 한국 휴대전화로 인식되면
    /// 11자리 "010XXXXXXXX"로 정규화한 숫자열을 돌려준다. 아니면 nil.
    static func koreanMobileDigits(_ raw: String) -> String? {
        var d = raw.filter { $0.isNumber }
        if d.hasPrefix("82") { d = "0" + d.dropFirst(2) }          // +82 → 0
        if d.count == 10 && d.hasPrefix("10") { d = "0" + d }       // 0 누락 보정
        return (d.count == 11 && d.hasPrefix("010")) ? d : nil
    }

    /// 사용자가 쓴 템플릿이 유효한가: 안의 숫자만 이어 붙였을 때 샘플 번호
    /// 01012345678 (국내식) 또는 821012345678 (+82 국제식)이어야 한다.
    static func isValidPhoneTemplate(_ template: String) -> Bool {
        let d = template.filter { $0.isNumber }
        return d == "01012345678" || d == "821012345678"
    }

    /// 인식된 한국 휴대전화를 템플릿 모양 그대로 변환한다. 템플릿의 숫자
    /// 자리에 실제 번호의 대응 숫자가 차례로 들어가고, 나머지 문자(-, 공백,
    /// 괄호, + 등)는 그대로 복사된다. 인식 실패면 nil(확인 필요 목록행).
    static func formatPhone(_ raw: String, template: String) -> String? {
        guard let d = koreanMobileDigits(raw) else { return nil }
        let t = isValidPhoneTemplate(template) ? template : defaultPhoneTemplate
        // 템플릿이 국제식(82…)이면 실제 번호도 82 + 0 뺀 10자리로 맞춘다.
        let source = t.filter { $0.isNumber }.hasPrefix("82") ? "82" + d.dropFirst() : d
        var digits = source.makeIterator()
        return String(t.map { $0.isNumber ? (digits.next() ?? $0) : $0 })
    }

    /// 기본 포맷(010-XXXX-XXXX) 변환. 인식 실패 시 원본 유지(해외 번호 등).
    static func cleanPhone(_ raw: String) -> String {
        formatPhone(raw, template: defaultPhoneTemplate)
            ?? raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The dedup key derived from a phone number: digits only, no formatting.
    /// Two rows with the same key are the same person.
    static func phoneKey(_ raw: String) -> String {
        var digits = raw.filter { $0.isNumber }
        if digits.hasPrefix("82") { digits = "0" + digits.dropFirst(2) }
        if digits.count == 10 && digits.hasPrefix("10") { digits = "0" + digits }
        return digits
    }

    /// 아카데미 시작 기준일: 다음 3월 1일 (이미 3월 1일이 지났으면 내년).
    static var academyStart: Date {
        let cal = Calendar(identifier: .gregorian)
        let now = Date()
        let year = cal.component(.year, from: now)
        let thisMar = cal.date(from: DateComponents(year: year, month: 3, day: 1))!
        return now < thisMar ? thisMar
            : cal.date(from: DateComponents(year: year + 1, month: 3, day: 1))!
    }

    /// 만 나이 (기준일: 아카데미 시작일). 생일을 인식 못하면 "".
    static func age(fromCleanDob dob: String) -> String {
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.dateFormat = "yyyy-MM-dd"
        guard let birth = parser.date(from: dob) else { return "" }
        let years = Calendar(identifier: .gregorian)
            .dateComponents([.year], from: birth, to: academyStart).year ?? 0
        return "\(years)"
    }

    /// 만 나이 → 연령대 구간 (최종본 형식: 19-20 / 21-25 / … / 41+ / NA).
    static func ageGroup(fromAge age: String) -> String {
        guard let n = Int(age) else { return "NA" }
        switch n {
        case ..<19:    return "Under 19"
        case 19...20:  return "19-20"
        case 21...25:  return "21-25"
        case 26...30:  return "26-30"
        case 31...35:  return "31-35"
        case 36...40:  return "36-40"
        default:       return "41+"
        }
    }

    /// Normalize a free-form birthdate into "yyyy-MM-dd".
    /// Tries several common input layouts and returns the first that parses.
    static func cleanDate(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "" }

        let candidateFormats = [
            "yyyy-MM-dd", "yyyy/MM/dd", "yyyy.MM.dd",
            "dd-MM-yyyy", "dd/MM/yyyy", "MM/dd/yyyy",
            "yyyyMMdd"
        ]
        let out = DateFormatter()
        out.locale = Locale(identifier: "en_US_POSIX")
        out.dateFormat = "yyyy-MM-dd"

        for fmt in candidateFormats {
            let parser = DateFormatter()
            parser.locale = Locale(identifier: "en_US_POSIX")
            parser.dateFormat = fmt
            if let d = parser.date(from: trimmed) {
                return out.string(from: d)
            }
        }
        // Could not parse: return the original so nothing is silently lost.
        return trimmed
    }
}
