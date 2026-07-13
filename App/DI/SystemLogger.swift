import OSLog
import PierApplication

struct SystemLogger: PierLogger {
    private let logger = Logger(subsystem: "app.pier.client", category: "connection")

    func log(_ level: LogLevel, _ message: String) {
        switch level {
        case .debug:
            logger.debug("\(message, privacy: .public)")
        case .info:
            logger.info("\(message, privacy: .public)")
        case .warning:
            logger.warning("\(message, privacy: .public)")
        case .error:
            logger.error("\(message, privacy: .public)")
        }
    }
}
