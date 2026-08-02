import SwiftUI

@main
struct SpeakPasteApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .onOpenURL { url in
                    model.handleIncomingURL(url)
                }
        }
    }
}
