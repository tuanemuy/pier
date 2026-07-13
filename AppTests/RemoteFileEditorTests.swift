import CitadelAdapter
import Foundation
@testable import Pier
import PierDomain
import XCTest

final class RemoteFileEditorTests: XCTestCase {
    func testLiveEditorOpensAndSavesThroughFileTransfer() async throws {
        let transfer = PreviewTransport(files: ["/tmp/file.txt": Data("initial".utf8)])
        let editor = LiveRemoteFileEditor(transfer: transfer)

        let opened = try await editor.open(path: "/tmp/file.txt")
        XCTAssertEqual(opened.contents, "initial")

        try await editor.save(opened.editing(contents: "updated"))
        let saved = try await editor.open(path: "/tmp/file.txt")
        XCTAssertEqual(saved.contents, "updated")
    }

    func testInMemoryEditorReportsMissingFileAndPersistsSaves() async throws {
        let editor = InMemoryRemoteFileEditor()

        do {
            _ = try await editor.open(path: "/tmp/missing.txt")
            XCTFail("Expected a missing file error")
        } catch {
            XCTAssertEqual(error as? RemoteFileEditorError, .fileNotFound("/tmp/missing.txt"))
        }

        let file = try RemoteFile.parse(path: "/tmp/new.txt", contents: "created").get()
        await editor.save(file)
        let opened = try await editor.open(path: file.path)
        XCTAssertEqual(opened, file)
    }
}
