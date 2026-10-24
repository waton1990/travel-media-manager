import Foundation
import Testing
@testable import TravelArchiveCore

struct LocationSelectionTests {
    private let day = CaptureDay("2026-10-13")!
    private let coordinate = GeoCoordinate(latitude: 31.23, longitude: 121.47)!
    private var request: DeviceArchiveRequest {
        DeviceArchiveRequest(name: "三天旅行", start: day, end: CaptureDay("2026-10-15")!,
                             destination: FileManager.default.temporaryDirectory, timeZoneIdentifier: "Asia/Shanghai")
    }
    private func file(_ id: String, name: String? = nil, kind: MediaKind = .photo, date: CaptureDay? = CaptureDay("2026-10-13")!, companions: [String] = []) -> DeviceMediaItem {
        DeviceMediaItem(id: id, name: name ?? "\(id).\(kind == .video ? "MOV" : "HEIC")", kind: kind, size: 10,
                        captureDay: date, dateBasis: "测试拍摄日期", companionIDs: companions)
    }
    private func asset(_ id: String, files: [String]? = nil, kind: MediaKind = .photo, known: Bool = true, date: CaptureDay? = nil) -> DeviceTravelAsset {
        DeviceTravelAsset(id: id, name: "\(id).HEIC", kind: kind, captureDay: date ?? day,
                          coordinate: known ? coordinate : nil, fileIDs: files ?? [id])
    }
    private func group(_ id: String, _ assets: [DeviceTravelAsset], unknown: Bool = false) -> DevicePlaceGroup {
        DevicePlaceGroup(id: id, name: unknown ? "位置未知" : id, assets: assets, isUnknown: unknown)
    }
    private func source(_ files: [DeviceMediaItem], issues: [DeviceScanIssue] = []) -> DeviceScanReport {
        DeviceScanReport(request: request, deviceID: "fixture-usb-session", deviceName: "测试 iPhone",
                         files: files, issues: issues, outsideRangeCount: 12, ignoredCount: 3)
    }
    private func select(_ source: DeviceScanReport, _ groups: [DevicePlaceGroup], cities: Set<String> = [], unknown: Set<String> = []) throws -> DeviceScanReport {
        try DevicePlaceSelection.report(from: source, groups: groups, selectedGroupIDs: cities, selectedUnknownAssetIDs: unknown)
    }

