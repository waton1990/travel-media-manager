import Foundation
import ImageIO
import AVFoundation

public struct DeviceDateResolution: Equatable, Sendable {
    public let day: CaptureDay?
    public let basis: String
    public let warning: String?
    /// Distinguishes conflicting reliable dates from missing/unusable metadata.
    /// A companion's date may fill the latter, but must never erase a conflict.
    public let hasConflict: Bool

    public init(day: CaptureDay?, basis: String, warning: String?, hasConflict: Bool = false) {
        self.day = day
        self.basis = basis
        self.warning = warning
        self.hasConflict = hasConflict
    }
}

/// Resolves capture dates without reading or downloading device files.
///
/// Pass ICCameraItem.creationDate as `deviceDate`, never ICCameraFile.fileCreationDate
/// or modificationDate. The ImageCaptureCore SDK describes creationDate as usually
/// the EXIF creation date, while fileCreationDate is the actual filesystem date.
/// ImageCaptureCore does not promise a single metadata dictionary layout, so only
/// explicit ImageIO/QuickTime capture-date keys are accepted here. Unknown layouts
/// use the separately supplied device date, visibly marked as a fallback.
public enum DeviceCaptureDateResolver {
    public static func resolve(
        metadata: [String: Any]?,
        deviceDate: Date?,
        timeZone: TimeZone
    ) -> DeviceDateResolution {
        var evidence: [Evidence] = []
        var warnings: [String] = []
        let metadata = metadata ?? [:]
        let exifKey = kCGImagePropertyExifDictionary as String
        let originalKey = kCGImagePropertyExifDateTimeOriginal as String

        // ImageIO's canonical EXIF dictionary is also used for HEIC images.
        // Accept a flattened DateTimeOriginal only by its unambiguous EXIF key.
        if let value = metadata[exifKey] {
            if let exif = value as? [String: Any] {
                if let original = exif[originalKey] {
                    collect(original, kind: .exif, field: "\(exifKey)/\(originalKey)", evidence: &evidence, warnings: &warnings)
                }
            } else {
                warnings.append("EXIF 拍摄元数据结构无效，不能用于日期匹配。")
            }
        }
        if let original = metadata[originalKey] {
            collect(original, kind: .exif, field: originalKey, evidence: &evidence, warnings: &warnings)
        }

        // Read the explicit QuickTime capture-date tag, not generic CreationDate
        // or movie/track header timestamps that may denote file/container dates.
        for key in [AVMetadataKey.quickTimeMetadataKeyCreationDate.rawValue,
                    AVMetadataIdentifier.quickTimeMetadataCreationDate.rawValue] {
            if let value = metadata[key] {
                collect(value, kind: .video, field: key, evidence: &evidence, warnings: &warnings)
            }
        }

        if let preferred = evidence.first {
            guard evidence.allSatisfy({ $0.day == preferred.day }) else {
                let details = evidence.map { "\($0.field)：\($0.day)" }.joined(separator: "；")
                warnings.append("可靠拍摄元数据存在跨日冲突，未纳入本次归档（\(details)）。")
                // The lower-priority device date must never mask conflicting metadata.
                return DeviceDateResolution(day: nil, basis: "拍摄日期冲突", warning: warningText(warnings), hasConflict: true)
            }
            return DeviceDateResolution(day: preferred.day, basis: preferred.kind.basis, warning: warningText(warnings))
        }

        if let deviceDate {
            if let day = deviceDay(deviceDate, timeZone: timeZone) {
                warnings.append("未取得可用的拍摄元数据，已按设备报告日期及所选旅行时区匹配。")
                return DeviceDateResolution(
                    day: day,
                    basis: "设备报告日期（旅行时区：\(timeZone.identifier)）",
                    warning: warningText(warnings)
                )
            }
            warnings.append("设备报告日期无效，不能用于日期匹配。")
        }

        warnings.append("没有可用的拍摄日期，未纳入本次归档；不会使用文件创建或修改时间替代。")
        return DeviceDateResolution(day: nil, basis: "拍摄日期未知", warning: warningText(warnings))
    }

    private enum Kind {
        case exif, video

        var basis: String {
            switch self {
            case .exif: return "EXIF 原始拍摄日期"
            case .video: return "媒体拍摄日期（含时区）"
            }
        }

        func parse(_ value: String) -> CaptureDay? {
            switch self {
            case .exif: return CaptureDateParser.exifOriginal(value)
            case .video: return CaptureDateParser.zonedCreationDate(value)
            }
        }
    }

    private struct Evidence {
        let day: CaptureDay
        let kind: Kind
        let field: String
    }

    private static func collect(
        _ value: Any,
        kind: Kind,
        field: String,
        evidence: inout [Evidence],
        warnings: inout [String]
    ) {
        // Preserve the calendar day written by the camera. Converting this value
        // through Date/Mac timezone would shift captures around local midnight.
        guard let text = value as? String, let day = kind.parse(text) else {
            warnings.append(kind == .exif
                ? "EXIF 原始拍摄日期无效，不能用于日期匹配。"
                : "媒体拍摄日期无效或缺少明确时区，不能用于日期匹配。")
            return
        }
        evidence.append(Evidence(day: day, kind: kind, field: field))
    }

    private static func deviceDay(_ date: Date, timeZone: TimeZone) -> CaptureDay? {
        guard date.timeIntervalSinceReferenceDate.isFinite else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        guard let year = components.year, let month = components.month, let day = components.day else { return nil }
        return CaptureDay(year: year, month: month, day: day)
    }

    private static func warningText(_ warnings: [String]) -> String? {
        var seen = Set<String>()
        let unique = warnings.filter { seen.insert($0).inserted }
        return unique.isEmpty ? nil : unique.joined(separator: " ")
    }
}
