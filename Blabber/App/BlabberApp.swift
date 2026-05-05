import SwiftUI

@main
struct BlabberApp: App {
    init() {
        LocationService.shared.requestPermission()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
