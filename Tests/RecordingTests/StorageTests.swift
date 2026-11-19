import Foundation
import XCTest
@testable import Recording

final class VaultTests: XCTestCase {
    func testSealedFileOpensOnlyWithTheSameKeyAndName() throws {
        let vault = Vault.generate()
        let clip = Data((0..<5000).map { UInt8($0 % 251) })
        let sealed = try vault.seal(clip, name: "recordings/a/2026-11-19/100000Z_60s.mp4.enc")
        XCTAssertEqual(sealed.prefix(4), Data("RVE1".utf8))
        XCTAssertEqual(sealed.count, clip.count + 4 + 12 + 16)
        XCTAssertNil(sealed.range(of: clip.prefix(32)), "the clear bytes must not show")
        XCTAssertEqual(try vault.open(sealed, name: "recordings/a/2026-11-19/100000Z_60s.mp4.enc"), clip)

        XCTAssertThrowsError(try vault.open(sealed, name: "recordings/b/2026-11-19/100000Z_60s.mp4.enc"), "another name")
        XCTAssertThrowsError(try Vault.generate().open(sealed, name: "recordings/a/2026-11-19/100000Z_60s.mp4.enc"), "another key")
        var tampered = sealed
        tampered[100] ^= 1
        XCTAssertThrowsError(try vault.open(tampered, name: "recordings/a/2026-11-19/100000Z_60s.mp4.enc"), "a flipped bit")
        XCTAssertThrowsError(try vault.open(clip, name: "x")) { XCTAssertEqual("\($0)", "\(VaultError.notSealed)") }
    }

    func testSealingTwiceGivesDifferentBytes() throws {
        let vault = Vault.generate()
        XCTAssertNotEqual(try vault.seal(Data([1, 2, 3]), name: "n"), try vault.seal(Data([1, 2, 3]), name: "n"))
    }

    func testKeyFileOpensWithThePassphraseOnly() throws {
        let vault = Vault.generate()
        let sealed = try vault.seal(Data("clip".utf8), name: "n")
        // Few iterations keep the test fast; the format is the same.
        let keyFile = try vault.keyFile(passphrase: "correct horse", iterations: 1000)
        XCTAssertEqual(try Vault(keyFile: keyFile, passphrase: "correct horse").open(sealed, name: "n"), Data("clip".utf8))
        XCTAssertThrowsError(try Vault(keyFile: keyFile, passphrase: "wrong horse")) {
            XCTAssertEqual("\($0)", "\(VaultError.wrongPassphrase)")
        }
        XCTAssertThrowsError(try Vault(keyFile: Data("{}".utf8), passphrase: "correct horse"))
    }

    func testChangingThePassphraseKeepsTheRecordingsReadable() throws {
        let vault = Vault.generate()
        let sealed = try vault.seal(Data("clip".utf8), name: "n")
        let first = try vault.keyFile(passphrase: "old", iterations: 1000)
        let rewrapped = try Vault(keyFile: first, passphrase: "old").keyFile(passphrase: "new", iterations: 1000)
        XCTAssertEqual(try Vault(keyFile: rewrapped, passphrase: "new").open(sealed, name: "n"), Data("clip".utf8))
        XCTAssertThrowsError(try Vault(keyFile: rewrapped, passphrase: "old"))
    }

    func testGeneratedPassphrases() {
        let a = Vault.generatePassphrase(), b = Vault.generatePassphrase()
        XCTAssertNotEqual(a, b)
        XCTAssertEqual(a.split(separator: "-").map(\.count), [5, 5, 5, 5, 5, 5])
        XCTAssertNil(a.rangeOfCharacter(from: CharacterSet(charactersIn: "01IO")))
    }
}

final class S3SignatureTests: XCTestCase {
    // The worked examples from the AWS documentation ("Signature Calculations for the
    // Authorization Header: Transferring Payload in a Single Chunk").
    private let credentials = S3Credentials(accessKeyID: "AKIAIOSFODNN7EXAMPLE", secretAccessKey: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY")
    private let endpoint = URL(string: "https://examplebucket.s3.amazonaws.com")!
    private let date = Date(timeIntervalSince1970: 1_369_353_600)  // 2013-05-24 00:00:00 UTC

    private func signature(_ request: URLRequest) -> String? {
        request.value(forHTTPHeaderField: "Authorization")?.components(separatedBy: "Signature=").last
    }

    func testGetObject() {
        let request = S3Client.signedRequest(method: "GET", endpoint: endpoint, path: "/test.txt", query: nil,
                                             headers: ["Range": "bytes=0-9"], body: Data(), region: "us-east-1",
                                             credentials: credentials, date: date)
        XCTAssertEqual(signature(request), "f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-amz-date"), "20130524T000000Z")
        XCTAssertEqual(request.url?.absoluteString, "https://examplebucket.s3.amazonaws.com/test.txt")
        XCTAssertTrue(request.value(forHTTPHeaderField: "Authorization")?.hasPrefix(
            "AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20130524/us-east-1/s3/aws4_request, SignedHeaders=host;range;x-amz-content-sha256;x-amz-date, ") ?? false)
    }

