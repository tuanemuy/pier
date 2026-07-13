import Foundation
import PierApplication
import PierDomain
import PierSupport
import XCTest

final class RemoteFileUseCaseTests: XCTestCase {
    func testOpenRemoteFileReadsAndDecodesUTF8() async throws {
        let transfer = FakeFileTransfer(files: ["/tmp/note.txt": Data("hello".utf8)])

        let file = try await OpenRemoteFile(transfer: transfer)(path: "/tmp/note.txt")

        XCTAssertEqual(file.path, "/tmp/note.txt")
        XCTAssertEqual(file.contents, "hello")
        let reads = await transfer.reads
        XCTAssertEqual(reads, ["/tmp/note.txt"])
    }

    func testOpenRemoteFileRejectsInvalidUTF8() async {
        let transfer = FakeFileTransfer(files: ["/tmp/note.txt": Data([0xFF])])

        do {
            _ = try await OpenRemoteFile(transfer: transfer)(path: "/tmp/note.txt")
            XCTFail("Expected invalid encoding")
        } catch {
            XCTAssertEqual(error as? RemoteFileError, .invalidEncoding)
        }
    }

    func testOpenRemoteFilePropagatesTransferFailure() async {
        let expected = PierError.transport("read failed")
        let transfer = FakeFileTransfer(readError: expected)

        do {
            _ = try await OpenRemoteFile(transfer: transfer)(path: "/tmp/note.txt")
            XCTFail("Expected transfer error")
        } catch {
            XCTAssertEqual(error as? PierError, expected)
        }
    }

    func testSaveRemoteFileWritesUTF8() async throws {
        let transfer = FakeFileTransfer()
        let file = try RemoteFile.parse(path: "/tmp/note.txt", contents: "日本語").get()

        try await SaveRemoteFile(transfer: transfer)(file)

        let data = await transfer.data(at: "/tmp/note.txt")
        XCTAssertEqual(data, Data("日本語".utf8))
    }

    func testSaveRemoteFilePropagatesTransferFailure() async throws {
        let expected = PierError.transport("write failed")
        let transfer = FakeFileTransfer(writeError: expected)
        let file = try RemoteFile.parse(path: "/tmp/note.txt", contents: "hello").get()

        do {
            try await SaveRemoteFile(transfer: transfer)(file)
            XCTFail("Expected transfer error")
        } catch {
            XCTAssertEqual(error as? PierError, expected)
        }
    }
}
