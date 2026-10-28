import Testing
import Foundation
import Darwin
@testable import TravelArchiveCore

struct ArchiveEngineTests {
    private let day = CaptureDay("2026-08-26")!

    private final class Fixture: @unchecked Sendable {
        let root: URL
        let source: URL
        let destination: URL
        init(root: URL, source: URL, destination: URL) { self.root = root; self.source = source; self.destination = destination }
        deinit { try? FileManager.default.removeItem(at: root) }
        var request: ArchiveRequest {
            ArchiveRequest(name: "旅行测试", start: CaptureDay("2026-08-26")!, end: CaptureDay("2026-08-28")!, source: source, destination: destination)
        }
    }

    private func fixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TravelArchiveEngineTests-\(UUID().uuidString)", isDirectory: true)
        let source = root.appendingPathComponent("source", isDirectory: true)
        let destination = root.appendingPathComponent("destination", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        return Fixture(root: root, source: source, destination: destination)
    }

    private func media(_ url: URL, kind: MediaKind = .video, data: Data = Data([0, 1, 2, 3, 255])) throws -> MediaFile {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
        return MediaFile(url: url, kind: kind, captureDay: day, dateBasis: "fixture", snapshot: try FileSnapshot.read(url))
    }

    private func report(_ request: ArchiveRequest, _ files: [MediaFile]) -> ScanReport {
        ScanReport(request: request, files: files, issues: [], outsideRangeCount: 0, ignoredCount: 0)
    }

    private func failure(_ report: ScanReport, progress: @escaping @Sendable (ArchiveProgress) -> Void = { _ in }) async throws -> ArchiveFailure {
        do {
            _ = try await ArchiveEngine.archive(report: report, progress: progress)
            Issue.record("Expected an ArchiveFailure")
            throw ArchiveError.invalid("Expected failure")
        } catch let error as ArchiveFailure {
            return error
        }
    }

    @Test func testCopiesAllSupportedKindsWithExactBytesAndUnchangedSources() async throws {
        let f = try fixture()
        let files = try [
            media(f.source.appendingPathComponent("nested/clip.MP4"), data: Data(repeating: 42, count: 2_100_007)),
            media(f.source.appendingPathComponent("photo.JPG"), kind: .photo),
            media(f.source.appendingPathComponent("sound.AAC"), kind: .audio)
        ]
        let lrf = f.source.appendingPathComponent("clip.LRF")
        let lrfData = Data([9, 8, 7])
        try lrfData.write(to: lrf)
        let events = ProgressLog()
        try ArchiveEngine.validateDestination(for: f.request, requiredBytes: report(f.request, files).totalBytes)
        #expect(!(FileManager.default.fileExists(atPath: f.request.targetURL.path)))
        let result = try await ArchiveEngine.archive(report: report(f.request, files)) { events.append($0) }
        #expect((result.fileCount) == (3))
        #expect((result.totalBytes) == (files.reduce(0) { $0 + $1.size }))
        for file in files {
            let copy = result.targetURL.appendingPathComponent(file.url.lastPathComponent)
            #expect((try Data(contentsOf: copy)) == (try Data(contentsOf: file.url)))
            #expect((try FileSnapshot.read(file.url)) == (file.snapshot))
        }
        #expect((try Data(contentsOf: lrf)) == (lrfData))
        #expect(!(FileManager.default.fileExists(atPath: result.targetURL.appendingPathComponent("clip.LRF").path)))
        #expect((try FileManager.default.contentsOfDirectory(atPath: result.targetURL.path).count) == (3))
        let progress = events.all
        #expect(progress.contains { $0.stage == .copying })
        #expect(progress.contains { $0.stage == .verifying })
        #expect((progress.last?.fraction) == (1))
        #expect((progress.last?.completedFiles) == (3))
        #expect(zip(progress, progress.dropFirst()).allSatisfy { $0.completedBytes <= $1.completedBytes })
    }

