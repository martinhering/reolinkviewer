import Baichuan
import CameraMedia
import Foundation
import Recording

/// Command-line harness for the Baichuan library.
///
///   bctool info   --host H [--port 9000] [--user admin]
///   bctool stream --host H [--sub] [--seconds 10] [--out file.h264]
///   bctool ptz    --host H --dir left|right|up|down [--speed 32] [--ms 500]
///   bctool events --host H [--seconds 60]
///   bctool record --host H --out DIR [--sub] [--seconds 180] [--segment 60] [--no-audio]
///   bctool recorder --host H --out DIR [--seconds 180] [--segment 60] [--frame-size]
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
        if command == "decrypt" {
            decryptCommand(options)
            return
        }
        if command == "keyfile" {
            guard let out = options["out"] else { usage() }
            guard let passphrase = options["passphrase"] ?? ProcessInfo.processInfo.environment["BC_PASSPHRASE"] else {
                fail("no passphrase: pass --passphrase or set BC_PASSPHRASE")
            }
            do {
                try Vault.generate().keyFile(passphrase: passphrase).write(to: URL(fileURLWithPath: out))
                print("new key file written to \(out)")
            } catch {
                fail("\(error)")
            }
            return
        }
        if command == "storage" {
            await storageCommand(options)
            return
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
            case "sizes":
                try await sizesCommand(camera: camera, kind: flags.contains("sub") ? .sub : .main,
                                       seconds: Double(options["seconds"] ?? "60") ?? 60)
            case "recorder":
                guard let out = options["out"] else { usage() }
                await camera.disconnect()  // the recorder holds its own connection
                var parameters = RecordingSettings.Parameters()
                parameters.stream = flags.contains("sub") ? .sub : .main
                parameters.audio = !flags.contains("no-audio")
                parameters.keep = flags.contains("keep-all") ? .everything : .motionOnly
                parameters.segmentLength = Int(options["segment"] ?? "60") ?? 60
                parameters.paddingBefore = Int(options["before"] ?? "10") ?? 10
                parameters.paddingAfter = Int(options["after"] ?? "20") ?? 20
                parameters.floodlight = flags.contains("floodlight")
                let recorder = CameraRecorder(
                    camera: RecorderCamera(id: UUID(), name: host, host: host, port: port, username: user, password: password),
                    parameters: parameters, directory: URL(fileURLWithPath: out, isDirectory: true),
                    forceFrameSizeDetection: flags.contains("frame-size"), log: { print("  \(clock())  \($0)") })
                let seconds = Double(options["seconds"] ?? "180") ?? 180
                print("recorder running for \(Int(seconds)) s, keeping "
                      + (parameters.keep == .everything ? "everything" : "segments with motion") + ", Ctrl-C to stop")
                recorder.start()
                let interrupt = Interrupt()
                let deadline = Date().addingTimeInterval(seconds)
                while Date() < deadline, !interrupt.fired { try await Task.sleep(for: .milliseconds(200)) }
                await recorder.stop()
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
        let trace = ProcessInfo.processInfo.environment["BC_TRACE"] != nil
        for try await frame in stream {
            if trace {
                let ms = Int(Date().timeIntervalSince(t0) * 1000)
                switch frame {
                case .videoKeyFrame(_, let data, let micros, _): print("\(ms) K \(micros) \(data.count)")
                case .videoFrame(_, let data, let micros): print("\(ms) P \(micros) \(data.count)")
                case .aac(let data): print("\(ms) A - \(data.count)")
                default: break
                }
            }
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
        for segment in try await recorder.finish() { report(segment) }
        if let failure { throw failure }
        await camera.stopVideo()
        print("recording stopped, \(files) file\(files == 1 ? "" : "s")"
              + (recorder.discontinuities > 0 ? ", \(recorder.discontinuities) time stamp jumps" : ""))
    }

    /// Prints, second by second, what the frame-size motion detector sees next to what the
    /// camera's own detector reports. For judging the fallback on a given camera.
    static func sizesCommand(camera: BaichuanCamera, kind: StreamKind, seconds: Double) async throws {
        let cameraMotion = Counter()
        await camera.setMotionHandler { event in cameraMotion.set(event.isMotion ? 1 : 0) }
        let events = (try? await camera.startMotionEvents()) != nil
        let stream = try await camera.startVideo(kind)
        print("time      P bytes/s  baseline  frame sizes  camera" + (events ? "" : " (pushes no events)"))
        var detector = FrameSizeMotionDetector()
        let deadline = Date().addingTimeInterval(seconds)
        var second = Date()
        var bytes = 0
        for try await frame in stream {
            let now = Date()
            _ = detector.add(frame, at: now)
            if case .videoFrame(_, let data, _) = frame { bytes += data.count }
            if now.timeIntervalSince(second) >= 1 {
                print(String(format: "%@  %9d  %8.0f  %@  %@", String(clock(now).prefix(8)), bytes, detector.baseline ?? 0,
                             detector.isMotion ? "motion     " : "-          ", cameraMotion.value == 1 ? "motion" : "-"))
                second = now
                bytes = 0
            }
            if now >= deadline { break }
        }
        await camera.stopVideo()
    }

    /// Opens a sealed recording, as downloaded from the bucket, with the key file and the passphrase.
    static func decryptCommand(_ options: [String: String]) {
        guard let input = options["in"], let keyFilePath = options["key-file"], let name = options["name"] else { usage() }
        guard let passphrase = options["passphrase"] ?? ProcessInfo.processInfo.environment["BC_PASSPHRASE"] else {
            fail("no passphrase: pass --passphrase or set BC_PASSPHRASE")
        }
        do {
            let vault = try Vault(keyFile: Data(contentsOf: URL(fileURLWithPath: keyFilePath)), passphrase: passphrase)
            let clear = try vault.open(Data(contentsOf: URL(fileURLWithPath: input)), name: name)
            let out = options["out"] ?? (input.hasSuffix(".enc") ? String(input.dropLast(4)) : input + ".clear")
            try clear.write(to: URL(fileURLWithPath: out))
            print("opened \(input): \(clear.count) bytes written to \(out)")
        } catch {
            fail("\(error is VaultError ? "\(error)" : error.localizedDescription)")
        }
    }

    /// Tries the requests the recorder and storage setup make against a bucket, to see
    /// whether a provider and a key are fit for it.
    static func storageCommand(_ options: [String: String]) async {
        guard let endpoint = options["endpoint"], let bucket = options["bucket"], let keyID = options["key-id"] else { usage() }
        guard let secret = options["secret"] ?? ProcessInfo.processInfo.environment["BC_S3_SECRET"] else {
            fail("no secret: pass --secret or set BC_S3_SECRET")
        }
        var settings = StorageSettings()
        settings.endpoint = endpoint
        settings.bucket = bucket
        settings.region = options["region"] ?? ""
        guard let configuration = settings.configuration else { fail("not an endpoint: \(endpoint)") }
        let client = S3Client(configuration: configuration, credentials: S3Credentials(accessKeyID: keyID, secretAccessKey: secret))
        let key = StorageLayout.recordingsPrefix + "setup-check"
        func attempt(_ what: String, _ work: () async throws -> String) async {
            do {
                print("  \(what): \(try await work())")
            } catch {
                print("  \(what): failed, \(error is S3Error ? "\(error)" : error.localizedDescription)")
            }
        }
        print("\(bucket) at \(configuration.endpoint.absoluteString), region \(configuration.region)")
        await attempt("upload") {
            try await client.putObject(key: key, data: Data("ok".utf8))
            return "ok"
        }
        await attempt("download") { "\(try await client.getObject(key: key).count) bytes" }
        await attempt("missing object") {
            do {
                _ = try await client.getObject(key: key + "-missing")
                return "unexpectedly there"
            } catch let error as S3Error where error.isNotFound {
                return "reported as missing (\(error.code ?? "404"))"
            }
        }
        if let days = options["lifecycle-days"].flatMap({ Int($0) }) {
            await attempt("lifecycle rule, \(days) days") {
                try await client.putLifecycle(expireAfterDays: days, prefix: StorageLayout.recordingsPrefix)
                return "written (this replaced the bucket's lifecycle rules)"
            }
        }
        if options["delete"] != nil || CommandLine.arguments.contains("--delete") {
            await attempt("delete") {
                try await client.deleteObject(key: key)
                return "allowed (an upload-only key should be refused)"
            }
        }
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
          bctool recorder --host H --out DIR [--seconds 180] [--segment 60] [--before 10] [--after 20]
                          [--sub] [--no-audio] [--keep-all] [--frame-size] [--floodlight]
                                                             (the background recorder for one camera: keeps only segments
                                                              with motion; --frame-size judges motion by frame sizes)
          bctool sizes  --host H [--sub] [--seconds 60]      (P-frame bytes per second, the frame-size motion detector
                                                              and the camera's own motion state side by side)
          bctool decrypt --in FILE.enc --key-file data-key.json --name OBJECT-KEY [--out FILE]
                                                             (open a recording downloaded from the bucket; OBJECT-KEY is its
                                                              name there, recordings/<camera>/<day>/<file>; passphrase from
                                                              --passphrase or BC_PASSPHRASE)
          bctool keyfile --out data-key.json                 (a new random data key, wrapped with the passphrase; for tests)
          bctool storage --endpoint E --bucket B --key-id K [--region R] [--lifecycle-days N] [--delete]
                                                             (try a bucket and a key: upload, download, optionally write the
                                                              lifecycle rule and try a delete; secret from --secret or BC_S3_SECRET)
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

    func set(_ value: Int) {
        lock.lock(); defer { lock.unlock() }
        count = value
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
