import SwiftUI

@main
struct FootBrakeApp: App {
    init() {
        // Imports and exports from a previous run are no longer referenced.
        ImportStore.removeAll()
        OutputStore.removeAll()
    }

    var body: some Scene {
        WindowGroup {
            HomeView()
        }
    }
}
