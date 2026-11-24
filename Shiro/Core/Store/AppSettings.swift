import Foundation
import Combine

enum StreamResolution: Int, CaseIterable, Identifiable, Codable {
    case p360 = 1, p540 = 2, p720 = 3, p1080 = 4
    var id: Int { rawValue }
    var label: String {
        switch self {
        case .p360: return "360p"
        case .p540: return "540p"
        case .p720: return "720p"
        case .p1080: return "1080p"
        }
    }
    var size: (width: UInt32, height: UInt32) {
        switch self {
        case .p360: return (640, 360)
        case .p540: return (960, 540)
        case .p720: return (1280, 720)
        case .p1080: return (1920, 1080)
        }
    }
    /// Bitrate (kbit/s) that gives the best picture the console will reliably sustain.
    var recommendedBitrate: Int {
        switch self {
        case .p360: return 3_000
        case .p540: return 8_000
        case .p720: return 15_000
        case .p1080: return 30_000
        }
    }
}

enum StreamCodec: String, CaseIterable, Identifiable, Codable {
    case auto, h264, hevc, hevcHDR
    var id: String { rawValue }
    var label: String {
        switch self {
        case .auto: return "Automatic"
        case .h264: return "H.264"
        case .hevc: return "HEVC"
        case .hevcHDR: return "HEVC HDR"
        }
    }
}

enum CoopMode: String, CaseIterable, Identifiable, Codable {
    /// Every connected controller drives the console at the same time.
    case merge
    /// Only the controller that most recently pressed a button drives the console.
    case handoff
    /// Only the first ("player 1") controller drives the console.
    case single
    var id: String { rawValue }
    var label: String {
        switch self {
        case .merge: return "Shared (all controllers)"
        case .handoff: return "Hand-off (last active)"
        case .single: return "Player 1 only"
        }
    }
}

enum VideoFill: String, CaseIterable, Identifiable, Codable {
    case fit, fill, stretch
    var id: String { rawValue }
    var label: String {
        switch self {
        case .fit: return "Fit"
        case .fill: return "Fill (crop)"
        case .stretch: return "Stretch"
        }
    }
}

/// User preferences, persisted in UserDefaults.
final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    private let d = UserDefaults.standard

    @Published var localResolution: StreamResolution { didSet { d.set(localResolution.rawValue, forKey: "localResolution") } }
    @Published var remoteResolution: StreamResolution { didSet { d.set(remoteResolution.rawValue, forKey: "remoteResolution") } }
    @Published var fps60: Bool { didSet { d.set(fps60, forKey: "fps60") } }
    @Published var localBitrate: Int { didSet { d.set(localBitrate, forKey: "localBitrate") } }
    @Published var remoteBitrate: Int { didSet { d.set(remoteBitrate, forKey: "remoteBitrate") } }
    @Published var codec: StreamCodec { didSet { d.set(codec.rawValue, forKey: "codec") } }
    @Published var audioBufferMs: Int { didSet { d.set(audioBufferMs, forKey: "audioBufferMs") } }
    @Published var coopMode: CoopMode { didSet { d.set(coopMode.rawValue, forKey: "coopMode") } }
    @Published var videoFill: VideoFill { didSet { d.set(videoFill.rawValue, forKey: "videoFill") } }
    @Published var ambientFill: Bool { didSet { d.set(ambientFill, forKey: "ambientFill") } }
    @Published var foldedSplit: Bool { didSet { d.set(foldedSplit, forKey: "foldedSplit") } }
    @Published var useExternalDisplay: Bool { didSet { d.set(useExternalDisplay, forKey: "useExternalDisplay") } }
    @Published var showStats: Bool { didSet { d.set(showStats, forKey: "showStats") } }
    @Published var touchControls: Bool { didSet { d.set(touchControls, forKey: "touchControls") } }
    @Published var touchControlsOpacity: Double { didSet { d.set(touchControlsOpacity, forKey: "touchControlsOpacity") } }
    @Published var dualSenseFeatures: Bool { didSet { d.set(dualSenseFeatures, forKey: "dualSenseFeatures") } }
    @Published var rumbleIntensity: Double { didSet { d.set(rumbleIntensity, forKey: "rumbleIntensity") } }
    @Published var motionControls: Bool { didSet { d.set(motionControls, forKey: "motionControls") } }
    @Published var swapCrossCircle: Bool { didSet { d.set(swapCrossCircle, forKey: "swapCrossCircle") } }
    @Published var sleepOnDisconnect: Bool { didSet { d.set(sleepOnDisconnect, forKey: "sleepOnDisconnect") } }
    @Published var verboseLogging: Bool {
        didSet { d.set(verboseLogging, forKey: "verboseLogging"); ShiroLog.shared.verbose = verboseLogging }
    }
    @Published var packetLossMax: Double { didSet { d.set(packetLossMax, forKey: "packetLossMax") } }

    private init() {
        d.register(defaults: [
            "localResolution": StreamResolution.p1080.rawValue,
            "remoteResolution": StreamResolution.p1080.rawValue,
            "fps60": true,
            "localBitrate": 30_000,
            "remoteBitrate": 15_000,
            "codec": StreamCodec.auto.rawValue,
            "audioBufferMs": 40,
            "coopMode": CoopMode.merge.rawValue,
            "videoFill": VideoFill.fit.rawValue,
            "ambientFill": true,
            "foldedSplit": true,
            "useExternalDisplay": true,
            "showStats": false,
            "touchControls": true,
            "touchControlsOpacity": 0.55,
            "dualSenseFeatures": true,
            "rumbleIntensity": 1.0,
            "motionControls": true,
            "swapCrossCircle": false,
            "sleepOnDisconnect": false,
            "verboseLogging": false,
            "packetLossMax": 0.05,
        ])
        localResolution = StreamResolution(rawValue: d.integer(forKey: "localResolution")) ?? .p1080
        remoteResolution = StreamResolution(rawValue: d.integer(forKey: "remoteResolution")) ?? .p1080
        fps60 = d.bool(forKey: "fps60")
        localBitrate = d.integer(forKey: "localBitrate")
        remoteBitrate = d.integer(forKey: "remoteBitrate")
        codec = StreamCodec(rawValue: d.string(forKey: "codec") ?? "") ?? .auto
        audioBufferMs = d.integer(forKey: "audioBufferMs")
        coopMode = CoopMode(rawValue: d.string(forKey: "coopMode") ?? "") ?? .merge
        videoFill = VideoFill(rawValue: d.string(forKey: "videoFill") ?? "") ?? .fit
        ambientFill = d.bool(forKey: "ambientFill")
        foldedSplit = d.bool(forKey: "foldedSplit")
        useExternalDisplay = d.bool(forKey: "useExternalDisplay")
        showStats = d.bool(forKey: "showStats")
        touchControls = d.bool(forKey: "touchControls")
        touchControlsOpacity = d.double(forKey: "touchControlsOpacity")
        dualSenseFeatures = d.bool(forKey: "dualSenseFeatures")
        rumbleIntensity = d.double(forKey: "rumbleIntensity")
        motionControls = d.bool(forKey: "motionControls")
        swapCrossCircle = d.bool(forKey: "swapCrossCircle")
        sleepOnDisconnect = d.bool(forKey: "sleepOnDisconnect")
        verboseLogging = d.bool(forKey: "verboseLogging")
        packetLossMax = d.double(forKey: "packetLossMax")
        ShiroLog.shared.verbose = verboseLogging
    }
}
