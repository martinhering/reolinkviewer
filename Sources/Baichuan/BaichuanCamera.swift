import Foundation

public enum StreamKind: String, CaseIterable, Sendable, Identifiable {
    /// The HD stream (“Clear” in the Reolink app).
    case main
    /// The low-resolution stream (“Fluent”).
    case sub

    public var id: String { rawValue }

    var streamName: String { self == .main ? "mainStream" : "subStream" }
    /// Value of the header's streamType byte. On the E1: main 0, sub 1.
    var streamTypeByte: UInt8 { self == .main ? 0 : 1 }
    /// Handle used by the official client: main 0, sub 256.
    var handle: UInt32 { self == .main ? 0 : 256 }
}

public enum PTZDirection: String, Sendable {
    case up, down, left, right, stop
}

/// Infrared illuminator mode.
public enum InfraredMode: String, CaseIterable, Sendable, Identifiable {
    /// The camera switches the IR LEDs on in the dark (default).
    case auto
    /// Always on.
    case on
    /// Always off.
    case off

    public var id: String { rawValue }

    var wireValue: String {
        switch self {
        case .auto: return "auto"
        case .on: return "open"
        case .off: return "close"
        }
    }

    init?(wireValue: String) {
        switch wireValue {
        case "auto": self = .auto
        case "open": self = .on
        case "close": self = .off
        default: return nil
        }
    }
}

/// Day & Night image mode: whether the sensor runs in colour or in monochrome (night) mode.
public enum DayNightMode: String, CaseIterable, Sendable, Identifiable {
    /// The camera decides from ambient light (default).
    case auto
    /// Always colour.
    case color
    /// Always monochrome.
    case blackAndWhite

    public var id: String { rawValue }
}

public struct LEDState: Sendable, Equatable {
    public var infrared: InfraredMode
    /// The blue status LED on the front.
    public var statusLight: Bool
}

public struct DeviceInfo: Sendable {
    public var fields: [(String, String)]
    public var rawXML: String

    public subscript(name: String) -> String? {
        fields.first { $0.0 == name }?.1
    }

    public var summary: String {
        let interesting = ["type", "name", "firmVer", "hardwareVersion", "serialNumber", "channelNum"]
        return interesting.compactMap { key in self[key].map { "\(key)=\($0)" } }.joined(separator: " ")
    }
}

