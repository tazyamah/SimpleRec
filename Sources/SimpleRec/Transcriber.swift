import Foundation
import WhisperKit

// ============================================================================
//  All WhisperKit-specific code lives in this file. If the WhisperKit API
//  differs in your installed version, this is the ONLY file you need to adjust.
// ============================================================================

struct SegmentInfo {
    let start: Double   // seconds from the start of the audio file passed to transcribe()
    let end: Double
    let text: String
}

actor Transcriber {
    private var whisper: WhisperKit?
    private let modelsDir: URL
    private let modelName: String

    init(modelsDir: URL, modelName: String) {
        self.modelsDir = modelsDir
        self.modelName = modelName
    }

    /// Marker file we control, so "is the model ready?" doesn't depend on
    /// WhisperKit's internal folder naming. Written after a successful load.
    private static func markerURL(modelsDir: URL, modelName: String) -> URL {
        modelsDir.appendingPathComponent(".ready_\(modelName)")
    }

    nonisolated static func isModelReady(modelsDir: URL, modelName: String) -> Bool {
        FileManager.default.fileExists(atPath: markerURL(modelsDir: modelsDir, modelName: modelName).path)
    }

    /// Load (and download on first use) the model into modelsDir.
    func ensureLoaded() async throws {
        if whisper != nil { return }
        try FileManager.default.createDirectory(at: modelsDir, withIntermediateDirectories: true)
        RecLog.shared.log("whisper: loading model=\(modelName) into \(modelsDir.path)")

        // downloadBase = parent dir; WhisperKit creates the model subfolder inside it.
        // Do NOT pass modelFolder here — that skips download entirely (setupModels L.314).
        let wk = try await WhisperKit(
            model: modelName,
            downloadBase: modelsDir,
            download: true
        )
        whisper = wk

        // Mark ready so the UI can hide the download button next launch.
        let marker = Self.markerURL(modelsDir: modelsDir, modelName: modelName)
        FileManager.default.createFile(atPath: marker.path, contents: Data())
        RecLog.shared.log("whisper: model ready")
    }

    /// Transcribe one audio file (m4a is supported directly).
    /// Returns the concatenated text and all segments with timestamps relative to the file start.
    func transcribe(_ audioURL: URL) async throws -> (text: String, segments: [SegmentInfo]) {
        try await ensureLoaded()
        guard let wk = whisper else {
            throw NSError(domain: "SimpleRec", code: 10,
                          userInfo: [NSLocalizedDescriptionKey: "モデルが読み込まれていません"])
        }
        RecLog.shared.log("whisper: transcribe \(audioURL.lastPathComponent)")
        let options = DecodingOptions(language: "ja", skipSpecialTokens: true)
        let results = try await wk.transcribe(audioPath: audioURL.path, decodeOptions: options)
        let text = results.map { $0.text }.joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let segments = results.flatMap { $0.segments }.map {
            SegmentInfo(start: Double($0.start), end: Double($0.end), text: $0.text)
        }
        RecLog.shared.log("whisper: done (\(text.count) chars, \(segments.count) segments)")
        return (text: text, segments: segments)
    }
}
