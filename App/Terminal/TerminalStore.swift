import Foundation
import PierApplication
import PierDomain

enum TerminalEvent {
    case data(Data)
    case reset
}

actor TerminalStore: PaneRendererPort {
    private let maximumBufferedBytes = 8 * 1024 * 1024
    private var buffers: [PaneID: Data] = [:]
    private var continuations: [PaneID: [UInt64: AsyncStream<TerminalEvent>.Continuation]] = [:]
    private var nextToken: UInt64 = 0
    private var activeGeneration: TmuxConnectionGeneration?

    func activate(generation: TmuxConnectionGeneration) async {
        if let activeGeneration, generation.rawValue <= activeGeneration.rawValue { return }
        activeGeneration = generation
        buffers.removeAll(keepingCapacity: true)
        for subscribers in continuations.values {
            for continuation in subscribers.values {
                continuation.yield(.reset)
            }
        }
    }

    func feed(_ data: sending Data, to paneID: PaneID, generation: TmuxConnectionGeneration) async {
        guard generation == activeGeneration else { return }
        await feed(data, to: paneID)
    }

    func reset(paneID: PaneID, generation: TmuxConnectionGeneration) async {
        guard generation == activeGeneration else { return }
        await reset(paneID: paneID)
    }

    func remove(paneID: PaneID, generation: TmuxConnectionGeneration) async {
        guard generation == activeGeneration else { return }
        await remove(paneID: paneID)
    }

    func feed(_ data: sending Data, to paneID: PaneID) async {
        buffers[paneID, default: Data()].append(data)
        if let count = buffers[paneID]?.count, count > maximumBufferedBytes {
            buffers[paneID] = buffers[paneID].map { Data($0.suffix(maximumBufferedBytes)) }
        }
        if let values = continuations[paneID]?.values {
            for continuation in values {
                continuation.yield(.data(data))
            }
        }
    }

    func reset(paneID: PaneID) async {
        buffers[paneID] = Data()
        for continuation in continuations[paneID]?.values ?? [:].values {
            continuation.yield(.reset)
        }
    }

    func remove(paneID: PaneID) async {
        buffers.removeValue(forKey: paneID)
        let removed = continuations.removeValue(forKey: paneID)
        for continuation in removed?.values ?? [:].values {
            continuation.finish()
        }
    }

    func stream(for paneID: PaneID) -> AsyncStream<TerminalEvent> {
        nextToken &+= 1
        let token = nextToken
        let initial = buffers[paneID]
        return AsyncStream { continuation in
            continuations[paneID, default: [:]][token] = continuation
            if let initial, !initial.isEmpty { continuation.yield(.data(initial)) }
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeSubscriber(token: token, paneID: paneID) }
            }
        }
    }

    private func removeSubscriber(token: UInt64, paneID: PaneID) {
        continuations[paneID]?.removeValue(forKey: token)
        if continuations[paneID]?.isEmpty == true {
            continuations.removeValue(forKey: paneID)
        }
    }
}