/// High-level client for one Reolink camera over the Baichuan protocol.
public actor BaichuanCamera {
    public let host: String
    public let port: UInt16
    public let username: String
    private let password: String
    public let channelId: UInt8

    private var connection: BCConnection?
    private var videoTask: Task<Void, Never>?
    public private(set) var deviceInfo: DeviceInfo?
    public var log: (@Sendable (String) -> Void)?
    public var logPackets = false

    public init(host: String, port: UInt16 = 9000, username: String = "admin", password: String, channelId: UInt8 = 0) {
        self.host = host
        self.port = port
        self.username = username
        self.password = password
        self.channelId = channelId
    }

    public var isConnected: Bool {
        get async { await connection?.isOpen ?? false }
    }

    public var encryption: BCEncryption? {
        get async { await connection?.encryption }
    }

    public var lastReceiveTime: Date? {
        get async { await connection?.lastReceiveTime }
    }

    // MARK: Connect / login

    /// Opens the TCP connection and logs in.
    @discardableResult
    public func connect() async throws -> DeviceInfo {
        await disconnect()
        let conn = BCConnection(host: host, port: port, password: password)
        if logPackets, let log { await conn.setLog(log) }
        try await conn.connect()
        // The camera occasionally pings us; answer so it keeps the session.
        await conn.setHandler(msgId: BCMsgID.udpKeepAlive) { m in
            BCMessage(msgId: BCMsgID.udpKeepAlive, channelId: m.channelId, streamType: m.streamType,
                      msgNum: m.msgNum, responseCode: 200)
        }
        connection = conn
        do {
            let info = try await login(conn)
            deviceInfo = info
            return info
        } catch {
            await conn.close()
            connection = nil
            throw error
        }
    }

    public func disconnect() async {
        videoTask?.cancel()
        videoTask = nil
        if let conn = connection {
            await conn.close()
        }
        connection = nil
    }

    private func login(_ conn: BCConnection) async throws -> DeviceInfo {
        let num = await conn.nextMessageNumber()
        let sub = await conn.subscribe(num)
        defer { Task { await conn.unsubscribe(num) } }

        // 1. Legacy "login upgrade": header only; responseCode asks for the strongest encryption (AES).
        try await conn.send(BCMessage(msgId: BCMsgID.login, channelId: channelId, msgNum: num,
                                      responseCode: 0xDC12, msgClass: BCHeader.classLegacy))
        let nonceReply = try await sub.next(timeout: 5)
        guard let xml = nonceReply.xml, let reader = try? XMLReader(xml),
              let nonce = reader.string("/body/Encryption/nonce") else {
            throw BCError.unexpectedReply(msgId: nonceReply.msgId, code: nonceReply.responseCode,
                                          why: "expected an Encryption nonce")
        }
        log?("nonce received, encryption \(await conn.encryption.name)")

        // 2. Modern login: MD5(username + nonce), MD5(password + nonce), both truncated to 31 hex chars.
        let userHash = BCCrypto.truncatedMD5(username + nonce)
        let passHash = BCCrypto.truncatedMD5(password + nonce)
        try await conn.send(BCMessage(msgId: BCMsgID.login, channelId: channelId, msgNum: num,
                                      payload: .xml(BCXML.login(userHash: userHash, passwordHash: passHash))))
        let reply = try await sub.next(timeout: 5)
        guard reply.responseCode == 200 else { throw BCError.loginFailed(code: reply.responseCode) }
        guard let infoXML = reply.xml, let infoReader = try? XMLReader(infoXML) else {
            if reply.payload == nil && reply.extensionXML == nil { throw BCError.loginFailed(code: reply.responseCode) }
            throw BCError.unexpectedReply(msgId: reply.msgId, code: reply.responseCode, why: "expected DeviceInfo")
        }
        var fields = infoReader.children("/body/DeviceInfo")
        for (name, value) in infoReader.children("/body/DeviceInfo/resolution") {
            fields.append(("resolution." + name, value))
        }
        return DeviceInfo(fields: fields, rawXML: infoXML)
    }

    private func requireConnection() throws -> BCConnection {
        guard let conn = connection else { throw BCError.notConnected }
        return conn
    }

    // MARK: Simple commands

    public func ping() async throws {
        let conn = try requireConnection()
        let num = await conn.nextMessageNumber()
        let sub = await conn.subscribe(num)
        defer { Task { await conn.unsubscribe(num) } }
        try await conn.send(BCMessage(msgId: BCMsgID.ping, channelId: channelId, msgNum: num))
        _ = try await sub.next(timeout: 5)
    }

    /// Starts moving in `direction` at `speed` (32 is what the official client uses).
    /// Movement continues until `.stop` is sent.
    public func ptz(_ direction: PTZDirection, speed: Float = 32) async throws {
        let conn = try requireConnection()
        let num = await conn.nextMessageNumber()
        let sub = await conn.subscribe(num)
        defer { Task { await conn.unsubscribe(num) } }
        let msg = BCMessage(msgId: BCMsgID.ptzControl, channelId: channelId, msgNum: num,
                            extensionXML: BCXML.extensionDocument(channelId: channelId),
                            payload: .xml(BCXML.ptzControl(channelId: channelId, speed: speed, command: direction.rawValue)))
        try await conn.send(msg)
        let reply = try await sub.next(timeout: 5)
        guard reply.responseCode == 200 else {
            throw BCError.unexpectedReply(msgId: reply.msgId, code: reply.responseCode, why: "PTZ command rejected")
        }
    }

    // MARK: LEDs

    public func getLEDState() async throws -> LEDState {
        let conn = try requireConnection()
        let num = await conn.nextMessageNumber()
        let sub = await conn.subscribe(num)
        defer { Task { await conn.unsubscribe(num) } }
        try await conn.send(BCMessage(msgId: BCMsgID.getLEDState, channelId: channelId, msgNum: num,
                                      extensionXML: BCXML.extensionDocument(channelId: channelId)))
        let reply = try await sub.next(timeout: 5)
        guard reply.responseCode == 200, let xml = reply.xml, let reader = try? XMLReader(xml),
              let state = reader.string("/body/LedState/state"), let mode = InfraredMode(wireValue: state) else {
            throw BCError.unexpectedReply(msgId: reply.msgId, code: reply.responseCode, why: "expected LedState")
        }
        return LEDState(infrared: mode, statusLight: reader.string("/body/LedState/lightState") != "close")
    }

    public func setLEDState(_ state: LEDState) async throws {
        let conn = try requireConnection()
        let num = await conn.nextMessageNumber()
        let sub = await conn.subscribe(num)
        defer { Task { await conn.unsubscribe(num) } }
        let xml = BCXML.ledState(channelId: channelId, state: state.infrared.wireValue,
                                 lightState: state.statusLight ? "open" : "close")
        try await conn.send(BCMessage(msgId: BCMsgID.setLEDState, channelId: channelId, msgNum: num,
                                      extensionXML: BCXML.extensionDocument(channelId: channelId), payload: .xml(xml)))
        // Some firmware does not acknowledge; treat silence as success like the official client does.
        guard let reply = try? await sub.next(timeout: 1) else { return }
        guard reply.responseCode == 200 else {
            throw BCError.unexpectedReply(msgId: reply.msgId, code: reply.responseCode, why: "LED state rejected")
        }
    }

    /// Sets the infrared mode, keeping the status-LED setting as it is.
    public func setInfrared(_ mode: InfraredMode) async throws {
        var state = try await getLEDState()
        state.infrared = mode
        try await setLEDState(state)
    }

    // MARK: Day & Night (ISP configuration)

    /// The camera's full ISP configuration XML (VideoInput + InputAdvanceCfg).
    private func getISPConfigXML() async throws -> String {
        let conn = try requireConnection()
        let num = await conn.nextMessageNumber()
        let sub = await conn.subscribe(num)
        defer { Task { await conn.unsubscribe(num) } }
        try await conn.send(BCMessage(msgId: BCMsgID.getISP, channelId: channelId, msgNum: num,
                                      extensionXML: BCXML.extensionDocument(channelId: channelId)))
        let reply = try await sub.next(timeout: 5)
        guard reply.responseCode == 200, let xml = reply.xml, let end = xml.lastIndex(of: ">") else {
            throw BCError.unexpectedReply(msgId: reply.msgId, code: reply.responseCode, why: "expected ISP configuration")
        }
        return String(xml[...end])
    }

    public func getDayNightMode() async throws -> DayNightMode {
        let xml = try await getISPConfigXML()
        guard let value = try XMLReader(xml).string("/body/InputAdvanceCfg/DayNight/mode"),
              let mode = DayNightMode(rawValue: value) else {
            throw BCError.malformedXML("no DayNight mode in ISP configuration")
        }
        return mode
    }

    /// Reads the ISP configuration, changes only the DayNight mode, and writes it back.
    public func setDayNightMode(_ mode: DayNightMode) async throws {
        let xml = try await getISPConfigXML()
        guard let updated = ISPConfig.replacingDayNightMode(in: xml, with: mode) else {
            throw BCError.malformedXML("no DayNight mode in ISP configuration")
        }

        let conn = try requireConnection()
        let num = await conn.nextMessageNumber()
        let sub = await conn.subscribe(num)
        defer { Task { await conn.unsubscribe(num) } }
        try await conn.send(BCMessage(msgId: BCMsgID.setISP, channelId: channelId, msgNum: num,
                                      extensionXML: BCXML.extensionDocument(channelId: channelId), payload: .xml(updated)))
        guard let reply = try? await sub.next(timeout: 2) else { return }
        guard reply.responseCode == 200 else {
            throw BCError.unexpectedReply(msgId: reply.msgId, code: reply.responseCode, why: "ISP configuration rejected")
        }
    }

    // MARK: Video

    /// Starts the live stream. Frames arrive on the returned stream until it is cancelled,
    /// `stopVideo()` is called, or the connection drops. Only one stream at a time.
    public func startVideo(_ kind: StreamKind) async throws -> AsyncThrowingStream<BCMediaFrame, Error> {
        let conn = try requireConnection()
        await stopVideo()
        let num = await conn.nextMessageNumber()
        let sub = await conn.subscribe(num)
        let start = BCMessage(msgId: BCMsgID.video, channelId: channelId, streamType: kind.streamTypeByte, msgNum: num,
                              payload: .xml(BCXML.preview(channelId: channelId, handle: kind.handle, streamName: kind.streamName)))
        do {
            try await conn.send(start)
            let ack = try await sub.next(timeout: 5)
            guard ack.responseCode == 200 else {
                throw BCError.unexpectedReply(msgId: ack.msgId, code: ack.responseCode, why: "camera refused to start the stream")
            }
        } catch {
            await conn.unsubscribe(num)
            throw error
        }

        let (stream, continuation) = AsyncThrowingStream<BCMediaFrame, Error>.makeStream(bufferingPolicy: .unbounded)
        let channelId = self.channelId
        let task = Task {
            var parser = BCMediaParser()
            do {
                while !Task.isCancelled {
                    let m = try await sub.next()
                    guard let bytes = m.binary else { continue }
                    parser.append(bytes)
                    while let frame = try parser.next() {
                        continuation.yield(frame)
                    }
                }
            } catch {
                if !Task.isCancelled { continuation.finish(throwing: error) }
            }
            // Tell the camera to stop and give it a moment to acknowledge.
            let stop = BCMessage(msgId: BCMsgID.videoStop, channelId: channelId, streamType: kind.streamTypeByte, msgNum: num,
                                 payload: .xml(BCXML.preview(channelId: channelId, handle: kind.handle, streamName: nil)))
            if (try? await conn.send(stop)) != nil {
                let deadline = Date().addingTimeInterval(2)
                while Date() < deadline {
                    guard let reply = try? await sub.next(timeout: max(0.05, deadline.timeIntervalSinceNow)) else { break }
                    if reply.msgId == BCMsgID.videoStop { break }
                }
            }
            await conn.unsubscribe(num)
            continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
        videoTask = task
        return stream
    }

    /// Stops the current stream, if any, and waits for the camera's acknowledgement.
    public func stopVideo() async {
        guard let task = videoTask else { return }
        videoTask = nil
        task.cancel()
        _ = await task.value
    }
}

extension BCConnection {
    func setLog(_ log: @escaping @Sendable (String) -> Void) {
        self.log = log
    }
}

extension BaichuanCamera {
    public func setLog(_ log: (@Sendable (String) -> Void)?) {
        self.log = log
    }

    public func setLogPackets(_ on: Bool) {
        logPackets = on
    }
}

enum ISPConfig {
    /// Replaces the text of `<DayNight><mode>…</mode>` and leaves every other byte untouched,
    /// so the configuration can be sent back exactly as the camera produced it.
    static func replacingDayNightMode(in xml: String, with mode: DayNightMode) -> String? {
        guard let dayNight = xml.range(of: "<DayNight>"),
              let dayNightEnd = xml.range(of: "</DayNight>", range: dayNight.upperBound..<xml.endIndex),
              let modeStart = xml.range(of: "<mode>", range: dayNight.upperBound..<dayNightEnd.lowerBound),
              let modeEnd = xml.range(of: "</mode>", range: modeStart.upperBound..<dayNightEnd.lowerBound) else {
            return nil
        }
        return xml.replacingCharacters(in: modeStart.upperBound..<modeEnd.lowerBound, with: mode.rawValue)
    }
}
