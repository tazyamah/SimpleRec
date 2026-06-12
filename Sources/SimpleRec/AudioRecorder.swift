import Foundation
import AVFoundation
import ScreenCaptureKit
import Combine
import AppKit
import CoreGraphics
import UserNotifications

// MARK: - Pump: converts incoming audio to a common format and buffers it

final class AudioPump: @unchecked Sendable {
    let procFormat: AVAudioFormat
    let ring: RingBuffer
    let name: String
    private var converters: [String: AVAudioConverter] = [:]
    private let convLock = NSLock()
    private(set) var pushCount = 0
    private var loggedFirst = false

    init(name: String, sampleRate: Double, channels: AVAudioChannelCount) {
        self.name = name
        self.procFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                        sampleRate: sampleRate,
                                        channels: channels,
                                        interleaved: false)!
        self.ring = RingBuffer(capacityFrames: Int(sampleRate) * 10, channels: Int(channels))
    }

    func resetCounters() { convLock.lock(); pushCount = 0; loggedFirst = false; convLock.unlock() }

    // System audio (CMSampleBuffer from ScreenCaptureKit)
    func push(_ sampleBuffer: CMSampleBuffer) {
        guard let pcm = sampleBuffer.toPCMBuffer() else {
            RecLog.shared.log("\(name).push: toPCMBuffer failed"); return
        }
        store(pcm)
    }

    // Microphone (AVAudioPCMBuffer from an AVAudioEngine input tap)
    func pushPCM(_ buffer: AVAudioPCMBuffer) { store(buffer) }

    private func store(_ pcm: AVAudioPCMBuffer) {
        guard let converted = convert(pcm) else {
            RecLog.shared.log("\(name): convert failed (in=\(pcm.format))"); return
        }
        guard let chans = converted.floatChannelData else { return }
        let n = Int(converted.frameLength)
        guard n > 0 else { return }
        var arrays: [[Float]] = []
        let chCount = Int(converted.format.channelCount)
        arrays.reserveCapacity(chCount)
        for c in 0..<chCount {
            arrays.append(Array(UnsafeBufferPointer(start: chans[c], count: n)))
        }
        ring.write(arrays, frames: n)

        convLock.lock()
        pushCount += 1
        let first = !loggedFirst
        if first { loggedFirst = true }
        convLock.unlock()
        if first { RecLog.shared.log("\(name): FIRST buffer ok (in=\(pcm.format), frames=\(n))") }
    }

    private func convert(_ input: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        if input.format == procFormat { return input }
        convLock.lock(); defer { convLock.unlock() }
        let key = input.format.description
        let conv: AVAudioConverter
        if let c = converters[key] { conv = c }
        else if let c = AVAudioConverter(from: input.format, to: procFormat) {
            converters[key] = c; conv = c
        } else { return nil }
        let ratio = procFormat.sampleRate / input.format.sampleRate
        let cap = AVAudioFrameCount(Double(input.frameLength) * ratio) + 1024
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: procFormat, frameCapacity: cap) else { return nil }
        var fed = false
        var err: NSError?
        let status = conv.convert(to: outBuf, error: &err) { _, inStatus in
            if fed { inStatus.pointee = .noDataNow; return nil }
            fed = true; inStatus.pointee = .haveData; return input
        }
        if status == .error { RecLog.shared.log("\(name).convert error: \(err?.localizedDescription ?? "?")"); return nil }
        return outBuf
    }
}

// MARK: - Mixer: pulls from sys/mic rings on a steady clock, sums, writes

final class Mixer: @unchecked Sendable {
    private let format: AVAudioFormat
    private let sysRing: RingBuffer?
    private let micRing: RingBuffer?
    private let writer: SegmentWriter
    private let sampleRate: Double
    private let maxChunk = 8192

    private let queue = DispatchQueue(label: "simplerec.mix")
    private var timer: DispatchSourceTimer?
    private var lastTick: UInt64 = 0
    private var remainder: Double = 0

    private let sysBuf: AVAudioPCMBuffer
    private let micBuf: AVAudioPCMBuffer
    private let outBuf: AVAudioPCMBuffer

    private let micWriter: SegmentWriter?
    private let sysWriter: SegmentWriter?

