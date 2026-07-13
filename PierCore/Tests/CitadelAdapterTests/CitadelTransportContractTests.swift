@testable import CitadelAdapter
import Foundation
import NIOCore
import PierSupport
import XCTest

final class CitadelTransportContractTests: XCTestCase {
    fileprivate enum TestError: Error { case transient, terminal }

    func testRetriesTransientIdempotentOperationWithBoundedAttempts() async throws {
        let recorder = AttemptRecorder(failures: 2)
        let policy = DriverRetryPolicy(
            maximumAttempts: 3,
            delays: [.milliseconds(1)],
            sleep: { _ in },
            isTransient: { ($0 as? TestError) == .transient }
        )

        let value = try await policy.run(safety: .idempotent) { try await recorder.perform() }

        XCTAssertEqual(value, "ok")
        let attempts = await recorder.attempts
        XCTAssertEqual(attempts, 3)
    }

    func testDisconnectAwaitsCancellationInsensitiveEstablishmentBeforeReconnect() async throws {
        let gate = EstablishmentGate()
        let state = QuiescenceState()
        let establishment = ConnectionEstablishment<String>(generation: 1) {
            await gate.stall()
            return "old-client"
        }
        await gate.waitUntilStalled()

        let disconnect = Task {
            await state.markStarted()
            await establishment.cancelAndWait()
            await state.markCompleted()
        }
        await state.waitUntilStarted()
        while !establishment.task.isCancelled {
            await Task.yield()
        }
        let completedWhileStalled = await state.completed
        XCTAssertFalse(completedWhileStalled)
        XCTAssertTrue(establishment.task.isCancelled)

        await gate.resume()
        await disconnect.value
        let completedAfterRelease = await state.completed
        XCTAssertTrue(completedAfterRelease)

        var lifecycle = TransportLifecycle()
        let oldGeneration = try lifecycle.beginConnection()
        lifecycle.invalidateCurrentGeneration()
        lifecycle.finishConnection(generation: oldGeneration)
        lifecycle.finishInvalidatedConnection(generation: lifecycle.generation)
        XCTAssertNoThrow(try lifecycle.beginConnection())
    }

    func testStopsRetryingAtConfiguredMaximum() async throws {
        let recorder = AttemptRecorder(failures: 3)
        let policy = DriverRetryPolicy(
            maximumAttempts: 2,
            delays: [],
            sleep: { _ in },
            isTransient: { ($0 as? TestError) == .transient }
        )

        do {
            _ = try await policy.run(safety: .idempotent) { try await recorder.perform() }
            XCTFail("Expected terminal retry failure")
        } catch {
            XCTAssertEqual(error as? TestError, .transient)
        }
        let attempts = await recorder.attempts
        XCTAssertEqual(attempts, 2)
    }

    func testDoesNotRetryAmbiguousWriteAuthenticationOrCancellation() async throws {
        let ambiguous = AttemptRecorder(failures: 1)
        let policy = DriverRetryPolicy(
            sleep: { _ in },
            isTransient: { _ in true }
        )
        do {
            _ = try await policy.run(safety: .ambiguousWrite) { try await ambiguous.perform() }
            XCTFail("Expected ambiguous write failure")
        } catch {}
        let attempts = await ambiguous.attempts
        XCTAssertEqual(attempts, 1)

        XCTAssertFalse(CitadelTransport.isTransient(PierError.authentication("denied")))
        XCTAssertFalse(CitadelTransport.isTransient(CancellationError()))
    }

    func testClassifiesDriverTimeoutAsTransientButClosedAndEOFAsTerminalTransport() {
        XCTAssertTrue(CitadelTransport.isTransient(ChannelError.connectTimeout(.seconds(1))))
        XCTAssertFalse(CitadelTransport.isTransient(ChannelError.inputClosed))
        XCTAssertFalse(CitadelTransport.isTransient(ChannelError.eof))
        XCTAssertEqual(
            CitadelTransport.translated(ChannelError.inputClosed),
            .transport("SSH connection input was closed by the remote host")
        )
        XCTAssertEqual(
            CitadelTransport.translated(ChannelError.eof),
            .transport("SSH connection reached end-of-file")
        )
    }

    func testLifecycleRejectsConcurrentConnectionAndInvalidatesCancelledGeneration() throws {
        var lifecycle = TransportLifecycle()
        let generation = try lifecycle.beginConnection()
        XCTAssertThrowsError(try lifecycle.beginConnection()) { error in
            XCTAssertEqual(error as? TransportLifecycleError, .connectionInProgress)
        }

        lifecycle.invalidateCurrentGeneration()
        XCTAssertThrowsError(try lifecycle.validate(generation)) { error in
            XCTAssertEqual(error as? TransportLifecycleError, .superseded)
        }
        lifecycle.finishConnection(generation: generation)
        XCTAssertThrowsError(try lifecycle.beginConnection())
        lifecycle.finishInvalidatedConnection(generation: lifecycle.generation)
        XCTAssertNoThrow(try lifecycle.beginConnection())
    }

