import Foundation
import PierApplication

struct SessionResourceSlot<Client, Writer> {
    var client: Client?
    var writer: Writer?
    var producer: Task<Void, Never>?
    var endpoint: SSHEndpoint?
    var inboundBytes = RawByteStreamBuffer()

    mutating func detach() -> Self {
        let detached = self
        self = Self()
        return detached
    }
}
