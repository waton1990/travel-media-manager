import CryptoKit
import Foundation
import Testing
@testable import TravelArchiveCore

struct LivePhotoImportModeTests {
    private let day = CaptureDay("2026-10-13")!

    private final class Fixture: @unchecked Sendable {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LivePhotoImportModeTests-\(UUID())", isDirectory: true)
        init() throws { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false) }
        deinit { try? FileManager.default.removeItem(at: root) }
        var request: DeviceArchiveRequest {
            DeviceArchiveRequest(name: "实况选择", start: CaptureDay("2026-10-13")!, end: CaptureDay("2026-10-15")!,
                                 destination: root, timeZoneIdentifier: "Asia/Shanghai")
        }
    }

    private func file(_ id: String, _ kind: MediaKind, name: String? = nil, size: Int64 = 10,
                      day: CaptureDay? = CaptureDay("2026-10-13")!, companions: [String] = []) -> DeviceMediaItem {
        DeviceMediaItem(id: id, name: name ?? "\(id).\(kind == .photo ? "HEIC" : "MOV")", kind: kind, size: size,
                        captureDay: day, dateBasis: "fixture", companionIDs: companions)
    }

    private var files: [DeviceMediaItem] {
        [file("p", .photo, companions: ["v"]), file("v", .video, companions: ["p"]), file("independent", .video)]
    }

    private func groups(unknown: Bool = false) -> [DevicePlaceGroup] {
        let coordinate = unknown ? nil : GeoCoordinate(latitude: 31.23, longitude: 121.47)
        return [DevicePlaceGroup(id: "place", name: unknown ? "位置未知" : "上海市", assets: [
            DeviceTravelAsset(id: "live", name: "p.HEIC", kind: .photo, captureDay: day, coordinate: coordinate, fileIDs: ["p", "v"]),
            DeviceTravelAsset(id: "video", name: "independent.MOV", kind: .video, captureDay: day, coordinate: coordinate, fileIDs: ["independent"])
        ], isUnknown: unknown)]
    }

    private func source(_ f: Fixture, files: [DeviceMediaItem], issues: [DeviceScanIssue] = []) -> DeviceScanReport {
        DeviceScanReport(request: f.request, deviceID: "fixture", deviceName: "测试 iPhone", files: files,
                         issues: issues, outsideRangeCount: 3, ignoredCount: 4)
    }

    private func select(_ source: DeviceScanReport, mode: LivePhotoImportMode = .complete) throws -> DeviceScanReport {
        try DevicePlaceSelection.report(from: source, groups: groups(), selectedGroupIDs: ["place"],
                                        selectedUnknownAssetIDs: [], livePhotoImportMode: mode)
    }

    @Test func defaultCompleteAndStillOnlySwitchesAreRebuiltFromOriginalCatalog() throws {
        let f = try Fixture(), original = source(f, files: files)
        #expect(original.livePhotoImportMode == .complete)
        let complete = try DevicePlaceSelection.report(from: original, groups: groups(), selectedGroupIDs: ["place"], selectedUnknownAssetIDs: [])
        #expect(complete.livePhotoImportMode == .complete && complete.canArchive)
        #expect(complete.count(.photo) == 1 && complete.count(.video) == 2 && complete.totalBytes == 30)
        let still = try select(original, mode: .stillOnly)
        #expect(still.livePhotoImportMode == .stillOnly && still.canArchive)
        #expect(Set(still.files.map(\.id)) == ["p", "independent"])
        #expect(still.count(.photo) == 1 && still.count(.video) == 1 && still.totalBytes == 20)
        #expect(still.files.first { $0.id == "p" }?.companionIDs == ["v"])
        #expect(still.outsideRangeCount == 3 && still.ignoredCount == 4)
        let restored = try select(original, mode: .complete)
        #expect(restored.files.map(\.id) == complete.files.map(\.id) && restored.totalBytes == 30)
        #expect(original.files.count == 3 && original.files[0].companionIDs == ["v"])
        #expect(throws: (any Error).self) { _ = try select(still, mode: .complete) }
    }

    @Test func unknownLiveAssetCanBeSelectedAsStaticWithoutSelectingIndependentVideo() throws {
        let f = try Fixture()
        let result = try DevicePlaceSelection.report(from: source(f, files: files), groups: groups(unknown: true),
                                                      selectedGroupIDs: [], selectedUnknownAssetIDs: ["live"], livePhotoImportMode: .stillOnly)
        #expect(result.canArchive && result.files.map(\.id) == ["p"] && result.totalBytes == 10)
        #expect(result.files[0].companionIDs == ["v"])
    }

    @Test func dateNormalizationUsesCompletePairBeforeProjectingStillPhoto() throws {
        let f = try Fixture()
        let original = source(f, files: [file("p", .photo, day: nil, companions: ["v"]), files[1], files[2]])
        let result = try select(original, mode: .stillOnly)
        #expect(result.canArchive)
        #expect(result.files.first { $0.id == "p" }?.captureDay == day)
        #expect(result.files.first { $0.id == "p" }?.dateBasis.contains("明确关联") == true)
    }

    @Test func missingAndMalformedOriginalRelationsCannotBeHiddenByStillOnly() throws {
        let f = try Fixture()
        for links: ([String], [String]) in [([], []), (["v"], []), (["p"], ["v"]), (["v", "v"], ["p"]), (["v", "missing"], ["p"])] {
            let original = source(f, files: [file("p", .photo, companions: links.0), file("v", .video, companions: links.1), files[2]])
            #expect(throws: (any Error).self) { _ = try select(original, mode: .stillOnly) }
        }
        #expect(throws: (any Error).self) {
            _ = try select(source(f, files: [files[0], files[2]]), mode: .stillOnly)
        }
        let unsafeCompanion = source(f, files: [files[0], file("v", .video, name: "../v.MOV", companions: ["p"]), files[2]])
        #expect(!(try select(unsafeCompanion, mode: .stillOnly)).canArchive)
        let companionIssue = DeviceScanIssue(id: "changed-video", name: "v.MOV", message: "原始配套文件已变化", isBlocking: true, scope: .files(["v"]))
        #expect(!(try select(source(f, files: files, issues: [companionIssue]), mode: .stillOnly)).canArchive)
    }

    @Test func stillOnlyRecomputesOnlyActualDestinationFilenameCollisions() throws {
        let f = try Fixture()
        let withCollision = [files[0], file("v", .video, name: "same.MOV", companions: ["p"]), file("independent", .video, name: "SAME.mov")]
        let original = try DeviceMediaPlanner.scan(items: withCollision, request: f.request, deviceID: "fixture", deviceName: "测试 iPhone")
        #expect(!original.canArchive && original.issues.count == 2)
        let still = try select(original, mode: .stillOnly)
        #expect(still.canArchive && still.issues.isEmpty && still.totalBytes == 20)
        #expect(!(try select(original, mode: .complete)).canArchive)
        let extraPhoto = file("other", .photo, name: "P.heic")
        let extraAsset = DeviceTravelAsset(id: "other-asset", name: extraPhoto.name, kind: .photo, captureDay: day,
                                          coordinate: GeoCoordinate(latitude: 31.23, longitude: 121.47), fileIDs: [extraPhoto.id])
        let group = groups()[0]
        let result = try DevicePlaceSelection.report(from: source(f, files: files + [extraPhoto]),
                                                      groups: [DevicePlaceGroup(id: group.id, name: group.name, assets: group.assets + [extraAsset])],
                                                      selectedGroupIDs: [group.id], selectedUnknownAssetIDs: [], livePhotoImportMode: .stillOnly)
        #expect(!result.canArchive && result.issues.filter(\.isFilenameCollision).count == 2)
    }

    @Test func plannerRequiresExplicitModeAndRejectsCompanionVideosOrMalformedProjection() throws {
        let f = try Fixture()
        let still = try DeviceMediaPlanner.scan(items: [files[0], files[2]], request: f.request, deviceID: "fixture", deviceName: "测试 iPhone", livePhotoImportMode: .stillOnly)
        #expect(still.canArchive && still.files.first { $0.id == "p" }?.companionIDs == ["v"])
        let complete = try DeviceMediaPlanner.scan(items: [files[0]], request: f.request, deviceID: "fixture", deviceName: "测试 iPhone")
        #expect(complete.livePhotoImportMode == .complete && !complete.canArchive)
        let invalidPlans: [[DeviceMediaItem]] = [
            files, [files[1]], [file("p", .photo, companions: ["p"])],
            [file("p", .photo, companions: [""])], [file("p", .photo, companions: ["v", "v"])],
            [file("p", .photo, companions: ["v", "missing"])],
            [files[0], file("q", .photo, companions: ["v"])],
            [files[0], file("v", .audio, name: "v.AAC")]
        ]
        for invalid in invalidPlans {
            let report = try DeviceMediaPlanner.scan(items: invalid, request: f.request, deviceID: "fixture", deviceName: "测试 iPhone", livePhotoImportMode: .stillOnly)
            #expect(!report.canArchive && report.issues.contains(where: \.isBlocking))
        }
    }

    @Test func stillOnlyArchiveReadsOnlyOriginalPhotoAndStandaloneVideoAndPreservesHashes() async throws {
        let f = try Fixture()
        let originalBytes = ["p": Data(repeating: 0x92, count: 1_048_593), "v": Data(repeating: 0x10, count: 17), "independent": Data(repeating: 0x7e, count: 23)]
        let originalFiles = files.map { file($0.id, $0.kind, size: Int64(originalBytes[$0.id]!.count), companions: $0.companionIDs) }
        let plan = try select(source(f, files: originalFiles), mode: .stillOnly)
        let reader = ModeReadRecorder(contents: originalBytes)
        let result = try await DeviceArchiveEngine.archive(report: plan, read: { try await reader.read($0, offset: $1, count: $2) }, validate: {}, verifyLivePhoto: { _, _ in
            Issue.record("Still-only mode must not read or verify the omitted movie")
            throw ArchiveError.invalid("Unexpected pair verification")
        })
        #expect(result.fileCount == 2 && result.totalBytes == 1_048_616)
        #expect(await reader.readIDs == ["p", "independent"])
        #expect(Set(try FileManager.default.contentsOfDirectory(atPath: result.targetURL.path)) == ["p.HEIC", "independent.MOV"])
        for item in plan.files {
            let copied = try Data(contentsOf: result.targetURL.appendingPathComponent(item.name))
            #expect(SHA256.hash(data: copied) == SHA256.hash(data: originalBytes[item.id]!))
        }
        #expect(reader.contents == originalBytes)
    }

    @Test func forgedModesFailBeforeDeviceAccessOrDestinationCreation() async throws {
        for mode: LivePhotoImportMode in [.complete, .stillOnly] {
            let f = try Fixture()
            let forged = DeviceScanReport(request: f.request, deviceID: "fixture", deviceName: "测试 iPhone",
                                           files: mode == .complete ? [files[0]] : files,
                                           issues: [], outsideRangeCount: 0, ignoredCount: 0, livePhotoImportMode: mode)
            do {
                _ = try await DeviceArchiveEngine.archive(report: forged, read: { _, _, _ in
                    Issue.record("Invalid mode must not read device bytes")
                    return Data()
                }, validate: { Issue.record("Invalid mode must fail before device validation") })
                Issue.record("Invalid mode must fail")
            } catch let failure as ArchiveFailure {
                #expect(failure.completedFiles == 0 && failure.targetURL == nil)
            }
            #expect(!FileManager.default.fileExists(atPath: f.request.targetURL.path))
        }
    }
}

private actor ModeReadRecorder {
    let contents: [String: Data]
    var readIDs = Set<String>()
    init(contents: [String: Data]) { self.contents = contents }
    func read(_ file: DeviceMediaItem, offset: Int64, count: Int) throws -> Data {
        readIDs.insert(file.id)
        guard file.id != "v", let bytes = contents[file.id] else { throw ArchiveError.invalid("Unselected file was read") }
        return bytes.subdata(in: Int(offset)..<min(Int(offset) + count, bytes.count))
    }
}
