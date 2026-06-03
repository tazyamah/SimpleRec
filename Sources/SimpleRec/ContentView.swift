import SwiftUI
import AppKit

struct ContentView: View {
    @EnvironmentObject var recorder: AudioRecorder

    private let newTag = "__new__"

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

                // Transcription (stage 2-a: mic -> transcript_self.txt)
                HStack(spacing: 8) {
                    if !recorder.modelReady {
                        Button("モデルを取得") { recorder.downloadModel() }
                            .controlSize(.small)
                            .disabled(recorder.isTranscribing)
                    }
                    Button("文字起こし（自分）") { recorder.transcribeSelected() }
                        .controlSize(.small)
                        .disabled(recorder.isTranscribing || recorder.isRecording
                                  || recorder.selectedRecording == nil)
                    if recorder.isTranscribing { ProgressView().controlSize(.small) }
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

    private func timeString(_ t: TimeInterval) -> String {
        let s = Int(t)
        return String(format: "%02d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
    }
}
