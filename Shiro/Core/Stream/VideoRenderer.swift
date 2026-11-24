import AVFoundation
import CoreMedia
import VideoToolbox

/// Turns chiaki-ng's Annex-B access units into CMSampleBuffers and pushes them
/// straight into hardware-decoding AVSampleBufferDisplayLayers marked
/// "display immediately" — the lowest-latency path on iOS. HEVC Main10 / PQ
/// streams are shown in HDR (EDR) on capable panels and external displays.
final class VideoRenderer {
    struct Stats {
        var framesReceived: Int = 0
        var framesLost: Int = 0
        var decodeErrors: Int = 0
        var width: Int32 = 0
        var height: Int32 = 0
        var fps: Double = 0
        var hdr = false
    }

    let hevc: Bool
    let hdr: Bool

    /// Called (on the chiaki video thread) when the decoder needs a fresh keyframe.
    var requestKeyframe: (() -> Void)?
    var onFirstFrame: (() -> Void)?

    private let lock = NSLock()
    private var layers: [ObjectIdentifier: AVSampleBufferDisplayLayer] = [:]
    private var formatDescription: CMVideoFormatDescription?
    private var parameterSetKey = Data()
    private var stats = Stats()
    private var fpsWindowStart = CACurrentMediaTime()
    private var fpsWindowFrames = 0
    private var firstFrameDelivered = false

    init(codec: ChiakiCodec) {
        hevc = chiaki_codec_is_h265(codec)
        hdr = chiaki_codec_is_hdr(codec)
        stats.hdr = hdr
    }

    var currentStats: Stats {
        lock.lock(); defer { lock.unlock() }
        return stats
    }

    func attach(_ layer: AVSampleBufferDisplayLayer) {
        lock.lock()
        layers[ObjectIdentifier(layer)] = layer
        lock.unlock()
        // A newly attached layer can only start decoding from a keyframe.
        requestKeyframe?()
    }

    func detach(_ layer: AVSampleBufferDisplayLayer) {
        lock.lock()
        layers.removeValue(forKey: ObjectIdentifier(layer))
        lock.unlock()
        layer.sampleBufferRenderer.flush(removingDisplayedImage: true, completionHandler: nil)
    }

    /// chiaki video sample callback. Returning false makes chiaki request a keyframe.
    func handle(_ buf: UnsafeMutablePointer<UInt8>, size: Int, framesLost: Int32, recovered: Bool) -> Bool {
        var info = ShiroFrameInfo()
        var outLen = 0
        guard let data = shiro_annexb_to_lp(buf, size, hevc, &outLen, &info) else { return true }

        lock.lock()
        stats.framesReceived += 1
        stats.framesLost += Int(max(0, framesLost))
        fpsWindowFrames += 1
        let now = CACurrentMediaTime()
        if now - fpsWindowStart >= 1 {
            stats.fps = Double(fpsWindowFrames) / (now - fpsWindowStart)
            fpsWindowFrames = 0
            fpsWindowStart = now
        }
        lock.unlock()

        if info.sps != nil, info.pps != nil, (!hevc || info.vps != nil) {
            updateFormatDescription(info)
        }
        guard let format = formatDescription else {
            free(data)
            return false
        }

        var block: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: data, blockLength: outLen,
            blockAllocator: kCFAllocatorMalloc, customBlockSource: nil,
            offsetToData: 0, dataLength: outLen, flags: 0, blockBufferOut: &block)
        guard status == kCMBlockBufferNoErr, let blockBuffer = block else {
            free(data)
            return false
        }

