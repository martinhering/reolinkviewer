import XCTest
@testable import Baichuan

final class HeaderTests: XCTestCase {
    func testRoundTripModern() throws {
        let h = BCHeader(msgId: 3, bodyLength: 1234, channelId: 0, streamType: 1, msgNum: 7,
                         responseCode: 200, msgClass: 0x6414, payloadOffset: 56)
        let data = h.encode()
        XCTAssertEqual(data.count, 24)
        XCTAssertEqual([UInt8](data.prefix(4)), [0xF0, 0xDE, 0xBC, 0x0A])
        XCTAssertEqual(try BCHeader.decode(data), h)
    }

    func testRoundTripLegacy() throws {
        let h = BCHeader(msgId: 1, bodyLength: 0, channelId: 0, streamType: 0, msgNum: 0,
                         responseCode: 0xDC12, msgClass: 0x6514, payloadOffset: nil)
        let data = h.encode()
        XCTAssertEqual(data.count, 20)
        XCTAssertEqual(try BCHeader.decode(data), h)
        XCTAssertFalse(h.isModern)
    }

    func testRejectsBadMagic() {
        var data = BCHeader(msgId: 1, bodyLength: 0, channelId: 0, streamType: 0, msgNum: 0,
                            responseCode: 0, msgClass: 0x6414, payloadOffset: 0).encode()
        data[0] = 0
        XCTAssertThrowsError(try BCHeader.decode(data))
    }
}

final class CryptoTests: XCTestCase {
    func testTruncatedMD5MatchesCamera() {
        // Reference value from the Neolink test-suite: MD5("admin") uppercased, 31 characters.
        XCTAssertEqual(BCCrypto.truncatedMD5("admin"), "21232F297A57A5A743894A0E4A801FC")
    }

    func testXorRoundTrip() {
        let plain = Data((0..<256).map { UInt8($0) })
        let enc = BCCrypto.xor(offset: 0, plain)
        XCTAssertNotEqual(enc, plain)
        XCTAssertEqual(BCCrypto.xor(offset: 0, enc), plain)
        XCTAssertEqual(BCCrypto.xor(offset: 3, BCCrypto.xor(offset: 3, plain)), plain)
    }

    func testXorKeySchedule() {
        // Byte 0 with offset 0: 0x00 ^ key[0] ^ 0 = 0x1F
        XCTAssertEqual(BCCrypto.xor(offset: 0, Data([0, 0]))[0], 0x1F)
        XCTAssertEqual(BCCrypto.xor(offset: 0, Data([0, 0]))[1], 0x2D)
        // Offset 1 starts at key[1] and XORs 1 in.
        XCTAssertEqual(BCCrypto.xor(offset: 1, Data([0]))[0], 0x2D ^ 0x01)
    }

    func testAESCFB128KnownAnswer() {
        // NIST SP 800-38A F.3.13 CFB128-AES128.Encrypt, first block.
        let key: [UInt8] = [0x2b, 0x7e, 0x15, 0x16, 0x28, 0xae, 0xd2, 0xa6, 0xab, 0xf7, 0x15, 0x88, 0x09, 0xcf, 0x4f, 0x3c]
        let iv: [UInt8] = Array(0..<16)
        let plain: [UInt8] = [0x6b, 0xc1, 0xbe, 0xe2, 0x2e, 0x40, 0x9f, 0x96, 0xe9, 0x3d, 0x7e, 0x11, 0x73, 0x93, 0x17, 0x2a,
                              0xae, 0x2d, 0x8a, 0x57, 0x1e, 0x03, 0xac, 0x9c, 0x9e, 0xb7, 0x6f, 0xac, 0x45, 0xaf, 0x8e, 0x51]
        let expected: [UInt8] = [0x3b, 0x3f, 0xd9, 0x2e, 0xb7, 0x2d, 0xad, 0x20, 0x33, 0x34, 0x49, 0xf8, 0xe8, 0x3c, 0xfb, 0x4a,
                                 0xc8, 0xa6, 0x45, 0x37, 0xa0, 0xb3, 0xa9, 0x3f, 0xcd, 0xe3, 0xcd, 0xad, 0x9f, 0x1c, 0xe5, 0x8b]
        XCTAssertEqual([UInt8](BCCrypto.cfbEncrypt(key: key, iv: iv, Data(plain))), expected)
        XCTAssertEqual([UInt8](BCCrypto.cfbDecrypt(key: key, iv: iv, Data(expected))), plain)
    }