    func testReadinessFailureCleansEstablishedClientAndAllowsImmediateReconnect() throws {
        var lifecycle = TransportLifecycle()
        let failedGeneration = try lifecycle.beginConnection()
        var resources = SessionResourceSlot<String, String>()
        resources.client = "established-client"

        let cleanupGeneration = try XCTUnwrap(lifecycle.invalidateConnection(ownedBy: failedGeneration))
        let detached = resources.detach()
        XCTAssertEqual(detached.client, "established-client")
        XCTAssertNil(resources.client)
        lifecycle.finishInvalidatedConnection(generation: cleanupGeneration)
        XCTAssertThrowsError(try lifecycle.validate(failedGeneration))

        let reconnectGeneration = try lifecycle.beginConnection()
        XCTAssertNoThrow(try lifecycle.validate(reconnectGeneration))
        XCTAssertNotEqual(failedGeneration, reconnectGeneration)

        lifecycle.finishInvalidatedConnection(generation: cleanupGeneration)
        XCTAssertTrue(lifecycle.connectionInProgress)
        XCTAssertNoThrow(try lifecycle.validate(reconnectGeneration))
        lifecycle.finishConnection(generation: reconnectGeneration)
    }

    func testLifecycleAndCancellationErrorsTranslateToSharedContract() {
        XCTAssertEqual(
            CitadelTransport.translated(TransportLifecycleError.connectionInProgress),
            .unavailable("An SSH connection is already in progress")
        )
        XCTAssertEqual(
            CitadelTransport.translated(TransportLifecycleError.superseded),
            .transport("The SSH connection attempt was superseded")
        )
        XCTAssertEqual(
            CitadelTransport.translated(CancellationError()),
            .transport("SSH operation was cancelled")
        )
    }

    func testProductionResourceCleanupSeamCancelsClosesAndWaitsInOrder() async {
        let recorder = CleanupRecorder()
        let cleanup = SessionResourceCleanup(
            cancelProducer: { recorder.record("cancel") },
            closeClient: { recorder.record("close") },
            waitForProducer: { recorder.record("wait") }
        )

        await cleanup.run()

        XCTAssertEqual(recorder.events, ["cancel", "close", "wait"])
    }

    func testStalledOldResourceCleanupCannotEraseNewResourceSlot() async throws {
        let gate = ProducerGate()
        let oldProducer = Task { await gate.stall() }
        await gate.waitUntilStalled()
        var slot = SessionResourceSlot<String, String>()
        slot.client = "old-client"
        slot.writer = "old-writer"
        slot.producer = oldProducer
        var detached = slot.detach()
        detached.inboundBytes.reset()
        let detachedProducer = detached.producer
        let cleanup = SessionResourceCleanup(
            cancelProducer: { detachedProducer?.cancel() },
            closeClient: {},
            waitForProducer: { await detachedProducer?.value }
        )
        let cleanupTask = Task { await cleanup.run() }

        slot.client = "new-client"
        slot.writer = "new-writer"
        await gate.resume()
        await cleanupTask.value

        XCTAssertEqual(slot.client, "new-client")
        XCTAssertEqual(slot.writer, "new-writer")
        slot.inboundBytes.activate(generation: 1)
        slot.inboundBytes.yield(Data("new-startup".utf8))
        let stream = slot.inboundBytes.makeStream(generation: 1)
        var iterator = stream.makeAsyncIterator()
        let startup = try await iterator.next()
        XCTAssertEqual(startup, Data("new-startup".utf8))
    }
}

private actor AttemptRecorder {
    private var failures: Int
    private(set) var attempts = 0

    init(failures: Int) {
        self.failures = failures
    }

    func perform() throws -> String {
        attempts += 1
        if failures > 0 {
            failures -= 1
            throw CitadelTransportContractTests.TestError.transient
        }
        return "ok"
    }
}

private final class CleanupRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedEvents: [String] = []

    var events: [String] {
        lock.withLock { storedEvents }
    }

    func record(_ event: String) {
        lock.withLock { storedEvents.append(event) }
    }
}

private actor ProducerGate {
    private var stalled = false
    private var stalledWaiter: CheckedContinuation<Void, Never>?
    private var resumeWaiter: CheckedContinuation<Void, Never>?

    func stall() async {
        stalled = true
        stalledWaiter?.resume()
        stalledWaiter = nil
        await withCheckedContinuation { resumeWaiter = $0 }
    }

    func waitUntilStalled() async {
        if stalled { return }
        await withCheckedContinuation { stalledWaiter = $0 }
    }

    func resume() {
        resumeWaiter?.resume()
        resumeWaiter = nil
    }
}

private actor EstablishmentGate {
    private var stalled = false
    private var stalledWaiter: CheckedContinuation<Void, Never>?
    private var resumeWaiter: CheckedContinuation<Void, Never>?

    func stall() async {
        stalled = true
        stalledWaiter?.resume()
        stalledWaiter = nil
        await withCheckedContinuation { resumeWaiter = $0 }
    }

    func waitUntilStalled() async {
        if stalled { return }
        await withCheckedContinuation { stalledWaiter = $0 }
    }

    func resume() {
        resumeWaiter?.resume()
        resumeWaiter = nil
    }
}

private actor QuiescenceState {
    private var started = false
    private var startedWaiter: CheckedContinuation<Void, Never>?
    private(set) var completed = false

    func markStarted() {
        started = true
        startedWaiter?.resume()
        startedWaiter = nil
    }

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { startedWaiter = $0 }
    }

    func markCompleted() {
        completed = true
    }
}
