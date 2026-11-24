import Foundation
import UIKit
import Combine

/// How to reach the console for this session.
enum ConnectRoute: Equatable {
    /// Local network (or VPN / manually forwarded address).
    case local(address: String)
    /// Internet Remote Play through PSN UDP hole punching.
    case psn(duid: String)
}

struct ConnectRequest {
    var console: RegisteredConsole?
    var route: ConnectRoute
    var isPS5: Bool
    var nickname: String
    /// PIN-less registration through PSN (console must be linked to the PSN account).
    var autoRegister: Bool = false
    var autoRegisterAddress: String?
}

enum StreamPhase: Equatable {
    case idle
    case waking
    case connecting(String)
    case streaming
    case ended(String?)
}

/// One Remote Play session: owns the chiaki session and wires video, audio,
/// microphone, haptics and controller input together.
@MainActor
final class StreamSession: ObservableObject {
    @Published private(set) var phase: StreamPhase = .idle
    @Published private(set) var pinRequest: Bool? = nil   // nil = none, value = was incorrect
    @Published private(set) var keyboardText: String? = nil
    @Published private(set) var micActive = false
    @Published private(set) var serverNickname: String?
    @Published private(set) var stats = StreamStats()

    nonisolated let request: ConnectRequest
    let codec: ChiakiCodec
    let resolution: StreamResolution
    let bitrate: Int
    let fps: Int
    nonisolated(unsafe) let video: VideoRenderer
    nonisolated(unsafe) let audio = AudioRenderer()

    private var session: UnsafeMutablePointer<ChiakiSession>?
    private var opusDecoder: UnsafeMutablePointer<ChiakiOpusDecoder>?
    private var opusEncoder: UnsafeMutablePointer<ChiakiOpusEncoder>?
    private var mic: MicrophoneCapture?
    private var micConnected = false
    private var statsTimer: Timer?
    private var selfRef: Unmanaged<StreamSession>?
    private var stopping = false
    private let settings = AppSettings.shared

    nonisolated var isPS5: Bool { request.isPS5 }

    /// Mirrors `session` / `phase == .streaming` for lock-free use from input threads.
    nonisolated(unsafe) private var rawSession: UnsafeMutablePointer<ChiakiSession>?
    nonisolated(unsafe) private var isStreaming = false

    init(request: ConnectRequest) {
        self.request = request
        let s = AppSettings.shared
        let isLocal: Bool
        if case .local(let a) = request.route { isLocal = NetworkInterfaces.isLocal(a) } else { isLocal = false }
        resolution = isLocal ? s.localResolution : s.remoteResolution
        bitrate = isLocal ? s.localBitrate : s.remoteBitrate
        fps = s.fps60 ? 60 : 30
        codec = StreamSession.chooseCodec(setting: s.codec, ps5: request.isPS5)
        video = VideoRenderer(codec: codec)
    }

    static func chooseCodec(setting: StreamCodec, ps5: Bool) -> ChiakiCodec {
        guard ps5 else { return CHIAKI_CODEC_H264 } // PS4 streams are H.264 only
        switch setting {
        case .h264: return CHIAKI_CODEC_H264
        case .hevc: return CHIAKI_CODEC_H265
        case .hevcHDR: return CHIAKI_CODEC_H265_HDR
        case .auto: return DisplayManager.shared.anyDisplaySupportsHDR ? CHIAKI_CODEC_H265_HDR : CHIAKI_CODEC_H265
        }
    }

    // MARK: Lifecycle

    func start() {
        guard phase == .idle else { return }
        ChiakiLib.initialize()
        AudioRenderer.configureSession(microphone: false)
        UIApplication.shared.isIdleTimerDisabled = true
        audio.targetLatencyMs = settings.audioBufferMs

        Task { await connect() }
    }

