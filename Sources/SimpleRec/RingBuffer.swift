import Foundation
import AVFoundation

/// Simple multi-channel float ring buffer.
/// Written from the SCStream audio callback queue, read from the
/// AVAudioSourceNode render thread. Guarded by an unfair lock.
final class RingBuffer: @unchecked Sendable {
    private let capacity: Int
    private let channels: Int
    private var data: [[Float]]      // [channel][capacity]
    private var readIndex = 0
    private var writeIndex = 0
    private var available = 0
    private var lock = os_unfair_lock()

    init(capacityFrames: Int, channels: Int) {
        self.capacity = capacityFrames
        self.channels = channels
        self.data = Array(repeating: Array(repeating: 0, count: capacityFrames), count: channels)
    }

    /// src is [channel][frame]. If src has fewer channels than the buffer,
    /// channel 0 is duplicated; extra channels are ignored.
    func write(_ src: [[Float]], frames: Int) {
        guard frames > 0, !src.isEmpty else { return }
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }

        for i in 0..<frames {
            let w = (writeIndex + i) % capacity
            for ch in 0..<channels {
                let srcCh = ch < src.count ? ch : 0
                data[ch][w] = (i < src[srcCh].count) ? src[srcCh][i] : 0
            }
        }
        writeIndex = (writeIndex + frames) % capacity
        available += frames
        if available > capacity {                 // overflow: drop oldest
            let overflow = available - capacity
            readIndex = (readIndex + overflow) % capacity
            available = capacity
        }
    }

    /// Reads up to `frames` into the AudioBufferList. Returns frames actually read.
    func read(into abl: UnsafeMutableAudioBufferListPointer, frames: Int) -> Int {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }

        let toRead = min(frames, available)
        guard toRead > 0 else { return 0 }

        for (idx, buf) in abl.enumerated() {
            guard idx < channels,
                  let ptr = buf.mData?.assumingMemoryBound(to: Float.self) else { continue }
            for i in 0..<toRead {
                ptr[i] = data[idx][(readIndex + i) % capacity]
            }
        }
        readIndex = (readIndex + toRead) % capacity
        available -= toRead
        return toRead
    }

    func reset() {
        os_unfair_lock_lock(&lock)
        readIndex = 0; writeIndex = 0; available = 0
        os_unfair_lock_unlock(&lock)
    }

    /// Convenience: read up to `maxFrames` into a PCM buffer's channel data.
    /// Returns frames actually read (caller should pre-zero for zero-fill).
    func read(into pcm: AVAudioPCMBuffer, maxFrames: Int) -> Int {
        let abl = UnsafeMutableAudioBufferListPointer(pcm.mutableAudioBufferList)
        return read(into: abl, frames: maxFrames)
    }
}