    @Test func testExistingTargetNeverOverwritten() async throws {
        let f = try fixture()
        let file = try media(f.source.appendingPathComponent("clip.MP4"))
        try FileManager.default.createDirectory(at: f.request.targetURL, withIntermediateDirectories: false)
        let existing = f.request.targetURL.appendingPathComponent("clip.MP4")
        let original = Data([8, 8, 8])
        try original.write(to: existing)
        let error = try await failure(report(f.request, [file]))
        #expect((error.completedFiles) == (0))
        #expect((error.targetURL) == nil)
        #expect((try Data(contentsOf: existing)) == (original))
    }

    @Test func testAnyChangedSnapshotPreventsCreatingTarget() async throws {
        let f = try fixture()
        let first = try media(f.source.appendingPathComponent("first.MP4"))
        let changed = try media(f.source.appendingPathComponent("changed.JPG"), kind: .photo)
        try Data([7, 6, 5, 4, 3, 2]).write(to: changed.url)
        let error = try await failure(report(f.request, [first, changed]))
        #expect(error.message.contains("发生变化"))
        #expect((error.targetURL) == nil)
        #expect(!(FileManager.default.fileExists(atPath: f.request.targetURL.path)))
    }

    @Test func testFlattenedCaseInsensitiveFilenameCollisionIsBlocked() async throws {
        let f = try fixture()
        let one = try media(f.source.appendingPathComponent("one/clip.MP4"))
        let two = try media(f.source.appendingPathComponent("two/CLIP.mp4"))
        let error = try await failure(report(f.request, [one, two]))
        #expect(error.message.contains("重名"))
        #expect(!(FileManager.default.fileExists(atPath: f.request.targetURL.path)))
    }

    @Test func testOutsideSourceAndLRFAreRejected() async throws {
        let f = try fixture()
        let outside = try media(f.root.appendingPathComponent("outside.MP4"))
        let escaped = try await failure(report(f.request, [outside]))
        #expect(escaped.message.contains("不在所选来源"))
        let lrf = try media(f.source.appendingPathComponent("clip.LRF"))
        let unsupported = try await failure(report(f.request, [lrf]))
        #expect(unsupported.message.contains("不支持"))
        #expect(!(FileManager.default.fileExists(atPath: f.request.targetURL.path)))
    }

    @Test func testDestinationInsideSourceIsRejectedWithoutWrites() throws {
        let f = try fixture()
        let nested = f.source.appendingPathComponent("output", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: false)
        let request = ArchiveRequest(name: "test", start: day, end: day, source: f.source, destination: nested)
        #expect(throws: (any Error).self) { try ArchiveEngine.validateDestination(for: request) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: nested.path).isEmpty)
    }

    @Test func testSymlinkReplacementOfSourceFileIsRejected() async throws {
        let f = try fixture()
        let file = try media(f.source.appendingPathComponent("clip.MP4"))
        let other = try media(f.root.appendingPathComponent("other.MP4"))
        try FileManager.default.removeItem(at: file.url)
        try FileManager.default.createSymbolicLink(at: file.url, withDestinationURL: other.url)
        let error = try await failure(report(f.request, [file]))
        #expect((error.completedFiles) == (0))
        #expect(!(FileManager.default.fileExists(atPath: f.request.targetURL.path)))
        #expect((try Data(contentsOf: other.url)) == (Data([0, 1, 2, 3, 255])))
    }

    @Test func testIntermediateSourceSymlinkIsRejected() async throws {
        let f = try fixture()
        let file = try media(f.source.appendingPathComponent("nested/clip.MP4"))
        let original = f.source.appendingPathComponent("nested")
        let moved = f.root.appendingPathComponent("moved")
        try FileManager.default.moveItem(at: original, to: moved)
        try FileManager.default.createSymbolicLink(at: original, withDestinationURL: moved)
        _ = try await failure(report(f.request, [file]))
        #expect(!(FileManager.default.fileExists(atPath: f.request.targetURL.path)))
    }

