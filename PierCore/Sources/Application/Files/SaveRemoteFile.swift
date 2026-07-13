import Foundation
import PierDomain

public struct SaveRemoteFile: Sendable {
    private let transfer: any FileTransferPort
    public init(transfer: any FileTransferPort) {
        self.transfer = transfer
    }

    public func callAsFunction(_ file: RemoteFile) async throws {
        try await transfer.write(Data(file.contents.utf8), path: file.path)
    }
}
