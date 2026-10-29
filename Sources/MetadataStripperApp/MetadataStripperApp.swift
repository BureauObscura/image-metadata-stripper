import SwiftUI

@main
struct MetadataStripperApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
        }
        .defaultSize(width: 720, height: 560)
        .windowResizability(.contentMinSize)
    }
}