    init(format: AVAudioFormat, sysRing: RingBuffer?, micRing: RingBuffer?,
         mixWriter: SegmentWriter, micWriter: SegmentWriter?, sysWriter: SegmentWriter?) {
        self.format = format
        self.sysRing = sysRing
        self.micRing = micRing
        self.writer = mixWriter
        self.micWriter = micWriter
        self.sysWriter = sysWriter
        self.sampleRate = format.sampleRate
        self.sysBuf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(maxChunk))!
        self.micBuf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(maxChunk))!
        self.outBuf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(maxChunk))!
    }

    func start() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + .milliseconds(40), repeating: .milliseconds(40))
        t.setEventHandler { [weak self] in self?.tick() }
        timer = t
        lastTick = DispatchTime.now().uptimeNanoseconds
        t.resume()
        RecLog.shared.log("mixer: started")
    }

    func stop() {
        timer?.cancel(); timer = nil
        RecLog.shared.log("mixer: stopped")
    }

    private func tick() {
        let now = DispatchTime.now().uptimeNanoseconds
        let dt = Double(now &- lastTick) / 1_000_000_000.0
        lastTick = now
        let framesD = dt * sampleRate + remainder
        var frames = Int(framesD)
        remainder = framesD - Double(frames)
        if frames <= 0 { return }
        if frames > maxChunk { frames = maxChunk; remainder = 0 }
        mixAndWrite(frames)
    }

    private func mixAndWrite(_ frames: Int) {
        let ch = Int(format.channelCount)
        outBuf.frameLength = AVAudioFrameCount(frames)
        guard let out = outBuf.floatChannelData else { return }
        for c in 0..<ch { memset(out[c], 0, frames * MemoryLayout<Float>.size) }

        // Read each source into its scratch buffer (zero-filled when short),
        // then both write that track AND add it into the mix.
        if let r = sysRing {
            readInto(r, scratch: sysBuf, frames: frames, ch: ch)
            sysWriter?.write(sysBuf)
            addBuffer(sysBuf, into: out, frames: frames, ch: ch)
        }
        if let r = micRing {
            readInto(r, scratch: micBuf, frames: frames, ch: ch)
            micWriter?.write(micBuf)
            addBuffer(micBuf, into: out, frames: frames, ch: ch)
        }

        for c in 0..<ch {
            let p = out[c]
            for i in 0..<frames {
                if p[i] > 1 { p[i] = 1 } else if p[i] < -1 { p[i] = -1 }
            }
        }
        writer.write(outBuf)
    }

    private func readInto(_ ring: RingBuffer, scratch: AVAudioPCMBuffer, frames: Int, ch: Int) {
        scratch.frameLength = AVAudioFrameCount(frames)
        guard let s = scratch.floatChannelData else { return }
        for c in 0..<ch { memset(s[c], 0, frames * MemoryLayout<Float>.size) }
        _ = ring.read(into: scratch, maxFrames: frames)
    }

    private func addBuffer(_ scratch: AVAudioPCMBuffer,
                           into out: UnsafePointer<UnsafeMutablePointer<Float>>,
                           frames: Int, ch: Int) {
        guard let s = scratch.floatChannelData else { return }
        for c in 0..<ch {
            let dst = out[c]; let src = s[c]
            for i in 0..<frames { dst[i] += src[i] }
        }
    }

}

// MARK: - Segmenting file writer

final class SegmentWriter: @unchecked Sendable {
    private let lock = NSLock()
    private let folder: URL
    private let baseName: String
    private let settings: [String: Any]
    private let sampleRate: Double
    private let bytesPerSecond: Double
    private let maxBytes: Double
    private let headerMargin: Double = 64 * 1024

    private var file: AVAudioFile?
    private var part = 0
    private var framesInSegment: Double = 0
    private(set) var urls: [URL] = []
    private(set) var writeCount = 0

    init(folder: URL, baseName: String, settings: [String: Any],
         sampleRate: Double, bitrate: Double, maxBytes: Double) {
        self.folder = folder
        self.baseName = baseName
        self.settings = settings
        self.sampleRate = sampleRate
        self.bytesPerSecond = bitrate / 8.0
        self.maxBytes = maxBytes
    }

    func write(_ buffer: AVAudioPCMBuffer) {
        lock.lock(); defer { lock.unlock() }
        if file == nil { openNext() }
        let estBytes = (framesInSegment / sampleRate) * bytesPerSecond + headerMargin
        if estBytes >= maxBytes { openNext() }
        do {
            try file?.write(from: buffer)
            framesInSegment += Double(buffer.frameLength)
            writeCount += 1
            if writeCount == 1 {
                RecLog.shared.log("writer: FIRST write ok (frames=\(buffer.frameLength))")
            }
        } catch {
            RecLog.shared.log("writer.write error: \(error.localizedDescription)")
        }
    }

    private func openNext() {
        file = nil
        part += 1
        let name = String(format: "%@_part%02d.m4a", baseName, part)
        let url = folder.appendingPathComponent(name)
        do {
            file = try AVAudioFile(forWriting: url, settings: settings)
            framesInSegment = 0
            urls.append(url)
            RecLog.shared.log("writer: opened \(name)")
        } catch {
            RecLog.shared.log("writer: FAILED to open \(name): \(error.localizedDescription)")
        }
    }

    func finish() -> [URL] {
        lock.lock(); defer { lock.unlock() }
        file = nil
        return urls
    }
}

// MARK: - Recorder

