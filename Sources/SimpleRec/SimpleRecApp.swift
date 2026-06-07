import SwiftUI
import AppKit

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        if UserDefaults.standard.bool(forKey: "menuBarMode") {
            NSApp.setActivationPolicy(.accessory)
            DispatchQueue.main.async {
                NSApp.windows.filter { !($0 is NSPanel) }.forEach { $0.orderOut(nil) }
            }
        }
    }
}

struct MenuBarStatusLabel: View {
    @ObservedObject var recorder: AudioRecorder

    var body: some View {
        if recorder.isRecording {
            Image(systemName: "mic.fill")
                .foregroundStyle(.red)
        } else if recorder.isTranscribing {
            Image(systemName: "waveform")
                .foregroundStyle(Color.accentColor)
        } else {
            Image(systemName: "mic")
        }
    }
}

@main
struct SimpleRecApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var recorder = AudioRecorder()

    var body: some Scene {
        WindowGroup(id: "main") {
            ContentView()
                .environmentObject(recorder)
                .frame(width: 400, height: 620)
        }

        MenuBarExtra {
            ContentView()
                .environmentObject(recorder)
                .frame(width: 400, height: 620)
        } label: {
            MenuBarStatusLabel(recorder: recorder)
        }
        .menuBarExtraStyle(.window)
    }
}
