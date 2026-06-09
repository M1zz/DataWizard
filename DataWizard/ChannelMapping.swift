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
        .province: "현재 거주하고 있는 도/시를 선택해주세요.",
        .currentCity: "어떤 도시에 거주하고 계신가요?",
        .currentStatus: "현재 신분",
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
        .processStatus: "Process Status",
        .gender: "Gender",
        .nationality: "Nationality",
        .currentCity: "Current City",
        .province: "Province",
        .country: "Current Country of Residence",
        .currentAddress: "Current Address",
        .pohangResidency: "Pohang/Gyeongsangbuk-do Residency and Origin",
        .currentStatus: "Current Status",
        .schoolCompany: "School/University/Company",
        .majorDept: "Major/Department",
        .levelOfEducation: "Level of Education",
        .school: "School/University",
        .major: "Major",
        .considerMyself: "Currently, I consider myself as a...",
        .foundationGrad: "Are you a graduate or an expected graduate of the Apple Foundation Program?",
        .coreCompetencies: "Core Competencies",
        .cvFile: "CV File (*mandatory)",
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
