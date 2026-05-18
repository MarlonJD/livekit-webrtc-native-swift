import CryptoKit
import Foundation
import LiveKitNative
import XCTest

struct LiveKitIntegrationHarness: Sendable {
    static let runIntegrationKey = "LIVEKIT_NATIVE_RUN_INTEGRATION"
    static let liveKitURLKey = "LIVEKIT_NATIVE_LIVEKIT_URL"
    static let apiKeyKey = "LIVEKIT_NATIVE_API_KEY"
    static let apiSecretKey = "LIVEKIT_NATIVE_API_SECRET"

    let liveKitURL: URL
    let roomPrefix: String

    private let tokenFactory: LiveKitIntegrationTokenFactory

    static func load(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        now: Date = Date(),
        uuid: UUID = UUID()
    ) throws -> Self {
        guard environment[runIntegrationKey] == "1" else {
            throw XCTSkip("Set \(runIntegrationKey)=1 and provide a local LiveKit server to run integration tests.")
        }

        let liveKitURLString = try requiredValue(liveKitURLKey, in: environment)
        guard let liveKitURL = URL(string: liveKitURLString),
              let scheme = liveKitURL.scheme?.lowercased(),
              ["http", "https", "ws", "wss"].contains(scheme),
              liveKitURL.host?.isEmpty == false
        else {
            throw LiveKitIntegrationHarnessError.invalidEnvironmentValue(
                name: liveKitURLKey,
                value: liveKitURLString,
                reason: "expected an http(s) or ws(s) LiveKit URL with a host"
            )
        }

        let apiKey = try requiredValue(apiKeyKey, in: environment)
        let apiSecret = try requiredValue(apiSecretKey, in: environment)
        let prefixTimestamp = Int(now.timeIntervalSince1970)
        let prefixEntropy = String(uuid.uuidString.lowercased().prefix(8))

        return Self(
            liveKitURL: liveKitURL,
            roomPrefix: "lknative-\(prefixTimestamp)-\(prefixEntropy)",
            tokenFactory: LiveKitIntegrationTokenFactory(
                apiKey: apiKey,
                apiSecret: apiSecret
            )
        )
    }

    func roomName(suffix: String) -> String {
        "\(roomPrefix)-\(suffix)-\(UUID().uuidString.lowercased())"
    }

    func token(identity: String, roomName: String, ttlSeconds: Int = 600) throws -> String {
        try tokenFactory.token(
            identity: identity,
            roomName: roomName,
            ttlSeconds: ttlSeconds
        )
    }

    private static func requiredValue(_ name: String, in environment: [String: String]) throws -> String {
        let value = environment[name]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !value.isEmpty else {
            throw LiveKitIntegrationHarnessError.missingEnvironmentValue(name)
        }

        return value
    }
}

private struct LiveKitIntegrationTokenFactory: Sendable {
    var apiKey: String
    var apiSecret: String

    func token(
        identity: String,
        roomName: String,
        ttlSeconds: Int,
        now: Date = Date()
    ) throws -> String {
        let identity = identity.trimmingCharacters(in: .whitespacesAndNewlines)
        let roomName = roomName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !identity.isEmpty else {
            throw LiveKitIntegrationHarnessError.invalidTokenInput("identity must not be empty")
        }
        guard !roomName.isEmpty else {
            throw LiveKitIntegrationHarnessError.invalidTokenInput("roomName must not be empty")
        }

        let issuedAt = Int(now.timeIntervalSince1970)
        let expiresAt = issuedAt + max(1, ttlSeconds)
        let header: [String: Any] = [
            "alg": "HS256",
            "typ": "JWT",
        ]
        let payload: [String: Any] = [
            "iss": apiKey,
            "sub": identity,
            "nbf": issuedAt,
            "exp": expiresAt,
            "video": [
                "roomJoin": true,
                "room": roomName,
                "canPublish": true,
                "canSubscribe": true,
                "canPublishData": true,
                "canUpdateOwnMetadata": true,
            ],
        ]

        let encodedHeader = try Self.base64URLEncodedJSONObject(header)
        let encodedPayload = try Self.base64URLEncodedJSONObject(payload)
        let signingInput = "\(encodedHeader).\(encodedPayload)"
        let signature = HMAC<SHA256>.authenticationCode(
            for: Data(signingInput.utf8),
            using: SymmetricKey(data: Data(apiSecret.utf8))
        )

        return "\(signingInput).\(Data(signature).base64URLEncodedString())"
    }

    private static func base64URLEncodedJSONObject(_ object: Any) throws -> String {
        try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys]
        ).base64URLEncodedString()
    }
}

enum LiveKitIntegrationHarnessError: Error, CustomStringConvertible {
    case missingEnvironmentValue(String)
    case invalidEnvironmentValue(name: String, value: String, reason: String)
    case invalidTokenInput(String)
    case timeout(seconds: TimeInterval)

    var description: String {
        switch self {
        case let .missingEnvironmentValue(name):
            "Missing required integration environment variable: \(name)."
        case let .invalidEnvironmentValue(name, value, reason):
            "Invalid integration environment variable \(name)=\(value): \(reason)."
        case let .invalidTokenInput(reason):
            "Invalid LiveKit integration token input: \(reason)."
        case let .timeout(seconds):
            "LiveKit integration operation timed out after \(seconds) seconds."
        }
    }
}

func withLiveKitIntegrationTimeout<T: Sendable>(
    seconds: TimeInterval,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask {
            try await operation()
        }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw LiveKitIntegrationHarnessError.timeout(seconds: seconds)
        }

        guard let result = try await group.next() else {
            throw LiveKitIntegrationHarnessError.timeout(seconds: seconds)
        }

        group.cancelAll()
        return result
    }
}

extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .trimmingCharacters(in: CharacterSet(charactersIn: "="))
    }

    init?(base64URLEncoded string: String) {
        var base64 = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 {
            base64.append("=")
        }

        self.init(base64Encoded: base64)
    }
}
