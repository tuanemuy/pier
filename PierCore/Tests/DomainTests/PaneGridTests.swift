import PierDomain
import XCTest

final class PaneGridTests: XCTestCase {
    func testFindsNearestPaneInEachDirection() throws {
        let center = try Pane(id: paneID("%1"), position: GridPosition(x: 1, y: 1))
        let left = try Pane(id: paneID("%2"), position: GridPosition(x: 0, y: 1))
        let farLeft = try Pane(id: paneID("%3"), position: GridPosition(x: -1, y: 1))
        let grid = PaneGrid(panes: [center, farLeft, left])
        XCTAssertEqual(grid.pane(from: center.id, toward: .leftward)?.id, left.id)
        XCTAssertNil(grid.pane(from: center.id, toward: .rightward))
    }

    func testMapsEmptyDirectionToSplitCommand() throws {
        let center = try Pane(id: paneID("%1"), position: GridPosition(x: 1, y: 1))
        let cases: [(Direction, String)] = [
            (.leftward, "split-window -h -b -t %1"),
            (.rightward, "split-window -h -t %1"),
            (.upward, "split-window -v -b -t %1"),
            (.downward, "split-window -v -t %1")
        ]
        for (direction, expected) in cases {
            XCTAssertEqual(PaneGrid(panes: [center]).splitCommand(paneID: center.id, toward: direction), expected)
        }
    }

    func testDoesNotSelectDiagonalPaneWithoutPerpendicularOverlap() throws {
        let current = try Pane(
            id: paneID("%1"),
            position: GridPosition(x: 0, y: 0),
            width: 40,
            height: 12
        )
        let diagonal = try Pane(
            id: paneID("%2"),
            position: GridPosition(x: 50, y: 20),
            width: 30,
            height: 10
        )
        let right = try Pane(
            id: paneID("%3"),
            position: GridPosition(x: 41, y: 3),
            width: 30,
            height: 9
        )
        let grid = PaneGrid(panes: [current, diagonal, right])

        XCTAssertEqual(grid.pane(from: current.id, toward: .rightward)?.id, right.id)
        XCTAssertNil(PaneGrid(panes: [current, diagonal]).pane(from: current.id, toward: .rightward))
    }
}
