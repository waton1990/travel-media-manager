import AVFoundation
import Foundation
import ImageIO

/// Checks the embedded pairing identifiers after both originals have been
/// copied locally. Matching filenames or byte counts never establish a pair.
public enum LivePhotoPairVerifier {
    public static func verify(photoURL: URL, videoURL: URL) async throws {
        try Task.checkCancellation()
        guard photoURL.isFileURL, videoURL.isFileURL, photoURL != videoURL,
              let source = CGImageSourceCreateWithURL(photoURL as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] else {
            throw ArchiveError.invalid("无法读取实况照片的原始图片元数据，整组未完成归档。")
        }
        let photoID = try photoIdentifier(properties: properties)
        let asset = AVURLAsset(url: videoURL)
        try await withTaskCancellationHandler {
            let metadata = try await asset.load(.metadata)
            let videoID = try await videoIdentifier(metadata: metadata)
            try Task.checkCancellation()
            guard photoID == videoID else {
                throw ArchiveError.invalid("实况照片与视频的内容标识不一致，整组未完成归档。")
            }
        } onCancel: {
            asset.cancelLoading()
        }
    }

    static func photoIdentifier(properties: [String: Any]) throws -> String {
        guard let maker = properties[kCGImagePropertyMakerAppleDictionary as String] as? NSDictionary else {
            throw ArchiveError.invalid("实况照片缺少可验证的 Apple 内容标识，整组未完成归档。")
        }
        let identifiers: [Any] = maker.compactMap { key, value in
            if let name = key as? String, name == "17" { return value }
            if let number = key as? NSNumber, number == NSNumber(value: 17) { return value }
            return nil
        }
        guard identifiers.count == 1 else {
            throw ArchiveError.invalid("实况照片的内容标识缺失或不唯一，整组未完成归档。")
        }
        return try canonicalIdentifier(identifiers[0])
    }

    static func videoIdentifier(metadata: [AVMetadataItem]) async throws -> String {
        let identifiers = AVMetadataItem.metadataItems(from: metadata, filteredByIdentifier: .quickTimeMetadataContentIdentifier)
        guard identifiers.count == 1, let value = try await identifiers[0].load(.stringValue) else {
            throw ArchiveError.invalid("实况视频的内容标识缺失或不唯一，整组未完成归档。")
        }
        return try canonicalIdentifier(value)
    }

    private static func canonicalIdentifier(_ value: Any) throws -> String {
        guard let text = value as? String, text.utf8.count == 36, let identifier = UUID(uuidString: text) else {
            throw ArchiveError.invalid("实况素材的内容标识格式暂不支持，整组未完成归档。")
        }
        return identifier.uuidString
    }
}
