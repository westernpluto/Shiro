import AVFoundation
import os

/// Plays the console's decoded PCM audio with a small, bounded jitter buffer.
///
/// Video is displayed the instant it is decoded, so A/V sync comes down to
/// keeping audio latency equally small and *constant*: we pre-roll to the
/// target buffer, and whenever network jitter lets the queue grow past twice
/// the target we drop the oldest audio, snapping back into sync instead of
/// drifting behind the picture.
final class AudioRenderer {
    private let engine = AVAudioEngine()
    private var source: AVAudioSourceNode?
    private var channels = 2
    private var sampleRate: Double = 48_000

    private let lock = UnfairLock()
    private var ring: [Int16] = []
    private var readIndex = 0
    private var writeIndex = 0
    private var count = 0
    private var priming = true
    private var targetFrames = 1920
    private(set) var underruns = 0
    private(set) var drops = 0

    var targetLatencyMs: Int = 40 {
        didSet { lock.withLock { targetFrames = Int(sampleRate * Double(targetLatencyMs) / 1000) } }
    }

    var isMuted = false

    func configure(channels: Int, rate: Int) {
        stop()
        self.channels = max(1, channels)
        self.sampleRate = Double(rate > 0 ? rate : 48_000)
        lock.withLock {
            ring = [Int16](repeating: 0, count: Int(sampleRate) * self.channels) // 1 s capacity
            readIndex = 0; writeIndex = 0; count = 0; priming = true
            targetFrames = Int(sampleRate * Double(targetLatencyMs) / 1000)
        }

        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                                         channels: AVAudioChannelCount(self.channels), interleaved: false) else { return }
        let node = AVAudioSourceNode(format: format) { [unowned self] _, _, frameCount, abl in
            self.render(frameCount: Int(frameCount), abl: abl)
            return noErr
        }
        source = node
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        engine.prepare()
        do {
            try engine.start()
            ShiroLog.shared.info("Audio: \(self.channels) ch @ \(Int(sampleRate)) Hz, target \(targetLatencyMs) ms, IO \(Int(AVAudioSession.sharedInstance().ioBufferDuration * 1000)) ms")
        } catch {
            ShiroLog.shared.error("Audio engine failed to start: \(error.localizedDescription)")
        }
    }

    func stop() {
        engine.stop()
        if let s = source {
            engine.detach(s)
            source = nil
        }
    }

    /// Called from chiaki's audio thread with interleaved S16 samples.
    func push(_ samples: UnsafePointer<Int16>, frames: Int) {
        let n = frames * channels
        lock.withLock {
            let cap = ring.count
            guard cap > 0 else { return }
            if count + n > cap { // overflow: drop oldest
                let drop = count + n - cap
                readIndex = (readIndex + drop) % cap
                count -= drop
            }
            ring.withUnsafeMutableBufferPointer { r in
                var src = 0
                var remaining = n
                while remaining > 0 {
                    let chunk = min(remaining, cap - writeIndex)
                    (r.baseAddress! + writeIndex).update(from: samples + src, count: chunk)
                    writeIndex = (writeIndex + chunk) % cap
                    src += chunk
                    remaining -= chunk
                }
            }
            count += n
            // Latency cap: never let audio fall behind the picture.
            let maxSamples = targetFrames * channels * 2
            if count > maxSamples {
                let drop = count - targetFrames * channels
                readIndex = (readIndex + drop) % cap
                count -= drop
                drops += 1
            }
        }
    }

    private func render(frameCount: Int, abl: UnsafeMutablePointer<AudioBufferList>) {
        let buffers = UnsafeMutableAudioBufferListPointer(abl)
        let ch = channels
        lock.withLock {
            let cap = ring.count
            let needed = frameCount * ch
            if priming {
                if count >= targetFrames * ch { priming = false }
            }
            if priming || count < needed || isMuted || cap == 0 {
                if !priming && count < needed && !isMuted {
                    underruns += 1
                    priming = true // re-prime after an underrun to absorb the jitter
                }
                for b in buffers { memset(b.mData, 0, Int(b.mDataByteSize)) }
                return
            }
            ring.withUnsafeBufferPointer { r in
                let base = r.baseAddress!
                for c in 0..<min(ch, buffers.count) {
                    guard let out = buffers[c].mData?.assumingMemoryBound(to: Float.self) else { continue }
                    var idx = (readIndex + c) % cap
                    for f in 0..<frameCount {
                        out[f] = Float(base[idx]) * (1.0 / 32768.0)
                        idx = (idx + ch) % cap
                    }
                }
            }
            readIndex = (readIndex + needed) % cap
            count -= needed
        }
    }

    var bufferedMs: Double {
        lock.withLock { Double(count / max(channels, 1)) / sampleRate * 1000 }
    }

    static func configureSession(microphone: Bool) {
        let s = AVAudioSession.sharedInstance()
        do {
            if microphone {
                try s.setCategory(.playAndRecord, mode: .voiceChat,
                                  options: [.defaultToSpeaker, .allowBluetooth, .allowBluetoothA2DP])
            } else {
                try s.setCategory(.playback, mode: .default, options: [])
            }
            try s.setPreferredSampleRate(48_000)
            try s.setPreferredIOBufferDuration(0.005)
            try s.setActive(true)
        } catch {
            ShiroLog.shared.warn("Audio session: \(error.localizedDescription)")
        }
    }
}
