import Combine
import Foundation
import TravelArchiveCore

struct ConnectedPhone: Identifiable, Equatable, Decodable, Sendable {
    let id: String
    let name: String
}

/// Uses only USB. No Image Capture catalog session, iCloud fallback, or device
/// access during initialization. Metadata stays in memory after scanning.
@MainActor
final class IPhoneSource: ObservableObject {
    @Published private(set) var devices: [ConnectedPhone] = []
    @Published var selectedDeviceID: String? {
        didSet {
            guard selectedDeviceID != oldValue else { return }
            client.cancel()
            scannedToken = nil
            scannedItems = [:]
            locationGroups = []
            catalogRevision += 1
            isReady = selectedDeviceID != nil
        }
    }
    @Published private(set) var statusMessage = "请用数据线连接 iPhone，解锁并信任此 Mac，然后查找设备。"
    @Published private(set) var isReady = false
    @Published private(set) var isDiscovering = false
    @Published private(set) var catalogRevision = 0
    @Published private(set) var locationGroups: [DevicePlaceGroup] = []
    private let client = USBHelperClient()
    private var discovery: Task<Void, Never>?
    private var scannedToken: String?
    private var scannedItems: [String: DeviceMediaItem] = [:]
    private let placeResolver = PlaceNameResolver()
    private(set) var lastPlaceResolution: PlaceResolutionResult?

    func start() {
        guard !isDiscovering else { return }
        isDiscovering = true
        statusMessage = "正在查找通过数据线连接的 iPhone…"
        discovery = Task { [weak self] in
            guard let self else { return }
            defer { self.isDiscovering = false; self.discovery = nil }
            do {
                let result: DeviceList = try await client.call("list", timeout: 20)
                try Task.checkCancellation()
                devices = result.devices
                if selectedDeviceID == nil, let first = devices.first { selectedDeviceID = first.id }
                isReady = selectedDeviceID != nil
                statusMessage = devices.isEmpty
                    ? "未发现数据线连接的 iPhone。已有结果仍可查看；归档前请接回手机并解锁。"
                    : "已找到 iPhone。扫描前请保持手机解锁，并停止使用 iPhone 镜像。"
            } catch is CancellationError { return }
            catch { statusMessage = error.localizedDescription }
        }
    }

    func stop() {
        discovery?.cancel()
        client.cancel()
        selectedDeviceID = nil
        devices = []
        isReady = false
        statusMessage = "已关闭手机读取连接。"
    }

    func cancelPendingReads() {
        client.cancel()
        scannedToken = nil
        statusMessage = "已停止手机读取。请重新扫描后再归档。"
    }

    func scan(request: DeviceArchiveRequest,
              progress: @escaping @Sendable (ScanProgress) -> Void) async throws -> DeviceScanReport {
        try request.validateBasics()
        guard let deviceID = selectedDeviceID else { throw ArchiveError.invalid("请先选择通过数据线连接的 iPhone。") }
        scannedToken = nil
        scannedItems = [:]
        locationGroups = []
        statusMessage = "正在读取手机的分类、日期和位置索引；请保持解锁。"
        lastPlaceResolution = nil
        do {
            let response: ScanResponse = try await client.call("scan", arguments: [
                "deviceID": deviceID, "start": request.start.description, "end": request.end.description,
                "timeZoneIdentifier": request.timeZoneIdentifier
            ], timeout: 600, progress: progress)
            try Task.checkCancellation()
            guard response.deviceID == deviceID, selectedDeviceID == deviceID, !response.token.isEmpty else {
                throw ArchiveError.invalid("扫描的 iPhone 与所选设备不一致，请重新扫描。")
            }
            let items = try response.items.map { try $0.item() }
            let assets = try response.assets.map { try $0.asset() }
            guard Set(items.map(\.id)).count == items.count else { throw ArchiveError.invalid("手机返回了重复文件，请重新扫描。") }
            var issues = response.issues.map { $0.issue() }
            // The helper has already closed AFC and StopSession here.
            statusMessage = "手机索引读取完成，正在整理城市信息；此时可以拔掉数据线。"
            let resolution = try await placeResolver.resolve(assets: assets, progress: progress)
            let names = resolution.names
            let unresolved = assets.filter { $0.coordinate != nil && names[$0.id] == nil }
            if !unresolved.isEmpty {
                issues.append(DeviceScanIssue(id: "places:unresolved", name: "城市名称查询",
                    message: "\(unresolved.count) 项素材有坐标，但未能从手机现成信息或联网查询中确认城市，已放入“位置未知”供手动选择。可联网后重新扫描重试。"))
            }
            let groups = try DevicePlaceSelection.groups(assets: assets, resolvedPlaceNames: names)
            let report = DeviceScanReport(request: request, deviceID: response.token,
                deviceName: response.deviceName, files: items, issues: issues,
                outsideRangeCount: response.outsideRangeCount, ignoredCount: response.ignoredCount)
            _ = try DevicePlaceSelection.report(from: report, groups: groups,
                selectedGroupIDs: [], selectedUnknownAssetIDs: [])
            try Task.checkCancellation()
            scannedToken = response.token
            scannedItems = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
            locationGroups = groups
            lastPlaceResolution = resolution
            let placeSummary = resolution.networkRequestCount == 0
                ? "城市整理无需联网查询。"
                : "已为缺少可用城市信息的素材联网补查。"
            statusMessage = "已找到所选日期内“由我拍摄”的 \(assets.count) 项素材。\(placeSummary)请选择城市或地区，再预览归档。"
            return report
        } catch {
            client.cancel()
            statusMessage = error is CancellationError ? "扫描已取消，手机读取连接已关闭。" : error.localizedDescription
            throw error
        }
    }

