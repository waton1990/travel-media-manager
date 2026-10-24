import AVFoundation
import CoreGraphics
import CoreVideo
import Darwin
import Foundation
import ImageIO
import Testing
@testable import TravelArchiveCore

struct LivePhotoPairTests {
    private final class Fixture: @unchecked Sendable {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LivePhotoPairTests-\(UUID())", isDirectory: true)
        init() throws { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false) }
        deinit { try? FileManager.default.removeItem(at: root) }
        var request: DeviceArchiveRequest {
            DeviceArchiveRequest(name: "实况照片", start: CaptureDay("2026-10-13")!, end: CaptureDay("2026-10-13")!, destination: root, timeZoneIdentifier: "Asia/Shanghai")
        }
    }

    private func metadata(_ value: String) -> AVMetadataItem {
        let item = AVMutableMetadataItem()
        item.identifier = .quickTimeMetadataContentIdentifier
        item.value = value as NSString
        item.dataType = kCMMetadataBaseDataType_UTF8 as String
        return item
    }

    private func image(at url: URL, identifier: String?, heic: Bool = false) throws {
        let context = try #require(CGContext(data: nil, width: 32, height: 32, bitsPerComponent: 8, bytesPerRow: 128,
                                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.6, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, (heic ? "public.heic" : "public.jpeg") as CFString, 1, nil))
        let properties: [String: Any] = identifier.map { [kCGImagePropertyMakerAppleDictionary as String: ["17": $0]] } ?? [:]
        CGImageDestinationAddImage(destination, try #require(context.makeImage()), properties as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
    }

    private func movie(at url: URL, identifiers: [String]) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        writer.metadata = identifiers.map(metadata)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 32, AVVideoHeightKey: 32])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: 32, kCVPixelBufferHeightKey as String: 32])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? ArchiveError.invalid("Cannot create synthetic movie") }
        writer.startSession(atSourceTime: .zero)
        var pixel: CVPixelBuffer?
        #expect(CVPixelBufferCreate(kCFAllocatorDefault, 32, 32, kCVPixelFormatType_32BGRA, nil, &pixel) == kCVReturnSuccess)
        let buffer = try #require(pixel)
        CVPixelBufferLockBaseAddress(buffer, [])
        if let address = CVPixelBufferGetBaseAddress(buffer) { memset(address, 0x80, CVPixelBufferGetDataSize(buffer)) }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        for _ in 0..<100 where !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 10_000_000) }
        guard input.isReadyForMoreMediaData, adaptor.append(buffer, withPresentationTime: .zero) else {
            throw writer.error ?? ArchiveError.invalid("Cannot append synthetic frame")
        }
        writer.endSession(atSourceTime: CMTime(value: 1, timescale: 30))
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? ArchiveError.invalid("Cannot finish synthetic movie") }
    }

    private func item(_ id: String, _ kind: MediaKind, size: Int64 = 5, companions: [String] = []) -> DeviceMediaItem {
        DeviceMediaItem(id: id, name: "\(id).\(kind == .photo ? "JPG" : "MOV")", kind: kind, size: size,
                        captureDay: CaptureDay("2026-10-13")!, dateBasis: "fixture", companionIDs: companions)
    }

    private func plan(_ f: Fixture, files: [DeviceMediaItem]) throws -> DeviceScanReport {
        try DeviceMediaPlanner.scan(items: files, request: f.request, deviceID: "fixture", deviceName: "测试 iPhone")
    }

    @Test func realJPEGAndHEICWithRealMOVRequireMatchingEmbeddedIdentifiers() async throws {
        let f = try Fixture(), id = UUID().uuidString
        let video = f.root.appendingPathComponent("paired.MOV")
        try await movie(at: video, identifiers: [id])
        for heic in [false, true] {
            let photo = f.root.appendingPathComponent(heic ? "photo.HEIC" : "photo.JPG")
            try image(at: photo, identifier: id.lowercased(), heic: heic)
            try await LivePhotoPairVerifier.verify(photoURL: photo, videoURL: video)
            let wrong = f.root.appendingPathComponent(heic ? "wrong.HEIC" : "wrong.JPG")
            try image(at: wrong, identifier: UUID().uuidString, heic: heic)
            do {
                try await LivePhotoPairVerifier.verify(photoURL: wrong, videoURL: video)
                Issue.record("Different embedded content identifiers must fail")
            } catch { #expect(error.localizedDescription.contains("不一致")) }
        }
    }

    @Test func realFilesWithMissingPhotoOrVideoIdentifierFailClosed() async throws {
        let f = try Fixture(), id = UUID().uuidString
        let validPhoto = f.root.appendingPathComponent("valid.JPG"), missingPhoto = f.root.appendingPathComponent("missing.JPG")
        let validVideo = f.root.appendingPathComponent("valid.MOV"), missingVideo = f.root.appendingPathComponent("missing.MOV")
        try image(at: validPhoto, identifier: id)
        try image(at: missingPhoto, identifier: nil)
        try await movie(at: validVideo, identifiers: [id])
        try await movie(at: missingVideo, identifiers: [])
        for (photo, video) in [(missingPhoto, validVideo), (validPhoto, missingVideo)] {
            do { try await LivePhotoPairVerifier.verify(photoURL: photo, videoURL: video); Issue.record("Missing identifier must fail") }
            catch { #expect(error.localizedDescription.contains("标识")) }
        }
    }

    @Test func ambiguousAndMalformedMetadataAreRejected() async throws {
        let id = UUID().uuidString
        for value: Any in ["", "not-an-id", [id], 17] {
            #expect(throws: (any Error).self) {
                _ = try LivePhotoPairVerifier.photoIdentifier(properties: [kCGImagePropertyMakerAppleDictionary as String: ["17": value]])
            }
        }
        let duplicate = NSMutableDictionary()
        duplicate["17"] = id
        duplicate[NSNumber(value: 17)] = id
        #expect(throws: (any Error).self) {
            _ = try LivePhotoPairVerifier.photoIdentifier(properties: [kCGImagePropertyMakerAppleDictionary as String: duplicate])
        }
        for items in [[], [metadata(id), metadata(id)], [metadata("not-an-id")]] {
            do { _ = try await LivePhotoPairVerifier.videoIdentifier(metadata: items); Issue.record("Ambiguous metadata must fail") }
            catch { #expect(error.localizedDescription.contains("标识")) }
        }
    }

    @Test func realPairUsesProductionValidatorBeforeCountingEitherFile() async throws {
        let f = try Fixture(), id = UUID().uuidString
        let photoURL = f.root.appendingPathComponent("source.JPG"), videoURL = f.root.appendingPathComponent("source.MOV")
        try image(at: photoURL, identifier: id)
        try await movie(at: videoURL, identifiers: [id])
        let bytes = ["p": try Data(contentsOf: photoURL), "v": try Data(contentsOf: videoURL)]
        let files = [item("p", .photo, size: Int64(bytes["p"]!.count), companions: ["v"]), item("v", .video, size: Int64(bytes["v"]!.count), companions: ["p"])]
        let progress = PairProgressRecorder()
        let result = try await DeviceArchiveEngine.archive(report: plan(f, files: files), read: { file, offset, count in
            let data = bytes[file.id]!
            return data.subdata(in: Int(offset)..<min(Int(offset) + count, data.count))
        }, validate: {}, progress: { progress.append($0.completedFiles) })
        #expect(result.fileCount == 2)
        #expect(!progress.values.contains(1))
        #expect(Set(try FileManager.default.contentsOfDirectory(atPath: result.targetURL.path)) == ["p.JPG", "v.MOV"])
        #expect(try Data(contentsOf: result.targetURL.appendingPathComponent("p.JPG")) == bytes["p"])
        #expect(try Data(contentsOf: result.targetURL.appendingPathComponent("v.MOV")) == bytes["v"])
    }

    @Test func mismatchedRealPairLeavesNoCommittedStaticImageOrVideo() async throws {
        let f = try Fixture()
        let photoURL = f.root.appendingPathComponent("source.JPG"), videoURL = f.root.appendingPathComponent("source.MOV")
        try image(at: photoURL, identifier: UUID().uuidString)
        try await movie(at: videoURL, identifiers: [UUID().uuidString])
        let bytes = ["p": try Data(contentsOf: photoURL), "v": try Data(contentsOf: videoURL)]
        let files = [item("p", .photo, size: Int64(bytes["p"]!.count), companions: ["v"]), item("v", .video, size: Int64(bytes["v"]!.count), companions: ["p"])]
        do {
            _ = try await DeviceArchiveEngine.archive(report: plan(f, files: files), read: { file, offset, count in
                let data = bytes[file.id]!
                return data.subdata(in: Int(offset)..<min(Int(offset) + count, data.count))
            }, validate: {})
            Issue.record("Mismatched real pair must not archive")
        } catch let failure as ArchiveFailure { #expect(failure.completedFiles == 0 && failure.message.contains("不一致")) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: f.request.targetURL.path).isEmpty)
    }

    @Test func readFailureClearsUnverifiedBatchButPairFailurePreservesVerifiedAssets() async throws {
        for failRead in [true, false] {
            let f = try Fixture()
            let files = [item("a", .photo), item("p", .photo, companions: ["v"]), item("v", .video, companions: ["p"])]
            do {
                _ = try await DeviceArchiveEngine.archive(report: plan(f, files: files), read: { file, _, _ in
                    if failRead && file.id == "v" { throw ArchiveError.invalid("synthetic read failure") }
                    return Data(repeating: 1, count: 5)
                }, validate: {}, verifyLivePhoto: { _, _ in throw ArchiveError.invalid("synthetic pair mismatch") })
                Issue.record("Failed pair must not archive")
            } catch let failure as ArchiveFailure { #expect(failure.completedFiles == (failRead ? 0 : 1)) }
            #expect(try FileManager.default.contentsOfDirectory(atPath: f.request.targetURL.path) == (failRead ? [] : ["a.JPG"]))
        }
    }

    @Test func cancellationDuringPairVerificationRemovesBothStagedFiles() async throws {
        let f = try Fixture()
        let report = try plan(f, files: [item("p", .photo, companions: ["v"]), item("v", .video, companions: ["p"])])
        let task = Task.detached {
            try await DeviceArchiveEngine.archive(report: report, read: { _, _, _ in Data(repeating: 1, count: 5) }, validate: {},
                                                 verifyLivePhoto: { _, _ in withUnsafeCurrentTask { $0?.cancel() } })
        }
        do { _ = try await task.value; Issue.record("Cancellation must fail") }
        catch let failure as ArchiveFailure { #expect(failure.completedFiles == 0 && failure.message.contains("取消")) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: f.request.targetURL.path).isEmpty)
    }

    @Test func defaultValidatorRejectsFakeBytesAndUnsupportedGroupsBeforeCommit() async throws {
        let f = try Fixture()
        let validShape = try plan(f, files: [item("p", .photo, companions: ["v"]), item("v", .video, companions: ["p"])])
        do {
            _ = try await DeviceArchiveEngine.archive(report: validShape, read: { _, _, _ in Data(repeating: 1, count: 5) }, validate: {})
            Issue.record("Production validator must reject arbitrary bytes")
        } catch let failure as ArchiveFailure { #expect(failure.completedFiles == 0) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: f.request.targetURL.path).isEmpty)
        let other = try Fixture()
        let invalidShape = try plan(other, files: [item("p", .photo, companions: ["q", "v"]), item("q", .photo, companions: ["p"]), item("v", .video, companions: ["p"])])
        do {
            _ = try await DeviceArchiveEngine.archive(report: invalidShape, read: { _, _, _ in Issue.record("Unsupported group must never read"); return Data() }, validate: {})
            Issue.record("Unsupported group must fail")
        } catch let failure as ArchiveFailure { #expect(failure.targetURL == nil && failure.completedFiles == 0) }
    }

    @Test func verificationCannotReplaceStagedFileAndPassIdentityChecks() async throws {
        let f = try Fixture()
        let report = try plan(f, files: [item("p", .photo, companions: ["v"]), item("v", .video, companions: ["p"])])
        do {
            _ = try await DeviceArchiveEngine.archive(report: report, read: { _, _, _ in Data(repeating: 1, count: 5) }, validate: {}, verifyLivePhoto: { photo, _ in
                try FileManager.default.removeItem(at: photo)
                try Data([9, 9, 9]).write(to: photo)
            })
            Issue.record("Replacing staged file must fail")
        } catch let failure as ArchiveFailure { #expect(failure.completedFiles == 0) }
        let remaining = try FileManager.default.contentsOfDirectory(at: f.request.targetURL, includingPropertiesForKeys: nil)
        #expect(remaining.count == 1)
        #expect(try Data(contentsOf: remaining[0]) == Data([9, 9, 9]))
        #expect(!FileManager.default.fileExists(atPath: f.request.targetURL.appendingPathComponent("p.JPG").path))
    }

    @Test func secondRenameFailureRollsBackOwnFirstFileButPreservesReplacement() throws {
        for replaceFirst in [false, true] {
            let f = try Fixture()
            try FileManager.default.createDirectory(at: f.request.targetURL, withIntermediateDirectories: false)
            let parentFD = try PathPolicy.openDirectory(PathPolicy.canonicalDirectory(f.root))
            let targetFD = try PathPolicy.openDirectory(PathPolicy.canonicalDirectory(f.request.targetURL))
            defer { close(parentFD); close(targetFD) }
            var staged: [DeviceArchiveEngine.StagedFile] = []
            defer { for entry in staged { close(entry.fd) } }
            for file in [item("p", .photo), item("v", .video)] {
                let temporaryName = "\(file.id).partial"
                let url = f.request.targetURL.appendingPathComponent(temporaryName)
                try Data(repeating: 1, count: 5).write(to: url)
                let fd = open(url.path, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
                #expect(fd >= 0)
                staged.append(.init(file: file, temporaryName: temporaryName, fd: fd, snapshot: try PathPolicy.snapshot(fd, name: file.name)))
            }
            #expect(throws: (any Error).self) {
                try DeviceArchiveEngine.commitStaged(staged, request: f.request, parentFD: parentFD, targetFD: targetFD) { count in
                    if count == 1 {
                        if replaceFirst {
                            let first = f.request.targetURL.appendingPathComponent("p.JPG")
                            try FileManager.default.removeItem(at: first)
                            try Data([7, 7]).write(to: first)
                        }
                        // A foreign file appears just before the second rename.
                        try Data([9]).write(to: f.request.targetURL.appendingPathComponent("v.MOV"))
                    }
                }
            }
            let first = f.request.targetURL.appendingPathComponent("p.JPG")
            #expect(FileManager.default.fileExists(atPath: first.path) == replaceFirst)
            if replaceFirst { #expect(try Data(contentsOf: first) == Data([7, 7])) }
            #expect(try Data(contentsOf: f.request.targetURL.appendingPathComponent("v.MOV")) == Data([9]))
        }
    }
}

private final class PairProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [Int] = []
    func append(_ count: Int) { lock.lock(); defer { lock.unlock() }; recorded.append(count) }
    var values: [Int] { lock.lock(); defer { lock.unlock() }; return recorded }
}
