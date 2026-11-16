import SwiftUI

@main
struct GaussApp: App {
    init() {
        // Imports and exports from a previous run are no longer referenced.
        ImportStore.removeAll()
        OutputStore.removeAll()
    }

    var body: some Scene {
        WindowGroup {
            HomeView()
                // Past this, the editor's controls and the export screen stop fitting on a phone.
                .dynamicTypeSize(...DynamicTypeSize.accessibility1)
                // Past this, the editor's controls and the export screen stop fitting on a phone.
                .dynamicTypeSize(...DynamicTypeSize.accessibility1)
        }
    }
}
