import Foundation
import AVFoundation
import ImageIO
import Darwin

/// Reads names and metadata only. It never changes the selected source folder.
public enum MediaScanner {
    public static let supportedExtensions: Set<String> = Set(extensionKinds.keys)

    private static let extensionKinds: [String: MediaKind] = [
        "mp4": .video, "mov": .video, "m4v": .video,
        "jpg": .photo, "jpeg": .photo, "heic": .photo, "dng": .photo,
        "png": .photo, "tif": .photo, "tiff": .photo,
        "aac": .audio, "m4a": .audio, "wav": .audio, "mp3": .audio, "aiff": .audio
    ]

    public static func scan(
        request: ArchiveRequest,
        progress: @escaping @Sendable (ScanProgress) -> Void = { _ in }
    ) async throws -> ScanReport {
        try request.validateBasics()
        try Task.checkCancellation()
        guard request.source.isFileURL else { throw ArchiveError.invalid("素材来源必须是本机文件夹。") }
        var rootStat = stat()
        guard lstat(request.source.path, &rootStat) == 0,
              (rootStat.st_mode & S_IFMT) == S_IFDIR else {
            throw ArchiveError.invalid("无法读取素材来源，请选择已连接设备上的真实文件夹。")
        }

        let manager = FileManager.default
        var issues: [ScanIssue] = []
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey, .isRegularFileKey]
        guard let enumerator = manager.enumerator(
            at: request.source,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { url, error in
                issues.append(ScanIssue(url: url, message: "无法完整读取目录：\(error.localizedDescription)", isBlocking: true))
                return false
            }
        ) else { throw ArchiveError.invalid("无法扫描素材来源目录。") }

        var candidates: [(URL, MediaKind)] = []
        var ignored = 0
        var visited = 0
        while let url = enumerator.nextObject() as? URL {
            try Task.checkCancellation()
            do {
                let values = try url.resourceValues(forKeys: Set(keys))
                if values.isSymbolicLink == true {
                    enumerator.skipDescendants()
                    ignored += 1
                    continue
                }
                if values.isDirectory == true {
                    if values.isPackage == true || ["MISC", "LOST+FOUND"].contains(url.lastPathComponent.uppercased()) {
                        enumerator.skipDescendants()
                    }
                    continue
                }
                visited += 1
                progress(ScanProgress(visitedFiles: visited, currentFile: url.lastPathComponent))
                guard let kind = extensionKinds[url.pathExtension.lowercased()] else {
                    ignored += 1
                    continue
                }
                guard values.isRegularFile == true else {
                    issues.append(ScanIssue(url: url, message: "候选素材不是普通文件，无法归档。", isBlocking: true))
                    continue
                }
                candidates.append((url, kind))
            } catch {
                enumerator.skipDescendants()
                issues.append(ScanIssue(url: url, message: "无法读取目录项目：\(error.localizedDescription)", isBlocking: true))
            }
        }

        var matched: [MediaFile] = []
        var outsideRange = 0
        for (url, kind) in candidates.sorted(by: { $0.0.path < $1.0.path }) {
            try Task.checkCancellation()
            progress(ScanProgress(visitedFiles: visited, currentFile: url.lastPathComponent))
            do {
                let snapshot = try FileSnapshot.read(url)
                try checkReadable(url, snapshot: snapshot)
                let filenameDate = CaptureDateParser.djiFilename(url.lastPathComponent)
                var evidence: [DateEvidence] = []
                switch filenameDate {
                case .valid(let day): evidence.append(DateEvidence(day: day, basis: "DJI 文件名日期"))
                case .invalid:
                    issues.append(ScanIssue(url: url, message: "DJI 文件名中的拍摄日期或时间无效，不能用于日期匹配。"))
                case .absent: break
                }

                do {
                    let metadata = try await captureMetadata(url: url, kind: kind)
                    evidence.append(contentsOf: metadata.evidence)
                    issues.append(contentsOf: metadata.warnings.map { ScanIssue(url: url, message: $0) })
                } catch is CancellationError { throw CancellationError() }
                catch {
                    // A valid DJI name remains usable when a codec or metadata reader is unavailable.
                    // Reading failure is visible; this does not claim the video/photo itself is playable.
                    issues.append(ScanIssue(url: url, message: "无法读取拍摄元数据：\(error.localizedDescription)"))
                }
                try Task.checkCancellation()
                guard try FileSnapshot.read(url) == snapshot else {
                    issues.append(ScanIssue(url: url, message: "扫描期间文件发生变化，请重新扫描。", isBlocking: true))
                    continue
                }
                guard let chosen = evidence.first else {
                    issues.append(ScanIssue(url: url, message: "没有可靠的拍摄日期，未纳入本次归档；不会使用文件修改时间代替。"))
                    continue
                }
                guard evidence.allSatisfy({ $0.day == chosen.day }) else {
                    let details = evidence.map { "\($0.basis)：\($0.day)" }.joined(separator: "；")
                    issues.append(ScanIssue(url: url, message: "拍摄日期存在跨日冲突，未纳入本次归档（\(details)）。"))
                    continue
                }
                guard request.start <= chosen.day && chosen.day <= request.end else {
                    outsideRange += 1
                    continue
                }
                matched.append(MediaFile(url: url, kind: kind, captureDay: chosen.day, dateBasis: chosen.basis, snapshot: snapshot))
            } catch is CancellationError { throw CancellationError() }
            catch {
                issues.append(ScanIssue(url: url, message: "无法读取素材：\(error.localizedDescription)", isBlocking: true))
            }
        }

