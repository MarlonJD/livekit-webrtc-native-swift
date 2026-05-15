import Foundation

package enum SDPParseError: Error, Equatable, Sendable {
    case malformedLine(String)
    case missingVersion
}

package enum SDPDTLSSetupRole: String, Equatable, Sendable {
    case active
    case passive
    case actpass
    case holdconn
}

package struct SDPLine: Equatable, Sendable {
    package var field: Character
    package var value: String

    package init(field: Character, value: String) {
        self.field = field
        self.value = value
    }

    package var serialized: String {
        "\(field)=\(value)"
    }
}

package struct SDPMediaSection: Equatable, Sendable {
    package var mediaLine: String
    package var attributes: [String]

    package init(mediaLine: String, attributes: [String] = []) {
        self.mediaLine = mediaLine
        self.attributes = attributes
    }

    package var mid: String? {
        attributes
            .first(where: { $0.hasPrefix("mid:") })
            .map { String($0.dropFirst(4)) }
    }

    package var hasRTCPMux: Bool {
        attributes.contains("rtcp-mux")
    }

    package var codecNames: [String] {
        attributes.compactMap { attribute in
            guard attribute.hasPrefix("rtpmap:") else { return nil }
            let mapping = attribute.dropFirst("rtpmap:".count)
            guard let codecStart = mapping.firstIndex(of: " ") else { return nil }
            let codecDescriptor = mapping[mapping.index(after: codecStart)...]
            let codecName = codecDescriptor.split(separator: "/", maxSplits: 1).first
            return codecName.map(String.init)
        }
    }
}

package struct SDPSessionDescription: Equatable, Sendable {
    package var lines: [SDPLine]
    package var mediaSections: [SDPMediaSection]

    package init(lines: [SDPLine]) throws {
        guard lines.contains(where: { $0.field == "v" }) else {
            throw SDPParseError.missingVersion
        }

        self.lines = lines
        self.mediaSections = Self.mediaSections(from: lines)
    }

    package init(parsing sdp: String) throws {
        let normalizedLines = sdp
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)

        let parsedLines = try normalizedLines.map { rawLine in
            let characters = Array(rawLine)
            guard characters.count >= 2, characters[1] == "=" else {
                throw SDPParseError.malformedLine(rawLine)
            }

            return SDPLine(field: characters[0], value: String(characters.dropFirst(2)))
        }

        try self.init(lines: parsedLines)
    }

    package var bundleMIDs: [String] {
        lines.flatMap { line -> [String] in
            guard line.field == "a", line.value.hasPrefix("group:BUNDLE ") else {
                return []
            }

            return line.value
                .dropFirst("group:BUNDLE ".count)
                .split(separator: " ")
                .map(String.init)
        }
    }

    package var iceCredentials: ICECredentials? {
        guard
            let usernameFragment = firstAttributeValue(prefix: "ice-ufrag:"),
            let password = firstAttributeValue(prefix: "ice-pwd:")
        else {
            return nil
        }

        return ICECredentials(usernameFragment: usernameFragment, password: password)
    }

    package var dtlsFingerprint: DTLSSignature? {
        guard let fingerprint = firstAttributeValue(prefix: "fingerprint:") else {
            return nil
        }

        let tokens = fingerprint.split(separator: " ", maxSplits: 1).map(String.init)
        guard tokens.count == 2 else {
            return nil
        }

        return DTLSSignature(hashFunction: tokens[0], value: tokens[1])
    }

    package var dtlsSetupRole: SDPDTLSSetupRole? {
        firstAttributeValue(prefix: "setup:").flatMap(SDPDTLSSetupRole.init(rawValue:))
    }

    package func serialized() -> String {
        lines.map(\.serialized).joined(separator: "\r\n") + "\r\n"
    }

    private func firstAttributeValue(prefix: String) -> String? {
        lines.first { line in
            line.field == "a" && line.value.hasPrefix(prefix)
        }
        .map { String($0.value.dropFirst(prefix.count)) }
    }

    private static func mediaSections(from lines: [SDPLine]) -> [SDPMediaSection] {
        var sections: [SDPMediaSection] = []

        for line in lines {
            switch line.field {
            case "m":
                sections.append(SDPMediaSection(mediaLine: line.value))
            case "a":
                guard !sections.isEmpty else { continue }
                sections[sections.count - 1].attributes.append(line.value)
            default:
                continue
            }
        }

        return sections
    }
}
