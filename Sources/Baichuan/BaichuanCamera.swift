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

/// A network service the camera can offer besides its own protocol.
public enum CameraService: String, CaseIterable, Sendable, Identifiable {
    case http, https, rtsp, rtmp, onvif
    public var id: String { rawValue }
    public var displayName: String { rawValue == "onvif" ? "ONVIF" : rawValue.uppercased() }

    /// What switching the service on gets you, for tooltips.
    public var purpose: String {
        switch self {
        case .http: return "The camera's web interface and HTTP API, unencrypted"
        case .https: return "The camera's web interface and HTTP API over TLS"
        case .rtsp: return "Let players such as VLC or an NVR pull the video stream over RTSP"
        case .rtmp: return "Let streaming software pull the video over RTMP"
        case .onvif: return "Let other software (Home Assistant, Synology, …) find and stream this camera over ONVIF"
        }
    }
}

/// Whether one of the camera's network services is switched on, and on which port.
public struct CameraServiceState: Sendable, Equatable {
    public var enabled: Bool
    public var port: Int?
    public init(enabled: Bool, port: Int? = nil) {
        self.enabled = enabled
        self.port = port
    }
}

/// One entry of the camera's user list.
public struct CameraUser: Sendable, Equatable {
    /// What message 59 should do with this entry.
    public enum SetState: String, Sendable {
        case none, add, delete, modify
    }

    public var userName: String
    /// Only sent when adding or modifying; the camera never returns it.
    public var password: String?
    public var userId: Int?
    /// 0 = user, 1 = administrator.
    public var userLevel: Int
    /// 1 for the user of the current session, as far as is known.
    public var loginState: Int?
    public var setState: SetState = .none

    public var isAdministrator: Bool { userLevel == 1 }

    public init(userName: String, password: String? = nil, userId: Int? = nil, userLevel: Int,
                loginState: Int? = nil, setState: SetState = .none) {
        self.userName = userName
        self.password = password
        self.userId = userId
        self.userLevel = userLevel
        self.loginState = loginState
        self.setState = setState
    }

