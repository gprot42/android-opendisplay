// MacSender — captures a display, H.264-encodes it, streams it to the phone.
//
// Milestone 1 (mirror):  capture the main display.
// Milestone 2 (extend):  create a CGVirtualDisplay sized to the phone panel
//                        (announced by the phone in a "hello" message) and
//                        capture that — macOS gains a true second monitor.
//
// Pipeline:  ScreenCaptureKit -> VideoToolbox (H.264) -> framed TCP
// Roles: the PHONE listens, the MAC connects (required for usbmux/USB).
//
// Wire protocol, Mac -> phone:   [4-byte big-endian length][Annex B payload]
//   (keyframes prefixed with SPS+PPS, NALUs delimited by 00 00 00 01)
// Wire protocol, phone -> Mac:   [4-byte big-endian length][JSON message]
//   e.g. {"type":"hello","pixelsWide":2556,"pixelsHigh":1179,"scale":3}

import ScreenCaptureKit
import VideoToolbox
import Network
import CoreMedia
import AppKit

enum CaptureMode: String {
    case mirror   // main display (Milestone 1)
    case extend   // virtual display (Milestone 2)
}

/// Where system audio should be heard while streaming.
enum AudioOutput: String, CaseIterable {
    /// Stream Mac system audio to the device (default).
    case tablet
    /// Leave sound on the Mac only — do not send `AUD1` frames.
    case mac

    var label: String {
        switch self {
        case .tablet: return "Tablet"
        case .mac: return "This Mac"
        }
    }

    var explanation: String {
        switch self {
        case .tablet:
            return "Play Mac system audio on the device only (Mac volume lowered while connected)."
        case .mac:
            return "Keep music and system sound on this Mac only (speakers restored)."
        }
    }
}

/// Capture-resolution / bitrate trade-off. The virtual display always runs at
/// native size — only the captured/encoded stream is scaled, so lower presets
/// cut encode, transmit, and decode time at the cost of sharpness.
enum StreamQuality: String, CaseIterable {
    case best, balanced, fast

    var scale: Double {
        switch self {
        case .best: return 1.0
        case .balanced: return 0.75
        case .fast: return 0.5
        }
    }

    /// Baseline bitrate at ~1080p; [bitrate(forPixelsWide:pixelsHigh:)] scales up for larger frames.
    var bitrate: Int {
        switch self {
        case .best: return 24_000_000
        case .balanced: return 12_000_000
        case .fast: return 7_000_000
        }
    }

    /// Resolution-aware bitrate so 2.5K/3K streams stay sharp (base rates assume ~2 MP).
    func bitrate(forPixelsWide w: Int, pixelsHigh h: Int) -> Int {
        let mp = max(Double(w * h) / 1_000_000.0, 0.5)
        let scaled = Double(bitrate) * (mp / 2.0)
        // Floor at the preset base; cap so Wi‑Fi stays usable.
        return min(max(Int(scaled), bitrate), 50_000_000)
    }

    var label: String {
        switch self {
        case .best: return "Best (native)"
        case .balanced: return "Balanced (75%)"
        case .fast: return "Fast (50%)"
        }
    }

    var explanation: String {
        switch self {
        case .best: return "Full resolution + higher bitrate. Sharpest text; uses more Wi‑Fi bandwidth."
        case .balanced: return "75% capture resolution — lower latency, slight softness."
        case .fast: return "Half resolution — lowest latency and bandwidth, visibly softer. Good for congested WiFi."
        }
    }
}

struct PhoneInfo: Decodable {
    let pixelsWide: Int   // landscape-oriented (long edge)
    let pixelsHigh: Int
    let scale: Double
    let device: String?   // "iPad" / "iPhone" (older receivers omit it)
    let id: String?       // per-install identity (older receivers omit it) —
                          // lets the controller match the same physical device
                          // across USB and WiFi
    let pv: Int?          // receiver protocol version (issue #132); absent on
                          // every pre-handshake install → treat as protocol 1
    /// 1 when the receiver can play `AUD1` system-audio frames (protocol 3+).
    let audio: Int?

    var kind: String { device ?? "device" }
    var protocolVersion: Int { pv ?? WireProtocol.assumedWhenAbsent }
    var wantsAudio: Bool { (audio ?? 0) != 0 }
}

/// How the sender reaches the receiver. Reconnects re-dial from scratch, so
/// a USB device that was replugged (new usbmuxd DeviceID) is found again.
enum SenderTransport {
    /// TCP dial. Optional `localHost` pins the source IPv4 (used for Android
    /// USB tethering so traffic stays on the tether interface and never
    /// reconfigures or roams onto Wi‑Fi).
    case tcp(NWEndpoint, localHost: String? = nil)
    case usb(udid: String?, port: UInt16)  // native usbmuxd dial; nil = first device
}

@available(macOS 14.0, *)
final class MacSender: NSObject, SCStreamOutput, SCStreamDelegate {

    // Status surfaced to the UI (updated on main thread).
    @MainActor var onStatus: ((String) -> Void)?
    @MainActor var onStats: ((Int, Double) -> Void)?   // framesSent, mbps
    // Fired when a previously connected device stays gone past the grace
    // period — the controller ends the session (capture, virtual display,
    // recording indicator all torn down) instead of dialing forever or
    // silently coming back over a different transport.
    @MainActor var onDisconnected: (() -> Void)?
    // Fired when the receiver announces its device locked. The controller
    // ends this session — an invisible display strands the cursor — and
    // starts a fresh one that waits for the wake.
    @MainActor var onPeerSleeping: (() -> Void)?
    // Fired when the receiver announces the app is quitting: deliberate,
    // so the controller ends the session without arming a reconnect.
    @MainActor var onPeerClosed: (() -> Void)?
    // Fired on every hello — carries the receiver's install id so the
    // controller can deduplicate USB/WiFi sessions to the same device.
    @MainActor var onHello: ((PhoneInfo) -> Void)?

    private var stream: SCStream?
    private var encoder: VTCompressionSession?
    private var connection: NWConnection?
    private var virtualDisplay: VirtualDisplay?
    private let queue = DispatchQueue(label: "sender.video")
    private let audioQueue = DispatchQueue(label: "sender.audio")
    private let audioResampler = AudioResampler()
    // Peer advertised audio=1 on hello; only send when audioOutput == .tablet.
    private var peerWantsAudio = false
    /// Escape hatch: `defaults write … streamAudio -bool false` forces off.
    private let streamAudioAllowed = UserDefaults.standard.object(forKey: "streamAudio") == nil
        || UserDefaults.standard.bool(forKey: "streamAudio")
    private let audioOutput: AudioOutput
    /// Capture + send system audio to the peer (tablet speakers).
    private var streamAudioEnabled: Bool {
        streamAudioAllowed && audioOutput == .tablet
    }
    /// True while we hold a SystemAudioMute claim (Mac speakers silenced).
    private var holdingSpeakerMute = false
    private let startCode: [UInt8] = [0, 0, 0, 1]

    // The dial target. Written on `queue` only (after init): the controller
    // can migrate a live session between transports via switchTransport.
    private var transport: SenderTransport
    private let endpointName: String
    private let mode: CaptureMode
    private let quality: StreamQuality
    // Stable per-device serial for the virtual display, so macOS can tell
    // multiple OpenDisplay monitors apart and persist their arrangement.
    private let displaySerial: UInt32

    // ── Encoder parallelism limiter (maxPendingEncodes = 1) ─────────────────
    //
    // VTCompressionSessionEncodeFrame returns immediately; the hardware H.264
    // encoder runs asynchronously. If ScreenCaptureKit delivers the next frame
    // before the previous encode callback fires, VideoToolbox will run multiple
    // encodes in parallel inside the same session.
    //
    // Capping pendingEncodes at 1 enforces “latest frame wins” on the encoder:
    // skip captures while an encode is in flight (enc drops), then feed the next
    // fresh buffer when the callback clears the slot. The H.264 reference chain
    // stays valid (pre-encode skip → normal P-frame n→n+2); we do NOT force
    // keyframes on enc drops.
    private var pendingEncodes = 0
    private let maxPendingEncodes = 1

    // ── Outstanding send backpressure (maxPendingSends = 3) ──────────────────
    //
    // pendingSends counts video frames whose NWConnection.send completion has
    // not fired yet — i.e. bytes still in flight / waiting on TCP ACKs. Allow a
    // small pipeline (3) so the link is not idle between ACKs; unlike the encoder,
    // a few outstanding sends helps throughput without piling up seconds of lag.
    //
    // When pendingSends hits the cap we skip the capture before encode (net
    // drops). Same drop point as enc drops, but means “TCP send queue full”, not
    // “encoder busy” — split counters (enc↓ vs net↓) so the HUD shows which
    // bottleneck fired. Never encode-then-discard: dropping here avoids wasting
    // VT work on frames that would only add latency.
    private var pendingSends = 0
    private let maxPendingSends = 3
    private let pipelineLock = NSLock()
    private var dropsEncThisWindow = 0
    private var dropsNetThisWindow = 0
    private var dropsEncTotal = 0
    private var dropsNetTotal = 0
    private var needsKeyframe = true
    private var connectionReady = false
    private var stopped = false
    // The liveness monitors are self-rescheduling chains guarded only by
    // `stopped`; arm them at most once per instance so a double start() can't
    // stack parallel loops (the failure mode behind #75). Mirrors the
    // `monitorsStarted` guard the iOS PhoneReceiver already uses.
    private var monitorsStarted = false

    // Disconnect detection: before the first connection we dial patiently
    // (the user may start the Mac side first); once connected, a device that
    // stays gone past the grace ends the session via onDisconnected.
    private var everConnected = false
    private var disconnectedSince: Date?
    /// How long to keep the virtual display + retry TCP after a blip.
    /// Android USB / decoder hiccups often need >10s to come back.
    private let disconnectGraceSeconds: TimeInterval = 45

    private var lastHello: PhoneInfo?
    private var helloContinuation: CheckedContinuation<PhoneInfo, Error>?
    private var inputInjector: InputInjector?

