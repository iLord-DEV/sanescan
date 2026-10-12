import XCTest
@testable import SaneScan

final class ScannerDeviceTests: XCTestCase {
    func testParsesDeviceList() {
        let output = """
        device `genesys:libusb:002:002' is a Canon LiDE 210 flatbed scanner
        device `epson2:libusb:001:004' is a Epson GT-S80 flatbed scanner
        device `pixma:04A91234_ABCDEF' is a CANON Canon PIXMA MG5300 multi-function peripheral
        """
        let devices = ScannerDevice.parseList(output)
        XCTAssertEqual(devices.map(\.id), ["genesys:libusb:002:002", "epson2:libusb:001:004", "pixma:04A91234_ABCDEF"])
        XCTAssertEqual(devices.map(\.name), ["Canon LiDE 210", "Epson GT-S80", "CANON Canon PIXMA MG5300"])
    }

    func testSelectorUsesBackendWhenUnique() {
        let lide = ScannerDevice(id: "genesys:libusb:002:002", name: "Canon LiDE 210")
        let epson1 = ScannerDevice(id: "epson2:libusb:001:004", name: "Epson A")
        let epson2 = ScannerDevice(id: "epson2:libusb:001:005", name: "Epson B")
        let all = [lide, epson1, epson2]
        XCTAssertEqual(lide.selector(in: all), "genesys")
        XCTAssertEqual(epson1.selector(in: all), "epson2:libusb:001:004")
        XCTAssertEqual(epson2.selector(in: all), "epson2:libusb:001:005")
    }

    func testIgnoresNoise() {
        let output = """

        No scanners were identified. If you were expecting something different,
        check that the scanner is plugged in, turned on and detected by the
        sane-find-scanner tool (if appropriate).
        """
        XCTAssertTrue(ScannerDevice.parseList(output).isEmpty)
    }
}

final class ScannerCapabilitiesTests: XCTestCase {
    func testParsesGenesysListing() {
        let output = """
        Output format is not set, using pnm as a default.

        All options specific to device `genesys:libusb:002:002':
          Scan Mode:
            --mode Color|Gray [Gray]
                Selects the scan mode (e.g., lineart, monochrome, or color).
            --source Flatbed [Flatbed]
                Selects the scan source (such as a document-feeder).
            --resolution 4800|2400|1200|600|300|150|100|75dpi [75]
                Sets the resolution of the scanned image.
          Geometry:
            -l 0..216.7mm [0]
                Top-left x position of scan area.
            -t 0..297.5mm [0]
                Top-left y position of scan area.
            -x 0..216.7mm [216.7]
                Width of scan-area.
            -y 0..297.5mm [297.5]
                Height of scan-area.
        """
        let caps = ScannerCapabilities.parse(output)
        XCTAssertEqual(caps.modes, ["Color", "Gray"])
        XCTAssertEqual(caps.sources, ["Flatbed"])
        XCTAssertEqual(caps.resolutions, [75, 100, 150, 300, 600, 1200, 2400, 4800])
        XCTAssertEqual(caps.maxWidth, 216.7)
        XCTAssertEqual(caps.maxHeight, 297.5)
        XCTAssertFalse(caps.hasFeeder)
    }

    func testParsesRangeResolutionAndFeeder() {
        let output = """
            --mode Lineart|Gray|Color [Color]
            --source Flatbed|ADF|ADF Duplex [Flatbed]
            --resolution 50..1200dpi (in steps of 1) [300]
            -x 0..215.9mm [215.9]
            -y 0..355.6mm [355.6]
        """
        let caps = ScannerCapabilities.parse(output)
        XCTAssertEqual(caps.modes, ["Lineart", "Gray", "Color"])
        XCTAssertEqual(caps.sources, ["Flatbed", "ADF", "ADF Duplex"])
        XCTAssertEqual(caps.resolutions, [75, 100, 150, 200, 300, 400, 600, 1200])
        XCTAssertEqual(caps.feederSource, "ADF")
        XCTAssertEqual(caps.maxHeight, 355.6)
    }

    func testMissingOptionsLeaveDefaults() {
        let caps = ScannerCapabilities.parse("nothing useful here")
        XCTAssertEqual(caps, ScannerCapabilities())
    }
}

final class PaperSizeTests: XCTestCase {
    private let lide = ScannerCapabilities(modes: [], sources: [], resolutions: [], maxWidth: 216.7, maxHeight: 297.5)

    func testA4FitsOnLide() {
        let area = PaperSize.a4.scanArea(for: lide)
        XCTAssertEqual(area?.width, 210)
        XCTAssertEqual(area?.height, 297)
    }

    func testLegalIsClampedToDevice() {
        let area = PaperSize.legal.scanArea(for: lide)
        XCTAssertEqual(area?.width, 215.9)
        XCTAssertEqual(area?.height, 297.5)
    }

    func testFullUsesDeviceMaximum() {
        let area = PaperSize.full.scanArea(for: lide)
        XCTAssertEqual(area?.width, 216.7)
        XCTAssertEqual(area?.height, 297.5)
    }

    func testFullWithoutDeviceInfoPassesNothing() {
        XCTAssertNil(PaperSize.full.scanArea(for: ScannerCapabilities()))
    }
}

final class ScanModeLabelTests: XCTestCase {
    func testPrefersGrayForDocuments() {
        XCTAssertEqual(ScanModeLabel.preferredMode(from: ["Color", "Lineart", "Gray"]), "Gray")
        XCTAssertEqual(ScanModeLabel.preferredMode(from: ["Color", "Lineart"]), "Color")
        XCTAssertEqual(ScanModeLabel.preferredMode(from: ["24bit Color", "True Gray"]), "True Gray")
    }

    func testLabels() {
        XCTAssertEqual(ScanModeLabel.kind(of: "Gray"), .gray)
        XCTAssertEqual(ScanModeLabel.kind(of: "Lineart"), .lineart)
        XCTAssertEqual(ScanModeLabel.kind(of: "Exotic"), .other)
        XCTAssertEqual(ScanModeLabel.label(for: "Exotic"), "Exotic")
    }
}