        let names = Dictionary(grouping: matched, by: { collisionKey($0.url.lastPathComponent) })
        for group in names.values where group.count > 1 {
            for file in group {
                issues.append(ScanIssue(url: file.url, message: "日期范围内有重名素材“\(file.url.lastPathComponent)”，平铺到同一旅行文件夹会冲突，请调整来源后重试。", isBlocking: true))
            }
        }
        try Task.checkCancellation()
        return ScanReport(
            request: request,
            files: matched.sorted { $0.captureDay == $1.captureDay ? $0.url.path < $1.url.path : $0.captureDay < $1.captureDay },
            issues: issues.sorted { $0.url.path == $1.url.path ? $0.message < $1.message : $0.url.path < $1.url.path },
            outsideRangeCount: outsideRange,
            ignoredCount: ignored
        )
    }

    private static func collisionKey(_ name: String) -> String {
        name.precomposedStringWithCanonicalMapping.folding(options: [.caseInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }

    private static func checkReadable(_ url: URL, snapshot: FileSnapshot) throws {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw ArchiveError.invalid("无法打开文件（\(String(cString: strerror(errno)))）。") }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              FileSnapshot(stat: info) == snapshot else { throw ArchiveError.invalid("文件在扫描期间已变化，请重新扫描。") }
    }

    private struct DateEvidence {
        let day: CaptureDay
        let basis: String
    }

    private struct MetadataDates {
        var evidence: [DateEvidence] = []
        var warnings: [String] = []
    }

    private static func captureMetadata(url: URL, kind: MediaKind) async throws -> MetadataDates {
        try Task.checkCancellation()
        var result = MetadataDates()
        if kind == .photo {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] else {
                throw ArchiveError.invalid("无法解析照片的元数据。")
            }
            if let exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any],
               let original = exif[kCGImagePropertyExifDateTimeOriginal as String] as? String {
                if let day = CaptureDateParser.exifOriginal(original) {
                    result.evidence.append(DateEvidence(day: day, basis: "EXIF 原始拍摄日期"))
                } else {
                    result.warnings.append("照片 EXIF 原始拍摄日期格式无效，不能用于日期匹配。")
                }
            }
            return result
        }

        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: false])
        let formats = try await asset.load(.availableMetadataFormats)
        try Task.checkCancellation()
        // The QuickTime movie header date is UTC, but some cameras write local time into it.
        // Only the explicit user creation-date tag retains a trustworthy stated timezone.
        if formats.contains(.quickTimeMetadata) {
            let metadata = try await asset.loadMetadata(for: .quickTimeMetadata)
            for item in metadata where item.identifier == .quickTimeMetadataCreationDate {
                try Task.checkCancellation()
                if let value = try await item.load(.stringValue) {
                    if let day = CaptureDateParser.zonedCreationDate(value) {
                        result.evidence.append(DateEvidence(day: day, basis: "媒体拍摄日期（含时区）"))
                    } else {
                        result.warnings.append("媒体拍摄日期缺少明确时区或格式无效，不能用于日期匹配。")
                    }
                }
            }
        }
        return result
    }
}

/// Parse written camera calendar dates, without converting them into the Mac's current timezone.
enum CaptureDateParser {
    enum FilenameDate: Equatable { case absent, invalid, valid(CaptureDay) }

    static func djiFilename(_ name: String) -> FilenameDate {
        // Use the complete timestamp and DJI separators; do not extract date-looking substrings.
        guard let parts = groups(#"^DJI_([0-9]{4})([0-9]{2})([0-9]{2})([0-9]{2})([0-9]{2})([0-9]{2})_[^.]+\.[^.]+$"#, name) else { return .absent }
        guard let day = checkedDay(parts) else { return .invalid }
        return .valid(day)
    }

    static func exifOriginal(_ value: String) -> CaptureDay? {
        guard let parts = groups(#"^([0-9]{4}):([0-9]{2}):([0-9]{2}) ([0-9]{2}):([0-9]{2}):([0-9]{2})$"#, value) else { return nil }
        return checkedDay(parts)
    }

    static func zonedCreationDate(_ value: String) -> CaptureDay? {
        guard let parts = groups(#"^([0-9]{4})-([0-9]{2})-([0-9]{2})[T ]([0-9]{2}):([0-9]{2}):([0-9]{2})(?:\.[0-9]+)?(Z|[+-][0-9]{2}:?[0-9]{2})$"#, value),
              let day = checkedDay(parts) else { return nil }
        let zone = parts[6]
        if zone != "Z" {
            let digits = zone.dropFirst().replacingOccurrences(of: ":", with: "")
            guard let hours = Int(digits.prefix(2)), let minutes = Int(digits.suffix(2)),
                  hours <= 14, minutes < 60, hours < 14 || minutes == 0 else { return nil }
        }
        return day
    }

    private static func checkedDay(_ parts: [String]) -> CaptureDay? {
        guard parts.count >= 6, let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]),
              let hour = Int(parts[3]), let minute = Int(parts[4]), let second = Int(parts[5]),
              (0...23).contains(hour), (0...59).contains(minute), (0...59).contains(second) else { return nil }
        return CaptureDay(year: year, month: month, day: day)
    }

    private static func groups(_ pattern: String, _ value: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
              match.range.length == value.utf16.count else { return nil }
        return (1..<match.numberOfRanges).compactMap { index in
            guard let range = Range(match.range(at: index), in: value) else { return nil }
            return String(value[range])
        }
    }
}
