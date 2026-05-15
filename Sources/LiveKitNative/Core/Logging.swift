import Foundation
#if canImport(OSLog)
import OSLog
#endif

public enum LiveKitNativeLogLevel: Int, Equatable, Sendable {
    case debug = 0
    case info = 1
    case warning = 2
    case error = 3
    case off = 4
}

public protocol LiveKitNativeLogger: Sendable {
    func log(level: LiveKitNativeLogLevel, message: String, file: String, line: UInt)
}

public enum LiveKitNativeLogging {
    private static let state = LiveKitNativeLoggingState()

    public static func configure(level: LiveKitNativeLogLevel, logger: any LiveKitNativeLogger = OSLogLiveKitNativeLogger()) {
        state.configure(level: level, logger: logger)
    }

    static func log(
        _ level: LiveKitNativeLogLevel,
        _ message: @autoclosure () -> String,
        file: String = #fileID,
        line: UInt = #line
    ) {
        let loggingState = state.snapshot()

        guard level.rawValue >= loggingState.level.rawValue, loggingState.level != .off else {
            return
        }

        loggingState.logger.log(level: level, message: message(), file: file, line: line)
    }
}

private final class LiveKitNativeLoggingState: @unchecked Sendable {
    private let lock = NSLock()
    private var level: LiveKitNativeLogLevel = .warning
    private var logger: any LiveKitNativeLogger = OSLogLiveKitNativeLogger()

    func configure(level: LiveKitNativeLogLevel, logger: any LiveKitNativeLogger) {
        lock.withLock {
            self.level = level
            self.logger = logger
        }
    }

    func snapshot() -> (level: LiveKitNativeLogLevel, logger: any LiveKitNativeLogger) {
        lock.withLock {
            (level, logger)
        }
    }
}

public struct OSLogLiveKitNativeLogger: LiveKitNativeLogger {
    private let subsystem: String
    private let category: String

    public init(subsystem: String = "LiveKitNative", category: String = "SDK") {
        self.subsystem = subsystem
        self.category = category
    }

    public func log(level: LiveKitNativeLogLevel, message: String, file: String, line: UInt) {
        #if canImport(OSLog)
        os_log(
            "%{public}@",
            log: OSLog(subsystem: subsystem, category: category),
            type: level.osLogType,
            "\(file):\(line) \(message)"
        )
        #else
        print("[\(level)] \(file):\(line) \(message)")
        #endif
    }
}

#if canImport(OSLog)
private extension LiveKitNativeLogLevel {
    var osLogType: OSLogType {
        switch self {
        case .debug:
            return .debug
        case .info:
            return .info
        case .warning:
            return .default
        case .error:
            return .error
        case .off:
            return .default
        }
    }
}
#endif
