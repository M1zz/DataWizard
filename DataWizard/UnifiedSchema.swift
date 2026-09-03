import Foundation

/// 컬럼 하나 — 파일 헤더 이름 그 자체.
///
/// 예전에는 애플 아카데미 제출자 양식 73컬럼으로 고정된 `enum` 이었다. 이제는 어떤
/// CSV/XLSX의 어떤 헤더든 컬럼이 될 수 있고, 73컬럼은 `academyPreset` 이라는 ‘자주 쓰는
/// 순서’로만 남는다. 이름 상수(`.code`, `.email` …)를 그대로 둔 덕분에 아카데미 전용
/// 로직(채널 매핑·중복 판정·파생 컬럼)은 손대지 않고 계속 동작한다.
struct UnifiedColumn: Hashable, Identifiable, RawRepresentable, CustomStringConvertible {
    let rawValue: String

    /// 헤더 문자열에서 만든다. 앞뒤 공백은 떼어 같은 컬럼이 둘로 갈라지지 않게 한다.
    /// 빈 이름은 컬럼이 아니므로 nil — 헤더가 비어 있는 칸을 그냥 건너뛸 수 있다.
    init?(rawValue: String) {
        let name = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        self.rawValue = name
    }

    /// 코드에서 이름을 직접 적을 때 (프리셋 상수용).
    init(_ name: String) {
        self.rawValue = name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var id: String { rawValue }
    var description: String { rawValue }

    // MARK: - 애플 아카데미 제출자 양식 (프리셋)

    static let code = UnifiedColumn("Code")
    static let koreanName = UnifiedColumn("Korean Name")
    static let channel = UnifiedColumn("지원방식")
    static let dupFlag = UnifiedColumn("중복삭제")
    static let email = UnifiedColumn("Email Address")
    static let phoneClean = UnifiedColumn("전화번호(Clean)")
    static let phone = UnifiedColumn("Phone Number")
    static let onTestScore = UnifiedColumn("온테점수(265)")
    static let fifthApply = UnifiedColumn("5기 지원여부")
    static let foundationOrigin = UnifiedColumn("파운데이션 출신")
    static let scoreFrom = UnifiedColumn("점수 (from 온테점수(265))")
    static let onTestPass = UnifiedColumn("온테패스")
    static let eventApplicant = UnifiedColumn("행사 신청자 (포폴챌 포함)")
    static let howHeard = UnifiedColumn("How did you hear about our program? (Please select one option only.)")
    static let dob = UnifiedColumn("Date of Birth")
    static let dobClean = UnifiedColumn("생년월일(Clean)")
    static let campaign = UnifiedColumn("Campaign")
    static let regCohort = UnifiedColumn("Registration Cohort")
    static let regBatch = UnifiedColumn("Registration Batch")
    static let regAcademy = UnifiedColumn("Registration Academy")
    static let curCohort = UnifiedColumn("Current Cohort")
    static let curBatch = UnifiedColumn("Current Batch")
    static let processStatus = UnifiedColumn("Process Status")
    static let totalActiveChoices = UnifiedColumn("Total Active Choices")
    static let confirmedAt = UnifiedColumn("Confirmed At")
    static let blocked = UnifiedColumn("Blocked")
    static let disabled = UnifiedColumn("Disabled")
    static let registeredAt = UnifiedColumn("Registered At")
    static let lastLogin = UnifiedColumn("Last Login")
    static let deleted = UnifiedColumn("Deleted")
    static let tncAge = UnifiedColumn("T&C Age")
    static let tncContact = UnifiedColumn("T&C Contact")
    static let academyChoice = UnifiedColumn("Academy Choice")
    static let age = UnifiedColumn("만 나이")
    static let ageGroup = UnifiedColumn("Age Group")
    static let gender = UnifiedColumn("Gender")
    static let idDocType = UnifiedColumn("ID Document Type")
    static let idNumber = UnifiedColumn("ID Number / Passport Number")
    static let nationality = UnifiedColumn("Nationality")
    static let currentCity = UnifiedColumn("Current City")
    static let cityOverseas = UnifiedColumn("City(Overseas)")
    static let province = UnifiedColumn("Province")
    static let country = UnifiedColumn("Current Country of Residence")
    static let currentAddress = UnifiedColumn("Current Address")
    static let postalCode = UnifiedColumn("Current Postal Code")
    static let pohangResidency = UnifiedColumn("Pohang/Gyeongsangbuk-do Residency and Origin")
    static let placeOfBirth = UnifiedColumn("Place of Birth")
    static let currentStatus = UnifiedColumn("Current Status")
    static let schoolCompany = UnifiedColumn("School/University/Company")
    static let majorDept = UnifiedColumn("Major/Department")
    static let dualMajor = UnifiedColumn("이중전공 학과명")
    static let uniStats = UnifiedColumn("Uni_Stats")
    static let othersSpecify = UnifiedColumn("Others (Please specify if you chose Others)")
    static let levelOfEducation = UnifiedColumn("Level of Education")
    static let school = UnifiedColumn("School/University")
    static let major = UnifiedColumn("Major")
    static let considerMyself = UnifiedColumn("Currently, I consider myself as a...")
    static let accomodation = UnifiedColumn("Accomodation Preference")
    static let sessionPref = UnifiedColumn("Session Preference Time")
    static let foundationGrad = UnifiedColumn("Are you a graduate or an expected graduate of the Apple Foundation Program?")
    static let snsChannel = UnifiedColumn("어떤SNS 였나요?")
    static let coreCompetencies = UnifiedColumn("Core Competencies")
    static let motivVideo = UnifiedColumn("Link to Motivational Video")
    static let cvFile = UnifiedColumn("CV File (*mandatory)")
    static let linkedin = UnifiedColumn("LinkedIn Profile")
    static let portfolioFile = UnifiedColumn("Portfolio File (*Mandatory)")
    static let portfolioLinks = UnifiedColumn("Portfolio Links")
    static let selfIntro = UnifiedColumn("자기소개 (최대 300자)")
    static let motivation = UnifiedColumn("지원동기 (최대 800자)")
    static let essayInitiative = UnifiedColumn("작은 일이라도 스스로 시작하거나 무언가를 바꿔본 경험을 들려주세요.  (최대 500자)")
    static let essayCraft = UnifiedColumn("결과물의 완성도를 높이기 위해 치열하게 고민했던 과정이 자세하게 드러나면 더 좋아요. (최대 500자)")
    static let essayChallenge = UnifiedColumn("익숙하지 않은 분야에 도전했거나 협업을 통해 나의 다른 면을 발견한 경험을 들려주세요. (최대 500자)")
    static let submittedAt = UnifiedColumn("Submitted At")

    /// 아카데미 통합본의 컬럼과 그 순서. 이 순서가 곧 내보내기 순서였다.
    /// 이제는 ‘고정 스키마’가 아니라 골라 쓸 수 있는 하나의 프리셋이다.
    static let academyPreset: [UnifiedColumn] = [
        .code,
        .koreanName,
        .channel,
        .dupFlag,
        .email,
        .phoneClean,
        .phone,
        .onTestScore,
        .fifthApply,
        .foundationOrigin,
        .scoreFrom,
        .onTestPass,
        .eventApplicant,
        .howHeard,
        .dob,
        .dobClean,
        .campaign,
        .regCohort,
        .regBatch,
        .regAcademy,
        .curCohort,
        .curBatch,
        .processStatus,
        .totalActiveChoices,
        .confirmedAt,
        .blocked,
        .disabled,
        .registeredAt,
        .lastLogin,
        .deleted,
        .tncAge,
        .tncContact,
        .academyChoice,
        .age,
        .ageGroup,
        .gender,
        .idDocType,
        .idNumber,
        .nationality,
        .currentCity,
        .cityOverseas,
        .province,
        .country,
        .currentAddress,
        .postalCode,
        .pohangResidency,
        .placeOfBirth,
        .currentStatus,
        .schoolCompany,
        .majorDept,
        .dualMajor,
        .uniStats,
        .othersSpecify,
        .levelOfEducation,
        .school,
        .major,
        .considerMyself,
        .accomodation,
        .sessionPref,
        .foundationGrad,
        .snsChannel,
        .coreCompetencies,
        .motivVideo,
        .cvFile,
        .linkedin,
        .portfolioFile,
        .portfolioLinks,
        .selfIntro,
        .motivation,
        .essayInitiative,
        .essayCraft,
        .essayChallenge,
        .submittedAt
    ]

    /// 병합이 직접 계산해 채우는 컬럼 — 원본 파일에서 읽어 오지 않는다.
    static let academyDerived: Set<UnifiedColumn> = [
        .channel, .dupFlag, .phoneClean, .dobClean, .age, .ageGroup
    ]
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
