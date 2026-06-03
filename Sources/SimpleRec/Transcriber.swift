import Foundation
import WhisperKit

// ============================================================================
//  All WhisperKit-specific code lives in this file. If the WhisperKit API
//  differs in your installed version, this is the ONLY file you need to adjust.
// ============================================================================

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

        // NOTE: convenience initializer used by current WhisperKit (2026).
        // If your version differs, adjust here (e.g. use WhisperKitConfig).
        let wk = try await WhisperKit(
            model: modelName,
            modelFolder: modelsDir.path,
            download: true
        )
        whisper = wk

        // Mark ready so the UI can hide the download button next launch.
        let marker = Self.markerURL(modelsDir: modelsDir, modelName: modelName)
        FileManager.default.createFile(atPath: marker.path, contents: Data())
        RecLog.shared.log("whisper: model ready")
    }

    /// Transcribe one audio file (m4a is supported directly) -> plain text.
    func transcribe(_ audioURL: URL) async throws -> String {
        try await ensureLoaded()
        guard let wk = whisper else {
            throw NSError(domain: "SimpleRec", code: 10,
                          userInfo: [NSLocalizedDescriptionKey: "モデルが読み込まれていません"])
        }
        RecLog.shared.log("whisper: transcribe \(audioURL.lastPathComponent)")
        let results = try await wk.transcribe(audioPath: audioURL.path)
        // results: [TranscriptionResult]; concatenate the text of each.
        let text = results.map { $0.text }.joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        RecLog.shared.log("whisper: done (\(text.count) chars)")
        return text
    }
}
