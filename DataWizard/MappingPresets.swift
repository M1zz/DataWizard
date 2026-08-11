import Foundation

/// 사양서에 명시된 공식 한글→영문 매핑표를 앱에 내장한다. ‘여러 값을 하나로
/// 모으기’ 시트에서 버튼 한 번으로 규칙을 채워 넣을 수 있어, 매번 붙여넣지
/// 않아도 된다. 채운 규칙은 2단계(적용 결과 확인)에서 검토 후 적용된다.
///
/// 출처: 애플 아카데미 데이터 클리닝 사양 — Mapping Table (Current Status / City / Country).
enum MappingPresets {

    /// (원본 한글, 통일 영문) 쌍. 사양서의 열 순서를 그대로 따른다.
    static func pairs(for column: UnifiedColumn) -> [(from: String, to: String)]? {
        switch column {
        case .currentStatus:            return currentStatus
        case .currentCity, .province:   return city
        case .country:                  return country
        default:                        return nil
        }
    }

    /// 버튼/설명에 쓸 매핑표 이름.
    static func label(for column: UnifiedColumn) -> String? {
        switch column {
        case .currentStatus:            return "Current Status 공식 매핑표"
        case .currentCity, .province:   return "도/시 → 영문 공식 매핑표"
        case .country:                  return "국가 → 영문 공식 매핑표"
        default:                        return nil
        }
    }

    /// 편집기에 채울 텍스트 (한 줄에 ‘원본 → 영문’ 하나).
    static func text(for column: UnifiedColumn) -> String? {
        pairs(for: column)?.map { "\($0.from) → \($0.to)" }.joined(separator: "\n")
    }

    // MARK: - 사양서 매핑표

    /// Current Status. 사양 주의: 값이 비어 있으면 High School Status일 수 있으나
    /// (고등학교 재학) 수기 확인이 필요하므로 빈 값 자동 매핑은 넣지 않는다.
    private static let currentStatus: [(from: String, to: String)] = [
        ("기타", "Others"),
        ("대학교 1학년", "University Yr1"),
        ("대학교 2학년", "University Yr2"),
        ("대학교 3학년", "University Yr3"),
        ("대학교 4학년", "University Yr4"),
        ("대학원 박사 과정 중", "Doctoral or Post Grad (Status)"),
        ("대학원 석사 과정 중", "Master Status"),
        ("무직/구직중", "Not Working nor in School"),
        ("자영업자/개인사업자", "Self-Employed / Entrepreneur"),
        ("파트타임 근로자", "Part Time Employee"),
        ("풀타임 근로자", "Full Time Employee"),
        ("프리랜서", "Freelancer"),
        ("휴학중", "Off-Year (University)"),
    ]

    /// Current City (도/시 → 영문). ‘그 외 국가’ 선택 시 Overseas.
    private static let city: [(from: String, to: String)] = [
        ("강원특별자치도", "Gangwon"),
        ("경기도", "Gyeonggi-do"),
        ("경상남도", "Gyeongsangnam-do"),
        ("경상북도", "Gyeongsangbuk-do"),
        ("광주광역시", "Gwangju"),
        ("대구광역시", "Daegu"),
        ("대전광역시", "Daejeon"),
        ("부산광역시", "Busan"),
        ("서울특별시", "Seoul"),
        ("세종특별자치시", "Sejong-si"),
        ("울산광역시", "Ulsan"),
        ("인천광역시", "Incheon"),
        ("전라남도", "Jeollanam-do"),
        ("전북특별자치도", "Jeonbuk"),
        ("충청남도", "Chungcheongnam-do"),
        ("충청북도", "Chungcheongbuk-do"),
        ("그 외 국가", "Overseas"),
    ]

    /// Current Country (국가 → 영문). 대한민국 외에는 Overseas.
    private static let country: [(from: String, to: String)] = [
        ("대한민국", "South Korea"),
        ("그 외 국가", "Overseas"),
    ]
}
