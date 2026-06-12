import SwiftUI
import AppKit

struct ContentView: View {
    @EnvironmentObject var recorder: AudioRecorder
    @AppStorage("menuBarMode") private var menuBarMode = false
    @Environment(\.openWindow) private var openWindow

    private let newTag = "__new__"
    @State private var showTranscribeConfirm = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("SimpleRec")
                .font(.title2).bold()
                .frame(maxWidth: .infinity, alignment: .center)

            // Library
            VStack(alignment: .leading, spacing: 4) {
                Text("ライブラリ").font(.caption).foregroundStyle(.secondary)
                HStack {
                    Text(recorder.libraryDisplay)
                        .font(.caption).lineLimit(1).truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button("変更") { recorder.chooseLibrary() }
                        .controlSize(.small).disabled(recorder.isRecording)
                }
            }

            Divider()

            // Screen Recording permission banner (shown only when not granted)
            if recorder.needsScreenPermission {
                VStack(alignment: .leading, spacing: 6) {
                    Text("システム音声には「画面収録」の許可が必要です")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        Button("許可を取得する") { recorder.requestScreenAccess() }
                            .controlSize(.small)
                        Button("再確認") { recorder.refreshScreenPermission() }
                            .controlSize(.small)
                    }
                    Text("設定でSimpleRecをオンにした後、アプリを再起動すると確実です。")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
                .padding(8)
                .background(Color(nsColor: .controlBackgroundColor))
                .cornerRadius(8)
            }

            // Sources
            HStack(spacing: 16) {
                Toggle("システム音声", isOn: $recorder.captureSystemAudio)
                Toggle("マイク", isOn: $recorder.captureMic)
            }
            .toggleStyle(.checkbox)
            .disabled(recorder.isRecording)

            Toggle("Zoom自動録音", isOn: $recorder.autoRecordZoom)
                .toggleStyle(.checkbox)
                .disabled(recorder.isRecording)

            // Recording name (applies to the active/just-recorded or selected recording)
            VStack(alignment: .leading, spacing: 4) {
                Text("録音名（任意）").font(.caption).foregroundStyle(.secondary)
                HStack {
                    TextField("例: 定例MTG", text: $recorder.recordingName)
                        .textFieldStyle(.roundedBorder)
                    if !recorder.isRecording && recorder.selectedRecording != nil {
                        Button("名前変更") { recorder.renameSelected() }
                            .controlSize(.small)
                    }
                }
            }

            // Timer + record button
            Text(timeString(recorder.elapsed))
                .font(.system(size: 30, weight: .semibold, design: .monospaced))
                .foregroundStyle(recorder.isRecording ? .red : .primary)
                .frame(maxWidth: .infinity, alignment: .center)

            Button(action: toggle) {
                Text(recorder.isRecording ? "停止" : "録音開始")
                    .frame(maxWidth: .infinity).padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .tint(recorder.isRecording ? .red : .accentColor)
            .disabled(!recorder.captureSystemAudio && !recorder.captureMic)

            Divider()

            // Existing recordings
            VStack(alignment: .leading, spacing: 6) {
                Text("レコーディング").font(.caption).foregroundStyle(.secondary)
                HStack {
                    Picker("", selection: pickerBinding) {
                        Text("（選択なし）").tag(newTag)
                        ForEach(recorder.recordings, id: \.self) { name in
                            Text(name).tag(name)
                        }
                    }
                    .labelsHidden()
                    .disabled(recorder.isRecording)
                    Button { recorder.refreshRecordings() } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .controlSize(.small).disabled(recorder.isRecording)
                }
                Button("フォルダを開く") { recorder.openSelectedInFinder() }
                    .controlSize(.small)

                // Transcription
                HStack(spacing: 6) {
                    Text("モデル").font(.caption).foregroundStyle(.secondary)
                    Picker("", selection: $recorder.selectedModelName) {
                        ForEach(AudioRecorder.modelOptions, id: \.self) { n in
                            Text(n).tag(n)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .disabled(recorder.isTranscribing || recorder.isRecording)
                }
                HStack(spacing: 8) {
                    if !recorder.modelReady {
                        Button("モデルを取得") { recorder.downloadModel() }
                            .controlSize(.small)
                            .disabled(recorder.isTranscribing)
                    }
                    Button("文字起こし") {
                        if recorder.transcriptSelfExists || recorder.transcriptOtherExists || recorder.transcriptMergedExists {
                            showTranscribeConfirm = true
                        } else {
                            recorder.transcribeSelected()
                        }
                    }
                    .controlSize(.small)
                    .disabled(recorder.isTranscribing || recorder.isRecording
                              || recorder.selectedRecording == nil)
                    .alert("文字起こしを再作成しますか？", isPresented: $showTranscribeConfirm) {
                        Button("キャンセル", role: .cancel) {}
                        Button("再作成", role: .destructive) { recorder.transcribeSelected() }
                    } message: {
                        Text("選択中のモデルで生成済みのファイルを上書きします。")
                    }
                    if recorder.isTranscribing { ProgressView().controlSize(.small) }
                }
                if recorder.selectedRecording != nil {
                    HStack(spacing: 10) {
                        transcriptBadge("自分",  exists: recorder.transcriptSelfExists)
                        transcriptBadge("相手",  exists: recorder.transcriptOtherExists)
                        transcriptBadge("マージ", exists: recorder.transcriptMergedExists)
                    }
                }
                if !recorder.transcriptionStatus.isEmpty {
                    Text(recorder.transcriptionStatus)
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            if !recorder.statusMessage.isEmpty {
                Text(recorder.statusMessage)
                    .font(.footnote).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
            Spacer(minLength: 0)

            HStack(spacing: 8) {
                Button(menuBarMode ? "ウィンドウモードに切り替え" : "メニューバーモードに切り替え") {
                    toggleMode()
                }
                if menuBarMode {
                    Text("·").foregroundStyle(.tertiary)
                    Button("終了") { NSApp.terminate(nil) }
                        .foregroundStyle(.red)
                }
            }
            .controlSize(.mini)
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .center)

            Text("build \(buildVersion)")
                .font(.caption2).foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .center)
        }
        .padding(20)
    }

    private var buildVersion: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String) ?? "?"
    }

    private var pickerBinding: Binding<String> {
        Binding(
            get: { recorder.selectedRecording ?? newTag },
            set: { recorder.selectRecording($0 == newTag ? nil : $0) }
        )
    }

    private func toggle() {
        recorder.isRecording ? recorder.stopRecording() : recorder.startRecording()
    }

    @ViewBuilder
    private func transcriptBadge(_ label: String, exists: Bool) -> some View {
        Label(label, systemImage: exists ? "checkmark.circle.fill" : "circle")
            .font(.caption2)
            .foregroundStyle(exists ? Color.green : Color.secondary)
    }

    private func toggleMode() {
        if menuBarMode {
            menuBarMode = false
            NSApp.setActivationPolicy(.regular)
            if let w = NSApp.windows.first(where: { !($0 is NSPanel) }) {
                w.makeKeyAndOrderFront(nil)
            } else {
                openWindow(id: "main")
            }
        } else {
            menuBarMode = true
            NSApp.setActivationPolicy(.accessory)
            NSApp.windows.filter { !($0 is NSPanel) }.forEach { $0.orderOut(nil) }
        }
    }

    private func timeString(_ t: TimeInterval) -> String {
        let s = Int(t)
        return String(format: "%02d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
    }
}
