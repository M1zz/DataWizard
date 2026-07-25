# DataWizard 작업

## 데이터 클렌징 3대 요구사항 (완료)

### 1. 여러 컬럼 → 한 컬럼 합치기 (공백/구분자 지정)
- [x] `ColumnSourceSheet` 구분자 빠른 선택(붙여쓰기/공백/하이픈/쉼표) 칩 추가
- [x] 파일별 다중 컬럼 조합 (기존)
- [x] 조합 구분자 지정 (기존)

### 2. 정규식으로 한 패턴 통일 + 실패값 표시
- [x] 전화번호/날짜 리뷰에 "표준화 실패" 전체 목록 + 인라인 수정 (`FlaggedValuesBody`)
- [x] `RegexCleanupSheet`에 목표 패턴(검증) 입력 → 맞지 않는 값(실패) 목록
- [x] 전화번호 정규화 `1023755880`/`+821023755880` → `010-2375-5880` (기존 Normalizer)

### 3. 매핑테이블 추가 → 전 데이터 매핑
- [x] 매핑표 붙여넣기/가져오기 파서 (`MappingTableParser`, 탭·→·:·쉼표 구분)
- [x] 매핑표 가져오기 시트 + 적용 결과 미리보기 (`MappingTableSheet`)
- [x] 미매핑 커버리지 표시 (전체 N종 / 매핑 M종 / 미매핑 K종) + "미매핑 값 채우기"
- [x] 값별 수동 매핑·자동 통일 (기존)

## 애플 아카데미 데이터 스펙 대응 (간편 Public/Private + 일반)
- [x] 지원방식 3분류: 일반/간편(Public)/간편(Private) — 파일명 기준 (`FilePlan.applicationType`)
- [x] 해외 전화번호 원본 유지 (`Normalizer.cleanPhone`, 비표준은 원본)
- [x] 중복 Key = 전화번호 OR 이메일 (union-find, `MergeEngine.deduplicate`)
- [x] 매핑표 파일 4종 제공 (~/Downloads/for Leeo/mappings/: City/Country/CurrentStatus/LevelOfEducation)
- [x] 스키마를 최종본과 동일한 73컬럼으로 확장 (`UnifiedColumn`)
- [x] CSV 중복 헤더 버그 수정 — "이름 (2)" 접미사로 보존 (`CSVParser`)
- [x] Unique ID 생성 6F10001~ (Code 없는 간편지원, `MergeEngine`)
- [x] 만 나이 + Age Group (기준일: 다음 3/1, `Normalizer.age/ageGroup`)
- [x] Current City ← 도/시 + City(Overseas) 분리, 해외 국가명 치환 (`compose`)
- [x] Current Status = 대학단계+그외 조합, School/Company 3컬럼 조합 시드
- [x] 성별 자동 통일 영문(Male/Female)
- [x] 중복 유지 기준: 최신 Submitted At → 채널 우선 (정답과 채널 분포 일치 검증됨)
- 검증 결과: Submitted 필터 111 ✓ · 총 336행 ✓ · 중복 17그룹/18삭제 ✓ · Keep 채널 12/4/1 ✓

## 명시적 변환 제안 (자동변환 → 제안+승인)
- [x] 전화번호/생년월일: 전체 종을 `이전 값 → 제안 값` 표로 표시 (`ProposalsBody`)
- [x] 요약 칩: 변환 제안 N종 · 이미 표준 N종 · 확인 필요 N종(미해결 카운트)
- [x] 세그먼트 필터 (전체/변환 제안/이미 표준/확인 필요)
- [x] 확인 필요 행만 인라인 수정 가능, 숨겨진 변환 없음

## 매핑표 잠금 + 유사도 추천
- [x] 매핑표 적용 시 컬럼 값을 허용 목록으로 잠금 (자유 입력 → Picker)
- [x] 매핑표 밖 값: 유사도 추천 (`Similarity` — 편집거리 + 한↔영 사전 브리지)
- [x] 행별 "추천: X (NN%)" 승인 버튼 + "추천대로 승인" 일괄 버튼
- [x] 매핑표 시트: 선택 메뉴 유사도순 정렬 + ✨추천 + "추천대로 모두 배정"
- [x] 빈 통일 값(`값 → `) 거부 — 데이터 삭제 사고 방지

