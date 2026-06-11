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

## 다이나믹 폰트 / 글자 크기 설정
- [x] `FontSizeOption` (DynamicTypeSize 매핑) + `@AppStorage` 저장 (`AppSettings.swift`)
- [x] 설정창(⌘,) `SettingsView` — 글자 크기 Picker + 미리보기
- [x] 루트에 `.dynamicTypeSize(...)` 적용 → 앱 전체 시맨틱 폰트 스케일
- [x] 메인 제목 고정폰트 → 스케일되는 `.largeTitle`로 변경
