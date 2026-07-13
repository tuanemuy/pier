import Foundation
import PersistenceAdapter
import PierApplication
import PierDomain
import XCTest

final class FileCommandJournalTests: XCTestCase {
    func testPersistsFinishedAndRunningBlocksAcrossInstances() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appending(path: "journal.json")
        let key = try CommandJournalKey(address: "host", username: "user", paneID: paneID("%7"))
        let blocks = [
            CommandBlock(
                id: UUID(),
                command: "echo ok",
                output: "ok",
                startedAt: Date(timeIntervalSince1970: 10),
                duration: .milliseconds(125),
                status: .finished(exitCode: 0)
            ),
            CommandBlock(
                id: UUID(),
                command: "sleep 10",
                output: "",
                startedAt: Date(timeIntervalSince1970: 20),
                duration: nil,
                status: .running
            )
        ]

        try await FileCommandJournal(fileURL: fileURL).save(blocks, for: key)
        let restored = try await FileCommandJournal(fileURL: fileURL).load(for: key)

        XCTAssertEqual(restored, blocks)
    }

    func testRemoveOnlyDeletesMatchingHostAndPane() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = FileCommandJournal(fileURL: directory.appending(path: "journal.json"))
        let first = try CommandJournalKey(address: "host-a", username: "user", paneID: paneID("%1"))
        let second = try CommandJournalKey(address: "host-b", username: "user", paneID: paneID("%1"))
        let block = CommandBlock(
            id: UUID(),
            command: "true",
            output: "",
            startedAt: Date(timeIntervalSince1970: 0),
            duration: .milliseconds(1),
            status: .finished(exitCode: 0)
        )
        try await journal.save([block], for: first)
        try await journal.save([block], for: second)

        try await journal.remove(for: first)

        let removed = try await journal.load(for: first)
        let retained = try await journal.load(for: second)
        XCTAssertEqual(removed, [])
        XCTAssertEqual(retained, [block])
    }
}