## 검증 가능성 (사용자가 100% 신뢰)
- [x] 변경 추적: 병합이 수정한 모든 셀 기록 (`ChangeRecord` — 파일·출처 키·이전→이후)
- [x] 변경 보고서 CSV 내보내기 (원본과 1:1 대조용)
- [x] 결과 화면 검증 요약: "값 수정 N건" / "0건 — 원본 그대로"
- [x] 검토 부제목에 "✏️ 수정 예정 N종" 표시 (합치기 전 확인)
- [x] 매핑표 시트 커버리지 게이지 (미매핑 N종)

## 결정 TODO 흐름 (파일 3개 → 결정할 일만 뜨고 하나씩 해결 → 완성본)
- [x] 검토 화면에 탭 추가: `결정 TODO`(기본) · `전체 컬럼 N` (`reviewTabBar`, `ReviewTab`)
- [x] `결정 TODO` = 실제 판단이 필요한 컬럼만 추림 (`isDecisionRelevant` — 전화/생년월일 표준화 실패, 매핑표 밖 값, 이상값, 값 통일 후보)
- [x] 미해결(⚠️) 항목 위로 정렬 (`decisionReviews`) + `결정해야 할 일 X / Y` 진행 막대 (`decisionProgressHeader`)
- [x] 각 TODO 인라인 해결 (값 편집 → `openCount` 0) 또는 `이대로 확정` 체크(`checked`)로 해결 (`isResolved`)
- [x] 병합 게이트를 `canMerge`(모든 결정 해결)로 변경 — 73컬럼 전부 체크 강제 해제
- [x] 서브타이틀 상태 뱃지(⚠️ 결정 필요 N종 / ✅ 해결됨) + 결정 없을 때 안내 카드
- [x] 해결할수록 미리보기 윈도우에 완성본이 채워짐 (기존 `refreshPreview` 재사용)
- [x] `여러 값을 하나로 모으기` 시트 2단계화 (① 규칙 입력 → ② 적용 결과 미리보기, `stepBar`)
- [x] 명사형 라벨 → 용도형 라벨 (매핑표→여러 값을 하나로 모으기, 정규식→패턴으로 정리하기 등)

## 파일 추가 후 ‘남길 컬럼 고르기’ 단계 (파일 → 컬럼 → 검토 → 결과)
- [x] `Stage.columns` 추가 — 파일 로드 직후 최종 컬럼 선택 화면 (`columnsStage`)
- [x] 스키마 73컬럼을 데이터 있는 것 위 / 빈(자리만) 것 아래로 정렬 + 상태 뱃지 (`columnStatus`)
- [x] 빠른 선택: 데이터 있는 것만 / 전체 선택 / 전체 해제, 선택 N/73 카운트
- [x] 기본값 = 데이터 있는 컬럼(`Set(finalColumns)`), 파일 재로드 시 유효 선택 유지
- [x] 선택(`includedColumns`)이 검토·미리보기·내보내기에 모두 반영 (`visibleFinalColumns`/`visibleReviews`/`includedOrdered`)
- [x] `Exporter.makeCSV/write`에 `columns:` 인자 추가 — 선택된 컬럼만 스키마 순서로 출력
- [x] 이전 완성본을 ‘참조 파일’로 불러와 컬럼 구성 맞추기 (`loadReference`/`applyReference`)
      - 완성본 헤더 ↔ 스키마 컬럼명 대응, 데이터 없어도 참조 컬럼 유지, 참조 컬럼 맨 위 정렬 + ‘참조’ 뱃지
      - 예: 2분기 보고서 + 7·8·9월 데이터 → 2분기와 같은 컬럼 구성으로

## 멈췄다 이어서 하기 (세션 저장/복원)
- [x] `SessionStore` + `SessionSnapshot` — 파싱 데이터(plans)+모든 결정을 Application Support에 JSON 저장
      (파일 재접근 불필요 → 원본이 옮겨져도 복원됨), Codable 라운드트립 검증 완료
