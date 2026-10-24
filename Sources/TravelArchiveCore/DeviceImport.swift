import Foundation

public enum DeviceMediaFilename {
    /// Keep the device catalog name. An edited asset's internal disk name can
    /// be a shared placeholder such as FullSizeRender.heic.
    public static func resolve(name: String?, originalFilename: String?) -> String {
        if let name, !name.isEmpty { return name }
        return originalFilename ?? ""
    }
}

public struct DeviceArchiveRequest: Sendable {
    public let name: String
    public let start: CaptureDay
    public let end: CaptureDay
    public let destination: URL
    public let timeZoneIdentifier: String
    public init(name: String, start: CaptureDay, end: CaptureDay, destination: URL, timeZoneIdentifier: String) {
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.start = start; self.end = end; self.destination = destination; self.timeZoneIdentifier = timeZoneIdentifier
    }
    public var folderName: String { "\(start)_\(name)" }
    public var targetURL: URL { destination.appendingPathComponent(folderName, isDirectory: true) }
    public func validateBasics() throws {
        try ArchiveRequest(name: name, start: start, end: end, source: destination, destination: destination).validateBasics()
        guard destination.isFileURL, !destination.path.contains("\0") else { throw ArchiveError.invalid("请选择本机或外置硬盘上的真实保存文件夹。") }
        guard TimeZone(identifier: timeZoneIdentifier) != nil else { throw ArchiveError.invalid("拍摄日期使用的时区无效，请重新选择。") }
    }
}

public struct DeviceMediaItem: Identifiable, Sendable {
    public let id: String
    public let name: String
    public let kind: MediaKind
    public let size: Int64
    public let captureDay: CaptureDay?
    public let dateBasis: String
    public let companionIDs: [String]
    public let hasDateConflict: Bool
    public init(id: String, name: String, kind: MediaKind, size: Int64, captureDay: CaptureDay?, dateBasis: String, companionIDs: [String] = [], hasDateConflict: Bool = false) {
        self.id = id; self.name = name; self.kind = kind; self.size = size
        self.captureDay = captureDay; self.dateBasis = dateBasis; self.companionIDs = companionIDs; self.hasDateConflict = hasDateConflict
    }
}

public struct DeviceScanIssue: Identifiable, Sendable {
    public enum Scope: Sendable, Equatable {
        case global
        case files(Set<String>)
        case assets(Set<String>)
    }
    /// Identifier of this issue, not an implicit reference to a media item.
    public let id: String
    public let name: String
    public let message: String
    public let isBlocking: Bool
    public let scope: Scope
    /// Filename collisions are recomputed after the user selects places.
    public let isFilenameCollision: Bool
    public init(id: String, name: String, message: String, isBlocking: Bool = false, scope: Scope = .global, isFilenameCollision: Bool = false) {
        self.id = id; self.name = name; self.message = message; self.isBlocking = isBlocking
        self.scope = scope; self.isFilenameCollision = isFilenameCollision
    }
}

public enum LivePhotoImportMode: String, CaseIterable, Sendable {
    case complete
    case stillOnly
}

public struct DeviceScanReport: Sendable {
    public let request: DeviceArchiveRequest
    public let deviceID: String
    public let deviceName: String
    public let files: [DeviceMediaItem]
    public let issues: [DeviceScanIssue]
    public let outsideRangeCount: Int
    public let ignoredCount: Int
    public let livePhotoImportMode: LivePhotoImportMode
    public var totalBytes: Int64 {
        var total: Int64 = 0
        for file in files {
            let next = total.addingReportingOverflow(file.size)
            if file.size < 0 || next.overflow { return Int64.max }
            total = next.partialValue
        }
        return total
    }
    public var canArchive: Bool { !files.isEmpty && totalBytes <= Int64.max / 2 && !issues.contains(where: \.isBlocking) }
    public func count(_ kind: MediaKind) -> Int { files.filter { $0.kind == kind }.count }
    public init(request: DeviceArchiveRequest, deviceID: String, deviceName: String, files: [DeviceMediaItem], issues: [DeviceScanIssue], outsideRangeCount: Int, ignoredCount: Int, livePhotoImportMode: LivePhotoImportMode = .complete) {
        self.request = request; self.deviceID = deviceID; self.deviceName = deviceName; self.files = files; self.issues = issues
        self.outsideRangeCount = outsideRangeCount; self.ignoredCount = ignoredCount
        self.livePhotoImportMode = livePhotoImportMode
    }
}