    func testAESCFBPartialBlockRoundTrip() {
        let key = BCCrypto.aesKey(nonce: "9E6D1FCB9E69846D", password: "secret")
        XCTAssertEqual(key.count, 16)
        let plain = Data("<?xml version=\"1.0\"?><body><x>37 bytes!</x></body>".utf8)
        let enc = BCCrypto.cfbEncrypt(key: key, plain)
        XCTAssertEqual(enc.count, plain.count)
        XCTAssertEqual(BCCrypto.cfbDecrypt(key: key, enc), plain)
    }
}

final class XMLTests: XCTestCase {
    func testReadsNonce() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8" ?>
        <body>
        <Encryption version="1.1">
        <type>md5</type>
        <nonce>9E6D1FCB9E69846D</nonce>
        </Encryption>
        </body>\0\0
        """
        let r = try XMLReader(xml)
        XCTAssertEqual(r.string("/body/Encryption/nonce"), "9E6D1FCB9E69846D")
        XCTAssertNil(r.string("/body/Encryption/missing"))
    }

    func testBinaryDataExtension() throws {
        let r = try XMLReader("<?xml version=\"1.0\" encoding=\"UTF-8\" ?><Extension version=\"1.1\"><binaryData>1</binaryData><encryptLen>4096</encryptLen></Extension>")
        XCTAssertEqual(r.int("/Extension/binaryData"), 1)
        XCTAssertEqual(r.int("/Extension/encryptLen"), 4096)
    }

    func testBuildersProduceParseableXML() throws {
        let login = try XMLReader(BCXML.login(userHash: "U", passwordHash: "P"))
        XCTAssertEqual(login.string("/body/LoginUser/userName"), "U")
        XCTAssertEqual(login.string("/body/LoginNet/type"), "LAN")
        let preview = try XMLReader(BCXML.preview(channelId: 0, handle: 256, streamName: "subStream"))
        XCTAssertEqual(preview.string("/body/Preview/streamType"), "subStream")
        XCTAssertNil(try XMLReader(BCXML.preview(channelId: 0, handle: 0, streamName: nil)).string("/body/Preview/streamType"))
        let led = try XMLReader(BCXML.ledState(channelId: 0, state: "close", lightState: "open"))
        XCTAssertEqual(led.string("/body/LedState/state"), "close")
        XCTAssertNil(led.string("/body/LedState/ledVersion"))
        let ptz = try XMLReader(BCXML.ptzControl(channelId: 0, speed: 32, command: "left"))
        XCTAssertEqual(ptz.string("/body/PtzControl/speed"), "32")
        XCTAssertEqual(ptz.string("/body/PtzControl/command"), "left")
    }
}

final class CodecTests: XCTestCase {
    func testEncodeDecodeRoundTripUnencrypted() throws {
        var codec = BCCodec(password: "pw")
        let msg = BCMessage(msgId: 18, channelId: 0, msgNum: 5, extensionXML: BCXML.extensionDocument(channelId: 0),
                            payload: .xml(BCXML.ptzControl(channelId: 0, speed: 32, command: "up")))
        let bytes = codec.encode(msg)
        let header = try BCHeader.decode(bytes)
        XCTAssertEqual(header.payloadOffset, UInt32(msg.extensionXML!.utf8.count))
        XCTAssertEqual(Int(header.bodyLength), bytes.count - 24)
        let decoded = try codec.decode(header: header, body: bytes.dropFirst(24))
        XCTAssertEqual(decoded.extensionXML, msg.extensionXML)
        XCTAssertEqual(decoded.xml, msg.xml)
    }

    func testNonceReplySwitchesToAES() throws {
        var codec = BCCodec(password: "pw")
        let nonceXML = "<?xml version=\"1.0\" encoding=\"UTF-8\" ?><body><Encryption version=\"1.1\"><type>md5</type><nonce>ABC</nonce></Encryption></body>"
        // The camera's reply is BCEncrypt-obfuscated and announces full AES (0xdd12).
        let body = BCCrypto.xor(offset: 0, Data(nonceXML.utf8))
        let header = BCHeader(msgId: 1, bodyLength: UInt32(body.count), channelId: 0, streamType: 0, msgNum: 0,
                              responseCode: 0xDD12, msgClass: 0x6614, payloadOffset: nil)
        let m = try codec.decode(header: header, body: body)
        XCTAssertEqual(try XMLReader(m.xml!).string("/body/Encryption/nonce"), "ABC")
        XCTAssertEqual(codec.encryption, .fullAes(key: BCCrypto.aesKey(nonce: "ABC", password: "pw")))

        // A subsequent login message is still only BCEncrypt'ed on the wire.
        let login = codec.encode(BCMessage(msgId: 1, msgNum: 0, payload: .xml("<body/>")))
        XCTAssertEqual(BCCrypto.xor(offset: 0, login.dropFirst(24)), Data("<body/>".utf8))
        // Other messages are AES.
        let ptz = codec.encode(BCMessage(msgId: 18, msgNum: 1, payload: .xml("<body/>")))
        XCTAssertEqual(BCCrypto.cfbDecrypt(key: BCCrypto.aesKey(nonce: "ABC", password: "pw"), ptz.dropFirst(24)), Data("<body/>".utf8))
    }

    func testBinaryModeIsStickyPerMessageNumber() throws {
        var codec = BCCodec(password: "pw")
        let ext = Data(BCXML.extensionDocument(channelId: 0).replacingOccurrences(of: "<channelId>0</channelId>", with: "<binaryData>1</binaryData>").utf8)
        let video = Data([1, 2, 3, 4])
        let first = BCHeader(msgId: 3, bodyLength: UInt32(ext.count + video.count), channelId: 0, streamType: 0, msgNum: 9,
                             responseCode: 0, msgClass: 0x6414, payloadOffset: UInt32(ext.count))
        XCTAssertEqual(try codec.decode(header: first, body: ext + video).binary, video)
        let next = BCHeader(msgId: 3, bodyLength: 4, channelId: 0, streamType: 0, msgNum: 9,
                            responseCode: 0, msgClass: 0x6414, payloadOffset: 0)
        XCTAssertEqual(try codec.decode(header: next, body: video).binary, video)
    }
}

final class MediaParserTests: XCTestCase {
    private func le32(_ v: UInt32) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 24)] }

    private func videoItem(magic: UInt32, extra: [UInt8], payload: [UInt8], micros: UInt32) -> [UInt8] {
        var b = le32(magic) + Array("H264".utf8) + le32(UInt32(payload.count)) + le32(UInt32(extra.count)) + le32(micros) + le32(0)
        b += extra + payload
        b += [UInt8](repeating: 0, count: (8 - payload.count % 8) % 8)
        return b
    }

    func testParsesFramesAcrossChunkBoundaries() throws {
        let key = videoItem(magic: 0x63643030, extra: le32(1_700_000_000), payload: [0, 0, 0, 1, 0x65, 9, 9], micros: 1000)
        let p = videoItem(magic: 0x63643130, extra: [], payload: [0, 0, 0, 1, 0x41, 1, 2, 3, 4, 5], micros: 2000)
        let aac = le32(0x62773530) + [3, 0, 3, 0] + [0xFF, 0xF1, 0x50] + [0, 0, 0, 0, 0]
        let all = key + p + aac
        var parser = BCMediaParser()
        var frames: [BCMediaFrame] = []
        // Feed in awkward 5-byte chunks.
        var i = 0
        while i < all.count {
            parser.append(Data(all[i..<min(i + 5, all.count)]))
            while let f = try parser.next() { frames.append(f) }
            i += 5
        }
        XCTAssertEqual(frames.count, 3)
        guard case .videoKeyFrame(let codec, let data, let micros, let time) = frames[0] else { return XCTFail("expected key frame") }
        XCTAssertEqual(codec, .h264)
        XCTAssertEqual([UInt8](data), [0, 0, 0, 1, 0x65, 9, 9])
        XCTAssertEqual(micros, 1000)
        XCTAssertEqual(time, 1_700_000_000)
        guard case .videoFrame(_, let pdata, 2000) = frames[1] else { return XCTFail("expected P frame") }
        XCTAssertEqual(pdata.count, 10)
        guard case .aac(let adata) = frames[2] else { return XCTFail("expected AAC") }
        XCTAssertEqual([UInt8](adata), [0xFF, 0xF1, 0x50])
    }

    func testResyncsAfterGarbage() throws {
        var parser = BCMediaParser()
        parser.append(Data([0xDE, 0xAD, 0xBE, 0xEF, 1, 2, 3, 4]))
        XCTAssertNil(try parser.next())
        XCTAssertEqual(parser.resyncCount, 1)
        parser.append(Data(videoItem(magic: 0x63643130, extra: [], payload: [1, 2, 3], micros: 5)))
        XCTAssertNotNil(try parser.next())
    }
}

final class ISPConfigTests: XCTestCase {
    func testReplacesOnlyTheDayNightMode() {
        let xml = """
        <body>
        <InputAdvanceCfg version="1.1">
        <Exposure>
        <mode>auto</mode>
        </Exposure>
        <DayNight>
        <mode>auto</mode>
        <IrcutMode>ir</IrcutMode>
        </DayNight>
        </InputAdvanceCfg>
        </body>
        """
        let out = ISPConfig.replacingDayNightMode(in: xml, with: .blackAndWhite)
        XCTAssertEqual(out, xml.replacingOccurrences(of: "<DayNight>\n<mode>auto</mode>", with: "<DayNight>\n<mode>blackAndWhite</mode>"))
        XCTAssertTrue(out!.contains("<Exposure>\n<mode>auto</mode>"))
        XCTAssertNil(ISPConfig.replacingDayNightMode(in: "<body/>", with: .color))
    }
}

final class ADTSTests: XCTestCase {
    func testParsesHeaderFromCamera() throws {
        // Real header from the E1: AAC-LC, 16 kHz, mono, 249-byte frame, no CRC.
        let frame = Data([0xFF, 0xF9, 0x60, 0x40, 0x1F, 0x21, 0xB4] + [UInt8](repeating: 0xAB, count: 242))
        let h = try XCTUnwrap(ADTSHeader(parsing: frame))
        XCTAssertTrue(h.isMPEG2)
        XCTAssertFalse(h.hasCRC)
        XCTAssertEqual(h.headerLength, 7)
        XCTAssertEqual(h.profile, 1)
        XCTAssertEqual(h.audioObjectType, 2)
        XCTAssertEqual(h.sampleRate, 16000)
        XCTAssertEqual(h.channels, 1)
        XCTAssertEqual(h.frameLength, 249)
        XCTAssertEqual([UInt8](h.audioSpecificConfig), [0x14, 0x08])
        XCTAssertEqual(h.payload(of: frame).count, 242)
        XCTAssertEqual(h.payload(of: frame).first, 0xAB)
    }

    func testRejectsGarbage() {
        XCTAssertNil(ADTSHeader(parsing: Data([0x00, 0x00, 0x00, 0x01, 0x65, 0, 0])))
        XCTAssertNil(ADTSHeader(parsing: Data([0xFF, 0xF9])))
    }
}

final class UserListTests: XCTestCase {
    func testParsesUserListReply() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8" ?>
        <body>
        <UserList version="1.1">
        <User>
        <userName>admin</userName>
        <userId>0</userId>
        <userLevel>1</userLevel>
        <loginState>1</loginState>
        <userSetState>none</userSetState>
        </User>
        <User>
        <userName>guest</userName>
        <userId>1</userId>
        <userLevel>0</userLevel>
        <loginState>0</loginState>
        <userSetState>none</userSetState>
        </User>
        </UserList>
        </body>
        \u{0}\u{0}
        """
        let users = try CameraUser.parseList(xml)
        XCTAssertEqual(users, [
            CameraUser(userName: "admin", userId: 0, userLevel: 1, loginState: 1),
            CameraUser(userName: "guest", userId: 1, userLevel: 0, loginState: 0),
        ])
        XCTAssertTrue(users[0].isAdministrator)
        XCTAssertFalse(users[1].isAdministrator)
    }

    func testBuildsModifyRequestWithEscapedPassword() throws {
        var admin = CameraUser(userName: "admin", userId: 0, userLevel: 1, loginState: 1)
        admin.password = "a<b&c\"d'e>"
        admin.setState = .modify
        let guest = CameraUser(userName: "guest", userId: 1, userLevel: 0, loginState: 0)
        let xml = BCXML.userList([admin, guest])
        let reader = try XMLReader(xml)
        let entries = reader.childrenOfEach("/body/UserList/User")
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0].map(\.0), ["userName", "password", "userId", "userLevel", "loginState", "userSetState"])
        XCTAssertEqual(entries[0].first { $0.0 == "password" }?.1, "a<b&c\"d'e>")
        XCTAssertEqual(entries[0].first { $0.0 == "userSetState" }?.1, "modify")
        XCTAssertNil(entries[1].first { $0.0 == "password" }, "untouched users carry no password")
        XCTAssertEqual(entries[1].first { $0.0 == "userSetState" }?.1, "none")
        XCTAssertEqual(reader.string("/body/UserList/@version"), "1.1")
    }

    func testUserNameExtension() throws {
        let reader = try XMLReader(BCXML.extensionDocument(userName: "admin"))
        XCTAssertEqual(reader.string("/Extension/userName"), "admin")
    }
}

