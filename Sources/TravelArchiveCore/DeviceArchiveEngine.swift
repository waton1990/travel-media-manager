import Foundation
import Darwin
import CryptoKit

public enum DeviceArchiveEngine {
    private static let chunkSize = 1_048_576
    private static let spaceMargin: Int64 = 10 * 1_048_576

    /// Performs only read-only checks. No folder is created until archive starts.
    public static func validateDestination(for request: DeviceArchiveRequest, requiredBytes: Int64 = 0) throws {
        try request.validateBasics()
        guard requiredBytes >= 0, requiredBytes <= Int64.max - spaceMargin else { throw ArchiveError.invalid("素材大小无效或过大。") }
        let destination = try PathPolicy.canonicalDirectory(request.destination)
        let fd = try PathPolicy.openDirectory(destination)
        defer { close(fd) }
        try requireAbsent(request.folderName, in: fd)
        guard faccessat(fd, ".", W_OK | X_OK, 0) == 0 else { throw ArchiveError.invalid("保存位置不可写，请选择其他文件夹。") }
        let values = try destination.resourceValues(forKeys: [.volumeIsReadOnlyKey, .volumeAvailableCapacityKey, .volumeAvailableCapacityForImportantUsageKey])
        guard values.volumeIsReadOnly != true else { throw ArchiveError.invalid("保存位置是只读存储。") }
        let available = values.volumeAvailableCapacity.map(Int64.init) ?? values.volumeAvailableCapacityForImportantUsage
        guard let available, available >= 0 else { throw ArchiveError.invalid("无法确认保存位置的可用空间，请重新连接或更换保存位置。") }
        guard available >= requiredBytes + spaceMargin else { throw ArchiveError.invalid("保存位置空间不足，需要容纳全部素材并保留至少 10 MB 余量。") }
    }