@MainActor
final class AudioRecorder: NSObject, ObservableObject {

    @Published var isRecording = false
    @Published var elapsed: TimeInterval = 0
    @Published var lastFiles: [URL] = []
    @Published var captureSystemAudio = true
    @Published var captureMic = true
    @Published var statusMessage = ""
    @Published var needsScreenPermission = false
    @Published var autoRecordZoom = false

    // Library = parent folder chosen once. Recordings = its subfolders.
    @Published var libraryDisplay = ""
    @Published var recordings: [String] = []          // subfolder names, newest first
    @Published var selectedRecording: String?          // nil = none selected
    @Published var recordingName = ""                  // name field (new name / rename)

    // Transcription (WhisperKit)
    @Published var modelReady = false
    @Published var isTranscribing = false
    @Published var transcriptionStatus = ""
    @Published var transcriptSelfExists = false
    @Published var transcriptOtherExists = false
    @Published var transcriptMergedExists = false
    static let modelOptions = [
        "openai_whisper-large-v3_turbo",
        "openai_whisper-large-v3",
        "openai_whisper-medium",
        "openai_whisper-small"
    ]
    @Published var selectedModelName: String
    private var cancellables = Set<AnyCancellable>()

    private let sampleRate: Double = 48_000
    private let channelCount: AVAudioChannelCount = 2
    private let bitrate: Double = 128_000
    private let maxBytes: Double = 24 * 1024 * 1024

    private let procFormat: AVAudioFormat
    private let sysPump: AudioPump
    private let micPump: AudioPump

    private let engine = AVAudioEngine()
    private var micTapInstalled = false

    private var stream: SCStream?
    private var streamOutput: StreamOutput?

    private var mixWriter: SegmentWriter?
    private var micWriter: SegmentWriter?
    private var sysWriter: SegmentWriter?
    private var mixer: Mixer?

    private var startDate: Date?
    private var timer: Timer?
    private var isStarting = false
    private let zoomMonitor = ZoomMonitor()
    private var mixerWriteCountAtLastCheck = 0
    private var watchdogTimer: Timer?

    private var activeRecordingFolder: URL?            // folder being recorded into
    private var activeTimestamp = ""                   // timestamp prefix of active recording
    private var engineConfigObserver: NSObjectProtocol?

    private let bookmarkKey = "libraryBookmark"
    private var libraryURL: URL?

    override init() {
        sysPump = AudioPump(name: "sys", sampleRate: 48_000, channels: 2)
        micPump = AudioPump(name: "mic", sampleRate: 48_000, channels: 2)
        procFormat = sysPump.procFormat
        let saved = UserDefaults.standard.string(forKey: "selectedModelName") ?? ""
        selectedModelName = AudioRecorder.modelOptions.contains(saved)
            ? saved : AudioRecorder.modelOptions[0]
        super.init()
        resolveSavedLibrary()
        updateLibraryDisplay()
        refreshRecordings()
        refreshModelState()
        refreshScreenPermission()
        $selectedModelName.dropFirst().sink { [weak self] name in
            UserDefaults.standard.set(name, forKey: "selectedModelName")
            self?.refreshModelState()
            self?.refreshTranscriptState()
        }.store(in: &cancellables)

        autoRecordZoom = UserDefaults.standard.bool(forKey: "autoRecordZoom")
        $autoRecordZoom.dropFirst().sink { [weak self] enabled in
            guard let self else { return }
            UserDefaults.standard.set(enabled, forKey: "autoRecordZoom")
            if enabled { self.startZoomMonitor() } else { self.zoomMonitor.stop() }
        }.store(in: &cancellables)
        if autoRecordZoom { startZoomMonitor() }
    }

    /// Reflect current Screen Recording grant into the UI flag (no dialog).
    func refreshScreenPermission() {
        needsScreenPermission = !CGPreflightScreenCaptureAccess()
    }

    // MARK: Zoom auto-recording

    private func startZoomMonitor() {
        zoomMonitor.onMeetingStart = { [weak self] in
            Task { @MainActor in
                guard let self = self, !self.isRecording else { return }
                RecLog.shared.log("zoomMonitor: auto-start recording")
                self.startRecording()
                self.sendNotification(title: "録音を開始しました", body: "Zoomミーティングを検出しました")
            }
        }
        zoomMonitor.onMeetingEnd = { [weak self] in
            Task { @MainActor in
                guard let self = self, self.isRecording else { return }
                RecLog.shared.log("zoomMonitor: auto-stop recording")
                self.stopRecording()
                self.sendNotification(title: "録音を停止しました", body: "Zoomミーティングが終了しました")
            }
        }
        zoomMonitor.start()
    }

    // MARK: Notifications

