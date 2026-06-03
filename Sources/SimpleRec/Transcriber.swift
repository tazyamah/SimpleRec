import Foundation
import AVFoundation
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

    // RMS below this is considered silence (AAC noise floor ≈ 0.001, speech ≫ 0.01).
    private static let silenceRMSThreshold: Float = 0.004

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

        // Pre-scan the file to find the range that actually contains audio.
        // WhisperKit 1.0.0 does not compute noSpeechProb (always 0), so segment-level
        // RMS alone can be fooled when a hallucination segment extends into real speech.
        let range = speechRange(url: audioURL)
        RecLog.shared.log("whisper: speech range \(range.map { String(format: "%.1f-%.1fs", $0.start, $0.end) } ?? "unknown")")

        let options = DecodingOptions(language: "ja", skipSpecialTokens: true)
        let results = try await wk.transcribe(audioPath: audioURL.path, decodeOptions: options)
        let allSegments = results.flatMap { $0.segments }

        // Log every raw segment so thresholds can be tuned if needed.
        for seg in allSegments {
            RecLog.shared.log("whisper: raw [\(String(format:"%.1f",seg.start))-\(String(format:"%.1f",seg.end))s] \"\(seg.text.prefix(40))\"")
        }

        let validSegments = allSegments.filter { seg in
            let segStart  = Double(seg.start)
            let segEnd    = Double(seg.end)
            let duration  = segEnd - segStart
            let midpoint  = (segStart + segEnd) / 2.0
            let chars     = Double(seg.text.trimmingCharacters(in: .whitespaces).count)
            let fmt       = { (t: Double) in String(format: "%.1f", t) }
            let label     = "[\(fmt(segStart))-\(fmt(segEnd))s]"

            // Check 1 — low speech density on a long segment.
            // Whisper hallucinates on non-speech audio (music, tones, Zoom test sound)
            // by generating a short phrase with an abnormally wide timestamp.
            // Real Japanese speech: >= 1 char/sec. Hallucinations: typically < 1 char/sec.
            // Only apply to segments longer than 10s to avoid penalising natural pauses.
            if duration > 10.0 && chars / duration < 1.0 {
                RecLog.shared.log("whisper: drop low-density \(label) \(String(format:"%.2f",chars/duration))c/s \"\(seg.text.prefix(30))\"")
                return false
            }

            // Check 2 — midpoint outside the file's speech range.
            // Catches silence-only hallucinations at the leading/trailing edges whose
            // wide timestamps don't trigger Check 1 (e.g. a short phrase at the end).
            if let r = range, midpoint < r.start || midpoint > r.end {
                RecLog.shared.log("whisper: drop out-of-range \(label) mid=\(fmt(midpoint)) \"\(seg.text.prefix(30))\"")
                return false
            }

            return true
        }

        let text = validSegments.map { $0.text }.joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let segments = validSegments.map {
            SegmentInfo(start: Double($0.start), end: Double($0.end), text: $0.text)
        }
        RecLog.shared.log("whisper: done (\(text.count) chars, \(validSegments.count)/\(allSegments.count) segments kept)")
        return (text: text, segments: segments)
    }

    // MARK: - Audio helpers

    // Scan the file in 1-second windows and return the time range that contains
    // audio above the silence threshold. Returns nil if the file is all silent.
    private func speechRange(url: URL) -> (start: Double, end: Double)? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let sr = file.processingFormat.sampleRate
        let totalSec = Double(file.length) / sr
        var speechStart: Double? = nil
        var speechEnd: Double? = nil
        var t = 0.0
        while t < totalSec {
            let rms = audioRMS(url: url, from: t, to: min(t + 1.0, totalSec))
            if rms >= Self.silenceRMSThreshold {
                if speechStart == nil { speechStart = t }
                speechEnd = t + 1.0
            }
            t += 1.0
        }
        guard let s = speechStart, let e = speechEnd else { return nil }
        // Add a small buffer so segments right at the edge aren't cut.
        return (start: max(0, s - 0.5), end: min(totalSec, e + 0.5))
    }

    // Compute RMS energy for [startSec, endSec]. Returns 1.0 on any error so
    // callers err on the side of keeping segments when the file is unreadable.
    private func audioRMS(url: URL, from startSec: Double, to endSec: Double) -> Float {
        guard endSec > startSec,
              let file = try? AVAudioFile(forReading: url) else { return 1.0 }
        let fmt = file.processingFormat
        let sr = fmt.sampleRate
        let channels = Int(fmt.channelCount)
        let startFrame = AVAudioFramePosition(startSec * sr)
        let frameCount = AVAudioFrameCount((endSec - startSec) * sr)
        guard frameCount > 0,
              let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frameCount) else { return 1.0 }
        do {
            file.framePosition = max(0, startFrame)
            try file.read(into: buf, frameCount: frameCount)
        } catch { return 1.0 }
        guard let ch = buf.floatChannelData, buf.frameLength > 0 else { return 1.0 }
        let n = Int(buf.frameLength)
        var sum: Float = 0
        for c in 0..<channels { let d = ch[c]; for i in 0..<n { sum += d[i]*d[i] } }
        return sqrt(sum / Float(n * max(1, channels)))
    }
}
