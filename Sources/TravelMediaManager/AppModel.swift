import AppKit
import Combine
import Foundation
import TravelArchiveCore

/// Keeps an explicitly acquired folder scope alive for the current selection.
/// Open-panel grants and the direct-download build may not require an explicit
/// scope, so a false return is not itself a filesystem permission failure.
final class SelectedFolderAccess {
    private let url: URL
    private let acquired: Bool
    private let stopAccess: (URL) -> Void

    init(url: URL,
         startAccess: (URL) -> Bool = { $0.startAccessingSecurityScopedResource() },
         stopAccess: @escaping (URL) -> Void = { $0.stopAccessingSecurityScopedResource() }) {
        self.url = url
        self.stopAccess = stopAccess
        acquired = startAccess(url)
    }

    deinit {
        if acquired { stopAccess(url) }
    }
}

/// Display-only data. Device items never pretend to have a local file URL or inode.
struct ArchivePreview {
    struct Issue: Identifiable {
        let id: String
        let name: String
        let location: String?
        let message: String
        let isBlocking: Bool
        let disposition: String
    }
    let fileCount: Int
    let assetCount: Int?
    let totalBytes: Int64
    let counts: [MediaKind: Int]
    let issues: [Issue]
    let outsideRangeCount: Int
    let canArchive: Bool
    let isDevice: Bool

    func count(_ kind: MediaKind) -> Int { counts[kind] ?? 0 }

    init(folder report: ScanReport) {
        fileCount = report.files.count
        assetCount = nil
        totalBytes = report.totalBytes
        counts = Dictionary(uniqueKeysWithValues: MediaKind.allCases.map { ($0, report.count($0)) })
        let paths = Set(report.files.map { $0.url.path })
        issues = report.issues.map {
            Issue(id: $0.id, name: $0.url.lastPathComponent, location: $0.url.path,
                  message: $0.message, isBlocking: $0.isBlocking,
                  disposition: $0.isBlocking ? "阻止归档" : (paths.contains($0.url.path) ? "已匹配 · 有提示" : "未纳入"))
        }
        outsideRangeCount = report.outsideRangeCount
        canArchive = report.canArchive
        isDevice = false
    }

    init(device report: DeviceScanReport, assets: [DeviceTravelAsset]) {
        fileCount = report.files.count
        let fileIDs = Set(report.files.map(\.id))
        let includedAssets = assets.filter { !fileIDs.isDisjoint(with: $0.fileIDs) }
        assetCount = includedAssets.count
        totalBytes = report.totalBytes
        counts = Dictionary(uniqueKeysWithValues: MediaKind.allCases.map { kind in
            (kind, includedAssets.filter { $0.kind == kind }.count)
        })
        issues = report.issues.map {
            Issue(id: $0.id, name: $0.name, location: report.deviceName,
                  message: $0.message, isBlocking: $0.isBlocking,
                  disposition: $0.isBlocking ? "阻止归档" : "提示")
        }
        outsideRangeCount = report.outsideRangeCount
        canArchive = report.canArchive
        isDevice = true
    }
}

@MainActor
final class AppModel: ObservableObject {
    enum Phase { case idle, scanning, ready, archiving, succeeded, failed, cancelled }
    enum SourceKind: String, CaseIterable, Identifiable {
        case folder, iphone
        var id: String { rawValue }
        var label: String { self == .folder ? "文件夹" : "iPhone（数据线）" }
    }
    private enum ArchivePlan: Sendable {
        case folder(ScanReport)
        case iphone(DeviceScanReport)
    }
    private enum ScanRequest: Sendable {
        case folder(ArchiveRequest)
        case iphone(DeviceArchiveRequest)
    }

