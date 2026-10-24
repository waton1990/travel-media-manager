import Foundation
import Testing
@testable import TravelArchiveCore

struct DeviceImportTests {
    private final class Fixture: @unchecked Sendable {
        let root: URL
        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("DeviceImportTests-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        }
        deinit { try? FileManager.default.removeItem(at: root) }
        var request: DeviceArchiveRequest {
            DeviceArchiveRequest(name: "三天旅行", start: CaptureDay("2026-08-26")!, end: CaptureDay("2026-08-28")!, destination: root, timeZoneIdentifier: "Asia/Shanghai")
        }
    }

    private func item(_ id: String, _ name: String, _ day: String? = "2026-08-26", kind: MediaKind = .photo, size: Int64 = 5, companions: [String] = []) -> DeviceMediaItem {
        DeviceMediaItem(id: id, name: name, kind: kind, size: size, captureDay: day.flatMap(CaptureDay.init), dateBasis: "EXIF fixture", companionIDs: companions)
    }
    private func plan(_ fixture: Fixture, _ items: [DeviceMediaItem]) throws -> DeviceScanReport {
        try DeviceMediaPlanner.scan(items: items, request: fixture.request, deviceID: "fixture-session-token", deviceName: "测试 iPhone")
    }
    private func expectFailure(_ report: DeviceScanReport, provider: FakeDeviceReader) async throws -> ArchiveFailure {
        do {
            _ = try await DeviceArchiveEngine.archive(report: report, read: { try await provider.read($0, offset: $1, count: $2) }, validate: { try await provider.validate() })
            Issue.record("Expected archive failure")
            throw ArchiveError.invalid("Expected failure")
        } catch let error as ArchiveFailure { return error }
    }

