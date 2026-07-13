@testable import Pier
import PierDomain
import XCTest

final class AsyncViewStatesTests: XCTestCase {
    func testWorkspacePreparationPublishesOnlyLatestCompletedGeneration() throws {
        var machine = WorkspacePreparationMachine()
        let stale = machine.begin()
        let current = machine.begin()
        let host = try host()

        XCTAssertFalse(machine.complete(host: host, sessions: ["stale"], generation: stale))
        XCTAssertEqual(machine.state, .discovering)
        XCTAssertTrue(machine.complete(host: host, sessions: ["main"], generation: current))
        XCTAssertEqual(machine.state, .loaded(host: host, sessions: ["main"]))
    }

    func testWorkspaceRetryClearsFailureBeforePublishingNewData() throws {
        var machine = WorkspacePreparationMachine()
        let failedGeneration = machine.begin()
        machine.fail(message: "offline", generation: failedGeneration)
        XCTAssertEqual(machine.state, .failed(message: "offline"))

        let retry = machine.begin()
        XCTAssertEqual(machine.state, .discovering)
        let host = try host()
        machine.complete(host: host, sessions: [], generation: retry)
        XCTAssertEqual(machine.state, .loaded(host: host, sessions: []))
    }

    func testEditorSaveFailureReturnsToEditableStateWithDraft() throws {
        let file = try remoteFile()
        var state = RemoteFileEditorState.loading
        state.load(file)
        state.updateDraft("changed")
        state.beginSaving(file: file, draft: "changed")
        state.updateDraft("must not replace submitted draft")
        XCTAssertEqual(state, .saving(file: file, draft: "changed"))
        state.failSaving(message: "offline")

        XCTAssertEqual(state, .loaded(file: file, draft: "changed", saveFailure: "offline"))
        state.beginSaving(file: file, draft: "changed")
        XCTAssertEqual(state, .saving(file: file, draft: "changed"))
    }

    func testHostListIgnoresOlderLoadedAndFailedResults() throws {
        var machine = HostListStateMachine()
        let stale = machine.begin()
        let current = machine.begin()
        let host = try host()

        XCTAssertTrue(machine.complete(hosts: [host], keys: [], generation: current))
        XCTAssertFalse(machine.complete(hosts: [], keys: [], generation: stale))
        XCTAssertFalse(machine.fail(message: "stale failure", generation: stale))
        XCTAssertEqual(machine.state, .loaded(hosts: [host], keys: []))
    }

    func testKeyManagerIgnoresOlderLoadedAndFailedResults() {
        var machine = KeyManagerStateMachine()
        let stale = machine.begin()
        let current = machine.begin()
        let key = SSHKeyMetadata(
            id: KeyID(rawValue: "key"),
            name: "Current",
            kind: .ed25519,
            publicKey: "ssh-ed25519 current"
        )

        XCTAssertTrue(machine.complete(keys: [key], generation: current))
        XCTAssertFalse(machine.complete(keys: [], generation: stale))
        XCTAssertFalse(machine.fail(message: "stale failure", generation: stale))
        XCTAssertEqual(machine.state, .loaded([key]))
    }

    private func host() throws -> Host {
        try Host.parse(
            id: HostID(rawValue: "host"),
            name: "Host",
            address: "example.com",
            username: "pier",
            keyID: KeyID(rawValue: "key")
        ).get()
    }

    private func remoteFile() throws -> RemoteFile {
        try RemoteFile.parse(path: "/tmp/file", contents: "initial").get()
    }
}