    @Test func testCanonicalRootRejectsAncestorReplacedWithSymlink() throws {
        let f = try fixture()
        let ancestor = f.root.appendingPathComponent("ancestor", isDirectory: true)
        let selected = ancestor.appendingPathComponent("selected", isDirectory: true)
        try FileManager.default.createDirectory(at: selected, withIntermediateDirectories: true)
        let canonical = try PathPolicy.canonicalDirectory(selected)
        let moved = f.root.appendingPathComponent("moved-ancestor", isDirectory: true)
        try FileManager.default.moveItem(at: ancestor, to: moved)
        try FileManager.default.createSymbolicLink(at: ancestor, withDestinationURL: moved)
        // The last component is still a real directory. Checking only that
        // component with O_NOFOLLOW would incorrectly allow this traversal.
        #expect(throws: (any Error).self) {
            let fd = try PathPolicy.openDirectory(canonical)
            close(fd)
        }
    }

    @Test func testSelectedDirectoryReplacementInvalidatesHeldDescriptor() throws {
        let f = try fixture()
        let canonical = try PathPolicy.canonicalDirectory(f.destination)
        let fd = try PathPolicy.openDirectory(canonical)
        defer { close(fd) }
        let moved = f.root.appendingPathComponent("previous-destination", isDirectory: true)
        try FileManager.default.moveItem(at: f.destination, to: moved)
        try FileManager.default.createDirectory(at: f.destination, withIntermediateDirectories: false)
        #expect(throws: (any Error).self) {
            try PathPolicy.confirmDirectory(f.destination, fd: fd)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: moved.path).isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: f.destination.path).isEmpty)
    }

    @Test func testCancelledCopyCleansPartialAndPreservesVerifiedFile() async throws {
        let f = try fixture()
        let first = try media(f.source.appendingPathComponent("first.MP4"))
        let second = try media(f.source.appendingPathComponent("second.MP4"), data: Data(repeating: 7, count: 3_100_000))
        let scan = report(f.request, [first, second])
        let task = Task.detached {
            try await ArchiveEngine.archive(report: scan) { progress in
                if progress.currentFile == "second.MP4", progress.stage == .copying,
                   progress.completedBytes > first.size * 2 {
                    withUnsafeCurrentTask { $0?.cancel() }
                }
            }
        }
        do {
            _ = try await task.value
            Issue.record("Expected cancellation")
        } catch let error as ArchiveFailure {
            #expect(error.message.contains("取消"))
            #expect((error.completedFiles) == (1))
            #expect((error.targetURL) == (f.request.targetURL))
        }
        #expect((try FileManager.default.contentsOfDirectory(atPath: f.request.targetURL.path)) == (["first.MP4"]))
        #expect((try FileSnapshot.read(second.url)) == (second.snapshot))
    }

    @Test func testSourceChangeDuringCopyCleansPartial() async throws {
        let f = try fixture()
        let file = try media(f.source.appendingPathComponent("clip.MP4"), data: Data(repeating: 4, count: 2_500_000))
        let error = try await failure(report(f.request, [file])) { update in
            if update.stage == .copying, update.completedBytes > 0 {
                // Replacing the path leaves the source descriptor valid, so the
                // post-copy pathname check must still detect the replacement.
                try? Data([1, 2, 3]).write(to: file.url, options: .atomic)
            }
        }
        #expect((error.completedFiles) == (0))
        #expect(try FileManager.default.contentsOfDirectory(atPath: f.request.targetURL.path).isEmpty)
    }

    @Test func testDestinationAppearingDuringCopyIsNotOverwritten() async throws {
        let f = try fixture()
        let file = try media(f.source.appendingPathComponent("clip.MP4"), data: Data(repeating: 4, count: 2_500_000))
        let finalURL = f.request.targetURL.appendingPathComponent("clip.MP4")
        let sentinel = Data([9, 9, 9])
        let error = try await failure(report(f.request, [file])) { update in
            if update.stage == .verifying { try? sentinel.write(to: finalURL) }
        }
        #expect((error.completedFiles) == (0))
        #expect((try Data(contentsOf: finalURL)) == (sentinel))
        #expect((try FileManager.default.contentsOfDirectory(atPath: f.request.targetURL.path)) == (["clip.MP4"]))
    }
}

private final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [ArchiveProgress] = []
    func append(_ item: ArchiveProgress) { lock.lock(); defer { lock.unlock() }; storage.append(item) }
    var all: [ArchiveProgress] { lock.lock(); defer { lock.unlock() }; return storage }
}