    /// Parses the `UserList` of a message-58 reply.
    static func parseList(_ xml: String) throws -> [CameraUser] {
        let reader = try XMLReader(xml)
        return reader.childrenOfEach("/body/UserList/User").compactMap { fields in
            func value(_ name: String) -> String? { fields.first { $0.0 == name }?.1 }
            guard let name = value("userName"), !name.isEmpty else { return nil }
            return CameraUser(userName: name, userId: value("userId").flatMap { Int($0) },
                              userLevel: value("userLevel").flatMap { Int($0) } ?? 0,
                              loginState: value("loginState").flatMap { Int($0) })
        }
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
    private var spotlightHandler: (@Sendable (Bool) -> Void)?
    /// The spotlight state the camera last reported (message 291); nil until it reports one.
    /// Cameras with a spotlight send it unasked right after login.
    public private(set) var spotlightState: Bool?
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
        spotlightState = nil
        let conn = BCConnection(host: host, port: port, password: password)
        if logPackets, let log { await conn.setLog(log) }
        try await conn.connect()
        // The camera occasionally pings us; answer so it keeps the session.
        await conn.setHandler(msgId: BCMsgID.udpKeepAlive) { m in
            BCMessage(msgId: BCMsgID.udpKeepAlive, channelId: m.channelId, streamType: m.streamType,
                      msgNum: m.msgNum, responseCode: 200)
        }
        connection = conn
        await installSpotlightHandler(on: conn)
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

    /// Switches the blue status LED on the front, keeping the infrared mode as it is.
    public func setStatusLight(_ on: Bool) async throws {
        var state = try await getLEDState()
        state.statusLight = on
        try await setLEDState(state)
    }

    // MARK: Spotlight

    /// The camera's answer to the spotlight settings request (message 438).
    public struct SpotlightProbe: Sendable {
        /// nil when the camera did not answer within the timeout.
        public var replyCode: UInt16?
        public var xml: String?
        /// Code 200 with a `FloodlightTask` document.
        public var hasSettings: Bool { replyCode == 200 && (xml?.contains("<FloodlightTask") ?? false) }
    }

    public func probeSpotlight() async -> SpotlightProbe {
        guard let conn = connection else { return SpotlightProbe() }
        let num = await conn.nextMessageNumber()
        let sub = await conn.subscribe(num)
        defer { Task { await conn.unsubscribe(num) } }
        do {
            try await conn.send(BCMessage(msgId: BCMsgID.floodlightTasksRead, channelId: channelId, msgNum: num,
                                          extensionXML: BCXML.extensionDocument(channelId: channelId)))
            let reply = try await sub.next(timeout: 3)
            return SpotlightProbe(replyCode: reply.responseCode, xml: reply.xml)
        } catch {
            return SpotlightProbe()
        }
    }

    /// Whether the camera has a white spotlight: it either answers the spotlight settings
    /// request (message 438) with a `FloodlightTask`, or reports a spotlight status of its own
    /// after login. Some firmware refuses 438 (code 405) but does the latter, so this waits up
    /// to `wait` seconds after the probe for that report.
    public func hasSpotlight(wait: TimeInterval = 1.5) async -> Bool {
        if await probeSpotlight().hasSettings { return true }
        let deadline = Date().addingTimeInterval(wait)
        while spotlightState == nil, Date() < deadline, connection != nil {
            try? await Task.sleep(for: .milliseconds(100))
        }
        return spotlightState != nil
    }

    /// Switches the spotlight on or off (message 288). The camera holds the setting for
    /// `duration` seconds and then returns to its automatic behaviour.
    public func setSpotlight(_ on: Bool, duration: UInt16 = 180) async throws {
        let conn = try requireConnection()
        let num = await conn.nextMessageNumber()
        let sub = await conn.subscribe(num)
        defer { Task { await conn.unsubscribe(num) } }
        try await conn.send(BCMessage(msgId: BCMsgID.floodlightManual, channelId: channelId, msgNum: num,
                                      extensionXML: BCXML.extensionDocument(channelId: channelId),
                                      payload: .xml(BCXML.floodlightManual(channelId: channelId, on: on, duration: duration))))
        // Some cameras do not acknowledge a successful change.
        guard let reply = try? await sub.next(timeout: 1) else { return }
        guard reply.responseCode == 200 else {
            throw BCError.unexpectedReply(msgId: reply.msgId, code: reply.responseCode, why: "spotlight command rejected")
        }
    }

    /// Called with the new state whenever the camera reports that its spotlight went on or
    /// off (message 291), including when a manual setting runs out. Survives reconnects.
    public func setSpotlightHandler(_ handler: (@Sendable (Bool) -> Void)?) {
        spotlightHandler = handler
    }

    /// Installed on every connection before login, so the report the camera sends right
    /// after login is not lost.
    private func installSpotlightHandler(on conn: BCConnection) async {
        let channelId = self.channelId
        let log = logPackets ? self.log : nil
        await conn.setHandler(msgId: BCMsgID.floodlightStatusList) { @Sendable [weak self] m in
            log?("spotlight status: \(m.xml ?? "(no XML)")")
            if let xml = m.xml, let on = SpotlightStatus.parse(xml, channelId: channelId) {
                Task { await self?.spotlightReported(on) }
            }
            return nil
        }
    }

    private func spotlightReported(_ on: Bool) {
        spotlightState = on
        spotlightHandler?(on)
    }

    // MARK: On-screen display

    /// The camera's OSD configuration XML (channel name and time stamp overlays).
    public func getOSDConfigXML() async throws -> String {
        let conn = try requireConnection()
        let num = await conn.nextMessageNumber()
        let sub = await conn.subscribe(num)
        defer { Task { await conn.unsubscribe(num) } }
        try await conn.send(BCMessage(msgId: BCMsgID.getOSD, channelId: channelId, msgNum: num,
                                      extensionXML: BCXML.extensionDocument(channelId: channelId)))
        let reply = try await sub.next(timeout: 5)
        guard reply.responseCode == 200, let xml = reply.xml, let end = xml.lastIndex(of: ">") else {
            throw BCError.unexpectedReply(msgId: reply.msgId, code: reply.responseCode, why: "expected OSD configuration")
        }
        return String(xml[...end])
    }

    /// The name the camera burns into the picture.
    public func getOSDName() async throws -> String {
        let xml = try await getOSDConfigXML()
        guard let name = OSDConfig.name(in: xml) else { throw BCError.malformedXML("no OsdChannelName in OSD configuration") }
        return name
    }

    /// Reads the OSD configuration, changes only the channel name, and writes it back.
    public func setOSDName(_ name: String) async throws {
        let xml = try await getOSDConfigXML()
        guard let updated = OSDConfig.replacingName(in: xml, with: name) else {
            throw BCError.malformedXML("no OsdChannelName in OSD configuration")
        }
        let conn = try requireConnection()
        let num = await conn.nextMessageNumber()
        let sub = await conn.subscribe(num)
        defer { Task { await conn.unsubscribe(num) } }
        try await conn.send(BCMessage(msgId: BCMsgID.setOSD, channelId: channelId, msgNum: num,
                                      extensionXML: BCXML.extensionDocument(channelId: channelId), payload: .xml(updated)))
        guard let reply = try? await sub.next(timeout: 2) else { return }
        guard reply.responseCode == 200 else {
            throw BCError.unexpectedReply(msgId: reply.msgId, code: reply.responseCode, why: "OSD configuration rejected")
        }
    }

    // MARK: Network services (ServerPort configuration)

    /// The camera's port configuration XML: `ServerPort` (its own Baichuan port) plus `HttpPort`,
    /// `HttpsPort`, `RtspPort`, `RtmpPort` and `OnvifPort`, each with a port number and an `enable` switch.
    public func getServerPortsXML() async throws -> String {
        let conn = try requireConnection()
        let num = await conn.nextMessageNumber()
        let sub = await conn.subscribe(num)
        defer { Task { await conn.unsubscribe(num) } }
        try await conn.send(BCMessage(msgId: BCMsgID.getServerPorts, channelId: channelId, msgNum: num))
        let reply = try await sub.next(timeout: 5)
        guard reply.responseCode == 200, let xml = reply.xml, let end = xml.lastIndex(of: ">") else {
            throw BCError.unexpectedReply(msgId: reply.msgId, code: reply.responseCode, why: "expected port configuration")
        }
        return String(xml[...end])
    }

    /// The state of every network service the camera reports.
    public func getServices() async throws -> [CameraService: CameraServiceState] {
        let xml = try await getServerPortsXML()
        let services = try ServerPortConfig.services(in: xml)
        guard !services.isEmpty else {
            throw BCError.malformedXML("no service ports in the reply to message 37; the camera sent: \(xml.prefix(600))")
        }
        return services
    }

    /// Reads the port configuration, flips only `service`'s `enable`, and writes it back.
    public func setService(_ service: CameraService, enabled: Bool) async throws {
        let xml = try await getServerPortsXML()
        guard let updated = ServerPortConfig.replacingEnabled(of: service, in: xml, with: enabled) else {
            throw BCError.malformedXML("no \(ServerPortConfig.element(for: service)) element in the port configuration")
        }
        let conn = try requireConnection()
        let num = await conn.nextMessageNumber()
        let sub = await conn.subscribe(num)
        defer { Task { await conn.unsubscribe(num) } }
        try await conn.send(BCMessage(msgId: BCMsgID.setServerPorts, channelId: channelId, msgNum: num, payload: .xml(updated)))
        guard let reply = try? await sub.next(timeout: 2) else { return }
        guard reply.responseCode == 200 else {
            throw BCError.unexpectedReply(msgId: reply.msgId, code: reply.responseCode, why: "port configuration rejected")
        }
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

    // MARK: Users

    /// The camera's user accounts (message 58).
    public func getUsers() async throws -> [CameraUser] {
        let conn = try requireConnection()
        let num = await conn.nextMessageNumber()
        let sub = await conn.subscribe(num)
        defer { Task { await conn.unsubscribe(num) } }
        try await conn.send(BCMessage(msgId: BCMsgID.getUsers, channelId: channelId, msgNum: num,
                                      extensionXML: BCXML.extensionDocument(userName: username)))
        let reply = try await sub.next(timeout: 5)
        guard reply.responseCode == 200, let xml = reply.xml else {
            throw BCError.unexpectedReply(msgId: reply.msgId, code: reply.responseCode, why: "expected UserList")
        }
        let users = try CameraUser.parseList(xml)
        guard !users.isEmpty else {
            throw BCError.unexpectedReply(msgId: reply.msgId, code: reply.responseCode, why: "reply has no UserList")
        }
        return users
    }

    /// Sends the whole user list back (message 59). Entries with `setState == .none` are left alone.
    public func updateUsers(_ users: [CameraUser]) async throws {
        let conn = try requireConnection()
        let num = await conn.nextMessageNumber()
        let sub = await conn.subscribe(num)
        defer { Task { await conn.unsubscribe(num) } }
        try await conn.send(BCMessage(msgId: BCMsgID.updateUserList, channelId: channelId, msgNum: num,
                                      payload: .xml(BCXML.userList(users))))
        // Some cameras do not acknowledge a successful change.
        guard let reply = try? await sub.next(timeout: 2) else { return }
        guard reply.responseCode == 200 else {
            throw BCError.unexpectedReply(msgId: reply.msgId, code: reply.responseCode, why: "user list change rejected")
        }
    }

    /// Changes the password of `userName` (default: the logged-in user). The current session
    /// may stay up, but every new login needs the new password.
    public func changePassword(to newPassword: String, for userName: String? = nil) async throws {
        let target = userName ?? username
        var users = try await getUsers()
        guard let index = users.firstIndex(where: { $0.userName == target }) else {
            throw BCError.unexpectedReply(msgId: BCMsgID.getUsers, code: 200, why: "no user named \(target)")
        }
        users[index].password = newPassword
        users[index].setState = .modify
        try await updateUsers(users)
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

enum SpotlightStatus {
    /// The state for `channelId` in a `FloodlightStatusList`, or nil if it has none.
    static func parse(_ xml: String, channelId: UInt8) -> Bool? {
        guard let reader = try? XMLReader(xml) else { return nil }
        for fields in reader.childrenOfEach("/body/FloodlightStatusList/FloodlightStatus") {
            func value(_ name: String) -> String? { fields.first { $0.0 == name }?.1 }
            guard value("channel").flatMap({ UInt8($0) }) ?? channelId == channelId,
                  let status = value("status").flatMap({ Int($0) }) else { continue }
            return status != 0
        }
        return nil
    }
}

enum OSDConfig {
    private static func nameRange(in xml: String) -> Range<String.Index>? {
        // The element carries a version attribute: <OsdChannelName version="1.1">.
        guard let start = xml.range(of: "<OsdChannelName"),
              let end = xml.range(of: "</OsdChannelName>", range: start.upperBound..<xml.endIndex),
              let nameStart = xml.range(of: "<name>", range: start.upperBound..<end.lowerBound),
              let nameEnd = xml.range(of: "</name>", range: nameStart.upperBound..<end.lowerBound) else { return nil }
        return nameStart.upperBound..<nameEnd.lowerBound
    }

    static func name(in xml: String) -> String? {
        nameRange(in: xml).map { BCXML.unescape(String(xml[$0])) }
    }

    /// Replaces the text of `<OsdChannelName><name>…</name>` and leaves every other byte
    /// untouched, so the configuration goes back exactly as the camera produced it.
    static func replacingName(in xml: String, with name: String) -> String? {
        nameRange(in: xml).map { xml.replacingCharacters(in: $0, with: BCXML.escape(name)) }
    }
}

enum ServerPortConfig {
    /// The element holding one service: `<OnvifPort version="1.1"><onvifPort>8000</onvifPort><enable>0</enable></OnvifPort>`.
    static func element(for service: CameraService) -> String {
        service.rawValue.prefix(1).uppercased() + service.rawValue.dropFirst() + "Port"
    }

    /// Every service the document has an element for. (`ServerPort` itself is the camera's own
    /// Baichuan port and is left alone.)
    static func services(in xml: String) throws -> [CameraService: CameraServiceState] {
        let reader = try XMLReader(xml)
        var out: [CameraService: CameraServiceState] = [:]
        for service in CameraService.allCases {
            let element = element(for: service)
            guard let enable = reader.int("/body/\(element)/enable") else { continue }
            out[service] = CameraServiceState(enabled: enable != 0, port: reader.int("/body/\(element)/\(service.rawValue)Port"))
        }
        return out
    }

    /// Replaces the text of the service element's `<enable>` and leaves every other byte
    /// untouched, so the configuration goes back exactly as the camera produced it.
    static func replacingEnabled(of service: CameraService, in xml: String, with enabled: Bool) -> String? {
        // The element carries a version attribute: <OnvifPort version="1.1">.
        let element = element(for: service)
        guard let start = xml.range(of: "<\(element)"),
              let end = xml.range(of: "</\(element)>", range: start.upperBound..<xml.endIndex),
              let valueStart = xml.range(of: "<enable>", range: start.upperBound..<end.lowerBound),
              let valueEnd = xml.range(of: "</enable>", range: valueStart.upperBound..<end.lowerBound) else { return nil }
        return xml.replacingCharacters(in: valueStart.upperBound..<valueEnd.lowerBound, with: enabled ? "1" : "0")
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