    let phone = IPhoneSource()
    @Published var sourceKind: SourceKind = .folder {
        didSet {
            guard sourceKind != oldValue else { return }
            invalidatePreview()
            if sourceKind == .folder { phone.stop() }
        }
    }
    @Published var travelName = "" { didSet { if travelName != oldValue { invalidatePreview() } } }
    @Published var startDate = Date() { didSet { if startDate != oldValue { invalidatePreview() } } }
    @Published var endDate = Date() { didSet { if endDate != oldValue { invalidatePreview() } } }
    @Published var timeZoneIdentifier = TimeZone.current.identifier {
        didSet { if timeZoneIdentifier != oldValue { invalidatePreview() } }
    }
    @Published private(set) var livePhotoImportMode: LivePhotoImportMode = .complete
    @Published private(set) var sourceURL: URL?
    @Published private(set) var destinationURL: URL?
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var preview: ArchivePreview?
    @Published private(set) var scanProgress: ScanProgress?
    @Published private(set) var archiveProgress: ArchiveProgress?
    @Published private(set) var result: ArchiveResult?
    @Published private(set) var errorMessage: String?
    @Published private(set) var partialTargetURL: URL?
    @Published private(set) var completedFiles = 0
    @Published private(set) var isCancelling = false
    @Published private(set) var locationGroups: [DevicePlaceGroup] = []
    @Published private(set) var selectedGroupIDs = Set<String>()
    @Published private(set) var selectedUnknownAssetIDs = Set<String>()

    private var plan: ArchivePlan?
    private var fullDeviceReport: DeviceScanReport?
    private var task: Task<Void, Never>?
    private var operationID = UUID()
    private var destinationValidated = false
    private var interruptedReason: String?
    private var phonePlanDeviceID: String?
    private var observers = Set<AnyCancellable>()
    private var sourceFolderAccess: SelectedFolderAccess?
    private var destinationFolderAccess: SelectedFolderAccess?

