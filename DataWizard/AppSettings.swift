import SwiftUI

/// User-selectable app font size. Each option maps to a SwiftUI `DynamicTypeSize`
/// so every semantic font (.callout/.caption/.headline …) scales together when
/// the root view applies `.dynamicTypeSize(...)`. Persisted via `@AppStorage`.
enum FontSizeOption: Int, CaseIterable, Identifiable {
    case xSmall, small, medium, large, xLarge, xxLarge, xxxLarge

    var id: Int { rawValue }

    /// The persisted default — matches the system standard size.
    static let `default` = FontSizeOption.large

    /// `@AppStorage` key shared by the App scene and the settings window.
    static let storageKey = "fontSizeOption"

    var label: String {
        switch self {
        case .xSmall:   return "아주 작게"
        case .small:    return "작게"
        case .medium:   return "조금 작게"
        case .large:    return "보통 (기본)"
        case .xLarge:   return "크게"
        case .xxLarge:  return "더 크게"
        case .xxxLarge: return "아주 크게"
        }
    }

    var dynamicTypeSize: DynamicTypeSize {
        switch self {
        case .xSmall:   return .xSmall
        case .small:    return .small
        case .medium:   return .medium
        case .large:    return .large
        case .xLarge:   return .xLarge
        case .xxLarge:  return .xxLarge
        case .xxxLarge: return .xxxLarge
        }
    }
}

/// The macOS Settings (⌘,) window: pick the app-wide font size with a live preview.
struct SettingsView: View {
    @AppStorage(FontSizeOption.storageKey) private var raw = FontSizeOption.default.rawValue

    private var selection: Binding<FontSizeOption> {
        Binding(
            get: { FontSizeOption(rawValue: raw) ?? .default },
            set: { raw = $0.rawValue }
        )
    }

    var body: some View {
        Form {
            Section {
                Picker("글자 크기", selection: selection) {
                    ForEach(FontSizeOption.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.menu)

                if selection.wrappedValue != .default {
                    Button("기본값으로") { selection.wrappedValue = .default }
                        .controlSize(.small)
                }
            } header: {
                Text("화면 표시")
            } footer: {
                Text("앱 전체 글자 크기를 조절합니다. 표·검토 화면의 모든 글자가 함께 커지고 작아집니다.")
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("미리보기") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("컬럼별 검토").font(.headline)
                    Text("값 통일 · 12종 값 · 340행").font(.body).foregroundStyle(.secondary)
                    Text("010-2375-5880").font(.body)
                }
                .dynamicTypeSize(selection.wrappedValue.dynamicTypeSize)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .formStyle(.grouped)
        .frame(width: 440, height: 320)
    }
}
