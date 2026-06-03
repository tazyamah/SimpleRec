import SwiftUI

@main
struct SimpleRecApp: App {
    @StateObject private var recorder = AudioRecorder()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(recorder)
                .frame(width: 400, height: 620)
        }
    }
}
