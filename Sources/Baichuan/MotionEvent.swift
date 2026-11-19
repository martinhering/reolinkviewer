import Foundation

/// One entry of the `AlarmEventList` the camera pushes (message 33) once motion events have
/// been requested (message 31). Ids and field names from Neolink and reolink_aio.
public struct MotionEvent: Sendable, Equatable {
    public var channelId: UInt8
    /// `MD` while the camera's motion detector fires, `none` when it stops.
    public var status: String
    /// What the camera's object detection recognised: `people`, `vehicle`, `dog_cat`, …;
    /// `none` or absent otherwise.
    public var aiType: String?
    /// Whether the camera is recording to its own storage.
    public var recording: Bool?

    public init(channelId: UInt8, status: String, aiType: String? = nil, recording: Bool? = nil) {
        self.channelId = channelId
        self.status = status
        self.aiType = aiType
        self.recording = recording
    }

    /// The recognised object, or nil when object detection reports nothing.
    public var detectedObject: String? {
        guard let aiType, !aiType.isEmpty, aiType != "none" else { return nil }
        return aiType
    }

    /// True while the motion detector or the object detection reports something.
    public var isMotion: Bool {
        (!status.isEmpty && status != "none") || detectedObject != nil
    }

    /// Parses the `AlarmEventList` of a message-33 push. Entries without a channel get `defaultChannel`.
    static func parseList(_ xml: String, defaultChannel: UInt8 = 0) -> [MotionEvent] {
        guard let reader = try? XMLReader(xml) else { return [] }
        return reader.childrenOfEach("/body/AlarmEventList/AlarmEvent").compactMap { fields in
            func value(_ name: String) -> String? { fields.first { $0.0 == name }?.1 }
            guard let status = value("status") else { return nil }
            return MotionEvent(channelId: value("channelId").flatMap { UInt8($0) } ?? defaultChannel,
                               status: status, aiType: value("AItype"),
                               recording: value("recording").flatMap { Int($0) }.map { $0 != 0 })
        }
    }
}

extension BaichuanCamera {
    /// Called for every motion event the camera pushes for this channel. Survives reconnects,
    /// but the camera only pushes after `startMotionEvents()` on the current connection.
    public func setMotionHandler(_ handler: (@Sendable (MotionEvent) -> Void)?) {
        motionHandler = handler
    }

    /// Asks the camera to push motion events on this connection (message 31). Throws when the
    /// camera refuses or does not answer; a camera that accepts may still never push one.
    public func startMotionEvents() async throws {
        let conn = try requireConnection()
        let num = await conn.nextMessageNumber()
        let sub = await conn.subscribe(num)
        defer { Task { await conn.unsubscribe(num) } }
        try await conn.send(BCMessage(msgId: BCMsgID.motionRequest, channelId: channelId, msgNum: num))
        let reply = try await sub.next(timeout: 5)
        guard reply.responseCode == 200 else {
            throw BCError.unexpectedReply(msgId: reply.msgId, code: reply.responseCode, why: "camera refused to push motion events")
        }
    }

    /// Installed on every connection before login, like the spotlight handler.
    func installMotionHandler(on conn: BCConnection) async {
        let channelId = self.channelId
        let log = logPackets ? self.log : nil
        await conn.setHandler(msgId: BCMsgID.motion) { @Sendable [weak self] m in
            log?("motion: \(m.xml ?? "(no XML)")")
            guard let xml = m.xml else { return nil }
            let events = MotionEvent.parseList(xml, defaultChannel: channelId).filter { $0.channelId == channelId }
            if !events.isEmpty {
                Task { await self?.motionReported(events) }
            }
            return nil
        }
    }

    private func motionReported(_ events: [MotionEvent]) {
        guard let motionHandler else { return }
        for event in events { motionHandler(event) }
    }
}
