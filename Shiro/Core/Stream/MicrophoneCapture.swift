import AVFoundation

/// Captures the microphone and delivers 10 ms frames of 48 kHz stereo S16
/// (480 frames) — exactly what chiaki's Opus encoder expects.
final class MicrophoneCapture {
    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private let onFrame: ([Int16]) -> Void
    private var pending: [Int16] = []
    private let frameSamples = 480 * 2
    private let outFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 48_000, channels: 2, interleaved: true)!

    init(onFrame: @escaping ([Int16]) -> Void) {
        self.onFrame = onFrame
    }

    static func requestPermission(_ completion: @escaping (Bool) -> Void) {
        AVAudioApplication.requestRecordPermission { completion($0) }
    }

    func start() {
        let input = engine.inputNode
        let inFormat = input.outputFormat(forBus: 0)
        guard inFormat.sampleRate > 0 else {
            ShiroLog.shared.warn("Microphone unavailable")
            return
        }
        converter = AVAudioConverter(from: inFormat, to: outFormat)
        input.installTap(onBus: 0, bufferSize: 480, format: inFormat) { [weak self] buffer, _ in
            self?.process(buffer)
        }
        do {
            try engine.start()
        } catch {
            ShiroLog.shared.error("Microphone start failed: \(error.localizedDescription)")
        }
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    private func process(_ buffer: AVAudioPCMBuffer) {
        guard let converter = converter else { return }
        let ratio = outFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else { return }
        var consumed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, let data = out.int16ChannelData else { return }
        let n = Int(out.frameLength) * 2
        pending.append(contentsOf: UnsafeBufferPointer(start: data[0], count: n))
        while pending.count >= frameSamples {
            let frame = Array(pending[0..<frameSamples])
            pending.removeFirst(frameSamples)
            onFrame(frame)
        }
    }
}