    func sendNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req) { err in
            if let err { RecLog.shared.log("notification error: \(err.localizedDescription)") }
        }
    }

    // MARK: Unexpected stop

    private func unexpectedStop(reason: String) {
        guard isRecording else { return }
        RecLog.shared.log("unexpectedStop: \(reason)")
        stopRecording()
        statusMessage = "録音が予期せず終了しました: \(reason)"
        sendNotification(title: "録音が予期せず終了しました", body: reason)
    }

    // MARK: Model / transcription (stage 2-a: mic -> transcript_self.txt)

    private func modelsDir() -> URL {
        library().appendingPathComponent("_models", isDirectory: true)
    }

    func openScreenRecordingSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Try to surface the system permission dialog. macOS only shows the
    /// "Open System Settings / Deny" dialog when the app is UNDETERMINED for
    /// screen recording; once answered it won't show again. If no dialog
    /// appears (already answered), fall back to opening the Settings pane.
    func requestScreenAccess() {
        let granted = CGRequestScreenCaptureAccess()   // shows dialog if undetermined
        needsScreenPermission = !granted
        if !granted { openScreenRecordingSettings() }
    }

    func refreshModelState() {
        modelReady = Transcriber.isModelReady(modelsDir: modelsDir(), modelName: selectedModelName)
    }

    func refreshTranscriptState() {
        guard let sel = selectedRecording else {
            transcriptSelfExists = false; transcriptOtherExists = false; transcriptMergedExists = false
            return
        }
        let folder = library().appendingPathComponent(sel, isDirectory: true)
        let fm = FileManager.default
        let s = "_\(selectedModelName)"
        transcriptSelfExists   = fm.fileExists(atPath: folder.appendingPathComponent("transcript_self\(s).txt").path)
        transcriptOtherExists  = fm.fileExists(atPath: folder.appendingPathComponent("transcript_other\(s).txt").path)
        transcriptMergedExists = fm.fileExists(atPath: folder.appendingPathComponent("transcript\(s).txt").path)
    }

    func downloadModel() {
        guard !isTranscribing else { return }
        isTranscribing = true
        transcriptionStatus = "モデルを取得中…（初回は数百MB、しばらくかかります）"
        let dir = modelsDir(); let name = selectedModelName
        Task {
            do {
                let t = Transcriber(modelsDir: dir, modelName: name)
                try await t.ensureLoaded()
                await MainActor.run {
                    self.modelReady = true
                    self.transcriptionStatus = "モデルの準備ができました"
                    self.isTranscribing = false
                }
            } catch {
                await MainActor.run {
                    self.transcriptionStatus = "モデル取得に失敗: \(error.localizedDescription)"
                    self.isTranscribing = false
                }
            }
        }
    }

    func transcribeSelected() {
        guard !isTranscribing, !isRecording, let sel = selectedRecording else {
            transcriptionStatus = "レコーディングを選択してください"; return
        }
        let folder = library().appendingPathComponent(sel, isDirectory: true)
        let micParts = partFiles(in: folder, prefix: "mic")
        let sysParts = partFiles(in: folder, prefix: "system")
        guard !micParts.isEmpty || !sysParts.isEmpty else {
            transcriptionStatus = "音声ファイルが見つかりません"; return
        }
        isTranscribing = true
        transcriptionStatus = "文字起こし中…"
        let dir = modelsDir(); let name = selectedModelName

        Task {
            do {
                let t = Transcriber(modelsDir: dir, modelName: name)

                // モデルのロード（未ダウンロードなら数百MBのダウンロードが走る）
                transcriptionStatus = modelReady
                    ? "モデルをロード中…"
                    : "モデルをダウンロード中…（初回は数百MB、しばらくかかります）"
                try await t.ensureLoaded()
                modelReady = true

                // mic パートを順に処理
                var selfText = ""
                var micSegs: [(start: Double, text: String)] = []
                var micOffset = 0.0
                for (i, url) in micParts.enumerated() {
                    transcriptionStatus = "文字起こし中… 自分 \(i + 1)/\(micParts.count)"
                    let (text, segs) = try await t.transcribe(url)
                    if !selfText.isEmpty { selfText += " " }
                    selfText += text
                    for seg in segs {
                        let s = seg.text.trimmingCharacters(in: .whitespaces)
                        if !s.isEmpty { micSegs.append((start: seg.start + micOffset, text: s)) }
                    }
                    micOffset += audioDuration(url)
                }

                // system パートを順に処理
                var otherText = ""
                var sysSegs: [(start: Double, text: String)] = []
                var sysOffset = 0.0
                for (i, url) in sysParts.enumerated() {
                    transcriptionStatus = "文字起こし中… 相手 \(i + 1)/\(sysParts.count)"
                    let (text, segs) = try await t.transcribe(url)
                    if !otherText.isEmpty { otherText += " " }
                    otherText += text
                    for seg in segs {
                        let s = seg.text.trimmingCharacters(in: .whitespaces)
                        if !s.isEmpty { sysSegs.append((start: seg.start + sysOffset, text: s)) }
                    }
                    sysOffset += audioDuration(url)
                }

                // 出力ファイルを書き出す（ファイル名にモデル名を含める）
                let fileSuffix = "_\(name)"
                var written: [String] = []
                if !selfText.isEmpty {
                    let fname = "transcript_self\(fileSuffix).txt"
                    try selfText.write(to: folder.appendingPathComponent(fname),
                                       atomically: true, encoding: .utf8)
                    written.append(fname)
                }
                if !otherText.isEmpty {
                    let fname = "transcript_other\(fileSuffix).txt"
                    try otherText.write(to: folder.appendingPathComponent(fname),
                                        atomically: true, encoding: .utf8)
                    written.append(fname)
                }
                let merged = mergeTranscripts(mic: micSegs, sys: sysSegs)
                if !merged.isEmpty {
                    let fname = "transcript\(fileSuffix).txt"
                    try merged.write(to: folder.appendingPathComponent(fname),
                                     atomically: true, encoding: .utf8)
                    written.append(fname)
                }
                RecLog.shared.log("transcribe: done, wrote \(written.joined(separator: ", "))")
                refreshTranscriptState()
                modelReady = true
                transcriptionStatus = written.isEmpty
                    ? "文字起こし結果なし"
                    : "完了: \(written.joined(separator: ", "))"
                isTranscribing = false
            } catch {
                transcriptionStatus = "文字起こし失敗: \(error.localizedDescription)"
                isTranscribing = false
            }
        }
    }

    private func partFiles(in folder: URL, prefix: String) -> [URL] {
        let all = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: nil)) ?? []
        return all
            .filter { $0.lastPathComponent.hasPrefix(prefix + "_part") && $0.pathExtension == "m4a" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func audioDuration(_ url: URL) -> Double {
        guard let file = try? AVAudioFile(forReading: url) else { return 0 }
        return Double(file.length) / file.processingFormat.sampleRate
    }

    private func mergeTranscripts(
        mic: [(start: Double, text: String)],
        sys: [(start: Double, text: String)]
    ) -> String {
        struct Line { let start: Double; let text: String }
        let lines = mic.map { Line(start: $0.start, text: "[自分] \($0.text)") }
                   + sys.map { Line(start: $0.start, text: "[相手] \($0.text)") }
        return lines.sorted { $0.start < $1.start }
                    .map { $0.text }
                    .joined(separator: "\n")
    }

    // MARK: Library & recordings

    func chooseLibrary() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "選択"
        if panel.runModal() == .OK, let url = panel.url {
            libraryURL = url
            if let data = try? url.bookmarkData() {
                UserDefaults.standard.set(data, forKey: bookmarkKey)
            }
            updateLibraryDisplay()
            refreshRecordings()
            refreshModelState()
        }
    }

    private func resolveSavedLibrary() {
        guard let data = UserDefaults.standard.data(forKey: bookmarkKey) else { return }
        var stale = false
        if let url = try? URL(resolvingBookmarkData: data, bookmarkDataIsStale: &stale) {
            libraryURL = url
        }
    }

    private func library() -> URL {
        if let u = libraryURL { return u }
        let fm = FileManager.default
        let base = fm.urls(for: .musicDirectory, in: .userDomainMask).first
            ?? fm.homeDirectoryForCurrentUser
        return base.appendingPathComponent("SimpleRec", isDirectory: true)
    }

    private func updateLibraryDisplay() { libraryDisplay = library().path }

    func refreshRecordings() {
        let fm = FileManager.default
        let lib = library()
        try? fm.createDirectory(at: lib, withIntermediateDirectories: true)
        let items = (try? fm.contentsOfDirectory(at: lib, includingPropertiesForKeys: [.isDirectoryKey],
                                                 options: [.skipsHiddenFiles])) ?? []
        let dirs = items.filter {
                        (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
                        && !$0.lastPathComponent.hasPrefix("_")  // exclude system folders (_models etc.)
                    }
                    .map { $0.lastPathComponent }
                    .sorted(by: >)   // timestamp prefix sorts newest first
        recordings = dirs
        if let sel = selectedRecording, !dirs.contains(sel) { selectedRecording = nil }
    }

    /// Reveal the selected recording's folder (or the library) in Finder.
    func openSelectedInFinder() {
        let url: URL
        if let sel = selectedRecording {
            url = library().appendingPathComponent(sel, isDirectory: true)
        } else {
            url = library()
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func selectRecording(_ name: String?) {
        selectedRecording = name
        if let name = name {
            recordingName = suffix(of: name)
        } else {
            recordingName = ""
        }
        refreshTranscriptState()
    }

    /// Rename the selected (stopped) recording's folder, keeping its timestamp prefix.
    func renameSelected() {
        guard !isRecording, let sel = selectedRecording else { return }
        let ts = timestampPrefix(of: sel)
        let newName = folderName(timestamp: ts, name: recordingName)
        guard newName != sel else { return }
        let fm = FileManager.default
        let src = library().appendingPathComponent(sel, isDirectory: true)
        let dst = library().appendingPathComponent(newName, isDirectory: true)
        do {
            try fm.moveItem(at: src, to: dst)
            refreshRecordings()
            selectedRecording = newName
            statusMessage = "名前を変更しました"
        } catch {
            statusMessage = "名前変更に失敗: \(error.localizedDescription)"
        }
    }

    // name helpers ---------------------------------------------------------

    private func sanitize(_ s: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\:.\"'") .union(.newlines)
        return s.components(separatedBy: bad).joined(separator: "_")
                .trimmingCharacters(in: .whitespaces)
    }

    private func folderName(timestamp: String, name: String) -> String {
        let n = sanitize(name)
        return n.isEmpty ? timestamp : "\(timestamp) - \(n)"
    }

    private func timestampPrefix(of folder: String) -> String {
        if let r = folder.range(of: " - ") { return String(folder[..<r.lowerBound]) }
        return folder
    }

    private func suffix(of folder: String) -> String {
        if let r = folder.range(of: " - ") { return String(folder[r.upperBound...]) }
        return ""
    }

    // MARK: Control

    func startRecording() {
        guard !isRecording, !isStarting else {
            RecLog.shared.log("startRecording ignored (isRecording=\(isRecording), isStarting=\(isStarting))")
            return
        }
        isStarting = true
        statusMessage = ""
        lastFiles = []
        selectedRecording = nil
        Task { await self.startAsync() }
    }

    func stopRecording() {
        RecLog.shared.log("stopRecording: begin")
        teardown(reason: "user stop")
        var saved: [URL] = []
        saved += micWriter?.finish() ?? []
        saved += sysWriter?.finish() ?? []
        saved += mixWriter?.finish() ?? []
        micWriter = nil; sysWriter = nil; mixWriter = nil
        sysPump.ring.reset(); micPump.ring.reset()
        isRecording = false
        elapsed = 0
        startDate = nil
        lastFiles = saved

        // Apply the name typed during/before recording (rename timestamp folder).
        if let folder = activeRecordingFolder {
            let desired = folderName(timestamp: activeTimestamp, name: recordingName)
            if desired != folder.lastPathComponent {
                let dst = library().appendingPathComponent(desired, isDirectory: true)
                if (try? FileManager.default.moveItem(at: folder, to: dst)) != nil {
                    activeRecordingFolder = dst
                }
            }
            refreshRecordings()
            selectedRecording = activeRecordingFolder?.lastPathComponent
        }
        activeRecordingFolder = nil

        for u in saved {
            let sz = ((try? FileManager.default.attributesOfItem(atPath: u.path))?[.size] as? Int) ?? -1
            RecLog.shared.log("stopRecording: \(u.lastPathComponent) size=\(sz) bytes")
        }
        RecLog.shared.log("stopRecording: sys.push=\(sysPump.pushCount) mic.push=\(micPump.pushCount) files=\(saved.count)")
        statusMessage = saved.isEmpty
            ? "保存ファイルがありません（ログを確認してください）"
            : "保存しました（\(saved.count)ファイル）"
    }

    private func teardown(reason: String) {
        RecLog.shared.log("teardown: \(reason)")
        watchdogTimer?.invalidate(); watchdogTimer = nil
        timer?.invalidate(); timer = nil
        if let obs = engineConfigObserver {
            NotificationCenter.default.removeObserver(obs)
            engineConfigObserver = nil
        }
        mixer?.stop(); mixer = nil
        if let s = stream {
            s.stopCapture { err in
                if let err = err { RecLog.shared.log("teardown: stopCapture error: \(err.localizedDescription)") }
            }
        }
        stream = nil
        streamOutput = nil
        if micTapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            micTapInstalled = false
        }
        if engine.isRunning { engine.stop() }
    }

    private func startAsync() async {
        defer { isStarting = false }

        let lib = library()
        try? FileManager.default.createDirectory(at: lib, withIntermediateDirectories: true)
        RecLog.shared.configure(folder: lib)   // log file lives in the library root
        RecLog.shared.log("start: sys=\(captureSystemAudio) mic=\(captureMic) macOS=\(ProcessInfo.processInfo.operatingSystemVersionString)")

        // Screen-recording permission must exist BEFORE we start, otherwise the
        // first run records a silent/empty system track. If not granted, surface
        // the dialog and abort without creating an empty recording.
        if captureSystemAudio {
            if !CGPreflightScreenCaptureAccess() {
                RecLog.shared.log("start: screen-recording NOT granted -> request + open settings, aborting")
                _ = CGRequestScreenCaptureAccess()   // shows dialog only on the very first response
                openScreenRecordingSettings()
                needsScreenPermission = true
                statusMessage = "画面収録の許可が必要です。設定でSimpleRecをオンにし、アプリを再起動してください（または「システム音声」をオフに）"
                return
            }
            needsScreenPermission = false
            RecLog.shared.log("start: screen-recording preflight ok")
        }

        // Create a fresh recording folder under the library: timestamp prefix.
        let tsf = DateFormatter(); tsf.dateFormat = "yyyyMMdd_HHmmss"
        let timestamp = tsf.string(from: Date())
        let folder = lib.appendingPathComponent(timestamp, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        activeRecordingFolder = folder
        activeTimestamp = timestamp
        RecLog.shared.log("start: recording folder=\(folder.path)")

        if captureMic {
            let granted = await requestMicAccess()
            RecLog.shared.log("start: mic permission granted=\(granted)")
            if !granted {
                statusMessage = "マイクのアクセスが許可されていません（システム設定 > プライバシー > マイク）"
                captureMic = false
            }
        }

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channelCount,
            AVEncoderBitRateKey: Int(bitrate)
        ]
        func makeWriter(_ base: String) -> SegmentWriter {
            SegmentWriter(folder: folder, baseName: base, settings: settings,
                          sampleRate: sampleRate, bitrate: bitrate, maxBytes: maxBytes)
        }
        sysPump.resetCounters(); micPump.resetCounters()
        sysPump.ring.reset(); micPump.ring.reset()

        // Microphone via input-tap only (NO output node -> avoids the engine crash)
        if captureMic {
            do {
                try startMicCapture()
                RecLog.shared.log("mic: engine started ok")
            } catch {
                RecLog.shared.log("mic: engine FAILED: \(error.localizedDescription)")
                captureMic = false
                if micTapInstalled { engine.inputNode.removeTap(onBus: 0); micTapInstalled = false }
                if engine.isRunning { engine.stop() }
            }
        }

        // System audio via ScreenCaptureKit
        if captureSystemAudio {
            do {
                try await startSystemAudioCapture()
                RecLog.shared.log("scstream: startCapture ok")
            } catch {
                RecLog.shared.log("scstream: startCapture FAILED: \(error.localizedDescription)")
                statusMessage = "システム音声の取得に失敗（画面収録の許可が必要です）: \(error.localizedDescription)"
                captureSystemAudio = false
            }
        }

        guard captureSystemAudio || captureMic else {
            teardown(reason: "no source available")
            return
        }

        // Build the three track writers now that we know which sources are live.
        let mixW = makeWriter("mix")
        let micW = captureMic ? makeWriter("mic") : nil
        let sysW = captureSystemAudio ? makeWriter("system") : nil
        mixWriter = mixW; micWriter = micW; sysWriter = sysW

        let mx = Mixer(format: procFormat,
                       sysRing: captureSystemAudio ? sysPump.ring : nil,
                       micRing: captureMic ? micPump.ring : nil,
                       mixWriter: mixW, micWriter: micW, sysWriter: sysW)
        mixer = mx
        mx.start()

        startDate = Date()
        isRecording = true
        statusMessage = "録音中…"
        RecLog.shared.log("recording: started")
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self = self, let s = self.startDate else { return }
                self.elapsed = Date().timeIntervalSince(s)
            }
        }
        // Watchdog: detect if mixer stops producing data while isRecording is true
        mixerWriteCountAtLastCheck = 0
        watchdogTimer = Timer.scheduledTimer(withTimeInterval: 20.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self = self, self.isRecording else { return }
                let current = self.mixWriter?.writeCount ?? 0
                if current == self.mixerWriteCountAtLastCheck {
                    RecLog.shared.log("watchdog: mixer stalled at writeCount=\(current), stopping")
                    self.unexpectedStop(reason: "録音データの書き込みが停止しました")
                }
                self.mixerWriteCountAtLastCheck = current
            }
        }
    }

    // MARK: Mic capture (input tap, no graph connections)

    private func startMicCapture() throws {
        if engine.isRunning { engine.stop() }
        if micTapInstalled { engine.inputNode.removeTap(onBus: 0); micTapInstalled = false }

        let input = engine.inputNode
        let micFormat = input.outputFormat(forBus: 0)
        RecLog.shared.log("mic: inputFormat=\(micFormat)")
        guard micFormat.sampleRate > 0, micFormat.channelCount > 0 else {
            throw NSError(domain: "SimpleRec", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "マイク入力フォーマットが無効です"])
        }
        let pump = micPump
        RecLog.shared.log("mic: installing tap…")
        input.installTap(onBus: 0, bufferSize: 4096, format: micFormat) { buffer, _ in
            pump.pushPCM(buffer)
        }
        micTapInstalled = true
        RecLog.shared.log("mic: preparing engine…")
        engine.prepare()
        RecLog.shared.log("mic: calling engine.start()…")
        try engine.start()
        RecLog.shared.log("mic: engine.start() returned")

        // When Zoom (or any app) exits and changes audio routing, macOS automatically
        // stops the engine. Catch this to tear down cleanly instead of crashing.
        engineConfigObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self] _ in
            RecLog.shared.log("engine: AVAudioEngineConfigurationChange — audio route changed")
            Task { @MainActor in
                guard let self = self, self.isRecording else { return }
                self.unexpectedStop(reason: "音声デバイスの設定が変更されました（Zoom終了等）")
            }
        }
    }

    // MARK: System audio capture

    private func startSystemAudioCapture() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first else {
            throw NSError(domain: "SimpleRec", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "ディスプレイが見つかりません"])
        }
        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = Int(sampleRate)
        config.channelCount = Int(channelCount)
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)

        let pump = sysPump
        let output = StreamOutput { sampleBuffer in pump.push(sampleBuffer) }
        output.onError = { [weak self] error in
            Task { @MainActor in
                guard let self = self, self.isRecording else { return }
                self.unexpectedStop(reason: "システム音声エラー: \(error.localizedDescription)")
            }
        }
        streamOutput = output

        let stream = SCStream(filter: filter, configuration: config, delegate: output)
        try stream.addStreamOutput(output, type: .audio,
                                   sampleHandlerQueue: DispatchQueue(label: "simplerec.audio"))
        try await stream.startCapture()
        self.stream = stream
    }

    // MARK: Permissions

    private func requestMicAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined:
            return await withCheckedContinuation { cont in
                AVCaptureDevice.requestAccess(for: .audio) { cont.resume(returning: $0) }
            }
        default: return false
        }
    }
}

