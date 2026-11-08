import Foundation

/// Known message ids.
public enum BCMsgID {
    public static let login: UInt32 = 1
    public static let logout: UInt32 = 2
    public static let video: UInt32 = 3
    public static let videoStop: UInt32 = 4
    public static let ptzControl: UInt32 = 18
    public static let setISP: UInt32 = 25
    /// Writes the `ServerPort` document (HTTP/HTTPS/RTSP/RTMP/ONVIF ports and switches); 37 reads it.
    public static let setServerPorts: UInt32 = 36
    public static let getServerPorts: UInt32 = 37
    /// Reads the on-screen display settings (`Osd` with `OsdChannelName`); 45 writes them back.
    public static let getOSD: UInt32 = 44
    public static let setOSD: UInt32 = 45
    public static let getISP: UInt32 = 26
    /// Returns the user list (and, on some firmware, more system information).
    public static let getUsers: UInt32 = 58
    /// Adds, modifies or deletes users; the whole list is sent each time.
    public static let updateUserList: UInt32 = 59
    public static let ping: UInt32 = 93
    public static let getLEDState: UInt32 = 208
    public static let setLEDState: UInt32 = 209
    public static let udpKeepAlive: UInt32 = 234
    /// Switches the white spotlight on or off for a while.
    public static let floodlightManual: UInt32 = 288
    /// Sent by the camera whenever the spotlight goes on or off.
    public static let floodlightStatusList: UInt32 = 291
    /// Reads the spotlight's automatic settings; only cameras with a spotlight answer with 200.
    public static let floodlightTasksRead: UInt32 = 438
}

/// A decoded (or to-be-encoded) Baichuan message.
public struct BCMessage: Sendable {
    public enum Payload: Sendable {
        case xml(String)
        case binary(Data)
    }

    public var msgId: UInt32
    public var channelId: UInt8
    public var streamType: UInt8
    public var msgNum: UInt16
    public var responseCode: UInt16
    public var msgClass: UInt16
    /// Decrypted extension XML, if present.
    public var extensionXML: String?
    /// Decrypted XML or raw binary payload, if present.
    public var payload: Payload?

    public init(msgId: UInt32, channelId: UInt8 = 0, streamType: UInt8 = 0, msgNum: UInt16,
                responseCode: UInt16 = 0, msgClass: UInt16 = BCHeader.classModern,
                extensionXML: String? = nil, payload: Payload? = nil) {
        self.msgId = msgId
        self.channelId = channelId
        self.streamType = streamType
        self.msgNum = msgNum
        self.responseCode = responseCode
        self.msgClass = msgClass
        self.extensionXML = extensionXML
        self.payload = payload
    }

    public var xml: String? {
        if case .xml(let s)? = payload { return s }
        return nil
    }

    public var binary: Data? {
        if case .binary(let d)? = payload { return d }
        return nil
    }

    public var isOK: Bool { responseCode == 200 }
}
