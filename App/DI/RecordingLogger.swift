import Foundation
import PierApplication

final class RecordingLogger: PierLogger, @unchecked Sendable {
    struct Entry {
        let level: LogLevel
        let message: String
    }

    private let lock = NSLock()
    private var storage: [Entry] = []

    func log(_ level: LogLevel, _ message: String) {
        lock.withLock {
            storage.append(Entry(level: level, message: message))
        }
    }

    var entries: [Entry] {
        lock.withLock { storage }
    }
}
