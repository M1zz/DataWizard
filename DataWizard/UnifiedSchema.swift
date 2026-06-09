import Foundation

/// The unified output schema. Order matters: this is the column order written to the merged file.
/// Derived from the final "제출자" sheet, dropping post-merge scoring columns that are added by hand later.
enum UnifiedColumn: String, CaseIterable {
    case code = "Code"
    case koreanName = "Korean Name"
    case channel = "지원방식"
    case dupFlag = "중복삭제"
    case email = "Email Address"
    case phoneClean = "전화번호(Clean)"
    case phone = "Phone Number"
    case howHeard = "How did you hear about our program? (Please select one option only.)"
    case dob = "Date of Birth"
    case dobClean = "생년월일(Clean)"
    case campaign = "Campaign"
    case processStatus = "Process Status"
    case gender = "Gender"
    case nationality = "Nationality"
    case currentCity = "Current City"
    case province = "Province"
    case country = "Current Country of Residence"
    case currentAddress = "Current Address"
    case pohangResidency = "Pohang/Gyeongsangbuk-do Residency and Origin"
    case currentStatus = "Current Status"
    case schoolCompany = "School/University/Company"
    case majorDept = "Major/Department"
    case levelOfEducation = "Level of Education"
    case school = "School/University"
    case major = "Major"
    case considerMyself = "Currently, I consider myself as a..."
    case foundationGrad = "Are you a graduate or an expected graduate of the Apple Foundation Program?"
    case snsChannel = "어떤SNS 였나요?"
    case coreCompetencies = "Core Competencies"
    case cvFile = "CV File (*mandatory)"
    case portfolioFile = "Portfolio File (*Mandatory)"
    case portfolioLinks = "Portfolio Links"
    case selfIntro = "자기소개 (최대 300자)"
    case motivation = "지원동기 (최대 800자)"
    case essayInitiative = "작은 일이라도 스스로 시작하거나 무언가를 바꿔본 경험을 들려주세요.  (최대 500자)"
    case essayCraft = "결과물의 완성도를 높이기 위해 치열하게 고민했던 과정이 자세하게 드러나면 더 좋아요. (최대 500자)"
    case essayChallenge = "익숙하지 않은 분야에 도전했거나 협업을 통해 나의 다른 면을 발견한 경험을 들려주세요. (최대 500자)"
    case submittedAt = "Submitted At"

    static var orderedHeaders: [String] { allCases.map { $0.rawValue } }
}

/// One normalized applicant row, keyed by unified column.
struct ApplicantRow: Identifiable {
    let id = UUID()
    var values: [UnifiedColumn: String] = [:]

    subscript(_ col: UnifiedColumn) -> String {
        get { values[col] ?? "" }
        set { values[col] = newValue }
    }
}

/// The kind of source file, auto-detected from its contents.
/// 간편지원 (Public/Private) share one Korean CSV layout and are no longer
/// distinguished — both collapse into `.simple`. 일반지원 is the XLSX export.
enum Channel: String, CaseIterable {
    case simple = "간편지원"
    case general = "일반지원"

    /// Guess a file's channel from its name and headers.
    /// 일반지원 ships as an .xlsx whose real header sits on the second row;
    /// 간편지원 ships as a Korean-headered .csv. Anything that isn't clearly
    /// the 일반지원 layout is treated as 간편지원.
    static func detect(url: URL) -> Channel {
        let ext = url.pathExtension.lowercased()
        if ext == "xlsx" { return .general }

        // A CSV could still carry the 일반지원 English layout — sniff its header.
        if let dicts = try? CSVParser.readDicts(at: url), let first = dicts.first {
            let keys = Set(first.keys)
            if keys.contains(ChannelMapping.generalStatusColumn) && keys.contains("Code") {
                return .general
            }
        }
        return .simple
    }
}
