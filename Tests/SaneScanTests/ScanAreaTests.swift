import XCTest
@testable import SaneScan

final class ScanAreaTests: XCTestCase {
    private let bed = ScanArea(width: 216.7, height: 297.5)

    func testSelectionMapsPositionAndSizeToMillimetres() {
        let selection = ScanSelection(rect: CGRect(x: 0.1, y: 0.2, width: 0.5, height: 0.6))
        let area = selection.area(on: bed)
        XCTAssertEqual(area.x, 21.67, accuracy: 0.0001)
        XCTAssertEqual(area.y, 59.5, accuracy: 0.0001)
        XCTAssertEqual(area.width, 108.35, accuracy: 0.0001)
        XCTAssertEqual(area.height, 178.5, accuracy: 0.0001)
    }

    func testExistingPaperAreaAndOffsetRoundTrip() {
        for area in [ScanArea(width: 210, height: 297),
                     ScanArea(x: 20, y: 40, width: 100, height: 150)] {
            let result = ScanSelection(area: area, bed: bed).area(on: bed)
            XCTAssertEqual(result.x, area.x, accuracy: 0.0001)
            XCTAssertEqual(result.y, area.y, accuracy: 0.0001)
            XCTAssertEqual(result.width, area.width, accuracy: 0.0001)
            XCTAssertEqual(result.height, area.height, accuracy: 0.0001)
        }
    }

    func testDraggingEachCornerKeepsOppositeCornerFixed() {
        let opposites: [ScanSelection.Corner: ScanSelection.Corner] = [
            .topLeft: .bottomRight, .topRight: .bottomLeft,
            .bottomLeft: .topRight, .bottomRight: .topLeft,
        ]
        for (corner, opposite) in opposites {
            var selection = ScanSelection.full
            let fixed = selection.point(for: opposite)
            selection.move(corner, to: CGPoint(x: 0.4, y: 0.6))
            XCTAssertEqual(selection.point(for: corner), CGPoint(x: 0.4, y: 0.6))
            XCTAssertEqual(selection.point(for: opposite), fixed)
        }
    }

    func testCornersCannotLeaveBedOrCrossOppositeCorner() {
        for corner in ScanSelection.Corner.allCases {
            var selection = ScanSelection(rect: CGRect(x: 0.2, y: 0.2, width: 0.6, height: 0.6))
            selection.move(corner, to: CGPoint(x: -10, y: -10))
            assertValid(selection)
            selection.move(corner, to: CGPoint(x: 10, y: 10))
            assertValid(selection)
        }
    }

    func testInvalidInitialSelectionIsClamped() {
        let selection = ScanSelection(rect: CGRect(x: 2, y: -1, width: 3, height: 4))
        assertValid(selection)
    }

    func testFullSelectionPreservesBedDimensions() {
        XCTAssertEqual(ScanSelection.full.area(on: bed), bed)
    }

    func testScannerArgumentsIncludeOffsetsAndUseDecimalPoints() {
        let area = ScanArea(x: 21.67, y: 59.5, width: 108.35, height: 178.5)
        XCTAssertEqual(area.arguments, ["-l", "21.670", "-t", "59.500",
                                        "-x", "108.350", "-y", "178.500"])
    }

    func testRoundingCannotExceedBedAtBottomRight() throws {
        let selection = ScanSelection(rect: CGRect(x: 0.123456, y: 0.654321, width: 1, height: 1))
        let args = selection.area(on: bed).arguments
        let x = try XCTUnwrap(Double(args[1]))
        let y = try XCTUnwrap(Double(args[3]))
        let width = try XCTUnwrap(Double(args[5]))
        let height = try XCTUnwrap(Double(args[7]))
        XCTAssertLessThanOrEqual(x + width, bed.width)
        XCTAssertLessThanOrEqual(y + height, bed.height)
    }

    private func assertValid(_ selection: ScanSelection, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertGreaterThanOrEqual(selection.rect.minX, 0, file: file, line: line)
        XCTAssertGreaterThanOrEqual(selection.rect.minY, 0, file: file, line: line)
        XCTAssertLessThanOrEqual(selection.rect.maxX, 1, file: file, line: line)
        XCTAssertLessThanOrEqual(selection.rect.maxY, 1, file: file, line: line)
        XCTAssertGreaterThanOrEqual(selection.rect.width, ScanSelection.minimumSpan - 1e-12, file: file, line: line)
        XCTAssertGreaterThanOrEqual(selection.rect.height, ScanSelection.minimumSpan - 1e-12, file: file, line: line)
    }
}
