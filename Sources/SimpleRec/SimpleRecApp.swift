import SwiftUI
import AppKit
import UserNotifications

class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            RecLog.shared.log("notifications: permission granted=\(granted)")
        }

        if UserDefaults.standard.bool(forKey: "menuBarMode") {
            NSApp.setActivationPolicy(.accessory)
            DispatchQueue.main.async {
                NSApp.windows.filter { !($0 is NSPanel) }.forEach { $0.orderOut(nil) }
            }
        }
    }

    // Show notifications even when the app is in foreground
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
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
