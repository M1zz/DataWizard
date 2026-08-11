import Foundation

/// Maps each source channel's raw column names onto the unified schema.
/// The two 간편지원 channels (Public/Private) share one Korean-language layout;
/// the 일반지원 export already uses the Airtable-style English headers.
enum ChannelMapping {

    /// Korean simple-application layout (Public & Private CSVs).
    /// Keys are unified columns, values are the source header to read from.
    static let simpleKorean: [UnifiedColumn: String] = [
        .koreanName: "국문 이름 (예: 애플)",          // surname is handled separately below
        .email: "이메일 주소",
        .phone: "휴대폰 번호",
        .dob: "생년월일",
        .gender: "성별을 선택해주세요",
        .country: "현재 거주 국가를 선택해주세요.",
        // 최종본 기준: 도/시 → Current City (매핑표로 영문 변환), 해외 도시 → City(Overseas)
        .currentCity: "현재 거주하고 있는 도/시를 선택해주세요.",
        .cityOverseas: "어떤 도시에 거주하고 계신가요?",
        .levelOfEducation: "최종 학력을 선택해주세요.",
        .majorDept: "재학 중인 학과명의 전체 이름을 적어주세요.",
        .dualMajor: "이중전공자라면 제2전공 학과명의 전체 이름을 적어주세요.",
        .snsChannel: "어떤 SNS였나요?",
        .cvFile: "선택 사항: 이력서 (CV) ",
        .portfolioFile: "선택 사항: 포트폴리오",
        .selfIntro: "자기소개 (최대 300자)",
        .motivation: "지원동기 (최대 800자)",
        .essayInitiative: "작은 일이라도 스스로 시작하거나 무언가를 바꿔본 경험을 들려주세요.  (최대 500자)",
        .essayCraft: "결과물의 완성도를 높이기 위해 치열하게 고민했던 과정이 자세하게 드러나면 더 좋아요. (최대 500자)",
        .essayChallenge: "익숙하지 않은 분야에 도전했거나 협업을 통해 나의 다른 면을 발견한 경험을 들려주세요. (최대 500자)",
        .howHeard: "Apple 디벨로퍼 아카데미를 어떻게 처음 알게 되었나요?",
        .foundationGrad: "Apple 디벨로퍼 아카데미 파운데이션 프로그램에 참여 중이거나 수료생인가요?",
        .submittedAt: "Submission date",
        .pohangResidency: "포항시에 거주하고 계신가요?"
    ]

    /// Headers that differ slightly between Public/Private exports (spacing).
    /// Tried in order; the first header the file actually has wins.
    static let simpleAlternates: [UnifiedColumn: [String]] = [
        .portfolioLinks: ["추가 링크(예: GitHub, Behance, 개인 SNS, 구글 드라이브 링크 등)",
                          "추가 링크 (예: GitHub, Behance, 개인 SNS, 구글 드라이브 링크 등)"]
    ]

    /// Current Status는 두 컬럼을 합쳐 만든다: 대학 재학 단계 + 그 외 신분.
    /// (한 행에는 둘 중 하나만 채워져 있다.)
    static let simpleStatusSources = ["대학교 재학/휴학/졸업 예정 ", "그 외"]

    /// School/University/Company: 재학 학교 → 졸업 학교 → 회사 순으로 합친다.
    static let simpleSchoolSources = ["재학/휴학/졸업 예정인 학교의 정식 명칭을 적어주세요. ",
                                      "졸업한 학교의 정식 명칭을 적어주세요.",
                                      "회사 또는 소속기관을 적어주세요."]

    /// ‘그 외 국가’ 선택자의 실제 국가명이 적힌 컬럼 (Country 치환에 사용).
    static let simpleCountryNameColumn = "현재 거주 국가명을 적어주세요."

    /// For the Korean layout, the full name is built from surname + given name.
    static let simpleSurnameColumn = "국문 성 (예: 김)"

    /// 일반지원 layout already matches unified English names for most fields.
    /// Listed explicitly so the mapping is auditable and not order-dependent.
    static let general: [UnifiedColumn: String] = [
        .code: "Code",
        .koreanName: "Korean Name",
        .email: "Email Address",
        .phone: "Phone Number",
        .dob: "Date of Birth",
        .campaign: "Campaign",
        .regCohort: "Registration Cohort",
        .regBatch: "Registration Batch",
        .regAcademy: "Registration Academy",
        .curCohort: "Current Cohort",
        .curBatch: "Current Batch",
        .processStatus: "Process Status",
        .totalActiveChoices: "Total Active Choices",
        .confirmedAt: "Confirmed At",
        .blocked: "Blocked",
        .disabled: "Disabled",
        .registeredAt: "Registered At",
        .lastLogin: "Last Login",
        .deleted: "Deleted",
        .tncAge: "T&C Age",
        .tncContact: "T&C Contact",
        .academyChoice: "Academy Choice",
        .gender: "Gender",
        .idDocType: "ID Document Type",
        .idNumber: "ID Number / Passport Number",
        .nationality: "Nationality",
        .currentCity: "Current City",
        .province: "Province",
        .country: "Current Country of Residence",
        .currentAddress: "Current Address",
        .postalCode: "Current Postal Code",
        .pohangResidency: "Pohang/Gyeongsangbuk-do Residency and Origin",
        .placeOfBirth: "Place of Birth",
        .currentStatus: "Current Status",
        .schoolCompany: "School/University/Company",
        .majorDept: "Major/Department",
        .othersSpecify: "Others (Please specify if you chose Others)",
        .levelOfEducation: "Level of Education",
        .school: "School/University",
        .major: "Major",
        .considerMyself: "Currently, I consider myself as a...",
        .accomodation: "Accomodation Preference",
        .sessionPref: "Session Preference Time",
        .foundationGrad: "Are you a graduate or an expected graduate of the Apple Foundation Program?",
        .coreCompetencies: "Core Competencies",
        .motivVideo: "Link to Motivational Video",
        .cvFile: "CV File (*mandatory)",
        .linkedin: "LinkedIn Profile",
        .portfolioFile: "Portfolio File (*Mandatory)",
        .portfolioLinks: "Portfolio Links",
        .howHeard: "How did you hear about our program? (Please select one option only.)",
        .selfIntro: "자기소개 (최대 300자)",
        .motivation: "지원동기 (최대 800자)",
        .essayInitiative: "작은 일이라도 스스로 시작하거나 무언가를 바꿔본 경험을 들려주세요.  (최대 500자)",
        .essayCraft: "결과물의 완성도를 높이기 위해 치열하게 고민했던 과정이 자세하게 드러나면 더 좋아요. (최대 500자)",
        .essayChallenge: "익숙하지 않은 분야에 도전했거나 협업을 통해 나의 다른 면을 발견한 경험을 들려주세요. (최대 500자)"
    ]

    /// 일반지원 rows only count when they reached this status.
    static let generalSubmittedStatus = "Submitted"
    static let generalStatusColumn = "Process Status"
}
