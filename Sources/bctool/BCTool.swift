import Baichuan
import CameraMedia
import Foundation

/// Command-line harness for the Baichuan library.
///
///   bctool info   --host H [--port 9000] [--user admin]
///   bctool stream --host H [--sub] [--seconds 10] [--out file.h264]
///   bctool ptz    --host H --dir left|right|up|down [--speed 32] [--ms 500]
///   bctool events --host H [--seconds 60]
///   bctool record --host H --out DIR [--sub] [--seconds 180] [--segment 60] [--no-audio]
///
/// The password comes from --password or the BC_PASSWORD environment variable.
@main
struct BCTool {
    static func main() async {
        var args = Array(CommandLine.arguments.dropFirst())
        guard let command = args.first else { usage() }
        args.removeFirst()
        var options: [String: String] = [:]
        var flags: Set<String> = []
        var i = 0
        while i < args.count {
            let a = args[i]
            guard a.hasPrefix("--") else { usage() }
            let key = String(a.dropFirst(2))
            if i + 1 < args.count, !args[i + 1].hasPrefix("--") {
                options[key] = args[i + 1]
                i += 2
            } else {
                flags.insert(key)
                i += 1
            }
        }
        guard let host = options["host"] else { usage() }
        let port = UInt16(options["port"] ?? "9000") ?? 9000
        let user = options["user"] ?? "admin"
        // `--password ""` cannot be told from a flag, so `--password` alone also means "empty".
        let explicitEmpty = flags.contains("password")
        guard let password = options["password"] ?? ProcessInfo.processInfo.environment["BC_PASSWORD"]
                ?? (explicitEmpty ? "" : nil) else {
            fail("no password: pass --password or set BC_PASSWORD")
        }

        let camera = BaichuanCamera(host: host, port: port, username: user, password: password)
        await camera.setLog { line in FileHandle.standardError.write(Data(("[bc] " + line + "\n").utf8)) }
        if flags.contains("verbose") { await camera.setLogPackets(true) }

        do {
            let t0 = Date()
            let info = try await camera.connect()
            let enc = await camera.encryption?.name ?? "?"
            print(String(format: "logged in to %@ in %.0f ms, encryption: %@", host, Date().timeIntervalSince(t0) * 1000, enc))
            switch command {
            case "info":
                for (k, v) in info.fields { print("  \(k) = \(v)") }
            case "ping":
                try await camera.ping()
                print("ping ok")
            case "ptz":
                guard let dirText = options["dir"], let dir = PTZDirection(rawValue: dirText) else { usage() }
                let speed = Float(options["speed"] ?? "32") ?? 32
                let ms = Int(options["ms"] ?? "500") ?? 500
                try await camera.ptz(dir, speed: speed)
                print("moving \(dir) for \(ms) ms")
                try await Task.sleep(for: .milliseconds(ms))
                try await camera.ptz(.stop, speed: speed)
                print("stopped")
            case "ir":
                if let modeText = options["mode"] {
                    guard let mode = InfraredMode(rawValue: modeText) else { usage() }
                    try await camera.setInfrared(mode)
                    print("infrared set to \(mode.rawValue)")
                }
                let state = try await camera.getLEDState()
                print("infrared: \(state.infrared.rawValue), status LED: \(state.statusLight ? "on" : "off")")
            case "led":
                if let stateText = options["state"] {
                    guard stateText == "on" || stateText == "off" else { usage() }
                    try await camera.setStatusLight(stateText == "on")
                    print("status LED set to \(stateText)")
                }
                let state = try await camera.getLEDState()
                print("status LED: \(state.statusLight ? "on" : "off"), infrared: \(state.infrared.rawValue)")
            case "light":
                let probe = await camera.probeSpotlight()
                let answer = probe.replyCode.map { "code \($0)" } ?? "no reply"
                print("spotlight settings (message 438): \(answer)")
                if flags.contains("verbose"), let xml = probe.xml { print(xml) }
                let present = await camera.hasSpotlight()
                let state = await camera.spotlightState
                print("spotlight: \(present ? "present" : "not found")" + (state.map { ", currently \($0 ? "on" : "off")" } ?? ""))
                await camera.setSpotlightHandler { on in print("camera reports spotlight \(on ? "on" : "off")") }
                if let stateText = options["state"] {
                    guard stateText == "on" || stateText == "off" else { usage() }
                    let seconds = UInt16(options["seconds"] ?? "180") ?? 180
                    try await camera.setSpotlight(stateText == "on", duration: seconds)
                    print("spotlight switched \(stateText)" + (stateText == "on" ? " for \(seconds) s" : ""))
                }
                if let autoText = options["auto"] {
                    guard autoText == "on" || autoText == "off" else { usage() }
                    try await camera.setSpotlightAutomatic(autoText == "on")
                    print("automatic spotlight switched \(autoText)")
                }
                if let automatic = try? await camera.getSpotlightAutomatic() {
                    print("automatic spotlight (on motion in the dark): \(automatic ? "on" : "off")")
                    if flags.contains("verbose") { print(try await camera.getFloodlightTaskXML()) }
                }
                try await Task.sleep(for: .seconds(2))  // let the camera report the change
            case "raw":
                guard let id = options["id"].flatMap({ UInt32($0) }) else { usage() }
                if let reply = try await camera.query(msgId: id, withChannelExtension: !flags.contains("no-extension")) {
                    print("message \(id): code \(reply.code)")
                    if let xml = reply.xml { print(xml) }
                } else {
                    print("message \(id): no reply")
                }
            case "osd":
                if flags.contains("verbose") { print(try await camera.getOSDConfigXML()) }
                if let name = options["name"] {
                    try await camera.setOSDName(name)
                    print("OSD name set to \(name)")
                }
                print("OSD name: \(try await camera.getOSDName())")
            case "services":
                if flags.contains("verbose") { print(try await camera.getServerPortsXML()) }
                for service in CameraService.allCases {
                    guard let state = options[service.rawValue] else { continue }
                    let enabled: Bool
                    switch state {
                    case "on": enabled = true
                    case "off": enabled = false
                    default: usage()
                    }
                    try await camera.setService(service, enabled: enabled)
                    print("\(service.displayName) switched \(state)")
                }
                let services = try await camera.getServices()
                for service in CameraService.allCases {
                    guard let state = services[service] else { continue }
                    print("  \(service.displayName): \(state.enabled ? "on" : "off")" + (state.port.map { "  port \($0)" } ?? ""))
                }
            case "daynight":
                if let modeText = options["mode"] {
                    let mode: DayNightMode
                    switch modeText {
                    case "auto": mode = .auto
                    case "color": mode = .color
                    case "bw", "blackAndWhite": mode = .blackAndWhite
                    default: usage()
                    }
                    try await camera.setDayNightMode(mode)
                    print("day/night set to \(mode.rawValue)")
                }
                print("day/night: \(try await camera.getDayNightMode().rawValue)")
            case "users":
                for u in try await camera.getUsers() {
                    print("  \(u.userName)  \(u.isAdministrator ? "administrator" : "user")"
                          + (u.userId.map { "  id=\($0)" } ?? "") + (u.loginState == 1 ? "  (this session)" : ""))
                }
            case "passwd":
                guard let newPassword = options["new"] ?? ProcessInfo.processInfo.environment["BC_NEW_PASSWORD"],
                      !newPassword.isEmpty else {
                    fail("no new password: pass --new or set BC_NEW_PASSWORD")
                }
                let target = options["for"] ?? user
                try await camera.changePassword(to: newPassword, for: target)
                print("password of \(target) changed")
                await camera.disconnect()
                let check = BaichuanCamera(host: host, port: port, username: target, password: newPassword)
                try await check.connect()
                await check.disconnect()
                print("login with the new password works")
            case "switch":
                for kind in [StreamKind.main, .sub, .main] {
                    try await streamCommand(camera: camera, kind: kind, seconds: 3, out: nil)
                }
            case "stream":
                try await streamCommand(camera: camera, kind: flags.contains("sub") ? .sub : .main,
                                        seconds: Double(options["seconds"] ?? "10") ?? 10, out: options["out"],
                                        audioOut: options["audio-out"])
            case "events":
                try await eventsCommand(camera: camera, seconds: Double(options["seconds"] ?? "60") ?? 60,
                                        verbose: flags.contains("verbose"))
            case "record":
                guard let out = options["out"] else { usage() }
                try await recordCommand(camera: camera, kind: flags.contains("sub") ? .sub : .main,
                                        directory: URL(fileURLWithPath: out, isDirectory: true),
                                        seconds: Double(options["seconds"] ?? "180") ?? 180,
                                        segmentLength: Double(options["segment"] ?? "60") ?? 60,
                                        audio: !flags.contains("no-audio"))
            default:
                usage()
            }
            await camera.disconnect()
        } catch {
            fail("\(error)")
        }
    }

