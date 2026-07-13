import Foundation
import PierApplication

struct SystemClock: Clock {
    func now() -> Date {
        Date()
    }

    func sleep(for duration: Duration) async throws {
        try await Task.sleep(for: duration)
    }
}