    private func connect() async {
        // Wake the console first when it is asleep on the local network.
        if case .local(let address) = request.route, let console = request.console {
            let state = ConsoleStore.shared.discovered[console.id]?.state
            if state == .standby || state == nil {
                if state == .standby { phase = .waking }
                DiscoveryService.wake(console, address: address)
                if state == .standby {
                    for _ in 0..<60 {
                        try? await Task.sleep(nanoseconds: 500_000_000)
                        if ConsoleStore.shared.discovered[console.id]?.state == .ready { break }
                        if stopping { return }
                    }
                }
            }
        }

        switch request.route {
        case .local(let address):
            phase = .connecting("Connecting to \(request.nickname)…")
            initSession(host: address, holepunch: nil)
        case .psn(let duid):
            phase = .connecting(request.autoRegister ? "Registering with PSN…" : "Reaching \(request.nickname) over the internet…")
            guard let duidData = Data(hex: duid) else { fail("Invalid console id"); return }
            let token: String
            do { token = try await PSNAuth.shared.validAccessToken() } catch { fail(error.localizedDescription); return }
            let ps5 = request.isPS5
            let result: (ChiakiHolepunchSession?, ChiakiErrorCode) = await Task.detached(priority: .userInitiated) {
                guard let hp = token.withCString({ chiaki_holepunch_session_init($0, ShiroLog.shared.pointer) }) else {
                    return (nil, CHIAKI_ERR_MEMORY)
                }
                let err = duidData.withUnsafeBytes { raw in
                    shiro_psn_connect(hp, raw.bindMemory(to: UInt8.self).baseAddress, duidData.count, ps5)
                }
                if err != CHIAKI_ERR_SUCCESS {
                    chiaki_holepunch_session_fini(hp)
                    return (nil, err)
                }
                return (hp, err)
            }.value
            if stopping {
                if let hp = result.0 { chiaki_holepunch_session_fini(hp) }
                return
            }
            guard let hp = result.0 else {
                switch result.1 {
                case CHIAKI_ERR_HOST_DOWN: fail("The console is off or not connected to PSN. Enable “Stay connected to the Internet” in its Rest Mode settings.")
                case CHIAKI_ERR_HOST_UNREACH: fail("Couldn't reach the console through your network (strict NAT). Try another network or enable UPnP on your router.")
                default: fail("Internet connection failed: \(result.1.message)")
                }
                return
            }
            phase = .connecting("Linking with \(request.nickname)…")
            initSession(host: request.autoRegisterAddress ?? "", holepunch: hp)
        }
    }

