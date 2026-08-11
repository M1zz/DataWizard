import SwiftUI

@main
struct DataWizardApp: App {
    @AppStorage(FontSizeOption.storageKey) private var fontSizeRaw = FontSizeOption.default.rawValue

    private var fontSize: FontSizeOption { FontSizeOption(rawValue: fontSizeRaw) ?? .default }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 920, minHeight: 640)
                .dynamicTypeSize(fontSize.dynamicTypeSize)
        }
        .windowResizability(.contentSize)

        // 합쳐진 파일 미리보기 — 검토 중 옆에 두고 보는 별도 윈도우.
        Window("합쳐진 파일 미리보기", id: "preview") {
            PreviewWindowView()
                .dynamicTypeSize(fontSize.dynamicTypeSize)
        }
        .defaultSize(width: 1000, height: 520)

        // App menu → 설정… (⌘,)
        Settings {
            SettingsView()
        }
    }
}