    // Receiver pinch-zoom: crop capture to the visible rect and encode that
    // region at full stream resolution so zoom stays sharp. Normalized
    // top-left + size in video/display space; z is the pinch scale for bitrate.
    private var receiverZoom: Double = 1
    private var receiverViewport = CGRect(x: 0, y: 0, width: 1, height: 1) // normalized
    private var captureWidth = 0
    private var captureHeight = 0
    private var captureConfig: SCStreamConfiguration?
    private var lastViewportApply = Date.distantPast

    // Liveness: both sides ping every 2s; if nothing arrives for 5s the link
    // is half-open (e.g. usbmuxd accepted but the device is gone) — reconnect.
    private var lastReceived = Date()

    // Session created after the receiver went to sleep: it refuses
    // connections until its screen is back, so dial failures mean "asleep",
    // not "app closed" — surface that instead of the usual hints. Cleared by
    // the first successful connection.
    private var awaitingWake: Bool

    // Consecutive actively-refused dials on a previously connected session.
    // Refusal means nothing is listening — but Android app restarts and adb
    // forward flaps also refuse for a few seconds, so allow many retries
    // before giving up (still capped by disconnectGraceSeconds).
    private var consecutiveRefusals = 0
    private let refusalsBeforeGivingUp = 20
    private var dropsTotal: Int { dropsEncTotal + dropsNetTotal }

    // Local cursor echo: a cursor baked into the video carries the full
    // capture→encode→stream→display latency (~30ms perceived). Instead we
    // hide it from capture and stream its position on the control channel —
    // the phone draws it locally on the ~2ms path the touches use.
    // Escape hatch: `defaults write sh.peet.opensidecar.mac localCursor -bool false`.
    private let localCursor = UserDefaults.standard.object(forKey: "localCursor") == nil
        || UserDefaults.standard.bool(forKey: "localCursor")
    private var cursorTimer: DispatchSourceTimer?
    private var cursorImageTimer: DispatchSourceTimer?
    private var lastCursorSent: (x: Double, y: Double, visible: Bool) = (-1, -1, false)
    private var lastCursorPNGHash = 0
    private var captureDisplayID: CGDirectDisplayID = 0

    // Input latency: touches arrive stamped in our clock (the phone applies
    // its sync offset); delta to now = network + deframe + dispatch.
    private var inputLatencies: [Double] = []
    // Capture cadence: SCK only emits on content change, so the phone can't
    // tell "Mac rendered 45fps" from "frames got lost" — count deliveries here.
    private var capFrames = 0
    private var capWindowStart = Date()

    private var framesSent = 0
    private var bytesSent = 0
    private var statsWindowStart = Date()

    // ScreenCaptureKit emits frames only when content changes. After a
    // reconnect on a static screen there is nothing to hang the forced
    // keyframe on — so keep the last frame around and re-encode it.
    private var lastPixelBuffer: CVPixelBuffer?
    private var lastCaptureAt = Date.distantPast
    // After a burst of captures (window drag / resize) SCK goes quiet. The
    // tablet can freeze on a mid-move frame that still shows the window or
    // its title, and H.264 P-frames can leave residual macroblocks for up
    // to MaxKeyFrameInterval. When capture idles, force an IDR + underlay
    // nudge so the receiver settles on a clean desktop sample.
    private var idleFlushWorkItem: DispatchWorkItem?
    private var capturesSinceIdleFlush = 0
    private var lastIdleFlushAt = Date.distantPast

    init(transport: SenderTransport, name: String, mode: CaptureMode,
         quality: StreamQuality = .best, audioOutput: AudioOutput = .tablet,
         displaySerial: UInt32 = 0x0001, awaitingWake: Bool = false) {
        self.transport = transport
        self.endpointName = name
        self.mode = mode
        self.quality = quality
        self.audioOutput = audioOutput
        self.displaySerial = displaySerial
        self.awaitingWake = awaitingWake
        super.init()
    }

    // MARK: - Lifecycle

    func start() async throws {
        stopped = false
        queue.async { self.connect() }   // dial state lives on `queue`
        if !monitorsStarted {
            monitorsStarted = true
            schedulePing()
            scheduleWatchdog()
        }

        // Screen Recording is required for both mirror and extend. Prompt once
        // here (in addition to the Permissions panel) so a fresh debug build
        // that lost TCC after re-sign is not stuck "Connected" with fps=0.
        if !CGPreflightScreenCaptureAccess() {
            await status("Screen Recording needed — enable “OpenDisplay Dev” in System Settings → Privacy")
            Log.info("Screen Recording permission missing — requesting access + opening Settings")
            CGRequestScreenCaptureAccess()
            // Open Settings so the user can flip the toggle when the system
            // dialog never appears (common for debug/ad-hoc builds).
            await MainActor.run {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                    NSWorkspace.shared.open(url)
                }
            }
            var reminded = false
            while !CGPreflightScreenCaptureAccess() {
                try await Task.sleep(for: .seconds(1))
                if stopped { return }
                // Re-nudge once after a few seconds if still denied.
                if !reminded {
                    reminded = true
                    await status("Waiting for Screen Recording — System Settings → Privacy & Security → Screen Recording → OpenDisplay Dev")
                }
            }
            Log.info("Screen Recording permission granted")
        }

        switch mode {
        case .mirror:
            let content = try await SCShareableContent.current
            guard let display = content.displays.first else {
                throw NSError(domain: "MacSender", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "no displays found"])
            }
            // Capture at full Retina pixel size (not points) so mirror is sharp.
            // SCDisplay width/height are points; CGDisplayPixels* is the framebuffer.
            let (captureW, captureH) = Self.capturePixelSize(display: display, qualityScale: quality.scale)
            try await startCapture(display: display, pixelsWide: captureW, pixelsHigh: captureH)

        case .extend:
            // awaitingWake is queue-confined — read it there before surfacing.
            queue.async { [weak self] in
                guard let self else { return }
                let text = self.awaitingWake
                    ? "\(self.endpointName) is asleep — reconnects when it wakes…"
                    : "Waiting for the device to connect…"
                Task { await self.status(text) }
            }
            let info = try await waitForHello()
            try await setupExtend(info)