    /// Preparation fixes the selected catalog entries before this operation.
    /// The provider validates those originals once before copying and once after
    /// all transfers; later catalog classification updates do not change the plan.
    /// Every `read` must check its current original and USB session. Short chunks
    /// are allowed; an empty chunk before the planned size is a transfer failure.
    public static func archive(
        report: DeviceScanReport,
        read: @escaping @Sendable (DeviceMediaItem, Int64, Int) async throws -> Data,
        validate: @escaping @Sendable () async throws -> Void,
        verifyLivePhoto: (@Sendable (URL, URL) async throws -> Void)? = nil,
        progress: @escaping @Sendable (ArchiveProgress) -> Void = { _ in }
    ) async throws -> ArchiveResult {
        var completedFiles = 0
        var targetURL: URL?
        var currentFile = ""
        do {
            try Task.checkCancellation()
            guard report.canArchive else { throw ArchiveError.invalid("没有可归档的照片或视频，或预览中仍有未解决的问题。") }
            let checked = try DeviceMediaPlanner.scan(items: report.files, request: report.request, deviceID: report.deviceID,
                                                     deviceName: report.deviceName, livePhotoImportMode: report.livePhotoImportMode)
            guard checked.canArchive, checked.files.count == report.files.count,
                  report.files.allSatisfy({ $0.captureDay != nil }) else { throw ArchiveError.invalid("归档清单无效或关联素材不完整，请重新扫描。") }
            let groups = try archiveGroups(checked.files, mode: report.livePhotoImportMode)
            let total = checked.totalBytes
            try validateDestination(for: report.request, requiredBytes: total)
            let destination = try PathPolicy.canonicalDirectory(report.request.destination)
            let destinationFD = try PathPolicy.openDirectory(destination)
            defer { close(destinationFD) }
            try PathPolicy.confirmDirectory(report.request.destination, fd: destinationFD)
            try await validate()
            try Task.checkCancellation()
            try PathPolicy.confirmDirectory(report.request.destination, fd: destinationFD)
            guard mkdirat(destinationFD, report.request.folderName, mode_t(0o700)) == 0 else {
                if errno == EEXIST { throw ArchiveError.invalid("旅行文件夹已存在，请修改旅行名称或保存位置。") }
                throw PathPolicy.systemError("无法创建旅行文件夹")
            }
            targetURL = report.request.targetURL
            let targetFD = openat(destinationFD, report.request.folderName, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard targetFD >= 0 else { throw PathPolicy.systemError("无法打开新建的旅行文件夹") }
            defer { close(targetFD) }
            // Copied files are not yet successful archive files. Keep only
            // metadata/digests between phases, so large trips do not keep an
            // open descriptor for every file. Cleanup never removes replacements.
            var pending: [CopiedFile] = []
            defer {
                for entry in pending {
                    // There is no pinned descriptor for this entry. A changed
                    // snapshot may belong to a replacement, so leave it alone.
                    removeOwned(name: entry.temporaryName, snapshot: entry.snapshot, targetFD: targetFD,
                                requireUnchangedSnapshot: true)
                }
            }
            var copiedGroups: [[CopiedFile]] = []
            var completedWork: Int64 = 0
            var copiedFiles = 0
            for group in groups {
                var copiedGroup: [CopiedFile] = []
                for file in group {
                    currentFile = file.name
                    try Task.checkCancellation()
                    try PathPolicy.confirmDirectory(report.request.destination, fd: destinationFD)
                    try confirmTarget(report.request.folderName, parent: destinationFD, target: targetFD)
                    let entry = try await copyOne(file, request: report.request, parentFD: destinationFD, targetFD: targetFD,
                                                  copiedFiles: copiedFiles, totalFiles: checked.files.count,
                                                  completedWork: completedWork, totalWork: total * 2,
                                                  read: read, progress: progress)
                    pending.append(entry)
                    copiedGroup.append(entry)
                    copiedFiles += 1
                    completedWork += file.size
                    progress(ArchiveProgress(stage: .copying, currentFile: currentFile, completedFiles: 0,
                                             totalFiles: checked.files.count, completedBytes: completedWork,
                                             totalBytes: total * 2, copiedFiles: copiedFiles))
                }
                copiedGroups.append(copiedGroup)
            }
            // This is the last device-wide originals check. It does not reopen
            // the Photos indexes, and no local verification starts before it.
            currentFile = ""
            progress(ArchiveProgress(stage: .verifying, currentFile: "复制完成，正在核对原件状态…", completedFiles: 0,
                                     totalFiles: checked.files.count, completedBytes: completedWork,
                                     totalBytes: total * 2, copiedFiles: copiedFiles))
            try Task.checkCancellation()
            try await validate()
            try Task.checkCancellation()
            for group in copiedGroups {
                var staged: [StagedFile] = []
                var committed = false
                defer {
                    for entry in staged {
                        if !committed { removeOwned(entry, name: entry.temporaryName, targetFD: targetFD) }
                        close(entry.fd)
                    }
                }
                for entry in group {
                    currentFile = entry.file.name
                    try Task.checkCancellation()
                    let verified = try verifyOne(entry, request: report.request, parentFD: destinationFD, targetFD: targetFD,
                                                 completedFiles: completedFiles, totalFiles: checked.files.count,
                                                 completedWork: completedWork, totalWork: total * 2, progress: progress)
                    staged.append(verified)
                    completedWork += entry.file.size
                }
                currentFile = group.map(\.file.name).joined(separator: "、")
                try confirmStaged(staged, request: report.request, parentFD: destinationFD, targetFD: targetFD)
                if group.count == 2 {
                    let photo = staged.first { $0.file.kind == .photo }!
                    let video = staged.first { $0.file.kind == .video }!
                    let photoURL = report.request.targetURL.appendingPathComponent(photo.temporaryName)
                    let videoURL = report.request.targetURL.appendingPathComponent(video.temporaryName)
                    if let verifyLivePhoto {
                        try await verifyLivePhoto(photoURL, videoURL)
                    } else {
                        try await LivePhotoPairVerifier.verify(photoURL: photoURL, videoURL: videoURL)
                    }
                }
                try Task.checkCancellation()
                try confirmStaged(staged, request: report.request, parentFD: destinationFD, targetFD: targetFD)
                try commitStaged(staged, request: report.request, parentFD: destinationFD, targetFD: targetFD)
                committed = true
                completedFiles += group.count
                progress(ArchiveProgress(stage: .verifying, currentFile: currentFile, completedFiles: completedFiles,
                                         totalFiles: checked.files.count, completedBytes: completedWork,
                                         totalBytes: total * 2, copiedFiles: copiedFiles))
            }
            try PathPolicy.confirmDirectory(report.request.destination, fd: destinationFD)
            try confirmTarget(report.request.folderName, parent: destinationFD, target: targetFD)
            return ArchiveResult(targetURL: report.request.targetURL, fileCount: completedFiles, totalBytes: total)
        } catch {
            let reason = error is CancellationError ? "归档已取消。" : error.localizedDescription
            throw ArchiveFailure(message: currentFile.isEmpty ? reason : "\(reason)\n当时处理的素材：\(currentFile)", completedFiles: completedFiles, targetURL: targetURL)
        }
    }

    private struct CopiedFile {
        let file: DeviceMediaItem
        let temporaryName: String
        let snapshot: FileSnapshot
        let digest: SHA256.Digest
    }

    struct StagedFile {
        let file: DeviceMediaItem
        let temporaryName: String
        let fd: Int32
        let snapshot: FileSnapshot
    }

    /// The hook is internal and exists for deterministic filesystem fault tests.
    /// Production always uses the default and the actual exclusive renames.
    static func commitStaged(_ staged: [StagedFile], request: DeviceArchiveRequest, parentFD: Int32, targetFD: Int32,
                             afterRename: (Int) throws -> Void = { _ in }) throws {
        var renamed: [StagedFile] = []
        var complete = false
        defer {
            if !complete {
                for entry in renamed { removeOwned(entry, name: entry.file.name, targetFD: targetFD) }
            }
        }
        for entry in staged { try requireAbsent(entry.file.name, in: targetFD) }
        // Two renames are not atomic; roll back only the inodes we created if
        // the second rename, cancellation, or a final identity check fails.
        for entry in staged {
            try Task.checkCancellation()
            try PathPolicy.confirmDirectory(request.destination, fd: parentFD)
            try confirmTarget(request.folderName, parent: parentFD, target: targetFD)
            try confirmFile(entry, name: entry.temporaryName, targetFD: targetFD)
            guard renameatx_np(targetFD, entry.temporaryName, targetFD, entry.file.name, UInt32(RENAME_EXCL)) == 0 else {
                throw PathPolicy.systemError("无法完成归档（目标可能已存在）：\(entry.file.name)")
            }
            renamed.append(entry)
            try afterRename(renamed.count)
        }
        try Task.checkCancellation()
        try PathPolicy.confirmDirectory(request.destination, fd: parentFD)
        try confirmTarget(request.folderName, parent: parentFD, target: targetFD)
        for entry in staged { try confirmFile(entry, name: entry.file.name, targetFD: targetFD) }
        complete = true
    }

    private static func archiveGroups(_ files: [DeviceMediaItem], mode: LivePhotoImportMode) throws -> [[DeviceMediaItem]] {
        let byID = Dictionary(uniqueKeysWithValues: files.map { ($0.id, $0) })
        let allIDs = Set(byID.keys)
        if mode == .stillOnly {
            guard files.allSatisfy({ DeviceMediaPlanner.hasValidComposition([$0], mode: mode, allIDs: allIDs) }) else {
                throw ArchiveError.invalid("仅静态照片归档清单包含无效关联或配套视频，请重新扫描。")
            }
            return files.map { [$0] }
        }
        var links: [String: Set<String>] = [:]
        for file in files {
            for companion in file.companionIDs {
                guard companion != file.id, byID[companion] != nil else {
                    throw ArchiveError.invalid("实况素材关联标识无效，请重新扫描。")
                }
                links[file.id, default: []].insert(companion)
                links[companion, default: []].insert(file.id)
            }
        }
        var visited = Set<String>()
        var result: [[DeviceMediaItem]] = []
        for file in files where !visited.contains(file.id) {
            var pending = [file.id], ids = Set<String>()
            while let id = pending.popLast() {
                guard ids.insert(id).inserted else { continue }
                pending.append(contentsOf: links[id, default: []])
            }
            let group = ids.compactMap { byID[$0] }.sorted { ($0.captureDay!, $0.name, $0.id) < ($1.captureDay!, $1.name, $1.id) }
            guard DeviceMediaPlanner.hasValidComposition(group, mode: mode, allIDs: allIDs) else {
                throw ArchiveError.invalid("关联素材的组成暂不支持，无法安全验证完整实况照片。")
            }
            result.append(group)
            visited.formUnion(ids)
        }
        return result
    }

    private static func removeOwned(_ entry: StagedFile, name: String, targetFD: Int32) {
        removeOwned(name: name, snapshot: entry.snapshot, targetFD: targetFD)
    }

    private static func removeOwned(name: String, snapshot: FileSnapshot, targetFD: Int32,
                                    requireUnchangedSnapshot: Bool = false) {
        var current = stat()
        if fstatat(targetFD, name, &current, AT_SYMLINK_NOFOLLOW) == 0,
           (current.st_mode & S_IFMT) == S_IFREG,
           Int64(current.st_dev) == snapshot.device, UInt64(current.st_ino) == snapshot.inode,
           !requireUnchangedSnapshot || FileSnapshot(stat: current) == snapshot {
            _ = unlinkat(targetFD, name, 0)
        }
    }

    private static func confirmFile(_ entry: StagedFile, name: String, targetFD: Int32) throws {
        let current = try PathPolicy.snapshot(entry.fd, name: entry.file.name)
        var named = stat()
        guard current == entry.snapshot, current.size == entry.file.size,
              fstatat(targetFD, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
              (named.st_mode & S_IFMT) == S_IFREG, FileSnapshot(stat: named) == current else {
            throw ArchiveError.invalid("目标临时文件在归档期间发生变化：\(entry.file.name)")
        }
    }

    private static func confirmStaged(_ staged: [StagedFile], request: DeviceArchiveRequest, parentFD: Int32, targetFD: Int32) throws {
        try PathPolicy.confirmDirectory(request.destination, fd: parentFD)
        try confirmTarget(request.folderName, parent: parentFD, target: targetFD)
        for entry in staged { try confirmFile(entry, name: entry.temporaryName, targetFD: targetFD) }
    }

    private static func copyOne(
        _ file: DeviceMediaItem, request: DeviceArchiveRequest, parentFD: Int32, targetFD: Int32,
        copiedFiles: Int, totalFiles: Int, completedWork: Int64, totalWork: Int64,
        read: @escaping @Sendable (DeviceMediaItem, Int64, Int) async throws -> Data,
        progress: @escaping @Sendable (ArchiveProgress) -> Void
    ) async throws -> CopiedFile {
        let temporaryName = ".travelarchive-\(UUID().uuidString).partial.\((file.name as NSString).pathExtension)"
        let output = openat(targetFD, temporaryName, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard output >= 0 else { throw PathPolicy.systemError("无法创建临时文件：\(file.name)") }
        let created = try? PathPolicy.snapshot(output, name: file.name)
        var transferred = false
        defer {
            if !transferred, let created {
                removeOwned(name: temporaryName, snapshot: created, targetFD: targetFD)
            }
            close(output)
        }
        func update(_ work: Int64) {
            progress(ArchiveProgress(stage: .copying, currentFile: file.name, completedFiles: 0,
                                     totalFiles: totalFiles, completedBytes: completedWork + work,
                                     totalBytes: totalWork, copiedFiles: copiedFiles))
        }
        var sourceHash = SHA256()
        var copied: Int64 = 0
        update(0)
        while copied < file.size {
            try Task.checkCancellation()
            let amount = Int(min(Int64(chunkSize), file.size - copied))
            let data = try await read(file, copied, amount)
            try Task.checkCancellation()
            guard !data.isEmpty else { throw ArchiveError.invalid("iPhone 返回的素材数据不完整：\(file.name)，请重新扫描后重试。") }
            guard data.count <= amount else { throw ArchiveError.invalid("iPhone 返回的素材大小发生变化：\(file.name)。") }
            try confirmTarget(request.folderName, parent: parentFD, target: targetFD)
            sourceHash.update(data: data)
            try data.withUnsafeBytes { raw in
                var offset = 0
                while offset < raw.count {
                    try Task.checkCancellation()
                    let written = Darwin.write(output, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                    if written < 0 && errno == EINTR { continue }
                    guard written > 0 else { throw PathPolicy.systemError("写入失败：\(file.name)") }
                    offset += written
                }
            }
            copied += Int64(data.count)
            update(copied)
        }
        try Task.checkCancellation()
        guard fsync(output) == 0 else { throw PathPolicy.systemError("保存文件失败：\(file.name)") }
        let copiedSnapshot = try PathPolicy.snapshot(output, name: file.name)
        let entry = StagedFile(file: file, temporaryName: temporaryName, fd: output, snapshot: copiedSnapshot)
        try confirmStaged([entry], request: request, parentFD: parentFD, targetFD: targetFD)
        transferred = true
        return CopiedFile(file: file, temporaryName: temporaryName, snapshot: copiedSnapshot, digest: sourceHash.finalize())
    }

    private static func verifyOne(
        _ copied: CopiedFile, request: DeviceArchiveRequest, parentFD: Int32, targetFD: Int32,
        completedFiles: Int, totalFiles: Int, completedWork: Int64, totalWork: Int64,
        progress: @escaping @Sendable (ArchiveProgress) -> Void
    ) throws -> StagedFile {
        let file = copied.file
        let input = openat(targetFD, copied.temporaryName, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard input >= 0 else { throw PathPolicy.systemError("无法打开待校验文件：\(file.name)") }
        var transferred = false
        var ownershipConfirmed = false
        let entry = StagedFile(file: file, temporaryName: copied.temporaryName, fd: input, snapshot: copied.snapshot)
        defer {
            if !transferred {
                if ownershipConfirmed { removeOwned(entry, name: entry.temporaryName, targetFD: targetFD) }
                close(input)
            }
        }
        try confirmStaged([entry], request: request, parentFD: parentFD, targetFD: targetFD)
        ownershipConfirmed = true
        func update(_ work: Int64) {
            progress(ArchiveProgress(stage: .verifying, currentFile: file.name, completedFiles: completedFiles,
                                     totalFiles: totalFiles, completedBytes: completedWork + work,
                                     totalBytes: totalWork, copiedFiles: totalFiles))
        }
        var buffer = [UInt8](repeating: 0, count: chunkSize)
        var targetHash = SHA256()
        var verified: Int64 = 0
        update(0)
        while true {
            try Task.checkCancellation()
            let count = buffer.withUnsafeMutableBytes { Darwin.read(input, $0.baseAddress!, $0.count) }
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw PathPolicy.systemError("无法读取目标校验数据：\(file.name)") }
            if count == 0 { break }
            guard verified <= file.size, Int64(count) <= file.size - verified else { throw ArchiveError.invalid("目标文件在校验时发生变化：\(file.name)") }
            targetHash.update(data: Data(buffer[0..<count]))
            verified += Int64(count)
            update(verified)
        }
        guard verified == file.size, copied.digest == targetHash.finalize() else { throw ArchiveError.invalid("复制结果校验失败：\(file.name)，未将残缺文件计为成功。") }
        try Task.checkCancellation()
        try confirmStaged([entry], request: request, parentFD: parentFD, targetFD: targetFD)
        transferred = true
        return entry
    }

    private static func requireAbsent(_ name: String, in directory: Int32) throws {
        var info = stat()
        if fstatat(directory, name, &info, AT_SYMLINK_NOFOLLOW) == 0 { throw ArchiveError.invalid("旅行文件夹已存在，请修改旅行名称或保存位置。") }
        guard errno == ENOENT else { throw PathPolicy.systemError("无法检查旅行文件夹") }
    }

    private static func confirmTarget(_ name: String, parent: Int32, target: Int32) throws {
        var info = stat()
        let identity = try PathPolicy.directoryIdentity(target)
        guard fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0, (info.st_mode & S_IFMT) == S_IFDIR,
              Int64(info.st_dev) == identity.device, UInt64(info.st_ino) == identity.inode else {
            throw ArchiveError.invalid("旅行文件夹在归档期间发生变化，已停止复制。")
        }
    }
}
