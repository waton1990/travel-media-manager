import Foundation
import Darwin

public enum ArchiveError: LocalizedError {
    case invalid(String)
    public var errorDescription: String? { if case .invalid(let text) = self { return text }; return nil }
}

public struct CaptureDay: Hashable, Comparable, Sendable, Codable, CustomStringConvertible {
    public let year: Int
    public let month: Int
    public let day: Int
    public init?(year: Int, month: Int, day: Int) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        guard (1900...2200).contains(year), let date = calendar.date(from: DateComponents(year: year, month: month, day: day)) else { return nil }
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        guard parts.year == year, parts.month == month, parts.day == day else { return nil }
        self.year = year; self.month = month; self.day = day
    }
    public init?(_ iso: String) {
        let p = iso.split(separator: "-")
        guard p.count == 3, let y = Int(p[0]), let m = Int(p[1]), let d = Int(p[2]) else { return nil }
        self.init(year: y, month: m, day: d)
    }
    public init(date: Date, calendar: Calendar = .current) {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        self.year = parts.year!; self.month = parts.month!; self.day = parts.day!
    }
    public var description: String { String(format: "%04d-%02d-%02d", year, month, day) }
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.description < rhs.description }
}

public enum MediaKind: String, Sendable, CaseIterable, Codable {
    case video, photo, audio
    public var label: String { switch self { case .video: return "视频"; case .photo: return "照片"; case .audio: return "音频" } }
}

public struct FileSnapshot: Equatable, Sendable {
    public let size: Int64
    public let device: Int64
    public let inode: UInt64
    public let modificationSeconds: Int64
    public let modificationNanoseconds: Int64
    public init(stat info: stat) {
        size = Int64(info.st_size); device = Int64(info.st_dev); inode = UInt64(info.st_ino)
        modificationSeconds = Int64(info.st_mtimespec.tv_sec); modificationNanoseconds = Int64(info.st_mtimespec.tv_nsec)
    }
    public static func read(_ url: URL) throws -> FileSnapshot {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { throw ArchiveError.invalid("无法读取文件：\(url.lastPathComponent)（\(String(cString: strerror(errno)))）") }
        guard (info.st_mode & S_IFMT) == S_IFREG else { throw ArchiveError.invalid("不是普通素材文件：\(url.lastPathComponent)") }
        return FileSnapshot(stat: info)
    }
}

public struct ArchiveRequest: Sendable {
    public let name: String
    public let start: CaptureDay
    public let end: CaptureDay
    public let source: URL
    public let destination: URL
    public init(name: String, start: CaptureDay, end: CaptureDay, source: URL, destination: URL) {
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.start = start; self.end = end; self.source = source; self.destination = destination
    }
    public var folderName: String { "\(start)_\(name)" }
    public var targetURL: URL { destination.appendingPathComponent(folderName, isDirectory: true) }
    public func validateBasics() throws {
        guard !name.isEmpty else { throw ArchiveError.invalid("请填写旅行名称。") }
        guard !name.contains("/"), !name.contains(":"), !name.contains("\\"), name != ".", name != "..", !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains), folderName.utf8.count <= 240 else {
            throw ArchiveError.invalid("旅行名称过长或包含不可用的字符，请使用简短名称，避开 /、\\、: 和换行。")
        }
        guard start <= end else { throw ArchiveError.invalid("结束日期不能早于开始日期。") }
    }
}

public struct MediaFile: Identifiable, Sendable {
    public var id: String { url.path }
    public let url: URL
    public let kind: MediaKind
    public let captureDay: CaptureDay
    public let dateBasis: String
    public let snapshot: FileSnapshot
    public var size: Int64 { snapshot.size }
    public init(url: URL, kind: MediaKind, captureDay: CaptureDay, dateBasis: String, snapshot: FileSnapshot) {
        self.url = url; self.kind = kind; self.captureDay = captureDay; self.dateBasis = dateBasis; self.snapshot = snapshot
    }
}

public struct ScanIssue: Identifiable, Sendable {
    public var id: String { url.path + message }
    public let url: URL
    public let message: String
    public let isBlocking: Bool
    public init(url: URL, message: String, isBlocking: Bool = false) { self.url = url; self.message = message; self.isBlocking = isBlocking }
}

public struct ScanProgress: Sendable {
    public let visitedFiles: Int
    public let currentFile: String
    public init(visitedFiles: Int, currentFile: String) { self.visitedFiles = visitedFiles; self.currentFile = currentFile }
}

public struct ScanReport: Sendable {
    public let request: ArchiveRequest
    public let files: [MediaFile]
    public let issues: [ScanIssue]
    public let outsideRangeCount: Int
    public let ignoredCount: Int
    public var totalBytes: Int64 { files.reduce(0) { $0 + $1.size } }
    public var canArchive: Bool { !files.isEmpty && !issues.contains(where: \.isBlocking) }
    public func count(_ kind: MediaKind) -> Int { files.filter { $0.kind == kind }.count }
    public init(request: ArchiveRequest, files: [MediaFile], issues: [ScanIssue], outsideRangeCount: Int, ignoredCount: Int) {
        self.request = request; self.files = files; self.issues = issues; self.outsideRangeCount = outsideRangeCount; self.ignoredCount = ignoredCount
    }
}

public struct ArchiveProgress: Sendable {
    public enum Stage: String, Sendable { case copying, verifying }
    public let stage: Stage
    public let currentFile: String
    public let completedFiles: Int
    /// Fully transferred files; only completedFiles have passed verification and been committed.
    public let copiedFiles: Int
    public let totalFiles: Int
    public let completedBytes: Int64
    public let totalBytes: Int64
    public var fraction: Double { totalBytes > 0 ? min(1, Double(completedBytes) / Double(totalBytes)) : 0 }
    public init(stage: Stage, currentFile: String, completedFiles: Int, totalFiles: Int, completedBytes: Int64, totalBytes: Int64, copiedFiles: Int? = nil) {
        self.stage = stage; self.currentFile = currentFile; self.completedFiles = completedFiles; self.totalFiles = totalFiles; self.completedBytes = completedBytes; self.totalBytes = totalBytes
        self.copiedFiles = copiedFiles ?? completedFiles
    }
}

public struct ArchiveResult: Sendable {
    public let targetURL: URL
    public let fileCount: Int
    public let totalBytes: Int64
    public init(targetURL: URL, fileCount: Int, totalBytes: Int64) { self.targetURL = targetURL; self.fileCount = fileCount; self.totalBytes = totalBytes }
}

public struct ArchiveFailure: LocalizedError {
    public let message: String
    public let completedFiles: Int
    public let targetURL: URL?
    public init(message: String, completedFiles: Int, targetURL: URL?) { self.message = message; self.completedFiles = completedFiles; self.targetURL = targetURL }
    public var errorDescription: String? { message }
}