    init() {
        phone.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &observers)
        phone.$selectedDeviceID.removeDuplicates().dropFirst().sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.phoneCatalogChanged() }
        }.store(in: &observers)
    }

    var isBusy: Bool { phase == .scanning || phase == .archiving }
    var canChangeLivePhotoImportMode: Bool {
        !isBusy && (!hasDeviceSelection || phase == .ready)
    }
    var folderName: String {
        let name = travelName.trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(CaptureDay(date: startDate))_\(name.isEmpty ? "旅行名称" : name)"
    }
    var targetURL: URL? { destinationURL?.appendingPathComponent(folderName, isDirectory: true) }
    var resultURL: URL? { result?.targetURL ?? partialTargetURL }
    var canScan: Bool { !isBusy && (try? makeRequest()) != nil }
    var canArchive: Bool {
        phase == .ready && destinationValidated && plan != nil && preview?.canArchive == true
            && (sourceKind == .folder || (phonePlanIsCurrent && phone.isReady && !phone.isDiscovering))
    }
    private var phonePlanIsCurrent: Bool {
        phonePlanDeviceID != nil && phonePlanDeviceID == phone.selectedDeviceID
    }
    var hasDeviceSelection: Bool { fullDeviceReport != nil && sourceKind == .iphone }
    var matchedAssetCount: Int { locationGroups.reduce(0) { $0 + $1.assets.count } }
    var selectedAssetCount: Int { selectedAssets.count }
    var hasPlaceSelection: Bool { !selectedGroupIDs.isEmpty || !selectedUnknownAssetIDs.isEmpty }
    private var selectedAssets: [DeviceTravelAsset] {
        locationGroups.flatMap { group in
            group.isUnknown
                ? group.assets.filter { selectedUnknownAssetIDs.contains($0.id) }
                : (selectedGroupIDs.contains(group.id) ? group.assets : [])
        }
    }
    var inputHint: String {
        if hasDeviceSelection {
            return "已读取所选日期内“由我拍摄”的素材。勾选城市或地区后，查看归档预览。"
        }
        do { _ = try makeRequest(); return "准备好后，扫描所选日期内的素材。" }
        catch { return error.localizedDescription }
    }
    var statusLabel: String {
        if isCancelling { return "正在取消…" }
        switch phase {
        case .idle: return "等待扫描"
        case .scanning: return "扫描中"
        case .ready:
            if hasDeviceSelection && matchedAssetCount > 0 && !hasPlaceSelection { return "请选择地点" }
            return preview?.fileCount == 0 ? "没有可归档素材" : (canArchive ? "待确认" : "请检查提示")
        case .archiving: return archiveProgress?.stage == .verifying ? "校验中" : (sourceKind == .iphone ? "导入中" : "复制中")
        case .succeeded: return "归档完成"
        case .failed: return preview == nil ? "扫描未完成" : "归档未完成"
        case .cancelled: return "已取消"
        }
    }

    func findPhones() { guard !isBusy else { return }; phone.start() }

    func setLivePhotoImportMode(_ mode: LivePhotoImportMode) {
        guard canChangeLivePhotoImportMode, mode != livePhotoImportMode else { return }
        livePhotoImportMode = mode
        // The full scan and place choices stay intact. Changing how a Live
        // Photo is copied only rebuilds the local archive plan.
        if phase == .ready, sourceKind == .iphone { updateDeviceSelection() }
    }

    func selectLocation(_ groupID: String, selected: Bool) {
        guard !isBusy, phase == .ready,
              locationGroups.contains(where: { $0.id == groupID && !$0.isUnknown }) else { return }
        if selected { selectedGroupIDs.insert(groupID) } else { selectedGroupIDs.remove(groupID) }
        updateDeviceSelection()
    }

    func selectUnknownAsset(_ assetID: String, selected: Bool) {
        guard !isBusy, phase == .ready,
              locationGroups.contains(where: { $0.isUnknown && $0.assets.contains(where: { $0.id == assetID }) }) else { return }
        if selected { selectedUnknownAssetIDs.insert(assetID) } else { selectedUnknownAssetIDs.remove(assetID) }
        updateDeviceSelection()
    }

    func chooseFolder(isSource: Bool) {
        guard !isBusy else { return }
        let panel = NSOpenPanel()
        panel.title = isSource ? "选择素材来源" : "选择保存位置"
        panel.message = isSource ? "请选择包含照片、视频和音频的素材文件夹。" : "请选择保存位置，开始归档后会在其中创建旅行文件夹。"
        panel.prompt = "选择文件夹"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = false
        panel.resolvesAliases = true
        panel.directoryURL = isSource ? sourceURL : destinationURL
        guard panel.runModal() == .OK, let url = panel.url else { return }
        setFolder(url, isSource: isSource)
    }

    func setFolder(_ url: URL, isSource: Bool) {
        guard !isBusy else { return }
        // Acquire the new selection before releasing the old one. Keep both
        // roots available through scan, preview, import, and result inspection.
        // Selections are session-only; no persistent bookmarks are needed.
        let access = SelectedFolderAccess(url: url)
        if isSource {
            sourceFolderAccess = access
            sourceURL = url
        } else {
            destinationFolderAccess = access
            destinationURL = url
        }
        invalidatePreview()
    }

    func scan() {
        guard !isBusy else { return }
        let request: ScanRequest
        do { request = try makeRequest() }
        catch { errorMessage = error.localizedDescription; return }
        resetOutcome()
        preview = nil
        plan = nil
        clearDeviceSelection()
        destinationValidated = false
        if sourceKind == .iphone {
            phonePlanDeviceID = phone.selectedDeviceID
        }
        phase = .scanning
        let id = UUID()
        operationID = id
        let progress = scanProgressHandler(id: id)
        let phoneSource = phone
        task = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            do {
                try Task.checkCancellation()
                switch request {
                case .folder(let request):
                    try ArchiveEngine.validateDestination(for: request)
                    let report = try await MediaScanner.scan(request: request, progress: progress)
                    try Task.checkCancellation()
                    var destinationError: String?
                    do { try ArchiveEngine.validateDestination(for: request, requiredBytes: report.totalBytes) }
                    catch { destinationError = error.localizedDescription }
                    try Task.checkCancellation()
                    await self.finishScan(.folder(report), destinationError: destinationError, id: id)
                case .iphone(let request):
                    try DeviceArchiveEngine.validateDestination(for: request)
                    let report = try await phoneSource.scan(request: request, progress: progress)
                    try Task.checkCancellation()
                    await self.finishScan(.iphone(report), destinationError: nil, id: id)
                }
            } catch {
                await self.finishFailure(error, cancelled: Task.isCancelled || error is CancellationError, wasScanning: true, id: id)
            }
        }
    }

    func archive() {
        guard canArchive, let plan else { return }
        resetOutcome()
        phase = .archiving
        let id = UUID()
        operationID = id
        let progress = archiveProgressHandler(id: id)
        let phoneSource = phone
        task = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            do {
                try Task.checkCancellation()
                let result: ArchiveResult
                switch plan {
                case .folder(let report):
                    try ArchiveEngine.validateDestination(for: report.request, requiredBytes: report.totalBytes)
                    result = try await ArchiveEngine.archive(report: report, progress: progress)
                case .iphone(let report):
                    try DeviceArchiveEngine.validateDestination(for: report.request, requiredBytes: report.totalBytes)
                    try await phoneSource.prepare(report: report)
                    result = try await DeviceArchiveEngine.archive(report: report, read: { item, offset, length in
                        try await phoneSource.read(item: item, offset: offset, length: length, deviceID: report.deviceID)
                    }, validate: {
                        try await phoneSource.validate(deviceID: report.deviceID)
                    }, progress: progress)
                }
                if case .iphone = plan { await phoneSource.finishAccess() }
                // A returned result means all files were committed and verified.
                await self.finishArchive(result, id: id)
            } catch {
                if case .iphone = plan { await phoneSource.finishAccess() }
                await self.finishFailure(error, cancelled: Task.isCancelled || error is CancellationError, wasScanning: false, id: id)
            }
        }
    }

    func cancel() {
        guard isBusy, !isCancelling else { return }
        isCancelling = true
        task?.cancel()
        if sourceKind == .iphone { phone.cancelPendingReads() }
    }

    func openResult() {
        guard let url = resultURL else { return }
        if !NSWorkspace.shared.open(url) { errorMessage = "无法打开结果文件夹，请检查保存设备是否仍连接。" }
    }

    func confirmCloseWhileBusy() {
        guard isBusy else { return }
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = isCancelling ? "正在安全停止任务" : "当前任务尚未完成"
        alert.informativeText = isCancelling
            ? "请等待取消完成后再关闭窗口。原素材保持不变。"
            : "可以继续等待，或取消当前任务。取消完成后可关闭窗口；已复制并校验的文件会保留。"
        alert.addButton(withTitle: "继续等待")
        if !isCancelling { alert.addButton(withTitle: "取消当前任务") }
        if alert.runModal() == .alertSecondButtonReturn { cancel() }
    }

    private func makeRequest() throws -> ScanRequest {
        guard !travelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ArchiveError.invalid("请填写旅行名称。")
        }
        guard CaptureDay(date: startDate) <= CaptureDay(date: endDate) else {
            throw ArchiveError.invalid("结束日期不能早于开始日期。")
        }
        guard let destinationURL else { throw ArchiveError.invalid("请选择归档保存位置。") }
        switch sourceKind {
        case .folder:
            guard let sourceURL else { throw ArchiveError.invalid("请选择素材来源文件夹。") }
            let request = ArchiveRequest(name: travelName, start: CaptureDay(date: startDate), end: CaptureDay(date: endDate), source: sourceURL, destination: destinationURL)
            try request.validateBasics()
            return .folder(request)
        case .iphone:
            guard phone.selectedDeviceID != nil, phone.isReady, !phone.isDiscovering else {
                throw ArchiveError.invalid("请用数据线连接 iPhone，解锁并信任此 Mac，然后查找并选择设备。")
            }
            let request = DeviceArchiveRequest(name: travelName, start: CaptureDay(date: startDate), end: CaptureDay(date: endDate), destination: destinationURL, timeZoneIdentifier: timeZoneIdentifier)
            try request.validateBasics()
            return .iphone(request)
        }
    }

    private func phoneCatalogChanged() {
        guard sourceKind == .iphone else { return }
        // Keep the scanned metadata available without a USB session. Only an
        // explicit device change invalidates this selection; importing performs
        // fresh connection and file checks before creating a destination.
        if phonePlanIsCurrent { return }
        if isBusy {
            // Cancelling our own device reads also retires the session and emits
            // a catalog revision. Do not turn a user cancellation into a failure.
            guard !isCancelling else { return }
            interruptedReason = "所选 iPhone 已改变，本次任务已停止。请重新扫描。"
            cancel()
        } else {
            invalidatePreview()
        }
    }

    private func invalidatePreview() {
        guard !isBusy else { return }
        operationID = UUID()
        preview = nil
        plan = nil
        clearDeviceSelection()
        phonePlanDeviceID = nil
        destinationValidated = false
        resetOutcome()
        phase = .idle
    }

    private func clearDeviceSelection() {
        fullDeviceReport = nil
        locationGroups = []
        selectedGroupIDs = []
        selectedUnknownAssetIDs = []
    }

    private func updateDeviceSelection() {
        guard let fullDeviceReport else { return }
        destinationValidated = false
        errorMessage = nil
        preview = nil
        plan = nil
        do {
            let selectedReport = try DevicePlaceSelection.report(
                from: fullDeviceReport, groups: locationGroups,
                selectedGroupIDs: selectedGroupIDs, selectedUnknownAssetIDs: selectedUnknownAssetIDs,
                livePhotoImportMode: livePhotoImportMode)
            plan = .iphone(selectedReport)
            preview = ArchivePreview(device: selectedReport, assets: selectedAssets)
            try DeviceArchiveEngine.validateDestination(for: selectedReport.request, requiredBytes: selectedReport.totalBytes)
            destinationValidated = true
        } catch {
            errorMessage = error.localizedDescription
            // Never leave an earlier selection eligible for import after a
            // filtering or destination validation failure.
            plan = nil
        }
    }

    private func resetOutcome() {
        scanProgress = nil
        archiveProgress = nil
        result = nil
        errorMessage = nil
        partialTargetURL = nil
        completedFiles = 0
        isCancelling = false
        interruptedReason = nil
    }

    private func finishScan(_ plan: ArchivePlan, destinationError: String?, id: UUID) {
        guard operationID == id else { return }
        if case .iphone = plan, !phonePlanIsCurrent, !isCancelling {
            interruptedReason = "所选 iPhone 已改变，请重新扫描。"
        }
        if interruptedReason != nil || isCancelling {
            finishFailure(CancellationError(), cancelled: true, wasScanning: true, id: id)
            return
        }
        phase = .ready
        switch plan {
        case .folder(let report):
            self.plan = plan
            preview = ArchivePreview(folder: report)
            destinationValidated = destinationError == nil
            errorMessage = destinationError
        case .iphone(let report):
            fullDeviceReport = report
            locationGroups = phone.locationGroups
            selectedGroupIDs = []
            selectedUnknownAssetIDs = []
            updateDeviceSelection()
        }
        isCancelling = false
        task = nil
    }

    private func finishArchive(_ result: ArchiveResult, id: UUID) {
        guard operationID == id else { return }
        self.result = result
        completedFiles = result.fileCount
        phase = .succeeded
        destinationValidated = false
        isCancelling = false
        task = nil
    }

    private func finishFailure(_ error: Error, cancelled: Bool, wasScanning: Bool, id: UUID) {
        guard operationID == id else { return }
        if let failure = error as? ArchiveFailure {
            completedFiles = failure.completedFiles
            partialTargetURL = failure.targetURL
        }
        errorMessage = interruptedReason ?? (cancelled
            ? (wasScanning ? "扫描已取消，尚未创建旅行文件夹。" : "归档已取消。已复制并校验 \(completedFiles) 个文件；其余素材尚未归档。")
            : error.localizedDescription)
        phase = cancelled && interruptedReason == nil ? .cancelled : .failed
        destinationValidated = false
        isCancelling = false
        task = nil
    }

    private func scanProgressHandler(id: UUID) -> @Sendable (ScanProgress) -> Void {
        let throttle = ProgressThrottle()
        return { [self] value in
            guard throttle.shouldEmit() else { return }
            Task { @MainActor [self] in
                guard self.operationID == id, self.phase == .scanning else { return }
                self.scanProgress = value
            }
        }
    }

    private func archiveProgressHandler(id: UUID) -> @Sendable (ArchiveProgress) -> Void {
        let throttle = ProgressThrottle()
        return { [self] value in
            guard throttle.shouldEmit(key: value.stage.rawValue) else { return }
            Task { @MainActor [self] in
                guard self.operationID == id, self.phase == .archiving else { return }
                self.archiveProgress = value
                self.completedFiles = value.completedFiles
            }
        }
    }
}

private final class ProgressThrottle: @unchecked Sendable {
    private let lock = NSLock()
    private var lastTime = 0.0
    private var lastKey = ""
    func shouldEmit(key: String = "") -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let time = ProcessInfo.processInfo.systemUptime
        guard time - lastTime >= 0.08 || key != lastKey else { return false }
        lastTime = time
        lastKey = key
        return true
    }
}
