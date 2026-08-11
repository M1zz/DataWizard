import Foundation

/// The unified output schema. Order matters: this is the column order written to
/// the merged file — it mirrors the hand-made 최종 ‘제출자’ CSV exactly (73 columns),
/// so the tool's output is drop-in comparable with the existing process.
enum UnifiedColumn: String, CaseIterable {
    case code = "Code"
    case koreanName = "Korean Name"
    case channel = "지원방식"
    case dupFlag = "중복삭제"
    case email = "Email Address"
    case phoneClean = "전화번호(Clean)"
    case phone = "Phone Number"
    // 후속 작업 컬럼 (클렌징 범위 밖 — 자리만 유지)
    case onTestScore = "온테점수(265)"
    case fifthApply = "5기 지원여부"
    case foundationOrigin = "파운데이션 출신"
    case scoreFrom = "점수 (from 온테점수(265))"
    case onTestPass = "온테패스"
    case eventApplicant = "행사 신청자 (포폴챌 포함)"
    case howHeard = "How did you hear about our program? (Please select one option only.)"
    case dob = "Date of Birth"
    case dobClean = "생년월일(Clean)"
    case campaign = "Campaign"
    case regCohort = "Registration Cohort"
    case regBatch = "Registration Batch"
    case regAcademy = "Registration Academy"
    case curCohort = "Current Cohort"
    case curBatch = "Current Batch"
    case processStatus = "Process Status"
    case totalActiveChoices = "Total Active Choices"
    case confirmedAt = "Confirmed At"
    case blocked = "Blocked"
    case disabled = "Disabled"
    case registeredAt = "Registered At"
    case lastLogin = "Last Login"
    case deleted = "Deleted"
    case tncAge = "T&C Age"
    case tncContact = "T&C Contact"
    case academyChoice = "Academy Choice"
    case age = "만 나이"
    case ageGroup = "Age Group"
    case gender = "Gender"
    case idDocType = "ID Document Type"
    case idNumber = "ID Number / Passport Number"
    case nationality = "Nationality"
    case currentCity = "Current City"
    case cityOverseas = "City(Overseas)"
    case province = "Province"
    case country = "Current Country of Residence"
    case currentAddress = "Current Address"
    case postalCode = "Current Postal Code"
    case pohangResidency = "Pohang/Gyeongsangbuk-do Residency and Origin"
    case placeOfBirth = "Place of Birth"
    case currentStatus = "Current Status"
    case schoolCompany = "School/University/Company"
    case majorDept = "Major/Department"
    case dualMajor = "이중전공 학과명"
    case uniStats = "Uni_Stats"
    case othersSpecify = "Others (Please specify if you chose Others)"
    case levelOfEducation = "Level of Education"
    case school = "School/University"
    case major = "Major"
    case considerMyself = "Currently, I consider myself as a..."
    case accomodation = "Accomodation Preference"
    case sessionPref = "Session Preference Time"
    case foundationGrad = "Are you a graduate or an expected graduate of the Apple Foundation Program?"
    case snsChannel = "어떤SNS 였나요?"
    case coreCompetencies = "Core Competencies"
    case motivVideo = "Link to Motivational Video"
    case cvFile = "CV File (*mandatory)"
    case linkedin = "LinkedIn Profile"
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
