# 데이터 마법사 (DataWizard, macOS)

Combines three application channels into one normalized, deduplicated roster —
the exact pipeline behind the 2027 패스트 트랙 제출자 sheet, automated.

## What it does

1. **Ingests three channels**
   - `간편지원(Public)` — CSV (Korean source headers)
   - `간편지원(Private)` — CSV (same layout as Public)
   - `일반지원` — XLSX (title row on top → real header is row 2; only `Process Status = Submitted` rows are kept)
2. **Normalizes** each row into one unified schema, tagged with its 지원방식:
   - `Phone Number → 전화번호(Clean)` formatted `010-XXXX-XXXX`
   - `Date of Birth → 생년월일(Clean)` as `YYYY-MM-DD`
   - Korean full name rebuilt from 성 + 이름
3. **Deduplicates across channels by cleaned phone number** (not email — the
   same person often applied with different emails). One row per person is
   marked `중복 -Keep`; the rest `중복 - 삭제`. Keep priority: 일반지원 → Private → Public.
4. **Exports** the merged CSV (UTF-8 BOM, so Excel opens Korean correctly),
   optionally dropping the removed duplicates.

Validated against the real files: 336 ingested → 17 duplicate groups →
18 removed → 318 active, matching the hand-made final sheet exactly.

## Tech notes

- Pure SwiftUI, no external dependencies.
- XLSX is read in-process (`MiniZip` central-directory walk + `Compression`
  raw-inflate), so it works under the App Sandbox without spawning `unzip`.
- CSV parser is RFC-4180 (quoted fields, embedded newlines, BOM).

## Build & run

Open `DataWizard.xcodeproj` in Xcode 15+, select the **DataWizard**
scheme, and Run (⌘R). macOS 13+.

## Adapting to new forms

If next year's forms change column names, edit `ChannelMapping.swift` — every
source-to-unified mapping lives there in one auditable place. The unified
output schema and column order live in `UnifiedSchema.swift`.