    private func initSession(host: String, holepunch: ChiakiHolepunchSession?) {
        let s = UnsafeMutablePointer<ChiakiSession>.allocate(capacity: 1)
        let size = resolution.size
        let accountId = PSNAuth.shared.credentials?.accountId
        let console = request.console
        var params = ShiroConnectParams()
        params.ps5 = request.isPS5
        params.width = size.width
        params.height = size.height
        params.max_fps = UInt32(fps)
        params.bitrate = UInt32(bitrate)
        params.codec = codec
        params.enable_dualsense = settings.dualSenseFeatures
        params.auto_regist = request.autoRegister
        params.holepunch_session = holepunch
        params.packet_loss_max = settings.packetLossMax
        params.enable_idr_on_fec_failure = true

        let registKey = holepunch == nil ? console?.registKey : nil
        let morning = holepunch == nil ? console?.rpKey : nil
        let err: ChiakiErrorCode = host.withCString { hostPtr in
            params.host = hostPtr
            return (registKey ?? Data()).withFixedBytes(count: 16) { rk in
                (morning ?? Data()).withFixedBytes(count: 16) { mo in
                    (accountId ?? Data()).withFixedBytes(count: 8) { acc in
                        params.regist_key = registKey == nil ? nil : rk
                        params.morning = morning == nil ? nil : mo
                        params.psn_account_id = accountId == nil ? nil : acc
                        return shiro_session_init(s, &params, ShiroLog.shared.pointer)
                    }
                }
            }
        }
        guard err == CHIAKI_ERR_SUCCESS else {
            s.deallocate()
            if let hp = holepunch { chiaki_holepunch_session_fini(hp) }
            fail("Could not start the session: \(err.message)")
            return
        }
        session = s
        rawSession = s
        let ref = Unmanaged.passRetained(self)
        selfRef = ref
        let user = ref.toOpaque()

        // Video
        chiaki_session_set_video_sample_cb(s, { buf, size, lost, recovered, user in
            guard let buf = buf, let user = user else { return false }
            let me = Unmanaged<StreamSession>.fromOpaque(user).takeUnretainedValue()
            return me.video.handle(buf, size: Int(size), framesLost: lost, recovered: recovered)
        }, user)
        video.requestKeyframe = { [weak self] in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.requestKeyframe() } }
        }

        // Audio (Opus → PCM)
        let dec = UnsafeMutablePointer<ChiakiOpusDecoder>.allocate(capacity: 1)
        chiaki_opus_decoder_init(dec, ShiroLog.shared.pointer)
        chiaki_opus_decoder_set_cb(dec, { channels, rate, user in
            guard let user = user else { return }
            let me = Unmanaged<StreamSession>.fromOpaque(user).takeUnretainedValue()
            me.audio.configure(channels: Int(channels), rate: Int(rate))
        }, { pcm, frames, user in
            guard let pcm = pcm, let user = user else { return }
            let me = Unmanaged<StreamSession>.fromOpaque(user).takeUnretainedValue()
            me.audio.push(pcm, frames: Int(frames))
        }, user)
        var sink = ChiakiAudioSink()
        chiaki_opus_decoder_get_sink(dec, &sink)
        chiaki_session_set_audio_sink(s, &sink)
        opusDecoder = dec

        // DualSense haptics arrive as a 3 kHz audio stream; turn its envelope into rumble.
        if settings.dualSenseFeatures {
            var hsink = ChiakiAudioSink()
            hsink.user = user
            hsink.frame_cb = { buf, size, user in
                guard let buf = buf, let user = user else { return }
                let me = Unmanaged<StreamSession>.fromOpaque(user).takeUnretainedValue()
                me.handleHaptics(buf, size: Int(size))
            }
            chiaki_session_set_haptics_sink(s, &hsink)
        }

        // Microphone (Opus encoder → console)
        let enc = UnsafeMutablePointer<ChiakiOpusEncoder>.allocate(capacity: 1)
        chiaki_opus_encoder_init(enc, ShiroLog.shared.pointer)
        var header = ChiakiAudioHeader()
        chiaki_audio_header_set(&header, 2, 16, 48_000, 480)
        chiaki_opus_encoder_header(&header, enc, s)
        opusEncoder = enc

        chiaki_session_set_event_cb(s, { event, user in
            guard let event = event, let user = user else { return }
            var e = ShiroEvent()
            shiro_event_flatten(event, &e)
            var host: ShiroRegisteredHost?
            if let h = e.registered_host {
                var out = ShiroRegisteredHost()
                shiro_registered_host_flatten(h, &out)
                host = out
            }
            let keyboard = e.keyboard_text.map { String(cString: $0) }
            let quitReason = e.quit_reason_str.map { String(cString: $0) }
            var triggerL = [UInt8](repeating: 0, count: 10)
            var triggerR = [UInt8](repeating: 0, count: 10)
            if let l = e.trigger_left { for i in 0..<10 { triggerL[i] = l[i] } }
            if let r = e.trigger_right { for i in 0..<10 { triggerR[i] = r[i] } }
            let me = Unmanaged<StreamSession>.fromOpaque(user).takeUnretainedValue()
            // Latency-critical feedback goes straight to the controllers.
            switch e.type {
            case CHIAKI_EVENT_RUMBLE:
                InputManager.shared.rumble(left: e.rumble_left, right: e.rumble_right)
                return
            case CHIAKI_EVENT_TRIGGER_EFFECTS:
                InputManager.shared.setTriggerEffects(typeLeft: e.trigger_type_left, left: triggerL,
                                                      typeRight: e.trigger_type_right, right: triggerR)
                return
            default: break
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    me.handle(event: e, host: host, keyboard: keyboard, quitReason: quitReason)
                }
            }
        }, user)

        let startErr = chiaki_session_start(s)
        if startErr != CHIAKI_ERR_SUCCESS {
            fail("Session start failed: \(startErr.message)")
            teardown()
            return
        }
        InputManager.shared.attach(self)
        statsTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshStats() }
        }
    }

    private func handle(event e: ShiroEvent, host: ShiroRegisteredHost?, keyboard: String?, quitReason: String?) {
        switch e.type {
        case CHIAKI_EVENT_CONNECTED:
            phase = .streaming
            isStreaming = true
            ShiroLog.shared.info("Connected: \(resolution.label)@\(fps) \(String(cString: chiaki_codec_name(codec))) \(bitrate) kbps")
        case CHIAKI_EVENT_QUIT:
            let reason = e.quit_reason
            if chiaki_quit_reason_is_error(reason) {
                var msg = String(cString: chiaki_quit_reason_string(reason))
                if let q = quitReason, !q.isEmpty { msg += " — \(q)" }
                fail(msg)
            } else {
                end(nil)
            }
        case CHIAKI_EVENT_LOGIN_PIN_REQUEST:
            pinRequest = e.login_pin_incorrect
        case CHIAKI_EVENT_REGIST:
            if let h = host {
                var duid: String?
                if case .psn(let d) = request.route { duid = d }
                ConsoleStore.shared.addRegistered(h, address: request.autoRegisterAddress, psnDuid: duid)
            }
        case CHIAKI_EVENT_HOLEPUNCH:
            if case .connecting = phase {
                phase = .connecting(e.holepunch_finished ? "Starting stream…" : "Opening data channel…")
            }
        case CHIAKI_EVENT_NICKNAME_RECEIVED:
            serverNickname = stringFromCTuple(e.nickname)
        case CHIAKI_EVENT_KEYBOARD_OPEN:
            keyboardText = keyboard ?? ""
        case CHIAKI_EVENT_KEYBOARD_TEXT_CHANGE:
            if keyboardText != nil { keyboardText = keyboard ?? "" }
        case CHIAKI_EVENT_KEYBOARD_REMOTE_CLOSE:
            keyboardText = nil
        case CHIAKI_EVENT_LED_COLOR:
            InputManager.shared.setLight(r: e.led_r, g: e.led_g, b: e.led_b)
        case CHIAKI_EVENT_PLAYER_INDEX:
            InputManager.shared.setConsolePlayerIndex(Int(e.player_index))
        case CHIAKI_EVENT_HAPTIC_INTENSITY:
            InputManager.shared.setHapticIntensity(level: e.haptic_intensity)
        case CHIAKI_EVENT_TRIGGER_INTENSITY:
            InputManager.shared.setTriggerIntensity(level: e.haptic_intensity)
        case CHIAKI_EVENT_MOTION_RESET:
            InputManager.shared.resetMotion()
        default:
            break
        }
    }

    private nonisolated func handleHaptics(_ buf: UnsafeMutablePointer<UInt8>, size: Int) {
        let samples = size / 4 // stereo S16
        guard samples > 0 else { return }
        var peakL: Int32 = 0, peakR: Int32 = 0
        buf.withMemoryRebound(to: Int16.self, capacity: samples * 2) { p in
            for i in 0..<samples {
                peakL = max(peakL, abs(Int32(p[i * 2])))
                peakR = max(peakR, abs(Int32(p[i * 2 + 1])))
            }
        }
        InputManager.shared.hapticsEnvelope(left: Float(peakL) / 32767, right: Float(peakR) / 32767)
    }

    // MARK: Controls

    nonisolated func setControllerState(_ state: inout ChiakiControllerState) {
        guard isStreaming, let s = rawSession else { return }
        chiaki_session_set_controller_state(s, &state)
    }

    func requestKeyframe() {
        guard let s = session else { return }
        _ = chiaki_session_request_idr(s)
    }

    func submitPin(_ pin: String) {
        guard let s = session else { return }
        pinRequest = nil
        let bytes = Array(pin.utf8)
        bytes.withUnsafeBufferPointer { _ = chiaki_session_set_login_pin(s, $0.baseAddress, bytes.count) }
    }

    func submitKeyboard(text: String, accept: Bool) {
        guard let s = session else { return }
        _ = text.withCString { chiaki_session_keyboard_set_text(s, $0) }
        _ = accept ? chiaki_session_keyboard_accept(s) : chiaki_session_keyboard_reject(s)
        keyboardText = nil
    }

    func goHome() {
        guard let s = session else { return }
        _ = chiaki_session_go_home(s)
    }

    func toggleMicrophone() {
        guard let s = session, let enc = opusEncoder else { return }
        if micActive {
            mic?.stop()
            _ = chiaki_session_toggle_microphone(s, true)
            micActive = false
            AudioRenderer.configureSession(microphone: false)
            return
        }
        MicrophoneCapture.requestPermission { granted in
            Task { @MainActor in
                guard granted else { ShiroLog.shared.warn("Microphone permission denied"); return }
                AudioRenderer.configureSession(microphone: true)
                if !self.micConnected {
                    _ = chiaki_session_connect_microphone(s)
                    self.micConnected = true
                }
                _ = chiaki_session_toggle_microphone(s, false)
                let capture = MicrophoneCapture { pcm in
                    pcm.withUnsafeBufferPointer { buf in
                        chiaki_opus_encoder_frame(UnsafeMutablePointer(mutating: buf.baseAddress), enc)
                    }
                }
                capture.start()
                self.mic = capture
                self.micActive = true
            }
        }
    }

    // MARK: Stats

    private func refreshStats() {
        guard let s = session else { return }
        let v = video.currentStats
        var st = StreamStats()
        st.width = Int(v.width)
        st.height = Int(v.height)
        st.fps = v.fps
        st.framesLost = v.framesLost
        st.decodeErrors = v.decodeErrors
        st.hdr = v.hdr
        st.codec = String(cString: chiaki_codec_name(codec))
        st.measuredMbps = s.pointee.stream_connection.measured_bitrate
        st.rttMs = Double(s.pointee.rtt_us) / 1000
        st.audioBufferMs = audio.bufferedMs
        st.audioUnderruns = audio.underruns
        st.requestedKbps = bitrate
        st.isInternet = { if case .psn = request.route { return true }; return false }()
        stats = st
    }

    // MARK: Teardown

    func stop(sleepConsole: Bool = false) {
        guard !stopping else { return }
        stopping = true
        if let s = session {
            if sleepConsole { _ = chiaki_session_goto_bed(s) }
            _ = chiaki_session_stop(s)
        }
        end(nil)
    }

    private func fail(_ message: String) {
        ShiroLog.shared.error(message)
        end(message)
    }

    private func end(_ error: String?) {
        if case .ended = phase { return }
        phase = .ended(error)
        teardown()
    }

    private func teardown() {
        statsTimer?.invalidate()
        statsTimer = nil
        mic?.stop()
        mic = nil
        micActive = false
        isStreaming = false
        rawSession = nil
        InputManager.shared.detach(self)
        UIApplication.shared.isIdleTimerDisabled = false
        let s = session
        let dec = opusDecoder
        let enc = opusEncoder
        let ref = selfRef
        session = nil
        opusDecoder = nil
        opusEncoder = nil
        selfRef = nil
        let audio = self.audio
        DispatchQueue.global(qos: .userInitiated).async {
            if let s = s {
                _ = chiaki_session_stop(s)
                _ = chiaki_session_join(s)
                chiaki_session_fini(s)
                s.deallocate()
            }
            if let dec = dec { chiaki_opus_decoder_fini(dec); dec.deallocate() }
            if let enc = enc { chiaki_opus_encoder_fini(enc); enc.deallocate() }
            DispatchQueue.main.async {
                audio.stop()
                ref?.release()
            }
        }
    }
}

struct StreamStats: Equatable {
    var width = 0
    var height = 0
    var fps: Double = 0
    var framesLost = 0
    var decodeErrors = 0
    var hdr = false
    var codec = ""
    var measuredMbps: Double = 0
    var rttMs: Double = 0
    var audioBufferMs: Double = 0
    var audioUnderruns = 0
    var requestedKbps = 0
    var isInternet = false
}
