import Foundation
import PierDomain

public struct OpenRemoteFile: Sendable {
    private let transfer: any FileTransferPort
    public init(transfer: any FileTransferPort) {
        self.transfer = transfer
    }

    public func callAsFunction(path: String) async throws -> RemoteFile {
        let data = try await transfer.read(path: path)
        guard let contents = String(data: data, encoding: .utf8) else { throw RemoteFileError.invalidEncoding }
        return try RemoteFile.parse(path: path, contents: contents).get()
    }
}