    @Test func coordinatesValidateBoundsFinitenessAndDecoding() throws {
        for pair in [(90.0, 180.0), (-90.0, -180.0), (0.0, 0.0)] {
            #expect(GeoCoordinate(latitude: pair.0, longitude: pair.1) != nil)
        }
        for pair in [(90.1, 0.0), (0.0, 180.1), (-91.0, 0.0), (0.0, -181.0), (Double.nan, 0.0), (0.0, Double.infinity)] {
            #expect(GeoCoordinate(latitude: pair.0, longitude: pair.1) == nil)
        }
        #expect(try JSONDecoder().decode(GeoCoordinate.self, from: JSONEncoder().encode(coordinate)) == coordinate)
        #expect(throws: (any Error).self) {
            _ = try JSONDecoder().decode(GeoCoordinate.self, from: Data(#"{"latitude":91,"longitude":0}"#.utf8))
        }
    }

    @Test func groupingKeepsUnresolvedCoordinatesAndMissingLocationUnknown() throws {
        let groups = try DevicePlaceSelection.groups(assets: [asset("a"), asset("b"), asset("c", known: false), asset("d")],
                                                     resolvedPlaceNames: ["a": " 上海市 ", "b": "上海市", "c": "不可信地点"])
        #expect(groups.count == 2)
        #expect(groups[0].name == "上海市" && groups[0].assets.map(\.id) == ["a", "b"])
        #expect(groups[1].id == DevicePlaceSelection.unknownGroupID && groups[1].isUnknown)
        #expect(groups[1].assets.map(\.id) == ["c", "d"])
        #expect(throws: (any Error).self) {
            _ = try DevicePlaceSelection.groups(assets: [asset("a"), asset("a")], resolvedPlaceNames: [:])
        }
        #expect(throws: (any Error).self) {
            _ = try DevicePlaceSelection.groups(assets: [asset("a")], resolvedPlaceNames: ["missing": "地点"])
        }
    }

    @Test func noSelectionCannotArchiveAndUnknownRequiresIndividualSelection() throws {
        let original = source([file("a"), file("b"), file("c")])
        let groups = [group("上海", [asset("a")]), group("unknown", [asset("b", known: false), asset("c", known: false)], unknown: true)]
        let empty = try select(original, groups)
        #expect(empty.files.isEmpty && !empty.canArchive)
        let cityOnly = try select(original, groups, cities: ["上海"])
        #expect(cityOnly.canArchive && cityOnly.files.map(\.id) == ["a"])
        let explicitUnknown = try select(original, groups, cities: ["上海"], unknown: ["c"])
        #expect(explicitUnknown.canArchive && Set(explicitUnknown.files.map(\.id)) == ["a", "c"])
        #expect(explicitUnknown.outsideRangeCount == 12 && explicitUnknown.ignoredCount == 3)
        #expect(throws: (any Error).self) { _ = try select(original, groups, cities: ["unknown"]) }
        #expect(throws: (any Error).self) { _ = try select(original, groups, unknown: ["a"]) }
    }

    @Test func emptySelectionStopsArchiveBeforeDeviceAccessOrFolderCreation() async throws {
        let request = DeviceArchiveRequest(name: "empty-selection-\(UUID().uuidString)", start: day, end: day,
                                           destination: FileManager.default.temporaryDirectory, timeZoneIdentifier: "Asia/Shanghai")
        let original = DeviceScanReport(request: request, deviceID: "fixture", deviceName: "测试 iPhone",
                                        files: [file("a")], issues: [], outsideRangeCount: 0, ignoredCount: 0)
        let empty = try select(original, [group("上海", [asset("a")])])
        let calls = SelectionDeviceAccessCounter()
        do {
            _ = try await DeviceArchiveEngine.archive(report: empty, read: { _, _, _ in
                await calls.record()
                return Data()
            }, validate: { await calls.record() })
            Issue.record("空选择不应开始归档")
        } catch let failure as ArchiveFailure {
            #expect(failure.targetURL == nil && failure.completedFiles == 0)
        }
        #expect(await calls.count == 0)
        #expect(!FileManager.default.fileExists(atPath: request.targetURL.path))
    }

    @Test func choosingOneCityRemovesCollisionsFromOtherCities() throws {
        let planned = try DeviceMediaPlanner.scan(items: [file("a", name: "IMG.HEIC"), file("b", name: "img.heic")],
                                                   request: request, deviceID: "fixture", deviceName: "测试 iPhone")
        #expect(!planned.canArchive)
        #expect(planned.issues.allSatisfy { $0.isFilenameCollision })
        let groups = [group("上海", [asset("a")]), group("杭州", [asset("b")])]
        let shanghai = try select(planned, groups, cities: ["上海"])
        #expect(shanghai.canArchive && shanghai.issues.isEmpty && shanghai.files.map(\.id) == ["a"])
        let both = try select(planned, groups, cities: ["上海", "杭州"])
        #expect(!both.canArchive && both.issues.count == 2)
        #expect(both.issues.allSatisfy { $0.isFilenameCollision })
    }

    @Test func livePhotoFilesStayTogetherAndCannotBeSplitAcrossAssets() throws {
        let original = source([file("p", companions: ["v"]), file("v", kind: .video, date: nil, companions: ["p"])])
        let complete = [group("上海", [asset("live", files: ["p", "v"])])]
        let selected = try select(original, complete, cities: ["上海"])
        #expect(selected.canArchive && Set(selected.files.map(\.id)) == ["p", "v"])
        #expect(selected.files.allSatisfy { $0.captureDay == day })
        let splitAcrossCities = [group("上海", [asset("photo", files: ["p"])]), group("杭州", [asset("video", files: ["v"], kind: .video)])]
        #expect(throws: (any Error).self) { _ = try select(original, splitAcrossCities, cities: ["上海"]) }
        let splitInsideCity = [group("上海", [asset("photo", files: ["p"]), asset("video", files: ["v"], kind: .video)])]
        #expect(throws: (any Error).self) { _ = try select(original, splitInsideCity, cities: ["上海"]) }
        let missingCompanion = source([file("p", companions: ["missing"])])
        #expect(throws: (any Error).self) { _ = try select(missingCompanion, [group("上海", [asset("p")])], cities: ["上海"]) }
    }

    @Test func lostOrMalformedLiveLinksCannotBypassContentVerification() throws {
        let groups = [group("上海", [asset("live", files: ["p", "v"])])]
        for links: ([String], [String]) in [([], []), (["v"], []), (["p"], ["v"]), (["v", "v"], ["p"])] {
            let original = source([file("p", companions: links.0), file("v", kind: .video, companions: links.1)])
            #expect(throws: (any Error).self) { _ = try select(original, groups, cities: ["上海"]) }
        }
        #expect(throws: (any Error).self) {
            _ = try select(source([file("p", companions: ["p"])]), [group("上海", [asset("p")])], cities: ["上海"])
        }
    }

    @Test func explicitIssueScopeFiltersSelectedAssetsAndFilesButRetainsGlobalIssues() throws {
        let issues = [
            DeviceScanIssue(id: "a-warning", name: "a", message: "照片 a 提示", scope: .assets(["a"])),
            DeviceScanIssue(id: "b-block", name: "b", message: "照片 b 错误", isBlocking: true, scope: .assets(["b"])),
            DeviceScanIssue(id: "b-file", name: "b", message: "文件 b 错误", isBlocking: true, scope: .files(["b"])),
            DeviceScanIssue(id: "global-warning", name: "设备", message: "全局提示")
        ]
        let original = source([file("a"), file("b")], issues: issues)
        let groups = [group("上海", [asset("a")]), group("杭州", [asset("b")])]
        let selected = try select(original, groups, cities: ["上海"])
        #expect(selected.canArchive && Set(selected.issues.map(\.id)) == ["a-warning", "global-warning"])
        let blocked = try select(original, groups, cities: ["杭州"])
        #expect(!blocked.canArchive && Set(blocked.issues.map(\.id)) == ["b-block", "b-file", "global-warning"])
        let globalError = DeviceScanIssue(id: "connection", name: "设备", message: "连接无效", isBlocking: true)
        #expect(!(try select(source(original.files, issues: issues + [globalError]), groups, cities: ["上海"])).canArchive)
    }

    @Test func invalidOrUnmappedIssueScopesCannotHideBlockingErrors() throws {
        let groups = [group("上海", [asset("a")])]
        for scope: DeviceScanIssue.Scope in [.files([]), .assets([]), .files(["missing"]), .assets(["missing"])] {
            let issue = DeviceScanIssue(id: "opaque", name: "问题", message: "未能确定归属", isBlocking: true, scope: scope)
            let result = try select(source([file("a")], issues: [issue]), groups, cities: ["上海"])
            #expect(!result.canArchive && result.issues.contains { $0.id == "opaque" })
        }
    }

    @Test func issueOnlyAssetsAreVisibleAndBlockOnlyWhenSelected() throws {
        let unavailable = asset("unavailable", files: [])
        let issue = DeviceScanIssue(id: "local-original", name: unavailable.name, message: "原件未保存在手机上", isBlocking: true, scope: .assets([unavailable.id]))
        let original = source([file("a")], issues: [issue])
        let groups = [group("上海", [asset("a")]), group("杭州", [unavailable])]
        #expect(try select(original, groups, cities: ["上海"]).canArchive)
        let selectedUnavailable = try select(original, groups, cities: ["上海", "杭州"])
        #expect(!selectedUnavailable.canArchive && selectedUnavailable.issues.map(\.id) == [issue.id])
        #expect(throws: (any Error).self) { _ = try select(source([file("a")]), groups, cities: ["上海"]) }
        let warning = DeviceScanIssue(id: "warning", name: "unavailable", message: "提示", scope: .assets(["unavailable"]))
        #expect(throws: (any Error).self) { _ = try select(source([file("a")], issues: [warning]), groups) }
        let unknownGroups = [group("上海", [asset("a")]), group("unknown", [asset("unavailable", files: [], known: false)], unknown: true)]
        #expect(try select(original, unknownGroups, cities: ["上海"]).canArchive)
        #expect(!(try select(original, unknownGroups, cities: ["上海"], unknown: ["unavailable"])).canArchive)
    }

    @Test func inconsistentGroupsFilesSelectionsAndDatesFailClosed() throws {
        let original = source([file("a"), file("b")])
        let invalidGroups: [[DevicePlaceGroup]] = [
            [group("上海", [asset("a")])],
            [group("上海", [asset("a"), asset("missing")])],
            [group("上海", [asset("a"), asset("b", files: ["a", "b"])])],
            [group("上海", [asset("a"), asset("a", files: ["b"])])],
            [group("上海", [asset("a")]), group("上海", [asset("b")])],
            [group("上海", [asset("a", known: false), asset("b")])],
            [group("上海", [asset("a", date: CaptureDay("2026-10-14")!), asset("b")])],
            [group("上海", [asset("a", date: CaptureDay("2026-10-12")!), asset("b")])],
            [group("上海", [asset("a", kind: .video), asset("b")])],
            [group("unknown1", [asset("a")], unknown: true), group("unknown2", [asset("b")], unknown: true)]
        ]
        for groups in invalidGroups {
            #expect(throws: (any Error).self) { _ = try select(original, groups) }
        }
        let valid = [group("上海", [asset("a"), asset("b")])]
        #expect(throws: (any Error).self) { _ = try select(original, valid, cities: ["陈旧地点"]) }
        #expect(throws: (any Error).self) { _ = try select(original, valid, unknown: ["陈旧素材"]) }
        #expect(throws: (any Error).self) { _ = try select(source([file("a"), file("a")]), [group("上海", [asset("a")])]) }
    }

    @Test func malformedDecodedCalendarDayCannotBypassSelectionValidation() throws {
        let invalidDay = try JSONDecoder().decode(CaptureDay.self, from: Data(#"{"year":2026,"month":10,"day":32}"#.utf8))
        #expect(throws: (any Error).self) {
            _ = try select(source([file("a")]), [group("上海", [asset("a", date: invalidDay)])], cities: ["上海"])
        }
    }

    @Test func plannerRevalidatesChosenFilesAndNeverSilentlyOmitsTheirDates() throws {
        let unsafe = source([file("a"), file("b", name: "../b.HEIC")])
        let groups = [group("上海", [asset("a")]), group("杭州", [asset("b")])]
        #expect(try select(unsafe, groups, cities: ["上海"]).canArchive)
        #expect(!(try select(unsafe, groups, cities: ["上海", "杭州"])).canArchive)
        let missingDate = source([file("a"), file("b", date: nil)])
        let selected = try select(missingDate, groups, cities: ["上海", "杭州"])
        #expect(!selected.canArchive && selected.files.map(\.id) == ["a"])
        #expect(selected.issues.contains { $0.id == "selection:omitted-files" && $0.isBlocking })
    }
}

private actor SelectionDeviceAccessCounter {
    var count = 0
    func record() { count += 1 }
}
