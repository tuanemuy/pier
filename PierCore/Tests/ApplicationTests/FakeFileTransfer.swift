import Foundation
import PierApplication
import PierSupport

actor FakeFileTransfer: FileTransferPort {
    private var files: [String: Data]
    private let readError: PierError?
    private let writeError: PierError?
    private(set) var reads: [String] = []
    private(set) var writes: [(path: String, data: Data)] = []

    init(
        files: [String: Data] = [:],
        readError: PierError? = nil,
        writeError: PierError? = nil
    ) {
        self.files = files
        self.readError = readError
        self.writeError = writeError
    }

    func read(path: String) async throws -> Data {
        reads.append(path)
        if let readError { throw readError }
        return files[path] ?? Data()
    }

    func write(_ data: sending Data, path: String) async throws {
        writes.append((path, data))
        if let writeError { throw writeError }
        files[path] = data
    }

    func data(at path: String) -> Data? {
        files[path]
    }
}
