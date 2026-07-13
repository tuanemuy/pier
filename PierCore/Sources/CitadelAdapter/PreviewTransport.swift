import Foundation
import PierApplication
import PierDomain
import PierSupport

public actor PreviewTransport: TransportPort, FileTransferPort {
    private var inboundBytes = RawByteStreamBuffer()
    private var files: [String: Data]
    private var generation: UInt64 = 0
    public init(files: [String: Data] = [:]) {
        self.files = files
    }

    public func execute(_ command: String, at _: SSHEndpoint) async throws -> Data {
        command.contains("list-sessions") ? Data("main\nwork\n".utf8) : Data()
    }

    public func executeIdempotent(_ command: String, at endpoint: SSHEndpoint) async throws -> Data {
        try await execute(command, at: endpoint)
    }

    public func connect(to _: SSHEndpoint, command _: String) async throws -> TransportConnectionGeneration {
        generation &+= 1
        inboundBytes.activate(generation: generation)
        inboundBytes.yield(Data("%begin 1 0 0\n%end 1 0 0\n".utf8))
        return TransportConnectionGeneration(rawValue: generation)
    }

    public func send(_ data: sending Data, generation: TransportConnectionGeneration) async throws {
        guard generation.rawValue == self.generation else { throw PierError.transport("Stale SSH writer") }
        guard let command = String(data: data, encoding: .utf8) else {
            throw PierError.invalidResponse("Preview command contains invalid UTF-8")
        }
        let delimiter = SessionTreeRecordFormat.delimiter
        let response = if command.hasPrefix("list-windows") {
            ["$1", "main", "@1", "0", "shell", "1"].joined(separator: delimiter)
        } else if command.hasPrefix("list-panes") {
            ["$1", "@1", "%1", "0", "0", "shell", "zsh", "/home/pier", "80", "24", "0", "1"]
                .joined(separator: delimiter)
        } else if command.hasPrefix("capture-pane") {
            "Pier preview ready"
        } else {
            ""
        }
        inboundBytes.yield(Data(("%begin 1 1 0\n" + (response.isEmpty ? "" : response + "\n") + "%end 1 1 0\n").utf8))
        if command.hasPrefix("send-keys") { inboundBytes.yield(Data("%output %1 preview\\015\\012\n".utf8)) }
    }

    public func incomingBytes(
        generation: TransportConnectionGeneration
    ) async -> AsyncThrowingStream<Data, Error> {
        inboundBytes.makeStream(generation: generation.rawValue)
    }

    public func disconnect() async {
        generation &+= 1
        inboundBytes.reset()
    }

    public func read(path: String) async throws -> Data {
        files[path] ?? Data()
    }

    public func write(_ data: sending Data, path: String) async throws {
        files[path] = data
    }
}
