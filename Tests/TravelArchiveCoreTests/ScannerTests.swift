import Testing
import Foundation
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers
@testable import TravelArchiveCore

@Suite(.serialized)
final class ScannerTests {
    private var root: URL!
    private var source: URL!
    private var destination: URL!

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("TravelArchiveScannerTests-\(UUID().uuidString)", isDirectory: true)
        source = root.appendingPathComponent("source", isDirectory: true)
        destination = root.appendingPathComponent("destination", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    }

    deinit {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    private func request(start: String = "2026-08-26", end: String = "2026-08-28") -> ArchiveRequest {
        ArchiveRequest(name: "旅行 A", start: CaptureDay(start)!, end: CaptureDay(end)!, source: source, destination: destination)
    }

    @discardableResult
    private func photo(_ name: String, exif: String? = nil, directory: URL? = nil) throws -> URL {
        let directory = directory ?? source!
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        let context = try #require(CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 8, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try #require(context.makeImage())
        let writer = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        var metadata: [CFString: Any] = [:]
        if let exif { metadata[kCGImagePropertyExifDictionary] = [kCGImagePropertyExifDateTimeOriginal: exif] }
        CGImageDestinationAddImage(writer, image, metadata as CFDictionary)
        #expect(CGImageDestinationFinalize(writer))
        return url
    }

    @Test func testInclusiveDateRangeAndChronologicalOrder() async throws {
        try photo("DJI_20260828235959_0003_D.JPG")
        try photo("DJI_20260826000000_0001_D.JPG")
        try photo("DJI_20260827120203_0002_D.JPG")
        try photo("DJI_20260825235959_0000_D.JPG")
        try photo("DJI_20260829000000_0004_D.JPG")
        let report = try await MediaScanner.scan(request: request())
        #expect(report.files.map(\.captureDay.description) == ["2026-08-26", "2026-08-27", "2026-08-28"])
        #expect(report.outsideRangeCount == 2)
        #expect(report.count(.photo) == 3)
        #expect(report.canArchive)
        #expect(report.issues.isEmpty)
        #expect(report.totalBytes == report.files.reduce(0) { $0 + $1.snapshot.size })
        #expect(!(FileManager.default.fileExists(atPath: request().targetURL.path)) , "Scanning must not create the target folder")
    }

    @Test func testMetadataFallbackAndDJIExifConflict() async throws {
        try photo("renamed-photo.jpg", exif: "2026:08:27 01:02:03")
        try photo("DJI_20260826160218_0008_D.JPG", exif: "2026:08:27 16:02:18")
        let report = try await MediaScanner.scan(request: request())
        #expect(report.files.map(\.url.lastPathComponent) == ["renamed-photo.jpg"])
        #expect(report.files.first?.dateBasis == "EXIF 原始拍摄日期")
        #expect(report.issues.contains { $0.message.contains("跨日冲突") && !$0.isBlocking })
    }

    @Test func testMatchingExifConfirmsFilenameDate() async throws {
        try photo("DJI_20260826160218_0008_D.JPG", exif: "2026:08:26 16:02:18")
        let report = try await MediaScanner.scan(request: request())
        #expect(report.files.count == 1)
        #expect(report.files.first?.dateBasis == "DJI 文件名日期")
        #expect(report.issues.isEmpty)
    }

    @Test func testUnknownDateDoesNotUseFilesystemDates() async throws {
        let file = try photo("holiday.jpg")
        let date = try #require(ISO8601DateFormatter().date(from: "2026-08-27T12:00:00Z"))
        try FileManager.default.setAttributes([.modificationDate: date, .creationDate: date], ofItemAtPath: file.path)
        let report = try await MediaScanner.scan(request: request())
        #expect(report.files.isEmpty)
        #expect(!(report.canArchive))
        #expect(report.issues.contains { $0.message.contains("没有可靠的拍摄日期") && !$0.isBlocking })
    }

    @Test func testInvalidTimestampDoesNotNormalizeIntoAnotherDay() async throws {
        try photo("DJI_20260826240000_0001_D.JPG")
        try photo("DJI_20260230010203_0002_D.JPG")
        let report = try await MediaScanner.scan(request: request())
        #expect(report.files.isEmpty)
        #expect(report.issues.filter { $0.message.contains("日期或时间无效") }.count == 2)
    }

    @Test func testAuxiliaryHiddenAndSystemDirectoriesAreSkipped() async throws {
        try Data([0, 1, 2]).write(to: source.appendingPathComponent("DJI_20260826000000_0001_D.LRF"))
        try Data([0, 1, 2]).write(to: source.appendingPathComponent("readme.txt"))
        try photo(".DJI_20260826120000_0002_D.JPG")
        try photo("DJI_20260826120000_0003_D.JPG", directory: source.appendingPathComponent("MISC"))
        try photo("DJI_20260826120000_0004_D.JPG", directory: source.appendingPathComponent("LOST+FOUND"))
        try photo("DJI_20260826120000_0005_D.JPG", directory: source.appendingPathComponent(".hidden"))
        try photo("DJI_20260826120000_0006_D.JPG", directory: source.appendingPathComponent("Fake.app"))
        let report = try await MediaScanner.scan(request: request())
        #expect(report.files.isEmpty)
        #expect(report.issues.isEmpty)
        #expect(report.ignoredCount == 2)
    }

    @Test func testSymbolicLinksAreNotFollowed() async throws {
        let external = root.appendingPathComponent("external", isDirectory: true)
        let original = try photo("DJI_20260826120000_0001_D.JPG", directory: external)
        try FileManager.default.createSymbolicLink(at: source.appendingPathComponent(original.lastPathComponent), withDestinationURL: original)
        try FileManager.default.createSymbolicLink(at: source.appendingPathComponent("linked-directory"), withDestinationURL: external)
        let report = try await MediaScanner.scan(request: request())
        #expect(report.files.isEmpty)
        #expect(report.issues.isEmpty)
    }

    @Test func testCaseInsensitiveDuplicateNamesBlockArchive() async throws {
        try photo("DJI_20260826120000_0001_D.JPG", directory: source.appendingPathComponent("card1"))
        try photo("DJI_20260826120000_0001_D.jpg", directory: source.appendingPathComponent("card2"))
        let report = try await MediaScanner.scan(request: request())
        #expect(report.files.count == 2)
        #expect(!(report.canArchive))
        #expect(report.issues.filter(\.isBlocking).count == 2)
    }

    @Test func testEmptyMatchIsSuccessfulScanButCannotArchive() async throws {
        try photo("DJI_20260901000000_0001_D.JPG")
        let report = try await MediaScanner.scan(request: request())
        #expect(report.outsideRangeCount == 1)
        #expect(report.files.isEmpty)
        #expect(report.issues.isEmpty)
        #expect(!(report.canArchive))
    }

    @Test func testMissingSourceThrowsRatherThanReturningEmptySuccess() async throws {
        try FileManager.default.removeItem(at: source)
        do {
            _ = try await MediaScanner.scan(request: request())
            Issue.record("Missing source must fail")
        } catch { #expect(error.localizedDescription.contains("素材来源")) }
    }

    @Test func testUnreadableCandidateProducesBlockingIssue() async throws {
        let file = try photo("DJI_20260826120000_0001_D.JPG")
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: file.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path) }
        let report = try await MediaScanner.scan(request: request())
        #expect(report.files.isEmpty)
        #expect(report.issues.contains { $0.isBlocking })
    }

