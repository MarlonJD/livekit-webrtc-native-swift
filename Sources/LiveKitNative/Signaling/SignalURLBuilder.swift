import Foundation

public struct SignalURLBuilder: Equatable, Sendable {
    public var serverURL: URL

    public init(serverURL: URL) {
        self.serverURL = serverURL
    }

    public func build(
        token: String,
        reconnect: Bool = false,
        autoSubscribe: Bool = true,
        connectOptions: ConnectOptions = .init()
    ) throws -> URL {
        guard !token.isEmpty else {
            throw LiveKitNativeError.missingToken
        }

        guard var components = URLComponents(url: serverURL, resolvingAgainstBaseURL: false) else {
            throw LiveKitNativeError.invalidURL("Unable to decompose URL components.")
        }

        switch components.scheme?.lowercased() {
        case "https":
            components.scheme = "wss"
        case "http":
            components.scheme = "ws"
        case "wss", "ws":
            break
        default:
            throw LiveKitNativeError.invalidURL("Expected http, https, ws, or wss scheme.")
        }

        guard components.host != nil else {
            throw LiveKitNativeError.invalidURL("Missing host.")
        }

        components.path = rtcPath(from: components.path)

        let reservedQueryNames: Set<String> = [
            "access_token",
            "reconnect",
            "auto_subscribe",
            "sdk",
            "version",
            "protocol",
        ]

        let existingItems = components.queryItems?.filter { !reservedQueryNames.contains($0.name) } ?? []
        components.queryItems = existingItems + [
            URLQueryItem(name: "access_token", value: token),
            URLQueryItem(name: "reconnect", value: String(reconnect)),
            URLQueryItem(name: "auto_subscribe", value: String(autoSubscribe)),
            URLQueryItem(name: "sdk", value: connectOptions.sdk),
            URLQueryItem(name: "version", value: connectOptions.version),
            URLQueryItem(name: "protocol", value: String(connectOptions.protocolVersion)),
        ]

        guard let url = components.url else {
            throw LiveKitNativeError.invalidURL("Unable to compose signaling URL.")
        }

        return url
    }

    private func rtcPath(from path: String) -> String {
        let normalizedPath = path.isEmpty ? "/" : path
        let trimmedPath = normalizedPath.hasSuffix("/") ? String(normalizedPath.dropLast()) : normalizedPath

        if trimmedPath == "/rtc" || trimmedPath.hasSuffix("/rtc") {
            return trimmedPath
        }

        if trimmedPath == "/" {
            return "/rtc"
        }

        return "\(trimmedPath)/rtc"
    }
}
