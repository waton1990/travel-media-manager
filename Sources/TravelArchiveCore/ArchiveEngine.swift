import Foundation
import Darwin
import CryptoKit

public enum ArchiveEngine {
    private static let bufferSize = 1_048_576
    private static let spaceMargin: Int64 = 10 * 1_048_576
    private static let supported: [String: MediaKind] = [
        "mp4": .video, "mov": .video, "m4v": .video,
        "jpg": .photo, "jpeg": .photo, "heic": .photo, "dng": .photo,
        "png": .photo, "tif": .photo, "tiff": .photo,
        "aac": .audio, "m4a": .audio, "wav": .audio, "mp3": .audio, "aiff": .audio
    ]

    /// Read-only preflight. This never creates a directory or a test file.
    public static func validateDestination(for request: ArchiveRequest, requiredBytes: Int64 = 0) throws {
        try request.validateBasics()
        guard requiredBytes >= 0, requiredBytes <= Int64.max - spaceMargin else {
            throw ArchiveError.invalid("素材大小无效或过大。")
        }
        let source = try PathPolicy.canonicalDirectory(request.source)
        let destination = try PathPolicy.canonicalDirectory(request.destination)
        let sourceFD = try PathPolicy.openDirectory(source)
        defer { close(sourceFD) }
        let destinationFD = try PathPolicy.openDirectory(destination)
        defer { close(destinationFD) }
        try validateLocations(request, source: source, destination: destination, sourceFD: sourceFD, destinationFD: destinationFD)
        try requireAbsent(request.folderName, in: destinationFD)
        guard faccessat(destinationFD, ".", W_OK | X_OK, 0) == 0 else {
            throw ArchiveError.invalid("保存位置不可写，请选择其他文件夹。")
        }
        let values = try destination.resourceValues(forKeys: [.volumeIsReadOnlyKey, .volumeAvailableCapacityKey, .volumeAvailableCapacityForImportantUsageKey])
        guard values.volumeIsReadOnly != true else { throw ArchiveError.invalid("保存位置是只读存储。") }
        // Prefer immediately available space. Important-usage capacity may also
        // include purgeable storage, so only use it when the ordinary value is absent.
        let available = values.volumeAvailableCapacity.map(Int64.init) ?? values.volumeAvailableCapacityForImportantUsage
        guard let available, available >= 0 else {
            throw ArchiveError.invalid("无法确认保存位置的可用空间，请重新连接存储或更换位置。")
        }
        guard available >= requiredBytes + spaceMargin else {
            throw ArchiveError.invalid("保存位置空间不足，需要容纳全部素材并保留至少 10 MB 余量。")
        }
    }

