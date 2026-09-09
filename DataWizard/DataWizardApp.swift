import SwiftUI
import AppKit

/// 앱을 켤 때 시스템이 되살린 ‘완성본 미리보기’ 창을 닫는다.
/// (SwiftUI의 `defaultLaunchBehavior(.suppressed)`는 macOS 15부터라 쓸 수 없다.)
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        closeRestoredPreview()
        // 창 복원이 조금 늦게 끝나는 경우가 있어 한 번 더 확인한다.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.closeRestoredPreview() }
    }

    private func closeRestoredPreview() {
        guard !PreviewModel.shared.openedByUser else { return }
        for w in NSApp.windows where w.title == PreviewWindowView.windowTitle {
            w.isRestorable = false
            w.close()
        }
    }
}

@main
struct DataWizardApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @AppStorage(FontSizeOption.storageKey) private var fontSizeRaw = FontSizeOption.default.rawValue

    private var fontSize: FontSizeOption { FontSizeOption(rawValue: fontSizeRaw) ?? .default }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 920, minHeight: 640)
                .dynamicTypeSize(fontSize.dynamicTypeSize)
        }
        .windowResizability(.contentSize)

        // 완성본 미리보기 — 작업 중 옆에 두고 보는 별도 윈도우.
        // 앱을 켤 때는 뜨지 않는다 (창이 복원돼도 스스로 닫는다 — PreviewWindowView.onAppear).
        Window("완성본 미리보기", id: "preview") {
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
