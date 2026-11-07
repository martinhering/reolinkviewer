import Foundation

/// Minimal XPath-based reader over the camera's XML documents.
public struct XMLReader {
    private let document: XMLDocument

    /// Parses `text`. Anything after the last `>` (NUL padding, garbage) is dropped first.
    public init(_ text: String) throws {
        guard let end = text.lastIndex(of: ">") else { throw BCError.malformedXML("no XML in reply") }
        let cleaned = String(text[...end])
        do {
            document = try XMLDocument(xmlString: cleaned, options: [])
        } catch {
            throw BCError.malformedXML(error.localizedDescription)
        }
    }

    public func string(_ xpath: String) -> String? {
        guard let nodes = try? document.nodes(forXPath: xpath), let first = nodes.first else { return nil }
        return first.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func int(_ xpath: String) -> Int? {
        string(xpath).flatMap { Int($0) }
    }

    /// Name/value pairs of the child elements of every node matching `xpath`.
    public func childrenOfEach(_ xpath: String) -> [[(String, String)]] {
        guard let nodes = try? document.nodes(forXPath: xpath) else { return [] }
        return nodes.map { node in
            (node.children ?? []).compactMap { child in
                guard child.kind == .element, let name = child.name else { return nil }
                return (name, child.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
            }
        }
    }

    /// Name/value pairs of all child elements of the node at `xpath`.
    public func children(_ xpath: String) -> [(String, String)] {
        guard let nodes = try? document.nodes(forXPath: xpath), let first = nodes.first else { return [] }
        return (first.children ?? []).compactMap { node in
            guard node.kind == .element, let name = node.name else { return nil }
            return (name, node.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
        }
    }
}

/// Builders for the XML bodies the client sends.
public enum BCXML {
    public static let version = "1.1"
    static let declaration = "<?xml version=\"1.0\" encoding=\"UTF-8\" ?>\n"

    static func body(_ inner: String) -> String {
        "\(declaration)<body>\n\(inner)</body>\n"
    }

    public static func extensionDocument(channelId: UInt8) -> String {
        "\(declaration)<Extension version=\"\(version)\">\n<channelId>\(channelId)</channelId>\n</Extension>\n"
    }

    /// Extension naming the user a request is about (used when reading the user list).
    public static func extensionDocument(userName: String) -> String {
        "\(declaration)<Extension version=\"\(version)\">\n<userName>\(escape(userName))</userName>\n</Extension>\n"
    }

    /// Escapes the five XML special characters for use in element text.
    public static func escape(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        for c in text {
            switch c {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&apos;"
            default: out.append(c)
            }
        }
        return out
    }

    /// The whole user list as sent with message 59. Each entry carries its `setState`;
    /// `password` is only included for users being added or modified.
    public static func userList(_ users: [CameraUser]) -> String {
        var inner = "<UserList version=\"\(version)\">\n"
        for user in users {
            inner += "<User>\n<userName>\(escape(user.userName))</userName>\n"
            if let password = user.password { inner += "<password>\(escape(password))</password>\n" }
            if let id = user.userId { inner += "<userId>\(id)</userId>\n" }
            inner += "<userLevel>\(user.userLevel)</userLevel>\n"
            if let state = user.loginState { inner += "<loginState>\(state)</loginState>\n" }
            inner += "<userSetState>\(user.setState.rawValue)</userSetState>\n</User>\n"
        }
        inner += "</UserList>\n"
        return body(inner)
    }

    public static func login(userHash: String, passwordHash: String) -> String {
        body("""
        <LoginUser version="\(version)">
        <userName>\(userHash)</userName>
        <password>\(passwordHash)</password>
        <userVer>1</userVer>
        </LoginUser>
        <LoginNet version="\(version)">
        <type>LAN</type>
        <udpPort>0</udpPort>
        </LoginNet>

        """)
    }

    /// `streamName` is "mainStream"/"subStream" when starting; nil when stopping.
    public static func preview(channelId: UInt8, handle: UInt32, streamName: String?) -> String {
        var inner = """
        <Preview version="\(version)">
        <channelId>\(channelId)</channelId>
        <handle>\(handle)</handle>

        """
        if let streamName {
            inner += "<streamType>\(streamName)</streamType>\n"
        }
        inner += "</Preview>\n"
        return body(inner)
    }

    /// `state` is the infrared LED mode ("auto", "open", "close"); `lightState` the blue status
    /// LED ("open", "close"). The camera's `ledVersion` must not be sent back.
    public static func ledState(channelId: UInt8, state: String, lightState: String) -> String {
        body("""
        <LedState version="\(version)">
        <channelId>\(channelId)</channelId>
        <state>\(state)</state>
        <lightState>\(lightState)</lightState>
        </LedState>

        """)
    }

    /// `status` 1 switches the spotlight on, 0 off; `duration` is how long, in seconds, the
    /// manual setting holds before the camera goes back to its automatic behaviour.
    public static func floodlightManual(channelId: UInt8, on: Bool, duration: UInt16) -> String {
        body("""
        <FloodlightManual version="1">
        <channelId>\(channelId)</channelId>
        <status>\(on ? 1 : 0)</status>
        <duration>\(duration)</duration>
        </FloodlightManual>

        """)
    }

    public static func ptzControl(channelId: UInt8, speed: Float, command: String) -> String {
        let speedText = speed == speed.rounded() ? String(Int(speed)) : String(speed)
        return body("""
        <PtzControl version="\(version)">
        <channelId>\(channelId)</channelId>
        <speed>\(speedText)</speed>
        <command>\(command)</command>
        </PtzControl>

        """)
    }
}
