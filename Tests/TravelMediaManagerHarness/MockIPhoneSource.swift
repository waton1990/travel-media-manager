import Combine
import Foundation
import TravelArchiveCore

struct ConnectedPhone: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
}

/// Local-only stand-in: this file has no USB, network, process or media APIs.
@MainActor
final class IPhoneSource: ObservableObject {
    @Published private(set) var devices: [ConnectedPhone] = []
    @Published var selectedDeviceID: String?
    @Published private(set) var statusMessage = "本地合成数据，不访问手机。"
    @Published private(set) var isReady = false
    @Published private(set) var isDiscovering = false
    @Published private(set) var catalogRevision = 0
    @Published private(set) var locationGroups: [DevicePlaceGroup] = []
    private(set) var scanCount = 0
    private(set) var finishAccessCount = 0
    private(set) var preparedFileIDs: [String] = []
    private(set) var preparedLivePhotoImportMode: LivePhotoImportMode?
    var enableSyntheticTransfer = false
    var releaseFinalValidation = false
    private(set) var isWaitingForFinalValidation = false
    private(set) var validationCount = 0
    func setDiscoveryActive(_ active: Bool) { isDiscovering = active }
    func start() {
        devices = [ConnectedPhone(id: "synthetic-phone", name: "合成 iPhone · 无真实连接")]
        selectedDeviceID = devices[0].id
        isReady = true
    }
    func stop() { selectedDeviceID = nil; isReady = false }
    func cancelPendingReads() {}
    func finishAccess() async { finishAccessCount += 1 }
    func prepare(report: DeviceScanReport) async throws {
        preparedFileIDs = report.files.map(\.id)
        preparedLivePhotoImportMode = report.livePhotoImportMode
    }
    func validate(deviceID: String) async throws {
        guard enableSyntheticTransfer else {
            throw ArchiveError.invalid("这是合成数据验收。已阻止实际归档；未访问手机，也未创建旅行文件夹。")
        }
        validationCount += 1
        if validationCount == 2 {
            isWaitingForFinalValidation = true
            while !releaseFinalValidation { try await Task.sleep(nanoseconds: 10_000_000) }
        }
    }
    func read(item: DeviceMediaItem, offset: Int64, length: Int, deviceID: String) async throws -> Data {
        guard enableSyntheticTransfer, preparedFileIDs == ["unknown-video"], item.id == "unknown-video" else {
            throw ArchiveError.invalid("合成数据验收不读取媒体。")
        }
        try await Task.sleep(nanoseconds: 30_000_000)
        return Data(repeating: 42, count: min(length, Int(item.size - offset)))
    }
    func scan(request: DeviceArchiveRequest,
              progress: @escaping @Sendable (ScanProgress) -> Void) async throws -> DeviceScanReport {
        scanCount += 1
        let day = request.start
        let files = [
            DeviceMediaItem(id: "beijing-still", name: "IMG_0001.HEIC", kind: .photo, size: 2_000_000, captureDay: day, dateBasis: "合成日期", companionIDs: ["beijing-video"]),
            DeviceMediaItem(id: "beijing-video", name: "IMG_0001.MOV", kind: .video, size: 3_000_000, captureDay: day, dateBasis: "合成日期", companionIDs: ["beijing-still"]),
            DeviceMediaItem(id: "tianjin-still", name: "IMG_0001.HEIC", kind: .photo, size: 2_500_000, captureDay: day, dateBasis: "合成日期"),
            DeviceMediaItem(id: "unknown-video", name: "IMG_0003.MOV", kind: .video, size: 4_000_000, captureDay: day, dateBasis: "合成日期")
        ]
        let assets = [
            DeviceTravelAsset(id: "beijing", name: "IMG_0001.HEIC", kind: .photo, captureDay: day, coordinate: GeoCoordinate(latitude: 39.9042, longitude: 116.4074), fileIDs: ["beijing-still", "beijing-video"]),
            DeviceTravelAsset(id: "tianjin", name: "IMG_0001.HEIC", kind: .photo, captureDay: day, coordinate: GeoCoordinate(latitude: 39.0842, longitude: 117.2009), fileIDs: ["tianjin-still"]),
            DeviceTravelAsset(id: "unknown", name: "IMG_0003.MOV", kind: .video, captureDay: day, coordinate: nil, fileIDs: ["unknown-video"]),
            DeviceTravelAsset(id: "unavailable", name: "IMG_0004.HEIC", kind: .photo, captureDay: day, coordinate: nil, fileIDs: [])
        ]
        locationGroups = try DevicePlaceSelection.groups(assets: assets, resolvedPlaceNames: ["beijing": "中国 · 北京市", "tianjin": "中国 · 天津市"])
        progress(ScanProgress(visitedFiles: 4, currentFile: "合成目录读取完成"))
        return DeviceScanReport(request: request, deviceID: "synthetic-scan-token", deviceName: "合成 iPhone", files: files,
            issues: [DeviceScanIssue(id: "unavailable-original", name: "IMG_0004.HEIC", message: "合成情况：原件不在本机，无法通过数据线读取。", isBlocking: true, scope: .assets(["unavailable"]))],
            outsideRangeCount: 8, ignoredCount: 2)
    }
}

@MainActor
func makeSyntheticModel(destination: URL) -> AppModel {
    let model = AppModel()
    model.sourceKind = .iphone
    model.travelName = "三日旅行 · 合成验收"
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
    model.startDate = calendar.date(from: DateComponents(year: 2026, month: 10, day: 13, hour: 12))!
    model.endDate = calendar.date(from: DateComponents(year: 2026, month: 10, day: 15, hour: 12))!
    model.timeZoneIdentifier = "Asia/Shanghai"
    model.setFolder(destination, isSource: false)
    model.findPhones()
    return model
}
