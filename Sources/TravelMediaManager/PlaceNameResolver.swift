import CoreLocation
import Foundation
import TravelArchiveCore

struct PlaceResolutionResult: Sendable {
    let names: [String: String]
    let localCount: Int
    let cacheCount: Int
    let networkRequestCount: Int
    let unresolvedCount: Int
}

/// Local labels belong to individual assets and never seed the network cache.
@MainActor
final class PlaceNameResolver {
    typealias Lookup = @MainActor (GeoCoordinate) async throws -> String?
    typealias Pause = @MainActor () async throws -> Void
    private let lookup: Lookup
    private let pause: Pause
    private var networkCache: [GeoCoordinate: String] = [:]

    init(lookup: Lookup? = nil, pause: Pause? = nil) {
        self.lookup = lookup ?? { coordinate in try await Self.lookupApple(coordinate) }
        self.pause = pause ?? { try await Task.sleep(nanoseconds: 1_200_000_000) }
    }

    func resolve(assets: [DeviceTravelAsset],
                 progress: @escaping @Sendable (ScanProgress) -> Void) async throws -> PlaceResolutionResult {
        guard Set(assets.map(\.id)).count == assets.count, assets.allSatisfy({ !$0.id.isEmpty }) else {
            throw ArchiveError.invalid("地点列表包含重复或缺失的素材标识，请重新扫描。")
        }
        var names: [String: String] = [:]
        var localCount = 0, cacheCount = 0, requests = 0, failures = 0
        var pending: [DeviceTravelAsset] = []
        // Trusted local records remain available even if the fallback service fails.
        for asset in assets {
            try Task.checkCancellation()
            guard let coordinate = asset.coordinate else { continue }
            if let localName = Self.validName(asset.localPlaceName) {
                names[asset.id] = localName
                localCount += 1
            } else if let cached = networkCache[coordinate] {
                names[asset.id] = cached
                cacheCount += 1
            } else {
                pending.append(asset)
            }
        }
        progress(ScanProgress(visitedFiles: localCount + cacheCount,
                              currentFile: "已读取手机现成城市信息（\(localCount)/\(assets.count)）"))
        let initiallyResolved = localCount + cacheCount
        for (index, asset) in pending.enumerated() {
            try Task.checkCancellation()
            guard let coordinate = asset.coordinate else { continue }
            // An earlier request may have populated this exact coordinate.
            if let cached = networkCache[coordinate] {
                names[asset.id] = cached
                cacheCount += 1
                continue
            }
            if failures >= 2 { continue }
            if requests > 0 { try await pause() }
            try Task.checkCancellation()
            progress(ScanProgress(visitedFiles: initiallyResolved + index,
                                  currentFile: "正在联网补查城市（\(index + 1)/\(pending.count)）"))
            requests += 1
            do {
                let result = try await lookup(coordinate)
                try Task.checkCancellation()
                if let name = Self.validName(result) {
                    networkCache[coordinate] = name
                    names[asset.id] = name
                }
                failures = 0
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try Task.checkCancellation()
                failures += 1
            }
        }
        try Task.checkCancellation()
        let unresolved = assets.count - names.count
        let summary = requests == 0
            ? "地点整理完成：使用手机现成信息 \(localCount) 项，复用查询结果 \(cacheCount) 项，无需联网查询。"
            : "地点整理完成：使用手机现成信息 \(localCount) 项，联网补查 \(requests) 次。"
        progress(ScanProgress(visitedFiles: assets.count, currentFile: summary))
        return PlaceResolutionResult(names: names, localCount: localCount, cacheCount: cacheCount,
                                     networkRequestCount: requests, unresolvedCount: unresolved)
    }

    private static func validName(_ value: String?) -> String? {
        guard let value, value.count <= 512,
              !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
        let name = value.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping
        return name.isEmpty ? nil : name
    }

    private static func lookupApple(_ coordinate: GeoCoordinate) async throws -> String? {
        let geocoder = CLGeocoder()
        let deadline = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            if !Task.isCancelled { geocoder.cancelGeocode() }
        }
        defer { deadline.cancel() }
        let places = try await withTaskCancellationHandler {
            try await geocoder.reverseGeocodeLocation(
                CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude),
                preferredLocale: Locale(identifier: "zh_CN"))
        } onCancel: { Task { @MainActor in geocoder.cancelGeocode() } }
        try Task.checkCancellation()
        guard let place = places.first,
              let region = place.locality ?? place.subAdministrativeArea ?? place.administrativeArea,
              !region.isEmpty else { return nil }
        var parts = [String]()
        for part in [place.country, place.administrativeArea, region].compactMap({ $0 })
            where !part.isEmpty && parts.last != part { parts.append(part) }
        return parts.joined(separator: " · ")
    }
}
