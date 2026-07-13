import Foundation
import PierApplication

struct SystemIdentifierGenerator: IdentifierGenerator {
    func makeUUID() -> UUID {
        UUID()
    }
}
