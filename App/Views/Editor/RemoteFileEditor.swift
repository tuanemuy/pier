import PierApplication
import PierDomain

protocol RemoteFileEditor: Sendable {
    func open(path: String) async throws -> RemoteFile
    func save(_ file: RemoteFile) async throws
}

struct LiveRemoteFileEditor: RemoteFileEditor {
    private let transfer: any FileTransferPort

    init(transfer: any FileTransferPort) {
        self.transfer = transfer
    }

    func open(path: String) async throws -> RemoteFile {
        try await OpenRemoteFile(transfer: transfer)(path: path)
    }

    func save(_ file: RemoteFile) async throws {
        try await SaveRemoteFile(transfer: transfer)(file)
    }
}

enum RemoteFileEditorError: Error, Equatable {
    case fileNotFound(String)
}

actor InMemoryRemoteFileEditor: RemoteFileEditor {
    private var files: [String: String]

    init(files: [String: String] = [:]) {
        self.files = files
    }

    func open(path: String) throws -> RemoteFile {
        guard let contents = files[path] else {
            throw RemoteFileEditorError.fileNotFound(path)
        }
        return try RemoteFile.parse(path: path, contents: contents).get()
    }

    func save(_ file: RemoteFile) {
        files[file.path] = file.contents
    }
}