final class SpotlightTests: XCTestCase {
    func testParsesStatusList() {
        let xml = """
        <?xml version="1.0" encoding="UTF-8" ?>
        <body>
        <FloodlightStatusList version="1.1">
        <FloodlightStatus>
        <channel>0</channel>
        <status>1</status>
        <brightness>100</brightness>
        </FloodlightStatus>
        </FloodlightStatusList>
        </body>
        """
        XCTAssertEqual(SpotlightStatus.parse(xml, channelId: 0), true)
        XCTAssertNil(SpotlightStatus.parse(xml, channelId: 1))
        XCTAssertEqual(SpotlightStatus.parse(xml.replacingOccurrences(of: "<status>1", with: "<status>0"), channelId: 0), false)
    }

    func testEmptyStatusListHasNoState() {
        let xml = "<?xml version=\"1.0\" encoding=\"UTF-8\" ?>\n<body>\n<FloodlightStatusList version=\"1.1\" />\n</body>\n"
        XCTAssertNil(SpotlightStatus.parse(xml, channelId: 0))
    }

    func testManualCommand() throws {
        let reader = try XMLReader(BCXML.floodlightManual(channelId: 0, on: true, duration: 180))
        XCTAssertEqual(reader.string("/body/FloodlightManual/@version"), "1")
        XCTAssertEqual(reader.children("/body/FloodlightManual").map(\.0), ["channelId", "status", "duration"])
        XCTAssertEqual(reader.int("/body/FloodlightManual/status"), 1)
        XCTAssertEqual(reader.int("/body/FloodlightManual/duration"), 180)
    }
}

