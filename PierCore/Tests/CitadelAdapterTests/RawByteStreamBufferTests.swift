@testable import CitadelAdapter
import Foundation
import PierSupport
import XCTest

final class RawByteStreamBufferTests: XCTestCase {
    func testRejectsStaleAndSecondSubscribersWithoutReplacingOwner() async throws {
        var buffer = RawByteStreamBuffer()
        buffer.activate(generation: 2)
        let owner = buffer.makeStream(generation: 2)
        let duplicate = buffer.makeStream(generation: 2)
        let stale = buffer.makeStream(generation: 1)
        buffer.yield(Data("owned".utf8))
        buffer.finish()

        var ownerIterator = owner.makeAsyncIterator()
        let owned = try await ownerIterator.next()
        XCTAssertEqual(owned, Data("owned".utf8))
        var duplicateIterator = duplicate.makeAsyncIterator()
        await assertFailure(&duplicateIterator, expected: .unavailable("Incoming byte stream already has a subscriber"))
        var staleIterator = stale.makeAsyncIterator()
        await assertFailure(&staleIterator, expected: .transport("Stale incoming byte stream generation"))
    }

    func testPreservesRawChunksYieldedBeforeAndAfterSubscription() async throws {
        var buffer = RawByteStreamBuffer()
        buffer.activate(generation: 1)
        let first = Data([0x1B, 0x50, 0x31, 0x30])
        let second = Data([0x30, 0x30, 0x70, 0x25, 0x62])
        buffer.yield(first)
        let stream = buffer.makeStream(generation: 1)
        buffer.yield(second)
        buffer.finish()

        var received: [Data] = []
        for try await chunk in stream {
            received.append(chunk)
        }

        XCTAssertEqual(received, [first, second])
    }

    func testDeliversBufferedTerminalErrorAfterRawBytes() async throws {
        var buffer = RawByteStreamBuffer()
        buffer.activate(generation: 1)
        let bytes = Data("%error 1 0 0\n".utf8)
        buffer.yield(bytes)
        buffer.finish(throwing: PierError.transport("channel failed"))
        let stream = buffer.makeStream(generation: 1)
        var iterator = stream.makeAsyncIterator()

        let received = try await iterator.next()
        XCTAssertEqual(received, bytes)
        do {
            _ = try await iterator.next()
            XCTFail("Expected buffered terminal error")
        } catch {
            XCTAssertEqual(error as? PierError, .transport("channel failed"))
        }
    }

    func testFailsWithTypedOverflowWithoutSilentlyDroppingBufferedBytes() async throws {
        var buffer = RawByteStreamBuffer(maximumBufferedBytes: 4, maximumBufferedChunks: 2)
        buffer.activate(generation: 1)
        buffer.yield(Data("abcde".utf8))
        let stream = buffer.makeStream(generation: 1)
        var received = Data()

        do {
            for try await chunk in stream {
                received.append(chunk)
            }
            XCTFail("Expected overflow")
        } catch {
            XCTAssertEqual(error as? PierError, .transport("Incoming SSH byte buffer exceeded 4 bytes"))
        }
        XCTAssertEqual(buffer.failure, .overflow(maximumBufferedBytes: 4))
        XCTAssertEqual(received, Data("abcd".utf8))
    }

    func testFailsWithTypedOverflowAfterSubscription() async throws {
        var buffer = RawByteStreamBuffer(maximumBufferedBytes: 4, maximumBufferedChunks: 2)
        buffer.activate(generation: 1)
        let stream = buffer.makeStream(generation: 1)
        buffer.yield(Data("abcde".utf8))
        var received = Data()

        do {
            for try await chunk in stream {
                received.append(chunk)
            }
            XCTFail("Expected overflow")
        } catch {
            XCTAssertEqual(error as? PierError, .transport("Incoming SSH byte buffer exceeded 4 bytes"))
        }
        XCTAssertEqual(buffer.failure, .overflow(maximumBufferedBytes: 4))
        XCTAssertEqual(received, Data("abcd".utf8))
    }

    func testByteLimitRemainsValidWhenRequestedChunkCountExceedsBytes() async throws {
        var buffer = RawByteStreamBuffer(maximumBufferedBytes: 2, maximumBufferedChunks: 8)
        buffer.activate(generation: 1)
        buffer.yield(Data("abc".utf8))
        let stream = buffer.makeStream(generation: 1)
        var received = Data()

        do {
            for try await chunk in stream {
                received.append(chunk)
            }
            XCTFail("Expected overflow")
        } catch {
            XCTAssertEqual(error as? PierError, .transport("Incoming SSH byte buffer exceeded 2 bytes"))
        }
        XCTAssertEqual(received, Data("ab".utf8))
    }

    func testNonDivisibleConfigurationNeverExceedsDeclaredByteLimit() async throws {
        var buffer = RawByteStreamBuffer(maximumBufferedBytes: 5, maximumBufferedChunks: 2)
        buffer.activate(generation: 1)
        buffer.yield(Data("abcde".utf8))
        let stream = buffer.makeStream(generation: 1)
        var received = Data()

        do {
            for try await chunk in stream {
                received.append(chunk)
            }
            XCTFail("Expected overflow at effective four-byte capacity")
        } catch {
            XCTAssertEqual(error as? PierError, .transport("Incoming SSH byte buffer exceeded 5 bytes"))
        }
        XCTAssertEqual(received, Data("abcd".utf8))
        XCTAssertLessThanOrEqual(received.count, 5)
    }

    func testOverflowRemainsTerminalAfterProducerFinishesNormally() async throws {
        var buffer = RawByteStreamBuffer(maximumBufferedBytes: 2, maximumBufferedChunks: 2)
        buffer.activate(generation: 1)
        buffer.yield(Data("abc".utf8))
        buffer.finish()
        let stream = buffer.makeStream(generation: 1)

        do {
            for try await _ in stream {}
            XCTFail("Expected original overflow")
        } catch {
            XCTAssertEqual(error as? PierError, .transport("Incoming SSH byte buffer exceeded 2 bytes"))
        }
        XCTAssertEqual(buffer.failure, .overflow(maximumBufferedBytes: 2))
    }

    func testFirstTerminalErrorWinsOverLaterError() async throws {
        var buffer = RawByteStreamBuffer()
        buffer.activate(generation: 1)
        buffer.finish(throwing: PierError.transport("first"))
        buffer.finish(throwing: PierError.transport("second"))
        let stream = buffer.makeStream(generation: 1)

        do {
            for try await _ in stream {}
            XCTFail("Expected first error")
        } catch {
            XCTAssertEqual(error as? PierError, .transport("first"))
        }
    }

    private func assertFailure(
        _ iterator: inout AsyncThrowingStream<Data, Error>.Iterator,
        expected: PierError
    ) async {
        do {
            _ = try await iterator.next()
            XCTFail("Expected stream failure")
        } catch {
            XCTAssertEqual(error as? PierError, expected)
        }
    }
}