    @Test func testCancellationIsPropagated() async throws {
        let selected = request()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await MediaScanner.scan(request: selected)
        }
        do {
            _ = try await task.value
            Issue.record("Cancelled scan must throw")
        } catch is CancellationError { }
    }

    @Test func testDateParserStrictnessAndTimezoneCalendarDays() {
        #expect(CaptureDateParser.djiFilename("DJI_20260826000000_0001_D.MP4") == .valid(CaptureDay("2026-08-26")!))
        #expect(CaptureDateParser.djiFilename("prefix_DJI_20260826000000_0001_D.MP4") == .absent)
        #expect(CaptureDateParser.djiFilename("DJI_20260229000000_0001_D.MP4") == .invalid)
        #expect(CaptureDateParser.djiFilename("DJI_20240229000000_0001_D.MP4") == .valid(CaptureDay("2024-02-29")!))
        #expect(CaptureDateParser.zonedCreationDate("2026-08-26T00:05:00+14:00") == CaptureDay("2026-08-26"))
        #expect(CaptureDateParser.zonedCreationDate("2026-08-26T23:55:00-1200") == CaptureDay("2026-08-26"))
        #expect(CaptureDateParser.zonedCreationDate("2026-08-26T00:05:00.123Z") == CaptureDay("2026-08-26"))
        #expect(CaptureDateParser.zonedCreationDate("2026-08-26T00:05:00") == nil)
        #expect(CaptureDateParser.zonedCreationDate("2026-08-26T00:05:00+14:01") == nil)
        #expect(CaptureDateParser.zonedCreationDate("2026-02-30T00:05:00+08:00") == nil)
        #expect(CaptureDateParser.exifOriginal("2026:08:26 23:59:60") == nil)
    }
}
