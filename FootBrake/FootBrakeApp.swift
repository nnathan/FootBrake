import SwiftUI

@main
struct FootBrakeApp: App {
    init() {
        // Imported copies from a previous run are no longer referenced.
        ImportStore.removeAll()
    }

    var body: some Scene {
        WindowGroup {
            HomeView()
        }
    }
}
