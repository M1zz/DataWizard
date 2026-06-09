import SwiftUI

@main
struct DataWizardApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 920, minHeight: 640)
        }
        .windowResizability(.contentSize)
    }
}