    @Test func threeDaysAndExplicitLivePhotoAreCopiedTogether() async throws {
        let f = try Fixture()
        let items = [
            item("a", "a.JPG", "2026-08-26"),
            item("b", "b.MOV", "2026-08-27", kind: .video),
            item("c", "c.HEIC", "2026-08-28", companions: ["d"]),
            item("d", "c.MOV", nil, kind: .video, companions: ["c"]),
            item("before", "before.JPG", "2026-08-25"), item("after", "after.JPG", "2026-08-29"),
            item("audio", "audio.AAC", kind: .audio)
        ]
        let report = try plan(f, items)
        #expect(report.canArchive)
        #expect(report.files.count == 4)
        #expect(report.count(.photo) == 2 && report.count(.video) == 2)
        #expect(report.outsideRangeCount == 2 && report.ignoredCount == 1)
        #expect(report.files.first { $0.id == "d" }?.captureDay == CaptureDay("2026-08-28"))
        #expect(report.files.first { $0.id == "d" }?.dateBasis.contains("明确关联") == true)
        let source = Dictionary(uniqueKeysWithValues: items.map { ($0.id, Data(repeating: UInt8($0.id.utf8.first!), count: Int($0.size))) })
        let provider = FakeDeviceReader(source)
        try DeviceArchiveEngine.validateDestination(for: f.request, requiredBytes: report.totalBytes)
        #expect(!FileManager.default.fileExists(atPath: f.request.targetURL.path))
        // This transport fixture contains arbitrary bytes; pairing metadata is
        // tested separately with real generated JPEG/HEIC and MOV resources.
        let result = try await DeviceArchiveEngine.archive(report: report, read: { try await provider.read($0, offset: $1, count: $2) }, validate: { try await provider.validate() }, verifyLivePhoto: { _, _ in })
        #expect(result.fileCount == 4 && result.totalBytes == 20)
        #expect(Set(try FileManager.default.contentsOfDirectory(atPath: result.targetURL.path)) == Set(report.files.map(\.name)))
        for file in report.files { #expect(try Data(contentsOf: result.targetURL.appendingPathComponent(file.name)) == source[file.id]) }
        #expect(await provider.snapshot() == source)
    }

    @Test func missingLiveCompanionAndDateConflictBlockArchive() throws {
        let f = try Fixture()
        let missing = try plan(f, [item("photo", "live.HEIC", companions: ["absent-video"])])
        #expect(!missing.canArchive && missing.issues.contains { $0.isBlocking && $0.message.contains("缺失") })
        let conflict = try plan(f, [item("photo", "live.HEIC", "2026-08-26", companions: ["video"]), item("video", "live.MOV", "2026-08-27", kind: .video)])
        #expect(!conflict.canArchive && conflict.issues.contains { $0.isBlocking && $0.message.contains("不一致") })
    }

    @Test func editedAssetsKeepDistinctCatalogNamesAndExactBytes() async throws {
        let f = try Fixture()
        let names = ["IMG_E1001.HEIC", "IMG_E1001.MOV", "IMG_E1002.HEIC", "IMG_E1002.MOV"]
        let items = names.enumerated().map { index, name in
            let photo = index % 2 == 0
            let resolved = DeviceMediaFilename.resolve(name: name, originalFilename: photo ? "FullSizeRender.heic" : "FullSizeRender.mov")
            return item(String(index), resolved, kind: photo ? .photo : .video, companions: [String(index ^ 1)])
        }
        let report = try plan(f, items)
        #expect(report.canArchive && report.files.count == 4)
        let source = Dictionary(uniqueKeysWithValues: items.enumerated().map { (index, file) in
            (file.id, Data(repeating: UInt8(index + 1), count: Int(file.size)))
        })
        let provider = FakeDeviceReader(source)
        let result = try await DeviceArchiveEngine.archive(report: report, read: { try await provider.read($0, offset: $1, count: $2) }, validate: { try await provider.validate() }, verifyLivePhoto: { _, _ in })
        #expect(Set(try FileManager.default.contentsOfDirectory(atPath: result.targetURL.path)) == Set(names))
        for file in report.files { #expect(try Data(contentsOf: result.targetURL.appendingPathComponent(file.name)) == source[file.id]) }
        #expect(DeviceMediaFilename.resolve(name: nil, originalFilename: "original.HEIC") == "original.HEIC")
        #expect(DeviceMediaFilename.resolve(name: "", originalFilename: "original.HEIC") == "original.HEIC")
        #expect(DeviceMediaFilename.resolve(name: nil, originalFilename: nil).isEmpty)
        let unsafe = DeviceMediaFilename.resolve(name: "../bad.JPG", originalFilename: "good.JPG")
        #expect(!(try plan(f, [item("bad", unsafe)])).canArchive)
        let collision = DeviceMediaFilename.resolve(name: "same.JPG", originalFilename: "different.JPG")
        #expect(!(try plan(f, [item("a", collision), item("b", "same.JPG")])).canArchive)
    }

    @Test func matchingBasenamesNeverInventPairingOrDates() throws {
        let f = try Fixture()
        let report = try plan(f, [item("photo", "IMG_001.HEIC"), item("video", "IMG_001.MOV", nil, kind: .video)])
        #expect(report.files.map(\.id) == ["photo"])
        #expect(report.issues.contains { $0.name == "IMG_001.MOV" && !$0.isBlocking && $0.message.contains("未纳入") })
    }

    @Test func unsafeNamesDuplicateIDsAndFlattenedCollisionsAreBlocked() throws {
        let f = try Fixture()
        let collision = try plan(f, [item("a", "IMG.JPG"), item("b", "img.jpg")])
        #expect(!collision.canArchive && collision.issues.contains { $0.isBlocking })
        let duplicate = try plan(f, [item("a", "a.JPG"), item("a", "b.JPG")])
        #expect(!duplicate.canArchive && duplicate.issues.contains { $0.message.contains("标识") })
        for unsafe in ["../outside.JPG", "a/b.JPG", "a\\b.JPG", "a:b.JPG", "a\0.JPG"] {
            let report = try plan(f, [item("a", unsafe)])
            #expect(!report.canArchive && report.issues.contains { $0.isBlocking })
        }
    }

    @Test func invalidSizesTimezonesAndOverflowAreRejected() throws {
        let f = try Fixture()
        #expect(!(try plan(f, [item("a", "a.JPG", size: -1)])).canArchive)
        #expect(!(try plan(f, [item("a", "a.JPG", size: 0)])).canArchive)
        #expect(throws: (any Error).self) {
            _ = try plan(f, [item("a", "a.JPG", size: Int64.max / 2), item("b", "b.JPG", size: 1)])
        }
        let request = DeviceArchiveRequest(name: "test", start: CaptureDay("2026-08-26")!, end: CaptureDay("2026-08-28")!, destination: f.root, timeZoneIdentifier: "not-a-timezone")
        #expect(throws: (any Error).self) { try request.validateBasics() }
    }

    @Test func metadataConflictCannotInheritACompanionsDate() async throws {
        let f = try Fixture()
        let conflict = DeviceMediaItem(id: "video", name: "live.MOV", kind: .video, size: 5, captureDay: nil,
                                       dateBasis: "conflicting metadata", companionIDs: ["photo"], hasDateConflict: true)
        let photo = item("photo", "live.HEIC", companions: ["video"])
        let report = try plan(f, [photo, conflict])
        #expect(report.files.isEmpty && !report.canArchive)
        #expect(report.issues.contains { $0.isBlocking && $0.message.contains("元数据冲突") })
        let alone = try plan(f, [DeviceMediaItem(id: "conflict", name: "alone.JPG", kind: .photo, size: 5,
                                               captureDay: nil, dateBasis: "conflict", hasDateConflict: true)])
        #expect(alone.files.isEmpty && alone.issues.contains { !$0.isBlocking && $0.message.contains("未纳入") })
        let forged = DeviceScanReport(request: f.request, deviceID: "session", deviceName: "Phone", files: [photo, conflict], issues: [], outsideRangeCount: 0, ignoredCount: 0)
        let provider = FakeDeviceReader(["photo": Data(repeating: 1, count: 5), "video": Data(repeating: 2, count: 5)])
        let failure = try await expectFailure(forged, provider: provider)
        #expect(failure.targetURL == nil)
        #expect(await provider.readCount == 0)
    }

    @Test func heifGifAndAllRequestedExtensionsAreAccepted() throws {
        let f = try Fixture()
        let photoExtensions = ["HEIC", "HEIF", "JPG", "JPEG", "PNG", "GIF", "TIF", "TIFF", "DNG"]
        let videoExtensions = ["MOV", "MP4", "M4V"]
        let items = photoExtensions.map { item($0, "photo.\($0)") } + videoExtensions.map { item($0, "video.\($0)", kind: .video) }
        let report = try plan(f, items)
        #expect(report.canArchive && report.count(.photo) == 9 && report.count(.video) == 3)
    }

    @Test func shortTransportChunksAreReadUntilExpectedSize() async throws {
        let f = try Fixture()
        let original = Data((0..<251).map(UInt8.init))
        let file = item("a", "a.MOV", kind: .video, size: Int64(original.count))
        let provider = FakeDeviceReader(["a": original], maximumChunk: 7)
        let report = try plan(f, [file])
        let result = try await DeviceArchiveEngine.archive(report: report, read: { try await provider.read($0, offset: $1, count: $2) }, validate: { try await provider.validate() })
        #expect(try Data(contentsOf: result.targetURL.appendingPathComponent(file.name)) == original)
        #expect(await provider.readCount > 1)
    }

    @Test func prematureEndAndOversizeReadLeaveNoCompletedFile() async throws {
        let f = try Fixture()
        let report = try plan(f, [item("a", "a.JPG", size: 10)])
        let short = FakeDeviceReader(["a": Data([1, 2, 3])])
        let error = try await expectFailure(report, provider: short)
        #expect(error.completedFiles == 0 && error.message.contains("不完整"))
        #expect(try FileManager.default.contentsOfDirectory(atPath: f.request.targetURL.path).isEmpty)
        let other = try Fixture()
        let oversize = FakeDeviceReader(["a": Data(repeating: 4, count: 20)], returnOversize: true)
        let otherError = try await expectFailure(plan(other, [item("a", "a.JPG", size: 5)]), provider: oversize)
        #expect(otherError.completedFiles == 0 && otherError.message.contains("大小发生变化"))
        #expect(try FileManager.default.contentsOfDirectory(atPath: other.request.targetURL.path).isEmpty)
    }

    @Test func disconnectedSessionBeforeStartCreatesNothing() async throws {
        let f = try Fixture()
        let report = try plan(f, [item("a", "a.JPG")])
        let provider = FakeDeviceReader(["a": Data(repeating: 4, count: 5)])
        await provider.invalidate()
        let error = try await expectFailure(report, provider: provider)
        #expect(error.targetURL == nil && error.completedFiles == 0)
        #expect(!FileManager.default.fileExists(atPath: f.request.targetURL.path))
    }

    @Test func sourceIdentityChangeDuringReadPreventsCommit() async throws {
        let f = try Fixture()
        let report = try plan(f, [item("a", "a.JPG")])
        let provider = FakeDeviceReader(["a": Data(repeating: 4, count: 5)], invalidateAfterRead: true)
        let error = try await expectFailure(report, provider: provider)
        #expect(error.completedFiles == 0 && error.message.contains("原件变化"))
        #expect(try FileManager.default.contentsOfDirectory(atPath: f.request.targetURL.path).isEmpty)
    }

    @Test func readFailureRemovesAllCopiedButUnverifiedFiles() async throws {
        let f = try Fixture()
        let report = try plan(f, [item("a", "a.JPG"), item("b", "b.MOV", kind: .video)])
        let provider = FakeDeviceReader(["a": Data(repeating: 4, count: 5), "b": Data(repeating: 5, count: 5)], failID: "b")
        let error = try await expectFailure(report, provider: provider)
        #expect(error.completedFiles == 0 && error.targetURL == f.request.targetURL)
        #expect(try FileManager.default.contentsOfDirectory(atPath: f.request.targetURL.path).isEmpty)
    }

    @Test func cancellationDuringCopyCleansAllUnverifiedFiles() async throws {
        let f = try Fixture()
        let report = try plan(f, [item("a", "a.JPG"), item("b", "b.MOV", kind: .video)])
        let provider = FakeDeviceReader(["a": Data(repeating: 4, count: 5), "b": Data(repeating: 5, count: 5)], cancelID: "b")
        let task = Task.detached { try await expectFailure(report, provider: provider) }
        let error = try await task.value
        #expect(error.completedFiles == 0 && error.message.contains("取消"))
        #expect(try FileManager.default.contentsOfDirectory(atPath: f.request.targetURL.path).isEmpty)
    }

    @Test func existingTargetIsNeverReadIntoOrOverwritten() async throws {
        let f = try Fixture()
        let report = try plan(f, [item("a", "a.JPG")])
        try FileManager.default.createDirectory(at: f.request.targetURL, withIntermediateDirectories: false)
        let sentinel = f.request.targetURL.appendingPathComponent("a.JPG")
        try Data([9, 9, 9]).write(to: sentinel)
        let provider = FakeDeviceReader(["a": Data(repeating: 4, count: 5)])
        let error = try await expectFailure(report, provider: provider)
        #expect(error.completedFiles == 0 && error.targetURL == nil)
        #expect(try Data(contentsOf: sentinel) == Data([9, 9, 9]))
        #expect(await provider.readCount == 0)
    }

    @Test func forgedReportCannotBypassPairNameOrDateChecks() async throws {
        let f = try Fixture()
        let file = item("a", "../outside.JPG")
        let report = DeviceScanReport(request: f.request, deviceID: "session", deviceName: "Phone", files: [file], issues: [], outsideRangeCount: 0, ignoredCount: 0)
        let provider = FakeDeviceReader(["a": Data(repeating: 4, count: 5)])
        let error = try await expectFailure(report, provider: provider)
        #expect(error.targetURL == nil)
        #expect(await provider.readCount == 0)
        #expect(!FileManager.default.fileExists(atPath: f.request.targetURL.path))
    }
}

private actor FakeDeviceReader {
    let contents: [String: Data]
    let maximumChunk: Int?
    let failID: String?
    let cancelID: String?
    let invalidateAfterRead: Bool
    let returnOversize: Bool
    var valid = true
    var readCount = 0
    init(_ contents: [String: Data], maximumChunk: Int? = nil, failID: String? = nil, cancelID: String? = nil, invalidateAfterRead: Bool = false, returnOversize: Bool = false) {
        self.contents = contents; self.maximumChunk = maximumChunk; self.failID = failID; self.cancelID = cancelID
        self.invalidateAfterRead = invalidateAfterRead; self.returnOversize = returnOversize
    }
    func snapshot() -> [String: Data] { contents }
    func invalidate() { valid = false }
    func validate() throws { guard valid else { throw ArchiveError.invalid("测试设备断开或原件变化") } }
    func read(_ item: DeviceMediaItem, offset: Int64, count: Int) throws -> Data {
        try validate()
        readCount += 1
        if item.id == failID { throw ArchiveError.invalid("测试读取失败") }
        if item.id == cancelID { withUnsafeCurrentTask { $0?.cancel() } }
        guard let data = contents[item.id], offset < data.count else { return Data() }
        if invalidateAfterRead { valid = false }
        if returnOversize { return data }
        let start = Int(offset)
        let length = min(count, maximumChunk ?? count, data.count - start)
        return data.subdata(in: start..<(start + length))
    }
}
