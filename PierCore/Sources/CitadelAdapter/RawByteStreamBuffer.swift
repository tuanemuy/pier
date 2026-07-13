import Foundation
import PierSupport

enum RawByteStreamFailure: Equatable {
    case overflow(maximumBufferedBytes: Int)
}

struct RawByteStreamBuffer {
    private var continuation: AsyncThrowingStream<Data, Error>.Continuation?
    private var activeGeneration: UInt64?
    private var backlog: [Data] = []
    private var terminalError: (any Error)?
    private var finished = false
    private let maximumBufferedBytes: Int
    private let maximumBufferedChunks: Int
    private let maximumChunkBytes: Int
    private(set) var failure: RawByteStreamFailure?

    init(maximumBufferedBytes: Int = 16 * 1024 * 1024, maximumBufferedChunks: Int = 256) {
        precondition(maximumBufferedBytes > 0)
        precondition(maximumBufferedChunks > 0)
        self.maximumBufferedBytes = maximumBufferedBytes
        self.maximumBufferedChunks = min(maximumBufferedChunks, maximumBufferedBytes)
        maximumChunkBytes = max(1, maximumBufferedBytes / self.maximumBufferedChunks)
    }

    mutating func activate(generation: UInt64) {
        reset()
        activeGeneration = generation
    }

    mutating func makeStream(generation: UInt64) -> AsyncThrowingStream<Data, Error> {
        guard generation == activeGeneration else {
            return failedStream(PierError.transport("Stale incoming byte stream generation"))
        }
        guard continuation == nil else {
            return failedStream(PierError.unavailable("Incoming byte stream already has a subscriber"))
        }
        let pair = AsyncThrowingStream<Data, Error>.makeStream(bufferingPolicy: .bufferingOldest(maximumBufferedChunks))
        for data in backlog {
            if case .dropped = pair.continuation.yield(data) {
                let error = overflowError()
                pair.continuation.finish(throwing: error)
                terminalError = error
                break
            }
        }
        backlog.removeAll(keepingCapacity: true)
        if let terminalError {
            pair.continuation.finish(throwing: terminalError)
        } else if finished {
            pair.continuation.finish()
        } else {
            continuation = pair.continuation
        }
        return pair.stream
    }

    mutating func yield(_ data: Data) {
        guard terminalError == nil, !finished else { return }
        var offset = data.startIndex
        while offset < data.endIndex {
            let end = data.index(offset, offsetBy: maximumChunkBytes, limitedBy: data.endIndex) ?? data.endIndex
            guard enqueue(Data(data[offset ..< end])) else { return }
            offset = end
        }
    }

    mutating func finish(throwing error: (any Error)? = nil) {
        guard terminalError == nil, !finished else { return }
        terminalError = error
        finished = error == nil
        if let continuation {
            if let error {
                continuation.finish(throwing: error)
            } else {
                continuation.finish()
            }
            self.continuation = nil
        }
    }

    mutating func reset() {
        continuation?.finish()
        continuation = nil
        backlog.removeAll(keepingCapacity: true)
        terminalError = nil
        finished = false
        failure = nil
        activeGeneration = nil
    }

    private func failedStream(_ error: any Error) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { $0.finish(throwing: error) }
    }

    private mutating func enqueue(_ data: Data) -> Bool {
        if let continuation {
            switch continuation.yield(data) {
            case .enqueued:
                return true
            case .dropped:
                failOverflow()
                return false
            case .terminated:
                return false
            @unknown default:
                failOverflow()
                return false
            }
        }
        guard backlog.count < maximumBufferedChunks else {
            failOverflow()
            return false
        }
        backlog.append(data)
        return true
    }

    private mutating func failOverflow() {
        let error = overflowError()
        terminalError = error
        continuation?.finish(throwing: error)
        continuation = nil
    }

    private mutating func overflowError() -> PierError {
        failure = .overflow(maximumBufferedBytes: maximumBufferedBytes)
        return .transport("Incoming SSH byte buffer exceeded \(maximumBufferedBytes) bytes")
    }
}
