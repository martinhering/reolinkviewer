import Baichuan
import Foundation

/// Command-line harness for the Baichuan library.
///
///   bctool info   --host H [--port 9000] [--user admin]
///   bctool stream --host H [--sub] [--seconds 10] [--out file.h264]
///   bctool ptz    --host H --dir left|right|up|down [--speed 32] [--ms 500]
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
        guard let password = options["password"] ?? ProcessInfo.processInfo.environment["BC_PASSWORD"] else {
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
            case "switch":
                for kind in [StreamKind.main, .sub, .main] {
                    try await streamCommand(camera: camera, kind: kind, seconds: 3, out: nil)
                }
            case "stream":
                try await streamCommand(camera: camera, kind: flags.contains("sub") ? .sub : .main,
                                        seconds: Double(options["seconds"] ?? "10") ?? 10, out: options["out"],
                                        audioOut: options["audio-out"])
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

    static func usage() -> Never {
        print("""
        usage:
          bctool info   --host H [--port 9000] [--user admin] [--verbose]
          bctool ping   --host H
          bctool stream --host H [--sub] [--seconds 10] [--out file.h264] [--audio-out file.aac]
          bctool switch --host H          (main → sub → main, 3 s each)
          bctool ir     --host H [--mode auto|on|off]        (infrared LEDs)
          bctool daynight --host H [--mode auto|color|bw]    (colour vs. monochrome picture)
          bctool ptz    --host H --dir left|right|up|down [--speed 32] [--ms 500]
        password: --password or BC_PASSWORD
        """)
        exit(2)
    }

    static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data(("error: " + message + "\n").utf8))
        exit(1)
    }
}