        var sample: CMSampleBuffer?
        var timing = CMSampleTimingInfo(duration: .invalid,
                                        presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
                                        decodeTimeStamp: .invalid)
        var sampleSize = outLen
        status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: blockBuffer, formatDescription: format,
            sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: &sampleSize, sampleBufferOut: &sample)
        guard status == noErr, let sampleBuffer = sample else { return false }

        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict,
                                 Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
            if !info.is_keyframe {
                CFDictionarySetValue(dict,
                                     Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque(),
                                     Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
            }
        }

        lock.lock()
        let targets = Array(layers.values)
        lock.unlock()

        var ok = true
        for layer in targets {
            let renderer = layer.sampleBufferRenderer
            if renderer.status == .failed {
                ShiroLog.shared.warn("Video decoder failed: \(renderer.error?.localizedDescription ?? "unknown"), recovering")
                renderer.flush()
                lock.lock(); stats.decodeErrors += 1; lock.unlock()
                ok = false
                continue
            }
            renderer.enqueue(sampleBuffer)
        }

        if !firstFrameDelivered && !targets.isEmpty {
            firstFrameDelivered = true
            onFirstFrame?()
        }
        return ok
    }

    private func updateFormatDescription(_ info: ShiroFrameInfo) {
        var key = Data()
        if let v = info.vps { key.append(v, count: info.vps_len) }
        if let s = info.sps { key.append(s, count: info.sps_len) }
        if let p = info.pps { key.append(p, count: info.pps_len) }
        guard key != parameterSetKey else { return }

        var desc: CMFormatDescription?
        var status: OSStatus
        if hevc {
            guard let vps = info.vps, let sps = info.sps, let pps = info.pps else { return }
            let ptrs: [UnsafePointer<UInt8>] = [vps, sps, pps]
            let sizes: [Int] = [info.vps_len, info.sps_len, info.pps_len]
            var ext: [CFString: Any] = [:]
            if hdr {
                ext[kCMFormatDescriptionExtension_ColorPrimaries] = kCMFormatDescriptionColorPrimaries_ITU_R_2020
                ext[kCMFormatDescriptionExtension_TransferFunction] = kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ
                ext[kCMFormatDescriptionExtension_YCbCrMatrix] = kCMFormatDescriptionYCbCrMatrix_ITU_R_2020
            }
            status = ptrs.withUnsafeBufferPointer { p in
                sizes.withUnsafeBufferPointer { s in
                    CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                        allocator: kCFAllocatorDefault, parameterSetCount: 3,
                        parameterSetPointers: p.baseAddress!, parameterSetSizes: s.baseAddress!,
                        nalUnitHeaderLength: 4, extensions: ext.isEmpty ? nil : (ext as CFDictionary),
                        formatDescriptionOut: &desc)
                }
            }
        } else {
            guard let sps = info.sps, let pps = info.pps else { return }
            let ptrs: [UnsafePointer<UInt8>] = [sps, pps]
            let sizes: [Int] = [info.sps_len, info.pps_len]
            status = ptrs.withUnsafeBufferPointer { p in
                sizes.withUnsafeBufferPointer { s in
                    CMVideoFormatDescriptionCreateFromH264ParameterSets(
                        allocator: kCFAllocatorDefault, parameterSetCount: 2,
                        parameterSetPointers: p.baseAddress!, parameterSetSizes: s.baseAddress!,
                        nalUnitHeaderLength: 4, formatDescriptionOut: &desc)
                }
            }
        }
        guard status == noErr, let d = desc else {
            ShiroLog.shared.error("Failed to create video format description (\(status))")
            return
        }
        parameterSetKey = key
        formatDescription = d
        let dims = CMVideoFormatDescriptionGetDimensions(d)
        lock.lock()
        stats.width = dims.width
        stats.height = dims.height
        lock.unlock()
        ShiroLog.shared.info("Video format: \(hevc ? "HEVC" : "H.264")\(hdr ? " HDR" : "") \(dims.width)x\(dims.height)")
    }

    func reset() {
        lock.lock()
        let targets = Array(layers.values)
        lock.unlock()
        for l in targets { l.sampleBufferRenderer.flush(removingDisplayedImage: false, completionHandler: nil) }
    }
}
