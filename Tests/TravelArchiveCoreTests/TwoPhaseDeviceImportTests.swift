import Darwin
import Foundation
import Testing
@testable import TravelArchiveCore

struct TwoPhaseDeviceImportTests {
    private final class Fixture: @unchecked Sendable {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TwoPhaseDeviceImportTests-\(UUID())", isDirectory: true)
        init() throws { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false) }
        deinit { try? FileManager.default.removeItem(at: root) }
        var request: DeviceArchiveRequest {
            DeviceArchiveRequest(name: "先复制后校验", start: CaptureDay("2026-10-13")!, end: CaptureDay("2026-10-15")!,
                                 destination: root, timeZoneIdentifier: "Asia/Shanghai")
        }
    }

    private func item(_ id: String, _ name: String, kind: MediaKind = .photo, companions: [String] = []) -> DeviceMediaItem {
        DeviceMediaItem(id: id, name: name, kind: kind, size: 5, captureDay: CaptureDay("2026-10-13")!,
                        dateBasis: "synthetic frozen selection", companionIDs: companions)
    }

    private func plan(_ f: Fixture, files: [DeviceMediaItem]) throws -> DeviceScanReport {
        try DeviceMediaPlanner.scan(items: files, request: f.request, deviceID: "synthetic-prepared-session", deviceName: "测试 iPhone")
    }

    @Test func allSelectedBytesArriveBeforeAnyLocalVerificationOrPublication() async throws {
        let f = try Fixture(), journal = TwoPhaseJournal()
        let files = [item("a", "a.JPG"), item("p", "b.HEIC", companions: ["v"]),
                     item("v", "b.MOV", kind: .video, companions: ["p"]), item("z", "z.MOV", kind: .video)]
        let report = try plan(f, files: files)
        let result = try await DeviceArchiveEngine.archive(report: report, read: { file, _, _ in
            journal.read(file.id)
            // Nothing can have a final name while USB transfer is still running.
            let current = try FileManager.default.contentsOfDirectory(atPath: f.request.targetURL.path)
            #expect(Set(current).isDisjoint(with: Set(files.map(\.name))))
            return Data(repeating: UInt8(file.id.utf8.first!), count: 5)
        }, validate: {
            _ = journal.validate()
        }, verifyLivePhoto: { _, _ in
            journal.pair()
            #expect(journal.snapshot().readIDs == Set(files.map(\.id)))
        }, progress: { journal.progress($0) })
        let state = journal.snapshot()
        #expect(result.fileCount == 4 && result.totalBytes == 20)
        #expect(state.validationReadCounts == [0, 4])
        let lastRead = try #require(state.events.lastIndex(where: { $0.hasPrefix("read:") }))
        let firstVerify = try #require(state.events.firstIndex(of: "verifying"))
        #expect(lastRead < firstVerify)
        #expect(state.events.filter { $0 == "pair" }.count == 1)
        let copying = state.progress.filter { $0.stage == .copying }
        let verifying = state.progress.filter { $0.stage == .verifying }
        #expect(!copying.isEmpty && !verifying.isEmpty)
        #expect(copying.allSatisfy { $0.completedFiles == 0 && $0.completedBytes <= 20 })
        #expect(verifying.allSatisfy { $0.copiedFiles == 4 && $0.completedBytes >= 20 })
        #expect(state.progress.allSatisfy { $0.totalFiles == 4 && $0.totalBytes == 40 && $0.completedFiles <= $0.copiedFiles })
        #expect(zip(state.progress, state.progress.dropFirst()).allSatisfy { $0.completedBytes <= $1.completedBytes })
        #expect(zip(state.progress, state.progress.dropFirst()).allSatisfy { $0.copiedFiles <= $1.copiedFiles })
        let final = try #require(state.progress.last)
        #expect(final.completedFiles == 4 && final.copiedFiles == 4 && final.completedBytes == 40)
        // The two Live Photo components publish together: 1 -> 3, never 2.
        #expect(!state.progress.contains { $0.completedFiles == 2 })
        for file in files {
            #expect(try Data(contentsOf: result.targetURL.appendingPathComponent(file.name)) == Data(repeating: UInt8(file.id.utf8.first!), count: 5))
        }
    }

    @Test func finalOriginalValidationFailureAfterWholeCopyPublishesNothing() async throws {
        let f = try Fixture(), journal = TwoPhaseJournal()
        let files = [item("a", "a.JPG"), item("b", "b.MOV", kind: .video), item("c", "c.JPG")]
        do {
            _ = try await DeviceArchiveEngine.archive(report: plan(f, files: files), read: { file, _, _ in
                journal.read(file.id)
                return Data(repeating: 1, count: 5)
            }, validate: {
                if journal.validate() == 2 { throw ArchiveError.invalid("所选原件已变化") }
            }, progress: { journal.progress($0) })
            Issue.record("A changed original at the end of transfer must prevent publication")
        } catch let failure as ArchiveFailure {
            #expect(failure.completedFiles == 0 && failure.message.contains("原件已变化"))
        }
        #expect(journal.snapshot().validationReadCounts == [0, 3])
        #expect(try FileManager.default.contentsOfDirectory(atPath: f.request.targetURL.path).isEmpty)
    }

    @Test func localHashDetectsChangedBytesEvenWhenIdentitySizeAndTimeMatch() async throws {
        let f = try Fixture(), journal = TwoPhaseJournal()
        let report = try plan(f, files: [item("a", "a.JPG")])
        do {
            _ = try await DeviceArchiveEngine.archive(report: report, read: { file, _, _ in
                journal.read(file.id)
                return Data(repeating: 1, count: 5)
            }, validate: {
                guard journal.validate() == 2 else { return }
                let urls = try FileManager.default.contentsOfDirectory(at: f.request.targetURL, includingPropertiesForKeys: nil)
                let staged = try #require(urls.only)
                let before = try FileSnapshot.read(staged)
                let fd = open(staged.path, O_WRONLY | O_NOFOLLOW | O_CLOEXEC)
                guard fd >= 0 else { throw ArchiveError.invalid("Cannot open synthetic staged file") }
                defer { close(fd) }
                var info = stat()
                #expect(fstat(fd, &info) == 0)
                let bytes = [UInt8](repeating: 9, count: 5)
                #expect(bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!, $0.count) } == 5)
                let times = [info.st_atimespec, info.st_mtimespec]
                #expect(times.withUnsafeBufferPointer { futimens(fd, $0.baseAddress!) } == 0)
                #expect(try FileSnapshot.read(staged) == before)
            })
            Issue.record("Matching file metadata must not bypass the final content hash")
        } catch let failure as ArchiveFailure {
            #expect(failure.completedFiles == 0 && failure.message.contains("校验失败"))
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: f.request.targetURL.path).isEmpty)
    }

    @Test func reopeningCopiedFileRejectsSymlinkAndPreservesForeignTarget() async throws {
        let f = try Fixture(), journal = TwoPhaseJournal()
        let foreign = f.root.appendingPathComponent("foreign.JPG")
        try Data([9, 8, 7, 6, 5]).write(to: foreign)
        do {
            _ = try await DeviceArchiveEngine.archive(report: plan(f, files: [item("a", "a.JPG")]), read: { file, _, _ in
                journal.read(file.id)
                return Data(repeating: 1, count: 5)
            }, validate: {
                guard journal.validate() == 2 else { return }
                let staged = try #require(try FileManager.default.contentsOfDirectory(at: f.request.targetURL, includingPropertiesForKeys: nil).only)
                try FileManager.default.removeItem(at: staged)
                try FileManager.default.createSymbolicLink(at: staged, withDestinationURL: foreign)
            })
            Issue.record("A replaced pending file must never be followed or committed")
        } catch let failure as ArchiveFailure { #expect(failure.completedFiles == 0) }
        #expect(try Data(contentsOf: foreign) == Data([9, 8, 7, 6, 5]))
        #expect(!FileManager.default.fileExists(atPath: f.request.targetURL.appendingPathComponent("a.JPG").path))
        let remaining = try FileManager.default.contentsOfDirectory(at: f.request.targetURL, includingPropertiesForKeys: [.isSymbolicLinkKey])
        #expect(remaining.count == 1)
        #expect(try remaining[0].resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true)
    }

    @Test func replacingDestinationBetweenCopyAndVerificationPreservesForeignDirectory() async throws {
        let f = try Fixture(), journal = TwoPhaseJournal()
        let moved = f.root.appendingPathComponent("moved-original-directory", isDirectory: true)
        do {
            _ = try await DeviceArchiveEngine.archive(report: plan(f, files: [item("a", "a.JPG")]), read: { file, _, _ in
                journal.read(file.id)
                return Data(repeating: 1, count: 5)
            }, validate: {
                guard journal.validate() == 2 else { return }
                try FileManager.default.moveItem(at: f.request.targetURL, to: moved)
                try FileManager.default.createDirectory(at: f.request.targetURL, withIntermediateDirectories: false)
                try Data([7]).write(to: f.request.targetURL.appendingPathComponent("sentinel"))
            })
            Issue.record("The pending copy's destination identity must remain pinned")
        } catch let failure as ArchiveFailure { #expect(failure.completedFiles == 0) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: f.request.targetURL.path) == ["sentinel"])
        #expect(try Data(contentsOf: f.request.targetURL.appendingPathComponent("sentinel")) == Data([7]))
        #expect(try FileManager.default.contentsOfDirectory(atPath: moved.path).isEmpty)
    }

    @Test func cancellationDuringVerificationPreservesOnlyAlreadyVerifiedGroups() async throws {
        let f = try Fixture(), journal = TwoPhaseJournal()
        let files = [item("a", "a.JPG"), item("b", "b.JPG"), item("c", "c.JPG")]
        let report = try plan(f, files: files)
        let task = Task.detached {
            try await DeviceArchiveEngine.archive(report: report, read: { file, _, _ in
                journal.read(file.id)
                return Data(repeating: 1, count: 5)
            }, validate: { _ = journal.validate() }, progress: { value in
                journal.progress(value)
                if value.stage == .verifying && value.completedFiles == 1 {
                    withUnsafeCurrentTask { $0?.cancel() }
                }
            })
        }
        do { _ = try await task.value; Issue.record("Cancellation must stop the remaining verification") }
        catch let failure as ArchiveFailure { #expect(failure.completedFiles == 1 && failure.message.contains("取消")) }
        #expect(journal.snapshot().readIDs == Set(files.map(\.id)))
        #expect(try FileManager.default.contentsOfDirectory(atPath: f.request.targetURL.path) == ["a.JPG"])
    }

    @Test func largeBatchDoesNotKeepOneOpenDescriptorPerCopiedFile() async throws {
        let f = try Fixture(), journal = TwoPhaseJournal()
        let files = (0..<300).map { item(String($0), String(format: "%04d.JPG", $0)) }
        let result = try await DeviceArchiveEngine.archive(report: plan(f, files: files), read: { file, _, _ in
            journal.read(file.id)
            if Int(file.id)! % 25 == 0 {
                let descriptorCount = try Self.openDescriptors(under: f.request.targetURL)
                #expect(descriptorCount <= 4)
            }
            return Data(repeating: 1, count: 5)
        }, validate: {
            if journal.validate() == 2 {
                let descriptorCount = try Self.openDescriptors(under: f.request.targetURL)
                #expect(descriptorCount <= 4)
            }
        })
        #expect(result.fileCount == 300)
        #expect(journal.snapshot().validationReadCounts == [0, 300])
        #expect(try FileManager.default.contentsOfDirectory(atPath: result.targetURL.path).count == 300)
    }

    private static func openDescriptors(under directory: URL) throws -> Int {
        let prefix = directory.resolvingSymlinksInPath().path
        return try FileManager.default.contentsOfDirectory(atPath: "/dev/fd").compactMap(Int32.init).filter { fd in
            var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
            let status = path.withUnsafeMutableBufferPointer { fcntl(fd, F_GETPATH, $0.baseAddress!) }
            return status == 0 && String(cString: path).hasPrefix(prefix)
        }.count
    }
}

private extension Array {
    var only: Element? { count == 1 ? first : nil }
}

private final class TwoPhaseJournal: @unchecked Sendable {
    struct Snapshot {
        let readIDs: Set<String>
        let validationReadCounts: [Int]
        let progress: [ArchiveProgress]
        let events: [String]
    }
    private let lock = NSLock()
    private var readIDs = Set<String>()
    private var validationReadCounts: [Int] = []
    private var values: [ArchiveProgress] = []
    private var events: [String] = []
    func read(_ id: String) {
        lock.lock(); defer { lock.unlock() }
        readIDs.insert(id); events.append("read:\(id)")
    }
    @discardableResult func validate() -> Int {
        lock.lock(); defer { lock.unlock() }
        validationReadCounts.append(readIDs.count); events.append("validate")
        return validationReadCounts.count
    }
    func pair() { lock.lock(); defer { lock.unlock() }; events.append("pair") }
    func progress(_ value: ArchiveProgress) {
        lock.lock(); defer { lock.unlock() }
        values.append(value); events.append(value.stage.rawValue)
    }
    func snapshot() -> Snapshot {
        lock.lock(); defer { lock.unlock() }
        return Snapshot(readIDs: readIDs, validationReadCounts: validationReadCounts, progress: values, events: events)
    }
}