    func testPutObjectWithACharacterThatNeedsEncoding() {
        let request = S3Client.signedRequest(method: "PUT", endpoint: endpoint, path: "/test$file.text", query: nil,
                                             headers: ["Date": "Fri, 24 May 2013 00:00:00 GMT", "x-amz-storage-class": "REDUCED_REDUNDANCY"],
                                             body: Data("Welcome to Amazon S3.".utf8), region: "us-east-1",
                                             credentials: credentials, date: date)
        XCTAssertEqual(signature(request), "98ad721746da40c64f1a55b78f14c238d841ea1380cd77a1b5971af0ece108bd")
        XCTAssertEqual(request.url?.absoluteString, "https://examplebucket.s3.amazonaws.com/test%24file.text")
    }

    func testBucketLifecycleQuery() {
        let request = S3Client.signedRequest(method: "GET", endpoint: endpoint, path: "/", query: "lifecycle=", headers: [:],
                                             body: Data(), region: "us-east-1", credentials: credentials, date: date)
        XCTAssertEqual(signature(request), "fea454ca298b7da1c68078a5d1bdbfbbe0d65c699e0f91ac7a200a0136783543")
    }

    func testPathStyleAddressWithAPort() {
        let request = S3Client.signedRequest(method: "PUT", endpoint: URL(string: "http://127.0.0.1:9000")!,
                                             path: "/bucket/recordings/a b/x.enc", query: nil, headers: [:], body: Data([1]),
                                             region: "garage", credentials: credentials, date: date)
        XCTAssertEqual(request.url?.absoluteString, "http://127.0.0.1:9000/bucket/recordings/a%20b/x.enc")
        XCTAssertTrue(request.value(forHTTPHeaderField: "Authorization")?.contains("/garage/s3/aws4_request") ?? false)
    }
}

final class StorageSettingsTests: XCTestCase {
    func testEndpointForms() {
        var s = StorageSettings()
        XCTAssertFalse(s.isConfigured)
        s.endpoint = "s3.eu-central-003.backblazeb2.com"
        s.bucket = "cams"
        s.uploadKeyID = "key"
        XCTAssertEqual(s.configuration?.endpoint.absoluteString, "https://s3.eu-central-003.backblazeb2.com")
        XCTAssertEqual(s.configuration?.region, "us-east-1", "a service that ignores the region still needs one in the signature")
        XCTAssertTrue(s.isConfigured)
        s.endpoint = "http://127.0.0.1:9000"
        s.region = "garage"
        XCTAssertEqual(s.configuration, S3Configuration(endpoint: URL(string: "http://127.0.0.1:9000")!, region: "garage", bucket: "cams"))
    }
}

