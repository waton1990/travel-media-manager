import Foundation

public struct GeoCoordinate: Codable, Hashable, Sendable {
    public let latitude: Double
    public let longitude: Double

    public init?(latitude: Double, longitude: Double) {
        guard latitude.isFinite, longitude.isFinite,
              (-90...90).contains(latitude), (-180...180).contains(longitude) else { return nil }
        self.latitude = latitude
        self.longitude = longitude
    }

    private enum CodingKeys: String, CodingKey { case latitude, longitude }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let latitude = try values.decode(Double.self, forKey: .latitude)
        let longitude = try values.decode(Double.self, forKey: .longitude)
        guard let coordinate = Self(latitude: latitude, longitude: longitude) else {
            throw DecodingError.dataCorruptedError(forKey: .latitude, in: values, debugDescription: "经纬度必须是有效范围内的有限数值。")
        }
        self = coordinate
    }
}

/// One Photos-library asset, which may contain several files (for example a
/// Live Photo's still image and video). Place selection preserves this unit;
/// the explicit still-only import mode subsequently projects its photo file.
public struct DeviceTravelAsset: Identifiable, Sendable {
    public let id: String
    public let name: String
    public let kind: MediaKind
    public let captureDay: CaptureDay
    public let coordinate: GeoCoordinate?
    public let fileIDs: [String]
    /// City label validated against the phone's location record; otherwise nil.
    public let localPlaceName: String?

    public init(id: String, name: String, kind: MediaKind, captureDay: CaptureDay, coordinate: GeoCoordinate?, fileIDs: [String], localPlaceName: String? = nil) {
        self.id = id; self.name = name; self.kind = kind
        self.captureDay = captureDay; self.coordinate = coordinate; self.fileIDs = fileIDs
        self.localPlaceName = localPlaceName
    }
}

public struct DevicePlaceGroup: Identifiable, Sendable {
    public let id: String
    public let name: String
    public let assets: [DeviceTravelAsset]
    public let isUnknown: Bool

    public init(id: String, name: String, assets: [DeviceTravelAsset], isUnknown: Bool = false) {
        self.id = id; self.name = name; self.assets = assets; self.isUnknown = isUnknown
    }
}

public enum DevicePlaceSelection {
    public static let unknownGroupID = "unknown"

    /// Place names come from validated local records or geocoding, keyed by asset identifier.
    /// A missing coordinate or unresolved name stays in the unknown group.
    public static func groups(assets: [DeviceTravelAsset], resolvedPlaceNames: [String: String]) throws -> [DevicePlaceGroup] {
        var seen = Set<String>()
        var buckets: [String: [DeviceTravelAsset]] = [:]
        var unknown: [DeviceTravelAsset] = []
        for asset in assets {
            guard !asset.id.isEmpty, seen.insert(asset.id).inserted else {
                throw ArchiveError.invalid("地点列表包含重复或缺失的素材标识，请重新扫描。")
            }
            let name = resolvedPlaceNames[asset.id]?.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping ?? ""
            if asset.coordinate != nil, !name.isEmpty {
                buckets[name, default: []].append(asset)
            } else {
                unknown.append(asset)
            }
        }
        guard Set(resolvedPlaceNames.keys).isSubset(of: seen) else {
            throw ArchiveError.invalid("地点解析结果与当前素材不一致，请重新扫描。")
        }
        func sorted(_ assets: [DeviceTravelAsset]) -> [DeviceTravelAsset] {
            assets.sorted { ($0.captureDay, $0.name, $0.id) < ($1.captureDay, $1.name, $1.id) }
        }
        var result = buckets.keys.sorted().map {
            DevicePlaceGroup(id: "place:\($0)", name: $0, assets: sorted(buckets[$0]!))
        }
        if !unknown.isEmpty {
            result.append(DevicePlaceGroup(id: unknownGroupID, name: "位置未知", assets: sorted(unknown), isUnknown: true))
        }
        return result
    }