// MARK: - SCStream output handler + delegate

private final class StreamOutput: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let onAudio: (CMSampleBuffer) -> Void
    var onError: ((Error) -> Void)?

    init(onAudio: @escaping (CMSampleBuffer) -> Void) { self.onAudio = onAudio }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid else { return }
        onAudio(sampleBuffer)
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        RecLog.shared.log("scstream: didStopWithError: \(error.localizedDescription)")
        onError?(error)
    }
}

// MARK: - Zoom Meeting Monitor

final class ZoomMonitor: @unchecked Sendable {
    var onMeetingStart: (() -> Void)?
    var onMeetingEnd: (() -> Void)?

    private let queue = DispatchQueue(label: "simplerec.zoommonitor", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var wasMeetingActive = false

    func start() {
        queue.async { [weak self] in
            guard let self, self.timer == nil else { return }
            let t = DispatchSource.makeTimerSource(queue: self.queue)
            t.schedule(deadline: .now() + 1, repeating: 5)
            t.setEventHandler { [weak self] in self?.check() }
            self.timer = t
            t.resume()
            RecLog.shared.log("zoomMonitor: started (polling every 5s)")
        }
    }

    func stop() {
        queue.async { [weak self] in
            self?.timer?.cancel()
            self?.timer = nil
            self?.wasMeetingActive = false
            RecLog.shared.log("zoomMonitor: stopped")
        }
    }

    private func check() {
        let active = isMeetingActive()
        if active && !wasMeetingActive {
            wasMeetingActive = true
            RecLog.shared.log("zoomMonitor: meeting STARTED")
            let cb = onMeetingStart
            DispatchQueue.main.async { cb?() }
        } else if !active && wasMeetingActive {
            wasMeetingActive = false
            RecLog.shared.log("zoomMonitor: meeting ENDED")
            let cb = onMeetingEnd
            DispatchQueue.main.async { cb?() }
        }
    }

    private func isMeetingActive() -> Bool {
        // Fast check: Zoom app must be running
        let zoomRunning = NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier == "us.zoom.xos"
        }
        guard zoomRunning else { return false }

        // CptHost is the audio/video subprocess that only runs during a Zoom meeting
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        task.arguments = ["-x", "CptHost"]
        task.standardOutput = Pipe()
        task.standardError = Pipe()
        do {
            try task.run()
            task.waitUntilExit()
            return task.terminationStatus == 0
        } catch {
            return false
        }
    }
}

// MARK: - CMSampleBuffer -> AVAudioPCMBuffer

extension CMSampleBuffer {
    func toPCMBuffer() -> AVAudioPCMBuffer? {
        guard let fmtDesc = CMSampleBufferGetFormatDescription(self),
              let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(fmtDesc) else { return nil }
        var asbd = asbdPtr.pointee
        guard let format = AVAudioFormat(streamDescription: &asbd) else { return nil }
        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(self))
        guard frames > 0,
              let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        pcm.frameLength = frames
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            self, at: 0, frameCount: Int32(frames), into: pcm.mutableAudioBufferList)
        return status == noErr ? pcm : nil
    }
}