/// Answers every request of a URLSession from a closure.
final class StubProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) -> Int)?
    nonisolated(unsafe) static var requests: [String] = []
    static let lock = NSLock()

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        Self.lock.lock()
        Self.requests.append("\(request.httpMethod ?? "?") \(request.url?.path ?? "?")")
        let status = Self.handler?(request) ?? 200
        Self.lock.unlock()
        if status == 0 {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data((status == 200 ? "" : "<Error><Code>AccessDenied</Code><Message>no</Message></Error>").utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}

final class UploaderTests: XCTestCase {
    private var root: URL!
    private let camera = UUID(uuidString: "02AC1B31-8439-40D6-8453-61E11CC5CBFD")!
    private let vault = Vault.generate()
    private let logged = Lines()

    final class Lines: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [String] = []
        func add(_ line: String) { lock.lock(); lines.append(line); lock.unlock() }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return lines }
    }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("UploaderTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        StubProtocol.handler = nil
        StubProtocol.requests = []
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func uploader() -> Uploader {
        let setup = StorageSetup(configuration: S3Configuration(endpoint: URL(string: "https://s3.example.com")!, region: "eu", bucket: "cams"),
                                 credentials: S3Credentials(accessKeyID: "id", secretAccessKey: "secret"), vault: vault)
        let logged = self.logged
        return Uploader(root: root, setup: setup, session: StubProtocol.session(), log: { logged.add($0) })
    }

    private func keptFile(_ name: String, day: String = "2026-11-19") throws -> URL {
        let url = RecordingStore.directory(for: camera, in: root).appendingPathComponent("\(day)/\(name)")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("clip \(name)".utf8).write(to: url)
        return url
    }

    private let tenOClock = Date(timeIntervalSince1970: 1_795_082_400)

    func testSealsUploadsAndIndexes() async throws {
        let uploader = uploader()
        let clear = try keptFile("100000Z_60s.mp4")
        await uploader.enqueue(file: clear, camera: camera, cameraName: "Lab", start: tenOClock, duration: 60,
                               motion: [DateInterval(start: tenOClock.addingTimeInterval(5), duration: 10)])
        let fm = FileManager.default
        XCTAssertFalse(fm.fileExists(atPath: clear.path), "the clear file is gone")
        let sealedURL = clear.appendingPathExtension("enc")
        let key = "recordings/\(camera.uuidString)/2026-11-19/100000Z_60s.mp4.enc"
        XCTAssertEqual(try vault.open(Data(contentsOf: sealedURL), name: key), Data("clip 100000Z_60s.mp4".utf8))
        let pendingBefore = await uploader.pending
        XCTAssertEqual(pendingBefore, 1)

        let first = await uploader.uploadNext()   // the file
        let second = await uploader.uploadNext()  // the day index
        let third = await uploader.uploadNext()
        XCTAssertEqual([first, second, third], [true, true, nil])
        XCTAssertEqual(StubProtocol.requests, ["PUT /cams/\(key)", "PUT /cams/recordings/index/2026-11-19.json.enc"])
        XCTAssertTrue(fm.fileExists(atPath: sealedURL.path), "the sealed file stays as the local cache")

        let sealedIndex = try Data(contentsOf: root.appendingPathComponent("index/2026-11-19.json.enc"))
        let index = try JSONDecoder().decode(DayIndex.self, from: vault.open(sealedIndex, name: "recordings/index/2026-11-19.json.enc"))
        XCTAssertEqual(index.day, "2026-11-19")
        let entry = try XCTUnwrap(index.cameras[camera.uuidString])
        XCTAssertEqual(entry.name, "Lab")
        XCTAssertEqual(entry.files.map(\.name), ["100000Z_60s.mp4.enc"])
        XCTAssertEqual(entry.files[0].motion, [[tenOClock.timeIntervalSince1970 + 5, tenOClock.timeIntervalSince1970 + 15]])
    }

    func testCatchesUpAfterAnOutage() async throws {
        let uploader = uploader()
        StubProtocol.handler = { _ in 0 }  // no network
        for (i, name) in ["100000Z_60s.mp4", "100100Z_60s.mp4", "100200Z_60s.mp4"].enumerated() {
            await uploader.enqueue(file: try keptFile(name), camera: camera, cameraName: "Lab",
                                   start: tenOClock.addingTimeInterval(Double(i) * 60), duration: 60, motion: [])
        }
        let failedOnce = await uploader.uploadNext()
        let failedTwice = await uploader.uploadNext()
        XCTAssertEqual([failedOnce, failedTwice], [false, false])
        let waiting = await uploader.pending
        XCTAssertEqual(waiting, 3, "nothing is lost while the network is down")
        XCTAssertEqual(logged.all.filter { $0.contains("upload failed") }.count, 1, "an outage is reported once")

        StubProtocol.handler = nil
        StubProtocol.requests = []
        while await uploader.uploadNext() != nil {}
        // The three files in order, the index after each, the last index upload carrying all three.
        XCTAssertEqual(StubProtocol.requests.filter { $0.hasSuffix(".mp4.enc") }.map { String($0.suffix(19)) },
                       ["100000Z_60s.mp4.enc", "100100Z_60s.mp4.enc", "100200Z_60s.mp4.enc"])
        XCTAssertEqual(StubProtocol.requests.last, "PUT /cams/recordings/index/2026-11-19.json.enc")
        XCTAssertTrue(logged.all.contains { $0.contains("uploads work again") })
        let sealedIndex = try Data(contentsOf: root.appendingPathComponent("index/2026-11-19.json.enc"))
        let index = try JSONDecoder().decode(DayIndex.self, from: vault.open(sealedIndex, name: "recordings/index/2026-11-19.json.enc"))
        XCTAssertEqual(index.cameras[camera.uuidString]?.files.count, 3)
    }

    func testARefusedUploadStaysQueued() async throws {
        let uploader = uploader()
        StubProtocol.handler = { _ in 403 }
        await uploader.enqueue(file: try keptFile("100000Z_60s.mp4"), camera: camera, cameraName: "Lab", start: tenOClock, duration: 60, motion: [])
        let result = await uploader.uploadNext()
        XCTAssertEqual(result, false)
        XCTAssertTrue(logged.all.contains { $0.contains("403 AccessDenied") }, "\(logged.all)")
        let waiting = await uploader.pending
        XCTAssertEqual(waiting, 1)
    }

    func testQueuesClearFilesLeftInTheDatedFolders() async throws {
        let left = try keptFile("235900Z_60s.mp4", day: "2026-11-18")
        let pending = RecordingStore.directory(for: camera, in: root).appendingPathComponent("pending/2026-11-19/100000Z_60s.mp4")
        try FileManager.default.createDirectory(at: pending.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([1]).write(to: pending)
        let uploader = uploader()
        await uploader.enqueueLeftovers(cameraNames: [camera: "Lab"])
        let waiting = await uploader.pending
        XCTAssertEqual(waiting, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: left.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: pending.path), "undecided files are not touched")
        while await uploader.uploadNext() != nil {}
        XCTAssertEqual(StubProtocol.requests.first, "PUT /cams/recordings/\(camera.uuidString)/2026-11-18/235900Z_60s.mp4.enc")
    }

    func testParsesStartAndLengthFromAFileName() throws {
        let (start, length) = try XCTUnwrap(Uploader.parse(day: "2026-11-19", name: "100000Z_60s.mp4"))
        XCTAssertEqual(start, tenOClock)
        XCTAssertEqual(length, 60)
        XCTAssertNil(Uploader.parse(day: "2026-11-19", name: "notes.mp4"))
    }
}
