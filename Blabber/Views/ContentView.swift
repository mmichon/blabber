import SwiftUI

struct ContentView: View {
    var body: some View {
        TabView {
            RecordView()
                .tabItem {
                    Label("Record", systemImage: "waveform.circle.fill")
                }

            RecordingsListView()
                .tabItem {
                    Label("Recordings", systemImage: "list.bullet.circle.fill")
                }
        }
        .preferredColorScheme(.dark)
        .tint(.blue)
    }
}