final class OSDConfigTests: XCTestCase {
    let xml = """
    <?xml version="1.0" encoding="UTF-8" ?>
    <body>
    <OsdDatetime version="1.1">
    <channelId>0</channelId>
    <enable>1</enable>
    </OsdDatetime>
    <OsdChannelName version="1.1">
    <channelId>0</channelId>
    <name>Roomcam Admin</name>
    <enable>1</enable>
    <topLeftX>65536</topLeftX>
    </OsdChannelName>
    </body>
    """

    func testReadsName() {
        XCTAssertEqual(OSDConfig.name(in: xml), "Roomcam Admin")
        XCTAssertNil(OSDConfig.name(in: "<body/>"))
    }

    func testReplacesOnlyTheName() {
        let out = OSDConfig.replacingName(in: xml, with: "Room <Admin> & Co")
        XCTAssertEqual(out, xml.replacingOccurrences(of: "<name>Roomcam Admin</name>", with: "<name>Room &lt;Admin&gt; &amp; Co</name>"))
        XCTAssertEqual(OSDConfig.name(in: out!), "Room <Admin> & Co")
        XCTAssertNil(OSDConfig.replacingName(in: "<body/>", with: "x"))
    }
}

final class ServerPortConfigTests: XCTestCase {
    // As an RLC-1240A answers message 37.
    let xml = """
    <?xml version="1.0" encoding="UTF-8" ?>
    <body>
    <ServerPort version="1.1">
    <serverPort>9000</serverPort>
    <enable>1</enable>
    </ServerPort>
    <HttpPort version="1.1">
    <httpPort>80</httpPort>
    <enable>0</enable>
    </HttpPort>
    <HttpsPort version="1.1">
    <httpsPort>443</httpsPort>
    <enable>1</enable>
    </HttpsPort>
    <RtspPort version="1.1">
    <rtspPort>554</rtspPort>
    <enable>0</enable>
    </RtspPort>
    <RtmpPort version="1.1">
    <rtmpPort>1935</rtmpPort>
    <enable>0</enable>
    </RtmpPort>
    <OnvifPort version="1.1">
    <onvifPort>8000</onvifPort>
    <enable>0</enable>
    </OnvifPort>
    </body>
    """