    static func streamCommand(camera: BaichuanCamera, kind: StreamKind, seconds: Double, out: String?, audioOut: String? = nil) async throws {
        let stream = try await camera.startVideo(kind)
        print("stream \(kind.rawValue) started, collecting for \(Int(seconds)) s")
        var file: FileHandle? = nil
        if let out {
            FileManager.default.createFile(atPath: out, contents: nil)
            file = FileHandle(forWritingAtPath: out)
        }
        var audioFile: FileHandle? = nil
        if let audioOut {
            FileManager.default.createFile(atPath: audioOut, contents: nil)
            audioFile = FileHandle(forWritingAtPath: audioOut)
        }
        var firstAAC = true
        var keyFrames = 0, frames = 0, aac = 0, adpcm = 0, bytes = 0
        var firstMicros: UInt32? = nil, lastMicros: UInt32 = 0
        var firstFrameAt: Date? = nil
        let deadline = Date().addingTimeInterval(seconds)
        let t0 = Date()
        for try await frame in stream {
            switch frame {
            case .info(let w, let h, let fps):
                print("  info: \(w)x\(h) @ \(fps) fps")
            case .videoKeyFrame(let codec, let data, let micros, let time):
                keyFrames += 1
                bytes += data.count
                if firstFrameAt == nil {
                    firstFrameAt = Date()
                    let head = data.prefix(8).map { String(format: "%02x", $0) }.joined(separator: " ")
                    print(String(format: "  first key frame after %.0f ms: %@ %d bytes, starts %@, time=%@",
                                 firstFrameAt!.timeIntervalSince(t0) * 1000, codec.rawValue, data.count, head,
                                 time.map(String.init) ?? "nil"))
                }
                if firstMicros == nil { firstMicros = micros }
                lastMicros = micros
                file?.write(data)
            case .videoFrame(_, let data, let micros):
                frames += 1
                bytes += data.count
                if firstMicros == nil { firstMicros = micros }
                lastMicros = micros
                file?.write(data)
            case .aac(let data):
                aac += 1
                if firstAAC {
                    firstAAC = false
                    let head = data.prefix(7).map { String(format: "%02x", $0) }.joined(separator: " ")
                    print("  first AAC frame: \(data.count) bytes, ADTS header \(head)")
                }
                audioFile?.write(data)
            case .adpcm: adpcm += 1
            }
            if Date() >= deadline { break }
        }
        let elapsed = Date().timeIntervalSince(t0)
        let span = firstMicros.map { Double(lastMicros &- $0) / 1_000_000 } ?? 0
        print(String(format: "  %d key + %d P frames (%.1f fps), %d audio AAC, %d ADPCM, %.1f MB video in %.1f s, timestamps span %.1f s",
                     keyFrames, frames, Double(keyFrames + frames) / elapsed, aac, adpcm, Double(bytes) / 1e6, elapsed, span))
        await camera.stopVideo()
        try? file?.close()
        try? audioFile?.close()
        print("stream stopped")
    }