    /// Call from a background task. Cancellation preserves verified files and
    /// removes only the incomplete temporary file made by this invocation.
    public static func archive(report: ScanReport, progress: @escaping @Sendable (ArchiveProgress) -> Void = { _ in }) async throws -> ArchiveResult {
        var completedFiles = 0
        var createdTarget: URL?
        var currentFile = ""
        do {
            try Task.checkCancellation()
            guard report.canArchive else { throw ArchiveError.invalid("没有可归档的素材，或扫描中仍有未解决的问题。") }
            let request = report.request
            let total = try validatedTotal(report.files)
            guard total <= Int64.max / 2 else { throw ArchiveError.invalid("素材大小超过单次归档限制。") }
            try validateDestination(for: request, requiredBytes: total)
            let source = try PathPolicy.canonicalDirectory(request.source)
            let destination = try PathPolicy.canonicalDirectory(request.destination)
            let sourceFD = try PathPolicy.openDirectory(source)
            defer { close(sourceFD) }
            let destinationFD = try PathPolicy.openDirectory(destination)
            defer { close(destinationFD) }
            try validateLocations(request, source: source, destination: destination, sourceFD: sourceFD, destinationFD: destinationFD)
            var names = Set<String>()
            var relativePaths: [[String]] = []
            for file in report.files {
                try Task.checkCancellation()
                currentFile = file.url.lastPathComponent
                guard supported[file.url.pathExtension.lowercased()] == file.kind else {
                    throw ArchiveError.invalid("不支持的素材类型：\(currentFile)；LRF 不参与归档。")
                }
                guard file.captureDay >= request.start, file.captureDay <= request.end else {
                    throw ArchiveError.invalid("素材日期不在旅行范围内：\(currentFile)")
                }
                let key = currentFile.precomposedStringWithCanonicalMapping.lowercased(with: Locale(identifier: "en_US_POSIX"))
                guard names.insert(key).inserted else { throw ArchiveError.invalid("存在重名素材：\(currentFile)，请调整素材来源。") }
                let relative = try PathPolicy.relativeComponents(file: file.url, source: request.source)
                let fd = try PathPolicy.openSource(relative, in: sourceFD)
                defer { close(fd) }
                try requireSnapshot(file.snapshot, fd: fd, name: currentFile)
                relativePaths.append(relative)
            }
            try PathPolicy.confirmDirectory(request.source, fd: sourceFD)
            try PathPolicy.confirmDirectory(request.destination, fd: destinationFD)
            try Task.checkCancellation()
            // mkdirat is atomic: even if something appeared after preflight, it
            // cannot overwrite or merge into an existing destination.
            guard mkdirat(destinationFD, request.folderName, mode_t(0o700)) == 0 else {
                if errno == EEXIST { throw ArchiveError.invalid("旅行文件夹已存在，请修改旅行名称或保存位置。") }
                throw PathPolicy.systemError("无法创建旅行文件夹")
            }
            createdTarget = request.targetURL
            let targetFD = openat(destinationFD, request.folderName, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard targetFD >= 0 else { throw PathPolicy.systemError("无法打开新建的旅行文件夹") }
            defer { close(targetFD) }
            var completedWork: Int64 = 0
            for (file, relative) in zip(report.files, relativePaths) {
                currentFile = file.url.lastPathComponent
                try Task.checkCancellation()
                try PathPolicy.confirmDirectory(request.source, fd: sourceFD)
                try PathPolicy.confirmDirectory(request.destination, fd: destinationFD)
                try confirmTarget(request.folderName, parent: destinationFD, target: targetFD)
                try copyOne(file, relative: relative, sourceFD: sourceFD, targetFD: targetFD,
                            completedFiles: completedFiles, totalFiles: report.files.count,
                            completedWork: completedWork, totalWork: total * 2, progress: progress)
                completedFiles += 1
                completedWork += file.size * 2
                progress(ArchiveProgress(stage: .verifying, currentFile: currentFile, completedFiles: completedFiles,
                                         totalFiles: report.files.count, completedBytes: completedWork, totalBytes: total * 2))
            }
            try PathPolicy.confirmDirectory(request.destination, fd: destinationFD)
            try confirmTarget(request.folderName, parent: destinationFD, target: targetFD)
            return ArchiveResult(targetURL: request.targetURL, fileCount: completedFiles, totalBytes: total)
        } catch {
            let reason = error is CancellationError ? "归档已取消。" : error.localizedDescription
            let details = currentFile.isEmpty ? reason : "\(reason)\n涉及素材：\(currentFile)"
            throw ArchiveFailure(message: details, completedFiles: completedFiles, targetURL: createdTarget)
        }
    }

    private static func validatedTotal(_ files: [MediaFile]) throws -> Int64 {
        var total: Int64 = 0
        for file in files {
            guard file.size >= 0 else { throw ArchiveError.invalid("素材大小无效：\(file.url.lastPathComponent)") }
            let sum = total.addingReportingOverflow(file.size)
            guard !sum.overflow else { throw ArchiveError.invalid("素材总大小过大。") }
            total = sum.partialValue
        }
        return total
    }

    private static func validateLocations(_ request: ArchiveRequest, source: URL, destination: URL, sourceFD: Int32, destinationFD: Int32) throws {
        guard !PathPolicy.isWithin(destination, source), !PathPolicy.isWithin(destination.appendingPathComponent(request.folderName), source) else {
            throw ArchiveError.invalid("保存位置不能位于素材来源文件夹内，请选择相机存储之外的位置。")
        }
        let sourceID = try PathPolicy.directoryIdentity(sourceFD)
        let destinationID = try PathPolicy.directoryIdentity(destinationFD)
        let sourceVolume = try source.resourceValues(forKeys: [.volumeIsInternalKey, .volumeURLKey])
        if sourceID.device == destinationID.device {
            guard sourceVolume.volumeIsInternal == true else {
                throw ArchiveError.invalid("保存位置不能与相机或外置素材来源位于同一存储卷。")
            }
        }
        let destinationVolume = try destination.resourceValues(forKeys: [.volumeURLKey])
        if sourceVolume.volumeIsInternal != true,
           let sourceVolumeURL = sourceVolume.volume,
           let destinationVolumeURL = destinationVolume.volume,
           sourceVolumeURL.standardizedFileURL == destinationVolumeURL.standardizedFileURL {
            throw ArchiveError.invalid("保存位置不能与相机或外置素材来源位于同一存储卷。")
        }
    }

    private static func requireAbsent(_ name: String, in directory: Int32) throws {
        var info = stat()
        if fstatat(directory, name, &info, AT_SYMLINK_NOFOLLOW) == 0 {
            throw ArchiveError.invalid("旅行文件夹已存在，请修改旅行名称或保存位置。")
        }
        guard errno == ENOENT else { throw PathPolicy.systemError("无法检查旅行文件夹") }
    }

    private static func requireSnapshot(_ expected: FileSnapshot, fd: Int32, name: String) throws {
        guard try PathPolicy.snapshot(fd, name: name) == expected else {
            throw ArchiveError.invalid("素材在扫描后发生变化，请重新扫描：\(name)")
        }
    }

    private static func confirmTarget(_ name: String, parent: Int32, target: Int32) throws {
        var info = stat()
        let identity = try PathPolicy.directoryIdentity(target)
        guard fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0,
              (info.st_mode & S_IFMT) == S_IFDIR,
              Int64(info.st_dev) == identity.device, UInt64(info.st_ino) == identity.inode else {
            throw ArchiveError.invalid("旅行文件夹在归档期间发生变化，已停止复制。")
        }
    }

    private static func copyOne(_ file: MediaFile, relative: [String], sourceFD: Int32, targetFD: Int32,
                                completedFiles: Int, totalFiles: Int, completedWork: Int64, totalWork: Int64,
                                progress: @escaping @Sendable (ArchiveProgress) -> Void) throws {
        let name = file.url.lastPathComponent
        let source = try PathPolicy.openSource(relative, in: sourceFD)
        defer { close(source) }
        try requireSnapshot(file.snapshot, fd: source, name: name)
        let temporaryName = ".travelarchive-\(UUID().uuidString).partial"
        let output = openat(targetFD, temporaryName, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard output >= 0 else { throw PathPolicy.systemError("无法创建临时文件：\(name)") }
        let createdSnapshot = try? PathPolicy.snapshot(output, name: name)
        var committed = false
        defer {
            close(output)
            // Check inode before unlink so a replaced path is never cleaned up
            // as if it were a temporary file owned by this archive operation.
            if !committed, let createdSnapshot {
                var info = stat()
                if fstatat(targetFD, temporaryName, &info, AT_SYMLINK_NOFOLLOW) == 0,
                   Int64(info.st_dev) == createdSnapshot.device, UInt64(info.st_ino) == createdSnapshot.inode,
                   (info.st_mode & S_IFMT) == S_IFREG {
                    _ = unlinkat(targetFD, temporaryName, 0)
                }
            }
        }
        var sourceHash = SHA256()
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        var copied: Int64 = 0
        func update(_ stage: ArchiveProgress.Stage, work: Int64) {
            progress(ArchiveProgress(stage: stage, currentFile: name, completedFiles: completedFiles, totalFiles: totalFiles,
                                     completedBytes: completedWork + work, totalBytes: totalWork))
        }
        update(.copying, work: 0)
        while true {
            try Task.checkCancellation()
            let count = try readChunk(source, buffer: &buffer, name: name)
            if count == 0 { break }
            guard copied <= file.size, Int64(count) <= file.size - copied else {
                throw ArchiveError.invalid("素材在复制时变大，请重新扫描：\(name)")
            }
            sourceHash.update(data: Data(buffer[0..<count]))
            try buffer.withUnsafeBytes { raw in
                var offset = 0
                while offset < count {
                    try Task.checkCancellation()
                    let written = Darwin.write(output, raw.baseAddress!.advanced(by: offset), count - offset)
                    if written < 0 && errno == EINTR { continue }
                    guard written > 0 else { throw PathPolicy.systemError("写入失败：\(name)") }
                    offset += written
                }
            }
            copied += Int64(count)
            update(.copying, work: copied)
        }
        guard copied == file.size else { throw ArchiveError.invalid("素材在复制时变短，请重新扫描：\(name)") }
        try requireSnapshot(file.snapshot, fd: source, name: name)
        guard fsync(output) == 0 else { throw PathPolicy.systemError("保存文件失败：\(name)") }
        let copiedSnapshot = try PathPolicy.snapshot(output, name: name)
        guard lseek(output, 0, SEEK_SET) == 0 else { throw PathPolicy.systemError("无法开始校验：\(name)") }
        var targetHash = SHA256()
        var verified: Int64 = 0
        update(.verifying, work: copied)
        while true {
            try Task.checkCancellation()
            let count = try readChunk(output, buffer: &buffer, name: name)
            if count == 0 { break }
            guard verified <= file.size, Int64(count) <= file.size - verified else {
                throw ArchiveError.invalid("目标文件在校验时发生变化：\(name)")
            }
            targetHash.update(data: Data(buffer[0..<count]))
            verified += Int64(count)
            update(.verifying, work: copied + verified)
        }
        guard verified == file.size, sourceHash.finalize() == targetHash.finalize() else {
            throw ArchiveError.invalid("复制结果校验失败：\(name)，未将残缺文件计为成功。")
        }
        try requireSnapshot(file.snapshot, fd: source, name: name)
        // Also verify the pathname, so replacing/unlinking a source while its old
        // descriptor remains valid cannot produce a misleading success result.
        let finalSource = try PathPolicy.openSource(relative, in: sourceFD)
        defer { close(finalSource) }
        try requireSnapshot(file.snapshot, fd: finalSource, name: name)
        let outputSnapshot = try PathPolicy.snapshot(output, name: name)
        var temporaryStat = stat()
        guard outputSnapshot == copiedSnapshot, outputSnapshot.size == file.size,
              fstatat(targetFD, temporaryName, &temporaryStat, AT_SYMLINK_NOFOLLOW) == 0,
              (temporaryStat.st_mode & S_IFMT) == S_IFREG,
              FileSnapshot(stat: temporaryStat) == outputSnapshot else {
            throw ArchiveError.invalid("目标临时文件在归档期间发生变化：\(name)")
        }
        try Task.checkCancellation()
        guard renameatx_np(targetFD, temporaryName, targetFD, name, UInt32(RENAME_EXCL)) == 0 else {
            throw PathPolicy.systemError("无法完成归档（目标可能已存在）：\(name)")
        }
        committed = true
    }

    private static func readChunk(_ fd: Int32, buffer: inout [UInt8], name: String) throws -> Int {
        while true {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress!, $0.count) }
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw PathPolicy.systemError("读取失败：\(name)") }
            return count
        }
    }
}