    func testReadsServices() throws {
        let services = try ServerPortConfig.services(in: xml)
        XCTAssertEqual(services[.onvif], CameraServiceState(enabled: false, port: 8000))
        XCTAssertEqual(services[.rtsp], CameraServiceState(enabled: false, port: 554))
        XCTAssertEqual(services[.https], CameraServiceState(enabled: true, port: 443))
        XCTAssertEqual(services.count, 5)
        XCTAssertTrue(try ServerPortConfig.services(in: "<body/>").isEmpty)
    }

    func testReplacesOnlyOneSwitch() throws {
        let out = ServerPortConfig.replacingEnabled(of: .onvif, in: xml, with: true)
        XCTAssertEqual(out, xml.replacingOccurrences(of: "<onvifPort>8000</onvifPort>\n<enable>0</enable>",
                                                     with: "<onvifPort>8000</onvifPort>\n<enable>1</enable>"))
        XCTAssertEqual(try ServerPortConfig.services(in: out!)[.onvif], CameraServiceState(enabled: true, port: 8000))
        // Switching HTTPS off must leave the camera's own ServerPort and the other services as they were.
        let https = ServerPortConfig.replacingEnabled(of: .https, in: xml, with: false)
        XCTAssertEqual(https, xml.replacingOccurrences(of: "<httpsPort>443</httpsPort>\n<enable>1</enable>",
                                                       with: "<httpsPort>443</httpsPort>\n<enable>0</enable>"))
        XCTAssertNil(ServerPortConfig.replacingEnabled(of: .onvif, in: "<body/>", with: true))
    }
}