    /// Local time with milliseconds, for lining events up with what happened in front of the camera.
    static func clock(_ date: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm:ss.SSS"
        return f.string(from: date)
    }

    static func describe(_ event: MotionEvent) -> String {
        var text = event.isMotion ? "motion" : "no motion"
        text += "  status=\(event.status)"
        if let ai = event.aiType { text += " AItype=\(ai)" }
        if let recording = event.recording { text += " recording=\(recording ? 1 : 0)" }
        return text
    }

    /// Asks for motion events and prints them as they arrive. Answers the question of phase 1
    /// of the recording plan: does this camera push motion events over Baichuan?
    static func eventsCommand(camera: BaichuanCamera, seconds: Double, verbose: Bool) async throws {
        let counter = Counter()
        await camera.setMotionHandler { event in
            counter.increment()
            print("  \(clock())  \(describe(event))")
        }
        do {
            try await camera.startMotionEvents()
        } catch {
            print("motion events (message 31): refused, \(error)")
            return
        }
        print("motion events (message 31): accepted. Listening for \(Int(seconds)) s; move in front of the camera, Ctrl-C to stop")
        let interrupt = Interrupt()
        let deadline = Date().addingTimeInterval(seconds)
        var lastPing = Date()
        while Date() < deadline, !interrupt.fired {
            try await Task.sleep(for: .milliseconds(200))
            // Nothing else is sent on this connection, so keep the session alive.
            if Date().timeIntervalSince(lastPing) >= 10 {
                lastPing = Date()
                try await camera.ping()
            }
        }
        let count = counter.value
        print(count == 0
              ? "no motion event in \(Int(Date().timeIntervalSince(deadline.addingTimeInterval(-seconds)))) s: the camera accepts the request but pushed nothing"
              : "\(count) motion event\(count == 1 ? "" : "s") received")
    }