- [x] 자동 저장 (0.8초 디바운스) + 창 내리거나 앱 벗어날 때 즉시 저장 (`scenePhase`)
- [x] 파일 화면 상단 ‘이전 작업 이어서 하기’ 카드 (요약·저장 시각 · 이어서/새로 시작)
- [x] 복원 시 stage·plans·finalColumns·reviews·valueMap·allowed·checked·참조 모두 되살림
- [x] 최종 내보내기 완료 시 세션 정리 (`SessionStore.clear`)
- [x] Xcode 프로젝트에 `SessionStore.swift` 등록 (pbxproj, ID 충돌 수정)

## 공식 매핑표 내장 (사양서 Mapping Table)
- [x] `MappingPresets.swift` — Current Status / City(도·시) / Country 공식 한글→영문 내장
- [x] ‘여러 값을 하나로 모으기’ 시트에 `공식 매핑표 채우기` 버튼 (해당 컬럼일 때만)
      - 이미 규칙 있으면 겹치지 않는 줄만 덧붙임 (`fillPreset`), 채운 뒤 2단계에서 검토
- [x] 사양서를 저장소 문서로 보존: `docs/데이터_클리닝_사양.md`
- 참고: Current Status 빈 값(High School Status)은 자동 매핑 제외 — 수기 확인 대상

## 컬럼 고르기 진입 시 ‘틀 있음/없음’ 갈림길 (옵션을 물어보며 진행)
- [x] `ColumnMode`(withTemplate/fromScratch) + `columnMode` 상태 — nil이면 갈림길 화면
- [x] `columnForkView` — “맞출 통합본 틀이 있으신가요?” 전용 선택 화면 (큰 카드 2개, `forkCard`)
      - 네: 완성본 불러오기 → 참조 로드 → **컬럼 선택 건너뛰고 바로 값 검토로** (`chooseTemplate`)
      - 아니요: 남길 컬럼 직접 골라 새 틀 만들기 (기존 `columnPickerView`)
- [x] `loadReference`/`applyReference` → `Bool` 반환 (취소·오류면 갈림길에 머무름)
- [x] 뒤로가기 흐름: 파일 → 갈림길 → (뒤로) 갈림길 → (뒤로) 파일 (`backToFiles`, 피커 ‘← 뒤로’)
- [x] `prepareReview` 진입 시 `columnMode=nil`로 갈림길부터, `restore`는 참조 유무로 모드 복원(갈림길 생략)

## 컬럼 타입 사용자 지정 (자유입력/범주/포맷 — 자동 판단 기본값)
- [x] `ColumnType`(freeText/category/format) + `FormatPreset`(전화번호/이메일/생년월일/직접) enum
- [x] 검토 카드 헤더에 타입 선택 메뉴(`typeControl`) — 포맷이면 하위 형식 메뉴 + ‘자동’ 뱃지
- [x] `typeOverride`/`formatChoice`/`customFormat` 상태 + 자동 판단 헬퍼(`autoType`/`autoFormat`/`effectiveType`)
- [x] 빌더가 모든 비파생 컬럼에 값·샘플·오타를 채워 타입 전환 시에도 데이터 유지 (`reviews`)
- [x] 포맷 검증 본문 `FormatBody` — 형식 안 맞는 값만 모아 인라인 수정 (이메일·직접 정규식)
- [x] 전화/생년월일은 기존 전용 제안 화면 유지(`usesProposalUI`), 이메일은 기본 포맷으로 자동 판단
- [x] `openCount`/`isDecisionRelevant`/`subtitle`/`body`를 effectiveType 기준으로 재작성
- [x] `RegexCleaner.fullyMatches` 추가(앵커 매칭), 세션 저장/복원에 타입·포맷 반영(옵셔널 필드)

## 다이나믹 폰트 / 글자 크기 설정
- [x] `FontSizeOption` (DynamicTypeSize 매핑) + `@AppStorage` 저장 (`AppSettings.swift`)
- [x] 설정창(⌘,) `SettingsView` — 글자 크기 Picker + 미리보기
- [x] 루트에 `.dynamicTypeSize(...)` 적용 → 앱 전체 시맨틱 폰트 스케일
- [x] 메인 제목 고정폰트 → 스케일되는 `.largeTitle`로 변경