    func prepare(report: DeviceScanReport) async throws {
        guard scannedToken == report.deviceID, report.canArchive,
              report.files.allSatisfy(matchesScannedItem) else {
            throw ArchiveError.invalid("请先选择完整可归档的素材。")
        }
        let _: USBHelperClient.Empty = try await client.call("prepare", arguments: [
            "token": report.deviceID, "livePhotoImportMode": report.livePhotoImportMode.rawValue
        ],
            lists: ["itemIDs": report.files.map(\.id)], timeout: 90)
    }

    func validate(deviceID: String) async throws {
        guard scannedToken == deviceID else { throw ArchiveError.invalid("扫描结果已经失效，请重新扫描。") }
        let _: USBHelperClient.Empty = try await client.call("validate", arguments: ["token": deviceID], timeout: 60)
    }

    func read(item: DeviceMediaItem, offset: Int64, length: Int, deviceID: String) async throws -> Data {
        guard scannedToken == deviceID, matchesScannedItem(item),
              offset >= 0, offset <= item.size, length > 0, length <= 4 * 1_048_576 else {
            throw ArchiveError.invalid("素材清单或读取范围已失效，请重新扫描。")
        }
        let response: ReadResponse = try await client.call("read", arguments: [
            "token": deviceID, "itemID": item.id
        ], integers: ["offset": offset, "length": Int64(length)], timeout: 90)
        guard let data = Data(base64Encoded: response.data), !data.isEmpty,
              data.count <= length, Int64(data.count) <= item.size - offset else {
            throw ArchiveError.invalid("手机返回的素材数据不完整，未将此文件计为成功。")
        }
        return data
    }

    private func matchesScannedItem(_ item: DeviceMediaItem) -> Bool {
        guard let original = scannedItems[item.id] else { return false }
        return original.name == item.name && original.size == item.size && original.kind == item.kind &&
            original.captureDay == item.captureDay && original.hasDateConflict == item.hasDateConflict &&
            original.dateBasis == item.dateBasis &&
            Set(original.companionIDs) == Set(item.companionIDs) &&
            original.companionIDs.count == item.companionIDs.count
    }

    func finishAccess() async {
        guard let token = scannedToken else { client.cancel(); return }
        do { let _: USBHelperClient.Empty = try await client.call("end", arguments: ["token": token], timeout: 10) }
        catch { client.cancel() }
    }

}

private struct DeviceList: Decodable, Sendable { let devices: [ConnectedPhone] }
private struct ReadResponse: Decodable, Sendable { let data: String }
private struct ScanResponse: Decodable, Sendable {
    let token: String; let deviceID: String; let deviceName: String
    let items: [ItemResponse]; let assets: [AssetResponse]; let issues: [IssueResponse]
    let outsideRangeCount: Int; let ignoredCount: Int
}
private struct ItemResponse: Decodable, Sendable {
    let id: String; let name: String; let kind: MediaKind; let size: Int64
    let captureDay: String; let dateBasis: String; let companionIDs: [String]
    func item() throws -> DeviceMediaItem {
        guard let day = CaptureDay(captureDay) else { throw ArchiveError.invalid("手机索引包含无法解析的拍摄日期。") }
        return DeviceMediaItem(id: id, name: name, kind: kind, size: size, captureDay: day,
                              dateBasis: dateBasis, companionIDs: companionIDs)
    }
}
private struct AssetResponse: Decodable, Sendable {
    let id: String; let name: String; let kind: MediaKind; let captureDay: String
    let latitude: Double?; let longitude: Double?; let fileIDs: [String]
    let localPlaceName: String?
    func asset() throws -> DeviceTravelAsset {
        guard let day = CaptureDay(captureDay) else { throw ArchiveError.invalid("手机素材的拍摄日期无法解析。") }
        let coordinate: GeoCoordinate?
        if let latitude, let longitude { coordinate = GeoCoordinate(latitude: latitude, longitude: longitude) }
        else { coordinate = nil }
        return DeviceTravelAsset(id: id, name: name, kind: kind, captureDay: day, coordinate: coordinate, fileIDs: fileIDs, localPlaceName: localPlaceName)
    }
}
private struct IssueResponse: Decodable, Sendable {
    let id: String; let name: String; let message: String; let isBlocking: Bool
    let assetID: String?
    func issue() -> DeviceScanIssue {
        DeviceScanIssue(id: id, name: name, message: message, isBlocking: isBlocking,
                        scope: assetID.map { .assets([$0]) } ?? .global)
    }
}