    /// Rebuilds the archive plan from whole selected assets. Scope is explicit:
    /// issue IDs are never interpreted as file or Photos-library identifiers.
    /// Empty-file assets are permitted only for an explicitly blocked asset, so
    /// unreadable originals remain visible and cannot be silently skipped.
    public static func report(
        from source: DeviceScanReport,
        groups: [DevicePlaceGroup],
        selectedGroupIDs: Set<String>,
        selectedUnknownAssetIDs: Set<String>,
        livePhotoImportMode: LivePhotoImportMode = .complete
    ) throws -> DeviceScanReport {
        try source.request.validateBasics()
        guard source.livePhotoImportMode == .complete else {
            throw ArchiveError.invalid("切换实况照片导入方式需要完整的原始扫描结果，请重新扫描。")
        }
        var files: [String: DeviceMediaItem] = [:]
        for file in source.files {
            guard !file.id.isEmpty, files.updateValue(file, forKey: file.id) == nil else {
                throw ArchiveError.invalid("设备素材清单包含重复或缺失的文件标识，请重新扫描。")
            }
        }

        var groupIDs = Set<String>()
        var knownGroupIDs = Set<String>()
        var assetIDs = Set<String>()
        var unknownAssetIDs = Set<String>()
        var selectedAssetIDs = Set<String>()
        var fileOwners: [String: String] = [:]
        var selectedFileIDs = Set<String>()
        var unknownGroupCount = 0

        for group in groups {
            guard !group.id.isEmpty, !group.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  groupIDs.insert(group.id).inserted, !group.assets.isEmpty else {
                throw ArchiveError.invalid("地点列表不完整或重复，请重新扫描。")
            }
            if group.isUnknown { unknownGroupCount += 1 } else { knownGroupIDs.insert(group.id) }
            for asset in group.assets {
                guard !asset.id.isEmpty, !asset.name.isEmpty, assetIDs.insert(asset.id).inserted,
                      asset.kind == .photo || asset.kind == .video,
                      CaptureDay(year: asset.captureDay.year, month: asset.captureDay.month, day: asset.captureDay.day) == asset.captureDay,
                      source.request.start <= asset.captureDay, asset.captureDay <= source.request.end,
                      group.isUnknown || asset.coordinate != nil else {
                    throw ArchiveError.invalid("地点素材的标识、类型、日期或位置信息不一致，请重新扫描。")
                }
                if group.isUnknown { unknownAssetIDs.insert(asset.id) }
                let selected = group.isUnknown ? selectedUnknownAssetIDs.contains(asset.id) : selectedGroupIDs.contains(group.id)
                if selected { selectedAssetIDs.insert(asset.id) }

                if asset.fileIDs.isEmpty {
                    let hasBlockingIssue = source.issues.contains { issue in
                        guard issue.isBlocking, !issue.isFilenameCollision, case .assets(let ids) = issue.scope else { return false }
                        return ids.contains(asset.id)
                    }
                    guard hasBlockingIssue else {
                        throw ArchiveError.invalid("素材没有对应文件且缺少原因说明，请重新扫描。")
                    }
                    continue
                }

                var hasPrimaryKind = false
                for id in asset.fileIDs {
                    guard let file = files[id], fileOwners.updateValue(asset.id, forKey: id) == nil else {
                        throw ArchiveError.invalid("地点素材对应的文件缺失或重复，请重新扫描。")
                    }
                    guard file.captureDay == nil || file.captureDay == asset.captureDay,
                          file.kind == .photo || file.kind == .video else {
                        throw ArchiveError.invalid("地点素材与原始文件的日期或类型不一致，请重新扫描。")
                    }
                    hasPrimaryKind = hasPrimaryKind || file.kind == asset.kind
                    if selected { selectedFileIDs.insert(id) }
                }
                guard hasPrimaryKind else {
                    throw ArchiveError.invalid("地点素材缺少对应类型的原始文件，请重新扫描。")
                }
                let componentIDs = Set(asset.fileIDs)
                let components = asset.fileIDs.compactMap { files[$0] }
                guard components.count == 1 || (components.count == 2 && asset.kind == .photo &&
                      components.filter { $0.kind == .photo }.count == 1 &&
                      components.filter { $0.kind == .video }.count == 1),
                      components.allSatisfy({ file in
                          let expected = componentIDs.subtracting([file.id])
                          return Set(file.companionIDs) == expected && file.companionIDs.count == expected.count
                      }) else {
                    throw ArchiveError.invalid("实况照片的组件关联缺失或不一致，请重新扫描；不能按独立文件归档。")
                }
            }
        }

        guard unknownGroupCount <= 1,
              selectedGroupIDs.isSubset(of: knownGroupIDs), selectedUnknownAssetIDs.isSubset(of: unknownAssetIDs),
              Set(fileOwners.keys) == Set(files.keys) else {
            throw ArchiveError.invalid("地点选择与当前扫描结果不一致，请重新扫描。")
        }
        for file in source.files {
            for companion in file.companionIDs where companion != file.id {
                guard let owner = fileOwners[companion], owner == fileOwners[file.id] else {
                    throw ArchiveError.invalid("Live Photo 或关联素材不完整，不能拆分到不同地点或单独归档。")
                }
            }
        }

        let selected = source.files.filter { selectedFileIDs.contains($0.id) }
        // Validate and normalize dates using both original components before
        // omitting any bytes from the import. Mode changes always start here
        // from the retained complete scan, so switching back restores the pair.
        let complete = try DeviceMediaPlanner.scan(items: selected, request: source.request, deviceID: source.deviceID, deviceName: source.deviceName)
        let projected = complete.files.filter { livePhotoImportMode == .complete || $0.kind != .video || $0.companionIDs.isEmpty }
        let planned = try DeviceMediaPlanner.scan(items: projected, request: source.request, deviceID: source.deviceID,
                                                 deviceName: source.deviceName, livePhotoImportMode: livePhotoImportMode)
        let omittedIDs = selectedFileIDs.subtracting(complete.files.map(\.id)).union(Set(projected.map(\.id)).subtracting(planned.files.map(\.id)))
        let omissions: [DeviceScanIssue] = omittedIDs.isEmpty ? [] : [
            DeviceScanIssue(id: "selection:omitted-files", name: "所选素材", message: "部分选中素材未能形成完整归档清单，请查看问题说明并重新扫描。",
                            isBlocking: true, scope: .files(omittedIDs))
        ]
        let allFileIDs = Set(files.keys)
        let retained = source.issues.filter { issue in
            guard !issue.isFilenameCollision else { return false }
            switch issue.scope {
            case .global:
                return true
            case .files(let ids):
                // A malformed or unknown scope cannot suppress an error.
                return ids.isEmpty || !ids.isSubset(of: allFileIDs) || !ids.isDisjoint(with: selectedFileIDs)
            case .assets(let ids):
                return ids.isEmpty || !ids.isSubset(of: assetIDs) || !ids.isDisjoint(with: selectedAssetIDs)
            }
        }
        return DeviceScanReport(request: source.request, deviceID: source.deviceID, deviceName: source.deviceName,
                                files: planned.files, issues: mergedIssues(retained + complete.issues.filter { !$0.isFilenameCollision } + planned.issues + omissions),
                                outsideRangeCount: source.outsideRangeCount, ignoredCount: source.ignoredCount,
                                livePhotoImportMode: livePhotoImportMode)
    }

    private static func mergedIssues(_ issues: [DeviceScanIssue]) -> [DeviceScanIssue] {
        var merged: [String: DeviceScanIssue] = [:]
        for issue in issues {
            guard let previous = merged[issue.id] else { merged[issue.id] = issue; continue }
            merged[issue.id] = DeviceScanIssue(
                id: issue.id,
                name: previous.name == issue.name ? issue.name : "\(previous.name)、\(issue.name)",
                message: previous.message == issue.message ? issue.message : "\(previous.message)\n\(issue.message)",
                isBlocking: previous.isBlocking || issue.isBlocking,
                scope: previous.scope == issue.scope ? issue.scope : .global,
                isFilenameCollision: previous.isFilenameCollision && issue.isFilenameCollision
            )
        }
        return merged.values.sorted { $0.id < $1.id }
    }
}