public enum DeviceMediaPlanner {
    static let extensions: [String: MediaKind] = [
        "mp4": .video, "mov": .video, "m4v": .video,
        "jpg": .photo, "jpeg": .photo, "heic": .photo, "heif": .photo, "dng": .photo,
        "png": .photo, "gif": .photo, "tif": .photo, "tiff": .photo
    ]
    static func isSupported(_ item: DeviceMediaItem) -> Bool {
        (item.kind == .photo || item.kind == .video) && extensions[(item.name as NSString).pathExtension.lowercased()] == item.kind
    }
    static func hasSafeName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && name.utf8.count <= 255 &&
        !name.contains("/") && !name.contains("\\") && !name.contains(":") &&
        !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }
    static func collisionKey(_ name: String) -> String {
        name.precomposedStringWithCanonicalMapping.lowercased(with: Locale(identifier: "en_US_POSIX"))
    }

    /// A still-only plan is an explicit projection of the complete catalog,
    /// validated by DevicePlaceSelection and bound to the original USB snapshot.
    /// Keep the original companion ID as evidence; never erase it to make a
    /// Live Photo look like an unrelated image. The omitted video is not read.
    static func hasValidComposition(_ group: [DeviceMediaItem], mode: LivePhotoImportMode, allIDs: Set<String>) -> Bool {
        if mode == .stillOnly {
            guard group.count == 1, let file = group.first else { return false }
            if file.companionIDs.isEmpty { return true }
            return file.kind == .photo && file.companionIDs.count == 1 &&
                !file.companionIDs[0].isEmpty && !allIDs.contains(file.companionIDs[0])
        }
        guard group.count == 1 || (group.count == 2 && group.filter { $0.kind == .photo }.count == 1 &&
                                  group.filter { $0.kind == .video }.count == 1) else { return false }
        let ids = Set(group.map(\.id))
        return group.allSatisfy { file in
            let expected = ids.subtracting([file.id])
            return Set(file.companionIDs) == expected && file.companionIDs.count == expected.count
        }
    }

    /// Companion links must come from explicit device metadata. A shared base
    /// filename alone never establishes a Live Photo relationship.
    public static func scan(items: [DeviceMediaItem], request: DeviceArchiveRequest, deviceID: String, deviceName: String, livePhotoImportMode: LivePhotoImportMode = .complete) throws -> DeviceScanReport {
        try request.validateBasics()
        guard !deviceID.isEmpty else { throw ArchiveError.invalid("设备标识不可用，请重新连接 iPhone。") }
        var issues: [DeviceScanIssue] = []
        var ignored = 0
        var candidates: [String: DeviceMediaItem] = [:]
        let grouped = Dictionary(grouping: items, by: \.id)
        let allIDs = Set(grouped.keys)
        for (id, group) in grouped {
            guard !id.isEmpty, group.count == 1 else {
                issues.append(DeviceScanIssue(id: "identity:\(id)", name: group.first?.name ?? "", message: "设备返回了重复或缺失的素材标识，请重新扫描。", isBlocking: true))
                continue
            }
            let item = group[0]
            guard isSupported(item) else { ignored += 1; continue }
            guard hasSafeName(item.name), item.size > 0, item.size <= Int64.max / 2 else {
                issues.append(DeviceScanIssue(id: "invalid:\(id)", name: item.name, message: "素材名称或大小无效，无法安全归档。", isBlocking: true, scope: .files([id])))
                continue
            }
            candidates[id] = item
        }
        var links: [String: Set<String>] = Dictionary(uniqueKeysWithValues: candidates.keys.map { ($0, []) })
        var missing: [String: Set<String>] = [:]
        var omittedCompanionOwners: [String: Set<String>] = [:]
        for item in candidates.values {
            for companion in Set(item.companionIDs) where companion != item.id {
                if candidates[companion] != nil {
                    links[item.id, default: []].insert(companion)
                    links[companion, default: []].insert(item.id)
                } else if livePhotoImportMode == .stillOnly, item.kind == .photo,
                          item.companionIDs.count == 1, !companion.isEmpty, grouped[companion] == nil {
                    omittedCompanionOwners[companion, default: []].insert(item.id)
                } else {
                    missing[item.id, default: []].insert(companion)
                }
            }
        }
        let reusedCompanionOwners = omittedCompanionOwners.values.filter { $0.count > 1 }.reduce(into: Set<String>()) { $0.formUnion($1) }
        var visited = Set<String>()
        var selected: [DeviceMediaItem] = []
        var outside = 0
        for startID in candidates.keys.sorted() where !visited.contains(startID) {
            var pending = [startID]
            var group: [DeviceMediaItem] = []
            while let id = pending.popLast() {
                guard visited.insert(id).inserted, let item = candidates[id] else { continue }
                group.append(item)
                pending.append(contentsOf: links[id, default: []].sorted())
            }
            let days = Set(group.compactMap(\.captureDay))
            let intersects = days.contains { request.start <= $0 && $0 <= request.end }
            if group.contains(where: \.hasDateConflict) {
                issues.append(DeviceScanIssue(id: "metadata-conflict:\(startID)", name: group.map(\.name).sorted().joined(separator: "、"),
                                              message: "素材拍摄日期存在元数据冲突，该素材及关联组件均未纳入本次归档；不会继承同伴日期掩盖冲突。",
                                              isBlocking: intersects, scope: .files(Set(group.map(\.id)))))
                continue
            }
            if days.isEmpty {
                for item in group {
                    issues.append(DeviceScanIssue(id: "date:\(item.id)", name: item.name, message: "没有可靠的拍摄日期，未纳入本次旅行。", scope: .files([item.id])))
                }
                continue
            }
            guard intersects else { outside += group.count; continue }
            let missingIDs = group.reduce(into: Set<String>()) { $0.formUnion(missing[$1.id] ?? []) }
            if !missingIDs.isEmpty {
                issues.append(DeviceScanIssue(id: "missing:\(startID)", name: group.map(\.name).sorted().joined(separator: "、"), message: "关联照片或视频缺失，无法完整归档 Live Photo／关联素材，请重新扫描。", isBlocking: true, scope: .files(Set(group.map(\.id)))))
                continue
            }
            guard days.count == 1, let day = days.first else {
                issues.append(DeviceScanIssue(id: "conflict:\(startID)", name: group.map(\.name).sorted().joined(separator: "、"), message: "明确关联的照片／视频拍摄日期不一致，不能自动确定旅行归属。", isBlocking: true, scope: .files(Set(group.map(\.id)))))
                continue
            }
            guard hasValidComposition(group, mode: livePhotoImportMode, allIDs: allIDs),
                  group.allSatisfy({ !reusedCompanionOwners.contains($0.id) }) else {
                issues.append(DeviceScanIssue(id: "composition:\(startID)", name: group.map(\.name).sorted().joined(separator: "、"),
                                              message: livePhotoImportMode == .stillOnly
                                                ? "实况照片的组件关联或导入方式不一致，请重新扫描；仅静态模式不能包含配套视频。"
                                                : "实况照片的组件关联缺失或不一致，请重新扫描。",
                                              isBlocking: true, scope: .files(Set(group.map(\.id)))))
                continue
            }
            for item in group {
                selected.append(DeviceMediaItem(id: item.id, name: item.name, kind: item.kind, size: item.size,
                                                captureDay: day, dateBasis: item.captureDay == nil ? "明确关联素材的拍摄日期（\(day)）" : item.dateBasis,
                                                companionIDs: item.companionIDs, hasDateConflict: item.hasDateConflict))
            }
        }
        for group in Dictionary(grouping: selected, by: { collisionKey($0.name) }).values where group.count > 1 {
            for item in group {
                issues.append(DeviceScanIssue(id: "name:\(item.id)", name: item.name, message: "多个素材具有相同的目标文件名，无法平铺归档；不会覆盖或自动改名。", isBlocking: true, scope: .files([item.id]), isFilenameCollision: true))
            }
        }
        var total: Int64 = 0
        for item in selected {
            let sum = total.addingReportingOverflow(item.size)
            guard !sum.overflow, sum.partialValue <= Int64.max / 2 else { throw ArchiveError.invalid("素材总大小超过单次归档限制。") }
            total = sum.partialValue
        }
        return DeviceScanReport(request: request, deviceID: deviceID, deviceName: deviceName,
                                files: selected.sorted { ($0.captureDay!, $0.name, $0.id) < ($1.captureDay!, $1.name, $1.id) },
                                issues: issues.sorted { $0.id < $1.id }, outsideRangeCount: outside, ignoredCount: ignored,
                                livePhotoImportMode: livePhotoImportMode)
    }
}