    /// Records the stream into MP4 files cut on the wall clock, and prints the camera's motion
    /// events alongside.
    static func recordCommand(camera: BaichuanCamera, kind: StreamKind, directory: URL, seconds: Double,
                              segmentLength: Double, audio: Bool) async throws {
        await camera.setMotionHandler { event in print("  \(clock())  \(describe(event))") }
        do {
            try await camera.startMotionEvents()
            print("motion events (message 31): accepted")
        } catch {
            print("motion events (message 31): refused, \(error)")
        }

        let recorder = SegmentRecorder(directory: directory, segmentLength: segmentLength, recordAudio: audio)
        let stream = try await camera.startVideo(kind)
        print("recording \(kind.rawValue) stream to \(directory.path) for \(Int(seconds)) s in \(Int(segmentLength)) s files"
              + (audio ? " with sound" : " without sound") + ", Ctrl-C to stop")
        let interrupt = Interrupt()
        let deadline = Date().addingTimeInterval(seconds)
        var files = 0
        func report(_ segment: SegmentRecorder.Segment) {
            files += 1
            print(String(format: "  %@  %@  %.1f s, %@ %dx%d, %d frames (%d key), %d audio frames, %.1f MB",
                         clock(segment.start), segment.url.path, segment.duration, segment.codec.rawValue,
                         segment.width, segment.height, segment.videoFrames, segment.keyFrames, segment.audioFrames,
                         Double(segment.bytes) / 1e6))
        }
        // Ends the stream when time is up, also while no frame arrives.
        let stopper = Task {
            while Date() < deadline, !interrupt.fired, !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(200))
            }
            if !Task.isCancelled { await camera.stopVideo() }
        }
        defer { stopper.cancel() }
        // A dropped connection must not cost the file that was being written.
        var failure: Error? = nil
        do {
            for try await frame in stream {
                if let segment = try await recorder.append(frame) { report(segment) }
            }
        } catch {
            failure = error
        }
        if let segment = try await recorder.finish() { report(segment) }
        if let failure { throw failure }
        await camera.stopVideo()
        print("recording stopped, \(files) file\(files == 1 ? "" : "s")"
              + (recorder.discontinuities > 0 ? ", \(recorder.discontinuities) time stamp jumps" : ""))
    }

    static func usage() -> Never {
        print("""
        usage:
          bctool info   --host H [--port 9000] [--user admin] [--verbose]
          bctool ping   --host H
          bctool stream --host H [--sub] [--seconds 10] [--out file.h264] [--audio-out file.aac]
          bctool switch --host H          (main → sub → main, 3 s each)
          bctool ir     --host H [--mode auto|on|off]        (infrared LEDs)
          bctool led    --host H [--state on|off]            (blue status LED)
          bctool light  --host H [--state on|off] [--seconds 180] [--auto on|off]
                                                             (white spotlight, if present; --auto: on by itself at night)
          bctool osd    --host H [--name N]                  (name shown in the picture; --verbose dumps the XML)
          bctool daynight --host H [--mode auto|color|bw]    (colour vs. monochrome picture)
          bctool services --host H [--onvif on|off] [--rtsp on|off] [--rtmp on|off] [--http on|off] [--https on|off]
                                                             (network services; omit to read, --verbose dumps the XML)
          bctool ptz    --host H --dir left|right|up|down [--speed 32] [--ms 500]
          bctool users  --host H                             (list user accounts)
          bctool events --host H [--seconds 60]              (ask for motion events and print them; --verbose dumps the XML)
          bctool record --host H --out DIR [--sub] [--seconds 180] [--segment 60] [--no-audio]
                                                             (MP4 files cut on the wall clock, no re-encoding; prints motion events)
          bctool raw    --host H --id N [--no-extension]     (send a request without a body, print the reply)
          bctool passwd --host H --new P [--for admin]       (change a password, then log in with it)
        password: --password or BC_PASSWORD (may be empty for a camera not yet set up)
        new password: --new or BC_NEW_PASSWORD
        """)
        exit(2)
    }

    static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data(("error: " + message + "\n").utf8))
        exit(1)
    }
}

/// Counts from any thread.
final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() {
        lock.lock(); defer { lock.unlock() }
        count += 1
    }

    var value: Int {
        lock.lock(); defer { lock.unlock() }
        return count
    }
}

/// Turns Ctrl-C into a flag, so a command can close its files before it exits.
final class Interrupt: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    private let source: DispatchSourceSignal

    init() {
        signal(SIGINT, SIG_IGN)
        source = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
        source.setEventHandler { [weak self] in self?.set() }
        source.resume()
    }

    private func set() {
        lock.lock(); defer { lock.unlock() }
        flag = true
    }

    var fired: Bool {
        lock.lock(); defer { lock.unlock() }
        return flag
    }
}