            // Touch back-channel (Milestone 3). Needs Accessibility trust;
            // streaming works without it, so don't interrupt with a prompt —
            // the permission panel's Grant button asks when the user is ready.
            if !AXIsProcessTrusted() {
                await status("Extending — grant Accessibility for touch input")
                // Event posting is trust-checked per-post, so it starts working
                // the moment the user grants — poll just to log/report it.
                while !AXIsProcessTrusted() {
                    try await Task.sleep(for: .seconds(2))
                    if stopped { return }
                }
                Log.info("Accessibility permission granted — touch input live")
            }
        }
    }

    /// Build (or rebuild) the virtual display + capture for the announced
    /// phone dimensions. Called at startup and again whenever the phone
    /// rotates (it re-sends hello with swapped dimensions).
    private func setupExtend(_ info: PhoneInfo) async throws {
        Log.info("phone hello: \(info.pixelsWide)x\(info.pixelsHigh) @\(info.scale)x")

        // Phone panel is @3x; the virtual display runs @2x HiDPI, so points
        // = native pixels / 2 (rounded down to even for the encoder).
        let pointsWide = (info.pixelsWide / 2) & ~1
        let pointsHigh = (info.pixelsHigh / 2) & ~1
        // Physical size drives macOS's PPI / "is this a TV?" heuristics.
        // Hard-coded phone mm made tablets look like tiny ultra-dense panels
        // and could confuse arrangement / window placement.
        let mm = Self.physicalSizeMillimeters(pixelsWide: info.pixelsWide,
                                              pixelsHigh: info.pixelsHigh)

        // USB sessions can start before lockdown resolves the device name —
        // fall back to the kind from the hello rather than the generic label.
        let displayName = endpointName.hasPrefix("iPhone / iPad")
            ? "OpenDisplay — \(info.kind)"
            : "OpenDisplay — \(endpointName)"
        // Orientation-specific serial: macOS persists the chosen mode per
        // serial, and a portrait mode restored onto a landscape display
        // pillarboxes the desktop INTO the framebuffer (streamed as-is).
        // Distinct serials per orientation keep the two configs apart.
        let serial = info.pixelsWide >= info.pixelsHigh
            ? displaySerial
            : displaySerial ^ 0x8000_0000
        // Arrangement memory (#116): keyed on the device's install id so the
        // display returns to its spot across transports and orientations —
        // the serial-keyed memory macOS keeps starts from scratch whenever
        // the serial changes. Old receivers without an id fall back to the
        // session serial, which is at least orientation-stable.
        let arrangementKey = info.id ?? String(format: "serial-%08x", displaySerial)
        let sizeInPoints = CGSize(width: pointsWide, height: pointsHigh)
        // Creating a display whose serial is still registered fails — e.g. a
        // just-quit instance's display lingers in WindowServer for a moment
        // after the process dies. Retry through that window instead of
        // parking the session on "Failed" until a manual reconnect.
        var vd: VirtualDisplay?
        for attempt in 0..<8 {
            if attempt > 0 { try await Task.sleep(for: .seconds(2)) }
            // A Disconnect during the retry window tore the session down. Bail
            // before creating/assigning the display: the serial the old display
            // held is likely free now, so a late attempt would *succeed* and
            // resurrect the very zombie this retry exists to avoid. (Mirrors the
            // `if stopped` checks in the permission-poll loops above.)
            if stopped { return }
            vd = await MainActor.run {
                let side = DisplayArrangement.preferredSide
                let origin = DisplayArrangement.origin(for: sizeInPoints, device: arrangementKey)
                return VirtualDisplay(name: displayName,
                                      pointsWide: pointsWide, pointsHigh: pointsHigh,
                                      sizeInMillimeters: mm, serialNum: serial,
                                      restoreOrigin: origin,
                                      preferredSide: side,
                                      onOriginChange: { origin in
                                          DisplayArrangement.save(origin: origin, size: sizeInPoints,
                                                                  device: arrangementKey)
                                      })
            }
            if vd != nil { break }
            Log.info("virtual display creation failed (attempt \(attempt + 1)) — retrying")
            await status("Preparing virtual display…")
        }
        guard let vd else {
            throw NSError(domain: "MacSender", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "CGVirtualDisplay creation failed"])
        }
        virtualDisplay = vd
        inputInjector = InputInjector(displayID: vd.displayID)

        // Solid desktop under the apps: private virtual displays often leave
        // unpainted residue (title bar / app name) when a window is dragged
        // off. Real pixels behind windows stop that ghosting.
        let underlayID = vd.displayID
        await MainActor.run {
            DesktopUnderlay.show(on: underlayID)
            // New displays often steal the pointer to the far left — keep the
            // Mac trackpad usable on the built-in screen immediately.
            WindowRecovery.warpPointerToMainDisplay()
        }

        let display = try await findSCDisplay(id: vd.displayID)
        // Quality scaling: capture/encode below native when requested — the
        // display itself stays native so window layout is unaffected.
        let captureW = (Int(Double(pointsWide * 2) * quality.scale)) & ~1
        let captureH = (Int(Double(pointsHigh * 2) * quality.scale)) & ~1
        try await startCapture(display: display, pixelsWide: captureW, pixelsHigh: captureH)

        // Debug aid (`defaults write sh.peet.opensidecar.mac testPattern -bool true`):
        // an animated window on the virtual display generates a constant frame
        // stream so steady-state latency can be measured without user activity.
        if UserDefaults.standard.bool(forKey: "testPattern") {
            let id = vd.displayID
            Task { @MainActor in TestPattern.show(on: id) }
        }
    }

    /// Tear down and rebuild when the phone announces new dimensions. Loops
    /// until the built display matches the latest hello, so rotations that
    /// arrive mid-rebuild aren't lost (and rapid flip-flops settle once).
    private var reconfiguring = false
    private func reconfigure(_ info: PhoneInfo) async {
        guard !reconfiguring, !stopped else { return }
        reconfiguring = true
        defer { reconfiguring = false }
        var target = info
        while !stopped {
            Log.info("reconfiguring for \(target.pixelsWide)x\(target.pixelsHigh)")
            if let stream { try? await stream.stopCapture() }
            stream = nil
            if let encoder { VTCompressionSessionInvalidate(encoder) }
            encoder = nil
            let oldID = captureDisplayID
            if oldID != 0 {
                await MainActor.run {
                    // Rotation rebuild: keep windows on the new panel when
                    // possible by translating; if that fails they still land
                    // on main rather than limbo.
                    _ = WindowRecovery.retrieveWindows(fromDisplay: oldID, includeOffScreen: true)
                    DesktopUnderlay.hide(on: oldID)
                    TestPattern.hide(on: oldID)
                }
            }
            virtualDisplay = nil   // removes the old display
            needsKeyframe = true
            do {
                try await setupExtend(target)
            } catch {
                Log.info("reconfigure failed: \(error)")
                await status("Rotation failed: \(error.localizedDescription)")
                return
            }
            if let latest = lastHello,
               latest.pixelsWide != target.pixelsWide || latest.pixelsHigh != target.pixelsHigh {
                target = latest   // rotated again while we were rebuilding
                continue
            }
            return
        }
    }

    /// The virtual display takes a moment to show up in shareable content.
    private func findSCDisplay(id: CGDirectDisplayID) async throws -> SCDisplay {
        for _ in 0..<20 {
            let content = try await SCShareableContent.current
            if let display = content.displays.first(where: { $0.displayID == id }) {
                return display
            }
            try await Task.sleep(for: .milliseconds(250))
        }
        throw NSError(domain: "MacSender", code: 3,
                      userInfo: [NSLocalizedDescriptionKey: "virtual display never appeared in SCShareableContent"])
    }

    private func startCapture(display: SCDisplay, pixelsWide: Int, pixelsHigh: Int) async throws {
        let filter = SCContentFilter(display: display, excludingWindows: [])

        let config = SCStreamConfiguration()
        config.width = pixelsWide
        config.height = pixelsHigh
        // Ask for 120 even though the virtual display is 60Hz: requesting
        // exactly 1/60 makes SCK's rate limiter skip frames that arrive a
        // hair early (beat frequency) — measured ~51fps instead of 60.
        config.minimumFrameInterval = CMTime(value: 1, timescale: 120)
        // 420v matches the encoder's native input — skips a BGRA→YUV conversion
        // inside VideoToolbox. (`-pixfmt bgra` reverts for A/B testing.)
        config.pixelFormat = UserDefaults.standard.string(forKey: "pixfmt") == "bgra"
            ? kCVPixelFormatType_32BGRA
            : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        // One buffer is held permanently (keyframe replay) and one sits in
        // the encoder for ~13ms — headroom prevents SCK starvation drops.
        config.queueDepth = 8
        config.showsCursor = !localCursor
        // Capture system audio whenever enabled; only *send* after hello
        // advertises audio=1 (so old receivers never see AUD1 frames).
        // Requires Screen Recording — no separate mic permission.
        peerWantsAudio = streamAudioEnabled && (lastHello?.wantsAudio == true)
        if streamAudioEnabled {
            config.capturesAudio = true
            config.sampleRate = 48_000
            config.channelCount = 2
        }
        applySourceRect(to: config, displayID: display.displayID)

        setupEncoder(width: pixelsWide, height: pixelsHigh)

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        if streamAudioEnabled {
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)
        }
        try await stream.startCapture()
        self.stream = stream
        self.captureConfig = config
        self.captureWidth = pixelsWide
        self.captureHeight = pixelsHigh
        captureDisplayID = display.displayID
        lastCursorPNGHash = 0      // rotation rebuilds: re-send the sprite
        lastCursorSent = (-1, -1, false)
        startCursorEcho()
        // Silence Mac speakers when routing system audio to the tablet so
        // Firefox / Music / etc. aren't doubled on both ends.
        updateSpeakerMute(active: peerWantsAudio && streamAudioEnabled)
        Log.info("capture started: \(pixelsWide)x\(pixelsHigh) display \(display.displayID) mode \(mode.rawValue) localCursor=\(localCursor) audioOut=\(audioOutput.rawValue) audioCap=\(streamAudioEnabled) audioSend=\(peerWantsAudio)")
        let kind = lastHello?.kind ?? "device"
        await status("\(mode == .extend ? "Extending to" : "Mirroring to") \(kind) (\(pixelsWide)×\(pixelsHigh))")
    }

    /// Mute/unmute the Mac default output for tablet-audio sessions.
    private func updateSpeakerMute(active: Bool) {
        if active, !holdingSpeakerMute {
            SystemAudioMute.claim()
            holdingSpeakerMute = true
        } else if !active, holdingSpeakerMute {
            SystemAudioMute.release()
            holdingSpeakerMute = false
        }
    }

    /// Map the receiver's normalized visible rect onto the capture display
    /// in points (ScreenCaptureKit `sourceRect` space).
    private func applySourceRect(to config: SCStreamConfiguration, displayID: CGDirectDisplayID) {
        let bounds = CGDisplayBounds(displayID)
        guard bounds.width > 1, bounds.height > 1 else {
            config.sourceRect = .null
            return
        }
        let vp = receiverViewport
        if receiverZoom <= 1.02 || (vp.width >= 0.98 && vp.height >= 0.98) {
            config.sourceRect = .null
            return
        }
        let nx = min(max(vp.origin.x, 0), 0.95)
        let ny = min(max(vp.origin.y, 0), 0.95)
        let nw = min(max(vp.width, 0.05), 1 - nx)
        let nh = min(max(vp.height, 0.05), 1 - ny)
        config.sourceRect = CGRect(
            x: bounds.minX + nx * bounds.width,
            y: bounds.minY + ny * bounds.height,
            width: nw * bounds.width,
            height: nh * bounds.height
        )
    }

    /// Receiver pinch-zoom: ROI-crop capture to the visible rect (encoded at
    /// full stream resolution → real pixels under the magnifier) and raise
    /// bitrate. The Android UI keeps a local View scale for instant feedback;
    /// that scale is modest so it does not fully double-zoom the ROI stream.
    private func handleReceiverViewport(x: Double, y: Double, w: Double, h: Double, z: Double) {
        let zoom = max(1.0, min(z, 5.0))
        let rect = CGRect(
            x: min(max(x, 0), 1),
            y: min(max(y, 0), 1),
            width: min(max(w, 0.05), 1),
            height: min(max(h, 0.05), 1)
        )
        let zoomChanged = abs(zoom - receiverZoom) > 0.03
        let rectChanged = abs(rect.origin.x - receiverViewport.origin.x) > 0.002
            || abs(rect.origin.y - receiverViewport.origin.y) > 0.002
            || abs(rect.width - receiverViewport.width) > 0.002
            || abs(rect.height - receiverViewport.height) > 0.002
        guard zoomChanged || rectChanged else { return }

        receiverZoom = zoom
        receiverViewport = rect

        let now = Date()
        if now.timeIntervalSince(lastViewportApply) < 0.04 {
            queue.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                self?.applyViewportToStream()
            }
            return
        }
        applyViewportToStream()
    }

    private func applyViewportToStream() {
        guard !stopped, let stream, let base = captureConfig, captureDisplayID != 0 else {
            applyZoomBitrate(forceKeyframe: true)
            return
        }
        lastViewportApply = Date()

        let config = SCStreamConfiguration()
        config.width = base.width
        config.height = base.height
        config.minimumFrameInterval = base.minimumFrameInterval
        config.pixelFormat = base.pixelFormat
        config.queueDepth = base.queueDepth
        config.showsCursor = base.showsCursor
        config.capturesAudio = base.capturesAudio
        config.sampleRate = base.sampleRate
        config.channelCount = base.channelCount
        applySourceRect(to: config, displayID: captureDisplayID)

        Task {
            do {
                try await stream.updateConfiguration(config)
                self.queue.async {
                    self.captureConfig = config
                    self.needsKeyframe = true
                    self.applyZoomBitrate(forceKeyframe: false)
                    Log.info(String(
                        format: "viewport zoom=%.2f crop=(%.2f,%.2f %.2f×%.2f) bitrate boost",
                        self.receiverZoom,
                        self.receiverViewport.origin.x, self.receiverViewport.origin.y,
                        self.receiverViewport.width, self.receiverViewport.height
                    ))
                }
            } catch {
                Log.info("viewport update failed: \(error.localizedDescription)")
                self.queue.async { self.applyZoomBitrate(forceKeyframe: true) }
            }
        }
    }

    /// Raise average bitrate with zoom so magnified regions keep detail.
    private func applyZoomBitrate(forceKeyframe: Bool = false) {
        guard let encoder else { return }
        let z = min(max(receiverZoom, 1), 4)
        let base = quality.bitrate(forPixelsWide: max(captureWidth, 1), pixelsHigh: max(captureHeight, 1))
        // Super-linear enough to fight upscale softness; hard-capped for Wi‑Fi.
        let factor = 1.0 + (z - 1.0) * 1.5
        let br = min(Int(Double(base) * factor), 50_000_000)
        VTSessionSetProperty(encoder, key: kVTCompressionPropertyKey_AverageBitRate, value: br as CFNumber)
        VTSessionSetProperty(
            encoder,
            key: kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality,
            value: z > 1.15 ? kCFBooleanFalse : kCFBooleanTrue
        )
        if forceKeyframe { needsKeyframe = true }
    }

    func stop() {
        stopped = true
        idleFlushWorkItem?.cancel()
        idleFlushWorkItem = nil
        cursorTimer?.cancel()
        cursorTimer = nil
        cursorImageTimer?.cancel()
        cursorImageTimer = nil
        updateSpeakerMute(active: false)
        inputInjector?.forceRelease()
        stream?.stopCapture { _ in }
        stream = nil
        connection?.cancel()
        connection = nil
        if let encoder { VTCompressionSessionInvalidate(encoder) }
        encoder = nil
        let oldID = captureDisplayID
        // Pull windows off the virtual panel *before* tearing it down —
        // otherwise they stay at absolute coords that no longer exist.
        // Never use main.sync here: if main is busy (cursor poll / AX), we
        // deadlock or freeze the UI. Async with a short wait + hard timeout.
        if oldID != 0 {
            let cleanup = { @MainActor in
                _ = WindowRecovery.retrieveWindows(fromDisplay: oldID, includeOffScreen: true)
                DesktopUnderlay.hide(on: oldID)
                TestPattern.hide(on: oldID)
            }
            if Thread.isMainThread {
                MainActor.assumeIsolated { cleanup() }
            } else {
                let sem = DispatchSemaphore(value: 0)
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { cleanup() }
                    sem.signal()
                }
                if sem.wait(timeout: .now() + 1.5) == .timedOut {
                    Log.info("stop: window recovery timed out — tearing down display anyway")
                }
            }
        }
        virtualDisplay = nil   // releasing it removes the display
        queue.async { [weak self] in
            // Unblock a start() that is still waiting for the hello.
            self?.helloContinuation?.resume(throwing: CancellationError())
            self?.helloContinuation = nil
        }
    }

    /// Move windows currently on this session’s virtual display (or stuck
    /// off-screen) back to the Mac main display.
    @MainActor
    @discardableResult
    func retrieveWindowsToMac() -> Int {
        releaseInjectedPointer()
        let id = virtualDisplay?.displayID ?? captureDisplayID
        let n = WindowRecovery.retrieveWindows(
            fromDisplay: id != 0 ? id : nil,
            includeOffScreen: true
        )
        if n > 0 {
            WindowRecovery.warpPointerToMainDisplay()
        }
        Task { await status(n == 0 ? "No windows to retrieve" : "Moved \(n) window(s) back to Mac") }
        return n
    }

    /// Clear a tablet-driven mouse-down (optionally restore the Mac cursor).
    /// No-op if the tablet is not currently capturing the pointer.
    /// `postEvents: false` clears state only — use while the settings panel is
    /// open so a synthetic mouse-up cannot cancel a real trackpad click.
    func releaseInjectedPointer(restoreCursor: Bool = true, postEvents: Bool = true) {
        inputInjector?.forceRelease(restoreCursor: restoreCursor, postEvents: postEvents)
    }

    /// Whether the tablet currently owns a synthetic mouse capture.
    var hasInjectedPointerCapture: Bool {
        inputInjector?.hasActiveCapture ?? false
    }

    /// Migrate the live session to another transport: swap the socket under
    /// the pipeline — virtual display, capture and encoder stay up (no
    /// display destroy/create, so no screen flash and no window reshuffle)
    /// while the connection redials over the new transport. The receiver
    /// treats it like any reconnect: the fresh connection replaces the old
    /// one and the video resyncs with a keyframe. Which transport to be on
    /// is the controller's call (cable-in upgrade, unplug failover).
    func switchTransport(to newTransport: SenderTransport) {
        queue.async { [weak self] in
            guard let self, !self.stopped else { return }
            let label = if case .usb = newTransport { "USB" } else { "WiFi" }
            Log.info("switching \(self.endpointName) to \(label)")
            self.transport = newTransport
            // Fresh grace window: if the new link can't come up either, the
            // session ends like any other disconnect instead of dialing
            // a dead transport forever.
            self.disconnectedSince = Date()
            self.connectionReady = false
            self.dialGeneration += 1   // a dial still in flight must not adopt
            if let previous = self.connection {
                previous.stateUpdateHandler = nil
                previous.cancel()
            }
            self.connection = nil
            self.pendingSends = 0
            self.pipelineLock.lock()
            self.pendingEncodes = 0
            self.pipelineLock.unlock()
            self.connect()
        }
    }

    // The controller's end() is idempotent, but several detectors (grace,
    // refusals, service withdrawal) can conclude "gone" repeatedly while the
    // stop is in flight — report once so the log tells the story once.
    private var goneReported = false

    /// Declare the device gone and end the session (must be called on `queue`).
    private func reportGone(_ reason: String) {
        guard !goneReported, !stopped else { return }
        goneReported = true
        Log.info(reason)
        Task { @MainActor in self.onDisconnected?() }
    }

    /// A dial was actively refused (must be called on `queue`). On a session
    /// that has streamed before, enough refusals in a row prove the receiver
    /// app is gone — end now instead of waiting out the grace.
    private func dialRefused() {
        guard everConnected, !stopped else { return }
        consecutiveRefusals += 1
        if consecutiveRefusals >= refusalsBeforeGivingUp {
            reportGone("dial refused \(consecutiveRefusals)x — receiver app is gone, ending session")
        }
    }

    /// The receiver's Bonjour advertisement disappeared (the system
    /// deregisters a dead app's service within ~1s, while a suspended app
    /// keeps it). Only meaningful once the connection is already down —
    /// a live connection outranks a flapping mDNS cache. Together they
    /// prove a WiFi receiver quit, where dials just stall instead of
    /// being refused.
    func peerServiceWithdrawn() {
        queue.async { [weak self] in
            guard let self, !self.stopped, self.everConnected,
                  !self.connectionReady else { return }
            self.reportGone("service withdrawn and connection down — receiver app is gone, ending session")
        }
    }

    /// Drop the current connection and dial again — fresh TCP through the
    /// tunnel, fresh accept on the phone. Bound to the UI Reconnect button.
    func forceReconnect() {
        queue.async { [weak self] in
            guard let self, !self.stopped else { return }
            Log.info("manual reconnect requested")
            self.disconnectedSince = Date()   // fresh grace window
            self.scheduleReconnect()
        }
    }

    /// True when extend mode has a live virtual display that can host windows.
    var canHostWindows: Bool {
        mode == .extend && virtualDisplay != nil
    }

    /// Move the frontmost app's focused window onto this session's virtual
    /// display. Useful when drag-to-edge is finicky (separate Spaces, Stage
    /// Manager, short shared edges). Requires Accessibility.
    @discardableResult
    @MainActor
    func moveFrontWindowToDisplay() -> Bool {
        guard mode == .extend, let vd = virtualDisplay else {
            Log.info("moveFrontWindow: no virtual display")
            return false
        }
        guard AXIsProcessTrusted() else {
            _ = InputInjector.ensureAccessibilityPermission()
            Log.info("moveFrontWindow: Accessibility required")
            Task { await status("Grant Accessibility, then use Send Window again") }
            return false
        }
        let bounds = CGDisplayBounds(vd.displayID)
        guard bounds.width > 1, bounds.height > 1 else { return false }

        guard let app = NSWorkspace.shared.frontmostApplication else {
            Log.info("moveFrontWindow: no frontmost app")
            return false
        }
        // Don't steal OpenDisplay's own window.
        if app.processIdentifier == ProcessInfo.processInfo.processIdentifier {
            Log.info("moveFrontWindow: frontmost is OpenDisplay — focus another app first")
            Task { await status("Click the app window you want, then Send Window") }
            return false
        }

        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var windowRef: CFTypeRef?
        let focusedErr = AXUIElementCopyAttributeValue(
            axApp, kAXFocusedWindowAttribute as CFString, &windowRef)
        if focusedErr != .success
            || windowRef == nil
            || CFGetTypeID(windowRef!) != AXUIElementGetTypeID() {
            // Fall back to main window.
            var mainRef: CFTypeRef?
            let mainErr = AXUIElementCopyAttributeValue(
                axApp, kAXMainWindowAttribute as CFString, &mainRef)
            guard mainErr == .success,
                  let mainRef,
                  CFGetTypeID(mainRef) == AXUIElementGetTypeID() else {
                Log.info("moveFrontWindow: no focused/main window for \(app.localizedName ?? "?")")
                return false
            }
            windowRef = mainRef
        }
        let window = windowRef as! AXUIElement

        // Leave a margin so the title bar stays draggable; size to ~90% of the
        // panel so the user immediately sees the app on the tablet.
        let margin: CGFloat = 24
        var pos = CGPoint(x: bounds.minX + margin, y: bounds.minY + margin)
        var size = CGSize(
            width: max(320, bounds.width - margin * 2),
            height: max(240, bounds.height - margin * 2)
        )
        guard let posVal = AXValueCreate(.cgPoint, &pos),
              let sizeVal = AXValueCreate(.cgSize, &size) else { return false }

        AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, posVal)
        AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeVal)
        Log.info("moveFrontWindow: \(app.localizedName ?? "app") → display \(vd.displayID) "
            + "(\(Int(bounds.minX)),\(Int(bounds.minY)) \(Int(size.width))x\(Int(size.height)))")
        Task { await status("Moved \(app.localizedName ?? "window") to the device") }
        return true
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        Log.info("stream stopped with error: \(error)")
        // Purple menu-bar / Control Center "Stop" (SCStreamErrorUserStopped
        // -3817). That is an intentional user action — do NOT rebuild the
        // pipeline, or the stop button looks broken and capture restarts.
        let ns = error as NSError
        let userStopped = ns.domain == SCStreamErrorDomain
            && ns.code == SCStreamError.userStopped.rawValue
        if userStopped {
            Log.info("user stopped screen capture from system UI — ending session")
            // Tear the TCP link immediately so the tablet leaves the frozen
            // desktop frame and returns to its waiting menu (don't wait for
            // the MainActor session teardown to cancel the connection).
            self.stream = nil
            self.connectionReady = false
            self.connection?.cancel()
            self.connection = nil
            Task { await status("Screen capture stopped") }
            Task { @MainActor in self.onPeerClosed?() }
            return
        }
        Task { await status("Capture stopped: \(error.localizedDescription)") }
        // E.g. display sleep can tear the virtual display down underneath the
        // stream — rebuild instead of sitting dead until an app restart.
        guard !stopped, mode == .extend else { return }
        self.stream = nil
        scheduleCaptureRecovery()
    }

    /// Retry until capture is back (a rebuild during display sleep can fail).
    private func scheduleCaptureRecovery() {
        queue.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            guard let self, !self.stopped, self.stream == nil,
                  let hello = self.lastHello else { return }
            Log.info("capture died — rebuilding pipeline")
            Task {
                await self.reconfigure(hello)
                self.queue.async {
                    if self.stream == nil { self.scheduleCaptureRecovery() }
                }
            }
        }
    }

    // MARK: - Connection (with retry)

    // Guards against a stale async USB dial adopting after a newer one (or a
    // manual reconnect) superseded it. Only touched on `queue`.
    private var dialGeneration = 0

    private func connect() {
        guard !stopped else { return }
        switch transport {
        case .tcp(let endpoint, let localHost): connectTCP(endpoint, localHost: localHost)
        case .usb(let udid, let port): connectUSB(udid: udid, port: port)
        }
    }

    /// Bookkeeping shared by both transports once a connection is live.
    private func becomeReady(_ conn: NWConnection) {
        // Ignore late `.ready` from a superseded dial.
        guard connection === conn else { return }
        // Network.framework can re-enter `.ready` after path updates; only
        // arm the receive loop once per connection.
        if connectionReady, connection === conn {
            lastReceived = Date()
            return
        }
        Log.info("connection ready to \(endpointName)")
        connectionReady = true
        everConnected = true
        awaitingWake = false
        consecutiveRefusals = 0
        disconnectedSince = nil
        needsKeyframe = true   // new peer needs SPS/PPS + IDR
        // A reconnect can recreate the phone's video view with no cursor
        // sprite; the sprite is otherwise only sent on shape change, so the
        // cursor would stay invisible until the user hovers something that
        // changes it. Reset the dedup state to re-send sprite + position to
        // the fresh peer — the cursor analogue of forcing a keyframe.
        lastCursorPNGHash = 0
        lastCursorSent = (-1, -1, false)
        lastReceived = Date()  // fresh grace period for the watchdog
        receiveControl(on: conn)
        Task { await self.status("Connected to \(self.endpointName)") }
    }

    /// Pixel dimensions for a capture of `display`, scaled by quality.
    private static func capturePixelSize(display: SCDisplay, qualityScale: Double) -> (Int, Int) {
        let pxW = CGDisplayPixelsWide(display.displayID)
        let pxH = CGDisplayPixelsHigh(display.displayID)
        // Fall back to points if CoreGraphics returns 0 (rare / headless).
        let w = pxW > 0 ? pxW : display.width
        let h = pxH > 0 ? pxH : display.height
        return ((Int(Double(w) * qualityScale) & ~1),
                (Int(Double(h) * qualityScale) & ~1))
    }

    /// Estimate panel size in millimeters from native pixels.
    /// Long-edge ≥ 2000 → tablet-class (~11"); otherwise phone-class (~6.1").
    private static func physicalSizeMillimeters(pixelsWide: Int, pixelsHigh: Int) -> CGSize {
        let longEdge = max(pixelsWide, pixelsHigh)
        let diagonalInches: Double = longEdge >= 2000 ? 11.0 : 6.1
        let diagPx = hypot(Double(pixelsWide), Double(pixelsHigh))
        guard diagPx > 0 else {
            return CGSize(width: 147, height: 68)
        }
        let mmPerPx = (diagonalInches * 25.4) / diagPx
        return CGSize(width: Double(pixelsWide) * mmPerPx,
                      height: Double(pixelsHigh) * mmPerPx)
    }

    private func connectTCP(_ endpoint: NWEndpoint, localHost: String? = nil) {
        let options = NWProtocolTCP.Options()
        options.noDelay = true   // latency matters more than throughput here
        options.enableKeepalive = true
        options.keepaliveIdle = 3
        options.keepaliveInterval = 1
        options.keepaliveCount = 3
        // Prefer a single path: multipath / Happy Eyeballs racing two
        // addresses (link-local + global IPv6) used to leave an orphan TCP
        // half-open on the receiver, which then "replaced" the live session
        // and thrashed both ends in a connect/RST loop.
        let params = NWParameters(tls: nil, tcp: options)
        params.allowLocalEndpointReuse = true
        params.multipathServiceType = .disabled
        // Prefer the faster local path; don't roam across expensive interfaces.
        params.serviceClass = .responsiveData
        // Android USB tether: bind source IP to the Mac’s address on the
        // RNDIS/NCM interface so the session never uses Wi‑Fi routes and we
        // never touch system routing/DNS (read-only discovery + user-space TCP).
        if let localHost, !localHost.isEmpty {
            params.requiredLocalEndpoint = NWEndpoint.hostPort(
                host: NWEndpoint.Host(localHost),
                port: 0)
            params.prohibitedInterfaceTypes = [.wifi, .cellular, .loopback]
            Log.info("TCP dial pinned to local \(localHost) (tether interface)")
        }

        // Always retire the previous dial before opening another — otherwise
        // its stateUpdateHandler can still fire `.failed` and schedule a
        // reconnect that cancels the connection that just became ready.
        if let previous = connection {
            previous.stateUpdateHandler = nil
            previous.cancel()
            connection = nil
        }

        let conn = NWConnection(to: endpoint, using: params)
        connection = conn
        // A dial to a withdrawn Bonjour service (receiver asleep or app
        // closed) sits in .preparing forever — it neither fails nor resolves
        // when the service later returns, observed on macOS 26. Give every
        // dial a deadline and redial fresh: a new NWConnection re-runs
        // Bonjour resolution, so the retry loop reaches the receiver the
        // moment it advertises again.
        let generation = dialGeneration
        // Android USB (adb forward) + Wi‑Fi can need >8s after sleep / app restart.
        queue.asyncAfter(deadline: .now() + 12.0) { [weak self] in
            guard let self, generation == self.dialGeneration, !self.stopped,
                  self.connection === conn, conn.state != .ready else { return }
            Log.info("dial timed out in \(conn.state) — redialing")
            self.scheduleReconnect()
        }
        conn.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            // Ignore events from a superseded dial — an orphan's `.failed`
            // must not cancel the live socket and restart the thrash loop.
            guard self.connection === conn else { return }
            switch state {
            case .ready:
                self.becomeReady(conn)
            case .failed(let error):
                Log.info("connection failed: \(error)")
                self.connectionReady = false
                if case .posix(let code) = error, code == .ECONNREFUSED {
                    self.dialRefused()
                }
                self.scheduleReconnect()
            case .waiting(let error):
                // Bonjour dials often pass through `.waiting` before `.ready`.
                // Do NOT cancel+redial here — that races the first dial and
                // leaves an orphan TCP on the receiver (connect/RST thrash).
                // The 5s dial timeout above handles dials that never leave
                // waiting; loopback "tunnel not up yet" also hits that path.
                Log.info("connection waiting: \(error)")
                if !self.connectionReady {
                    let text = self.awaitingWake
                        ? "\(self.endpointName) is asleep — reconnects when it wakes…"
                        : "Waiting for receiver at \(self.endpointName)…"
                    Task { await self.status(text) }
                }
            case .cancelled:
                // Only clear ready if this cancelled conn is still current
                // (always true due to the guard above).
                if self.connection === conn {
                    self.connectionReady = false
                }
            default:
                break
            }
        }
        conn.start(queue: queue)
    }

    /// Dial through macOS's built-in usbmuxd — no external tunnel needed.
    /// The handshake is async, so adoption is gated on `dialGeneration`.
    private func connectUSB(udid: String?, port: UInt16) {
        dialGeneration += 1
        let generation = dialGeneration
        Task { [weak self] in
            guard let self else { return }
            do {
                let conn = try await Usbmux.dial(udid: udid, port: port, queue: queue)
                queue.async {
                    guard generation == self.dialGeneration, !self.stopped else {
                        conn.cancel()
                        return
                    }
                    self.connection = conn
                    conn.stateUpdateHandler = { [weak self] state in
                        guard let self else { return }
                        switch state {
                        case .failed(let error):
                            Log.info("usb connection failed: \(error)")
                            self.connectionReady = false
                            self.scheduleReconnect()
                        case .cancelled:
                            self.connectionReady = false
                        default:
                            break
                        }
                    }
                    self.becomeReady(conn)
                }
            } catch {
                queue.async {
                    guard generation == self.dialGeneration, !self.stopped else { return }
                    // Distinct guidance per failure: cable missing vs app
                    // closed. Composed on `queue`: awaitingWake lives there.
                    let hint: String
                    switch error as? Usbmux.Failure {
                    case .noDevice:
                        hint = "Waiting for a USB device — plug in the iPhone or iPad…"
                    case .refused:
                        self.dialRefused()
                        hint = self.awaitingWake
                            ? "\(self.endpointName) is asleep — reconnects when it wakes…"
                            : "Device found — open the OpenDisplay app on it…"
                    default:
                        Log.info("usb dial failed: \(error)")
                        hint = "USB connection failed: \(error.localizedDescription)"
                    }
                    Task { await self.status(hint) }
                    self.scheduleReconnect()
                }
            }
        }
    }

    private func scheduleReconnect() {
        guard !stopped else { return }
        // While Screen Recording is still missing we keep dialing patiently —
        // the user may be flipping the Settings toggle; don't kill the session.
        let waitingForScreenRecording = !CGPreflightScreenCaptureAccess()
        let grace = waitingForScreenRecording ? max(disconnectGraceSeconds, 90) : disconnectGraceSeconds
        if everConnected {
            if let since = disconnectedSince {
                if Date().timeIntervalSince(since) > grace {
                    reportGone("device gone for >\(Int(grace))s — ending session")
                    return
                }
            } else {
                disconnectedSince = Date()
                Task { await status("Connection lost — retrying for \(Int(grace))s…") }
            }
        }
        connectionReady = false
        dialGeneration += 1   // a USB dial still in flight must not adopt
        let generation = dialGeneration
        // Never leave a synthetic mouse-down held across a reconnect.
        inputInjector?.forceRelease()
        if let previous = connection {
            previous.stateUpdateHandler = nil
            previous.cancel()
        }
        connection = nil
        pendingSends = 0
        pipelineLock.lock()
        pendingEncodes = 0
        pipelineLock.unlock()
        // Refresh adb forward before redialing loopback Android sessions —
        // a dead forward presents as Connection refused and burns the grace.
        refreshAndroidAdbForwardIfNeeded()
        // Short gap: faster recovery after RST; still avoids dual-accept thrash.
        queue.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            // Generation-guarded so a switchTransport (or another reconnect)
            // that landed in this window supersedes this dial instead of
            // racing it — otherwise the queued connect() re-dials the new
            // transport, briefly running two live connections. (No bare
            // self-rescheduling asyncAfter — the pattern banned in #76.)
            guard let self, generation == self.dialGeneration, !self.stopped else { return }
            self.connect()
        }
    }

    /// If this session dials via adb port-forward (127.0.0.1), ensure the
    /// forward still exists before the next connect().
    private func refreshAndroidAdbForwardIfNeeded() {
        guard case .tcp(let endpoint, _) = transport else { return }
        // hostPort form: loopback Android USB path.
        guard case .hostPort(let host, let port) = endpoint else { return }
        let hostStr = "\(host)"
        let isLoopback = hostStr == "127.0.0.1" || hostStr == "localhost" || hostStr == "::1"
        guard isLoopback else { return }
        let devicePort = port.rawValue
        DispatchQueue.global(qos: .utility).async {
            if let p = AndroidAdb.ensureForward(devicePort: devicePort) {
                Log.info("reconnect: adb forward ok host tcp:\(p) → device tcp:\(devicePort)")
            } else {
                Log.info("reconnect: adb forward missing — will retry dial anyway")
            }
        }
    }

    // MARK: - Liveness (ping + watchdog)

    private func schedulePing() {
        queue.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self, !self.stopped else { return }
            if self.connectionReady {
                // Liveness + send-side health for the phone's overlay.
                let elapsed = Date().timeIntervalSince(self.capWindowStart)
                let capFps = elapsed > 0 ? Int(Double(self.capFrames) / elapsed) : 0
                self.capFrames = 0
                self.capWindowStart = Date()
                let sorted = self.inputLatencies.sorted()
                let inp50 = sorted.isEmpty ? 0 : sorted[sorted.count / 2].rounded()
                let inp95 = sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))].rounded()
                self.sendJSONFrame("{\"type\":\"ping\",\"drops\":\(self.dropsTotal),\"encDrops\":\(self.dropsEncTotal),\"netDrops\":\(self.dropsNetTotal),\"pending\":\(self.pendingSends),\"inp50\":\(inp50),\"inp95\":\(inp95),\"capFps\":\(capFps)}")
            }
            self.schedulePing()
        }
    }

    private func scheduleWatchdog() {
        queue.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self, !self.stopped else { return }
            // 8s silence before TCP recycle — 5s was too twitchy under load
            // (decoder stalls + stats jitter look like a dead link).
            if self.connectionReady, Date().timeIntervalSince(self.lastReceived) > 8 {
                // A suspended receiver app (user switched apps) goes silent
                // like this while its kernel still accepts redials — the
                // session and display are kept on purpose so the user's
                // window arrangement survives until they come back. Genuine
                // network loss fails the redials and ends via the grace.
                Log.info("watchdog: nothing from the phone for >8s — reconnecting")
                // Can't tell a backgrounded receiver from a brief stall here
                // (both go silent while redials still succeed) — hedge.
                Task { await self.status("\(self.endpointName) is silent — keeping the display (app in background or brief stall)") }
                self.scheduleReconnect()
            }
            // The disconnect grace is otherwise only evaluated when a dial
            // changes state — a dial stuck in .preparing (withdrawn Bonjour
            // service) would keep a dead session's display up forever.
            // Enforce it from here too, where the clock always ticks.
            if !self.connectionReady, self.everConnected,
               let since = self.disconnectedSince,
               Date().timeIntervalSince(since) > self.disconnectGraceSeconds {
                self.reportGone("device gone for >\(Int(self.disconnectGraceSeconds))s — ending session")
            }
            // A reconnect on a static screen produces no capture frames, so
            // the receiver would stay black — replay the last frame as IDR.
            // Same path serves phone "kf" requests while the desktop is idle
            // (e.g. after a window was dragged off and SCK stopped emitting).
            if self.connectionReady, self.needsKeyframe,
               Date().timeIntervalSince(self.lastCaptureAt) > 1,
               let pixelBuffer = self.lastPixelBuffer {
                Log.info("static screen — replaying last frame as keyframe")
                self.encode(pixelBuffer, pts: CMClockGetTime(CMClockGetHostTimeClock()))
            }
            self.scheduleWatchdog()
        }
    }

    /// After capture goes quiet, force a clean IDR so the tablet cannot keep
    /// a mid-drag frame (title bar / app name) or P-frame residue. Also nudge
    /// the desktop underlay so SCK re-samples the true empty desktop.
    private func scheduleIdleFlush() {
        idleFlushWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.performIdleFlush()
        }
        idleFlushWorkItem = work
        // Window drags emit a burst then stop; 300ms is past settle without
        // feeling laggy when the user pauses briefly.
        queue.asyncAfter(deadline: .now() + 0.30, execute: work)
    }

    private func performIdleFlush() {
        guard !stopped, connectionReady, mode == .extend else { return }
        // Only after real activity — not every cursor-only tick (none with
        // localCursor) or a single spurious frame.
        guard capturesSinceIdleFlush >= 2 else { return }
        // Rate-limit: continuous UI on the tablet pauses often while typing.
        guard Date().timeIntervalSince(lastIdleFlushAt) >= 1.5 else { return }
        guard let pixelBuffer = lastPixelBuffer else { return }

        capturesSinceIdleFlush = 0
        lastIdleFlushAt = Date()
        needsKeyframe = true
        encode(pixelBuffer, pts: CMClockGetTime(CMClockGetHostTimeClock()))
        Log.info("idle flush: keyframe after capture settled (\(captureDisplayID))")

        let id = captureDisplayID
        guard id != 0 else { return }
        Task { @MainActor in DesktopUnderlay.nudge(on: id) }
        // Nudge may produce a fresh SCK sample ~one frame later. If not, push
        // whatever we have again so the receiver still gets an IDR.
        queue.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self, !self.stopped, self.connectionReady,
                  let pb = self.lastPixelBuffer else { return }
            self.needsKeyframe = true
            self.encode(pb, pts: CMClockGetTime(CMClockGetHostTimeClock()))
        }
    }

    // MARK: - Local cursor echo (Mac -> phone)

    private func startCursorEcho() {
        guard localCursor else { return }
        cursorTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(8))   // 120Hz
        timer.setEventHandler { [weak self] in self?.pollCursorPosition() }
        timer.resume()
        cursorTimer = timer
        scheduleCursorImagePoll()
    }

    /// Sprite changes (arrow ↔ I-beam ↔ resize…) — poll slowly on the main
    /// thread. `NSCursor.currentSystem` hits WindowServer (SLSCopyRegistered
    /// CursorImages) and at 30Hz it freezes the menu bar / whole app under load.
    /// 5 Hz is enough for arrow↔I-beam; PNG work runs off-main after a cheap hash.
    ///
    /// A dedicated timer (cancelled+replaced here, like cursorTimer above) — not
    /// a self-rescheduling asyncAfter chain (#75).
    private func scheduleCursorImagePoll() {
        cursorImageTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 0.2, repeating: .milliseconds(200))
        timer.setEventHandler { [weak self] in
            guard let self, !self.stopped, self.localCursor, self.connectionReady else { return }
            self.pollCursorImage()
        }
        timer.resume()
        cursorImageTimer = timer
    }

    private func pollCursorPosition() {
        guard connectionReady, captureDisplayID != 0,
              let loc = CGEvent(source: nil)?.location else { return }
        let bounds = CGDisplayBounds(captureDisplayID)
        guard bounds.width > 0, bounds.height > 0 else { return }
        if bounds.contains(loc) {
            let x = (loc.x - bounds.minX) / bounds.width
            let y = (loc.y - bounds.minY) / bounds.height
            if !lastCursorSent.visible
                || abs(x - lastCursorSent.x) > 0.0004 || abs(y - lastCursorSent.y) > 0.0004 {
                lastCursorSent = (x, y, true)
                sendJSONFrame(String(format: "{\"type\":\"cursor\",\"x\":%.4f,\"y\":%.4f,\"v\":1}", x, y))
            }
        } else if lastCursorSent.visible {
            lastCursorSent.visible = false
            sendJSONFrame("{\"type\":\"cursor\",\"v\":0}")
        }
    }

    private func pollCursorImage() {
        // Display size read LIVE, not snapshotted at capture start: the
        // HiDPI mode settles (and macOS re-flips it) asynchronously, and a
        // sprite normalized against the 1x size renders at half size on the
        // device. Mixing the size into the dedup hash re-sends the sprite
        // whenever the mode flips, so the proportion always heals.
        guard connectionReady, captureDisplayID != 0 else { return }
        // Prefer current (cheaper) over currentSystem — same for normal apps;
        // only special system cursors differ.
        let cursor = NSCursor.current
        let displaySize = CGDisplayBounds(captureDisplayID).size   // points, current mode
        guard displaySize.width > 0, displaySize.height > 0 else { return }
        let image = cursor.image
        let size = image.size
        let hot = cursor.hotSpot
        // Cheap identity: size + hotspot + image pointer — avoids full TIFF
        // hash / encode on every tick when the cursor is unchanged.
        let identity = "\(ObjectIdentifier(image as AnyObject))-\(Int(size.width))x\(Int(size.height))-\(Int(hot.x)),\(Int(hot.y))-\(Int(displaySize.width))"
        let hash = identity.hashValue
        guard hash != lastCursorPNGHash else { return }
        lastCursorPNGHash = hash
        // PNG encode off the main thread — this is what used to freeze UI.
        let captureID = captureDisplayID
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self, !self.stopped else { return }
            guard let tiff = image.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff),
                  let png = rep.representation(using: .png, properties: [:]),
                  png.count < 24_000 else { return }
            let liveSize = CGDisplayBounds(captureID).size
            guard liveSize.width > 0, liveSize.height > 0 else { return }
            let msg = String(format:
                "{\"type\":\"cursorImg\",\"nw\":%.5f,\"nh\":%.5f,\"ax\":%.3f,\"ay\":%.3f,\"png\":\"%@\"}",
                size.width / liveSize.width,
                size.height / liveSize.height,
                size.width > 0 ? hot.x / size.width : 0,
                size.height > 0 ? hot.y / size.height : 0,
                png.base64EncodedString())
            self.queue.async { self.sendJSONFrame(msg) }
        }
    }

    // MARK: - Control messages (phone -> Mac)

    private func receiveControl(on conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] data, _, _, error in
            guard let self, error == nil, let data, data.count == 4 else { return }
            let len = Int(UInt32(bigEndian: data.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }))
            guard len > 0, len < 1 << 20 else { return }
            conn.receive(minimumIncompleteLength: len, maximumLength: len) { [weak self] payload, _, _, error in
                guard let self, error == nil, let payload, payload.count == len else { return }
                self.handleControl(payload)
                self.receiveControl(on: conn)
            }
        }
    }

    private func handleControl(_ payload: Data) {
        lastReceived = Date()
        guard let obj = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let type = obj["type"] as? String else {
            Log.info("unparseable control message (\(payload.count) bytes)")
            return
        }
        switch type {
        case "ping":
            // Echo with our clock so the phone can estimate the offset
            // (NTP-style) and compute true end-to-end frame latency.
            if let t = obj["t"] as? Double {
                let mt = Date().timeIntervalSince1970 * 1000
                sendJSONFrame("{\"type\":\"pong\",\"t\":\(t),\"mt\":\(mt)}")
            }
        case "stats":
            // Aggregated pipeline health measured on the phone — logged here
            // so one file holds both ends of the story.
            if let json = try? JSONSerialization.data(withJSONObject: obj),
               let line = String(data: json, encoding: .utf8) {
                Log.info("PHONE-STATS \(line) | mac enc↓=\(dropsEncThisWindow) net↓=\(dropsNetThisWindow) pending=\(pendingSends)")
                dropsEncThisWindow = 0
                dropsNetThisWindow = 0
            }
        case "hello":
            if let info = try? JSONDecoder().decode(PhoneInfo.self, from: payload) {
                let previous = lastHello
                lastHello = info
                peerWantsAudio = streamAudioEnabled && info.wantsAudio
                updateSpeakerMute(active: peerWantsAudio)
                Task { @MainActor in self.onHello?(info) }
                // Version handshake (issue #132). Reply with our identity, and
                // if the receiver is below the version we support, tell it to
                // update. Both are additive: older receivers ignore unknown
                // message types. Sending on every hello is idempotent — the
                // phone dedupes by content.
                sendWelcome()
                if info.protocolVersion < WireProtocol.minSupportedPeer {
                    Log.info("receiver protocol \(info.protocolVersion) below supported \(WireProtocol.minSupportedPeer) — requesting update")
                    sendUpdateRequired(kind: info.kind)
                }
                if let continuation = helloContinuation {
                    helloContinuation = nil
                    continuation.resume(returning: info)
                } else if mode == .extend {
                    // start() may have failed (e.g. virtual display serial
                    // still held) while the TCP reconnect loop kept running.
                    // A later hello should (re)build the pipeline rather than
                    // leave the session stuck "Connected" with no capture.
                    // Skip while Screen Recording is still missing — start()
                    // owns that poll and will call setupExtend after grant.
                    // `reconfiguring` also covers "setup still in flight".
                    if stream == nil, !reconfiguring, CGPreflightScreenCaptureAccess() {
                        Task {
                            guard !self.stopped, self.stream == nil, !self.reconfiguring,
                                  CGPreflightScreenCaptureAccess() else { return }
                            self.reconfiguring = true
                            defer { self.reconfiguring = false }
                            // Drop any partial display from a prior failed attempt
                            // so the serial is free for the retry.
                            if let stream = self.stream { try? await stream.stopCapture() }
                            self.stream = nil
                            let oldID = self.captureDisplayID
                            if oldID != 0 {
                                await MainActor.run {
                                    DesktopUnderlay.hide(on: oldID)
                                    TestPattern.hide(on: oldID)
                                }
                            }
                            self.virtualDisplay = nil
                            do {
                                try await self.setupExtend(info)
                            } catch {
                                Log.info("late setupExtend failed: \(error)")
                                await self.status("Failed: \(error.localizedDescription)")
                            }
                        }
                    } else if stream != nil, let previous,
                              previous.pixelsWide != info.pixelsWide
                              || previous.pixelsHigh != info.pixelsHigh {
                        // Phone rotated — rebuild after a short debounce so a
                        // flurry of orientation flips settles into one rebuild.
                        Task {
                            try? await Task.sleep(for: .milliseconds(300))
                            guard let current = self.lastHello,
                                  current.pixelsWide == info.pixelsWide,
                                  current.pixelsHigh == info.pixelsHigh else { return }
                            await self.reconfigure(info)
                        }
                    }
                }
            }
        case "touch":
            // Hard block while settings UI is open — no HID events, no synthetic
            // mouse-up (that was cancelling real trackpad clicks on the panel).
            if InputInjector.injectionPaused {
                inputInjector?.forceRelease(restoreCursor: false, postEvents: false)
                break
            }
            if let phase = obj["phase"] as? String,
               let x = obj["x"] as? Double,
               let y = obj["y"] as? Double {
                inputInjector?.handleTouch(phase: phase, x: x, y: y)
                if let t = obj["t"] as? Double {
                    let delta = Date().timeIntervalSince1970 * 1000 - t
                    if delta > -50, delta < 1000 {
                        inputLatencies.append(max(delta, 0))
                        if inputLatencies.count > 240 { inputLatencies.removeFirst(120) }
                    }
                }
            }
        case "scroll":
            if InputInjector.injectionPaused { break }
            if let dx = obj["dx"] as? Double, let dy = obj["dy"] as? Double {
                inputInjector?.handleScroll(dx: dx, dy: dy)
            }
        case "kf":
            // The phone's decoder lost sync (e.g. it attached mid-GOP and
            // periodic keyframes are off) — force an IDR on the next frame.
            Log.info("phone requested keyframe")
            needsKeyframe = true
        case "viewport":
            // Android pinch-zoom: crop capture to the visible rect so the
            // stream carries real pixels instead of a soft local upscale.
            let x = obj["x"] as? Double ?? 0
            let y = obj["y"] as? Double ?? 0
            let w = obj["w"] as? Double ?? 1
            let h = obj["h"] as? Double ?? 1
            let z = obj["z"] as? Double ?? 1
            handleReceiverViewport(x: x, y: y, w: w, h: h, z: z)
        case WireMessage.sleeping:
            // The device locked and is about to close on us. Hand the
            // session to the controller right away: it tears the virtual
            // display down (returning the cursor to a visible screen) and
            // starts a wake-waiting replacement session.
            Log.info("receiver went to sleep — ending session, reconnect armed for wake")
            Task { @MainActor in self.onPeerSleeping?() }
        case WireMessage.closing:
            // The app on the device is quitting for real — end the session
            // without the silence grace and without waiting for a wake.
            Log.info("receiver app closed — ending session")
            Task { @MainActor in self.onPeerClosed?() }
        default:
            Log.info("unknown control message type: \(type)")
        }
    }

    private func waitForHello() async throws -> PhoneInfo {
        if let lastHello { return lastHello }
        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                if let hello = self.lastHello {
                    continuation.resume(returning: hello)
                } else {
                    self.helloContinuation = continuation
                }
            }
        }
    }

    // MARK: - Encoder setup

    private func setupEncoder(width: Int, height: Int) {
        // Low-latency rate control: the hardware encoder emits every frame
        // immediately instead of pipelining. (`-lowlatency NO` for A/B.)
        let lowLatency = UserDefaults.standard.object(forKey: "lowlatency") == nil
            || UserDefaults.standard.bool(forKey: "lowlatency")
        let spec: CFDictionary? = lowLatency
            ? [kVTVideoEncoderSpecification_EnableLowLatencyRateControl: kCFBooleanTrue] as CFDictionary
            : nil
        VTCompressionSessionCreate(
            allocator: nil,
            width: Int32(width), height: Int32(height),
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: spec,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &encoder
        )
        guard let encoder else {
            Log.info("FATAL: VTCompressionSessionCreate failed")
            return
        }
        // Low-latency settings: real-time, no B-frames, periodic keyframes.
        VTSessionSetProperty(encoder, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(encoder, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(encoder, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_High_AutoLevel)
        // No periodic IDRs: each one is a bitrate spike → transmit-time hiccup.
        // TCP never loses data, and we force a keyframe on reconnect/drop.
        VTSessionSetProperty(encoder, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: 3600 as CFNumber)
        VTSessionSetProperty(encoder, key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, value: 60 as CFNumber)
        VTSessionSetProperty(encoder, key: kVTCompressionPropertyKey_MaxFrameDelayCount, value: 0 as CFNumber)
        let br = quality.bitrate(forPixelsWide: width, pixelsHigh: height)
        VTSessionSetProperty(encoder, key: kVTCompressionPropertyKey_AverageBitRate, value: br as CFNumber)
        // Soft data-rate ceiling (~1.5× average) reduces macroblocking on busy frames.
        let bytesPerSecond = br / 8
        let limits: [CFNumber] = [1 as CFNumber, (bytesPerSecond * 3 / 2) as CFNumber]
        VTSessionSetProperty(encoder, key: kVTCompressionPropertyKey_DataRateLimits, value: limits as CFArray)
        VTSessionSetProperty(encoder, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: 60 as CFNumber)
        // Prefer a bit more quality at "best"; speed bias for lower presets.
        let preferSpeed = quality != .best
        VTSessionSetProperty(encoder, key: kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality,
                             value: preferSpeed ? kCFBooleanTrue : kCFBooleanFalse)
        if quality == .best {
            // 0.0–1.0; higher = better looking frames at the cost of size.
            VTSessionSetProperty(encoder, key: kVTCompressionPropertyKey_Quality, value: 0.75 as CFNumber)
        }
        VTCompressionSessionPrepareToEncodeFrames(encoder)
        // Re-apply zoom bitrate if the receiver is already pinched in.
        if receiverZoom > 1.02 { applyZoomBitrate(forceKeyframe: false) }
        Log.info("encoder ready: \(width)x\(height) H.264 \(br / 1_000_000)Mbps quality=\(quality.rawValue) lowLatencyRC=\(lowLatency)")
    }

    // MARK: - Capture callback

    func stream(_ stream: SCStream,
                didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        if type == .audio {
            handleAudioSample(sampleBuffer)
            return
        }
        guard type == .screen,
              CMSampleBufferIsValid(sampleBuffer),
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer)
        else { return }

        lastPixelBuffer = pixelBuffer
        lastCaptureAt = Date()
        capFrames += 1
        capturesSinceIdleFlush += 1
        // When this burst ends (window finished moving), flush an IDR so the
        // tablet cannot keep a remnant of the previous window.
        if mode == .extend { scheduleIdleFlush() }

        // No receiver, or a pipeline stage is backed up: skip this frame.
        guard connectionReady else { return }
        if shouldDropFrame(reason: "pending_encode") { return }  // encoder busy
        if shouldDropFrame(reason: "pending_sends") { return }   // TCP send queue full

        encode(pixelBuffer, pts: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
    }

    private func handleAudioSample(_ sampleBuffer: CMSampleBuffer) {
        guard peerWantsAudio, connectionReady, streamAudioEnabled else { return }
        // Don't let audio fight a backed-up video send queue forever.
        if pendingSends >= maxPendingSends { return }
        guard CMSampleBufferIsValid(sampleBuffer) else { return }
        let pcm = audioResampler.convert(sampleBuffer)
        guard !pcm.isEmpty else { return }
        // Chunk ~20 ms (960 @ 48 kHz) to keep latency low without tiny packets.
        let chunk = 960
        var i = 0
        while i < pcm.count {
            let end = min(i + chunk, pcm.count)
            let slice = Array(pcm[i..<end])
            sendFramed(AudioWire.pack(pcmS16Mono: slice))
            i = end
        }
    }

    /// Drop when encode or send pipeline is busy.
    /// Pre-encode drops are invisible to the decoder — the H.264 reference
    /// chain stays intact, so the next frame can be a normal P-frame (n → n+2).
    /// Do NOT force keyframes here; that causes IDR pulsing / blockiness.
    private func shouldDropFrame(reason: String) -> Bool {
        pipelineLock.lock()
        let drop: Bool
        switch reason {
        case "pending_encode":
            drop = pendingEncodes >= maxPendingEncodes
        case "pending_sends":
            drop = pendingSends >= maxPendingSends
        default:
            drop = false
        }
        pipelineLock.unlock()
        guard drop else { return false }
        switch reason {
        case "pending_encode":
            dropsEncThisWindow += 1
            dropsEncTotal += 1
        case "pending_sends":
            dropsNetThisWindow += 1
            dropsNetTotal += 1
        default:
            break
        }
        return true
    }

    private func encode(_ pixelBuffer: CVPixelBuffer, pts: CMTime) {
        guard let encoder else { return }
        pipelineLock.lock()
        pendingEncodes += 1
        pipelineLock.unlock()
        let capturedAtMs = Int64(Date().timeIntervalSince1970 * 1000)
        var frameProperties: CFDictionary?
        if needsKeyframe {
            frameProperties = [kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue!] as CFDictionary
            needsKeyframe = false
        }
        let submitStatus = VTCompressionSessionEncodeFrame(
            encoder,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: pts,
            duration: .invalid,
            frameProperties: frameProperties,
            infoFlagsOut: nil
        ) { [weak self] status, _, buffer in
            guard let self else { return }
            defer {
                self.pipelineLock.lock()
                self.pendingEncodes = max(0, self.pendingEncodes - 1)
                self.pipelineLock.unlock()
            }
            guard status == noErr, let buffer else { return }
            if let data = self.annexB(from: buffer) {
                let sndMs = Int64(Date().timeIntervalSince1970 * 1000)
                var framed = Data("{\"cap\":\(capturedAtMs),\"snd\":\(sndMs)}".utf8)
                framed.append(data)
                self.sendFramed(framed)
            }
        }
        if submitStatus != noErr {
            pipelineLock.lock()
            pendingEncodes = max(0, pendingEncodes - 1)
            pipelineLock.unlock()
            Log.info("VTCompressionSessionEncodeFrame failed: \(submitStatus)")
        }
    }

    // MARK: - H.264 -> Annex B

    private func annexB(from sample: CMSampleBuffer) -> Data? {
        guard let block = CMSampleBufferGetDataBuffer(sample) else { return nil }
        var len = 0, total = 0
        var ptr: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(block, atOffset: 0,
                lengthAtOffsetOut: &len, totalLengthOut: &total,
                dataPointerOut: &ptr) == noErr, let ptr else { return nil }

        var out = Data(capacity: total + 128)
        // On keyframes, prepend SPS/PPS (they live in the format description).
        if isKeyframe(sample), let fmt = CMSampleBufferGetFormatDescription(sample) {
            for i in 0..<2 {           // index 0 = SPS, 1 = PPS
                var psPtr: UnsafePointer<UInt8>?
                var psLen = 0
                if CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                        fmt, parameterSetIndex: i,
                        parameterSetPointerOut: &psPtr,
                        parameterSetSizeOut: &psLen,
                        parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil) == noErr,
                   let psPtr {
                    out.append(contentsOf: startCode)
                    out.append(Data(bytes: psPtr, count: psLen))
                }
            }
        }
        // Convert AVCC (4-byte length-prefixed NALUs) to Annex B start codes.
        let raw = UnsafeRawPointer(ptr)
        var offset = 0
        while offset + 4 <= total {
            var nalLen: UInt32 = 0
            memcpy(&nalLen, raw + offset, 4)
            nalLen = CFSwapInt32BigToHost(nalLen)
            offset += 4
            guard offset + Int(nalLen) <= total else { break }
            out.append(contentsOf: startCode)
            out.append(Data(bytes: raw + offset, count: Int(nalLen)))
            offset += Int(nalLen)
        }
        return out
    }

    private func isKeyframe(_ sample: CMSampleBuffer) -> Bool {
        guard let arr = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false),
              let dict = (arr as? [[CFString: Any]])?.first else { return true }
        return !(dict[kCMSampleAttachmentKey_NotSync] as? Bool ?? false)
    }

    // MARK: - Wire framing: [4-byte big-endian length][payload]

    /// Control messages on the video channel (pong etc.) — framed JSON without
    /// start codes; the receiver routes payloads starting with '{'.
    // MARK: - Version handshake (issue #132)

    /// Identify ourselves to the receiver: our protocol version and the oldest
    /// receiver version we still support.
    private func sendWelcome() {
        sendJSONFrame("{\"type\":\"\(WireMessage.welcome)\",\"pv\":\(WireProtocol.version),\"min\":\(WireProtocol.minSupportedPeer)}")
    }

    /// Ask the receiver to update from the App Store (built via JSONSerialization
    /// because the message text is user-facing prose).
    private func sendUpdateRequired(kind: String) {
        let dict: [String: Any] = [
            "type": WireMessage.updateRequired,
            "target": "ios",
            "store": AppStore.updateURL.absoluteString,
            "message": "This \(kind) app is too old for this Mac. Update OpenDisplay from the App Store to reconnect.",
        ]
        if let data = try? JSONSerialization.data(withJSONObject: dict),
           let json = String(data: data, encoding: .utf8) {
            sendJSONFrame(json)
        }
    }

    private func sendJSONFrame(_ json: String) {
        guard let connection, connectionReady else { return }
        let payload = Data(json.utf8)
        var header = UInt32(payload.count).bigEndian
        var frame = Data(bytes: &header, count: 4)
        frame.append(payload)
        connection.send(content: frame, completion: .contentProcessed { _ in })
    }

    private func sendFramed(_ payload: Data) {
        guard let connection, connectionReady else { return }
        var header = UInt32(payload.count).bigEndian
        var frame = Data(bytes: &header, count: 4)
        frame.append(payload)
        pendingSends += 1
        connection.send(content: frame, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            self.pendingSends = max(0, self.pendingSends - 1)
            if let error {
                Log.info("send error: \(error)")
                return
            }
            self.framesSent += 1
            self.bytesSent += frame.count
            // Report stats roughly once a second.
            let elapsed = Date().timeIntervalSince(self.statsWindowStart)
            if elapsed >= 1.0 {
                let mbps = Double(self.bytesSent) * 8 / elapsed / 1_000_000
                let frames = self.framesSent
                self.bytesSent = 0
                self.statsWindowStart = Date()
                Task { @MainActor in self.onStats?(frames, mbps) }
            }
        })
    }

    // MARK: - Helpers

    private func status(_ text: String) async {
        await MainActor.run { onStatus?(text) }
    }
}
